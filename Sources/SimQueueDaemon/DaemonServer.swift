// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueEngine
import SimQueueIPC
import SimQueueProtocol

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// Exclusive `flock` on the state directory's lock file: at most one daemon per state
/// directory, even before the socket exists. Released automatically if the process dies.
public final class InstanceLock {
    private var descriptor: Int32

    public enum LockError: Error, Equatable, CustomStringConvertible {
        case alreadyRunning(String)
        case system(String, Int32)

        public var description: String {
            switch self {
            case .alreadyRunning(let path): return "another simqd holds \(path)"
            case .system(let call, let code): return "\(call) failed: \(String(cString: strerror(code)))"
            }
        }
    }

    public init(path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Close-on-exec: a job command must never inherit (and so keep holding) the lock.
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw LockError.system("open \(path)", errno)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK {
                throw LockError.alreadyRunning(path)
            }
            throw LockError.system("flock", code)
        }
        self.descriptor = descriptor
    }

    public func release() {
        if descriptor >= 0 {
            flock(descriptor, LOCK_UN)
            close(descriptor)
            descriptor = -1
        }
    }

    deinit {
        release()
    }
}

/// Host-wide lock for daemons that manage real sims (#35). The per-state-dir lock lets
/// two daemons with different state dirs run at once, but the `simq-` sim namespace is
/// the whole (per-user) CoreSimulator device set, so each would reap the other's sims.
/// A real-sim daemon must also hold this lock; the file records the holder's state dir
/// so the refusal can name it. The fake backend never touches real sims and skips it.
public enum HostLock {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case heldBy(lockPath: String, stateDir: String?)
        public var description: String {
            switch self {
            case .heldBy(let path, let stateDir):
                "another simqd on this host already manages the simq- sim namespace"
                    + (stateDir.map { " (state dir \($0))" } ?? "")
                    + "; only one real-sim daemon per user (host lock \(path))"
            }
        }
    }

    /// Takes the lock for `backend`, or returns nil when the backend needs none.
    public static func acquire(backend: BackendKind, lockPath: String, stateDir: String) throws -> InstanceLock? {
        guard backend != .fake else { return nil }
        do {
            let lock = try InstanceLock(path: lockPath)
            try? Data((stateDir + "\n").utf8).write(to: URL(fileURLWithPath: lockPath))
            return lock
        } catch InstanceLock.LockError.alreadyRunning {
            let holder = (try? String(contentsOfFile: lockPath, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.heldBy(lockPath: lockPath, stateDir: holder?.isEmpty == false ? holder : nil)
        }
    }
}

/// Socket server plus run loop. Requests are newline-delimited JSON; each connection
/// carries one request. `wait` streams `event` lines on every change, then a final
/// `result`. The tick loop runs scheduling passes; a lost lease stops everything.
public final class DaemonServer: @unchecked Sendable {
    public let service: DaemonService
    public let listener: UnixListener
    /// Seconds between `wait` polls of the job row.
    public var waitPollSeconds: Double = 0.05

    // Separate bounded lanes keep streaming waits and slow administrative work
    // from consuming the control lane or Dispatch's shared worker pool.
    private let ingressSlots = DispatchSemaphore(value: 4)
    private let workSlots = DispatchSemaphore(value: 8)
    private let controlSlots = DispatchSemaphore(value: 4)
    private let waitSlots = DispatchSemaphore(value: 16)
    private let healthSlots = DispatchSemaphore(value: 1)
    public var livenessIntervalSeconds: Double = 5
    public var livenessTimeoutSeconds: Double = 2
    /// How long status may go unanswered while the service lock also stands still before
    /// the daemon counts as wedged.
    public var livenessFailureSeconds: Double = 30
    /// How long status may go unanswered while the daemon is otherwise working (the lock
    /// still changes hands) before the socket counts as unusable. Much longer: on an
    /// overloaded host a status answer regularly takes longer than the probe waits, and
    /// restarting a working daemon interrupts every running job.
    public var livenessStarvedSeconds: Double = 600
    /// A wedged lock cannot be joined safely. Exit directly so KeepAlive can restart.
    /// The argument is the reason; the default writes it to the daemon log first.
    public var livenessFailure: @Sendable (String) -> Void = { reason in
        RotatingDaemonLog.writeFinal("simqd: \(reason); exiting for restart")
        _exit(70)
    }
    /// Asks the daemon for its status over its own socket; false if no answer came in time.
    public var livenessProbe: (@Sendable () -> Bool)?
    /// Monotonic seconds, injectable for tests.
    public var livenessUptime: @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }
    public var livenessLog: @Sendable (String) -> Void = { line in
        FileHandle.standardError.write(Data("simqd: \(line)\n".utf8))
    }
    private let livenessWake = DispatchSemaphore(value: 0)

    private let stateLock = NSLock()
    private var stopped = false
    private var wakePending = false
    private var stopReason: String?
    private var stopCause: String?
    private let wake = DispatchSemaphore(value: 0)
    private let finished = DispatchGroup()

    public init(service: DaemonService, socketPath: String) throws {
        self.service = service
        self.listener = try UnixListener(path: socketPath)
        service.wakeScheduler = { [weak self] in self?.requestTick() }
    }

    public var isStopped: Bool { stateLock.withLock { stopped } }
    /// Why the server stopped (nil for a normal stop).
    public var failure: String? { stateLock.withLock { stopReason } }
    /// Who asked for a normal stop (a signal, a client), if known.
    public var requestedBy: String? { stateLock.withLock { stopCause } }

    /// Starts the accept and tick threads and returns at once.
    public func start() {
        finished.enter()
        Thread.detachNewThread { [self] in
            acceptLoop()
            finished.leave()
        }
        finished.enter()
        Thread.detachNewThread { [self] in
            tickLoop()
            finished.leave()
        }
        finished.enter()
        Thread.detachNewThread { [self] in
            livenessLoop()
            finished.leave()
        }
    }

    private func socketAnswersStatus() -> Bool {
        if let livenessProbe { return livenessProbe() }
        let response = try? SimQueueClient(socketPath: listener.path, timeoutSeconds: livenessTimeoutSeconds)
            .send(Request(id: "simqd-liveness", params: .status))
        if case .result(.status) = response?.body { return true }
        return false
    }

    /// Exits the daemon when it is wedged, and only then.
    ///
    /// A failed probe alone proves little: with the host at many times its CPU capacity
    /// an answer can take longer than the probe waits while every job is running fine.
    /// So two things are measured: how long status has gone unanswered, and how long the
    /// service lock has gone without being acquired by anyone. Both standing still for
    /// `livenessFailureSeconds` is a wedge. Unanswered status with the lock still moving
    /// is an overloaded daemon: it is logged once and left alone until
    /// `livenessStarvedSeconds`, when the socket is as good as gone for clients anyway.
    ///
    /// Time is counted as this thread observes it, capped per round, so a process that
    /// was itself not scheduled (or a host that slept) is never mistaken for a wedge.
    private func livenessLoop() {
        var last = livenessUptime()
        var unanswered = 0.0
        var lockIdle = 0.0
        var lastAcquisitions = service.lockAcquisitions
        var warned = false
        while !isStopped {
            if livenessWake.wait(timeout: .now() + livenessIntervalSeconds) == .success { return }
            if isStopped { return }
            let answered = socketAnswersStatus()
            if isStopped { return }
            let now = livenessUptime()
            let observed = min(max(0, now - last), livenessIntervalSeconds + livenessTimeoutSeconds + 1)
            last = now
            let acquisitions = service.lockAcquisitions
            if acquisitions != lastAcquisitions {
                lastAcquisitions = acquisitions
                lockIdle = 0
            } else {
                lockIdle += observed
            }
            if answered {
                if warned { livenessLog("socket liveness: status answered again after \(Int(unanswered))s") }
                unanswered = 0
                warned = false
                continue
            }
            unanswered += observed
            guard unanswered >= livenessFailureSeconds else { continue }
            if lockIdle >= livenessFailureSeconds {
                livenessFailure(
                    "socket liveness: status unanswered for \(Int(unanswered))s and the service lock idle for "
                        + "\(Int(lockIdle))s; the daemon is wedged ("
                        + (service.lockHolderDescription.map { "service lock held by \($0)" }
                            ?? "service lock free, nobody taking it") + ")")
                return
            }
            if unanswered >= livenessStarvedSeconds {
                livenessFailure(
                    "socket liveness: status unanswered for \(Int(unanswered))s although the daemon is working; "
                        + "the socket is unusable")
                return
            }
            if !warned {
                warned = true
                livenessLog(
                    "socket liveness: status unanswered for \(Int(unanswered))s but the daemon is working "
                        + "(service lock last taken \(Int(lockIdle))s ago); not restarting. The host is likely "
                        + "overloaded.")
            }
        }
    }

    /// Stops accepting, ends the tick loop, and waits for both threads. `reason` marks a
    /// failure (the daemon exits non-zero); `cause` says who asked for a normal stop.
    public func stop(reason: String? = nil, cause: String? = nil) {
        let first: Bool = stateLock.withLock {
            guard !stopped else { return false }
            stopped = true
            stopReason = reason
            stopCause = cause
            return true
        }
        guard first else { return }
        listener.close()
        wake.signal()
        livenessWake.signal()
    }

    /// Blocks until `stop` has been called and both loops have exited.
    public func waitUntilStopped() {
        finished.wait()
        service.waitForBackgroundWork()
    }

    /// Runs a tick soon (after a submit, say) instead of waiting for the interval.
    public func requestTick() {
        stateLock.withLock {
            guard !stopped, !wakePending else { return }
            wakePending = true
            wake.signal()
        }
    }

    private func tickLoop() {
        while !isStopped {
            do {
                try service.tick()
            } catch let error as EngineError where error.stopsDaemon {
                stop(reason: error.description)
                return
            } catch {
                // Everything else is retried by the next tick: a process table or simulator
                // list that could not be read says nothing about the daemon's own state.
                FileHandle.standardError.write(Data("simqd: tick failed: \(error)\n".utf8))
            }
            _ = wake.wait(timeout: .now() + service.nextTickInterval)
            stateLock.withLock { wakePending = false }
        }
    }

    private func acceptLoop() {
        while !isStopped {
            let connection: UnixConnection
            do {
                connection = try listener.accept()
            } catch {
                if isStopped { return }
                continue
            }
            connection.setSendTimeout(0.1)
            guard ingressSlots.wait(timeout: .now()) == .success else {
                _ = send(
                    Response(
                        id: "",
                        body: .error(
                            ProtocolError(.queueFull, "daemon busy: too many incoming requests; retry shortly"))),
                    on: connection)
                connection.close()
                continue
            }
            finished.enter()
            Thread.detachNewThread { [self] in
                defer { ingressSlots.signal(); finished.leave() }
                serve(connection)
            }
        }
    }

    private func send(_ response: Response, on connection: UnixConnection) -> Bool {
        guard let data = try? LineCodec.encode(response) else { return false }
        return (try? connection.write(data)) != nil
    }

    func serve(_ connection: UnixConnection) {
        var handedOff = false
        defer { if !handedOff { connection.close() } }
        connection.setReceiveTimeout(2)
        connection.setSendTimeout(1)
        // Owner-only socket; also refuse a peer running as a different user.
        if let peer = connection.peerUID(), peer != getuid() {
            _ = send(
                Response(id: "", body: .error(ProtocolError(.badRequest, "peer uid \(peer) is not the daemon's user"))),
                on: connection)
            return
        }
        let line: Data
        do {
            guard
                let read = try connection.readLine(
                    maxBytes: LineCodec.maxLineBytes, deadline: Date().timeIntervalSince1970 + 2)
            else { return }
            line = read
        } catch {
            _ = send(Response(id: "", body: .error(ProtocolError(.badRequest, "\(error)"))), on: connection)
            return
        }
        let request: Request
        do {
            request = try LineCodec.decode(Request.self, from: line)
        } catch {
            _ = send(
                Response(id: "", body: .error(ProtocolError(.badRequest, "malformed request: \(error)"))),
                on: connection)
            return
        }
        let slots: DispatchSemaphore
        switch request.params {
        case .wait: slots = waitSlots
        case .status where request.id == "simqd-liveness": slots = healthSlots
        case .status, .submit, .cancel, .jobs: slots = controlSlots
        default: slots = workSlots
        }
        guard slots.wait(timeout: .now()) == .success else {
            _ = send(
                Response(
                    id: request.id,
                    body: .error(ProtocolError(.queueFull, "daemon busy: request limit reached; retry shortly"))),
                on: connection)
            return
        }
        handedOff = true
        finished.enter()
        Thread.detachNewThread { [self] in
            defer { connection.close(); slots.signal(); finished.leave() }
            execute(request, on: connection)
        }
    }

    private func execute(_ request: Request, on connection: UnixConnection) {
        if case .wait(let params) = request.params, request.schemaVersion <= Envelope.currentSchemaVersion {
            streamWait(request, params, on: connection)
            return
        }
        let response = service.handle(request)
        _ = send(response, on: connection)
        if case .stop(let params) = request.params, params.exitDaemon, case .result(.status) = response.body {
            stop(cause: "stop request from a client")
            return
        }
        switch request.params {
        case .submit, .cancel, .bump, .drain, .resume, .leaseAcquire, .leaseRelease, .templateBuild, .templateRemove:
            requestTick()
        default: break
        }
    }

    private func streamWait(_ request: Request, _ params: WaitParams, on connection: UnixConnection) {
        var last: JobInfo?
        while !isStopped {
            let current: JobInfo
            do {
                guard let info = try service.jobInfo(params.jobID) else {
                    _ = send(
                        Response(id: request.id, body: .error(ProtocolError(.notFound, "no job \(params.jobID)"))),
                        on: connection)
                    return
                }
                current = info
            } catch {
                _ = send(
                    Response(id: request.id, body: .error(ProtocolError(.internalError, "\(error)"))), on: connection)
                return
            }
            let done =
                (current.state.isTerminal && current.cleanupPending != true)
                || (params.untilAdmitted && current.state != .queued)
            if done {
                // The final record lists the run directory like `explain` does (artifacts,
                // `artifacts_truncated`, `result_bundles`). Once, here, and outside the
                // service lock: `jobInfo` has already released it; polls stay listing-free.
                _ = send(
                    Response(id: request.id, body: .result(.job(ArtifactListing.attach(to: current)))), on: connection)
                return
            }
            if params.stream, current != last {
                // A failed write means the client left (for example its --wait-timeout).
                guard send(Response(id: request.id, body: .event(current)), on: connection) else { return }
            }
            last = current
            Thread.sleep(forTimeInterval: waitPollSeconds)
        }
        _ = send(
            Response(id: request.id, body: .error(ProtocolError(.internalError, "daemon is shutting down"))),
            on: connection)
    }
}
