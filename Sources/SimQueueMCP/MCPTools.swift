// SPDX-License-Identifier: MIT

/// The MCP tools: one per socket method. Input schemas use the socket's snake_case
/// params (see docs/PROTOCOL.md).
struct MCPTool {
    var name: String
    var description: String
    var properties: [String: Any]
    var required: [String]

    var descriptor: [String: Any] {
        [
            "name": name, "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required],
        ]
    }
}

enum MCPTools {
    static func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
    static func integer(_ description: String) -> [String: Any] { ["type": "integer", "description": description] }
    static func number(_ description: String) -> [String: Any] { ["type": "number", "description": description] }
    static func boolean(_ description: String) -> [String: Any] { ["type": "boolean", "description": description] }
    static var jobID: [String: Any] { string("Job id from simq_submit or simq_jobs.") }
    static var timeout: [String: Any] { number("Seconds to wait (default 60, max 600).") }

    static var all: [MCPTool] {
        [
            MCPTool(
                name: "simq_submit", description: "Queue a job. Returns its id and queue position.",
                properties: [
                    "project": string("Project name."),
                    "command": ["type": "array", "items": ["type": "string"], "description": "argv to run."],
                    "kind": string("Free-form label."),
                    "priority": integer("0...100, higher first (default 50)."),
                    "priority_name": string("A priority alias from the daemon config."),
                    "submitter": string("Who submits (default: mcp, or SIMQ_SUBMITTER)."),
                    "worktree": string("Worktree path."),
                    "git_sha": string("Commit sha; must be checked out in worktree (or cwd)."),
                    "dedupe_key": string("Jobs with the same key are deduplicated."),
                    "min_sims": integer("Sims needed (default 0)."), "max_sims": integer("Sims it can use."),
                    "memory_bytes": integer(
                        "Optional scheduling estimate in bytes, not an enforced limit or RAM reservation."),
                    "memory_bytes_per_sim": integer(
                        "Additional scheduling estimate per simulator in bytes; not an enforced limit."),
                    "exclusive": boolean("Serialize with other exclusive jobs."),
                    "retryable": boolean("Retry once after an infra failure."),
                    "max_retries": integer("Infra retries (0...10)."),
                    "run_timeout_seconds": number("Run timeout (0: none)."),
                    "queue_timeout_seconds": number("Queue timeout before start (0: none)."),
                    "environment": ["type": "object", "additionalProperties": ["type": "string"]],
                    "cwd": string("Absolute working directory."),
                    "reset_apps": [
                        "type": "array", "items": ["type": "string"],
                        "description":
                            "Bundle ids to reset on each leased sim before the command (uninstall, privacy reset, then keychain reset; falls back to an erase if a step fails). Needs min_sims >= 1.",
                    ],
                    "fresh_sim": boolean("Erase each leased sim before the command. Needs min_sims >= 1."),
                ],
                required: ["project"]),
            MCPTool(name: "simq_status", description: "Queue and host summary.", properties: [:], required: []),
            MCPTool(
                name: "simq_jobs", description: "List jobs.",
                properties: [
                    "states": ["type": "array", "items": ["type": "string"], "description": "Filter by state."],
                    "project": string("Filter by project."), "limit": integer("At most this many."),
                ],
                required: []),
            MCPTool(
                name: "simq_explain",
                description:
                    "One job, with why it is waiting. Once started: run_dir (SIMQ_RUN_DIR) and artifacts (files left there: path, bytes, type; capped at 200, artifacts_truncated when more).",
                properties: ["job_id": jobID],
                required: ["job_id"]),
            MCPTool(
                name: "simq_cancel", description: "Cancel a queued or running job.", properties: ["job_id": jobID],
                required: ["job_id"]),
            MCPTool(
                name: "simq_wait",
                description:
                    "Wait for a job to finish (or be admitted) up to timeout_seconds. Returns the job, with run_dir and artifacts as in simq_explain; timed_out is true if it is still going.",
                properties: [
                    "job_id": jobID, "until_admitted": boolean("Return once admitted."), "timeout_seconds": timeout,
                ],
                required: ["job_id"]),
            MCPTool(
                name: "simq_logs", description: "Read a slice of a job's output log from offset.",
                properties: [
                    "job_id": jobID, "offset": integer("Byte offset (default 0)."),
                    "max_bytes": integer("At most this many bytes."),
                ],
                required: ["job_id"]),
            MCPTool(
                name: "simq_lease_acquire",
                description:
                    "Lease a settled pool sim (pool on only), waiting up to timeout_seconds. The lease is held by this MCP server's process and ends with the session; state is pending if none settled in time.",
                properties: ["holder": string("Stable holder name (used to release)."), "timeout_seconds": timeout],
                required: ["holder"]),
            MCPTool(
                name: "simq_lease_release", description: "Return a leased pool sim.",
                properties: ["holder": string("The holder that acquired it."), "udid": string("The sim's UDID.")],
                required: ["holder", "udid"]),
            MCPTool(name: "simq_doctor", description: "Read-only health report.", properties: [:], required: []),
        ]
    }
}
