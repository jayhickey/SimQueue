// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueDaemon
import SimQueueEngine
import SimQueueHost
import SimQueueIPC
import SimQueueProtocol
import SimQueueSim
import SimQueueStore
import XCTest

/// A real daemon on a real Unix socket in a short temp dir, with fakes behind it and a
/// fast tick. Runs on Linux CI.
final class TestDaemon: @unchecked Sendable {
    let paths: SimQueuePaths
    let processes = FakeProcessTable()
    let sims = FakeSimBackend(pool: PoolSnapshot(idleRunning: 4))
    let store: JobStore
    let engine: Engine
    let service: DaemonService
    let server: DaemonServer
    let lock: InstanceLock
    /// The test's own connection to the state file (never share the daemon's).
    let side: JobStore

    /// Set when the daemon runs real commands (`realProcesses: true`).
    private(set) var processExecutor: ProcessExecutor?

    init(
        config: DaemonConfig = DaemonConfig(), stateDir: String? = nil, realProcesses: Bool = false,
        processTable: (any ProcessTable)? = nil,
        simsOverride: (any SimBackend)? = nil, processesOverride: (any ProcessTable)? = nil,
        executorOverride: (any JobExecutor)? = nil, tickIntervalOverride: Double? = nil,
        fileSystemOverride: (any FileSystem)? = nil
    ) throws {
        let dir = stateDir ?? testScratchRoot() + "/sqd-" + UUID().uuidString.prefix(8)
        paths = SimQueuePaths(stateDir: dir)
        var config = config
        // Most socket tests use a 20ms loop; production pacing has dedicated coverage.
        config.scheduler.minAdmissionIntervalSeconds = 0
        config.scheduler.maxAdmissionsPerPass = Int.max
        config.tickIntervalSeconds = tickIntervalOverride ?? min(config.tickIntervalSeconds, 0.02)
        lock = try InstanceLock(path: paths.lockPath)
        store = try JobStore(
            path: paths.databasePath, maxInfraRetries: config.defaultMaxRetries,
            maxQueuedPerSubmitterPerProject: config.maxQueuedPerSubmitterPerProject)
        store.maxQueuedTotal = config.maxQueuedTotal
        let environment = EngineEnvironment(
            clock: SystemClock(),
            probe: FakeResourceProbe(fixed: healthyFakeHost),
            sims: simsOverride ?? sims,
            processes: processesOverride ?? (realProcesses ? (processTable ?? SystemProcessTable()) : processes),
            fileSystem: fileSystemOverride ?? FakeFileSystem(),
            layout: RunDirectoryLayout(root: paths.runsRoot),
            processGraceSeconds: config.timeouts.killGraceSeconds,
            artifactsRoot: paths.jobsRoot
        )
        (engine, _, _) = try Engine.start(
            store: store, environment: environment, config: config.scheduler, reliability: config.reliability,
            timeouts: config.timeouts, watchdog: config.watchdog, ownerID: "test", pid: 1)
        let info = DaemonInfo(
            version: SimQueueVersion.current, pid: 1, epoch: engine.epoch, backend: "fake", startedAt: 0,
            statePath: paths.databasePath, socketPath: paths.socketPath,
            cleanupMode: config.reliability.cleanupMode.rawValue)
        let executor: any JobExecutor
        if let executorOverride {
            executor = executorOverride
        } else if realProcesses {
            let real = ProcessExecutor(
                artifacts: JobArtifacts(root: paths.jobsRoot), processes: environment.processes,
                baseEnvironment: ["PATH": "/usr/bin:/bin"], graceSeconds: config.timeouts.killGraceSeconds)
            processExecutor = real
            executor = real
        } else {
            executor = FakeExecutor(processes: processes)
        }
        service = DaemonService(
            engine: engine, config: config, info: info, executor: executor,
            artifacts: JobArtifacts(root: paths.jobsRoot), log: { _ in })
        server = try DaemonServer(service: service, socketPath: paths.socketPath)
        server.waitPollSeconds = 0.01
        side = try JobStore(path: paths.databasePath)
        server.start()
    }

    var client: SimQueueClient { SimQueueClient(socketPath: paths.socketPath, timeoutSeconds: 10) }

    func stop() {
        server.stop()
        server.waitUntilStopped()
        lock.release()
    }

    func destroy() {
        stop()
        try? FileManager.default.removeItem(atPath: paths.stateDir)
    }

    // MARK: - Request helpers

