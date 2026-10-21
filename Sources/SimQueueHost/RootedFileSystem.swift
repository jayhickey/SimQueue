// SPDX-License-Identifier: MIT

import Foundation

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// Why `RootedFileSystem` refused a path.
public enum PathSafetyError: Error, Equatable, CustomStringConvertible {
    case outsideRoots(String)
    case symlinkInPath(String)
    case system(call: String, path: String, errno: Int32)

    public var description: String {
        switch self {
        case .outsideRoots(let path): "\(path) is outside SimQueue's own directories; refusing"
        case .symlinkInPath(let path): "\(path) goes through a symlink; refusing"
        case .system(let call, let path, let code): "\(call) \(path) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// The real file system, limited to SimQueue's own roots (simqd's work and jobs
/// directories). Every path must be absolute, strictly inside one root, free of `.`/`..`
/// components, and must not pass through a symlink below the root. Nothing follows a
/// symlink: a symlink is listed, sized and removed as the link itself, never its target.
/// The roots' own ancestors are trusted (they come from the state directory the operator
/// chose).
public struct RootedFileSystem: FileSystem {
    public let roots: [String]

    public init(roots: [String]) {
        self.roots = roots.map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
    }

    /// The root `path` sits under (or is), or nil if it is outside every root or malformed.
    func root(of path: String) -> String? {
        guard path.hasPrefix("/"), !path.contains("//") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.dropFirst().contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        return roots.first { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Checks `path` is inside a root and that no component from the root down to (but not
    /// including) `path` itself is a symlink. `allowRoot` permits the root itself.
    func check(_ path: String, allowRoot: Bool) throws {
        guard let root = root(of: path) else { throw PathSafetyError.outsideRoots(path) }
        if path == root {
            guard allowRoot else { throw PathSafetyError.outsideRoots(path) }
            if Self.isSymlink(root) { throw PathSafetyError.symlinkInPath(path) }
            return
        }
        var current = root
        if Self.isSymlink(current) { throw PathSafetyError.symlinkInPath(path) }
        let relative = path.dropFirst(root.count + 1).split(separator: "/")
        for component in relative.dropLast() {
            current += "/\(component)"
            if Self.isSymlink(current) { throw PathSafetyError.symlinkInPath(path) }
        }
    }

    static func lstatMode(_ path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode
    }

    static func isSymlink(_ path: String) -> Bool {
        lstatMode(path).map { $0 & S_IFMT == S_IFLNK } ?? false
    }

    static func isRealDirectory(_ path: String) -> Bool {
        lstatMode(path).map { $0 & S_IFMT == S_IFDIR } ?? false
    }

    public func fileExists(_ path: String) -> Bool {
        guard (try? check(path, allowRoot: true)) != nil else { return false }
        return Self.lstatMode(path) != nil
    }

    public func children(of path: String) throws -> [String] {
        try check(path, allowRoot: true)
        // A symlinked directory is never entered.
        guard Self.isRealDirectory(path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: path).sorted().map { "\(path)/\($0)" }
    }

    public func createDirectory(_ path: String) throws {
        guard let root = root(of: path) else { throw PathSafetyError.outsideRoots(path) }
        try check(path, allowRoot: true)
        var current = ""
        for component in path.split(separator: "/") {
            current += "/\(component)"
            // Ancestors of the root are created as needed but never inspected for links.
            let insideRoot = current == root || current.hasPrefix(root + "/")
            if let mode = Self.lstatMode(current) {
                if insideRoot, mode & S_IFMT != S_IFDIR { throw PathSafetyError.symlinkInPath(path) }
                continue
            }
            guard mkdir(current, 0o700) == 0 || errno == EEXIST else {
                throw PathSafetyError.system(call: "mkdir", path: current, errno: errno)
            }
            if insideRoot, !Self.isRealDirectory(current) { throw PathSafetyError.symlinkInPath(path) }
        }
    }

    public func removeItem(_ path: String) throws {
        try check(path, allowRoot: false)
        try Self.removeTree(path)
    }

    /// Removes `path` and everything under it without following any symlink: a link is
    /// unlinked, a real directory is emptied then removed. Missing is fine.
    public static func removeTree(_ path: String) throws {
        guard let mode = lstatMode(path) else { return }
        if mode & S_IFMT == S_IFDIR {
            for name in try FileManager.default.contentsOfDirectory(atPath: path) {
                try removeTree(path + "/" + name)
            }
            guard rmdir(path) == 0 || errno == ENOENT else {
                throw PathSafetyError.system(call: "rmdir", path: path, errno: errno)
            }
        } else {
            guard unlink(path) == 0 || errno == ENOENT else {
                throw PathSafetyError.system(call: "unlink", path: path, errno: errno)
            }
        }
    }

    /// Bytes in regular files under `path`, counting a symlink as nothing and never
    /// entering one. Nil if `path` is unsafe or missing.
    public func sizeOfItem(_ path: String) -> UInt64? {
        guard (try? check(path, allowRoot: true)) != nil, Self.lstatMode(path) != nil else { return nil }
        return Self.treeSize(path)
    }

    static func treeSize(_ path: String) -> UInt64 {
        var info = stat()
        guard lstat(path, &info) == 0 else { return 0 }
        switch info.st_mode & S_IFMT {
        case S_IFREG:
            return UInt64(max(0, info.st_size))
        case S_IFDIR:
            let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            return names.reduce(0) { $0 + treeSize(path + "/" + $1) }
        default:
            return 0
        }
    }
}
