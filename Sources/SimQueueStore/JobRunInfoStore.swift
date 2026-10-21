// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore

// MARK: - Per-job run info (sims held, sampled peak memory)

extension JobStore {
    /// Records the pool sims a job holds as it starts (replacing any earlier record, e.g.
    /// from a previous attempt).
    public func recordJobSims(jobID: String, sims: [JobSim]) throws {
        let json = String(decoding: try JSONEncoder().encode(sims), as: UTF8.self)
        try database.run(
            """
            INSERT INTO job_run_info (job_id, sims_json) VALUES (?, ?)
            ON CONFLICT(job_id) DO UPDATE SET sims_json = excluded.sims_json;
            """,
            [.text(jobID), .text(json)])
    }

    /// Starts an attempt's record: the pool sims it holds (possibly none) and no peak yet,
    /// replacing whatever an earlier attempt left.
    public func beginJobRun(jobID: String, sims: [JobSim]) throws {
        let json = String(decoding: try JSONEncoder().encode(sims), as: UTF8.self)
        try database.run(
            """
            INSERT INTO job_run_info (job_id, sims_json, peak_rss_bytes) VALUES (?, ?, NULL)
            ON CONFLICT(job_id) DO UPDATE SET sims_json = excluded.sims_json, peak_rss_bytes = NULL;
            """,
            [.text(jobID), .text(json)])
    }

    /// Raises the job's recorded peak resident memory to `bytes` (never lowers it).
    public func recordPeakResidentBytes(jobID: String, bytes: UInt64) throws {
        let value = Int64(clamping: bytes)
        try database.run(
            """
            INSERT INTO job_run_info (job_id, peak_rss_bytes) VALUES (?, ?)
            ON CONFLICT(job_id) DO UPDATE SET peak_rss_bytes = MAX(COALESCE(peak_rss_bytes, 0), excluded.peak_rss_bytes);
            """,
            [.text(jobID), .integer(value)])
    }

    /// What was recorded for the job, or nil if nothing was.
    public func jobRunInfo(jobID: String) throws -> JobRunInfo? {
        guard
            let row = try database.query(
                "SELECT sims_json, peak_rss_bytes FROM job_run_info WHERE job_id = ?;", [.text(jobID)]
            ).first
        else { return nil }
        let sims =
            row.string("sims_json").flatMap { try? JSONDecoder().decode([JobSim].self, from: Data($0.utf8)) } ?? []
        return JobRunInfo(sims: sims, peakResidentBytes: row.int("peak_rss_bytes").map { UInt64(max(0, $0)) })
    }
}
