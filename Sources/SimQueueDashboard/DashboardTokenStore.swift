// SPDX-License-Identifier: MIT

import Foundation

#if canImport(Glibc)
    import Glibc
#else
    import Darwin
#endif

/// Shared by CLI and app dashboards for one daemon configuration.
public struct DashboardTokenStore {
    public let configPath: String
    public init(configPath: String) {
        // Match project onboarding: preserve a configured symlink and atomically
        // replace its resolved target rather than destroying the link.
        self.configPath = URL(fileURLWithPath: configPath).resolvingSymlinksInPath().path
    }

    public func loadOrCreate() throws -> String { try update(rotate: false) }
    public func rotate() throws -> String { try update(rotate: true) }

    public func current() throws -> String {
        guard let token = try configuration()["dashboard_token"] as? String,
            token.count == 36, UUID(uuidString: token) != nil
        else { throw Failure.invalidConfiguration }
        return token
    }

    private func update(rotate: Bool) throws -> String {
        let parent = (configPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = open(configPath + ".dashboard.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard lock >= 0 else { throw Failure.unavailable }
        defer { _ = close(lock) }
        try validate(lock)
        guard flock(lock, LOCK_EX) == 0 else { throw Failure.unavailable }
        defer { _ = flock(lock, LOCK_UN) }
        var config = try configuration()
        if !rotate, config["dashboard_token"] != nil { return try current() }
        let token = UUID().uuidString
        config["dashboard_token"] = token
        let data = try JSONSerialization.data(
            withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let temporary = configPath + "." + UUID().uuidString + ".tmp"
        let fd = open(temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.unavailable }
        defer { _ = unlink(temporary) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try file.write(contentsOf: data + Data("\n".utf8))
        try file.synchronize()
        try file.close()
        guard rename(temporary, configPath) == 0 else { throw Failure.unavailable }
        let directory = open(parent, O_RDONLY)
        if directory >= 0 { _ = fsync(directory); _ = close(directory) }
        return token
    }

    private func configuration() throws -> [String: Any] {
        let fd = open(configPath, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return [:] }
            throw Failure.unavailable
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        try validate(fd)
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Failure.unavailable }
        if info.st_mode & 0o777 != 0o600 {
            guard fchmod(fd, 0o600) == 0 else { throw Failure.unavailable }
        }
        let data = try file.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576,
            let config = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw Failure.invalidConfiguration }
        return config
    }

    private func validate(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid() else {
            throw Failure.unavailable
        }
    }

    enum Failure: Error, LocalizedError {
        case unavailable, invalidConfiguration
        var errorDescription: String? {
            switch self {
            case .unavailable: "Cannot access the owner-only dashboard configuration."
            case .invalidConfiguration:
                "Invalid dashboard configuration: dashboard_token must be a UUID string in a JSON object."
            }
        }
    }
}
