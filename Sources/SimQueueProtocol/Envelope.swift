// SPDX-License-Identifier: MIT

import SimQueueCore

/// Versioned envelope for newline-delimited JSON over the local socket (Phase 2).
public struct Envelope: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var kind: String

    public init(kind: String, schemaVersion: Int = Envelope.currentSchemaVersion) {
        self.kind = kind
        self.schemaVersion = schemaVersion
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case kind
    }
}

/// Ownership section of `simq doctor --json`. `owned_udids` is a stable contract: external
/// reapers read it to know which sims to leave alone. Add fields; never rename or remove.
public struct DoctorOwnership: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    /// Sorted UDIDs of every sim with a live ownership row (active or orphaned).
    public var ownedUDIDs: [String]

    public init(ownedUDIDs: [String], schemaVersion: Int = Envelope.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.ownedUDIDs = ownedUDIDs.sorted()
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case ownedUDIDs = "owned_udids"
    }
}
