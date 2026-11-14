# Architecture

SimQueue runs one local queue and one host-wide simulator pool. Each job owns its complete command: a simulator job runs its whole workload on one leased simulator, while `--sims 0` runs a build or another simulator-free command. SimQueue does not enumerate tests, shard suites or combine test results.

The CLI exchanges newline-delimited JSON with `simqd` over an owner-only Unix socket. Commands run as the daemon’s user, with a process group, artifacts and a job-specific temporary directory. This is trusted local execution: socket permissions do not sandbox a submitted command. Give access only to callers and workflows that may execute code as that user.

For setup and operation, see [installation](INSTALL.md), [the template contract](TEMPLATE.md) and [the socket protocol](PROTOCOL.md). Maintainer validation and artifact provenance are described in [releasing](RELEASING.md).

## Components and state

| Component | Responsibility |
| --- | --- |
| `SimQueueCore` | Job/resource models, scheduling policy, pool state machine and cleanup planning |
| `SimQueueStore` | SQLite queue, ownership ledger, claims, audit events, intents and archived history |
| `SimQueueHost` / `SimQueueSim` | Resource readings, process identity, filesystem operations and simulator backends |
| `SimQueueEngine` | Apply policy to stored state, admit work, supervise deadlines and reconcile ownership |
| `SimQueueDaemon` | Serialize requests/state changes, run commands and coordinate background host work |
| `simq` / `simqd` | User-facing client and daemon entry points |

The default state directory is `~/Library/Application Support/SimQueue`. It holds the database, socket, configuration, health snapshot and logs; jobs have separate output/artifact directories. An instance lock protects that state directory, and the real backend also takes a per-user host lock to prevent competing managers of that user's CoreSimulator device set. Callers sharing the queue run under the daemon's user; separate macOS accounts do not share its socket or admission accounting. A persisted owner tag distinguishes simulator names created from different state directories. Changing a directory name or configuration is not a safe way to adopt another installation’s resources.

SQLite uses WAL and `synchronous=FULL`. The database is authoritative for queue state, resource ownership and audit history; the event log and `health.json` are derived views. Claims use a daemon epoch and fencing token so a stale supervisor cannot finish a newer claim.

## Admission and capacity

The scheduler plans from queued/active jobs, current resource readings, pool readiness and queue controls. It does not learn per-job memory estimates. Optional `--memory-hint-mib` estimates and current host probes determine memory admission; each command has a conservative 512 MiB minimum charge, including smaller or absent hints. This is scheduler accounting, not a RAM reservation or enforced limit; exceeding a hint does not terminate the command. Recent admissions remain charged during the probe settling window because the host reading may lag a newly started command. Active grants and unresolved process cleanup remain capacity commitments even when a backend snapshot has not caught up.

Production admits at most one command per pass, at least ten seconds apart once sustained CPU telemetry is available (one second with fallback load telemetry), and limits simultaneous commands to the host’s active core count. RAM-derived simulator limits and explicit host settings separately bound the pool. One project has no default execution cap; `max_running_per_project` optionally adds one. `--exclusive` uses its own configured exclusive slots rather than bypassing resource gates. The default backlog is 128 queued jobs per submitter/project and 1024 globally; queue-full rejection is actionable, and a deduplicated submission can attach to existing nonterminal work.

Admissions stop on memory pressure, insufficient reserve/headroom, excessive swap growth, thermal pressure, insufficient disk space or the CPU/load policy. Stable historical swap above 3 GiB alone does not stop an otherwise healthy host. A failed probe holds admissions rather than substituting an optimistic reading. These are admission controls: unrelated applications can change the host after a sample, and SimQueue does not impose an operating-system resource quota on arbitrary commands.

When memory pressure blocks admission, the pool shuts down verified idle, unleased simulators serially, even when jobs are waiting or the warm minimum would otherwise keep them booted. It samples pressure after every shutdown and stops as soon as pressure clears, no eligible simulators remain, or an operation fails or cannot be verified. Running and leased simulators, templates and unrelated devices remain protected. Shutting down idle simulators does not relax the admission gates.

