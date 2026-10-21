// SPDX-License-Identifier: MIT

import Foundation

/// The file-system operations SimQueue needs for run and DerivedData directories.
/// Injected so recovery and soak tests never touch real disk.
public protocol FileSystem: Sendable {
    func fileExists(_ path: String) -> Bool
    /// Absolute paths of the direct children of `path`; empty if it doesn't exist.
    func children(of path: String) throws -> [String]
    func createDirectory(_ path: String) throws
    func removeItem(_ path: String) throws
    /// Total bytes under `path` (a file or a directory tree); nil if unknown.
    func sizeOfItem(_ path: String) -> UInt64?
}

extension FileSystem {
    public func sizeOfItem(_ path: String) -> UInt64? { nil }
}

public struct LocalFileSystem: FileSystem {
    public init() {}

    public func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func children(of path: String) throws -> [String] {
        guard fileExists(path) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(atPath: path).sorted().map { "\(path)/\($0)" }
    }

    public func createDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    public func removeItem(_ path: String) throws {
        guard fileExists(path) else {
            return
        }
        try FileManager.default.removeItem(atPath: path)
    }

    public func sizeOfItem(_ path: String) -> UInt64? {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        guard isDirectory.boolValue else {
            return (try? manager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value
        }
        var total: UInt64 = 0
        guard let walker = manager.enumerator(atPath: path) else { return nil }
        while let relative = walker.nextObject() as? String {
            let attributes = try? manager.attributesOfItem(atPath: path + "/" + relative)
            if attributes?[.type] as? FileAttributeType == .typeRegular {
                total += (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
            }
        }
        return total
    }
}

/// In-memory file system: a set of directory paths.
public final class FakeFileSystem: FileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var directories: Set<String>
    public private(set) var removed: [String] = []
    /// Paths whose removal throws.
    public var removeFails: Set<String> = []
    /// Paths whose removal "succeeds" but leaves the directory in place.
    public var removeHasNoEffect: Set<String> = []
    /// Sizes reported by `sizeOfItem` (paths not listed are unknown).
    public var sizes: [String: UInt64] = [:]

    public init(directories: Set<String> = []) {
        self.directories = directories
    }

    public func fileExists(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return directories.contains(path)
    }

    public func children(of path: String) throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let prefix = path + "/"
        return directories.filter { $0.hasPrefix(prefix) && !$0.dropFirst(prefix.count).contains("/") }.sorted()
    }

    public func createDirectory(_ path: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var current = ""
        for component in path.split(separator: "/") {
            current += "/\(component)"
            directories.insert(current)
        }
    }

    public func removeItem(_ path: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if removeFails.contains(path) {
            throw FakeFault.injected("remove \(path)")
        }
        removed.append(path)
        if removeHasNoEffect.contains(path) {
            return
        }
        directories = directories.filter { $0 != path && !$0.hasPrefix(path + "/") }
    }

    public func sizeOfItem(_ path: String) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        if let size = sizes[path] { return size }
        let nested = sizes.filter { $0.key.hasPrefix(path + "/") }
        return nested.isEmpty ? nil : nested.values.reduce(0, +)
    }

    public var allDirectories: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return directories
    }
}
