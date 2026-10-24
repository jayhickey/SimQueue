// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import SimQueueCore
import SimQueueDaemon
import SimQueueIPC
import SimQueueMCP
import SimQueueProtocol

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

@main
struct SimQ: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "simq",
        abstract: "Queue and inspect jobs on this Mac's SimQueue daemon.",
        discussion: """
            Builds: simq run --sims 0 -- swift build -j 4
            Whole simulator suites: simq run --sims 1 -- ./run-tests.sh
            Coding agents: read simq agent-guide for version-matched offline instructions.
            Full installed documentation: simq docs

            Exit codes: 0 success, 1 test or command failure, 2 build failure, 3 timed out (run timeout),
            4 infra failure, 5 canceled, 6 expired (queue timeout), 7 --wait-timeout ran out,
            64 usage, 65 protocol error, 66 unknown job, 69 daemon unavailable, 70 internal,
            73 queue full. `simq doctor` exits 0 healthy, 1 warnings, 2 unhealthy.
            """,
        version: SimQueueVersion.current,
        subcommands: [
            Submit.self, Run.self, OutputHoldCommand.self, Status.self, Jobs.self, Explain.self, Logs.self, Cancel.self,
            Bump.self, Wait.self,
            Doctor.self,
            OwnedUDIDs.self, Lease.self, Project.self, Template.self, LegacyGolden.self, MCP.self,
            Dashboard.self, Init.self, Uninstall.self, Drain.self, Resume.self, GC.self, AgentGuide.self, Docs.self,
        ]
    )
}

// MARK: - Shared

struct Connection: ParsableArguments {
    @Option(help: "State directory. Default: $SIMQ_STATE_DIR or the platform default.")
    var stateDir: String?

    @Flag(help: "Print machine-readable JSON (stable, snake_case).")
    var json = false

    var paths: SimQueuePaths { SimQueuePaths.resolve(explicit: stateDir) }

    func client(timeout: Double = 10) -> SimQueueClient {
        SimQueueClient(socketPath: paths.socketPath, timeoutSeconds: timeout)
    }
}

extension JobState: ExpressibleByArgument {}

func failure(_ code: SimQExitCode) -> ExitCode { ExitCode(code.rawValue) }

/// Seconds a request waits for the daemon's answer: 10, or `$SIMQ_REQUEST_TIMEOUT_SECONDS`
/// (a positive number; tests use a short one).
let requestTimeoutSeconds: Double = {
    guard let text = ProcessInfo.processInfo.environment["SIMQ_REQUEST_TIMEOUT_SECONDS"],
        let value = Double(text), value > 0
    else { return 10 }
    return value
}()

/// How long a client keeps reconnecting to a daemon that went away (a planned drain and
/// restart, a crash): 10 minutes, or `$SIMQ_RECONNECT_SECONDS` (0 turns reconnecting off).
/// The window restarts each time the daemon answers again.
let daemonReconnectSeconds: Double = {
    guard let text = ProcessInfo.processInfo.environment["SIMQ_RECONNECT_SECONDS"],
        let value = Double(text), value.isFinite, value >= 0
    else { return 600 }
    return value
}()

func printError(_ message: String) {
    FileHandle.standardError.write(Data("simq: \(message)\n".utf8))
}

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(value))
    FileHandle.standardOutput.write(Data("\n".utf8))
}

/// Parses `--timeout` / `--queue-timeout`: a duration ("90", "90s", "10m", "1h30m") or
/// "none" (sent as 0 = no limit).
func parseTimeout(_ text: String?, flag: String) throws -> Double? {
    guard let text else { return nil }
    if ["none", "never", "0"].contains(text.lowercased()) {
        return 0
    }
    guard let seconds = DurationParser.seconds(text), seconds > 0 else {
        throw ValidationError("\(flag) takes a duration like 90s, 10m or 1h30m, or \"none\"")
    }
    return seconds
}

