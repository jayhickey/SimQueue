// SPDX-License-Identifier: MIT

import SimQueueCore
import XCTest

/// `ReconcileAction.description` must print what Swift's default reflection printed before
/// it existed: audit details and anomaly texts already in databases use that form.
final class ReconcileActionDescriptionTests: XCTestCase {
    /// Same shape as `ReconcileAction`, with no custom description.
    private enum Reflected {
        case markGone(resourceID: Int64)
        case adopt(resourceID: Int64)
        case killProcessGroup(pgid: Int32, resourceID: Int64)
        case deleteSim(udid: String, resourceID: Int64?)
        case removeDirectory(path: String, resourceID: Int64?)
        case revokeLease(resourceID: Int64)
        case reportForeignSim(udid: String, name: String)
    }

    func testMatchesDefaultReflection() {
        let pairs: [(ReconcileAction, Reflected)] = [
            (.markGone(resourceID: 7), .markGone(resourceID: 7)),
            (.adopt(resourceID: 8), .adopt(resourceID: 8)),
            (.killProcessGroup(pgid: -3, resourceID: 9), .killProcessGroup(pgid: -3, resourceID: 9)),
            (.deleteSim(udid: "A-1", resourceID: 4), .deleteSim(udid: "A-1", resourceID: 4)),
            (.deleteSim(udid: "q\"u\\o\n", resourceID: nil), .deleteSim(udid: "q\"u\\o\n", resourceID: nil)),
            (.removeDirectory(path: "/x/y z", resourceID: nil), .removeDirectory(path: "/x/y z", resourceID: nil)),
            (.removeDirectory(path: "/é/ü", resourceID: 12), .removeDirectory(path: "/é/ü", resourceID: 12)),
            (.revokeLease(resourceID: 1), .revokeLease(resourceID: 1)),
            (.reportForeignSim(udid: "U", name: "iPhone \"16\""), .reportForeignSim(udid: "U", name: "iPhone \"16\"")),
        ]
        for (action, reflected) in pairs {
            XCTAssertEqual("\(action)", "\(reflected)")
        }
    }
}
