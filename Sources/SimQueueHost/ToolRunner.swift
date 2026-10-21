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
    case timedOut(command: String, seconds: Double)
    case failed(command: String, status: Int32, stderr: String)

    public var description: String {
        switch self {
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
        let outBox = DataBox()
        let errBox = DataBox()
        let readers = DispatchGroup()
        for (descriptor, box) in [(spawned.stdout, outBox), (spawned.stderr, errBox)] {
            readers.enter()
            DispatchQueue.global().async {
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                box.set(handle.readDataToEndOfFile())
                readers.leave()
            }
        }
        let exitBox = ExitBox()
        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var info = siginfo_t()
            var code: Int32
            repeat { code = waitid(P_PID, id_t(pgid), &info, WEXITED | WNOWAIT) } while code < 0 && errno == EINTR
            if code == 0 { exitBox.set(.exited(0)) }
            exited.signal()
        }
        let command = ([tool] + arguments).joined(separator: " ")
        if exited.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            kill(-pgid, SIGTERM)
            if exited.wait(timeout: .now() + killGraceSeconds) == .timedOut {
                kill(-pgid, SIGKILL)
                _ = exited.wait(timeout: .now() + killGraceSeconds)
            }
            // The leader remains unreaped until after the final signal; its pgid
            // therefore cannot be reused for an unrelated process in this window.
            kill(-pgid, SIGKILL)
            if exitBox.get() != nil {
                _ = ProcessSpawner.waitBlocking(pgid)
            } else {
                DispatchQueue.global().async { _ = ProcessSpawner.waitBlocking(pgid) }
            }
            _ = readers.wait(timeout: .now() + killGraceSeconds)
            throw ToolError.timedOut(command: command, seconds: timeoutSeconds)
        }
        _ = readers.wait(timeout: .now() + max(1, killGraceSeconds))
        let status: Int32
        switch ProcessSpawner.waitBlocking(pgid) {
        case .exited(let code): status = code
        case .signaled(let signal): status = 128 + signal
        case nil: status = -1
        }
        return ToolResult(
            status: status, stdout: String(decoding: outBox.get(), as: UTF8.self),
            stderr: String(decoding: errBox.get(), as: UTF8.self))
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

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) {
        lock.lock()
        data = value
        lock.unlock()
    }
    func get() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

private final class ExitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ChildExit?
    func set(_ exit: ChildExit?) {
        lock.lock()
        value = exit
        lock.unlock()
    }
    func get() -> ChildExit? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
