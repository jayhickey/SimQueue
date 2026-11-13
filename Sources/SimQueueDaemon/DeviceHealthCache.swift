// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore

/// Status only reads this cache. A single independent worker refreshes requested
/// devices; ToolRunner bounds the real devicectl calls, including their children.
final class DeviceHealthCache: @unchecked Sendable {
    private let lock = NSLock()
    private let probe: (String) -> DeviceHealth
    private var values: [String: (Double, DeviceHealth)] = [:]
    private var pending: Set<String> = []
    private var running = false
    private var probing: String?

    init(probe: @escaping (String) -> DeviceHealth) { self.probe = probe }

    func health(_ udid: String) -> DeviceHealth {
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        let cached = values[udid]
        let stale = cached.map { now - $0.0 >= 30 } ?? true
        if stale && probing != udid { pending.insert(udid) }
        let start = !running && !pending.isEmpty
        if start { running = true }
        lock.unlock()
        if start { Thread.detachNewThread { [self] in refresh() } }
        guard let cached, now - cached.0 < 60 else {
            return DeviceHealth(state: "device_unavailable", detail: "device health refresh pending or stale")
        }
        return cached.1
    }

    private func refresh() {
        while true {
            lock.lock()
            guard let udid = pending.sorted().first else {
                running = false
                lock.unlock()
                return
            }
            pending.remove(udid)
            probing = udid
            lock.unlock()
            let value = probe(udid)
            lock.lock()
            values[udid] = (ProcessInfo.processInfo.systemUptime, value)
            probing = nil
            lock.unlock()
        }
    }
}
