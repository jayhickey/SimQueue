// SPDX-License-Identifier: MIT

extension JobStore {
    /// The admitted audit survives fast completion and retry clearing admitted_at.
    /// Read once on daemon startup; normal ticks retain the latest claim in memory.
    public func latestAdmissionAt() throws -> Double? {
        try database.query("SELECT at FROM audit_log WHERE type = 'admitted' ORDER BY seq DESC LIMIT 1;").first?.double(
            "at")
    }
}
