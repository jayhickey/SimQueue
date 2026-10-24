// SPDX-License-Identifier: MIT

import ArgumentParser
import Dispatch
import Foundation
import SimQueueCore
import SimQueueProtocol

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// `simq run -- <cmd>`: queue a command that holds a simulator, wait for it to start,
/// stream its output, and exit with the command's own status. A thin client over
/// submit, wait, logs and cancel; the daemon still runs and supervises the command.
struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a command holding a simulator; exit with the command's status.",
        discussion: """
            Queues the command (default --sims 1), waits for it to start, then streams its
            output to stdout until it ends. The daemon runs it in its own process group in the
            current directory (or --cwd) with SIMQ_UDID (the first leased pool sim),
            SIMQ_SIM_UDIDS, SIMQ_JOB_ID, SIMQ_RUN_DIR, SIMQ_DERIVED_DATA and SIMQ_RESULT_BUNDLE
            (paths inside the job's run directory; nothing is created), plus
            SIMQ_ATTEMPT, SIMQ_PROJECT, SIMQ_KIND and SIMQ_SIMS. Daemon notes ("=== simq ...")
            go to stderr. The sim is a warm, booted pool sim as the last job left it; --reset-app
            BUNDLE_ID (repeatable) resets those apps and the keychain first, falling back to an
            erase if a reset step fails, and --fresh-sim erases it first.
            Exit status (--exit-code passthrough, the default): the command's own exit status
            when it ran and ended on its own. Otherwise simq's codes: 3 run timeout, 4 infra
            failure, 5 canceled, 6 queue timeout. A command can exit 3...6 itself, so to tell
            them apart use --exit-code mapped (simq's stable codes only: 1 for any command
            failure) or read state, result_class and command_exit_code from --result-file.
            --wait-timeout limits the wait for the start. When it runs out, the job is
            canceled (nobody is left to read its output) and simq exits with
            --wait-timeout-exit (default 7). On SIGINT, SIGTERM or SIGHUP the job is canceled,
            and simq waits for it to stop and then exits 128 + the signal number.
            """
    )

    @OptionGroup var connection: Connection
    @Option(help: "Project name. Default: the current directory's name.") var project: String?
    @Option(help: "Free-form label for status and logs (no behavior).") var kind: String?
    @Option(help: "Priority 0...100, or a configured alias.") var priority: String?
    @Option(help: "Named host template (from host_templates).") var template: String?
    @Option(help: "Who is submitting. Default: $USER.") var submitter: String?
    @Option(help: "Simulators to hold (default 1; 0 runs without one).") var sims = 1
    @Flag(help: "Take the exclusive slot: exclusive jobs run one at a time.") var exclusive = false
    @Flag(help: "Permit replay after infrastructure failure or restart, within --retries.") var retryable = false
    @Option(help: "Maximum retries, 0...10 (implies --retryable).") var retries: Int?
    @Option(
        name: .customLong("memory-hint-mib"),
        help:
            "Optional scheduling estimate in MiB, not a memory limit or RAM reservation. Omitted: 512 MiB minimum accounting."
    )
    var memoryMib: UInt64 = 0
    @Option(help: "Run timeout from start, e.g. 30m, or none.") var timeout: String?
    @Option(help: "Queue timeout before the start, e.g. 2h, or none.") var queueTimeout: String?
    @Option(
        help:
            "Stop waiting for the start after this long (queue time plus any --reset-app/--fresh-sim prep); the job is canceled."
    )
    var waitTimeout: String?
    @Option(help: "Exit status when --wait-timeout runs out, 1...255 (default 7).") var waitTimeoutExit: Int32 = 7
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
    @Option(help: "passthrough (default): exit with the command's own status; mapped: simq's stable codes only.")
    var exitCode: ExitCodeMode = .passthrough
    @Option(help: "Write the final job record (JSON, with its artifacts) to this file.") var resultFile: String?
    @Option(help: "Atomically attach job output to an active output-hold UUID (requires daemon support).")
    var outputHold: String?
    @Argument(parsing: .postTerminator, help: "The command to run, after --.") var command: [String] = []

    func validate() throws {
        if let outputHold { _ = try validatedOutputHoldID(outputHold) }
        guard !command.isEmpty else { throw ValidationError("simq run needs a command after --") }
        guard memoryMib <= UInt64.max / ByteSize.mebibyte else {
            throw ValidationError("--memory-hint-mib is too large")
        }
        guard sims >= 0 else { throw ValidationError("--sims must be >= 0") }
        guard (1...255).contains(waitTimeoutExit) else { throw ValidationError("--wait-timeout-exit must be 1...255") }
        if let retries, !(0...10).contains(retries) { throw ValidationError("--retries must be 0...10") }
        _ = try selectedEnvironment(environment, names: environmentFrom)
    }

    func run() throws {
        // A job's command must not queue another job: it would wait behind its own parent.
        if let parent = ProcessInfo.processInfo.environment["SIMQ_JOB_ID"], !parent.isEmpty {
            printError("nested simq run inside job \(parent) is not supported")
            throw failure(.nestedRun)
        }
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
            minSims: sims,
            memoryBytes: memoryMib * ByteSize.mebibyte,
            exclusive: exclusive ? true : nil,
            retryable: retryable || retries != nil ? true : nil,
            maxRetries: retries,
            runTimeoutSeconds: try parseTimeout(timeout, flag: "--timeout"),
            queueTimeoutSeconds: try parseTimeout(queueTimeout, flag: "--queue-timeout"),
            command: command,
            environment: try selectedEnvironment(environment, names: environmentFrom),
            cwd: Submit.absolute(cwd ?? FileManager.default.currentDirectoryPath),
            resetApps: resetApps.isEmpty ? nil : resetApps,
            freshSim: freshSim ? true : nil
        )
        // Handlers go in before the submit, so a signal at any point after it cancels the
        // job instead of leaving it queued with nobody waiting (#41).
        let signals = SignalForwarder(connection: connection)
        signals.install()
        if let signal = signals.received { throw ExitCode(128 + signal) }
        let response = try submitJob(
            params, outputHold: outputHold, connection: connection, stopRetrying: { signals.received != nil })
        let jobID = response.job.id
        printError("queued \(jobID)")
        #if DEBUG
            // Test hook (debug builds only): widens the window between the submit's reply
            // and `attach`. Clamped to 0–10 s so a stray value can't hang a run.
            if let delay = ProcessInfo.processInfo.environment["SIMQ_TEST_RUN_PAUSE_AFTER_SUBMIT"].flatMap(Double.init),
                delay.isFinite
            {
                Thread.sleep(forTimeInterval: min(max(delay, 0), 10))
            }
        #endif
        signals.attach(jobID: jobID)

        // 1. Wait for the start (or an end before it).
        let deadline = clientWait.map { Date().timeIntervalSince1970 + $0 }
        do {
            _ = try call(
                connection, .wait(WaitParams(jobID: jobID, stream: false, untilAdmitted: true)), timeout: 0,
                deadline: deadline, reconnect: true, stopRetrying: { signals.received != nil })
        } catch let exit as ExitCode where exit.rawValue == SimQExitCode.waitTimeout.rawValue {
            _ = try? call(connection, .cancel(CancelParams(jobID: jobID)))
            printError("\(jobID) didn't start within --wait-timeout; canceled")
            throw ExitCode(waitTimeoutExit)
        }

        // 2. Stream the output until the job ends.
        var splitter = LogSplitter()
        var offset: Int64 = 0
        while true {
            guard
                case .logs(let chunk) = try call(
                    connection, .logs(LogsParams(jobID: jobID, offset: offset)), reconnect: true,
                    stopRetrying: { signals.received != nil })
            else {
                throw failure(.protocolError)
            }
            splitter.feed(chunk.data)
            offset = chunk.nextOffset
            if !chunk.atEnd { continue }
            if chunk.jobFinished { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        splitter.finish()

        // 3. Exit with the command's status.
        guard
            case .job(let job) = try call(
                connection, .explain(JobRef(jobID: jobID)), reconnect: true, stopRetrying: { signals.received != nil })
        else {
            throw failure(.protocolError)
        }
        if let resultFile { try Self.writeResult(job, to: resultFile) }
        if let signal = signals.received {
            if job.cleanupBlocked == true, let message = job.message { printError(message) }
            printError("\(jobID) \(job.state.rawValue) after signal \(signal)")
            throw ExitCode(128 + signal)
        }
        let status = Self.exitStatus(for: job, mode: exitCode)
        if status != 0 {
            printError(describe(job))
        } else if job.artifacts?.isEmpty == false {
            printError(
                "=== simq \(jobID)"
                    + describeArtifacts(job, indent: "").replacingOccurrences(of: "\n", with: "\n=== simq "))
        }
        if status != 0 { throw ExitCode(status) }
    }

    /// How `simq run` picks its exit status.
    enum ExitCodeMode: String, ExpressibleByArgument, CaseIterable {
        /// The command's own status when it ran and ended on its own, else simq's code.
        case passthrough
        /// simq's stable codes only (docs/PROTOCOL.md): 0, 1 command failure, 3...7, ...
        case mapped
    }

    /// With `passthrough`, the command's own status when it ran to the end, else simq's
    /// code for the state. With `mapped`, always simq's stable code.
    static func exitStatus(for job: JobInfo, mode: ExitCodeMode = .passthrough) -> Int32 {
        if job.cleanupBlocked == true { return SimQExitCode.infraFailure.rawValue }
        switch (job.state, mode) {
        case (.succeeded, _): return 0
        case (.failed, .passthrough):
            if let code = job.commandExitCode, code > 0 { return min(code, 255) }
            return job.exitCode.rawValue
        default: return job.exitCode.rawValue
        }
    }

    /// Writes the job record as pretty JSON (the `explain --json` shape), atomically.
    static func writeResult(_ job: JobInfo, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        do {
            try (try encoder.encode(job) + Data("\n".utf8)).write(
                to: URL(fileURLWithPath: Submit.absolute(path)), options: .atomic)
        } catch {
            printError("could not write --result-file \(path): \(error)")
        }
    }
}