### CPU admission and load fallback

Normal admission uses a time-weighted ten-second CPU utilization window from native CPU tick deltas. New commands hold above 90% utilization and resume at or below 75%. Starts are spaced at least ten seconds apart so the host can reflect new work before another admission. Warm simulator jobs and simulator-free jobs use the same admission policy. This permits useful overlap when load averages remain elevated but CPU has capacity.

New simulator boots require sustained CPU at or below 80%, independently of warm-job admission. Default post-boot settling also requires CPU at or below 80%, after bounded backend boot-status completes. Memory pressure, reserve/headroom, swap growth, thermal state, disk availability, simulator capacity and boot concurrency remain binding. These utilization thresholds are built-in policy, not additional host tuning knobs.

A CPU window requires continuous valid samples spanning ten seconds; gaps above five seconds reset it. Missing, invalid or stale CPU telemetry falls back to the existing load policy. Load is an averaged demand signal, not a CPU percentage; CPU capacity alone does not establish healthy storage or eliminate other gates. Status exposes instantaneous `cpuUsagePercent` and optional `cpuSustainedPercent`; CPU holds use `cpu_throttle` / `cpu_too_high_for_boot` reasons. The legacy `load_throttled` status field now indicates either CPU or fallback-load admission holds. Startup and transition audit logs identify the signals.

Fallback entry occurs when load5 exceeds 3 × active cores, or load1 exceeds 3 × cores while load5 exceeds 1.5 × cores. A recovered load1 at or below 2 × cores suppresses those historical gates. Otherwise a hold persists until entry rules stop and load5 clears the recovery threshold. Existing `host.throttle_*_per_core` settings tune this fallback; `host.boot_load_per_core` tunes the fallback boot ceiling (default 3 × cores). Optional absolute `max_load5` / `resume_below_load5` remain binding even with valid CPU telemetry.

Explicit `pool.settle.load_below` or `host.settle_load5_per_core` preserves strict load5 settling, including a value equal to the default. Default settling falls back to load5 or recovered load1 when CPU observation is unavailable. `pool.settle.mode: off` still requires completed boot-status. No change increases boot concurrency, warm minimum or simulator capacity.

### Ordering and backfill

Jobs are ordered by integer priority (0–100), a configurable capped aging boost and FIFO ties. Aging does not promise eventual service across an arbitrary priority gap. A blocked job reserves the memory/simulator capacity it needs, allowing fitting work to use other capacity. For example, a simulator waiter can permit a simulator-free build. A memory-constrained large job lets smaller fitting jobs start ahead of it for its first 10 minutes in the queue (`memoryHoldGraceSeconds`, measured from its queue time); after that it keeps accumulating headroom instead of losing it to repeated smaller starts, and it is admitted first once memory returns. Impossible requests and project-limited jobs do not reserve shared resources.

## Simulator lifecycle and warm reuse

The pool clones one explicitly selected host template. Building a candidate does not select it. Existing clones must match the selected template before they can be handed out; an incompatible selection fails with a drain/remove/restart procedure. Project names label jobs and do not route them to different runtimes or templates.

A clone progresses through shutdown, booting, settling, ready and leased phases. Only ready, untainted simulators are eligible for handoff; booting/settling rows hold boot slots. The implemented settle modes are load-based or off. Retrying a failed boot or recycling an old/tainted clone uses the bounded pool worker and ownership checks.

A healthy ended lease normally returns to ready without erasing or shutting down the simulator. The next job therefore receives its retained state. App-data/privacy/keychain reset and full fresh-simulator preparation are explicit job requests (`--reset-app` and `--fresh-sim`). Preparation runs before the command and holds the lease throughout; failed or interrupted preparation taints disturbed devices for recycling. Do not treat warm reuse as test isolation.

## Supervision and host work

