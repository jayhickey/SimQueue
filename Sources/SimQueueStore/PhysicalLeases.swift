// SPDX-License-Identifier: MIT

import SimQueueCore

extension JobStore {
    public func physicalLeases() throws -> [String: String] {
        var result: [String: String] = [:]
        for row in try database.query("SELECT udid, job_id FROM physical_leases;") {
            if let udid = row.string("udid"), let job = row.string("job_id") { result[udid] = job }
        }
        return result
    }

    /// Keep a terminal job's phone until its host processes and artifact writers are gone.
    /// Startup uses the same pass after normal process ownership recovery.
    public func releasePhysicalLeases(holdingJobIDs: Set<String>, now: Double) throws {
        for (udid, jobID) in try physicalLeases() {
            guard !holdingJobIDs.contains(jobID), try job(id: jobID)?.state.isActive != true else { continue }
            try database.run("DELETE FROM physical_leases WHERE udid = ?;", [.text(udid)])
            try audit("physical_lease_released", jobID: jobID, detail: udid, now: now)
        }
    }
}
