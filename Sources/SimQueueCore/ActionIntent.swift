// SPDX-License-Identifier: MIT

/// What a destructive host action targets, so recovery can check whether it happened.
public enum ActionTarget: Sendable, Equatable {
    case processGroup(Int32)
    case sim(udid: String)
    case path(String)
    /// Creating a sim with this name (the name carries the intent's id).
    case simCreate(name: String)

    public var kind: String {
        switch self {
        case .processGroup: return "process_group"
        case .sim: return "sim"
        case .path: return "path"
        case .simCreate: return "sim_create"
        }
    }

    public var value: String {
        switch self {
        case .processGroup(let pgid): return "\(pgid)"
        case .sim(let udid): return udid
        case .path(let path): return path
        case .simCreate(let name): return name
        }
    }

    public init?(kind: String, value: String) {
        switch kind {
        case "process_group":
            guard let pgid = Int32(value) else { return nil }
            self = .processGroup(pgid)
        case "sim": self = .sim(udid: value)
        case "path": self = .path(value)
        case "sim_create": self = .simCreate(name: value)
        default: return nil
        }
    }
}

/// A write-ahead record of a destructive action (spec §8a.3): written before the action,
/// removed together with the action's audit entry once the action is verified. One left
/// behind means the daemon (or its database) failed in between; recovery checks the target
/// and either confirms the action (audited then) or abandons the intent.
public struct ActionIntent: Sendable, Equatable {
    public var id: Int64
    public var target: ActionTarget
    /// The audit entry the action gets once confirmed (e.g. `cleanup_executed`).
    public var auditType: String
    public var detail: String
    public var jobID: String?
    /// The ownership row released with the confirmation, if any.
    public var resourceID: Int64?
    public var releaseReason: String?
    public var createdAt: Double
    public var passID: String?

    public init(
        id: Int64 = 0, target: ActionTarget, auditType: String, detail: String, jobID: String? = nil,
        resourceID: Int64? = nil, releaseReason: String? = nil, createdAt: Double = 0, passID: String? = nil
    ) {
        self.id = id
        self.target = target
        self.auditType = auditType
        self.detail = detail
        self.jobID = jobID
        self.resourceID = resourceID
        self.releaseReason = releaseReason
        self.createdAt = createdAt
        self.passID = passID
    }
}
