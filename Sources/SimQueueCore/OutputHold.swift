// SPDX-License-Identifier: MIT

import Foundation

public enum OutputHoldError: Error, Equatable, CustomStringConvertible {
    case invalidArgument(String)
    case notFound(String)
    case conflict(String)
    case inUse(String)

    public var description: String {
        switch self {
        case .invalidArgument(let detail), .conflict(let detail), .inUse(let detail): return detail
        case .notFound(let id): return "output hold \(id) not found"
        }
    }
}

/// A deletion veto for whole job run directories. No expiry, lease or writer ownership.
public struct OutputHold: Sendable, Equatable, Codable {
    public var id: String
    public var label: String
    public var createdAt: Double
    public var releasedAt: Double?

    public init(id: String, label: String, createdAt: Double, releasedAt: Double? = nil) {
        self.id = id; self.label = label; self.createdAt = createdAt; self.releasedAt = releasedAt
    }

    public static func canonicalID(_ value: String) throws -> String {
        guard value.utf8.count == 36, let uuid = UUID(uuidString: value) else {
            throw OutputHoldError.invalidArgument("output hold id must be a hyphenated UUID")
        }
        return uuid.uuidString.lowercased()
    }

    public static func validateLabel(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 256, JobKindLabel.isValid(value) else {
            throw OutputHoldError.invalidArgument(
                "output hold label must be printable, nonempty, at most 100 characters and 256 UTF-8 bytes, without surrounding whitespace"
            )
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, label
        case createdAt = "created_at"
        case releasedAt = "released_at"
    }
}

public struct OutputHoldMembership: Sendable, Equatable, Codable {
    public var jobID: String
    public var attachedAt: Double

    public init(jobID: String, attachedAt: Double) {
        self.jobID = jobID; self.attachedAt = attachedAt
    }

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case attachedAt = "attached_at"
    }
}
