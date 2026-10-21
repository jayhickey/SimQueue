// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueIPC
import SimQueueProtocol

/// Narrow browser API; never forwards arbitrary daemon methods.
public struct DashboardAPI {
    public static let historyLimit = 100
    public static let activeLimit = 10_000
    private let observe: (RequestParams) throws -> ResultPayload

    public init(observe: @escaping (RequestParams) throws -> ResultPayload) {
        self.observe = observe
    }

    public init(socketPath: String) {
        self.init { params in
            let client = SimQueueClient(socketPath: socketPath, timeoutSeconds: 2)
            guard let response = try client.send(Request(params: params)) else { throw DashboardError.unavailable }
            switch response.body {
            case .result(let value): return value
            case .error(let error): throw error
            case .event: throw DashboardError.unavailable
            }
        }
    }

    public func response(path: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if path == "snapshot" {
            guard case .status(let status) = try observe(.status),
                case .jobs(let active) = try observe(
                    .jobs(JobsParams(states: [.queued, .admitted, .running], limit: Self.activeLimit))),
                case .jobs(let recent) = try observe(
                    .jobs(JobsParams(states: JobState.allCases.filter(\.isTerminal), limit: Self.historyLimit)))
            else { throw DashboardError.unavailable }
            return try encoder.encode(
                Snapshot(
                    status: status, active: active, recent: recent, generatedAt: Timestamp(Date().timeIntervalSince1970)
                ))
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, !parts[1].isEmpty, parts[1].utf8.count <= 128,
            parts[1].utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
            })
        else { throw DashboardError.notFound }
        switch parts[0] {
        case "job":
            guard case .job(let job) = try observe(.explain(JobRef(jobID: parts[1]))) else {
                throw DashboardError.unavailable
            }
            return try encoder.encode(job)
        case "logs":
            guard case .logs(let logs) = try observe(.logs(LogsParams(jobID: parts[1], offset: 0, maxBytes: 32_768)))
            else {
                throw DashboardError.unavailable
            }
            return try encoder.encode(logs)
        default: throw DashboardError.notFound
        }
    }

    public func mutate(path: String) throws -> Data {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !parts[1].isEmpty, parts[1].utf8.count <= 128,
            parts[1].utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
            })
        else { throw DashboardError.notFound }
        let params: RequestParams
        if parts[0] == "cancel", parts.count == 2 {
            params = .cancel(CancelParams(jobID: parts[1]))
        } else if parts[0] == "priority", parts.count == 3, let priority = Int(parts[2]), Priority.isValid(priority) {
            params = .bump(BumpParams(jobID: parts[1], priority: priority))
        } else {
            throw ProtocolError(.invalidArgument, "use cancel/JOB or priority/JOB/0...100")
        }
        guard case .job(let job) = try observe(params) else { throw DashboardError.unavailable }
        return try JSONEncoder().encode(job)
    }

    struct Snapshot: Encodable {
        let status: StatusResult
        let active: [JobInfo]
        let recent: [JobInfo]
        let generatedAt: Timestamp
    }
}

public enum DashboardError: Error {
    case unavailable
    case notFound
}
