// SPDX-License-Identifier: MIT

import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// Output of one external tool call.
public struct ToolResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var succeeded: Bool { status == 0 }
}

public enum ToolError: Error, Equatable, CustomStringConvertible {
    case notFound(String)
    case outputLimitExceeded(command: String)
    case timedOut(command: String, seconds: Double)
    case failed(command: String, status: Int32, stderr: String)

    public var description: String {
        switch self {
        case .outputLimitExceeded(let command): "\(command) exceeded the 16 MiB output limit per stream (killed)"
        case .notFound(let tool): "\(tool) not found on PATH"
        case .timedOut(let command, let seconds): "\(command) timed out after \(Int(seconds))s (killed)"
        case .failed(let command, let status, let stderr):
            "\(command) exited \(status): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))"
        }
    }
}

/// Runs external tools (`xcrun`, `simslim`, `sysctl`, `vm_stat`, `ps`) with a hard
/// timeout on every call: past the timeout the tool gets SIGTERM, then SIGKILL after
/// `killGraceSeconds`, and the call throws `timedOut`. Tools are found on `PATH` from
/// `environment`, so tests put fake scripts first.
public struct ToolRunner: Sendable {
    public var environment: [String: String]
    public var killGraceSeconds: Double

    public init(environment: [String: String] = ProcessInfo.processInfo.environment, killGraceSeconds: Double = 2) {
        self.environment = environment
        self.killGraceSeconds = killGraceSeconds
    }

    /// Runs `tool arguments...` and returns its result whatever the exit status.
    public func run(_ tool: String, _ arguments: [String], timeoutSeconds: Double) throws -> ToolResult {
        guard
            let executable = ProcessSpawner.resolveExecutable(tool, path: environment["PATH"], cwd: nil)
        else { throw ToolError.notFound(tool) }
        // Its own process group, so a timeout reaches whatever the tool forked (xcrun
        // starting simctl, say), not just the direct child.
        let spawned = try ProcessSpawner.spawnTool(
            executable: executable, argv: [executable] + arguments, environment: environment)
        let pgid = spawned.pid
        // Drain and observe the child on this calling thread. Never schedule a
        // blocking pipe reader or reaper on Dispatch's shared worker pool: enough
        // concurrent tools otherwise starve the very workers needed to reap them.
        let descriptors = [spawned.stdout, spawned.stderr]
        for fd in descriptors { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        defer { for fd in descriptors { close(fd) } }
        var output = [Data(), Data()]
        var eof = [false, false]
        var outputLimitExceeded = false
        let outputLimit = 16 * 1024 * 1024
        let started = ProcessInfo.processInfo.systemUptime
        var exited = false
        func observeExit() -> Bool {
            var info = siginfo_t()
            var result: Int32
            repeat {
                result = waitid(P_PID, id_t(pgid), &info, WEXITED | WNOWAIT | WNOHANG)
            } while result < 0 && errno == EINTR
            return result < 0 || info.si_signo != 0
        }
        while true {
            var madeProgress = false
            for index in descriptors.indices where !eof[index] {
                // Bound each pass even if a tool writes forever.
                for _ in 0..<16 {
                    var bytes = [UInt8](repeating: 0, count: 16 * 1024)
                    let count = read(descriptors[index], &bytes, bytes.count)
                    if count > 0 {
                        madeProgress = true
                        // Bound diagnostic memory while continuing to drain the pipe.
                        let remaining = max(0, outputLimit - output[index].count)
                        output[index].append(contentsOf: bytes.prefix(min(count, remaining)))
                        if count > remaining { outputLimitExceeded = true }
                    } else {
                        if count == 0 { eof[index] = true }
                        break
                    }
                }
            }
            exited = observeExit()
            if !outputLimitExceeded && exited && eof.allSatisfy({ $0 }) { break }
            if outputLimitExceeded || ProcessInfo.processInfo.systemUptime - started >= max(0, timeoutSeconds) {
                // Keep the leader unreaped until the final group signal, preventing
                // pid/pgid reuse from targeting an unrelated process.
                kill(-pgid, SIGTERM)
                let grace = ProcessInfo.processInfo.systemUptime + max(0, killGraceSeconds)
                while !observeExit() && ProcessInfo.processInfo.systemUptime < grace {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                kill(-pgid, SIGKILL)
                // SIGKILL may wait on an uninterruptible kernel operation. Keep
                // the call bounded and transfer only that PID to a dedicated reaper.
                let reapDeadline = ProcessInfo.processInfo.systemUptime + max(0.05, killGraceSeconds)
                var reaped = false
                repeat {
                    do {
                        if try ProcessSpawner.reap(pgid) != nil { reaped = true; break }
                    } catch { reaped = true; break }
                    Thread.sleep(forTimeInterval: 0.005)
                } while ProcessInfo.processInfo.systemUptime < reapDeadline
                if !reaped { ToolChildReaper.shared.add(pgid) }
                let command = ([tool] + arguments).joined(separator: " ")
                if outputLimitExceeded { throw ToolError.outputLimitExceeded(command: command) }
                throw ToolError.timedOut(command: command, seconds: timeoutSeconds)
            }
            // Do not throttle a tool that is actively producing output. Only
            // back off when both pipes would block (or have reached EOF).
            if !madeProgress { Thread.sleep(forTimeInterval: 0.005) }
        }
        let status: Int32
        switch ProcessSpawner.waitBlocking(pgid) {
        case .exited(let code): status = code
        case .signaled(let signal): status = 128 + signal
        case nil: status = -1
        }
        return ToolResult(
            status: status, stdout: String(decoding: output[0], as: UTF8.self),
            stderr: String(decoding: output[1], as: UTF8.self))
    }

    /// Like `run`, but a non-zero exit throws `failed`.
    public func check(_ tool: String, _ arguments: [String], timeoutSeconds: Double) throws -> String {
        let result = try run(tool, arguments, timeoutSeconds: timeoutSeconds)
        guard result.succeeded else {
            throw ToolError.failed(
                command: ([tool] + arguments).joined(separator: " "), status: result.status, stderr: result.stderr)
        }
        return result.stdout
    }
}

/// One independent, nonblocking reaper for killed children still in the kernel.
/// It never uses waitpid(-1), so job supervision retains ownership of its children.
private final class ToolChildReaper: @unchecked Sendable {
    static let shared = ToolChildReaper()
    private let condition = NSCondition()
    private var children: Set<Int32> = []

    private init() { Thread.detachNewThread { [self] in run() } }

    func add(_ pid: Int32) {
        condition.lock()
        children.insert(pid)
        condition.signal()
        condition.unlock()
    }

    private func run() {
        while true {
            condition.lock()
            while children.isEmpty { condition.wait() }
            let pending = children
            condition.unlock()
            for pid in pending {
                let finished: Bool
                do { finished = try ProcessSpawner.reap(pid) != nil } catch { finished = true }
                if finished {
                    condition.lock()
                    children.remove(pid)
                    condition.unlock()
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}
