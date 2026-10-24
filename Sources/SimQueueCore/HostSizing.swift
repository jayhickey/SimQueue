// SPDX-License-Identifier: MIT

/// Limits derived from the host's core count and RAM (config `host`), so one config fits a
/// 10-core 32 GiB Mac mini and a 24-core 128 GiB Mac Studio. `simqd` applies them once at
/// start (`apply(cpuCount:totalMemoryBytes:to:pool:)`), before the scheduler and pool read
/// their configs. Every derived value can be set outright: an explicit setting always wins.
///
/// On a 10-core host the defaults give admission throttle 30/30/15/20, settle 20,
/// and a simulator boot limit of 30 (3x cores). Simulator ceilings below
/// scale with RAM; automatic pool capacity can fill the running-simulator ceiling.
public struct HostSizing: Sendable, Equatable {
    /// Throttle admissions when load5 is above this x cores (`throttle_load5_per_core`).
    public var throttleLoad5PerCore: Double
    /// Or when load1 is above this x cores (`throttle_load1_per_core`) ...
    public var throttleLoad1PerCore: Double
    /// ... while load5 is above this x cores (`throttle_load5_with_load1_per_core`).
    public var throttleLoad5WithLoad1PerCore: Double
    /// Short-average recovery when load1 is at or below this x cores. Also clears
    /// historical load5 hysteresis after entry triggers stop. Existing config name:
    /// `throttle_clear_load5_per_core`; explicit max_load5/resume still takes precedence.
    public var throttleClearLoad5PerCore: Double
    /// Boot gate: a sim boots only when load1 <= this x cores (`boot_load_per_core`;
    /// `SchedulerConfig.bootLoadFactor`).
    public var bootLoadPerCore: Double
    /// Pool settle load5 threshold (`settle_load5_per_core`), unless
    /// `pool.settle.load_below` sets an absolute number. Defaults also permit recovery
    /// at the shorter load1 clear threshold; explicit settle thresholds remain load5-only.
    public var settleLoad5PerCore: Double
    /// Always-free memory headroom as a percent of RAM (`reserve_percent`) ...
    public var reservePercent: Double
    /// ... but never less than this (`min_reserve_mib`).
    public var minReserveBytes: UInt64
    /// `reserve_mib`: an absolute reserve instead of the percent (0: no reserve at all).
    public var reserveBytes: UInt64?
    /// Optional memory allowance per cold simulator boot (`sim_boot_cost_mib`).
    public var simBootCostBytes: UInt64?
    /// One running sim per this much RAM (`ram_per_running_sim_mib`) ...
    public var ramPerRunningSimBytes: UInt64
    /// ... unless `max_running_sims` sets the number.
    public var maxRunningSims: Int?
    /// One pool sim per this much RAM (`ram_per_pool_sim_mib`), unless `pool.max_sims` is set.
    public var ramPerPoolSimBytes: UInt64
    /// Set by the config loader when `pool.max_sims` / `pool.settle.load_below` were given,
    /// so the derived values don't replace them.
    public var poolMaxSimsIsExplicit = false
    public var settleLoadBelowIsExplicit = false
    public var settleLoad5PerCoreIsExplicit = false

    public init(
        throttleLoad5PerCore: Double = 3.0, throttleLoad1PerCore: Double = 3.0,
        throttleLoad5WithLoad1PerCore: Double = 1.5, throttleClearLoad5PerCore: Double = 2.0,
        bootLoadPerCore: Double = 3.0, settleLoad5PerCore: Double = 2.0,
        reservePercent: Double = 10, minReserveBytes: UInt64 = ByteSize.gibibyte,
        reserveBytes: UInt64? = nil, simBootCostBytes: UInt64? = nil,
        ramPerRunningSimBytes: UInt64 = 8 * ByteSize.gibibyte, maxRunningSims: Int? = nil,
        ramPerPoolSimBytes: UInt64 = 8 * ByteSize.gibibyte
    ) {
        self.throttleLoad5PerCore = throttleLoad5PerCore
        self.throttleLoad1PerCore = throttleLoad1PerCore
        self.throttleLoad5WithLoad1PerCore = throttleLoad5WithLoad1PerCore
        self.throttleClearLoad5PerCore = throttleClearLoad5PerCore
        self.bootLoadPerCore = bootLoadPerCore
        self.settleLoad5PerCore = settleLoad5PerCore
        self.reservePercent = reservePercent
        self.minReserveBytes = minReserveBytes
        self.reserveBytes = reserveBytes
        self.simBootCostBytes = simBootCostBytes
        self.ramPerRunningSimBytes = ramPerRunningSimBytes
        self.maxRunningSims = maxRunningSims
        self.ramPerPoolSimBytes = ramPerPoolSimBytes
    }

    /// The memory reserve for a host with `totalMemoryBytes` of RAM.
    public func reserve(totalMemoryBytes: UInt64) -> UInt64 {
        if let reserveBytes { return reserveBytes }
        let percent = UInt64(Double(totalMemoryBytes) * reservePercent / 100)
        return max(minReserveBytes, percent)
    }

    /// Running sims a host with `totalMemoryBytes` of RAM gets (at least 1).
    /// TODO(trial data): also cap by cores (min of the RAM and core limits). A 128 GiB host
    /// with few cores would get 16 sims by RAM alone; leave it until boots per core are measured.
    public func runningSims(totalMemoryBytes: UInt64) -> Int {
        maxRunningSims ?? max(1, Int(totalMemoryBytes / max(1, ramPerRunningSimBytes)))
    }

    /// Pool sims a host with `totalMemoryBytes` of RAM gets (at least 1).
    public func poolSims(totalMemoryBytes: UInt64) -> Int {
        max(1, Int(totalMemoryBytes / max(1, ramPerPoolSimBytes)))
    }

    /// Sets the derived limits on `scheduler` and `pool` (when there is one). The throttle's
    /// optional `max_load5` / `resume_below_load5` stay absolute.
    public func apply(
        cpuCount: Int, totalMemoryBytes: UInt64, to scheduler: inout SchedulerConfig, pool: inout SimPoolConfig?
    ) {
        let cores = Double(max(1, cpuCount))
        scheduler.reserveBytes = reserve(totalMemoryBytes: totalMemoryBytes)
        if let simBootCostBytes { scheduler.simBootCostBytes = simBootCostBytes }
        scheduler.maxRunningSims = runningSims(totalMemoryBytes: totalMemoryBytes)
        scheduler.bootLoadFactor = bootLoadPerCore
        scheduler.loadThrottle.load5Above = throttleLoad5PerCore * cores
        scheduler.loadThrottle.load1Above = throttleLoad1PerCore * cores
        scheduler.loadThrottle.load5WithLoad1Above = throttleLoad5WithLoad1PerCore * cores
        scheduler.loadThrottle.clearBelowLoad5 = throttleClearLoad5PerCore * cores
        guard var settings = pool else { return }
        if !poolMaxSimsIsExplicit {
            settings.maxSims = max(
                settings.warmMin, min(scheduler.maxRunningSims, poolSims(totalMemoryBytes: totalMemoryBytes)))
        }
        if !settleLoadBelowIsExplicit { settings.settle.loadBelow = settleLoad5PerCore * cores }
        settings.settle.load1RecoveryBelow =
            settleLoadBelowIsExplicit || settleLoad5PerCoreIsExplicit
            ? nil : min(settings.settle.loadBelow, scheduler.loadThrottle.clearBelowLoad5)
        pool = settings
    }
}
