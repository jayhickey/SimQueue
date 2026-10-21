// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore

// MARK: - Sim pool rows

extension JobStore {
    /// Every pool sim, oldest first.
    public func poolSims() throws -> [PoolSim] {
        try database.query("SELECT sim_json FROM pool_sims;").compactMap { row in
            row.string("sim_json").flatMap { try? JSONDecoder().decode(PoolSim.self, from: Data($0.utf8)) }
        }.sorted { ($0.createdAt, $0.udid) < ($1.createdAt, $1.udid) }
    }

    public func savePoolSim(_ sim: PoolSim) throws {
        let json = String(decoding: try JSONEncoder().encode(sim), as: UTF8.self)
        try database.run(
            "INSERT OR REPLACE INTO pool_sims (udid, sim_json) VALUES (?, ?);", [.text(sim.udid), .text(json)])
    }

    public func deletePoolSim(udid: String) throws {
        try database.run("DELETE FROM pool_sims WHERE udid = ?;", [.text(udid)])
    }
}
