# MCP integration

Connect a local MCP client to SimQueue to submit commands, inspect the queue, read logs, and manage simulator leases. The MCP server uses the same local daemon and job records as the CLI.

Complete [installation](INSTALL.md) first. `simq mcp` runs on stdio using JSON-RPC 2.0, one message per line. It starts only when your MCP client launches it and keeps no queue state of its own. See the [socket reference](PROTOCOL.md#socket-api) for the underlying request model.

## Configure your client

For a client that accepts an `mcpServers` configuration:

```json
{ "mcpServers": { "simq": { "command": "simq", "args": ["mcp"] } } }
```

If your desktop client does not inherit your shell PATH, replace `"simq"` with the absolute path returned by `command -v simq`.

Options: `--state-dir` (default `$SIMQ_STATE_DIR` or the platform default) and
`--submitter` (default `$SIMQ_SUBMITTER` or `mcp`).

## Available tools

| Tool | Socket method | Notes |
| --- | --- | --- |
| `simq_submit` | `submit` | `submit` params. `submitter`, `min_sims` and memory default to `mcp`, 0, 0. `reset_apps` and `fresh_sim` ask for sim prep ([backends](BACKENDS.md)). |
| `simq_status` | `status` | |
| `simq_jobs` | `jobs` | |
| `simq_explain` | `explain` | `job_id`. The job has `run_dir`, `artifacts` (`{path, bytes, type}`, relative to `run_dir`). |
| `simq_cancel` | `cancel` | `job_id` |
| `simq_wait` | `wait` | `job_id`, `until_admitted`, `timeout_seconds` (default 60, max 600). Adds `timed_out`. Like `simq_explain`, the job has `run_dir` and `artifacts` (files left in `SIMQ_RUN_DIR`). |
| `simq_logs` | `logs` | `job_id`, `offset`, `max_bytes` |
| `simq_lease_acquire` | `lease_acquire` | `holder`, `timeout_seconds`. Polls until granted. The holder pid is the MCP server process, so the lease can be reclaimed when that process exits. |
| `simq_lease_release` | `lease_release` | `holder`, `udid` |
| `simq_doctor` | `doctor` | |

## Submit and follow a command

Call `simq_submit` with a project and command argv, for example:

```json
{
  "project": "app",
  "command": ["/bin/sh", "-c", "./test.sh"],
  "cwd": "/path/to/checkout",
  "min_sims": 1,
  "memory_bytes": 2147483648,
  "run_timeout_seconds": 1800
}
```

Replace the checkout path and command. `test.sh` can use `SIMQ_UDID` and the other [job environment variables](PROTOCOL.md#environment-and-execution). Submissions default to zero simulators, so request `min_sims: 1` for a simulator job. Memory is an optional scheduling estimate in **bytes**, unlike the CLI's `--memory-hint-mib` flag. It does not reserve RAM or enforce a limit. Omission uses the scheduler's 512 MiB minimum accounting, alongside current host checks and simulator costs.

Save the returned job ID. Use `simq_wait` for bounded waits, `simq_explain` for state and artifact paths, and `simq_logs` for output slices. If a wait returns `timed_out: true`, the job continues; wait again using the same ID. Use `simq_cancel` to request cancellation. Repeated waits do not create new jobs.

A tool's text content is `{"result_kind", "result"}` in the socket's JSON. A daemon
error comes back as a tool error (`isError: true`) with `{"error": {"code", "message"}}`.

## Execution and lease ownership

`simq_submit` has the same trusted-command boundary and recovery rules as the CLI.
Its `exclusive` flag takes the single exclusive slot; ordinary jobs may run alongside.
Only explicit `retryable`/retry permission permits replay of a started command, and
restart bounds still apply. A waiting client reconnecting does not grant retry permission.
Pass selected environment entries deliberately in the submit request; `SIMQ_*` names
are reserved. The CLI's `--env-from NAME` is a caller-side convenience rather than a
daemon request to copy arbitrary client or daemon secrets.

For manual leases, keep a stable holder name for acquisition and release. Acquisition can return `state: pending` when its wait expires; check for `state: granted` and a UDID before using a simulator. The MCP server's process owns the lease; once it exits, holder-liveness checks can reclaim the simulator. Use ordinary submitted jobs when you want SimQueue to supervise the command and its simulator together. Neither a manual lease nor a queued job provides a pristine simulator or security isolation; see [reuse](TEMPLATE.md#reuse-and-readiness).