/// Parses `--env NAME=VALUE` pairs (later pairs win).
func parseEnvironment(_ items: [String]) throws -> [String: String] {
    var pairs: [String: String] = [:]
    for item in items {
        guard let equals = item.firstIndex(of: "="), equals != item.startIndex else {
            throw ValidationError("--env takes NAME=VALUE, got \"\(item)\"")
        }
        let name = String(item[..<equals])
        guard JobCommand.isValidEnvironmentName(name) else {
            throw ValidationError("--env name \"\(name)\" must match [A-Za-z_][A-Za-z0-9_]*")
        }
        pairs[name] = String(item[item.index(after: equals)...])
    }
    return pairs
}

/// Sends the job's output to stdout and the daemon's own "=== simq" lines to stderr.
struct LogSplitter {
    private var pending = ""

    mutating func feed(_ text: String) {
        pending += text
        while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[...newline])
            pending = String(pending[pending.index(after: newline)...])
            write(line)
        }
    }

    mutating func finish() {
        if !pending.isEmpty { write(pending) }
        pending = ""
    }

    private func write(_ line: String) {
        let handle = line.hasPrefix("=== simq") ? FileHandle.standardError : FileHandle.standardOutput
        handle.write(Data(line.utf8))
    }
}

/// Turns SIGINT, SIGTERM and SIGHUP into one `cancel` of the job. Installed before the
/// submit: a signal that arrives before the job id is known is remembered, and `attach`
/// cancels the job as soon as it has an id. The caller keeps waiting so the command's
/// process group is stopped before simq exits.
final class SignalForwarder: @unchecked Sendable {
    private let connection: Connection
    private let lock = NSLock()
    private var sources: [DispatchSourceSignal] = []
    private var signal: Int32?
    private var jobID: String?

