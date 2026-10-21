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

    private let stateLock = NSLock()
    private var stopped = false
    private var wakePending = false
    private var stopReason: String?
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
    }

    /// Stops accepting, ends the tick loop, and waits for both threads.
    public func stop(reason: String? = nil) {
        let first: Bool = stateLock.withLock {
            guard !stopped else { return false }
            stopped = true
            stopReason = reason
            return true
        }
        guard first else { return }
        listener.close()
        wake.signal()
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
            } catch let error as EngineError {
                stop(reason: error.description)
                return
            } catch {
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
            DispatchQueue.global().async { [self] in
                serve(connection)
            }
        }
    }

    private func send(_ response: Response, on connection: UnixConnection) -> Bool {
        guard let data = try? LineCodec.encode(response) else { return false }
        return (try? connection.write(data)) != nil
    }

    func serve(_ connection: UnixConnection) {
        defer { connection.close() }
        connection.setReceiveTimeout(10)
        // Owner-only socket; also refuse a peer running as a different user.
        if let peer = connection.peerUID(), peer != getuid() {
            _ = send(
                Response(id: "", body: .error(ProtocolError(.badRequest, "peer uid \(peer) is not the daemon's user"))),
                on: connection)
            return
        }
        let line: Data
        do {
            guard let read = try connection.readLine(maxBytes: LineCodec.maxLineBytes) else { return }
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
        if case .wait(let params) = request.params, request.schemaVersion <= Envelope.currentSchemaVersion {
            streamWait(request, params, on: connection)
            return
        }
        let response = service.handle(request)
        _ = send(response, on: connection)
        if case .stop(let params) = request.params, params.exitDaemon, case .result(.status) = response.body {
            stop()
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
