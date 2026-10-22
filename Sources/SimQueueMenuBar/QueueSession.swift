// SPDX-License-Identifier: MIT

import Foundation
import SimQueueIPC
import SimQueueProtocol

/// The native app uses the same owner-only socket as the CLI. No automatic mutation retries.
public struct QueueSession: Sendable {
    private let request: @Sendable (RequestParams) throws -> ResultPayload

    public init(request: @escaping @Sendable (RequestParams) throws -> ResultPayload) {
        self.request = request
    }

    public init(socketPath: String) {
        self.init { params in
            let client = SimQueueClient(socketPath: socketPath, timeoutSeconds: 3)
            guard let response = try client.send(Request(params: params)) else { throw SessionError.noResponse }
            switch response.body {
            case .result(let result): return result
            case .error(let error): throw error
            case .event: throw SessionError.noResponse
            }
        }
    }

    public enum SessionError: Error {
        case noResponse, daemonChanged
    }

    public func status() throws -> StatusResult {
        guard case .status(let value) = try request(.status) else { throw SessionError.noResponse }
        return value
    }

    /// Sets the gate before listing/canceling so queued work cannot start in between.
    /// Only admitted/running jobs are canceled; queued work stays persisted.
    public func beginStop(cancelActive: Bool, expectedEpoch: Int64) throws -> StatusResult {
        let current = try status()
        guard current.daemon.epoch == expectedEpoch else { throw SessionError.daemonChanged }
        guard case .status(let draining) = try request(.drain), draining.daemon.epoch == expectedEpoch else {
            throw SessionError.daemonChanged
        }
        if cancelActive {
            guard case .jobs(let jobs) = try request(.jobs(JobsParams(states: [.admitted, .running], limit: 10_000)))
            else { throw SessionError.noResponse }
            for job in jobs {
                let latest = try status()
                guard latest.daemon.epoch == expectedEpoch else { throw SessionError.daemonChanged }
                _ = try request(.cancel(CancelParams(jobID: job.id)))
            }
        }
        return draining
    }

    /// Updates never cancel work. A caller controls polling/deadline/cancellation;
    /// installation can proceed only after the epoch-checked service stop succeeds.
    public func stopForUpdate(
        expectedEpoch: Int64,
        service: @Sendable (StatusResult) throws -> (@Sendable () throws -> Void)?,
        poll: @Sendable () async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        _ = try beginStop(cancelActive: false, expectedEpoch: expectedEpoch)
        while true {
            try Task.checkCancellation()
            if try finishStop(expectedEpoch: expectedEpoch, service: service) { return }
            try await poll()
        }
    }

    /// Used only when an update wait is canceled before the final stop request.
    /// The daemon also rejects resume after its final stop acknowledgement.
    public func resumeAfterCanceledUpdate(expectedEpoch: Int64) throws {
        guard try status().daemon.epoch == expectedEpoch else { throw SessionError.daemonChanged }
        guard case .status(let resumed) = try request(.resume), resumed.daemon.epoch == expectedEpoch else {
            throw SessionError.daemonChanged
        }
    }

    /// The daemon rechecks drain completion under its service lock before acknowledging stop.
    public func finishStop(
        expectedEpoch: Int64,
        service: @Sendable (StatusResult) throws -> (@Sendable () throws -> Void)? = { _ in nil }
    ) throws -> Bool {
        let current = try status()
        guard current.daemon.epoch == expectedEpoch else { throw SessionError.daemonChanged }
        guard current.drainComplete == true else { return false }
        let stopService = try service(current)
        guard
            case .status(let stopped) = try request(
                .stop(StopParams(epoch: expectedEpoch, exitDaemon: stopService == nil))),
            stopped.daemon.epoch == expectedEpoch
        else {
            throw SessionError.noResponse
        }
        try stopService?()
        return true
    }
}
