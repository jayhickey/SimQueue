// SPDX-License-Identifier: MIT

/// macOS memory pressure level, ordered from best to worst.
public enum MemoryPressure: String, Sendable, Codable, Comparable, CaseIterable {
    case normal
    case warn
    case critical

    private var rank: Int {
        switch self {
        case .normal: return 0
        case .warn: return 1
        case .critical: return 2
        }
    }

    public static func < (lhs: MemoryPressure, rhs: MemoryPressure) -> Bool { lhs.rank < rhs.rank }

    /// Maps `sysctl kern.memorystatus_vm_pressure_level` (1 normal, 2 warn, 4 critical).
    /// Unknown values map to the worse neighbor, so a surprise never loosens admission.
    public init(kernelLevel: Int) {
        switch kernelLevel {
        case ...1: self = .normal
        case 2: self = .warn
        default: self = .critical
        }
    }
}

/// Thermal state, ordered from best to worst (matches ProcessInfo.ThermalState).
public enum ThermalState: String, Sendable, Codable, Comparable, CaseIterable {
    case nominal
    case fair
    case serious
    case critical

    private var rank: Int {
        switch self {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        }
    }

    public static func < (lhs: ThermalState, rhs: ThermalState) -> Bool { lhs.rank < rhs.rank }
}

/// One sample of host resources (spec section 5c). Produced by a `ResourceProbe`.
public struct HostSnapshot: Sendable, Codable, Equatable {
    public var cpuUsagePercent: Double?
    public var sampledAt: Double
    public var totalMemoryBytes: UInt64
    /// Free + inactive + purgeable memory.
    public var availableMemoryBytes: UInt64
    public var swapUsedBytes: UInt64
    public var memoryPressure: MemoryPressure
    public var load1: Double
    public var load5: Double
    public var cpuCount: Int
    public var freeDiskBytes: UInt64
    public var thermalState: ThermalState

    public init(
        sampledAt: Double,
        totalMemoryBytes: UInt64,
        availableMemoryBytes: UInt64,
        swapUsedBytes: UInt64 = 0,
        memoryPressure: MemoryPressure = .normal,
        load1: Double = 0,
        load5: Double = 0,
        cpuCount: Int,
        freeDiskBytes: UInt64,
        thermalState: ThermalState = .nominal, cpuUsagePercent: Double? = nil
    ) {
        self.cpuUsagePercent = cpuUsagePercent
        self.sampledAt = sampledAt
        self.totalMemoryBytes = totalMemoryBytes
        self.availableMemoryBytes = availableMemoryBytes
        self.swapUsedBytes = swapUsedBytes
        self.memoryPressure = memoryPressure
        self.load1 = load1
        self.load5 = load5
        self.cpuCount = cpuCount
        self.freeDiskBytes = freeDiskBytes
        self.thermalState = thermalState
    }
}

/// One swap reading.
public struct SwapSample: Sendable, Equatable, Codable {
    public var at: Double
    public var swapUsedBytes: UInt64

    public init(at: Double, swapUsedBytes: UInt64) {
        self.at = at
        self.swapUsedBytes = swapUsedBytes
    }
}

/// Tracks swap usage over a sliding window and reports growth in bytes per minute.
public struct SwapGrowthTracker: Sendable, Equatable {
    public var windowSeconds: Double
    public private(set) var samples: [SwapSample] = []

    public init(windowSeconds: Double = 60) {
        self.windowSeconds = windowSeconds
    }

    public mutating func add(at time: Double, swapUsedBytes: UInt64) {
        samples.append(SwapSample(at: time, swapUsedBytes: swapUsedBytes))
        samples.removeAll { $0.at < time - windowSeconds }
    }

    /// Growth between the oldest and newest sample in the window, scaled to one minute.
    /// Returns 0 with fewer than two samples or when swap shrank.
    public var growthBytesPerMinute: Double {
        guard let first = samples.first, let last = samples.last, last.at > first.at else {
            return 0
        }
        let delta = Double(last.swapUsedBytes) - Double(first.swapUsedBytes)
        guard delta > 0 else {
            return 0
        }
        return delta / (last.at - first.at) * 60
    }
}

/// Default load throttle: load5 > 30, or load1 > 30 with load5 > 15. A recovered
/// load1 <= 20 suppresses those historical gates; otherwise a prior hold clears
/// when the entry rules stop and load5 <= 20. The optional absolute load5 limit
/// always takes precedence. Host sizing scales the default thresholds by cores.
public struct LoadThrottlePolicy: Sendable, Equatable {
    public var load5Above: Double
    public var load1Above: Double
    public var load5WithLoad1Above: Double
    /// Historical hysteresis threshold, also used for short-average recovery.
    public var clearBelowLoad5: Double
    /// Optional stricter admission limit (config `max_load5`; nil = off, the default): hold
    /// new jobs while load5 is above it.
    public var maxLoad5: Double?
    /// Once held by `maxLoad5`, admit again only when load5 is at or below this (config
    /// `resume_below_load5`; default 80% of `maxLoad5`).
    public var resumeBelowLoad5: Double?

    public init(
        load5Above: Double = 30, load1Above: Double = 30, load5WithLoad1Above: Double = 15,
        clearBelowLoad5: Double = 20,
        maxLoad5: Double? = nil, resumeBelowLoad5: Double? = nil
    ) {
        self.load5Above = load5Above
        self.load1Above = load1Above
        self.load5WithLoad1Above = load5WithLoad1Above
        self.clearBelowLoad5 = clearBelowLoad5
        self.maxLoad5 = maxLoad5
        self.resumeBelowLoad5 = resumeBelowLoad5
    }

    /// The explicit `maxLoad5`/resume policy shares the persisted hysteresis state
    /// and runs first. Short-average recovery suppresses the default rules on both
    /// new and held decisions, so lingering load5 cannot re-trigger every other tick.
    public func isThrottled(load1: Double, load5: Double, wasThrottled: Bool) -> Bool {
        if let maxLoad5 {
            if load5 > maxLoad5 { return true }
            if wasThrottled, load5 > (resumeBelowLoad5 ?? maxLoad5 * 0.8) { return true }
        }
        if load1 <= clearBelowLoad5 { return false }
        if load5 > load5Above {
            return true
        }
        if load1 > load1Above, load5 > load5WithLoad1Above {
            return true
        }
        return wasThrottled && load5 > clearBelowLoad5
    }
}
