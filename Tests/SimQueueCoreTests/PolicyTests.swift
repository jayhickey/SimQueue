// SPDX-License-Identifier: MIT

import Foundation
import XCTest

@testable import SimQueueCore

final class PolicyTests: XCTestCase {
    // MARK: - Host

    func testKernelPressureLevelMapping() {
        XCTAssertEqual(MemoryPressure(kernelLevel: 1), .normal)
        XCTAssertEqual(MemoryPressure(kernelLevel: 2), .warn)
        XCTAssertEqual(MemoryPressure(kernelLevel: 4), .critical)
        XCTAssertEqual(MemoryPressure(kernelLevel: 3), .critical, "unknown levels round toward caution")
        XCTAssertTrue(
            MemoryPressure(kernelLevel: 2) >= SchedulerConfig().pressureStop,
            "admission stops at kernel pressure level 2")
    }

    func testSwapGrowthTrackerScalesToPerMinute() {
        var tracker = SwapGrowthTracker()
        tracker.add(at: 0, swapUsedBytes: 0)
        XCTAssertEqual(tracker.growthBytesPerMinute, 0)
        tracker.add(at: 30, swapUsedBytes: 30 * mib)
        XCTAssertEqual(tracker.growthBytesPerMinute, Double(60 * mib), accuracy: 1)
    }

    func testSwapGrowthTrackerDropsOldSamplesAndIgnoresShrink() {
        var tracker = SwapGrowthTracker()
        tracker.add(at: 0, swapUsedBytes: 0)
        tracker.add(at: 100, swapUsedBytes: 500 * mib)
        XCTAssertEqual(tracker.samples.count, 1, "the sample at t=0 is outside the 60 s window")
        tracker.add(at: 130, swapUsedBytes: 400 * mib)
        XCTAssertEqual(tracker.growthBytesPerMinute, 0)
    }

    // MARK: - Drain

    func testDrainTripsAtLimitInsideWindow() {
        let policy = InfraDrainPolicy(limit: 3, windowSeconds: 900)
        XCTAssertEqual(policy.status(failureTimes: [100, 200], clearedAt: nil, now: 300), .normal)
        XCTAssertEqual(
            policy.status(failureTimes: [100, 200, 300], clearedAt: nil, now: 300), .draining(recentInfraFailures: 3))
        XCTAssertEqual(
            policy.status(failureTimes: [100, 200, 300], clearedAt: nil, now: 1001), .normal, "oldest aged out")
    }

    func testResumeClearsDrainAndZeroLimitDisables() {
        let policy = InfraDrainPolicy(limit: 3, windowSeconds: 900)
        XCTAssertEqual(policy.status(failureTimes: [100, 200, 300], clearedAt: 250, now: 400), .normal)
        XCTAssertEqual(InfraDrainPolicy(limit: 0).status(failureTimes: [1, 2, 3, 4], clearedAt: nil, now: 5), .normal)
    }

    func testOnlyInfraResultClassesCountTowardDrain() {
        XCTAssertEqual(
            ResultClass.allCases.filter(\.isInfraFailure), [.runnerBootstrapFailure, .artifactFailure, .internalError])
        XCTAssertFalse(ResultClass.queueTimeout.isInfraFailure, "a busy host is not a broken host")
        XCTAssertEqual(ResultClass.queueTimeout.terminalState, .expired)
        XCTAssertEqual(ResultClass.runTimeout.terminalState, .timedOut)
        XCTAssertFalse(ResultClass.runTimeout.isInfraFailure)
    }

    // MARK: - Wait reasons

    func testWaitReasonCodesAreUniqueAndStable() {
        let all: [WaitReason] = [
            .paused, .draining(recentInfraFailures: 3), .memoryPressure(level: .warn, stopAt: .warn),
            .swapGrowing(bytesPerMinute: 1, limitBytesPerMinute: 0), .swapHigh(usedBytes: 4 * gib, maxBytes: 3 * gib),
            .loadThrottle(load1: 31, load5: 16, clearing: false), .thermal(state: .serious, stopAt: .serious),
            .diskLow(freeBytes: gib, minBytes: 40 * gib), .projectCap(project: "app", running: 3, max: 3),
            .exclusiveSlot(running: 1, max: 1), .simCapacity(needed: 1, runningAfter: 5, maxRunning: 4),
            .bootCapacity(bootsNeeded: 1, inProgress: 1, max: 1), .loadTooHighForBoot(load1: 25, limit: 20),
            .insufficientMemory(availableBytes: gib, neededBytes: gib, reserveBytes: 3 * gib),
            .reservedForHigherPriority(jobID: "J-1"), .neverFits(detail: "x"),
        ]
        XCTAssertEqual(Set(all.map(\.code)).count, all.count)
        for reason in all {
            XCTAssertFalse(reason.summary.isEmpty)
            let data = try? JSONEncoder().encode(reason)
            XCTAssertEqual(data.flatMap { try? JSONDecoder().decode(WaitReason.self, from: $0) }, reason)
        }
        XCTAssertEqual(all.filter(\.isSelfLimited).map(\.code), ["project_cap", "exclusive_slot", "never_fits"])
    }

