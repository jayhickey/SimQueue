// SPDX-License-Identifier: MIT

import Foundation

/// Basic availability checks, not volume identity or disconnect-race guarantees.
public enum JobStorage {
    public static func check(_ root: String) throws {
        let manager = FileManager.default
        // Never create /Volumes/<name> when an external disk is absent. Check the
        // mount's filesystem, not merely the existence of its former mount directory.
        let components = root.split(separator: "/")
        if components.count >= 2, components[0] == "Volumes" {
            let mount = "/Volumes/" + components[1]
            let mounted = try manager.attributesOfFileSystem(forPath: mount)[.systemNumber] as? NSNumber
            let parent = try manager.attributesOfFileSystem(forPath: "/Volumes")[.systemNumber] as? NSNumber
            guard let mounted, let parent, mounted != parent else {
                throw Failure("external volume is not mounted at \(mount)")
            }
        }
        var ancestor = root
        var directory: ObjCBool = false
        while !manager.fileExists(atPath: ancestor, isDirectory: &directory) {
            ancestor = (ancestor as NSString).deletingLastPathComponent
            if ancestor.isEmpty { ancestor = "/" }
        }
        guard directory.boolValue, manager.isWritableFile(atPath: ancestor) else {
            throw Failure("job output is not a writable directory: \(ancestor)")
        }
        // Rooted cleanup refuses symlinks. Reject them before the executor can write.
        // Only the link type is needed; Foundation attributes also read extended metadata.
        guard !RootedFileSystem.isSymlink(root) else {
            throw Failure("job output root must not pass through symlinks: \(root)")
        }
    }

    public static func freeBytes(_ root: String) -> UInt64? {
        var ancestor = root
        while !FileManager.default.fileExists(atPath: ancestor), ancestor != "/" {
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
        return (try? FileManager.default.attributesOfFileSystem(forPath: ancestor)[.systemFreeSize] as? NSNumber)?
            .uint64Value
    }

    public struct Failure: Error, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }
}

/// Check availability before touching configured output roots, including cleanup.
public struct StorageFileSystem: FileSystem {
    public var base: any FileSystem
    public var roots: [String]
    public init(base: any FileSystem, roots: [String]) { self.base = base; self.roots = roots }
    private func check(_ path: String) throws {
        for root in roots where path == root || path.hasPrefix(root + "/") { try JobStorage.check(root) }
    }
    public func fileExists(_ path: String) -> Bool {
        // Recovery must not mistake an offline volume for confirmed deletion.
        guard (try? check(path)) != nil else { return true }
        return base.fileExists(path)
    }
    public func children(of path: String) throws -> [String] {
        // An unavailable old root must not prevent retention on available roots.
        guard (try? check(path)) != nil else { return [] }
        return try base.children(of: path)
    }
    public func createDirectory(_ path: String) throws { try check(path); try base.createDirectory(path) }
    public func removeItem(_ path: String) throws { try check(path); try base.removeItem(path) }
    public func removeEmptyDirectory(_ path: String) throws -> Bool {
        try check(path)
        return try base.removeEmptyDirectory(path)
    }
    public func sizeOfItem(_ path: String) -> UInt64? {
        guard (try? check(path)) != nil else { return nil }
        return base.sizeOfItem(path)
    }
}