/// Sends one request; maps transport failures and error responses to exit codes.
/// With `retryTimeoutsUntil`, a request that times out (a daemon busy for a moment) is sent
/// again until that time instead of failing; only for requests that are safe to repeat.
///
/// With `reconnect`, a daemon that goes away (drain and restart, crash) is retried with
/// backoff for `daemonReconnectSeconds`. Any request retries a failed connect, since nothing
/// was sent. Only observations of an existing job (`wait`, `logs`, `explain`) also retry
/// after an ambiguous disconnect or an unanswered request. A `wait` first re-reads the job
/// (a short `explain`) to prove the new daemon answers and still has it, then waits again
/// with no recovery deadline: a requeued job can wait in the queue as long as it needs.
/// `stopRetrying` ends the retries early (a signal).
func call(
    _ connection: Connection, _ params: RequestParams, timeout: Double = requestTimeoutSeconds,
    deadline: Double? = nil, retryTimeoutsUntil: Date? = nil, reconnect: Bool = false,
    onEvent: (JobInfo) -> Bool = { _ in true }, stopRetrying: () -> Bool = { false }
) throws -> ResultPayload {
    var response: Response?
    var notedBusy = false
    var reconnectUntil: Date?
    var backoff = 0.2
    var triedAutoStart = false
    let observingJob: Bool
    switch params {
    case .wait, .logs, .explain: observingJob = true
    default: observingJob = false
    }
    while true {
        let now = Date()
        if let deadline, now.timeIntervalSince1970 >= deadline { throw failure(.waitTimeout) }
        // While reconnecting, every attempt fits the reconnect window. The caller's absolute
        // wait deadline always takes precedence.
        let attemptDeadline = [deadline, reconnectUntil?.timeIntervalSince1970].compactMap { $0 }.min()
        do {
            if reconnectUntil != nil, case .wait(let wait) = params {
                let probe = try connection.client(timeout: requestTimeoutSeconds).send(
                    Request(params: .explain(JobRef(jobID: wait.jobID))), deadline: attemptDeadline)
                if let probe, case .error = probe.body {
                    response = probe
                    break
                }
                if !connection.json { printError("reconnected; still waiting on \(wait.jobID)") }
                reconnectUntil = nil
                backoff = 0.2
                continue
            }
            do {
                response = try connection.client(timeout: timeout).send(
                    Request(params: params), deadline: attemptDeadline, onEvent: onEvent)
            } catch let error as SocketError where AutoStart.isNoDaemon(error) && !triedAutoStart {
                // Nothing was sent (the connect failed), so one retry after a start is safe.
                triedAutoStart = true
                switch AutoStart.ensureDaemon(paths: connection.paths) {
                case .disabled: throw error
                case .failed(let why):
                    printError(why)
                    throw error
                case .ready:
                    response = try connection.client(timeout: timeout).send(
                        Request(params: params), deadline: attemptDeadline, onEvent: onEvent)
                }
            }
            break
        } catch SocketError.timedOut where deadline.map({ Date().timeIntervalSince1970 >= $0 }) == true {
            throw failure(.waitTimeout)
        } catch SocketError.timedOut where retryTimeoutsUntil.map({ Date() < $0 }) == true {
            if !notedBusy, !connection.json {
                printError(
                    "daemon busy (no answer in \(timeout == timeout.rounded() ? "\(Int(timeout))" : "\(timeout)") s); retrying"
                )
            }
            notedBusy = true
        } catch let error as SocketError {
            // Never replay a submit or another mutation after an ambiguous disconnect: only a
            // failed connect (nothing sent) or an observation of an existing job is retried.
            if reconnect, daemonReconnectSeconds > 0, !stopRetrying(),
                AutoStart.isNoDaemon(error) || (observingJob && isObservationInterruption(error))
            {
                let now = Date()
                if reconnectUntil == nil {
                    reconnectUntil = now.addingTimeInterval(daemonReconnectSeconds)
                    if !connection.json {
                        printError(
                            "daemon busy or disconnected (\(error)); reconnecting for up to \(Int(daemonReconnectSeconds)) s"
                        )
                    }
                }
                if let deadline, now.timeIntervalSince1970 >= deadline { throw failure(.waitTimeout) }
                if let reconnectUntil, now < reconnectUntil {
                    Thread.sleep(forTimeInterval: min(backoff, reconnectUntil.timeIntervalSince(now)))
                    backoff = min(backoff * 2, 5)
                    continue
                }
                printError(
                    "daemon unavailable at \(connection.paths.socketPath): no answer for \(Int(daemonReconnectSeconds)) s (\(error))"
                )
                throw failure(.daemonUnavailable)
            }
            printError("daemon unavailable at \(connection.paths.socketPath): \(error)")
            throw failure(.daemonUnavailable)
        }
    }
    guard let response else {
        throw failure(.waitTimeout)
    }
    switch response.body {
    case .result(let payload):
        return payload
    case .error(let protocolError):
        if connection.json {
            try printJSON(["error": protocolError])
        } else {
            printError("\(protocolError.code.rawValue): \(protocolError.message)")
        }
        throw failure(protocolError.code.exitCode)
    case .event:
        printError("unexpected event")
        throw failure(.protocolError)
    }
}

