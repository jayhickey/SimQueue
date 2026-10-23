// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
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
            var bundles = categories["Result bundles"] ?? .init(name: "Result bundles")
            var bundleBytes: UInt64 = 0
            var bundlesKnown = true
            for path in entry.resultBundles {
                bundles.count += 1
                if let bytes = index < 200 ? fileSystem.sizeOfItem(path) : nil {
                    bundles.bytes += bytes; bundleBytes += bytes
                } else {
                    bundles.unknownSizes += 1; bundlesKnown = false
                }
            }
            if bundles.count > 0 { categories[bundles.name] = bundles }
            // Only subtract subtrees with known sizes; never count them twice.
            if let total, (!entry.hasDerivedData || derived != nil), bundlesKnown {
                category.bytes += total - min(total, (derived ?? 0) + bundleBytes)
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
    static func protection(
        _ entries: [Engine.StorageEntry], candidates: [GarbageCollection.Candidate], fileSystem: any FileSystem
    ) -> [ArtifactStorageInfo.Category] {
        let eligible = Set(candidates.map(\.path))
        var groups: [String: ArtifactStorageInfo.Category] = [:]
        for (index, entry) in entries.enumerated() where !eligible.contains(entry.path) {
            let reason =
                ["Pinned", "Active / cleanup pending"].contains(entry.category)
                ? entry.category : "Within retention / not eligible"
            var group = groups[reason] ?? .init(name: reason)
            group.count += 1
            if index < 200, let total = fileSystem.sizeOfItem(entry.path) {
                if eligible.contains(entry.path + "/DerivedData") {
                    if let derived = fileSystem.sizeOfItem(entry.path + "/DerivedData") {
                        group.bytes += total - min(total, derived)
                    } else {
                        group.unknownSizes += 1
                    }
                } else {
                    group.bytes += total
                }
            } else {
                group.unknownSizes += 1
            }
            groups[reason] = group
        }
        return groups.values.sorted { $0.name < $1.name }
    }

    /// Inventory readings are matched by ledger ID, never by simulator name.
    static func simulators(resources: [OwnedResource], devices: [SimDevice]) -> [ArtifactStorageInfo.Category] {
        var owned: [String: OwnedResourceKind] = [:]
        for resource in resources
        where resource.state != .released && (resource.kind == .sim || resource.kind == .template) {
            guard let id = UUID(uuidString: resource.externalID)?.uuidString else { continue }
            if owned[id] != .template { owned[id] = resource.kind }
        }
        var sizes: [String: UInt64] = [:]
        for device in devices {
            if let id = UUID(uuidString: device.udid)?.uuidString, let size = device.dataSizeBytes { sizes[id] = size }
        }
        var categories: [String: ArtifactStorageInfo.Category] = [:]
        for (id, kind) in owned {
            let name = kind == .template ? "Managed template data" : "Managed simulator data"
            var category = categories[name] ?? .init(name: name)
            category.count += 1
            if let size = sizes[id] { category.bytes += size } else { category.unknownSizes += 1 }
            categories[name] = category
        }
        return categories.values.sorted { $0.name < $1.name }
    }

}
