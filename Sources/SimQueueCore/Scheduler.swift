// SPDX-License-Identifier: MIT

/// Everything one scheduling pass looks at. Built fresh each tick.
public struct SchedulerInput: Sendable {
    public var now: Double
    public var queued: [Job]
    /// Admitted or running jobs (they hold exclusive slots and project slots).
    public var active: [Job]
    public var host: HostSnapshot
    public var swapGrowthBytesPerMinute: Double
    public var pool: PoolSnapshot
    public var control: QueueControl
    public var drain: DrainStatus
    /// The previous pass's load-throttle decision (for hysteresis).
    public var loadThrottledPreviously: Bool
    /// False when a separate pool manager owns creation and booting. Counts remain real.
    public var allowNewBoots: Bool
    public var lastAdmissionAt: Double?
    public var cleanupJobIDs: Set<String>

    public init(
        now: Double,
        queued: [Job],
        active: [Job],
        host: HostSnapshot,
        swapGrowthBytesPerMinute: Double = 0,
        pool: PoolSnapshot,
        control: QueueControl = QueueControl(),
        drain: DrainStatus = .normal,
        loadThrottledPreviously: Bool = false,
        allowNewBoots: Bool = true,
        lastAdmissionAt: Double? = nil,
        cleanupJobIDs: Set<String> = []
    ) {
        self.now = now
        self.queued = queued
        self.active = active
        self.host = host
        self.swapGrowthBytesPerMinute = swapGrowthBytesPerMinute
        self.pool = pool
        self.control = control
        self.drain = drain
        self.loadThrottledPreviously = loadThrottledPreviously
        self.allowNewBoots = allowNewBoots
        self.lastAdmissionAt = lastAdmissionAt
        self.cleanupJobIDs = cleanupJobIDs
    }
}

/// A decision to admit one job, with where its simulators come from.
public struct Admission: Sendable, Equatable, Codable {
    public var jobID: String
    public var grantedSims: Int
    public var fromIdleRunning: Int
    public var fromParked: Int
    public var newBoots: Int
    /// Memory the pass charged for this admission.
    public var chargedMemoryBytes: UInt64

    public init(
        jobID: String,
        grantedSims: Int,
        fromIdleRunning: Int,
        fromParked: Int,
        newBoots: Int,
        chargedMemoryBytes: UInt64
    ) {
        self.jobID = jobID
        self.grantedSims = grantedSims
        self.fromIdleRunning = fromIdleRunning
        self.fromParked = fromParked
        self.newBoots = newBoots
        self.chargedMemoryBytes = chargedMemoryBytes
    }
}

/// Where a queued job stands and why it's waiting.
public struct QueueExplanation: Sendable, Equatable, Codable {
    public var jobID: String
    /// 1-based position in dispatch order.
    public var position: Int
    public var effectiveScore: Double
    public var reasons: [WaitReason]

    public init(jobID: String, position: Int, effectiveScore: Double, reasons: [WaitReason]) {
        self.jobID = jobID
        self.position = position
        self.effectiveScore = effectiveScore
        self.reasons = reasons
    }
}

/// Result of one pass.
public struct SchedulerPlan: Sendable, Equatable {
    public var admissions: [Admission]
    public var waiting: [QueueExplanation]
    /// The highest-ranked job that didn't fit and now holds a reservation, if any.
    public var reservedFor: String?
    /// How many more ready sims the reserved job needs; a pool manager can warm them.
    public var warmupHint: Int
    /// This pass's load-throttle decision; feed it back as `loadThrottledPreviously`.
    public var loadThrottled: Bool

    public init(
        admissions: [Admission], waiting: [QueueExplanation], reservedFor: String?, warmupHint: Int, loadThrottled: Bool
    ) {
        self.admissions = admissions
        self.waiting = waiting
        self.reservedFor = reservedFor
        self.warmupHint = warmupHint
        self.loadThrottled = loadThrottled
    }
}

/// Admission control (spec section 5d). Pure: same input, same plan.
public struct Scheduler: Sendable {
    public var config: SchedulerConfig

    public init(config: SchedulerConfig = SchedulerConfig()) {
        self.config = config
    }

