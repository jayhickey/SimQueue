import SimQueueEngine
import SimQueueHost
import SimQueueProtocol
// SPDX-License-Identifier: MIT
import XCTest

@testable import SimQueueDaemon

final class StorageAccountingTests: XCTestCase {
    func testReclaimableEstimateDoesNotDoubleCountNestedCandidates() {
        let result = StorageAccounting.reclaimable([
            GCEntry(path: "/runs/a", reason: "budget", bytes: 100),
            GCEntry(path: "/runs/a/DerivedData", reason: "age", bytes: 60),
            GCEntry(path: "/runs/b", reason: "age", bytes: nil),
        ])
        XCTAssertEqual(result.bytes, 100)
        XCTAssertEqual(result.unknown, 1)
    }

    func testDerivedDataIsNotCountedTwiceAndUnknownSizesStayUnknown() {
        let fs = FakeFileSystem()
        fs.sizes = ["/runs/a": 100, "/runs/a/DerivedData": 60, "/runs/b": 50]
        let entries = [
            Engine.StorageEntry(path: "/runs/a", category: "Successful runs", hasDerivedData: true),
            Engine.StorageEntry(path: "/runs/b", category: "Active / cleanup pending", hasDerivedData: false),
            Engine.StorageEntry(path: "/runs/c", category: "Pinned", hasDerivedData: false),
        ]
        let result = StorageAccounting.categories(entries, fileSystem: SizingFileSystem(fs))
        XCTAssertEqual(result.first { $0.name == "DerivedData" }?.bytes, 60)
        XCTAssertEqual(result.first { $0.name == "Successful runs" }?.bytes, 40)
        XCTAssertEqual(result.first { $0.name == "Active / cleanup pending" }?.bytes, 50)
        XCTAssertEqual(result.first { $0.name == "Pinned" }?.unknownSizes, 1)
    }
    func testAdditionalAccountingIsCappedWithoutClaimingMissingDirectoriesAreEmpty() {
        let fs = FakeFileSystem()
        let entries = (0..<201).map {
            Engine.StorageEntry(path: "/runs/\($0)", category: "Successful runs", hasDerivedData: false)
        }
        for entry in entries { fs.sizes[entry.path] = 1 }
        let result = StorageAccounting.categories(entries, fileSystem: fs)
        XCTAssertEqual(result.first?.bytes, 200)
        XCTAssertEqual(result.first?.count, 201)
        XCTAssertEqual(result.first?.unknownSizes, 1)
    }
}