/// Observing an existing job can safely retry an unanswered request or a disconnected
/// socket. Permission, ownership, framing and protocol errors are never retried.
func isObservationInterruption(_ error: SocketError) -> Bool {
    switch error {
    case .closed, .timedOut: return true
    case .system(let call, let code):
        if call == "connect" { return code == ENOENT || code == ECONNREFUSED }
        return code == ECONNRESET || code == EPIPE || code == ENOTCONN
    default: return false
    }
}

/// One job: a summary line, then indented details. `times` adds when it was queued and
/// when it started (local time, `-` before the start), for `simq jobs` and `simq explain`.
func describe(_ job: JobInfo, times: Bool = false) -> String {
    var parts = [
        "\(job.id)", job.state.rawValue, "p\(job.priority)", job.kind.isEmpty ? "-" : job.kind, "\(job.project)",
    ]
    if times {
        parts.append("queued at \(Timestamp.shortLocalOrDash(job.queueTime))")
        parts.append("started at \(Timestamp.shortLocalOrDash(job.startedAt))")
    }
    if job.exclusive { parts.append("exclusive") }
    if job.retryable { parts.append("retryable") }
    if let position = job.position { parts.append("#\(position)") }
    if let result = job.resultClass { parts.append(result.rawValue) }
    if let code = job.commandExitCode { parts.append("command exit \(code)") }
    var line = parts.joined(separator: "  ")
    if !job.waitReasons.isEmpty {
        line += "\n    waiting: " + job.waitReasons.map(\.summary).joined(separator: "; ")
    }
    if let message = job.message { line += "\n    \(message)" }
    line += describeArtifacts(job, indent: "    ")
    return line
}

/// The run directory listing, one line per entry (empty when there is none).
func describeArtifacts(_ job: JobInfo, indent: String) -> String {
    guard let artifacts = job.artifacts, !artifacts.isEmpty, let runDir = job.runDir else { return "" }
    var text = "\n\(indent)artifacts in \(runDir):"
    for artifact in artifacts {
        text += "\n\(indent)  \(artifact.path)  \(artifact.bytes) B  \(artifact.type)"
    }
    if job.artifactsTruncated == true { text += "\n\(indent)  (more not listed)" }
    return text
}

/// Waits for a job to finish (or be admitted) and returns its final view.
func waitFor(
    _ jobID: String, connection: Connection, stream: Bool, untilAdmitted: Bool, waitTimeout: Double?
) throws -> JobInfo {
    let deadline = waitTimeout.map { Date().timeIntervalSince1970 + $0 }
    let payload = try call(
        connection, .wait(WaitParams(jobID: jobID, stream: stream, untilAdmitted: untilAdmitted)), timeout: 0,
        deadline: deadline, reconnect: true
    ) { event in
        if connection.json {
            try? printJSON(["event": event])
        } else {
            print(describe(event))
        }
        return true
    }
    guard case .job(let job) = payload else { throw failure(.protocolError) }
    return job
}

func finish(_ job: JobInfo, connection: Connection, untilAdmitted: Bool) throws {
    if connection.json { try printJSON(job) } else { print(describe(job)) }
    if job.state.isTerminal {
        let code = job.exitCode
        if code != .success { throw failure(code) }
    } else if !untilAdmitted {
        throw failure(.internalError)
    }
}

// MARK: - Commands

