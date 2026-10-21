// SPDX-License-Identifier: MIT

import SimQueueCore
import SimQueueEngine
import SimQueueHost
import SimQueueSim
import SimQueueStore

let gib = ByteSize.gibibyte

func healthyHost(availableGiB: UInt64 = 20) -> HostSnapshot {
    HostSnapshot(
        sampledAt: 0,
        totalMemoryBytes: 32 * gib,
        availableMemoryBytes: availableGiB * gib,
        swapUsedBytes: 0,
        memoryPressure: .normal,
        load1: 2,
        load5: 2,
        cpuCount: 10,
        freeDiskBytes: 200 * gib,
        thermalState: .nominal
    )
}

/// A store plus fake world, all driven by one manual clock.
final class Harness {
    let clock = ManualClock(start: 1_800_000_000)
    let probe = SettableResourceProbe(healthyHost())
    let sims = FakeSimBackend()
    let processes = FakeProcessTable()
    let fileSystem = FakeFileSystem()
    let layout = RunDirectoryLayout(root: "/fake/simq")
    let path: String
    var config: SchedulerConfig
    var reliability: ReliabilityConfig
    var timeouts = TimeoutConfig()
    var artifactsRoot: String?

    init(
        path: String = ":memory:", config: SchedulerConfig = SchedulerConfig(),
        reliability: ReliabilityConfig = ReliabilityConfig(), preserveAdmissionPacing: Bool = false
    ) {
        self.path = path
        self.config = config
        // Fake-clock suites isolate allocation/recovery from wall-clock pacing.
        if !preserveAdmissionPacing {
            self.config.maxAdmissionsPerPass = Int.max
            self.config.minAdmissionIntervalSeconds = 0
        }
        self.config.minimumJobMemoryBytes = 0
        self.reliability = reliability
    }

    var environment: EngineEnvironment {
        EngineEnvironment(
            clock: clock, probe: probe, sims: sims, processes: processes, fileSystem: fileSystem, layout: layout,
            artifactsRoot: artifactsRoot)
    }

    func start(store: JobStore) throws -> (Engine, RecoveryReport, ReconcileReport) {
        try Engine.start(
            store: store, environment: environment, config: config, reliability: reliability, timeouts: timeouts,
            ownerID: "test", pid: 1)
    }

    func submit(
        _ store: JobStore,
        exclusive: Bool = false,
        retryable: Bool = true,
        priority: Int = Priority.defaultValue,
        project: String = "app",
        submitter: String = "bot",
        resources: ResourceRequest = ResourceRequest(minSims: 1),
        runTimeout: Double? = nil,
        queueTimeout: Double? = nil
    ) throws -> Job {
        try store.submit(
            JobSubmission(
                project: project, priority: priority, submitter: submitter, resources: resources,
                exclusive: exclusive, retryable: retryable, runTimeoutSeconds: runTimeout,
                queueTimeoutSeconds: queueTimeout),
            now: clock.now()
        ).job
    }
}
