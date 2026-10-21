# CLI, configuration, and protocol reference

Use this page to look up command behavior, execution guarantees, configuration, and the local API. For a first run, start with [installation](INSTALL.md); for CI examples, see [GitHub Actions](ACTIONS.md).

One queue and one simulator pool belong to the daemon’s user on one Mac. Callers submit complete commands; the scheduler does not split tests or route project labels to separate environments. See [architecture](ARCHITECTURE.md), [installation/upgrade](INSTALL.md) and [template contract](TEMPLATE.md).

## Commands

Use `simq <command> --help` for the full flag list. The two submission commands serve different workflows:

```sh
# Run, stream output, and return the command's exit status.
simq run --sims 0 --memory-hint-mib 4096 --timeout 20m -- swift build -j 4

# Submit and leave it in the queue; inspect/wait using the returned job ID.
simq submit --project app --sims 1 --memory-hint-mib 2048 --timeout 30m -- ./test.sh
simq wait J-0001
```

`run` defaults to one simulator; `submit` defaults to zero. Both place the command after `--`. `submit --wait` waits and uses SimQueue's mapped result codes; `run` passes through normal command exits by default.

| Command | Behavior |
| --- | --- |
| `simq dashboard [--port PORT] [--no-open]` | Local browser dashboard with cancellation and queued-job priority controls |
| `simq bump JOB_ID PRIORITY` | Change a queued job’s base priority (integer 0–100); admitted/running/finished jobs are rejected |
| `simq agent-guide` | Version-matched offline operational guide; no daemon or state creation |
| `simq docs [--json]` | Resolve full offline docs beside the actual installed executable; no daemon or state creation |
| `simq init` | Create starter configuration and check Xcode; existing config is kept by default |
| `simq project add <name> --repo <path>` | Store optional project metadata; does not infer a test command or select a simulator |
| `simq run -- <command>` | Lease one simulator by default, stream output, wait, return the command’s status; `--sims 0` for builds |
| `simq submit -- <command>` | Queue an independent job; defaults to no simulator; add `--wait` to wait |
| `simq jobs`, `status`, `explain <job>` | Current queue, host gates and actionable wait reasons |
| `simq cancel <job>` | Request termination of the owned process group and verified cleanup |
| `simq wait <job>` | Reconnect to the same job across service outages; never resubmit |
| `simq logs <job>` | Read retained job output |
| `simq doctor --json`, `owned-udids` | Current diagnostics and ownership, including offline doctor |
| `simq drain`, `resume` | Planned drain/resume; drain timeout leaves the gate set |
| `simq template build <label> [--slim]`, `list`, `rm` | Host template candidates; creation does not select one |
| `simq gc [--apply]` | Inspect/apply artifact retention; application requires cleanup enforcement |
| `simq lease acquire`, `renew`, `release` | Explicit manual leases with holder liveness/identity checks |
| `simq mcp` | Optional local MCP interface over the same socket |
| `simq uninstall [--yes]` | Preview or perform owned-resource cleanup; state is retained unless explicitly purged; see [uninstall](INSTALL.md#uninstall) |

`docs` prints an absolute directory containing `README.md` and the linked `docs/`
guides. It follows the executable through Homebrew symlinks to its Cellar documentation,
and also recognizes an extracted release archive or complete source checkout.
`docs --json` returns `schema_version`, `version`, `path`, and `layout`. Missing or
incomplete documentation exits 1 with `documentation_not_found` in JSON and guidance
to reinstall; `agent-guide` remains available. These offline commands accept no
connection or state-directory options. See [agent setup](INSTALL.md#offline-docs-and-coding-agents).

## Scheduling options

Priority is an integer 0–100, higher first; aliases are empty unless configured. Equal effective priority uses FIFO. The aging boost is capped (default +25), so it cannot guarantee service across arbitrary priority gaps. `--kind` is a display label. `--exclusive` serializes only exclusive jobs; ordinary jobs can run alongside them. Explicit `--retryable` or `--retries N` permits bounded infrastructure/restart replay, not ordinary command-failure retries.

`--memory-hint-mib` is an optional estimate used to require memory headroom before admission. It does not reserve physical RAM, enforce a runtime limit, or terminate a command that exceeds its estimate. If omitted, the command has no explicit estimate and the scheduler applies its 512 MiB minimum accounting. Smaller hints also use that floor. Host resource checks, simulator costs, and admission pacing still apply; the floor is not an automatically measured workload estimate.

For example, `--memory-hint-mib 4096` asks the scheduler to allow approximately 4 GiB of command headroom at admission. After starting, the command can exceed that estimate; current resource conditions can hold back additional jobs. Hints are charged during the admission settling window while host readings catch up, rather than reserved as a fixed lifetime allocation.

`--sims` requests simulator capacity. A normal test job uses one simulator for its entire suite. SimQueue admits independent commands gradually as current host resources allow; it does not split a test command.

`submit --dedupe-key KEY` attaches to matching nonterminal work instead of creating another job. `submit --keep` pins artifacts for the configured extended retention period. See [retention](PROOF-JOBS.md#retention-and-listing-limits).

## Environment and execution

Commands get the daemon’s environment plus explicit `--env NAME=value`. `--env-from NAME` forwards only named caller variables, rejects missing/reserved names and is repeatable. Explicit values override forwarded ones. `SIMQ_*` variables are reserved and never caller-forwarded. On-demand startup uses an environment allowlist rather than inheriting the entire CI environment. Deliberately forward toolchain/CI variables your command needs; do not pass all secrets blindly.

| Variable | Value supplied to the command |
| --- | --- |
| `SIMQ_JOB_ID`, `SIMQ_ATTEMPT` | Job identity and attempt number |
| `SIMQ_PROJECT`, `SIMQ_KIND` | Submission labels |
| `SIMQ_SIMS` | Number of granted simulators |
| `SIMQ_UDID`, `SIMQ_SIM_UDIDS` | First leased UDID and comma-separated leased UDIDs; absent without simulators |
| `SIMQ_RUN_DIR` | This job's artifact directory |
| `SIMQ_DERIVED_DATA`, `SIMQ_RESULT_BUNDLE` | Suggested per-job build and result paths; the command creates their contents |
| `SIMQ_TMPDIR` | Private temporary path under the job directory |
| `TMPDIR` | Defaults to `SIMQ_TMPDIR`; an explicit job environment value overrides it |

Use a queued shell when you want these variables expanded at execution time:

```sh
simq run --sims 1 -- /bin/sh -c 'printf "%s\n" "$SIMQ_UDID"'
```

Warm reuse preserves state. `--reset-app bundle.id` resets the requested apps and keychain, falling back to an erase if reset fails; `--fresh-sim` erases before execution. Preparation finishes before the command starts. See [templates and reuse](TEMPLATE.md).

## Working directory and checkout assertions

Commands run in the submitting directory unless `--cwd` selects another directory. With `submit`, `--worktree` plus `--git-sha` asserts the checked-out commit at submission and again at execution:

```sh
simq submit --project app --sims 0 --memory-hint-mib 4096 \
  --cwd /path/to/checkout --worktree /path/to/checkout --git-sha COMMIT_SHA \
  --wait -- swift build -j 4
```

Replace the path and commit placeholder. This verifies HEAD; it does not freeze files or prevent edits. Use isolated checkouts for concurrent builds and do not delete them while jobs may use them.

## Timeouts and cancellation

`--timeout` counts from command start; `--queue-timeout` counts before the first attempt starts (default 24h). `none`/0 disables a limit. Timeout enforcement persists TERM/KILL timestamps through restart. Cancellation and timeout target verified owned process groups. Unknown/reused identities are reported rather than signalled.

`run --wait-timeout 10m` also limits the caller's wait for the command to start, including simulator preparation; expiry requests cancellation. By contrast, `submit --wait --wait-timeout 10m` stops waiting and leaves the job queued or running. `run` handles SIGINT, SIGTERM, and SIGHUP by requesting cancellation and waiting for cleanup, then exits with 128 plus the signal number. Cleanup can take the configured TERM/KILL grace period.

## Recovery

Queued work and work proven not to have started can recover, with a three-requeue restart-loop cap. A started command is replayed only with explicit retry permission and remaining retry/restart budgets. Otherwise it ends interrupted with a warning to inspect side effects before resubmitting. An unknown start ends with uncertainty; absence of a PID alone does not prove absence of execution. A previous process is stopped only after identity verification. This prevents simultaneous duplicates but cannot undo earlier side effects.

Client recovery is separate: `run` and `wait` can retry unanswered observations or reconnect to the same job for up to 30 seconds after the first transport interruption. Only `wait`, log reads and the final job read are repeated, using the same job ID and log offset; submission and other mutations are never replayed after an ambiguous reply. An explicit wait deadline still wins. Receive deadlines cover complete response lines, including partial bytes; local socket connect/send retain their existing system behavior. Recovery does not promise arbitrary command survival or exactly-once execution. Planned upgrades use drain, successful completion, Homebrew upgrade, service restart and version/health checks. A timeout exits 7 and leaves draining set; `simq resume` cancels that maintenance gate. A new daemon clears the in-memory planned gate and resumes queued jobs.

## Configuration

State defaults to `~/Library/Application Support/SimQueue`; `--state-dir` or `SIMQ_STATE_DIR` selects isolated state. `config.json` keys are optional. Start with [config.example.json](config.example.json), replacing the template placeholder. Drain and restart the daemon after changing its configuration; see [installation](INSTALL.md).

- `simctl.template` explicitly selects the host template UDID/name. `template.device_type` and `template.runtime` define host-wide build defaults. Project-specific template settings are rejected.
- `pool.mode`: `active`, `report-only` or `follow-cleanup`; `warm_min` defaults to 0. RAM-derived `max_sims` can be overridden explicitly. Boots are serialized by `max_concurrent_boots`. Only load/off settling is supported; cap handoff/failure is explicit and audited.
- `host` scales running simulator, memory reserve and load thresholds to RAM/cores. Explicit limits win. Safeguards hold work on pressure, swap growth, reserve shortage, thermal state, disk space and high load. Healthy stable swap can recover without historical swap usage falling below a fixed ceiling.
- Production admission starts at most one command per fresh tick, at least one second apart, with a host-wide core-count concurrency ceiling. Every command incurs at least a 512 MiB memory charge, including smaller or absent hints. Recent starts remain charged during the probe settling window.
- `max_running_per_project` is optional (0, the default, imposes no project cap). The default backlog is 128 queued jobs per submitter/project and 1024 total. Queue-full responses explain which limit was reached; dedupe keys attach to existing nonterminal work.
- `priority_aliases`, `aging_points_per_minute` and `aging_max_boost` configure priority. `max_load5`/`resume_below_load5` configure optional absolute load hysteresis, which remains binding when the default policy recovers from a lower one-minute load.
- `default_run_timeout_seconds`, `default_queue_timeout_seconds`, `kill_grace_seconds`, and `default_max_retries` govern defaults.
- `cleanup_mode` starts report-only for orphan cleanup. Enforcement remains namespace/ownership/identity checked, verified and rate limited. Current anomaly state can open a cleanup breaker; `doctor` explains it.
- `age_rules.artifact_retention_days` controls retained job files. Explicit pins keep required metadata; inspect `gc` before deleting artifacts. Database archival and daemon log limits are described in the architecture and release evidence.

## Socket API

Transport is newline-delimited JSON over an owner-only Unix socket. One request per connection; `wait` may stream changes then a final result. Requests carry `schema_version`, `id`, `method`, `params`. Responses carry the same id and either `result_kind`/`result` or a structured error. Newer unsupported schemas are refused. Removed legacy group-submission fields are rejected rather than silently submitting a different job.

Methods: `submit`, `status`, `jobs`, `explain`, `cancel`, `wait`, `logs`, `doctor`, `drain`, `resume`, `gc`, `lease_acquire`, `lease_renew`, `lease_release`, `template_build`, `template_list`, `template_rm`. Submit fields include project/submitter, integer priority, label, command argv, environment/cwd, memory bytes, simulator count, timeout/retry/exclusive options, checkout assertion, reset/fresh options, dedupe and artifact keep. No test orchestration is supported. Commands and argument help expose the current complete surface.

A terminal result can carry `cleanup_pending: true` while owned processes remain; `wait` and `run` wait for verified cleanup before returning completion. If cleanup cannot be verified, `cleanup_blocked: true` returns an infrastructure failure with doctor guidance while capacity remains held. Job results include state, result class, command exit code, attempt, timestamps, wait reasons, simulator/template identities and artifact paths. Secret environment values are not echoed into job info. `owned_udids` in doctor JSON is a stable contract for external cleanup tools. Offline doctor is read-only and refuses an incompatible database schema.

## Exit codes

`simq run` passes through a normally ended command's exit status. Use `--exit-code mapped` for the following stable codes, or inspect `state`, `result_class`, and `command_exit_code` in `--result-file result.json` to distinguish a command's own exit code from a SimQueue failure.

| Code | Meaning |
| --- | --- |
| 0 | Success |
| 1 | Command failure |
| 2 | Build-failure result (compatibility result class; normal command failures use 1) |
| 3 | Run timeout |
| 4 | Infrastructure failure, including blocked cleanup |
| 5 | Cancelled or interrupted |
| 6 | Queue timeout |
| 7 | Client wait or drain timeout |
| 64 | Invalid command-line usage |
| 65 | Rejected or incompatible protocol request |
| 66 | Unknown job ID |
| 69 | Daemon unavailable |
| 70 | Internal client error |
| 73 | Queue backlog limit reached |
| 128 + signal | The waiting `run` client received a termination signal |

`submit --wait` and `wait` use mapped job results. A drain timeout leaves the drain gate set; a client wait timeout has the command-specific behavior described above.

## Logs, artifacts, and retention

Jobs retain combined logs, `job.json`/summary and command-produced evidence under `jobs/<UTC date>/<id>`. Log events rotate; persistent daemon output uses its internal bounded writer. Artifact listings are bounded and report truncation. No exactly-once side-effect guarantee or pristine-simulator guarantee is implied.

Use `simq logs <job>` for command output and `simq explain <job> --json` for result and artifact metadata. The [artifact guide](PROOF-JOBS.md) covers screenshots, recordings, result bundles, retention periods, and bounded listings.

### Change a queued job's priority

The `bump` method takes `{"job_id":"J-0001","priority":80}` and returns the
updated `job` payload. The daemon validates the range and queued state while
holding its scheduling lock, records a `bumped` audit event, and requests a
scheduling pass. Submission time, sequence and aging are preserved. Unknown IDs
return `not_found`, invalid values return `invalid_argument`, and jobs that have
already been admitted or ended return `invalid_state`. Older daemons do not
support this additive method.