struct Submit: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Queue a job.",
        discussion: """
            Priority is an integer 0...100 (higher runs first, default 50) or an alias defined
            in the daemon's config. Equal priorities run in submission order; waiting jobs
            slowly gain priority within a capped boost; large priority gaps can still starve.
            --timeout limits run time from job start (default: no limit). --queue-timeout limits
            the wait before the job's first start (default: 24h). Pass "none" for no limit.
            --kind is a free-form label for status and logs; it changes nothing. Behavior comes
            from flags: --exclusive (run one at a time in the exclusive slot), --retryable
            (retry after an infra failure), --sims. Started non-retryable commands are interrupted after a daemon restart.
            The command goes after --, e.g. `simq submit --kind lint -- make lint`. It runs in
            its own process group in the current directory (or --cwd) with the daemon's
            environment plus any --env NAME=VALUE and SIMQ_JOB_ID, SIMQ_ATTEMPT, SIMQ_PROJECT,
            SIMQ_KIND, SIMQ_SIMS, SIMQ_RUN_DIR, SIMQ_UDID, SIMQ_SIM_UDIDS, SIMQ_DERIVED_DATA and
            SIMQ_RESULT_BUNDLE (see `simq run`).
            A non-zero exit ends the job failed
            (command_failure, exit 1); its own status is in command_exit_code. Output:
            `simq logs <job>`.
            """
    )

    @OptionGroup var connection: Connection
    @Option(help: "Project name. Default: the current directory's name.") var project: String?
    @Option(help: "Free-form label for status and logs (no behavior), e.g. lint or \"Quotify PR #134 · Unit tests\".")
    var kind: String?
    @Option(help: "Priority 0...100, or a configured alias.") var priority: String?
    @Option(help: "Named host template (from host_templates).") var template: String?
    @Option(help: "Who is submitting. Default: $USER.") var submitter: String?
    @Option(help: "While a job with this key is queued or running, return it instead of queuing another.")
    var dedupeKey: String?
    @Option(help: "Simulators to lease (default 0).") var sims = 0
    @Option(help: "Use up to this many simulators when free (at least --sims).") var maxSims: Int?
    @Flag(help: "Take the exclusive slot: exclusive jobs run one at a time.") var exclusive = false
    @Flag(
        help:
            "Retry automatically after an infra failure. (Started commands replay only with explicit retry permission.)"
    )
    var retryable = false
    @Option(help: "Infra retries for a retryable job, 0...10 (implies --retryable). Default: daemon config (1).")
    var retries: Int?
    @Option(
        name: .customLong("memory-hint-mib"),
        help:
            "Optional scheduling estimate in MiB, not a memory limit or RAM reservation. Omitted: 512 MiB minimum accounting."
    )
    var memoryMib: UInt64 = 0
    @Option(help: "Memory per granted simulator, in MiB.") var memoryPerSimMib: UInt64 = 0
    @Option(help: "Run timeout from job start, e.g. 30m, or none.") var timeout: String?
    @Option(help: "Queue timeout before first start, e.g. 2h, or none.") var queueTimeout: String?
    @Option(help: "Job-specific payload (JSON).") var payload: String?
    @Option(help: "Worktree path.") var worktree: String?
    @Option(help: "Commit that must be checked out in --worktree (or --cwd); checked at submit and at start.")
    var gitSha: String?
    @Flag(help: "Wait for the job to finish; exit with its result.") var wait = false
    @Flag(help: "With --wait, print each state or position change.") var stream = false
    @Option(help: "With --wait, stop waiting after this long (exit 7). The job keeps its place.")
    var waitTimeout: String?
    @Option(name: .customLong("env"), help: "Environment for the command, NAME=VALUE (repeatable).")
    var environment: [String] = []
    @Option(
        name: .customLong("env-from"),
        help: "Forward this caller variable by name (repeatable); missing or SIMQ_* names fail.")
    var environmentFrom: [String] = []
    @Option(help: "Working directory for the command. Default: the current directory.") var cwd: String?
    @Option(
        name: .customLong("reset-app"),
        help: "Before the command, reset this app on each leased sim: uninstall, privacy reset (repeatable).")
    var resetApps: [String] = []
    @Flag(help: "Before the command, erase each leased sim (slower; use when app resets aren't enough).")
    var freshSim = false
    @Flag(
        help: "Pin the job's artifacts: kept 90 days (artifact_retention_days.kept), never removed for the size budget."
    )
    var keep = false
    @Option(help: "Atomically attach job output to an active output-hold UUID (requires daemon support).")
    var outputHold: String?
    @Argument(parsing: .postTerminator, help: "The command to run, after --.") var command: [String] = []

    /// `--env` pairs as a dictionary (later pairs win).
    func environmentPairs() throws -> [String: String] { try selectedEnvironment(environment, names: environmentFrom) }

    func validate() throws {
        if let outputHold { _ = try validatedOutputHoldID(outputHold) }
        guard memoryMib <= UInt64.max / ByteSize.mebibyte,
            memoryPerSimMib <= UInt64.max / ByteSize.mebibyte
        else { throw ValidationError("memory hints are too large") }
        guard sims >= 0 else { throw ValidationError("--sims must be >= 0") }
        if command.isEmpty, !environment.isEmpty || cwd != nil {
            throw ValidationError("--env and --cwd need a command after --")
        }
        _ = try environmentPairs()
        if let maxSims, maxSims < sims { throw ValidationError("--max-sims must be >= --sims") }
        if let retries, !(0...10).contains(retries) { throw ValidationError("--retries must be 0...10") }
    }

    func run() throws {
        let runTimeout = try parseTimeout(timeout, flag: "--timeout")
        let queueLimit = try parseTimeout(queueTimeout, flag: "--queue-timeout")
        let clientWait = try waitTimeout.map { text -> Double in
            guard let seconds = DurationParser.seconds(text), seconds > 0 else {
                throw ValidationError("--wait-timeout takes a duration like 10m")
            }
            return seconds
        }
        var numeric: Int?
        var name: String?
        if let priority {
            if let value = Int(priority) {
                guard Priority.isValid(value) else { throw ValidationError("--priority must be 0...100") }
                numeric = value
            } else {
                name = priority
            }
        }
        let params = SubmitParams(
            project: project ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).lastPathComponent,
            kind: kind,
            template: template,
            priority: numeric,
            priorityName: name,
            submitter: submitter ?? ProcessInfo.processInfo.environment["USER"] ?? "unknown",
            worktree: worktree,
            gitSHA: gitSha,
            dedupeKey: dedupeKey,
            minSims: sims,
            maxSims: maxSims,
            memoryBytes: memoryMib * ByteSize.mebibyte,
            memoryBytesPerSim: memoryPerSimMib * ByteSize.mebibyte,
            exclusive: exclusive ? true : nil,
            retryable: retryable ? true : nil,
            maxRetries: retries,
            runTimeoutSeconds: runTimeout,
            queueTimeoutSeconds: queueLimit,
            payloadJSON: payload,
            command: command.isEmpty ? nil : command,
            environment: command.isEmpty ? nil : try environmentPairs(),
            cwd: command.isEmpty ? nil : Self.absolute(cwd ?? FileManager.default.currentDirectoryPath),
            resetApps: resetApps.isEmpty ? nil : resetApps,
            freshSim: freshSim ? true : nil,
            keep: keep ? true : nil
        )
        let response = try submitJob(params, outputHold: outputHold, connection: connection)
        guard wait else {
            if connection.json {
                try printJSON(response)
            } else {
                print((response.deduplicated ? "existing " : "queued ") + describe(response.job))
            }
            return
        }
        if !connection.json {
            print((response.deduplicated ? "existing " : "queued ") + describe(response.job))
        }
        let job = try waitFor(
            response.job.id, connection: connection, stream: stream, untilAdmitted: false, waitTimeout: clientWait)
        try finish(job, connection: connection, untilAdmitted: false)
    }
}