    init(connection: Connection) {
        self.connection = connection
    }

    /// Gives the forwarder the job to cancel, and cancels it now if a signal already came.
    func attach(jobID: String) {
        let pending: Int32? = lock.withLock {
            self.jobID = jobID
            return signal
        }
        if let pending { cancel(jobID, signal: pending) }
    }

    var received: Int32? { lock.withLock { signal } }

    func install() {
        for number in [SIGINT, SIGTERM, SIGHUP] {
            ignoreDefaultAction(number)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in self?.handle(number) }
            source.resume()
            sources.append(source)
        }
    }

    private func handle(_ number: Int32) {
        let target: String?? = lock.withLock {
            guard signal == nil else { return .none }
            signal = number
            return .some(jobID)
        }
        // Not attached yet: `attach` cancels once the submit returns an id.
        guard case .some(.some(let jobID)) = target else { return }
        cancel(jobID, signal: number)
    }

    private func cancel(_ jobID: String, signal number: Int32) {
        printError("signal \(number): canceling \(jobID)")
        _ = try? connection.client().send(Request(params: .cancel(CancelParams(jobID: jobID))))
    }
}

/// Ignores the default action so the dispatch source sees the signal.
private func ignoreDefaultAction(_ number: Int32) {
    _ = signal(number, SIG_IGN)
}

func selectedEnvironment(
    _ overrides: [String], names: [String], caller: [String: String] = ProcessInfo.processInfo.environment
) throws -> [String: String] {
    var selected: [String: String] = [:]
    for name in names {
        guard !name.hasPrefix("SIMQ_"), name != "SIMQUEUE_STATE_DIR", let value = caller[name] else {
            throw ValidationError("--env-from requires a present, non-reserved caller variable: \(name)")
        }
        for (key, value) in try parseEnvironment([name + "=" + value]) { selected[key] = value }
    }
    return selected.merging(try parseEnvironment(overrides)) { _, explicit in explicit }
}