    // MARK: - Timeouts

    func testRunTimeoutIsMeasuredFromJobStart() {
        var job = makeJob("J-1", seq: 1, queueTime: 0)
        job.runTimeoutSeconds = 100
        XCTAssertNil(job.runDeadline)
        XCTAssertFalse(job.isRunTimedOut(now: 10_000), "queue wait never counts toward the run timeout")
        job.state = .admitted
        job.admittedAt = 5_000
        XCTAssertNil(job.runDeadline, "time admitted (sim boot) doesn't count")
        XCTAssertFalse(job.isRunTimedOut(now: 1e9))
        job.state = .running
        job.startedAt = 5_030
        XCTAssertEqual(job.runDeadline, 5_130)
        XCTAssertFalse(job.isRunTimedOut(now: 5_129))
        XCTAssertTrue(job.isRunTimedOut(now: 5_130))
        job.runTimeoutSeconds = nil
        XCTAssertFalse(job.isRunTimedOut(now: 1e12), "no timeout means no limit")
    }

    func testQueueTimeoutAppliesToUnstartedFirstAttempts() {
        var job = makeJob("J-1", seq: 1, queueTime: 0)
        job.createdAt = 100
        XCTAssertFalse(job.isQueueExpired(now: 1e12), "no queue timeout means no limit")
        job.queueTimeoutSeconds = 60
        XCTAssertEqual(job.queueDeadline, 160, "measured from created_at, not the inherited queue time")
        XCTAssertFalse(job.isQueueExpired(now: 159))
        XCTAssertTrue(job.isQueueExpired(now: 160))
        job.attempt = 1
        XCTAssertFalse(job.isQueueExpired(now: 1e6), "a retry already started once")
        job.attempt = 0
        job.state = .running
        XCTAssertFalse(job.isQueueExpired(now: 1e6))
    }

    func testTimeoutDefaults() {
        let config = TimeoutConfig()
        XCTAssertEqual(config.killGraceSeconds, 10)
        XCTAssertNil(config.defaultRunTimeoutSeconds, "run timeout has no default limit")
        XCTAssertEqual(config.defaultQueueTimeoutSeconds, 86_400, "queue timeout defaults to 24 h")
        let plain = config.apply(to: JobSubmission(project: "p", submitter: "s"))
        XCTAssertNil(plain.runTimeoutSeconds)
        XCTAssertEqual(plain.queueTimeoutSeconds, 86_400)
    }

    func testPerJobTimeoutsOverrideDefaultsAndZeroMeansNoLimit() {
        let config = TimeoutConfig(defaultRunTimeoutSeconds: 1_800)
        let explicit = config.apply(
            to: JobSubmission(
                project: "p", submitter: "s", runTimeoutSeconds: 5, queueTimeoutSeconds: 60))
        XCTAssertEqual(explicit.runTimeoutSeconds, 5)
        XCTAssertEqual(explicit.queueTimeoutSeconds, 60)
        let unlimited = config.apply(
            to: JobSubmission(project: "p", submitter: "s", runTimeoutSeconds: 0, queueTimeoutSeconds: 0)
        )
        XCTAssertNil(unlimited.runTimeoutSeconds, "per-job 0 overrides a configured default")
        XCTAssertNil(unlimited.queueTimeoutSeconds, "per-job 0 overrides the 24 h default")
        let noDefault = TimeoutConfig(defaultQueueTimeoutSeconds: 0)
        XCTAssertNil(
            noDefault.apply(to: JobSubmission(project: "p", submitter: "s")).queueTimeoutSeconds)
    }

    func testClientWaitTimeoutIsSeparateFromRunTimeout() {
        var job = makeJob("J-1", seq: 1)
        job.runTimeoutSeconds = 30
        let wait = ClientWait(timeoutSeconds: 600, startedAt: 0)
        XCTAssertEqual(wait.outcome(for: job, now: 599), .keepWaiting)
        XCTAssertEqual(wait.outcome(for: job, now: 600), .stoppedWaiting)
        job.state = .admitted
        XCTAssertEqual(wait.outcome(for: job, now: 10_000), .admitted)
        job.state = .succeeded
        XCTAssertEqual(wait.outcome(for: job, now: 10_000), .finished(.succeeded))
        XCTAssertEqual(
            ClientWait(timeoutSeconds: nil, startedAt: 0).outcome(for: makeJob("J-2", seq: 2), now: 1e9), .keepWaiting)
    }

    // MARK: - Shards

    // MARK: - Clock

    func testManualClockAdvances() {
        let clock = ManualClock(start: 100)
        clock.advance(by: 5)
        XCTAssertEqual(clock.now(), 105)
        clock.set(1)
        XCTAssertEqual(clock.now(), 1)
        XCTAssertGreaterThan(SystemClock().now(), 1_700_000_000)
    }
}
