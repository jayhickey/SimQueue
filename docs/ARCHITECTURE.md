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

Production admits at most one command per pass, at least one second apart, and limits simultaneous commands to the host’s active core count. RAM-derived simulator limits and explicit host settings separately bound the pool. One project has no default execution cap; `max_running_per_project` optionally adds one. `--exclusive` uses its own configured exclusive slots rather than bypassing resource gates. The default backlog is 128 queued jobs per submitter/project and 1024 globally; queue-full rejection is actionable, and a deduplicated submission can attach to existing nonterminal work.

Admissions stop on memory pressure, insufficient reserve/headroom, excessive swap growth, thermal pressure, insufficient disk space or the load policy. Stable historical swap above 3 GiB alone does not stop an otherwise healthy host. A failed probe holds admissions rather than substituting an optimistic reading. These are admission controls: unrelated applications can change the host after a sample, and SimQueue does not impose an operating-system resource quota on arbitrary commands.

### Load recovery

By default, entry occurs when five-minute load exceeds 3 × active cores, or one-minute load exceeds 3 × cores while five-minute load exceeds 1.5 × cores. A recovered one-minute load at or below 2 × cores suppresses those historical gates. On a ten-core Mac that recovery threshold is 20, so a previous boot spike need not keep admissions waiting for the entire five-minute average to decay.

The existing `host.throttle_clear_load5_per_core` factor supplies both short-average recovery and historical hysteresis. Above its one-minute threshold, the original entry rules remain, and a prior hold persists until entry rules stop and five-minute load clears that threshold. Optional `max_load5` and `resume_below_load5` always take precedence, including during recovery. Default recovery applies on every pass, so stale five-minute history cannot toggle the hold solely because its persisted state changed.

Boots have an additional one-minute load gate, normally 2 × cores. Memory, pressure, swap, thermal and disk gates still apply after load recovery. Load averages are not instantaneous CPU utilization; an idle-looking CPU sample alone does not bypass these checks.

### Ordering and backfill

Jobs are ordered by integer priority (0–100), a configurable capped aging boost and FIFO ties. Aging does not promise eventual service across an arbitrary priority gap. A blocked job reserves the memory/simulator capacity it needs, allowing fitting work to use other capacity. For example, a simulator waiter can permit a simulator-free build, while a memory-constrained large job keeps accumulating headroom instead of losing it to repeated smaller starts. Impossible requests and project-limited jobs do not reserve shared resources.

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

After a restart, proven-unstarted work can requeue under a bounded restart policy. A started non-retryable command is interrupted rather than replayed; explicitly retryable work obeys both retry and restart bounds. An uncertain start reports uncertainty and retains resources when absence cannot be proved. Killing an old process avoids concurrent copies but cannot undo side effects. SimQueue does not guarantee exactly-once command execution or survival across abrupt restarts.

A waiting client reconnects to the same job; reconnect is separate from command recovery. Planned upgrades first drain admitted work, process groups, simulator leases, pending intents and template/pool/preparation/archive/artifact workers. A drain timeout leaves its gate set and does not authorize a restart. Live destructive uninstall also requires completed drain, refuses unresolved processes/intents even with force, and re-reads ownership after stop. See [installation](INSTALL.md) for consistent backups, legacy-state transitions and matching-backup rollback. Unfinished legacy shard groups are refused before database migration or writer journal changes.

## Reconciliation and health

The watchdog runs light health checks and periodic full ownership reconciliation. It reports current anomalies, verified cleanup outcomes and circuit-breaker state through local status/doctor output. Cleanup is namespace/ownership/identity checked, verified and rate limited; its default report-only mode does not authorize destructive orphan cleanup. Templates have a separate explicit removal path and are not ordinary pool garbage.

There is no historical stats/top view, external alert delivery or webhooks. Clock, resource, simulator, process and filesystem interfaces are injectable so deterministic tests can exercise timeouts, crashes and interleavings. Fakes establish those contracts; they do not establish real simulator throughput or a clean installation.

## History and log bounds

| Data | Policy |
| --- | --- |
| Daemon stdout/stderr | Active writer rotates four 5 MiB segments (20 MiB); service external sinks are `/dev/null` |
| `events.jsonl` | Rotate at a 64 MiB threshold, keeping one previous generation; a batch can overshoot the threshold |
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
