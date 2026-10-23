import SimQueueCore
import SimQueueHost
import SimQueueProtocol
// SPDX-License-Identifier: MIT
import XCTest

@testable import SimQueueDaemon
@testable import SimQueueEngine

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

    func testProtectionIncludesDerivedDataAndResultsAndSubtractsEligibleSubtrees() {
        let fs = FakeFileSystem()
        fs.sizes = ["/runs/active": 100, "/runs/pinned": 200, "/runs/retained": 300, "/runs/retained/DerivedData": 100]
        let entries = [
            Engine.StorageEntry(path: "/runs/active", category: "Active / cleanup pending", hasDerivedData: true),
            Engine.StorageEntry(path: "/runs/pinned", category: "Pinned", hasDerivedData: true),
            Engine.StorageEntry(path: "/runs/retained", category: "Successful runs", hasDerivedData: true),
            Engine.StorageEntry(path: "/runs/unknown", category: "Pinned", hasDerivedData: false),
        ]
        let result = StorageAccounting.protection(
            entries, candidates: [.init(path: "/runs/retained/DerivedData", reason: "age", bytes: 100)], fileSystem: fs)
        XCTAssertEqual(result.first { $0.name == "Active / cleanup pending" }?.bytes, 100)
        XCTAssertEqual(result.first { $0.name == "Pinned" }?.bytes, 200)
        XCTAssertEqual(result.first { $0.name == "Pinned" }?.unknownSizes, 1)
        XCTAssertEqual(result.first { $0.name == "Within retention / not eligible" }?.bytes, 200)
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
    func testInventoryDiscoversOnlyTopLevelBundlesDuringExplicitAccounting() throws {
        let path = "/jobs/2026-10-01/J-1"
        let fs = FakeFileSystem(directories: [
            "/jobs/2026-10-01", path, path + "/Result.xcresult", path + "/nested", path + "/nested/Other.xcresult",
        ])
        XCTAssertEqual(try Engine.gcInventory(roots: ["/jobs"], fileSystem: fs).directories.first?.resultBundles, [])
        XCTAssertEqual(
            try Engine.gcInventory(roots: ["/jobs"], fileSystem: fs, includeStorageDetails: true).directories.first?
                .resultBundles, [path + "/Result.xcresult"])
    }

    func testResultBundlesAreSeparatedAndUnknownSubtreesDoNotDoubleCount() {
        let fs = FakeFileSystem()
        fs.sizes = ["/runs/a": 100, "/runs/a/DerivedData": 60, "/runs/a/Result.xcresult": 30]
        let entry = Engine.StorageEntry(
            path: "/runs/a", category: "Successful runs", hasDerivedData: true,
            resultBundles: ["/runs/a/Result.xcresult"])
        var result = StorageAccounting.categories([entry], fileSystem: fs)
        XCTAssertEqual(result.reduce(0) { $0 + $1.bytes }, 100)
        XCTAssertEqual(result.first { $0.name == "Result bundles" }?.bytes, 30)
        XCTAssertEqual(result.first { $0.name == "Successful runs" }?.bytes, 10)
        fs.sizes.removeValue(forKey: "/runs/a/Result.xcresult")
        result = StorageAccounting.categories([entry], fileSystem: fs)
        XCTAssertEqual(result.first { $0.name == "Successful runs" }?.unknownSizes, 1)
        XCTAssertEqual(result.first { $0.name == "Result bundles" }?.unknownSizes, 1)
    }

    func testSimulatorAccountingRequiresLedgerOwnershipAndDeduplicates() {
        let a = "00000000-0000-0000-0000-000000000001"
        let b = "00000000-0000-0000-0000-000000000002"
        func owned(_ id: String, _ kind: OwnedResourceKind, _ state: OwnedResourceState = .active) -> OwnedResource {
            .init(id: 1, kind: kind, externalID: id, owner: .pool, epoch: 1, generation: 1, state: state, acquiredAt: 0)
        }
        let resources = [owned(a, .sim), owned(a, .template), owned(b, .sim), owned("invalid", .sim)]
        let devices = [
            SimDevice(
                udid: a, name: "arbitrary", isBooted: false, state: "Shutdown", runtime: "runtime", dataSizeBytes: 100)
        ]
        let result = StorageAccounting.simulators(resources: resources, devices: devices)
        XCTAssertEqual(result.first { $0.name == "Managed template data" }?.bytes, 100)
        XCTAssertEqual(result.first { $0.name == "Managed simulator data" }?.unknownSizes, 1)
        XCTAssertEqual(result.reduce(0) { $0 + $1.count }, 2)
        XCTAssertTrue(StorageAccounting.simulators(resources: [owned(a, .sim, .released)], devices: devices).isEmpty)
        XCTAssertTrue(StorageAccounting.simulators(resources: [], devices: devices).isEmpty)
    }

}