extension Submit {
    static func absolute(_ path: String) -> String {
        let url =
            path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(path)
        return url.standardizedFileURL.path
    }
}

struct Logs: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print a job's output (stdout and stderr together).",
        discussion: """
            Prints what the job's command has written so far. --follow keeps printing until the
            job ends. With --json, each chunk is one JSON object per line (offset, next_offset,
            data, at_end, job_finished).
            """
    )
    @OptionGroup var connection: Connection
    @Argument var jobID: String
    @Flag(name: [.short, .long], help: "Keep printing new output until the job ends.") var follow = false
    @Option(help: "Start at this byte offset.") var offset: Int64 = 0

    func run() throws {
        var position = offset
        while true {
            guard case .logs(let chunk) = try call(connection, .logs(LogsParams(jobID: jobID, offset: position))) else {
                throw failure(.protocolError)
            }
            if connection.json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                FileHandle.standardOutput.write(try encoder.encode(chunk) + Data("\n".utf8))
            } else if !chunk.data.isEmpty {
                FileHandle.standardOutput.write(Data(chunk.data.utf8))
            }
            position = chunk.nextOffset
            if !chunk.atEnd { continue }
            if !follow || chunk.jobFinished { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show daemon and queue status.")
    @OptionGroup var connection: Connection

    func run() throws {
        guard case .status(let status) = try call(connection, .status) else { throw failure(.protocolError) }
        if connection.json { return try printJSON(status) }
        if let health = status.health { print(health.line(now: Date().timeIntervalSince1970)) }
        print(
            "simqd \(status.daemon.version) pid \(status.daemon.pid) epoch \(status.daemon.epoch) (\(status.daemon.backend))"
        )
        let client = SimQueueVersion.current
        print("simq \(client)\(client == status.daemon.version ? "" : " (differs from simqd; restart simqd)")")
        print("queued \(status.queued)  admitted \(status.admitted)  running \(status.running)")
        if let storage = status.storage {
            print("state: \(storage.stateDirectory)")
            print("job output: \(storage.jobOutputRoot) (\(storage.failure ?? "available, writable"))")
            if let free = storage.freeBytes { print("job output free bytes: \(free)") }
        }
        if let hint = status.templateHint { print("template: \(hint)") }
        var flags: [String] = []
        if status.paused { flags.append("paused") }
        if status.draining { flags.append("draining") }
        if status.loadThrottled { flags.append("load-throttled") }
        if !flags.isEmpty { print("state: " + flags.joined(separator: ", ")) }
        for reason in status.globalWaitReasons { print("blocked: \(reason.summary)") }
    }
}

struct Jobs: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List jobs, newest first.")
    @OptionGroup var connection: Connection
    @Option(name: .customLong("state"), help: "Only these states (repeatable).") var states: [JobState] = []
    @Option(help: "Only this project.") var project: String?
    @Option(help: "Maximum rows.") var limit = 50

    func run() throws {
        let params = JobsParams(states: states.isEmpty ? nil : states, project: project, limit: limit)
        guard case .jobs(let jobs) = try call(connection, .jobs(params)) else { throw failure(.protocolError) }
        if connection.json { return try printJSON(jobs) }
        if jobs.isEmpty { print("no jobs") }
        for job in jobs { print(describe(job, times: true)) }
    }
}

