// SPDX-License-Identifier: MIT

/// Byte helpers so config reads clearly.
public enum ByteSize {
    public static let mebibyte: UInt64 = 1 << 20
    public static let gibibyte: UInt64 = 1 << 30
}

/// Admission and capacity limits (spec section 6 `[host]` and `[auto]`).
///
/// Defaults come from the spec where it gives a value; the spec itself labels those as
/// starting-point estimates for a 32 GB M2 Mac mini. Values the spec doesn't give are
/// marked "placeholder" and should be tuned once real measurements exist.
public struct SchedulerConfig: Sendable, Equatable {
    public var priority: PriorityPolicy
    public var maxAdmissionsPerPass: Int = 1
    public var minAdmissionIntervalSeconds: Double = 1
    public var minimumJobMemoryBytes: UInt64 = 512 * ByteSize.mebibyte

    /// Always-free headroom. Spec `reserve_gb = 3.0`.
    public var reserveBytes: UInt64
    /// Booted, unparked sims (including booting ones). Spec `max_sims = 4`.
    public var maxRunningSims: Int
    /// Parked (SIGSTOPped) sims. Parking is a later phase, so 0 until measured. Placeholder.
    public var maxParkedSims: Int
    /// Spec `max_concurrent_boots = 1`: at most one boot at a time.
    public var maxConcurrentBoots: Int
    /// Exclusive jobs (`--exclusive`) that may run at once. Default 1: one at a time.
    public var maxConcurrentExclusive: Int
    /// Boot-only gate: a boot is allowed only when load1 <= factor x cpuCount. Default 2.0
    /// from manzanas. Stricter than the host-wide load throttle on hosts with few cores.
    public var bootLoadFactor: Double
    /// Spec `min_free_disk_gb = 40`.
    public var minFreeDiskBytes: UInt64
    /// Spec `swap_growth_limit_mb_per_min = 50`.
    public var swapGrowthLimitBytesPerMinute: Double
    /// Legacy configuration value; stable historical swap no longer stops admissions.
    public var maxSwapUsedBytes: UInt64
    /// Spec `pressure_stop = "warn"` (kernel pressure level 2 or worse).
    public var pressureStop: MemoryPressure
    /// Host-wide load throttle with hysteresis.
    public var loadThrottle: LoadThrottlePolicy
    /// Spec `step_down_on` includes `thermal_serious`.
    public var thermalStop: ThermalState
    /// Explicit conservative memory cost of booting one more simulator.
    /// Default 4.38 GB: the largest stock simulator measured on the Mac mini on
    /// Oct 19, 2026 (spec section 1). Slimmed sims should lower this.
    public var simBootCostBytes: UInt64
    /// Optional project concurrency cap. Zero uses the host-wide policy.
    public var maxRunningPerProject: Int
    /// Bounded per-submitter/project queue allowance for CI bursts.
    public var maxQueuedPerSubmitterPerProject: Int
    public var drain: InfraDrainPolicy
    /// For this long after admission, a job's memory is charged against the probe's
    /// available memory again, because the probe lags behind a freshly started job.
    public var admissionSettleSeconds: Double

    public init(
        priority: PriorityPolicy = PriorityPolicy(),
        reserveBytes: UInt64 = 3 * ByteSize.gibibyte,
        maxRunningSims: Int = 4,
        maxParkedSims: Int = 0,
        maxConcurrentBoots: Int = 1,
        maxConcurrentExclusive: Int = 1,
        bootLoadFactor: Double = 2.0,
        minFreeDiskBytes: UInt64 = 40 * ByteSize.gibibyte,
        swapGrowthLimitBytesPerMinute: Double = Double(50 * ByteSize.mebibyte),
        maxSwapUsedBytes: UInt64 = 3 * ByteSize.gibibyte,
        pressureStop: MemoryPressure = .warn,
        loadThrottle: LoadThrottlePolicy = LoadThrottlePolicy(),
        thermalStop: ThermalState = .serious,
        simBootCostBytes: UInt64 = 4_380_000_000,
        maxRunningPerProject: Int = 0,
        maxQueuedPerSubmitterPerProject: Int = 128,
        drain: InfraDrainPolicy = InfraDrainPolicy(),
        admissionSettleSeconds: Double = 60
    ) {
        self.priority = priority
        self.reserveBytes = reserveBytes
        self.maxRunningSims = maxRunningSims
        self.maxParkedSims = maxParkedSims
        self.maxConcurrentBoots = maxConcurrentBoots
        self.maxConcurrentExclusive = maxConcurrentExclusive
        self.bootLoadFactor = bootLoadFactor
        self.minFreeDiskBytes = minFreeDiskBytes
        self.swapGrowthLimitBytesPerMinute = swapGrowthLimitBytesPerMinute
        self.maxSwapUsedBytes = maxSwapUsedBytes
        self.pressureStop = pressureStop
        self.loadThrottle = loadThrottle
        self.thermalStop = thermalStop
        self.simBootCostBytes = simBootCostBytes
        self.maxRunningPerProject = maxRunningPerProject
        self.maxQueuedPerSubmitterPerProject = maxQueuedPerSubmitterPerProject
        self.drain = drain
        self.admissionSettleSeconds = admissionSettleSeconds
    }

    /// Load ceiling for starting a boot on this host.
    public func bootLoadLimit(cpuCount: Int) -> Double {
        bootLoadFactor * Double(max(1, cpuCount))
    }

    /// Whether the pool may park one more sim (used by the pool manager, a later phase).
    public func canPark(_ pool: PoolSnapshot) -> Bool {
        pool.idleParked < maxParkedSims
    }
}