    /// Host-wide gates that stop all admissions, in a stable order.
    public func globalWaitReasons(_ input: SchedulerInput) -> [WaitReason] {
        var reasons: [WaitReason] = []
        if input.control.paused {
            reasons.append(.paused)
        }
        if case .draining(let count) = input.drain {
            reasons.append(.draining(recentInfraFailures: count))
        }
        let host = input.host
        if config.loadThrottle.isThrottled(
            load1: host.load1, load5: host.load5, wasThrottled: input.loadThrottledPreviously)
        {
            let clearing = !config.loadThrottle.isThrottled(load1: host.load1, load5: host.load5, wasThrottled: false)
            reasons.append(.loadThrottle(load1: host.load1, load5: host.load5, clearing: clearing))
        }
        if input.host.memoryPressure >= config.pressureStop {
            reasons.append(.memoryPressure(level: input.host.memoryPressure, stopAt: config.pressureStop))
        }
        if input.swapGrowthBytesPerMinute > config.swapGrowthLimitBytesPerMinute {
            reasons.append(
                .swapGrowing(
                    bytesPerMinute: input.swapGrowthBytesPerMinute,
                    limitBytesPerMinute: config.swapGrowthLimitBytesPerMinute
                )
            )
        }
        if input.host.thermalState >= config.thermalStop {
            reasons.append(.thermal(state: input.host.thermalState, stopAt: config.thermalStop))
        }
        if input.host.freeDiskBytes < config.minFreeDiskBytes {
            reasons.append(.diskLow(freeBytes: input.host.freeDiskBytes, minBytes: config.minFreeDiskBytes))
        }
        return reasons
    }

    public func plan(_ input: SchedulerInput) -> SchedulerPlan {
        let ordered = config.priority.order(input.queued, now: input.now)
        var state = CapacityState(
            input: input, settleSeconds: config.admissionSettleSeconds, minimumMemory: config.minimumJobMemoryBytes)
        var admissions: [Admission] = []
        var waiting: [QueueExplanation] = []
        var reservedFor: String?
        var warmupHint = 0
        let global = globalWaitReasons(input)

        for (index, job) in ordered.enumerated() {
            let score = config.priority.effectiveScore(of: job, now: input.now)
            func wait(_ reasons: [WaitReason]) {
                waiting.append(
                    QueueExplanation(jobID: job.id, position: index + 1, effectiveScore: score, reasons: reasons))
            }

            if !global.isEmpty {
                wait(global)
                continue
            }

            if input.cleanupJobIDs.contains(job.id) {
                wait([.cleanupPending(jobID: job.id)])
                continue
            }
            let minimumMemory = job.resources.memoryCost(
                sims: job.resources.minSims, minimum: config.minimumJobMemoryBytes)
            let maximumHeadroom = input.host.totalMemoryBytes - min(input.host.totalMemoryBytes, config.reserveBytes)
            if minimumMemory > maximumHeadroom {
                wait([
                    .neverFits(
                        detail:
                            "minimum memory hint exceeds total host RAM minus the configured reserve; lower the hint or move this job to a larger Mac"
                    )
                ])
                continue
            }

            let concurrent = input.active.count + admissions.count
            let latest = max(
                input.lastAdmissionAt ?? -.infinity, input.active.compactMap(\.admittedAt).max() ?? -.infinity)
            let recent = input.now - latest < config.minAdmissionIntervalSeconds
            if concurrent >= max(1, input.host.cpuCount) || admissions.count >= config.maxAdmissionsPerPass || recent {
                wait([
                    .admissionPacing(active: concurrent, limit: max(1, input.host.cpuCount))
                ])
                continue
            }
            let projectRunning = state.runningByProject[job.project, default: 0]
            if config.maxRunningPerProject > 0, projectRunning >= config.maxRunningPerProject {
                wait([.projectCap(project: job.project, running: projectRunning, max: config.maxRunningPerProject)])
                continue
            }

            switch allocate(job, state: state, cpuCount: input.host.cpuCount, load1: input.host.load1) {
            case .success(let allocation):
                state.apply(allocation, job: job)
                admissions.append(
                    Admission(
                        jobID: job.id,
                        grantedSims: allocation.sims,
                        fromIdleRunning: allocation.fromIdle,
                        fromParked: allocation.fromParked,
                        newBoots: allocation.boots,
                        chargedMemoryBytes: allocation.memory
                    )
                )
            case .failure(let failure):
                wait(failure.reasons)
                if reservedFor == nil, !failure.reasons.allSatisfy(\.isSelfLimited) {
                    reservedFor = job.id
                    let ready = state.idleRunning + state.idleParked
                    warmupHint = max(0, job.resources.minSims - ready)
                    // Reserve the waiter's real memory and simulator needs. Builds can use
                    // the remainder; a memory-bound waiter retains headroom until it fits.
                    let memory = job.resources.memoryCost(
                        sims: job.resources.minSims,
                        minimum: config.minimumJobMemoryBytes, boots: warmupHint, bootCost: config.simBootCostBytes)
                    let free =
                        state.availableMemory > config.reserveBytes ? state.availableMemory - config.reserveBytes : 0
                    state.availableMemory -= min(memory, free)
                    let reservedIdle = min(state.idleRunning, job.resources.minSims)
                    state.idleRunning -= reservedIdle
                    let remaining = max(0, job.resources.minSims - reservedIdle)
                    state.idleParked -= min(state.idleParked, remaining)
                    state.reservedRunningSlots += remaining
                }
            }
        }

        let loadThrottled = config.loadThrottle.isThrottled(
            load1: input.host.load1,
            load5: input.host.load5,
            wasThrottled: input.loadThrottledPreviously
        )
        return SchedulerPlan(
            admissions: admissions,
            waiting: waiting,
            reservedFor: reservedFor,
            warmupHint: warmupHint,
            loadThrottled: loadThrottled
        )
    }

