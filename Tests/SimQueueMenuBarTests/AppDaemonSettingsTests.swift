// SPDX-License-Identifier: MIT

import Foundation
import SimQueueMenuBar
import XCTest

final class AppDaemonSettingsTests: XCTestCase {
    func testRequiresDefaultStateAndExplicitlyDisabledCLIStartup() throws {
        let home = "/isolated/home"
        let state = home + "/Library/Application Support/SimQueue"
        try AppDaemonSettings.validate(config: Data(#"{"autostart":false}"#.utf8), stateDirectory: state, home: home)
        for json in [
            #"{}"#, #"{"autostart":true}"#, #"{"autostart":0}"#, #"{"autostart":"false"}"#,
            #"{"autostart":{"enabled":false}}"#,
        ] {
            XCTAssertThrowsError(
                try AppDaemonSettings.validate(config: Data(json.utf8), stateDirectory: state, home: home))
        }
        XCTAssertThrowsError(
            try AppDaemonSettings.validate(
                config: Data(#"{"autostart":false}"#.utf8), stateDirectory: "/other", home: home))
    }
}
