// SPDX-License-Identifier: MIT

import Dispatch
import Foundation
import SimQueueHost

/// Guards against job output whose metadata answers while its file I/O blocks.
public enum JobOutputGuard {
    /// The storage check `simqd` gives the executor: the volume's own checks (`volume`), then a
    /// real-I/O probe that must have passed. A root the probe reports hung, or has not verified
    /// yet (a daemon that has just started), fails the check, so start preparation holds the job
    /// like a disconnected volume: it stays admitted and spends no attempt.
    public static func storageCheck(
        volume: @escaping @Sendable (String) throws -> Void, probe: StorageIOProbe
    ) -> @Sendable (String) throws -> Void {
        { root in
            try volume(root)
            if let failure = probe.check(root, requireResult: true) { throw JobStorage.Failure(failure) }
        }
    }
}

/// Runs file-system work on its own thread and waits at most a deadline for it, so a caller
/// holding the state lock is not held by a volume that stops answering. While earlier work
/// for a root is still blocked, new work for that root is skipped: a hung volume holds at
/// most one thread per root, and the work it was given finishes whenever the volume answers.
public final class BoundedWriters: @unchecked Sendable {
    private let lock = NSLock()
    private var busy: Set<String> = []

    public init() {}

    /// True when `work` finished within `deadlineSeconds`; false when it is still running
    /// (it carries on in the background) or was skipped because `root` already has a writer.
    @discardableResult
    public func run(root: String, deadlineSeconds: Double, _ work: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        guard busy.insert(root).inserted else {
            lock.unlock()
            return false
        }
        lock.unlock()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread { [self] in
            work()
            lock.lock()
            busy.remove(root)
            lock.unlock()
            done.signal()
        }
        return done.wait(timeout: .now() + deadlineSeconds) == .success
    }

    /// Roots with work still running (for tests and diagnostics).
    public var busyRoots: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return busy
    }
}
