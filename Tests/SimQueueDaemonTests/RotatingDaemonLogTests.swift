// SPDX-License-Identifier: MIT
import Foundation
import SimQueueDaemon
import SimQueueHost
import XCTest

final class RotatingDaemonLogTests: XCTestCase {
    func testRotationCapsEverySegmentAndKeepsWritingToCurrentFile() throws {
        let dir = testScratchRoot() + "/log-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/simqd.log"
        let logger = try RotatingDaemonLog(path: path, segmentBytes: 128, segments: 3)
        try logger.append(Data(repeating: 65, count: 2048))
        try logger.append(Data("last-diagnostic".utf8))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir)
        XCTAssertEqual(names.sorted(), ["simqd.log", "simqd.log.1", "simqd.log.2"])
        for name in names {
            let size =
                (try FileManager.default.attributesOfItem(atPath: dir + "/" + name)[.size] as? NSNumber)?.intValue ?? -1
            XCTAssertLessThanOrEqual(size, 128)
        }
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "last-diagnostic")
    }

    func testLoggingRecoversAfterRotationLosesItsCurrentPath() throws {
        let dir = testScratchRoot() + "/log-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/simqd.log"
        let logger = try RotatingDaemonLog(path: path, segmentBytes: 8, segments: 2)
        try logger.append(Data("12345678".utf8))
        // A missing current path reproduces the recoverable state after a rotation
        // closes its writer but cannot create the replacement file.
        try FileManager.default.removeItem(atPath: path)
        XCTAssertThrowsError(try logger.append(Data("lost".utf8)))
        try logger.append(Data("recovery".utf8))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "recovery")
        XCTAssertLessThanOrEqual(try FileManager.default.contentsOfDirectory(atPath: dir).count, 2)
    }

    #if os(macOS)
        func testNativeHostProbeNeedsNoHelperProcesses() throws {
            let probe = SystemResourceProbe(
                runner: ToolRunner(environment: ["PATH": "/does-not-exist"]), nativeReadings: true)
            let host = try probe.sample(now: 100)
            XCTAssertEqual(host.sampledAt, 100)
            XCTAssertGreaterThan(host.totalMemoryBytes, 0)
            XCTAssertGreaterThan(host.availableMemoryBytes, 0)
            XCTAssertGreaterThan(host.cpuCount, 0)
        }
    #endif
}
