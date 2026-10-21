// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import XCTest

final class SimNamingTests: XCTestCase {
    func testTheSimqRootCantBeConfiguredAway() throws {
        XCTAssertEqual(SimNamingScheme().prefix, "simq")
        XCTAssertEqual(SimNamingScheme(prefix: "simq").prefix, "simq")
        XCTAssertEqual(SimNamingScheme(prefix: "").prefix, "simq")
        XCTAssertEqual(SimNamingScheme(prefix: "ci").prefix, "simq-ci", "config only adds after simq-")
        XCTAssertEqual(SimNamingScheme(prefix: "simq-ci").prefix, "simq-ci")
        XCTAssertEqual(SimNamingScheme(prefix: "-other-").prefix, "simq-other")
        let decoded = try JSONDecoder().decode(SimNamingScheme.self, from: Data(#"{"prefix":"xcsteward"}"#.utf8))
        XCTAssertEqual(decoded.prefix, "simq-xcsteward")
        for scheme in [SimNamingScheme(), SimNamingScheme(prefix: "ci"), decoded] {
            for name in [
                scheme.poolSimName(slot: 3, intentID: 41), scheme.poolSimName(project: "app", slot: 1, intentID: 7),
                scheme.poolName(project: "app", index: 2),
                scheme.templateName(project: "app", profile: "p", intentID: 9),
            ] {
                XCTAssertTrue(name.hasPrefix("simq-"), name)
                XCTAssertTrue(scheme.owns(name), name)
            }
        }
        XCTAssertEqual(SimNamingScheme().poolSimName(slot: 3, intentID: 41), "simq-pool-3-41")
    }

    /// Templates were called goldens: new ones are `simq-template-...`, and `simq-golden-...`
    /// sims from before the rename are still templates.
    func testTemplateNamesAndTheLegacyGoldenShape() {
        let scheme = SimNamingScheme()
        XCTAssertEqual(
            scheme.templateName(project: "exampleapp", profile: "default", intentID: 1),
            "simq-template-exampleapp-default-1")
        for name in ["simq-template-exampleapp-default-1", "simq-golden-exampleapp-default-1"] {
            XCTAssertTrue(scheme.isTemplate(name), name)
            XCTAssertTrue(scheme.owns(name), name)
        }
        for name in ["simq-pool-1-2", "simq-exampleapp-1-3", "golden-x", "simq-goldenish-1"] {
            XCTAssertFalse(scheme.isTemplate(name), name)
        }
        XCTAssertTrue(SimNamingScheme(prefix: "ci").isTemplate("simq-ci-golden-app-p-4"))
    }

    // MARK: - Owner tags (two daemons on one host)

    func testOwnerTagsAreStablePerStateDirAndDistinctAcrossThem() {
        let a = SimNamingScheme.ownerTag(stateDirectory: "/Users/me/Library/Application Support/SimQueue")
        XCTAssertEqual(a, SimNamingScheme.ownerTag(stateDirectory: "/Users/me/Library/Application Support/SimQueue/"))
        XCTAssertNotEqual(a, SimNamingScheme.ownerTag(stateDirectory: "/tmp/simq-ci"))
        XCTAssertEqual(a.count, 9)
        XCTAssertTrue(a.hasPrefix("d"))
        XCTAssertEqual(SimNamingScheme.ownerTag(of: "simq-pool-3-41-\(a)"), a)
    }

    func testTaggedPoolNamesStayUniqueAndParseTheirSlot() {
        let mine = SimNamingScheme(ownerTag: "d0000abcd")
        let theirs = SimNamingScheme(ownerTag: "d1234beef")
        let name = mine.poolSimName(slot: 3, intentID: 41)
        XCTAssertEqual(name, "simq-pool-3-41-d0000abcd")
        XCTAssertNotEqual(name, theirs.poolSimName(slot: 3, intentID: 41), "same slot and intent id, different daemon")
        XCTAssertEqual(SimNamingScheme.poolSlot(of: name), 3)
        XCTAssertEqual(SimNamingScheme.poolSlot(of: "simq-pool-3-41"), 3, "legacy untagged names still parse")
        XCTAssertNil(SimNamingScheme.ownerTag(of: "simq-pool-3-41"), "an intent id is never a tag")
        XCTAssertNil(SimNamingScheme.ownerTag(of: "simq-pool-3-123456789"))
    }

    func testAnotherDaemonsSimsAreInTheNamespaceButNotOwned() {
        let mine = SimNamingScheme(ownerTag: "d0000abcd")
        let theirs = SimNamingScheme(ownerTag: "d1234beef").poolSimName(slot: 1, intentID: 1)
        XCTAssertTrue(mine.inNamespace(theirs))
        XCTAssertTrue(mine.belongsToAnotherDaemon(theirs))
        XCTAssertFalse(mine.owns(theirs))
        XCTAssertFalse(mine.isLookalike(theirs), "SimQueue's own namespace, not a lookalike")
        XCTAssertTrue(mine.owns(mine.poolSimName(slot: 1, intentID: 1)))
        XCTAssertTrue(mine.owns("simq-pool-1-1"), "untagged (legacy) names keep the old rule")
        XCTAssertTrue(SimNamingScheme().belongsToAnotherDaemon(theirs), "an untagged daemon owns no tagged sim")
    }

    func testTheReaperLeavesAnotherDaemonsSimsAlone() {
        let mine = SimNamingScheme(ownerTag: "d0000abcd")
        let theirs = SimDevice(udid: "T", name: "simq-pool-1-1-d1234beef", isBooted: true)
        let ownLeak = SimDevice(udid: "O", name: "simq-pool-2-5-d0000abcd", isBooted: false)
        let legacyLeak = SimDevice(udid: "L", name: "simq-pool-3-6", isBooted: false)
        let actions = Reconciler.plan(
            resources: [], activeJobs: [], epoch: 1, world: ObservedWorld(sims: [theirs, ownLeak, legacyLeak]),
            naming: mine, layout: RunDirectoryLayout(root: "/fake/simq"))
        XCTAssertEqual(
            actions, [.deleteSim(udid: "L", resourceID: nil), .deleteSim(udid: "O", resourceID: nil)],
            "own and legacy leaks reaped; the other daemon's sim neither reaped nor reported as foreign")
    }
}
