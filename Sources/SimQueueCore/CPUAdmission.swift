// SPDX-License-Identifier: MIT

/// Time-weighted CPU utilization. Missing readings or a sampling gap reset the
/// observation window, so one low sample never establishes spare capacity.
public struct CPUUsageWindow: Sendable {
    private var samples: [(at: Double, percent: Double)] = []
    public init() {}

    public mutating func add(at time: Double, percent: Double?) -> Double? {
        guard time.isFinite, let percent, percent.isFinite, (0...100).contains(percent) else {
            samples.removeAll()
            return nil
        }
        if let last = samples.last, time < last.at { samples.removeAll() }
        if let last = samples.last, time == last.at { return nil }
        if let last = samples.last, time - last.at > 5 { samples.removeAll() }
        samples.append((time, percent))
        let start = time - 10
        while samples.count > 1, samples[1].at <= start { samples.removeFirst() }
        guard let first = samples.first, first.at <= start else { return nil }
        var total = 0.0
        for index in 1..<samples.count {
            let duration = samples[index].at - max(start, samples[index - 1].at)
            total += duration * samples[index].percent
        }
        return total / 10
    }
}

/// CPU is primary once a continuous ten-second observation exists. Load remains
/// the conservative fallback during startup, probe failure or stale sampling.
public enum CPUAdmission {
    public static let stopPercent = 90.0
    public static let resumePercent = 75.0
    public static let bootPercent = 80.0
    public static let admissionIntervalSeconds = 10.0

    public static func utilization(_ host: HostSnapshot, now: Double) -> Double? {
        guard now >= host.sampledAt, now - host.sampledAt <= 5,
            let value = host.cpuSustainedPercent, value.isFinite, (0...100).contains(value)
        else { return nil }
        return value
    }
}