    // MARK: - Allocation

    struct Allocation {
        var sims: Int
        var fromIdle: Int
        var fromParked: Int
        var boots: Int
        var memory: UInt64
    }

    struct AllocationFailure: Error {
        var reasons: [WaitReason]
    }

    /// Grants the largest sim count in the job's range that fits. On failure, reports the
    /// reasons for the minimum count (the most permissive request).
    func allocate(_ job: Job, state: CapacityState, cpuCount: Int, load1: Double) -> Result<
        Allocation, AllocationFailure
    > {
        if job.resources.minSims > config.maxRunningSims {
            return .failure(
                AllocationFailure(reasons: [
                    .neverFits(
                        detail: "needs \(job.resources.minSims) sims; max_running_sims is \(config.maxRunningSims)")
                ])
            )
        }
        if job.exclusive, state.exclusiveRunning >= config.maxConcurrentExclusive {
            return .failure(
                AllocationFailure(reasons: [
                    .exclusiveSlot(running: state.exclusiveRunning, max: config.maxConcurrentExclusive)
                ])
            )
        }
        var minimumFailure: [WaitReason] = []
        for count in stride(
            from: min(job.resources.maxSims, config.maxRunningSims), through: job.resources.minSims, by: -1)
        {
            let attempt = tryAllocate(job, sims: count, state: state, cpuCount: cpuCount, load1: load1)
            switch attempt {
            case .success:
                return attempt
            case .failure(let failure):
                if count == job.resources.minSims {
                    minimumFailure = failure.reasons
                }
            }
        }
        return .failure(AllocationFailure(reasons: minimumFailure))
    }

