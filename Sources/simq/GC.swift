// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import SimQueueProtocol

struct GC: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gc",
        abstract: "List what artifact retention would remove now; remove it with --apply.",
        discussion: """
            A dry run by default: lists run dirs past their retention \
            (age_rules.artifact_retention_days in config.json: succeeded, other, unknown, kept) \
            and, with age_rules.artifact_budget_gib set, the oldest ended run dirs over the \
            budget (succeeded before failed). Jobs submitted with --keep \
            are never removed for the budget. --apply removes everything listed now (the \
            watchdog removes a few per pass); refused while cleanup_mode is report-only.
            """)
    @OptionGroup var connection: Connection
    @Flag(help: "Remove what's listed.") var apply = false

    func run() throws {
        guard case .gc(let result) = try call(connection, .gc(GCParams(apply: apply ? true : nil)))
        else { throw failure(.protocolError) }
        if connection.json { return try printJSON(result) }
        let total = result.candidates.compactMap(\.bytes).reduce(0, +)
        if result.candidates.isEmpty { print("nothing to remove") }
        for entry in result.candidates {
            print("\(entry.path)  \(entry.bytes.map(Self.size) ?? "?")  \(entry.reason)")
        }
        let budget = result.budgetBytes.map { " (budget \(Self.size($0)))" } ?? ""
        if result.applied {
            if let summary = result.cleanup {
                print(
                    "removed \(summary.removedCount) of \(result.candidates.count), \(Self.size(summary.removedBytes)) logical bytes\(summary.unknownRemovedSizes > 0 ? " + unknown sizes" : "")\(budget)"
                )
                print(
                    "\(summary.deferredCount) deferred or protected; \(summary.unavailableRoots.count) unavailable roots"
                )
                for root in summary.unavailableRoots { print("storage: \(root)") }
            } else {
                print(
                    "removed \(result.removed.count) of \(result.candidates.count); removed size unavailable\(budget)")
            }
            for failure in result.failures { print("failed: \(failure)") }
        } else if !result.candidates.isEmpty {
            print("dry run: \(result.candidates.count) run dirs, \(Self.size(total))\(budget); --apply to remove")
        }
    }

    static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .binary)
    }
}