struct Explain: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show a job and why it is waiting.")
    @OptionGroup var connection: Connection
    @Argument var jobID: String

    func run() throws {
        guard case .job(let job) = try call(connection, .explain(JobRef(jobID: jobID))) else {
            throw failure(.protocolError)
        }
        if connection.json { return try printJSON(job) }
        print(describe(job, times: true))
        if let score = job.effectiveScore { print(String(format: "    effective score %.2f", score)) }
        if let deadline = job.queueDeadlineAt {
            print("    expires unstarted at \(deadline.rfc3339)")
        }
        if let deadline = job.runDeadlineAt { print("    run deadline \(deadline.rfc3339)") }
    }
}

struct Cancel: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Cancel a queued or running job.")
    @OptionGroup var connection: Connection
    @Argument var jobID: String

    func run() throws {
        guard case .job(let job) = try call(connection, .cancel(CancelParams(jobID: jobID))) else {
            throw failure(.protocolError)
        }
        if connection.json { try printJSON(job) } else { print(describe(job)) }
    }
}

struct Wait: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Wait for a job; exit with its result.")
    @OptionGroup var connection: Connection
    @Argument var jobID: String
    @Flag(help: "Print each state or position change.") var stream = false
    @Flag(help: "Return once the job is admitted instead of finished.") var untilAdmitted = false
    @Option(help: "Stop waiting after this long (exit 7). The job is not changed.") var waitTimeout: String?

    func run() throws {
        let clientWait = try waitTimeout.map { text -> Double in
            guard let seconds = DurationParser.seconds(text), seconds > 0 else {
                throw ValidationError("--wait-timeout takes a duration like 10m")
            }
            return seconds
        }
        let job = try waitFor(
            jobID, connection: connection, stream: stream, untilAdmitted: untilAdmitted, waitTimeout: clientWait)
        try finish(job, connection: connection, untilAdmitted: untilAdmitted)
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Read-only health report. Works without the daemon (reads the state file).")
    @OptionGroup var connection: Connection

    func run() throws {
        var report: DoctorReport
        do {
            let response = try connection.client(timeout: 5).send(Request(params: .doctor))
            guard case .result(.doctor(let online))? = response?.body else { throw SocketError.closed }
            report = online
        } catch {
            guard FileManager.default.fileExists(atPath: connection.paths.databasePath) else {
                printError("daemon unavailable and no state file at \(connection.paths.databasePath)")
                throw failure(.daemonUnavailable)
            }
            do {
                report = try DoctorBuilder.offline(paths: connection.paths, now: Date().timeIntervalSince1970)
            } catch {
                printError("can't read state file: \(error)")
                throw ExitCode(2)
            }
        }
        report.checks.insert(.version(client: SimQueueVersion.current, daemon: report.daemon?.version), at: 0)
        if let simq = Bundle.main.executablePath,
            let appCLI = DoctorCheck.appCLI(runningSimq: simq, apps: DoctorCheck.installedApps())
        {
            report.checks.insert(appCLI, at: 1)
        }
        if connection.json {
            try printJSON(report)
        } else {
            for check in report.checks { print("\(check.level.rawValue.uppercased())  \(check.name): \(check.detail)") }
            print("owned sims: \(report.ownedUDIDs.count)")
            if let pool = report.pool {
                for sim in pool.sims {
                    let lease = sim.leaseID.map { " lease \($0)" } ?? ""
                    print(
                        "pool  \(sim.name) \(sim.udid) \(sim.phase) \(Int(sim.phaseSeconds))s\(lease)\(sim.tainted ? " unleased-user" : "")"
                    )
                }
                for hit in pool.recentSettleCapHits { print("settle_cap_hit  \(hit)") }
            }
        }
        if report.exitStatus != 0 { throw ExitCode(report.exitStatus) }
    }
}

