// SPDX-License-Identifier: MIT

import Dispatch
import Foundation

/// A bounded real-I/O check for an output root.
///
/// A mounted volume can still answer metadata calls (`stat`, free space, writability) while
/// file data reads and writes block indefinitely. This probe writes, reads back and removes
/// a tiny file on its own thread and never blocks a caller past `inlineWaitSeconds`. A probe
/// still pending after `timeoutSeconds` reports the root as hung; no second probe starts for
/// that root until the first returns, so a hung volume cannot accumulate blocked threads.
public final class StorageIOProbe: @unchecked Sendable {
    public typealias Operation = @Sendable (String) throws -> Void

    public let timeoutSeconds: Double
    public let intervalSeconds: Double
    public let inlineWaitSeconds: Double
    private let operation: Operation
    private let uptime: @Sendable () -> Double
    private let lock = NSLock()
    private var inFlight: [String: Pending] = [:]
    private var results: [String: Result] = [:]

    private struct Pending {
        let started: Double
        let group: DispatchGroup
    }

    private struct Result {
        let at: Double
        let failure: String?
    }

    /// - Parameters:
    ///   - timeoutSeconds: A probe pending this long reports the root as hung.
    ///   - intervalSeconds: Minimum time between completed probes of one root.
    ///   - inlineWaitSeconds: How long the call that starts a probe waits for its result.
    public init(
        timeoutSeconds: Double = 5, intervalSeconds: Double = 30, inlineWaitSeconds: Double = 0.25,
        operation: @escaping Operation = StorageIOProbe.writeReadRemove,
        uptime: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.intervalSeconds = intervalSeconds
        self.inlineWaitSeconds = inlineWaitSeconds
        self.operation = operation
        self.uptime = uptime
    }

    /// Returns nil when the latest probe of `root` succeeded (or none has finished yet),
    /// otherwise a description of the failure. Starts a new probe when the last is stale.
    ///
    /// - Parameter requireResult: For callers about to start work on `root` (admission, start
    ///   preparation, run-directory listings): until a probe of `root` has finished, report it
    ///   as not verified instead of assuming it answers. A daemon that starts while the volume
    ///   hangs then holds work rather than blocking in its first `open()` there. Status and
    ///   doctor report without it.
    public func check(_ root: String, requireResult: Bool = false) -> String? {
        lock.lock()
        let now = uptime()
        var started: Pending?
        if inFlight[root] == nil, results[root].map({ now - $0.at >= intervalSeconds }) ?? true {
            let pending = Pending(started: now, group: DispatchGroup())
            pending.group.enter()
            inFlight[root] = pending
            started = pending
        }
        let pending = inFlight[root]
        let last = results[root]
        lock.unlock()

        if let started {
            let operation = self.operation
            Thread.detachNewThread { [self] in
                let failure: String?
                do { try operation(root); failure = nil } catch { failure = String(describing: error) }
                lock.lock()
                results[root] = Result(at: uptime(), failure: failure)
                inFlight[root] = nil
                lock.unlock()
                started.group.leave()
            }
            let wait = min(inlineWaitSeconds, timeoutSeconds)
            if wait > 0, started.group.wait(timeout: .now() + wait) == .success {
                lock.lock(); defer { lock.unlock() }
                return results[root]?.failure
            }
        }
        if let pending {
            let elapsed = uptime() - pending.started
            if elapsed >= timeoutSeconds {
                return "job output I/O probe has not finished after \(Self.seconds(elapsed)) "
                    + "(limit \(Self.seconds(timeoutSeconds))) at \(root); reads and writes there may be hung"
            }
        }
        if requireResult, last == nil {
            return "job output I/O at \(root) is not verified yet; work waits for the first probe to finish"
        }
        return last?.failure
    }

    /// Writes a small file into `root`, reads it back uncached and removes it.
    /// A missing root is skipped: availability checks cover it without creating it.
    @Sendable public static func writeReadRemove(_ root: String) throws {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &directory), directory.boolValue else {
            return
        }
        let name = ".simq-io-probe-\(getpid())-\(UUID().uuidString)"
        let path = (root as NSString).appendingPathComponent(name)
        let payload = Data(name.utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard FileManager.default.createFile(atPath: path, contents: payload, attributes: [.posixPermissions: 0o600])
        else { throw JobStorage.Failure("job output I/O probe could not write a file in \(root)") }
        let read = try Data(contentsOf: URL(fileURLWithPath: path), options: [.uncached])
        guard read == payload else {
            throw JobStorage.Failure("job output I/O probe read back different bytes in \(root)")
        }
        try FileManager.default.removeItem(atPath: path)
    }

    private static func seconds(_ value: Double) -> String {
        value >= 10 ? "\(Int(value))s" : String(format: "%.1fs", value)
    }
}