    func tryAllocate(_ job: Job, sims: Int, state: CapacityState, cpuCount: Int, load1: Double) -> Result<
        Allocation, AllocationFailure
    > {
        var reasons: [WaitReason] = []
        let fromIdle = min(sims, state.idleRunning)
        let fromParked = min(sims - fromIdle, state.idleParked)
        let boots = sims - fromIdle - fromParked
        let runningAfter = state.runningTotal + fromParked + boots
        if sims > 0 && runningAfter + state.reservedRunningSlots > config.maxRunningSims {
            reasons.append(
                .simCapacity(
                    needed: sims, runningAfter: runningAfter + state.reservedRunningSlots,
                    maxRunning: config.maxRunningSims))
        }
        if boots > 0 && !state.allowNewBoots {
            reasons.append(.poolWarming(needed: sims, ready: state.idleRunning))
        }
        if boots > 0 && state.allowNewBoots {
            // Boots run one after another (at most `maxConcurrentBoots` at a time), so a
            // job may be admitted whenever a boot slot is free; its remaining boots queue
            // behind it and keep the slots busy until done. Requiring every boot to start
            // at once would make any job needing more boots than slots unschedulable.
            if state.bootsInProgress >= config.maxConcurrentBoots {
                reasons.append(
                    .bootCapacity(bootsNeeded: boots, inProgress: state.bootsInProgress, max: config.maxConcurrentBoots)
                )
            }
            let limit = config.bootLoadLimit(cpuCount: cpuCount)
            if load1 > limit {
                reasons.append(.loadTooHighForBoot(load1: load1, limit: limit))
            }
        }
        let needed = job.resources.memoryCost(
            sims: sims, minimum: config.minimumJobMemoryBytes,
            boots: boots, bootCost: config.simBootCostBytes)
        let available = state.availableMemory
        if available < config.reserveBytes || available - config.reserveBytes < needed {
            reasons.append(
                .insufficientMemory(availableBytes: available, neededBytes: needed, reserveBytes: config.reserveBytes))
        }
        if !reasons.isEmpty {
            return .failure(AllocationFailure(reasons: reasons))
        }
        return .success(
            Allocation(sims: sims, fromIdle: fromIdle, fromParked: fromParked, boots: boots, memory: needed))
    }
}

/// Capacity left during one pass; each admission draws it down.
struct CapacityState {
    var availableMemory: UInt64
    var allowNewBoots: Bool
    var idleRunning: Int
    var idleParked: Int
    var runningTotal: Int
    var reservedRunningSlots: Int = 0
    var bootsInProgress: Int
    var exclusiveRunning: Int
    var runningByProject: [String: Int]

    /// Starts from the probe and pool snapshots, then corrects for lag: sims granted to
    /// active jobs that the pool doesn't yet show as busy are taken from idle, then parked,
    /// then counted as pending boots; memory for jobs admitted within the settle window is
    /// charged again, because the host probe may not reflect it yet. Both corrections only
    /// make the pass more conservative, never less.
    init(input: SchedulerInput, settleSeconds: Double = 0, minimumMemory: UInt64 = 512 * ByteSize.mebibyte) {
        availableMemory = input.host.availableMemoryBytes
        allowNewBoots = input.allowNewBoots
        idleRunning = input.pool.idleRunning
        idleParked = input.pool.idleParked
        runningTotal = input.pool.runningTotal
        bootsInProgress = input.pool.bootsInProgress

        let committed = input.active.reduce(0) { $0 + $1.grantedSims }
        var unattached = max(0, committed - input.pool.busyRunning)
        let fromIdle = min(unattached, idleRunning)
        idleRunning -= fromIdle
        unattached -= fromIdle
        let fromParked = min(unattached, idleParked)
        idleParked -= fromParked
        unattached -= fromParked
        runningTotal += fromParked + unattached
        bootsInProgress += unattached

        for job in input.active {
            guard let admittedAt = job.admittedAt, input.now - admittedAt < settleSeconds else {
                continue
            }
            let charge = job.resources.memoryCost(sims: job.grantedSims, minimum: minimumMemory)
            availableMemory -= min(availableMemory, charge)
        }
        exclusiveRunning = input.active.filter(\.exclusive).count
        runningByProject = Dictionary(grouping: input.active, by: \.project).mapValues(\.count)
    }

    mutating func apply(_ allocation: Scheduler.Allocation, job: Job) {
        availableMemory -= min(availableMemory, allocation.memory)
        idleRunning -= allocation.fromIdle
        idleParked -= allocation.fromParked
        runningTotal += allocation.fromParked + allocation.boots
        bootsInProgress += allocation.boots
        if job.exclusive {
            exclusiveRunning += 1
        }
        runningByProject[job.project, default: 0] += 1
    }
}
