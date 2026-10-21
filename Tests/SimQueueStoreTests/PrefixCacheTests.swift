// SPDX-License-Identifier: MIT

import SimQueueCore
import SimQueueStore
import XCTest

final class PrefixCacheTests: XCTestCase {
    func testPrefixBuckets() {
        var book = PrefixBuckets<Int>()
        book["process_group:1"] = 1
        book["process_group:2"] = 2
        book["sim:A"] = 3
        book["breaker"] = 4
        XCTAssertEqual(book.bucket("process_group:"), ["process_group:1": 1, "process_group:2": 2])
        XCTAssertEqual(book.count, 4)
        book["process_group:1"] = nil
        book.setBucket("process_group:", [:])
        XCTAssertEqual(book.all, ["sim:A": 3, "breaker": 4])
    }

    func testLiveResourcesByKindTrackWrites() throws {
        let store = try JobStore(path: ":memory:")
        let epoch = try store.acquireDaemonLease(ownerID: "test", pid: 1, now: 0)
        let sim = try store.acquireResource(kind: .sim, externalID: "S1", owner: .pool, epoch: epoch, now: 1)
        let group = try store.acquireResource(
            kind: .processGroup, externalID: "100", owner: .pool, epoch: epoch, now: 1)
        XCTAssertEqual(try store.liveResources(kinds: [.processGroup]).map(\.id), [group.id])
        XCTAssertEqual(try store.liveResources(kinds: [.processGroup, .sim]).map(\.id), [sim.id, group.id])
        try store.releaseResource(id: group.id, generation: group.generation, now: 2)
        XCTAssertTrue(try store.liveResources(kinds: [.processGroup]).isEmpty)
        XCTAssertEqual(try store.liveResources(kinds: [.sim]).map(\.id), [sim.id])
    }

    func testScopedSightingSyncLeavesOtherBucketsAlone() throws {
        let store = try JobStore(path: ":memory:")
        _ = try store.syncSightings(["sim:A", "process_group:1"], now: 1)
        let light = try store.syncSightings(
            ["process_group:2"], scopePrefix: "process_group:", inScope: { $0.hasPrefix("process_group:") }, now: 2)
        XCTAssertEqual(Set(light.keys), ["process_group:2"])
        XCTAssertEqual(Set(try store.sightings().keys), ["sim:A", "process_group:2"])
        XCTAssertEqual(try store.sightings()["sim:A"]?.firstSeenAt, 1)
    }
}
