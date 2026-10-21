// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueDaemon
import XCTest

/// `age_rules.artifact_retention_days.derived_data`: one age cutoff, in days.
final class RetentionConfigTests: XCTestCase {
    func testDerivedDataCutoffParsesAndDefaultsToOneDay() throws {
        XCTAssertEqual(DaemonConfig().reliability.ageRules.artifactRetention.derivedDataSeconds, 86_400)
        let config = try DaemonConfig.parse(
            Data(#"{"age_rules": {"artifact_retention_days": {"derived_data": 0.5}}}"#.utf8))
        XCTAssertEqual(config.reliability.ageRules.artifactRetention.derivedDataSeconds, 43_200)
        XCTAssertThrowsError(
            try DaemonConfig.parse(Data(#"{"age_rules": {"artifact_retention_days": {"derived_data": 0}}}"#.utf8)))
        let example = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/config.example.json").path
        let boundedExample = try DaemonConfig.load(path: example).reliability.ageRules.artifactRetention
        XCTAssertEqual(boundedExample.derivedDataSeconds, 2 * 3600, accuracy: 0.001)
        XCTAssertEqual(boundedExample.budgetBytes, 20 * ByteSize.gibibyte)
        XCTAssertEqual(boundedExample.succeededSeconds, 2 * 86_400)
        XCTAssertEqual(boundedExample.otherSeconds, 7 * 86_400)
    }

    func testBudgetAndKeptParseAndAreOffOrNinetyDaysByDefault() throws {
        let defaults = DaemonConfig().reliability.ageRules.artifactRetention
        XCTAssertNil(defaults.budgetBytes)
        XCTAssertEqual(defaults.keptRetentionSeconds, 90 * 86_400)
        let config = try DaemonConfig.parse(
            Data(#"{"age_rules": {"artifact_budget_gib": 2, "artifact_retention_days": {"kept": 3}}}"#.utf8))
        XCTAssertEqual(config.reliability.ageRules.artifactRetention.budgetBytes, 2 * 1_073_741_824)
        XCTAssertEqual(config.reliability.ageRules.artifactRetention.keptSeconds, 3 * 86_400)
        for bad in [
            #"{"age_rules": {"artifact_budget_gib": 0}}"#, #"{"age_rules": {"artifact_retention_days": {"kept": -1}}}"#,
        ] {
            XCTAssertThrowsError(try DaemonConfig.parse(Data(bad.utf8)), bad)
        }
    }
}
