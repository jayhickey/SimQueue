// SPDX-License-Identifier: MIT

import ArgumentParser
import SimQueueProtocol

struct Bump: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Change a queued job's priority (0...100, higher first).")
    @OptionGroup var connection: Connection
    @Argument var jobID: String
    @Argument var priority: Int

    func run() throws {
        guard (0...100).contains(priority) else { throw ValidationError("priority must be 0...100") }
        let result = try call(connection, .bump(BumpParams(jobID: jobID, priority: priority)))
        guard case .job(let job) = result else { throw failure(.protocolError) }
        if connection.json { try printJSON(job) } else { print(describe(job)) }
    }
}
