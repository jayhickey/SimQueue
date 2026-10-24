// SPDX-License-Identifier: MIT

import SimQueueCore

public struct OutputHoldCreateParams: Sendable, Equatable, Codable {
    public var id: String
    public var label: String
    public init(id: String, label: String) { self.id = id; self.label = label }
}

/// show/release share a bounded membership page. Release always checks all members.
public struct OutputHoldRef: Sendable, Equatable, Codable {
    public var id: String
    public var afterJobID: String?
    public var limit: Int?
    public init(id: String, afterJobID: String? = nil, limit: Int? = nil) {
        self.id = id; self.afterJobID = afterJobID; self.limit = limit
    }
    enum CodingKeys: String, CodingKey {
        case id, limit
        case afterJobID = "after_job_id"
    }
}

public struct OutputHoldListParams: Sendable, Equatable, Codable {
    public var afterID: String?
    public var limit: Int?
    public init(afterID: String? = nil, limit: Int? = nil) { self.afterID = afterID; self.limit = limit }
    enum CodingKeys: String, CodingKey {
        case limit
        case afterID = "after_id"
    }
}

public struct SubmitHeldParams: Sendable, Equatable, Codable {
    public var holdID: String
    public var submission: SubmitParams
    public init(holdID: String, submission: SubmitParams) { self.holdID = holdID; self.submission = submission }
    enum CodingKeys: String, CodingKey {
        case submission
        case holdID = "hold_id"
    }
}

/// Wire timestamps follow the protocol's RFC 3339 UTC convention.
public struct OutputHoldInfo: Sendable, Equatable, Codable {
    public var id: String
    public var label: String
    public var createdAt: Timestamp
    public var releasedAt: Timestamp?
    public init(_ hold: OutputHold) {
        id = hold.id; label = hold.label
        createdAt = Timestamp(hold.createdAt); releasedAt = Timestamp(hold.releasedAt)
    }
    enum CodingKeys: String, CodingKey {
        case id, label
        case createdAt = "created_at"
        case releasedAt = "released_at"
    }
}

public struct OutputHoldMembershipInfo: Sendable, Equatable, Codable {
    public var jobID: String
    public var attachedAt: Timestamp
    public init(_ membership: OutputHoldMembership) {
        jobID = membership.jobID; attachedAt = Timestamp(membership.attachedAt)
    }
    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case attachedAt = "attached_at"
    }
}

public struct OutputHoldResult: Sendable, Equatable, Codable {
    public var hold: OutputHoldInfo
    public var jobs: [OutputHoldMembershipInfo]
    /// A nonempty full page returns its final id; an empty next page ends traversal.
    public var nextJobID: String?
    public init(hold: OutputHold, jobs: [OutputHoldMembership], nextJobID: String?) {
        self.hold = OutputHoldInfo(hold); self.jobs = jobs.map(OutputHoldMembershipInfo.init);
        self.nextJobID = nextJobID
    }
    enum CodingKeys: String, CodingKey {
        case hold, jobs
        case nextJobID = "next_job_id"
    }
}

public struct OutputHoldsResult: Sendable, Equatable, Codable {
    public var holds: [OutputHoldInfo]
    public var nextID: String?
    public init(holds: [OutputHold], nextID: String?) {
        self.holds = holds.map(OutputHoldInfo.init); self.nextID = nextID
    }
    enum CodingKeys: String, CodingKey {
        case holds
        case nextID = "next_id"
    }
}

/// Explicit acknowledgement: an ordinary submit result cannot satisfy protected submission.
public struct SubmitHeldResponse: Sendable, Equatable, Codable {
    public var holdID: String
    public var submission: SubmitResponse
    public init(holdID: String, submission: SubmitResponse) { self.holdID = holdID; self.submission = submission }
    enum CodingKeys: String, CodingKey {
        case submission
        case holdID = "hold_id"
    }
}
