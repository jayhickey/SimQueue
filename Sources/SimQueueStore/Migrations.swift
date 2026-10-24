// SPDX-License-Identifier: MIT

/// One schema step. Versions are consecutive, starting at 1.
public struct Migration: Sendable {
    public var version: Int32
    public var sql: String

    public init(version: Int32, sql: String) {
        self.version = version
        self.sql = sql
    }
}

/// Applies pending migrations in order, each in its own `BEGIN IMMEDIATE` transaction
/// together with its `PRAGMA user_version` bump. A database newer than the code is
/// refused rather than guessed at. (XCSteward has no migration mechanism; this adds one.)
public enum Migrator {
    public static func migrate(_ database: Database, migrations: [Migration] = SchemaMigrations.all) throws {
        let latest = migrations.map(\.version).max() ?? 0
        let current = try database.userVersion
        if current > latest {
            throw DatabaseError.schemaTooNew(found: current, supported: latest)
        }
        for migration in migrations.sorted(by: { $0.version < $1.version }) where migration.version > current {
            try database.immediateTransaction {
                // Re-check inside the write lock: another process may have migrated first.
                guard try database.userVersion < migration.version else {
                    return
                }
                try database.execute(migration.sql)
                try database.execute("PRAGMA user_version = \(migration.version);")
            }
        }
    }
}

/// The SimQueue schema history. Never edit a shipped migration; append a new one.
public enum SchemaMigrations {
    public static let latestVersion: Int32 = all.map(\.version).max() ?? 0