Requests and store transitions are serialized. A scheduling tick samples the host and shares fresh readings with pool planning; aged readings are refreshed before an admission or a later host action. Long create/boot/recycle operations run through one serial pool worker outside the service lock, so a second pool pass cannot overlap them. Per-job simulator preparation and history archival have their own serialized workers. Completion re-enters protected state transitions and checks that the planned row still applies.

Simulator inventory is demand-driven. An idle pool does not enumerate external simulators on every pass. An otherwise eligible create/boot checks relevant external devices immediately before acting and refreshes resource gates after a slow query. A backend without the managed pool needs an inventory snapshot only when queued work can request simulators. Full watchdog reconciliation still observes actual devices; skipping an admission query does not turn cached ownership into proof of absence.

While work, queued jobs or process cleanup are outstanding, the normal tick interval is at most one second. Idle polling backs off to at most five seconds. Submissions and control requests wake the loop immediately. Record measured supervision latency and daemon/helper CPU and RSS separately from workload costs; the polling intervals alone do not establish performance. See [release evidence](RELEASING.md#release-evidence).

For the maintainer’s controlled retained-history profile (10,000 completed jobs), investigate daemon/helper CPU above 0.5% of one core while idle or resource-blocked, above 3% during the tiny-command workload, or daemon RSS above 100 MiB. Investigate unexplained growth above 2 MiB in a 50-second idle window or 8 MiB across the matched busy interval. These are regression investigation thresholds for that profile, separate from admission limits and production workload costs. Preserve the duration, queue state, helper accounting and platform with each result.

The process executor starts each command in a separate process group and records identity. Cancellation and run timeout use TERM, a grace period and KILL when needed. Exited leaders are retained long enough to verify and drain their groups; reused or unverifiable groups are never signaled. Unresolved cleanup keeps dependent resources held and reports a cleanup block instead of pretending they are free. This supervision covers the recorded command process group; services launched independently by CoreSimulator or launchd are not automatically members of that group.

## Durability, restart and upgrades

Write-ahead spawn/action intents record a potentially interrupted host operation before it runs. Successful operations are confirmed against observations before their resource release is recorded. An in-flight marker prevents ordinary reconciliation from treating a live worker as a crashed action; pending clone names remain protected until ownership registration finishes.

After a restart, interrupted work is requeued at its original queue position, at most three times per job. That includes a command that had started: its process group is stopped first, only after its recorded identity is verified, and the command then runs again from the beginning. A daemon going away is SimQueue's failure, not the job's, so no retry permission is needed and no infra retry is used up. A job submitted with `--no-restart-replay` is never replayed after it started; it ends `interrupted`. Setting `restart_recovery` to `interrupt` restores the stricter rule host-wide: a started command is replayed only if it is retryable with retry budget left. A command whose process group is still alive and cannot be verified is never requeued beside it, and an uncertain start reports uncertainty and retains resources when absence cannot be proved. Killing an old process avoids concurrent copies but cannot undo side effects. A replay repeats them. SimQueue does not guarantee exactly-once command execution, and a running command does not survive an abrupt daemon restart; it is rerun.

A restart interruption never counts toward the infra-failure drain: the drain holds admission when work keeps failing on the host, and a restart says nothing about the next job. A job that reaches the restart cap ends `infra_failed` and does count. Repeated unplanned restarts are held back by their own breaker, described under liveness below.

A replayed attempt runs in the job's existing run directory. Before it starts, the earlier attempt's result bundle is moved aside and kept and its temporary directory is emptied; the build cache and the log are kept. A requeued job is not admitted again while it still holds a simulator lease from its earlier attempt: the lease is released by the pool the way it is after any ended job, so the replay holds one simulator, in the state any job would get. A pool that takes no host action never releases a lease, so the hold is not applied there: the job is admitted only when another simulator is ready, keeps the one it holds, and otherwise waits like every simulator job on such a pool. Only the command's own process group is stopped before a replay; a descendant that left the group can outlive it.

A waiting client reconnects to the same job; reconnect is separate from command recovery. Planned upgrades first drain admitted work, process groups, simulator leases, pending intents and template/pool/preparation/archive/artifact workers. A drain timeout leaves its gate set and does not authorize a restart. Live destructive uninstall also requires completed drain, refuses unresolved processes/intents even with force, and re-reads ownership after stop. See [installation](INSTALL.md) for consistent backups, legacy-state transitions and matching-backup rollback. Unfinished legacy shard groups are refused before database migration or writer journal changes.

## Reconciliation and health

The watchdog runs light health checks and periodic full ownership reconciliation. It reports current anomalies, verified cleanup outcomes and circuit-breaker state through local status/doctor output. Cleanup is namespace/ownership/identity checked, verified and rate limited; its default report-only mode does not authorize destructive orphan cleanup. Templates have a separate explicit removal path and are not ordinary pool garbage.

Daemon host calls release the service lock while tools run and reacquire it before
applying results. Admission reloads job rows and current pool capacity after those observations. Template removal reserves its name and UDID across unlocked inventory, deletion and verification, preventing a new clone from starting against that source. Template capability probes also use the lock handoff. Physical-device
health is read from a background cache: one worker probes configured devices, refreshes
values after 30 seconds, and reports unavailable once a sample is 60 seconds old.
A cold cache reports refresh pending rather than blocking status on devicectl.

ToolRunner drains nonblocking output pipes and observes/reaps its own child on the
calling thread, independently of Dispatch worker availability. Every tool has a deadline;
timeout sends TERM then KILL to its entire process group before reaping the leader.
Even when the leader exits first, inherited output pipes remain bounded by that deadline.
A dedicated nonblocking reaper owns any killed child still waiting in the kernel.

Socket admission has separate limits: 4 incoming readers, 4 control requests, 8 other
requests, 16 streaming waits, and one reserved self-check. Excess requests receive
`queue_full` with a `daemon busy` explanation; callers may retry after a delay.
Incoming lines have a two-second total deadline and writes are bounded. Socket handlers
use bounded independent threads rather than blocking Dispatch's shared pool.

A separate liveness thread makes a real status round-trip every five seconds, with
bounded connect, write and read phases. An unanswered probe alone is not a wedge: on a
host far over its CPU capacity an answer can take longer than the probe waits while
every job runs normally. So the thread also watches, without taking it, whether the
service lock shows activity: somebody acquired it, or its holder moved on to the next
step of a pass (the next reconcile action, the next resource of a teardown). Only when
status has gone unanswered and the lock has shown no activity for 30 seconds does simqd
exit with status 70, without joining potentially wedged workers. Unanswered status
while the lock is still active is logged once and tolerated for five minutes, after
which the socket counts as unusable. That limit plus the time a restart takes is kept
well inside the clients' ten-minute reconnect window, so clients are still reconnecting
when the restarted daemon answers. Time is counted as the thread observes it, so a
process that was not scheduled, or a host that slept, is never mistaken for a wedge.
The existing service manager restarts the daemon; running commands are then stopped
and requeued as after any daemon crash. This check is independent of the ownership
watchdog and does not change its report-only cleanup policy.

What this check does not tell apart or does not see:

- A single operation that holds the service lock for the whole 30 seconds without
  reaching a next step, such as one very large directory removal on a stalled disk, is
  indistinguishable from a deadlock and still ends the daemon. The stop reason names
  the holder and its step.
- Lock activity includes other clients' requests and `wait` polls. A dead accept path
  with a client still attached is therefore found by the five-minute rule, not the
  30-second one.
- A tick thread stuck outside the lock while status still answers is not detected. The
  liveness messages report when a tick last finished; that alone never exits the daemon.

Only two things stop a running daemon by its own decision: that wedge, and losing the
daemon lease to another daemon. A failed tick is logged and retried, including a
process table that could not be read and a cleanup that could not be confirmed yet.

Every stop leaves its reason behind. The last line of the daemon log is written
straight to the file and flushed, after the stdout pipe has been drained; a line
written to a pipe just before `_exit` is otherwise lost. `last-stop.json` in the state
directory holds the epoch, PID, time, exit status and reason, and needs neither the
service lock nor the database. The audit log gets a `daemon_stopped` entry, which also
appears in `events.jsonl`. A wedged daemon cannot write that entry, so the next daemon
writes it from `last-stop.json` at startup. A daemon that lost its lease writes only
its log line and `last-stop.json`: the database and `events.jsonl` belong to the other
daemon by then. A previous daemon that left no record at all (killed, crashed, power
loss) is logged and audited as `daemon_exit_unrecorded` with the age of its last
heartbeat. A wedged daemon records its reason under a five-second hard deadline, so a
stalled disk cannot keep it alive.

Each start after anything but a requested stop is audited as
`daemon_unplanned_restart`. While five of them fall inside the last 15 minutes,
admissions are held (`restart_loop`) and health is `degraded`. The hold lifts by itself
when the oldest ages out of the window, and `simq resume` lifts it sooner; see
[recovery](PROTOCOL.md#recovery).

The `simq doctor` client also reports `socket_round_trip` latency, `daemon_threads`
and `daemon_zombies`. When the socket fails, it inspects the persisted daemon PID;
these process counts are a diagnostic snapshot, not proof that a stale PID is still the
original daemon.


There is no historical stats/top view, external alert delivery or webhooks. Clock, resource, simulator, process and filesystem interfaces are injectable so deterministic tests can exercise timeouts, crashes and interleavings. Fakes establish those contracts; they do not establish real simulator throughput or a clean installation.

## History and log bounds

| Data | Policy |
| --- | --- |
| Daemon stdout/stderr | Active writer rotates four 5 MiB segments (20 MiB); service external sinks are `/dev/null` |
| `events.jsonl` | Rotate at a 64 MiB threshold, keeping one previous generation; a batch can overshoot the threshold |
| `last-stop.json` | One record, replaced at each daemon stop |
| Database history targets | 10,000 completed job rows; 100,000 eligible audit rows or 30-day audit age |
| History snapshots | At most three self-contained 512 MiB archives, plus one bounded partial copy |
| Submission backpressure | Refuse new submissions above 256 MiB of used database pages; cleanup/recovery remain writable |

A single hourly maintenance worker first makes an online SQLite backup, checks integrity, syncs the file, durably renames it and syncs the directory. Only then may a connection-scoped authorization guard permit pruning in an atomic transaction. Normal audit UPDATE/DELETE remains forbidden. A backup retry deadline is 30 seconds; bounded prune batches have a two-second SQLite instruction deadline. That SQL deadline cannot bound an arbitrarily stalled filesystem/fsync.

A pass scans at most 1,000 job and 1,000 old-health candidates, removes at most 10,000 eligible audits/released pool resources, and uses cursors so protected early rows do not starve later history. Active jobs/resources, pending intents, pins, retained artifacts and their required metadata remain protected. Recent cleanup-accounting events and current anomaly/breaker state also survive retention. A failed copy/prune leaves live history intact; the next exclusively locked pass cleans interrupted partial copies.

Targets and the 256 MiB high-water mark are not hard filesystem quotas. Protected state and recent high churn can exceed them. Free SQLite pages are reused; older databases may retain their allocated file size until an intentionally drained, backed-up `VACUUM`. Archives rotate and are not permanent backups. Job output/artifacts have separate retention and are outside the daemon-log bound. See [installation](INSTALL.md) before exporting, compacting or purging state.

## Artifact cleanup

Artifact retention runs on one background worker shared with manual `simq gc` requests.
Planning and ownership rechecks use the service lock; recursive sizing and removal run outside
it so large build directories do not block job supervision. An automatic pass removes at most
20 candidates, honoring a lower configured cap. It rechecks cleanup mode, breaker state,
terminal job/process ownership and pins before each removal. In-flight deletion intents stay
protected from recovery until the worker finishes; planned drain and shutdown wait for it.

Use the supplied top-level DerivedData directory for disposable compiler/tool output.
Configure an artifact size budget and retention periods for the host's workload; retained
artifacts have separate bounds from the database, daemon logs and history archives.