    func send(_ params: RequestParams, deadline: Double? = nil) throws -> Response {
        try XCTUnwrap(client.send(Request(params: params), deadline: deadline))
    }

    func result(_ params: RequestParams) throws -> ResultPayload {
        let response = try send(params)
        guard case .result(let payload) = response.body else {
            throw TestFailure("expected a result, got \(response.body)")
        }
        return payload
    }

    func protocolError(_ params: RequestParams) throws -> ProtocolError {
        let response = try send(params)
        guard case .error(let error) = response.body else {
            throw TestFailure("expected an error, got \(response.body)")
        }
        return error
    }

    func submit(_ params: SubmitParams) throws -> SubmitResponse {
        guard case .submit(let response) = try result(.submit(params)) else { throw TestFailure("not a submit result") }
        return response
    }

    func job(_ id: String) throws -> JobInfo {
        guard case .job(let job) = try result(.explain(JobRef(jobID: id))) else { throw TestFailure("not a job") }
        return job
    }

    func wait(_ id: String, stream: Bool = false, events: ((JobInfo) -> Void)? = nil) throws -> JobInfo {
        let response = try XCTUnwrap(
            SimQueueClient(socketPath: paths.socketPath, timeoutSeconds: 0).send(
                Request(params: .wait(WaitParams(jobID: id, stream: stream))),
                deadline: Date().timeIntervalSince1970 + 30
            ) { event in
                events?(event)
                return true
            })
        guard case .result(.job(let job)) = response.body else { throw TestFailure("wait failed: \(response.body)") }
        return job
    }
}

let healthyFakeHost = HostSnapshot(
    sampledAt: 0,
    totalMemoryBytes: 32 * ByteSize.gibibyte,
    availableMemoryBytes: 16 * ByteSize.gibibyte,
    cpuCount: 8,
    freeDiskBytes: 200 * ByteSize.gibibyte
)

/// The real process table, except that a group signalled with SIGTERM keeps looking live
/// for the next `lagPolls` liveness checks, the way a dying process can on macOS. Lets
/// tests hit "the leader was reaped before the timeout path saw the group gone".
final class LaggingProcessTable: ProcessTable, @unchecked Sendable {
    private let base = SystemProcessTable()
    private let lock = NSLock()
    private var lagging: [Int32: Int] = [:]
    let lagPolls: Int

    init(lagPolls: Int) {
        self.lagPolls = lagPolls
    }

    func liveProcessGroups() throws -> Set<Int32> {
        var live = try base.liveProcessGroups()
        lock.lock()
        defer { lock.unlock() }
        for (pgid, remaining) in lagging where remaining > 0 {
            live.insert(pgid)
            lagging[pgid] = remaining - 1
        }
        return live
    }

    func signalGroup(_ pgid: Int32, _ signal: ProcessSignal) throws {
        try base.signalGroup(pgid, signal)
        if signal == .term {
            lock.lock()
            lagging[pgid] = lagPolls
            lock.unlock()
        }
    }

    func terminateGroup(_ pgid: Int32, graceSeconds: Double) throws {
        try base.terminateGroup(pgid, graceSeconds: graceSeconds)
    }

    func processIdentity(_ pid: Int32) throws -> String? {
        try base.processIdentity(pid)
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func params(
    project: String = "app", priority: Int? = nil, priorityName: String? = nil, submitter: String = "dev",
    dedupeKey: String? = nil, timeout: Double? = nil, queueTimeout: Double? = nil, fake: String? = nil,
    kind: String? = nil, exclusive: Bool? = nil, retryable: Bool? = nil, maxRetries: Int? = nil
) -> SubmitParams {
    SubmitParams(
        project: project, kind: kind, priority: priority, priorityName: priorityName, submitter: submitter,
        dedupeKey: dedupeKey, exclusive: exclusive, retryable: retryable, maxRetries: maxRetries,
        runTimeoutSeconds: timeout, queueTimeoutSeconds: queueTimeout,
        payloadJSON: fake.map { "{\"fake\": \($0)}" })
}

/// Where tests put state dirs (which hold a Unix socket): `$SIMQ_TEST_TMPDIR` when set
/// (CI points it inside the runner's work dir), else `/tmp`. Socket paths must stay
/// under 104 bytes, so a root longer than 78 falls back to `/tmp` (CI checks the length).
func testScratchRoot() -> String {
    if let root = ProcessInfo.processInfo.environment["SIMQ_TEST_TMPDIR"], !root.isEmpty, root.utf8.count <= 78 {
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }
    return "/tmp"
}
