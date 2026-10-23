// SPDX-License-Identifier: MIT

import Foundation

/// Pins each output root to its filesystem UUID, not its mount name. Only a small
/// JSON map lives on the state volume; checks never enumerate output directories.
public final class StorageVolumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var identities: [String: String]
    private let path: String
    private let probe: @Sendable (String) throws -> String
    private let persist: Bool

    public init(
        path: String, persist: Bool = true,
        probe: @escaping @Sendable (String) throws -> String = StorageVolumeGuard.volumeIdentity
    ) throws {
        self.path = path; self.probe = probe; self.persist = persist
        identities =
            FileManager.default.fileExists(atPath: path)
            ? try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path))) : [:]
    }

    public func check(_ root: String) throws {
        try JobStorage.check(root)
        let current = try probe(root)
        guard !current.isEmpty else { throw JobStorage.Failure("volume identity unavailable for \(root)") }
        lock.lock(); defer { lock.unlock() }
        if let expected = identities[root] {
            guard current == expected else {
                throw JobStorage.Failure(
                    "wrong volume at \(root); reconnect the original drive at its configured mount path. "
                        + "For a replacement drive, drain and configure a new dedicated job_output_root.")
            }
        } else {
            var updated = identities; updated[root] = current
            // Do not trust a binding until it is durably saved. Failure holds admission.
            if persist {
                try JSONEncoder().encode(updated).write(to: URL(fileURLWithPath: path), options: .atomic)
            }
            identities = updated
        }
    }

    public static func volumeIdentity(_ root: String) throws -> String {
        var ancestor = root
        while !FileManager.default.fileExists(atPath: ancestor), ancestor != "/" {
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
        #if os(macOS)
            let values = try URL(fileURLWithPath: ancestor).resourceValues(forKeys: [.volumeUUIDStringKey])
            guard let uuid = values.volumeUUIDString else {
                throw JobStorage.Failure("cannot read volume UUID for \(root)")
            }
            return uuid
        #else
            guard
                let number = try FileManager.default.attributesOfFileSystem(forPath: ancestor)[.systemNumber]
                    as? NSNumber
            else {
                throw JobStorage.Failure("cannot read filesystem identity for \(root)")
            }
            return number.stringValue
        #endif
    }
}
