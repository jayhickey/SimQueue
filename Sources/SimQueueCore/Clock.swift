// SPDX-License-Identifier: MIT

import Foundation

/// Time source. Everything that reads "now" goes through a clock, so soak tests can run
/// days of scheduling against a simulated clock in milliseconds.
public protocol Clock: Sendable {
    /// Seconds since the Unix epoch.
    func now() -> Double
}

public struct SystemClock: Clock {
    public init() {}

    public func now() -> Double {
        Date().timeIntervalSince1970
    }
}

/// Manually advanced clock for tests.
public final class ManualClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Double

    public init(start: Double = 1_800_000_000) {
        current = start
    }

    public func now() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    public func advance(by seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        current += seconds
    }

    public func set(_ time: Double) {
        lock.lock()
        defer { lock.unlock() }
        current = time
    }
}
