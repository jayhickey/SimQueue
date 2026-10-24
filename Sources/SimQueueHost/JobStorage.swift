// SPDX-License-Identifier: MIT

import Foundation

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// Basic availability checks. StorageVolumeGuard adds persistent volume identity checks.
public enum JobStorage {
    private struct DirectoryIdentity: Hashable {
        var device: UInt64
        var inode: UInt64
    }

    /// Component comparison only: safe to use while holding the service lock.
    /// Case-insensitive comparison is a conservative veto on case-sensitive volumes.
    public static func isSameOrAncestor(_ ancestor: String, of path: String, caseSensitive: Bool = true) -> Bool {
        guard ancestor.hasPrefix("/"), path.hasPrefix("/") else { return false }
        let parent = URL(fileURLWithPath: ancestor).standardizedFileURL.pathComponents
        let child = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard parent.count <= child.count else { return false }
        return zip(parent, child).allSatisfy {
            caseSensitive ? $0 == $1 : $0.compare($1, options: .caseInsensitive) == .orderedSame
        }
    }

    private struct RootAncestry {
        var ancestors: [DirectoryIdentity: String]
        var caseSensitive: Bool

        func contains(_ other: Self) -> Bool {
            ancestors.contains { identity, suffix in
                guard let otherSuffix = other.ancestors[identity] else { return false }
                return JobStorage.isSameOrAncestor(
                    suffix, of: otherSuffix, caseSensitive: caseSensitive && other.caseSensitive)
            }
        }
    }

    /// Startup-only validation, before routing history is saved or recovery/GC begins.
    /// Compare existing ancestors without creating missing roots, and respect the
    /// volume's case semantics. This never scans job directories or changes routing.
    public static func validateDisjointRoots(_ roots: [String]) throws {
        let canonical = try roots.map(rootAncestry)
        for index in roots.indices {
            for other in roots.indices where other > index {
                if canonical[index].contains(canonical[other]) || canonical[other].contains(canonical[index]) {
                    throw Failure(
                        "job output roots overlap: \(roots[index]) and \(roots[other]); current and historical roots must be disjoint. Restore a non-overlapping routing configuration before restarting; no files or routing history have been changed"
                    )
                }
            }
        }
    }

    /// Filesystem boundary defense for callers that bypass daemon configuration.
    /// Only call outside the service lock: it stats ancestors, never descendants.
    static func containsConfiguredRoot(_ path: String, roots: [String]) throws -> Bool {
        let candidate = try rootAncestry(path)
        return try roots.contains { try candidate.contains(rootAncestry($0)) }
    }

    private static func rootAncestry(_ root: String) throws -> RootAncestry {
        guard root.hasPrefix("/"), root != "/", !root.utf8.contains(0),
            !root.split(separator: "/", omittingEmptySubsequences: false).dropFirst().contains(where: {
                $0.isEmpty || $0 == "." || $0 == ".."
            })
        else {
            throw Failure(
                "invalid job output root \(root): use an absolute dedicated path without dot components or trailing/repeated slashes; routing history is unchanged"
            )
        }
        var ancestor = root
        var suffix: [String] = []
        var nearest = stat()
        while stat(ancestor, &nearest) != 0 {
            guard errno == ENOENT, ancestor != "/" else {
                throw Failure("cannot verify job output root ancestry: \(ancestor)")
            }
            suffix.insert((ancestor as NSString).lastPathComponent, at: 0)
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
        let existing = URL(fileURLWithPath: ancestor).resolvingSymlinksInPath()
        #if os(macOS)
            let values = try existing.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            let caseSensitive = values.volumeSupportsCaseSensitiveNames ?? false
        #else
            let caseSensitive = true
        #endif
        // Walk physical parents so trusted symlinks cannot skip an enclosing root.
        // Keep the missing-path suffix accumulated before resolving the existing ancestor.
        ancestor = existing.path
        // Trusted ancestors can have symlink, mount or macOS firmlink aliases.
        // Compare device/inode identities plus the relative suffix at each ancestor.
        var identities: [DirectoryIdentity: String] = [:]
        while true {
            var info = stat()
            guard stat(ancestor, &info) == 0 else {
                throw Failure("cannot verify job output root ancestry: \(ancestor)")
            }
            let identity = DirectoryIdentity(
                device: UInt64(truncatingIfNeeded: info.st_dev), inode: UInt64(info.st_ino))
            if identities[identity] == nil { identities[identity] = "/" + suffix.joined(separator: "/") }
            guard ancestor != "/" else { break }
            suffix.insert((ancestor as NSString).lastPathComponent, at: 0)
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
        return RootAncestry(ancestors: identities, caseSensitive: caseSensitive)
    }

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

    public static func ensureFreeSpace(_ free: UInt64?, minimum: UInt64) throws {
        guard minimum > 0 else { return }
        guard let free else { throw Failure("cannot read free space on job output volume") }
        guard free >= minimum else {
            throw Failure("job output volume has \(free) bytes free; requires \(minimum) bytes")
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
    public var validate: @Sendable (String) throws -> Void
    public init(
        base: any FileSystem, roots: [String], validate: @escaping @Sendable (String) throws -> Void = JobStorage.check
    ) {
        self.base = base; self.roots = roots; self.validate = validate
    }
    private func check(_ path: String) throws {
        for root in roots where path == root || path.hasPrefix(root + "/") { try validate(root) }
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
