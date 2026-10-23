// SPDX-License-Identifier: MIT

import Foundation
import SimQueueEngine
import SimQueueHost
import SimQueueProtocol

/// One cleanup-lane pass shares sizes across budget planning, preview and accounting.
final class SizingFileSystem: FileSystem, @unchecked Sendable {
    private let base: any FileSystem
    private let lock = NSLock()
    private var sizes: [String: UInt64?] = [:]
    init(_ base: any FileSystem) { self.base = base }
    func fileExists(_ path: String) -> Bool { base.fileExists(path) }
    func children(of path: String) throws -> [String] { try base.children(of: path) }
    func createDirectory(_ path: String) throws { try base.createDirectory(path) }
    func removeItem(_ path: String) throws { try base.removeItem(path) }
    func removeEmptyDirectory(_ path: String) throws -> Bool { try base.removeEmptyDirectory(path) }
    func sizeOfItem(_ path: String) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = sizes[path] { return cached }
        let value = base.sizeOfItem(path)
        sizes[path] = .some(value)
        return value
    }
}

enum StorageAccounting {
    static func reclaimable(_ candidates: [GCEntry]) -> (bytes: UInt64, unknown: Int) {
        let paths = Set(candidates.map(\.path))
        let roots = candidates.filter { candidate in
            var ancestor = (candidate.path as NSString).deletingLastPathComponent
            while !ancestor.isEmpty {
                if paths.contains(ancestor) { return false }
                if ancestor == "/" { break }
                ancestor = (ancestor as NSString).deletingLastPathComponent
            }
            return true
        }
        return (roots.reduce(0) { $0 + ($1.bytes ?? 0) }, roots.filter { $0.bytes == nil }.count)
    }

    /// Additional accounting is capped; unknown sizes are never treated as known zero.
    static func categories(_ entries: [Engine.StorageEntry], fileSystem: any FileSystem) -> [ArtifactStorageInfo
        .Category]
    {
        var categories: [String: ArtifactStorageInfo.Category] = [:]
        for (index, entry) in entries.enumerated() {
            var category = categories[entry.category] ?? .init(name: entry.category)
            category.count += 1
            let total = index < 200 ? fileSystem.sizeOfItem(entry.path) : nil
            let derived = index < 200 && entry.hasDerivedData ? fileSystem.sizeOfItem(entry.path + "/DerivedData") : nil
            // Do not subtract unknown DerivedData from a known total and count it twice.
            if let total, !entry.hasDerivedData || derived != nil {
                category.bytes += total - min(total, derived ?? 0)
            } else {
                category.unknownSizes += 1
            }
            categories[entry.category] = category
            if entry.hasDerivedData {
                var value = categories["DerivedData"] ?? .init(name: "DerivedData")
                value.count += 1
                if let derived { value.bytes += derived } else { value.unknownSizes += 1 }
                categories[value.name] = value
            }
        }
        return categories.values.sorted { $0.name < $1.name }
    }
}
