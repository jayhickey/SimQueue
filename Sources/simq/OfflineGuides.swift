// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import SimQueueCore

/// Version-matched operational instructions, available without a daemon or filesystem writes.
struct AgentGuide: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent-guide",
        abstract: "Print the installed version's offline guide for coding agents.")

    func run() {
        print(Self.text)
    }

    static var text: String {
        """
        SimQueue \(SimQueueVersion.current) agent guide

        Use the queue for builds, tests and other trusted commands sharing this Mac.
        Commands execute as the daemon's user, not in a security sandbox. Use the existing
        host configuration; change templates, services or unrelated devices only when authorized.

        Quick start
          simq run --project app --sims 0 --timeout 20m -- swift build -j 4
          simq run --project app --sims 1 --timeout 30m -- ./run-tests.sh
        Every simulator job runs its whole suite on one leased simulator. Submit independent
        jobs for concurrency; keep separate checkouts and build paths, with bounded tool workers.
        SimQueue controls admission, not the command's own threads or memory allocation.

        Simulator test scripts
          xcodebuild test -workspace App.xcworkspace -scheme App \\
            -destination "id=$SIMQ_UDID" -parallel-testing-enabled NO \\
            -maximum-concurrent-test-simulator-destinations 1 \\
            -derivedDataPath "$SIMQ_DERIVED_DATA" -resultBundlePath "$SIMQ_RESULT_BUNDLE"
        Expand these variables in the queued script/shell, not the submitting shell.
        SIMQ_UDID is the exact first leased simulator; SIMQ_SIM_UDIDS lists the job's leases.
        SIMQ_JOB_ID, SIMQ_ATTEMPT, SIMQ_PROJECT, SIMQ_KIND and SIMQ_SIMS identify the job.
        SIMQ_RUN_DIR holds logs/artifacts. SIMQ_DERIVED_DATA and SIMQ_RESULT_BUNDLE are
        suggested per-job output paths; the command must write its results there.
        SIMQ_TMPDIR is the job's temporary directory; TMPDIR uses it unless explicitly set.
        Do not choose a simulator by name, boot another device, or reuse another job's paths.

        Admission and environment
        --memory-hint-mib N is an optional scheduling estimate, not a memory limit or RAM
        reservation. Omission uses 512 MiB minimum accounting with live host resource gates
        and gradual admission. A realistic hint helps large builds before their usage appears.
        Exceeding a hint does not kill a command. Do not bypass resource holds to increase starts.
        Commands inherit the daemon's environment. Forward selected caller values with
        --env-from NAME or set --env NAME=value; SIMQ_* names are reserved. A missing
        --env-from variable fails before submission. Use --cwd for an explicit checkout.

        Inspect and retrieve
          simq status --json
          simq jobs --json
          simq explain JOB_ID --json
          simq logs JOB_ID
        Use --result-file result.json on run to retain state, result_class,
        command_exit_code, run_dir and artifact/result-bundle paths. Keep the job ID.
        After a disconnect, inspect that job and use simq wait JOB_ID or logs JOB_ID;
        never blindly resubmit a command whose first submission may have succeeded.

        Results, cancellation and recovery
        run defaults to the command's exit status when it ended normally. Use --exit-code
        mapped for stable categories: 0 success, 1 command/test failure, 2 build failure,
        3 run timeout, 4 infrastructure failure, 5 canceled, 6 queue expiry, 7 wait timeout.
        Read command_exit_code to distinguish an ordinary command exit from a mapped failure.
        --timeout bounds execution; --queue-timeout bounds waiting. run --wait-timeout
        cancels a job that has not started; it also includes any requested simulator prep.
        simq cancel JOB_ID requests cancellation. Keep a waiting run client in the foreground;
        signals cancel its job and wait for cleanup. Unknown ownership keeps capacity held;
        inspect doctor/cleanup diagnostics instead of discarding the ledger or killing broadly.
        Waiting clients retry unanswered observations or reconnect briefly to the same job; they do not
        preserve arbitrary running commands. Started work is not replayed unless --retryable
        or --retries N permits it within the retry budget. Retries do not undo side effects.

        Warm state and maintenance
        The pool uses explicitly configured host templates; --template selects a named template. Warm simulators retain
        state. --reset-app BUNDLE_ID resets an app and keychain before execution, with erase
        fallback on a reset failure; --fresh-sim erases the leased simulator before execution.
        Use reset/fresh deliberately when isolation is required, not for every warm job.
        simq drain --timeout 30m holds new starts and waits for running work/cleanup.
        Restart only after drain succeeds; simq resume reopens admission. Follow the installed
        upgrade guide and preserve a consistent backup for rollback. Uninstall and purge
        require deliberate ownership-safe cleanup; unrelated resources remain untouched.

        More help
          simq run --help
          simq docs
        docs prints the installed full documentation root; open its README.md for linked
        guides, configuration, installation and MCP. This guide and docs discovery work
        offline without starting a daemon or creating state. Optional Agent Skills only
        point here; installing one into an agent directory is an explicit user choice.
        """
    }
}

/// Resolves documentation from the actual executable, not the current working directory.
enum DocumentationLocation {
    struct Found {
        var root: URL
        var layout: String
    }

    static func resolve() -> Found? {
        let fallback = URL(fileURLWithPath: CommandLine.arguments[0])
        let executable = (Bundle.main.executableURL ?? fallback).resolvingSymlinksInPath().standardizedFileURL
        let prefix = executable.deletingLastPathComponent().deletingLastPathComponent()
        let installed = prefix.appendingPathComponent("share/doc/simqueue", isDirectory: true)
        if hasGuides(installed) { return Found(root: installed, layout: "homebrew") }
        if hasGuides(prefix), isFile(prefix.appendingPathComponent("LICENSE")),
            isFile(prefix.appendingPathComponent("NOTICE"))
        {
            return Found(root: prefix, layout: "archive")
        }
        var ancestor = executable.deletingLastPathComponent()
        for _ in 0..<12 {
            if hasGuides(ancestor), isFile(ancestor.appendingPathComponent("Package.swift")),
                isFile(ancestor.appendingPathComponent("Sources/simq/SimQ.swift"))
            {
                return Found(root: ancestor, layout: "source")
            }
            let parent = ancestor.deletingLastPathComponent()
            if parent == ancestor { break }
            ancestor = parent
        }
        return nil
    }

    private static func hasGuides(_ root: URL) -> Bool {
        ["README.md", "docs/INSTALL.md", "docs/PROTOCOL.md"].allSatisfy {
            isFile(root.appendingPathComponent($0))
        }
    }

    private static func isFile(_ url: URL) -> Bool {
        var directory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && !directory.boolValue
    }
}

struct Docs: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the full offline documentation directory; never starts a daemon.")

    @Flag(help: "Print the documentation path and installed version as JSON.")
    var json = false

    private struct Result: Encodable {
        var schemaVersion = 1
        var version = SimQueueVersion.current
        var path: String?
        var layout: String?
        var error: String?
        var message: String?

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case version, path, layout, error, message
        }
    }

    func run() throws {
        guard let location = DocumentationLocation.resolve() else {
            let message =
                "Full documentation was not found beside this executable. Reinstall SimQueue through Homebrew or use a complete source checkout. simq agent-guide is always available offline."
            if json {
                try printJSON(Result(error: "documentation_not_found", message: message))
            } else {
                printError(message)
            }
            throw ExitCode.failure
        }
        if json {
            try printJSON(Result(path: location.root.path, layout: location.layout))
        } else {
            print(location.root.path)
        }
    }
}