struct OwnedUDIDs: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "owned-udids",
        abstract: "Print the simulator UDIDs SimQueue owns, one per line (read-only).",
        discussion:
            "Reads the state file directly, so it works whether or not the daemon runs. External reapers use it to leave these sims alone."
    )
    @OptionGroup var connection: Connection

    func run() throws {
        guard FileManager.default.fileExists(atPath: connection.paths.databasePath) else {
            // No state yet: SimQueue owns nothing.
            if connection.json { try printJSON(DoctorOwnership(ownedUDIDs: [])) }
            return
        }
        let report: DoctorReport
        do {
            report = try DoctorBuilder.offline(paths: connection.paths, now: Date().timeIntervalSince1970)
        } catch {
            printError("can't read state file: \(error)")
            throw failure(.internalError)
        }
        if connection.json {
            try printJSON(report.ownership)
        } else {
            for udid in report.ownedUDIDs { print(udid) }
        }
    }
}

struct Lease: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Lease a settled pool sim for work outside the queue (pool on only).",
        subcommands: [LeaseAcquire.self, LeaseRenew.self, LeaseRelease.self])
}

struct LeaseAcquire: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "acquire",
        abstract: "Wait until a pool sim has settled, lease it to --holder, and print it.",
        discussion: """
            The lease lasts only while its holder is live. By default the holder is this command's \
            parent process (the calling shell or script), or --pid. When that process is gone, the \
            watchdog reclaims the sim. With --pid 0 there is no holder process, so the lease needs \
            `simq lease renew` within the orphan grace (default 10 min). With --hold, this command \
            is the holder: it stays running, renews the lease, and releases it on SIGINT/SIGTERM. \
            Repeating with the same holder returns the sim it already holds. Exit 7 if \
            --wait-timeout runs out.
            """)
    @OptionGroup var connection: Connection
    @Option(help: "Who holds the lease (stable per caller; used to renew and release).") var holder: String
    @Option(help: "Holder process id (default: the parent process; 0 for heartbeat-only).") var pid: Int32?
    @Flag(help: "Keep running as the holder, renewing until interrupted, then release.") var hold = false
    @Option(help: "With --hold: seconds between renewals.") var renewSeconds: Double = 60
    @Option(help: "Stop waiting after this long (exit 7). Default 10m.") var waitTimeout: String = "10m"
    @Option(help: "Seconds between polls.") var pollSeconds: Double = 1

    func run() throws {
        guard let limit = DurationParser.seconds(waitTimeout), limit > 0 else {
            throw ValidationError("--wait-timeout takes a duration like 10m")
        }
        let holderPID: Int32? = hold ? getpid() : (pid ?? getppid()) == 0 ? nil : (pid ?? getppid())
        let deadline = Date().addingTimeInterval(limit)
        var lastState: String?
        var granted: LeaseResult?
        while granted == nil {
            guard
                // Repeating acquire for the same holder is safe (it returns the sim it holds).
                case .lease(let result) = try call(
                    connection, .leaseAcquire(LeaseAcquireParams(holder: holder, pid: holderPID)),
                    retryTimeoutsUntil: deadline)
            else { throw failure(.protocolError) }
            if result.state == "granted" {
                granted = result
                break
            }
            if !connection.json, result.poolState != lastState {
                printError("waiting for a pool sim (\(result.poolState ?? "waiting"))")
                lastState = result.poolState
            }
            if Date() >= deadline {
                printError("--wait-timeout ran out before a pool sim settled")
                throw failure(.waitTimeout)
            }
            Thread.sleep(forTimeInterval: max(0.05, pollSeconds))
        }
        guard let result = granted, let udid = result.udid else { throw failure(.protocolError) }
        if connection.json { try printJSON(result) } else { print("\(udid)  \(result.name ?? "")") }
        guard hold else { return }
        fflush(nil)
        try holdLease(udid: udid)
    }

    private func holdLease(udid: String) throws {
        let connection = self.connection
        let holder = self.holder
        let stop = DispatchSemaphore(value: 0)
        var sources: [DispatchSourceSignal] = []
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { stop.signal() }
            source.resume()
            sources.append(source)
        }
        while stop.wait(timeout: .now() + max(1, renewSeconds)) == .timedOut {
            do {
                _ = try call(
                    connection, .leaseRenew(LeaseReleaseParams(holder: holder, udid: udid)),
                    retryTimeoutsUntil: Date().addingTimeInterval(max(30, renewSeconds)))
            } catch {
                printError("lease renew failed; the lease may have been reclaimed")
                throw failure(.internalError)
            }
        }
        _ = try? call(connection, .leaseRelease(LeaseReleaseParams(holder: holder, udid: udid)))
        withExtendedLifetime(sources) {}
    }
}

