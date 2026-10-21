// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import SimQueueProtocol

struct Drain: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop admitting work and wait until a planned restart is safe.",
        discussion:
            "Running jobs finish; queued and newly submitted jobs wait. The gate clears on daemon restart or simq resume. A timeout leaves the gate in place and never cancels jobs."
    )
    @OptionGroup var connection: Connection
    @Option(help: "How long to wait, for example 30m. A timeout leaves the daemon draining.")
    var timeout = "30m"
    @Flag(help: "Set the drain gate and return immediately.") var noWait = false

    func run() throws {
        guard let seconds = DurationParser.seconds(timeout), seconds > 0, seconds.isFinite else {
            throw ValidationError("--timeout needs a positive duration, for example 30m")
        }
        let deadline = Date().addingTimeInterval(seconds)
        guard case .status(var status) = try call(connection, .drain) else { throw failure(.protocolError) }
        while !noWait && status.drainComplete != true {
            guard Date() < deadline else {
                printError("drain timed out; jobs are still running and the drain gate remains set")
                throw failure(.waitTimeout)
            }
            Thread.sleep(forTimeInterval: min(0.2, max(0, deadline.timeIntervalSinceNow)))
            guard case .status(let next) = try call(connection, .status) else { throw failure(.protocolError) }
            guard next.daemon.epoch == status.daemon.epoch else {
                printError("daemon restarted while draining; check its status before continuing")
                throw failure(.daemonUnavailable)
            }
            status = next
        }
        if connection.json {
            try printJSON(status)
        } else {
            print(
                status.drainComplete == true ? "Drained; safe to restart simqd." : "Draining; running work will finish."
            )
        }
    }
}

struct Resume: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Resume admissions after a planned or infra-failure drain.")
    @OptionGroup var connection: Connection

    func run() throws {
        guard case .status(let status) = try call(connection, .resume) else { throw failure(.protocolError) }
        if connection.json { try printJSON(status) } else { print("Admissions resumed.") }
    }
}
