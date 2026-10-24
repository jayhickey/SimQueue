// SPDX-License-Identifier: MIT

import ArgumentParser
import SimQueueCore
import SimQueueProtocol

struct OutputHoldCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "output-hold",
        abstract: "Protect job output until an explicit permanent release.",
        subcommands: [Create.self, Show.self, List.self, Release.self])

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create an active hold, idempotently by UUID and label.")
        @OptionGroup var connection: Connection
        @Option(help: "Client-generated UUID. A released UUID can never be reused.") var id: String
        @Option(help: "Short descriptive label.") var label: String
        func run() throws {
            let id = try validatedOutputHoldID(id)
            do { try OutputHold.validateLabel(label) } catch { throw ValidationError(String(describing: error)) }
            guard case .outputHold(let result) = try call(connection, .outputHoldCreate(.init(id: id, label: label)))
            else {
                throw failure(.protocolError)
            }
            try display(result, connection: connection)
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show a hold and one page of member jobs.")
        @OptionGroup var connection: Connection
        @Argument var id: String
        @Option(help: "Membership cursor from next_job_id.") var afterJobId: String?
        @Option(help: "Page size, 1...200.") var limit = 100
        func run() throws {
            guard
                case .outputHold(let result) = try call(
                    connection,
                    .outputHoldShow(.init(id: try validatedOutputHoldID(id), afterJobID: afterJobId, limit: limit)))
            else { throw failure(.protocolError) }
            try display(result, connection: connection)
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List a page of active and released hold UUIDs.")
        @OptionGroup var connection: Connection
        @Option(help: "Hold cursor from next_id.") var afterId: String?
        @Option(help: "Page size, 1...200.") var limit = 100
        func run() throws {
            guard
                case .outputHolds(let result) = try call(
                    connection, .outputHoldList(.init(afterID: afterId, limit: limit)))
            else { throw failure(.protocolError) }
            if connection.json { return try printJSON(result) }
            for hold in result.holds {
                print("\(hold.id)  \(hold.releasedAt == nil ? "active" : "released")  \(hold.label)")
            }
            if let next = result.nextID { print("next_id: \(next)") }
        }
    }

    struct Release: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Permanently release a hold once all member jobs and writers have stopped.",
            discussion:
                "Original output ages resume immediately. Keep the hold through upload, review and any grace period.")
        @OptionGroup var connection: Connection
        @Argument var id: String
        func run() throws {
            guard
                case .outputHold(let result) = try call(
                    connection, .outputHoldRelease(.init(id: try validatedOutputHoldID(id))))
            else { throw failure(.protocolError) }
            try display(result, connection: connection)
        }
    }

    private static func display(_ result: OutputHoldResult, connection: Connection) throws {
        if connection.json { return try printJSON(result) }
        let hold = result.hold
        print("\(hold.id)  \(hold.releasedAt == nil ? "active" : "released")  \(hold.label)")
        for member in result.jobs { print(member.jobID) }
        if let next = result.nextJobID { print("next_job_id: \(next)") }
    }
}

/// Protected submission never falls back to ordinary submit, even on an old daemon.
func submitJob(
    _ params: SubmitParams, outputHold: String?, connection: Connection, stopRetrying: () -> Bool = { false }
) throws -> SubmitResponse {
    if let outputHold {
        let id = try validatedOutputHoldID(outputHold)
        guard
            case .submitHeld(let response) = try call(
                connection, .submitHeld(.init(holdID: id, submission: params)), reconnect: true,
                stopRetrying: stopRetrying),
            response.holdID == id
        else { throw failure(.protocolError) }
        return response.submission
    }
    guard
        case .submit(let response) = try call(connection, .submit(params), reconnect: true, stopRetrying: stopRetrying)
    else { throw failure(.protocolError) }
    return response
}

func validatedOutputHoldID(_ value: String) throws -> String {
    do { return try OutputHold.canonicalID(value) } catch { throw ValidationError(String(describing: error)) }
}