    public static let all: [Migration] = [
        Migration(
            version: 1,
            sql: """
                CREATE TABLE jobs (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    id TEXT NOT NULL UNIQUE,
                    project TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    priority_class TEXT NOT NULL,
                    submitter TEXT NOT NULL,
                    worktree TEXT,
                    git_sha TEXT,
                    request_key TEXT,
                    min_sims INTEGER NOT NULL DEFAULT 0,
                    max_sims INTEGER NOT NULL DEFAULT 0,
                    memory_bytes INTEGER NOT NULL DEFAULT 0,
                    memory_bytes_per_sim INTEGER NOT NULL DEFAULT 0,
                    run_timeout_seconds REAL,
                    parent_id TEXT REFERENCES jobs(id),
                    payload_json TEXT,
                    attempt INTEGER NOT NULL DEFAULT 0,
                    queue_time REAL NOT NULL,
                    created_at REAL NOT NULL,
                    admitted_at REAL,
                    started_at REAL,
                    finished_at REAL,
                    state TEXT NOT NULL,
                    result_class TEXT,
                    granted_sims INTEGER NOT NULL DEFAULT 0,
                    owner_pid INTEGER,
                    owner_epoch INTEGER,
                    fence_token INTEGER,
                    message TEXT
                );
                CREATE INDEX jobs_state_queue_idx ON jobs(state, queue_time, seq);
                CREATE INDEX jobs_project_submitter_idx ON jobs(project, submitter, state);
                CREATE UNIQUE INDEX jobs_active_request_key_idx ON jobs(request_key)
                    WHERE request_key IS NOT NULL AND state IN ('queued', 'admitted', 'running');
                CREATE INDEX jobs_infra_finished_idx ON jobs(result_class, finished_at);

                CREATE TABLE daemon_lease (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    owner_id TEXT NOT NULL,
                    pid INTEGER NOT NULL,
                    epoch INTEGER NOT NULL,
                    heartbeat REAL NOT NULL
                );

                -- Monotonic fencing-token source. Every grant takes the next value, so a
                -- holder with an older token (lost lease, restarted daemon) is rejected.
                CREATE TABLE fence_counter (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    value INTEGER NOT NULL
                );
                INSERT INTO fence_counter (singleton, value) VALUES (1, 0);

                CREATE TABLE queue_control (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    paused INTEGER NOT NULL DEFAULT 0,
                    drain_cleared_at REAL,
                    -- Load-throttle state, persisted so hysteresis survives a restart.
                    load_throttled INTEGER NOT NULL DEFAULT 0
                );
                INSERT INTO queue_control (singleton, paused) VALUES (1, 0);

                -- Append-only audit log: every state change, grant, release and cleanup.
                -- UPDATE and DELETE are rejected by triggers. Retention (rotation to an
                -- archive file) is a later, explicit migration, never an ad-hoc DELETE.
                CREATE TABLE audit_log (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    at REAL NOT NULL,
                    epoch INTEGER,
                    job_id TEXT,
                    resource_id INTEGER,
                    type TEXT NOT NULL,
                    detail TEXT
                );
                CREATE INDEX audit_log_job_idx ON audit_log(job_id, seq);
                CREATE INDEX audit_log_type_at_idx ON audit_log(type, at);
                CREATE TRIGGER audit_log_no_update BEFORE UPDATE ON audit_log
                    BEGIN SELECT RAISE(ABORT, 'audit_log is append-only'); END;
                CREATE TRIGGER audit_log_no_delete BEFORE DELETE ON audit_log
                    BEGIN SELECT RAISE(ABORT, 'audit_log is append-only'); END;

                -- Ownership ledger. One row per sim, process group, lease, run dir or
                -- DerivedData dir SimQueue creates. At most one live row per thing.
                CREATE TABLE owned_resources (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    kind TEXT NOT NULL,
                    external_id TEXT NOT NULL,
                    owner_job_id TEXT REFERENCES jobs(id),
                    owner_kind TEXT NOT NULL CHECK (owner_kind IN ('job', 'pool')),
                    epoch INTEGER NOT NULL,
                    generation INTEGER NOT NULL,
                    state TEXT NOT NULL CHECK (state IN ('active', 'orphaned', 'released')),
                    acquired_at REAL NOT NULL,
                    released_at REAL,
                    last_used_at REAL,
                    detail TEXT,
                    CHECK ((owner_kind = 'job') = (owner_job_id IS NOT NULL))
                );
                CREATE UNIQUE INDEX owned_resources_live_idx ON owned_resources(kind, external_id)
                    WHERE state != 'released';
                CREATE INDEX owned_resources_owner_idx ON owned_resources(owner_job_id, state);

                -- When each cleanup target first became a candidate, for the orphan grace
                -- period. Working state, not history (history is in audit_log).
                CREATE TABLE cleanup_sightings (
                    target_key TEXT PRIMARY KEY,
                    first_seen_at REAL NOT NULL,
                    reported INTEGER NOT NULL DEFAULT 0
                );

                CREATE TABLE explanations (
                    job_id TEXT PRIMARY KEY,
                    position INTEGER NOT NULL,
                    effective_score REAL NOT NULL,
                    reasons_json TEXT NOT NULL,
                    at REAL NOT NULL
                );
                """
        ),
        // v2: priority is a plain integer chosen by the caller (no named classes), and a
        // generic dedupe key replaces the request key. Existing rows get the neutral 50.
        // Adds queue timeouts and the persisted run-timeout kill schedule, plus the
        // sustained-anomaly tracker used by reconcile and the watchdog.
        Migration(
            version: 2,
            sql: """
                ALTER TABLE jobs ADD COLUMN priority INTEGER NOT NULL DEFAULT 50
                    CHECK (priority BETWEEN 0 AND 100);
                ALTER TABLE jobs DROP COLUMN priority_class;
                DROP INDEX jobs_active_request_key_idx;
                ALTER TABLE jobs RENAME COLUMN request_key TO dedupe_key;
                CREATE UNIQUE INDEX jobs_active_dedupe_key_idx ON jobs(dedupe_key)
                    WHERE dedupe_key IS NOT NULL AND state IN ('queued', 'admitted', 'running');
                ALTER TABLE jobs ADD COLUMN queue_timeout_seconds REAL;
                ALTER TABLE jobs ADD COLUMN term_sent_at REAL;
                ALTER TABLE jobs ADD COLUMN kill_sent_at REAL;

                CREATE TABLE anomalies (
                    target_key TEXT PRIMARY KEY,
                    detail TEXT NOT NULL,
                    first_seen_at REAL NOT NULL,
                    last_seen_at REAL NOT NULL,
                    consecutive_passes INTEGER NOT NULL,
                    clean_passes INTEGER NOT NULL DEFAULT 0,
                    level TEXT NOT NULL CHECK (level IN ('observed', 'sustained', 'needs_human'))
                );
                """
        ),
        // v3: `kind` becomes a free-form label with no behavior. Per-job flags replace
        // what kinds used to decide. Existing rows keep their kind text as a label and get
        // the flags their old kind implied (the only place the old names still appear):
        // the build slot became `exclusive`; requeue-after-restart and infra retry
        // became `retryable`.
        Migration(
            version: 3,
            sql: """
                ALTER TABLE jobs ADD COLUMN exclusive INTEGER NOT NULL DEFAULT 0 CHECK (exclusive IN (0, 1));
                ALTER TABLE jobs ADD COLUMN retryable INTEGER NOT NULL DEFAULT 0 CHECK (retryable IN (0, 1));
                ALTER TABLE jobs ADD COLUMN max_retries INTEGER
                    CHECK (max_retries IS NULL OR max_retries BETWEEN 0 AND 10);
                UPDATE jobs SET exclusive = 1 WHERE kind IN ('build', 'ui-test');
                UPDATE jobs SET retryable = 1
                    WHERE kind IN ('build', 'unit-test', 'ui-test', 'ui-test-shard', 'screenshots');
                """
        ),
        // v4: jobs can carry a command for the process executor (argv, environment and
        // working directory as JSON), and the command's own exit status once it ends.
        Migration(
            version: 4,
            sql: """
                ALTER TABLE jobs ADD COLUMN command_json TEXT;
                ALTER TABLE jobs ADD COLUMN command_exit_code INTEGER;
                """
        ),
        // v5: a process group row records its leader's identity (pid start time), so a
        // restarted daemon or reconcile can tell its own group from a reused pgid.
        Migration(
            version: 5,
            sql: """
                ALTER TABLE owned_resources ADD COLUMN identity TEXT;
                """
        ),
        // v6: watchdog passes. Audit entries carry the pass that wrote them; the watchdog
        // keeps its breaker and last-pass times in one row.
        Migration(
            version: 6,
            sql: """
                ALTER TABLE audit_log ADD COLUMN pass_id TEXT;
                CREATE TABLE watchdog_state (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    state_json TEXT NOT NULL,
                    updated_at REAL NOT NULL
                );
                """
        ),
        // v7: alerts, one row per stable alert key (history plus delivery state).
        Migration(
            version: 7,
            sql: """
                CREATE TABLE alerts (
                    alert_key TEXT PRIMARY KEY,
                    record_json TEXT NOT NULL,
                    last_seen_at REAL NOT NULL
                );
                """
        ),
        // v8: daily drift reports (the baseline is computed from earlier ones).
        Migration(
            version: 8,
            sql: """
                CREATE TABLE drift_reports (
                    report_date TEXT PRIMARY KEY,
                    report_json TEXT NOT NULL,
                    generated_at REAL NOT NULL
                );
                """
        ),
        // v9: write-ahead intents for destructive host actions. A row is written before
        // the action and removed, together with the action's audit entry, once it's
        // verified; a row left behind is reconciled by recovery.
        Migration(
            version: 9,
            sql: """
                CREATE TABLE action_intents (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    target_kind TEXT NOT NULL,
                    target TEXT NOT NULL,
                    audit_type TEXT NOT NULL,
                    detail TEXT NOT NULL,
                    job_id TEXT,
                    resource_id INTEGER,
                    release_reason TEXT,
                    created_at REAL NOT NULL,
                    pass_id TEXT
                );
                """
        ),
        // v10: the sim pool's own state per sim (phase, timers, lease, pre-warm, taint).
        // Ownership of the sim itself stays in owned_resources (owner pool).
        Migration(
            version: 10,
            sql: """
                CREATE TABLE pool_sims (
                    udid TEXT PRIMARY KEY,
                    sim_json TEXT NOT NULL
                );
                """
        ),
        // v11: shard groups. A job with children (`simq submit --shards`) is a group: it is
        // never scheduled itself and ends when its shards have all ended.
        Migration(
            version: 11,
            sql: """
                CREATE INDEX jobs_parent_idx ON jobs(parent_id) WHERE parent_id IS NOT NULL;
                """
        ),
        // v12: what the executor saw while a job ran: the pool sims it held (with the
        // template each was cloned from) and the sampled peak memory of its process group.
        Migration(
            version: 12,
            sql: """
                CREATE TABLE job_run_info (
                    job_id TEXT PRIMARY KEY REFERENCES jobs(id),
                    sims_json TEXT,
                    peak_rss_bytes INTEGER
                );
                """
        ),
        // v13: requeues after a daemon restart, counted apart from infra retries so they
        // never use up a job's `max_retries` and have their own cap.
        Migration(
            version: 13,
            sql: """
                ALTER TABLE jobs ADD COLUMN restart_requeues INTEGER NOT NULL DEFAULT 0;
                """
        ),
        Migration(
            version: 14,
            sql: """
                CREATE TABLE history_archive_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1), job_cursor INTEGER NOT NULL DEFAULT 0, alert_cursor TEXT NOT NULL DEFAULT '');
                INSERT INTO history_archive_state(singleton) VALUES(1);
                CREATE INDEX audit_log_resource_idx ON audit_log(resource_id,seq);
                CREATE INDEX action_intents_job_idx ON action_intents(job_id);
                CREATE INDEX action_intents_resource_idx ON action_intents(resource_id);
                DROP TRIGGER audit_log_no_delete;
                CREATE TRIGGER audit_log_no_delete BEFORE DELETE ON audit_log
                    WHEN simqueue_archive_allows(OLD.seq, OLD.at) != 1
                    BEGIN SELECT RAISE(ABORT, 'audit_log is append-only; verified archival required'); END;
                """),
        // v15: durable, explicitly released protection of job-owned output.
        Migration(
            version: 15,
            sql: """
                CREATE TABLE output_holds (
                    id TEXT PRIMARY KEY NOT NULL,
                    label TEXT NOT NULL CHECK(length(CAST(label AS BLOB)) BETWEEN 1 AND 256),
                    created_at REAL NOT NULL CHECK(created_at >= 0),
                    released_at REAL CHECK(released_at >= created_at)
                );
                CREATE TABLE output_hold_jobs (
                    hold_id TEXT NOT NULL REFERENCES output_holds(id) ON DELETE RESTRICT,
                    job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE RESTRICT,
                    attached_at REAL NOT NULL CHECK(attached_at >= 0),
                    PRIMARY KEY(hold_id,job_id)
                );
                CREATE INDEX output_hold_jobs_job_idx ON output_hold_jobs(job_id,hold_id);
                """),
    ]
}
