// SPDX-License-Identifier: MIT

/// The simulator pool tried to prepare a sim for one host template, failed, and has not
/// succeeded since. Without it, a waiter shows only "waiting for the simulator pool: needs
/// 1, 0 ready" while the pool retries the same failing clone every pass, and an
/// unrelated host gate (for example a swap warning) looks like the cause.
public struct PoolBlock: Sendable, Equatable, Codable {
    /// Host template the pool was preparing (nil with one host-wide template).
    public var template: String?
    /// Highest-ranked simulator waiter the pool was preparing for when it last failed.
    public var jobID: String?
    /// The backend's error, as written to `pool_action_failed`.
    public var detail: String
    public var since: Double
    public var lastAt: Double
    public var failures: Int

    public init(template: String?, jobID: String?, detail: String, since: Double, lastAt: Double, failures: Int) {
        self.template = template
        self.jobID = jobID
        self.detail = detail
        self.since = since
        self.lastAt = lastAt
        self.failures = failures
    }

    /// One line for `simq status` and the dashboard.
    public var summary: String {
        let target = template.map { "a \($0) sim" } ?? "a sim"
        let waiter = jobID.map { " for \($0)" } ?? ""
        return "simulator pool can't prepare \(target)\(waiter): \(detail) "
            + "(\(failures) failed attempt\(failures == 1 ? "" : "s"))"
    }

    /// Records another failed attempt (a new detail or waiter replaces the old one).
    public func failedAgain(jobID: String?, detail: String, at now: Double) -> PoolBlock {
        PoolBlock(
            template: template, jobID: jobID, detail: detail, since: since, lastAt: now, failures: failures + 1)
    }
}
