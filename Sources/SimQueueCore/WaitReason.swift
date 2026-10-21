// SPDX-License-Identifier: MIT

/// Why a queued job isn't running yet. Shown by `simq explain` and `simq status`.
/// The capacity-snapshot-with-reasons idea is borrowed from XCSteward.
public enum WaitReason: Sendable, Equatable, Codable {
    case admissionPacing(active: Int, limit: Int)
    case cleanupPending(jobID: String)
    case paused
    case draining(recentInfraFailures: Int)
    case memoryPressure(level: MemoryPressure, stopAt: MemoryPressure)
    case swapGrowing(bytesPerMinute: Double, limitBytesPerMinute: Double)
    case swapHigh(usedBytes: UInt64, maxBytes: UInt64)
    case loadThrottle(load1: Double, load5: Double, clearing: Bool)
    case thermal(state: ThermalState, stopAt: ThermalState)
    case diskLow(freeBytes: UInt64, minBytes: UInt64)
    case projectCap(project: String, running: Int, max: Int)
    case exclusiveSlot(running: Int, max: Int)
    case simCapacity(needed: Int, runningAfter: Int, maxRunning: Int)
    case bootCapacity(bootsNeeded: Int, inProgress: Int, max: Int)
    case poolWarming(needed: Int, ready: Int)
    case loadTooHighForBoot(load1: Double, limit: Double)
    case insufficientMemory(availableBytes: UInt64, neededBytes: UInt64, reserveBytes: UInt64)
    case reservedForHigherPriority(jobID: String)
    /// The request can never be satisfied under the current config (for example more sims
    /// than `max_running_sims`). Never takes a reservation, so it can't block the queue.
    case neverFits(detail: String)

    /// Stable machine-readable code for `--json` output.
    public var code: String {
        switch self {
        case .admissionPacing: return "admission_pacing"
        case .cleanupPending: return "cleanup_pending"
        case .paused: return "paused"
        case .draining: return "draining"
        case .memoryPressure: return "memory_pressure"
        case .swapGrowing: return "swap_growing"
        case .swapHigh: return "swap_high"
        case .loadThrottle: return "load_throttle"
        case .thermal: return "thermal"
        case .diskLow: return "disk_low"
        case .projectCap: return "project_cap"
        case .exclusiveSlot: return "exclusive_slot"
        case .simCapacity: return "sim_capacity"
        case .bootCapacity: return "boot_capacity"
        case .poolWarming: return "pool_warming"
        case .loadTooHighForBoot: return "load_too_high_for_boot"
        case .insufficientMemory: return "insufficient_memory"
        case .reservedForHigherPriority: return "reserved_for_higher_priority"
        case .neverFits: return "never_fits"
        }
    }

    /// One-line human explanation.
    public var summary: String {
        switch self {
        case .admissionPacing(let active, let limit):
            return
                "gradual admission: \(active)/\(limit) active commands; at most one new command per second, rechecks automatically"
        case .cleanupPending(let jobID):
            return
                "previous command processes for \(jobID) still hold resources; cleanup must finish before retry (simq doctor)"
        case .paused:
            return "queue is paused (simq resume)"
        case .draining(let count):
            return "draining after \(count) recent infra failures (simq resume to clear)"
        case .memoryPressure(let level, let stopAt):
            return "memory pressure is \(level.rawValue) (stops at \(stopAt.rawValue))"
        case .swapGrowing(let rate, let limit):
            return "swap growing \(Self.mib(rate))/min (limit \(Self.mib(limit))/min)"
        case .swapHigh(let used, let maximum):
            return "swap used \(Self.gib(used)) is above \(Self.gib(maximum))"
        case .loadThrottle(let load1, let load5, let clearing):
            return clearing
                ? "host load has not reached recovery thresholds (load1 \(Self.fixed(load1)), load5 \(Self.fixed(load5)))"
                : "host load too high (load1 \(Self.fixed(load1)), load5 \(Self.fixed(load5)))"
        case .thermal(let state, let stopAt):
            return "thermal state is \(state.rawValue) (stops at \(stopAt.rawValue))"
        case .diskLow(let free, let minimum):
            return "free disk \(Self.gib(free)) is below \(Self.gib(minimum))"
        case .projectCap(let project, let running, let maximum):
            return "project \(project) already has \(running) of \(maximum) running jobs"
        case .exclusiveSlot(let running, let maximum):
            return "exclusive slot busy (\(running) of \(maximum))"
        case .simCapacity(let needed, let runningAfter, let maximum):
            return "needs \(needed) sims; would make \(runningAfter) running sims (max \(maximum))"
        case .poolWarming(let needed, let ready):
            return "waiting for the simulator pool: needs \(needed), \(ready) ready"
        case .bootCapacity(let needed, let inProgress, let maximum):
            return "needs \(needed) new boot(s); \(inProgress) boot(s) pending, at most \(maximum) at a time"
        case .loadTooHighForBoot(let load, let limit):
            return "load1 \(Self.fixed(load)) is above the boot limit \(Self.fixed(limit))"
        case .insufficientMemory(let available, let needed, let reserve):
            return
                "needs \(Self.gib(needed)) but only \(Self.gib(available)) available with \(Self.gib(reserve)) reserve"
        case .reservedForHigherPriority(let jobID):
            return "capacity is reserved for higher-priority job \(jobID)"
        case .neverFits(let detail):
            return "can never run under the current config: \(detail)"
        }
    }

    /// Reasons that don't justify holding a reservation for the job.
    public var isSelfLimited: Bool {
        switch self {
        case .cleanupPending, .projectCap, .exclusiveSlot, .neverFits: return true
        default: return false
        }
    }

    private static func mib(_ bytes: Double) -> String {
        fixed(bytes / Double(ByteSize.mebibyte)) + " MiB"
    }

    private static func gib(_ bytes: UInt64) -> String {
        fixed(Double(bytes) / Double(ByteSize.gibibyte)) + " GiB"
    }

    private static func fixed(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return String(describing: rounded)
    }
}
