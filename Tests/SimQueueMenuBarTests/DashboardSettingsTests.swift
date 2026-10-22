// SPDX-License-Identifier: MIT

import Foundation
import XCTest

@testable import SimQueueMenuBar

final class DashboardSettingsTests: XCTestCase {
    func testDefaultsAndPersistenceAcrossPreferenceInstances() throws {
        let suite = "SimQueue-dashboard-settings-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(DashboardSettings.load(from: defaults), DashboardSettings())
        let saved = try DashboardSettings(address: " 100.101.102.103 ", portText: "8765")
        saved.save(to: defaults)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(DashboardSettings.load(from: reopened), saved)
        XCTAssertEqual(defaults.string(forKey: "DashboardBindAddress"), "100.101.102.103")
        XCTAssertEqual(defaults.integer(forKey: "DashboardPort"), 8765)
    }

    func testValidationAndWildcardSettings() throws {
        XCTAssertEqual(try DashboardSettings(address: "0.0.0.0", portText: "0").port, 0)
        for address in ["", "localhost", "::1", "256.1.1.1", "01.2.3.4", "1.2.3", "1.2.3.4:8765"] {
            XCTAssertThrowsError(try DashboardSettings(address: address, portText: "8765"))
        }
        for port in ["", "-1", "65536", "abc", "1.5"] {
            XCTAssertThrowsError(try DashboardSettings(address: "127.0.0.1", portText: port))
        }
    }

    func testInvalidStoredSettingsFallBackToLocalDefaults() throws {
        let suite = "SimQueue-dashboard-settings-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("invalid", forKey: "DashboardBindAddress")
        defaults.set(8765, forKey: "DashboardPort")
        XCTAssertEqual(DashboardSettings.load(from: defaults), DashboardSettings())
    }
}
