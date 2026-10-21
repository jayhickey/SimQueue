// SPDX-License-Identifier: MIT
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Owns the writer, so rotating never leaves the daemon writing to a renamed descriptor.
/// Four 5 MiB segments by default. One bounded reader; no subprocesses.
public final class RotatingDaemonLog: @unchecked Sendable {
    private let lock = NSLock()
    public let path: String
    public let segmentBytes: Int
    public let segments: Int
    private var bytes = 0
    private var output: FileHandle?
    nonisolated(unsafe) private static var redirected: RotatingDaemonLog?

    public init(path: String, segmentBytes: Int = 5 * 1024 * 1024, segments: Int = 4) throws {
        self.path = path; self.segmentBytes = max(1, segmentBytes); self.segments = max(1, segments)
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try openOutput()
    }
    private func openOutput() throws {
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let oldSize = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
        if oldSize > segmentBytes {
            let reader = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            try reader.seek(toOffset: UInt64(oldSize - segmentBytes))
            let recent = try reader.read(upToCount: segmentBytes) ?? Data()
            try reader.close()
            try recent.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        bytes = Int(try handle.seekToEnd())
        output = handle
    }
    public func append(_ data: Data) throws {
        try lock.withLock {
            // A previous rotation/write may have failed after closing or renaming the
            // writer. Reopen from the actual file length so disk recovery is automatic.
            if output == nil { try openOutput() }
            var offset = 0
            while offset < data.count {
                if bytes >= segmentBytes {
                    try output?.close(); output = nil
                    let files = FileManager.default
                    if segments > 1 {
                        try? files.removeItem(atPath: path + ".\(segments-1)")
                        if segments > 2 {
                            for n in stride(from: segments - 2, through: 1, by: -1)
                            where files.fileExists(atPath: path + ".\(n)") {
                                try files.moveItem(atPath: path + ".\(n)", toPath: path + ".\(n+1)")
                            }
                        }
                        try files.moveItem(atPath: path, toPath: path + ".1")
                    } else {
                        try files.removeItem(atPath: path)
                    }
                    try openOutput()
                }
                let size = min(segmentBytes - bytes, data.count - offset)
                do {
                    try output?.write(contentsOf: data.subdata(in: offset..<(offset + size)))
                } catch {
                    try? output?.close()
                    output = nil
                    throw error
                }
                offset += size; bytes += size
            }
        }
    }
    public static func redirect(to path: String) throws {
        let logger = try RotatingDaemonLog(path: path)
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw CocoaError(.fileWriteUnknown) }
        guard dup2(descriptors[1], STDOUT_FILENO) >= 0, dup2(descriptors[1], STDERR_FILENO) >= 0 else {
            close(descriptors[0]); close(descriptors[1]); throw CocoaError(.fileWriteUnknown)
        }
        close(descriptors[1]); redirected = logger
        let reader = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = read(reader.fileDescriptor, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                // Disk-pressure diagnostics remain available over the socket. Drain the
                // pipe even if disk writes fail, so logging cannot SIGPIPE the daemon.
                try? logger.append(Data(buffer.prefix(count)))
            }
        }
    }
}
