// SPDX-License-Identifier: MIT

import SimQueueCore

let gib = ByteSize.gibibyte
let mib = ByteSize.mebibyte

func makeJob(
    _ id: String,
    seq: Int64,
    priority: Int = Priority.defaultValue,
    exclusive: Bool = false,
    retryable: Bool = false,
    project: String = "app",
    queueTime: Double = 0,
    resources: ResourceRequest = ResourceRequest()
) -> Job {
    Job(
        id: id,
        sequence: seq,
        project: project,
        priority: priority,
        submitter: "bot",
        resources: resources,
        exclusive: exclusive,
        retryable: retryable,
        queueTime: queueTime,
        createdAt: queueTime
    )
}

func makeHost(
    availableGiB: UInt64 = 20,
    pressure: MemoryPressure = .normal,
    load1: Double = 1,
    load5: Double = 1,
    cpuCount: Int = 10,
    freeDiskGiB: UInt64 = 200,
    thermal: ThermalState = .nominal,
    swapUsed: UInt64 = 0
) -> HostSnapshot {
    HostSnapshot(
        sampledAt: 0,
        totalMemoryBytes: 32 * gib,
        availableMemoryBytes: availableGiB * gib,
        swapUsedBytes: swapUsed,
        memoryPressure: pressure,
        load1: load1,
        load5: load5,
        cpuCount: cpuCount,
        freeDiskBytes: freeDiskGiB * gib,
        thermalState: thermal
    )
}

/// One sim request with an explicit per-boot cost so memory math in tests is obvious.
func sims(_ minimum: Int, _ maximum: Int? = nil, perSim: UInt64 = 0, memory: UInt64 = 0) -> ResourceRequest {
    ResourceRequest(minSims: minimum, maxSims: maximum, memoryBytes: memory, memoryBytesPerSim: perSim)
}

/// Config with round numbers: 3 gib reserve, 2 gib per boot.
func testConfig(
    maxRunningSims: Int = 4,
    maxParkedSims: Int = 0,
    maxConcurrentBoots: Int = 1,
    maxConcurrentExclusive: Int = 1,
    maxRunningPerProject: Int = 3,
    drain: InfraDrainPolicy = InfraDrainPolicy(),
    admissionSettleSeconds: Double = 60,
    memoryHoldGraceSeconds: Double = 0
) -> SchedulerConfig {
    var config = SchedulerConfig(
        reserveBytes: 3 * gib,
        maxRunningSims: maxRunningSims,
        maxParkedSims: maxParkedSims,
        maxConcurrentBoots: maxConcurrentBoots,
        maxConcurrentExclusive: maxConcurrentExclusive,
        simBootCostBytes: 2 * gib,
        maxRunningPerProject: maxRunningPerProject,
        drain: drain,
        admissionSettleSeconds: admissionSettleSeconds,
        memoryHoldGraceSeconds: memoryHoldGraceSeconds
    )
    config.maxAdmissionsPerPass = Int.max
    config.minAdmissionIntervalSeconds = 0
    config.minimumJobMemoryBytes = 0
    return config
}

func input(
    queued: [Job],
    active: [Job] = [],
    host: HostSnapshot = makeHost(),
    pool: PoolSnapshot = PoolSnapshot(),
    now: Double = 0,
    swapGrowth: Double = 0,
    control: QueueControl = QueueControl(),
    drain: DrainStatus = .normal,
    loadThrottledPreviously: Bool = false
) -> SchedulerInput {
    SchedulerInput(
        now: now,
        queued: queued,
        active: active,
        host: host,
        swapGrowthBytesPerMinute: swapGrowth,
        pool: pool,
        control: control,
        drain: drain,
        loadThrottledPreviously: loadThrottledPreviously
    )
}

extension SchedulerPlan {
    var admittedIDs: [String] { admissions.map(\.jobID) }

    func reasons(for jobID: String) -> [WaitReason] {
        waiting.first { $0.jobID == jobID }?.reasons ?? []
    }

    func reasonCodes(for jobID: String) -> [String] {
        reasons(for: jobID).map(\.code)
    }
}
