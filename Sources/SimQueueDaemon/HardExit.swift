// SPDX-License-Identifier: MIT

import Foundation

/// A deadline for a process that has decided to exit and wants to leave a record first.
///
/// The record means disk I/O (a log line, a flush, a small file) and possibly a lock.
/// On a host whose disk has stalled, or whose lock is the reason for exiting, any of
/// those can block forever. Arm this first: the exit then happens after `seconds`
/// whatever the caller is blocked on.
public enum HardExit {
    /// Time a wedged daemon may spend recording why before it is ended regardless.
    public static let lastWordsSeconds: Double = 5

    public static func arm(after seconds: Double, _ exit: @escaping @Sendable () -> Void) {
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: max(0, seconds))
            exit()
        }
    }
}