struct LeaseRenew: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "renew", abstract: "Renew a held pool lease (its heartbeat).")
    @OptionGroup var connection: Connection
    @Option(help: "The holder that acquired it.") var holder: String
    @Argument var udid: String

    func run() throws {
        guard
            case .lease(let result) = try call(connection, .leaseRenew(LeaseReleaseParams(holder: holder, udid: udid)))
        else { throw failure(.protocolError) }
        if connection.json { try printJSON(result) } else { print("renewed \(result.udid ?? udid)") }
    }
}

struct LeaseRelease: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "release", abstract: "Return a leased pool sim to the pool.")
    @OptionGroup var connection: Connection
    @Option(help: "The holder that acquired it.") var holder: String
    @Argument var udid: String

    func run() throws {
        guard
            case .lease(let result) = try call(
                connection, .leaseRelease(LeaseReleaseParams(holder: holder, udid: udid)))
        else { throw failure(.protocolError) }
        if connection.json { try printJSON(result) } else { print("released \(result.udid ?? udid)") }
    }
}

struct MCP: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Run an MCP server on stdio over the daemon's socket (opt-in).",
        discussion: """
            Speaks the Model Context Protocol (JSON-RPC, one message per line) on stdin/stdout. \
            Tools: simq_submit, simq_status, simq_jobs, simq_explain, simq_cancel, simq_wait, simq_logs, \
            simq_lease_acquire, simq_lease_release, simq_doctor. Arguments and results use the socket \
            protocol's JSON. Pool leases taken here are held by this process and end with it.
            """)
    @Option(help: "State directory. Default: $SIMQ_STATE_DIR or the platform default.") var stateDir: String?
    @Option(help: "Default submitter for simq_submit (default: $SIMQ_SUBMITTER or mcp).") var submitter: String?

    func run() throws {
        let paths = SimQueuePaths.resolve(explicit: stateDir)
        let server = MCPServer(
            version: SimQueueVersion.current, holderPID: getpid(),
            defaultSubmitter: submitter ?? ProcessInfo.processInfo.environment["SIMQ_SUBMITTER"] ?? "mcp",
            transport: MCPServer.socketTransport(paths.socketPath))
        server.run()
    }
}
