// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueEngine
import SimQueueHost
import SimQueueSim
import SimQueueStore
import XCTest

/// Deterministic PRNG so a failing soak run can be replayed from its seed.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Simulated-clock soak: random arrivals, a fake executor that creates and releases owned
/// resources, random daemon crashes and stray leaks, with invariants checked every tick.
/// PRs run a short simulation (SIMQ_SOAK_HOURS, default 4 simulated hours, a few seconds of
/// wall time); a longer run is the same test with a bigger number.
final class SoakTests: XCTestCase {
    private struct RunningJob {
        var finishAt: Double
        var resources: [OwnedResource]
    }

    private var simulatedHours: Double {
        ProcessInfo.processInfo.environment["SIMQ_SOAK_HOURS"].flatMap(Double.init) ?? 4
    }

    /// Nightly mode: SIMQ_SOAK_DAYS simulated days, each a busy window
    /// (SIMQ_SOAK_BUSY_MINUTES, default 30) at 5 s ticks and a quiet rest of the day at
    /// 15 min steps with full watchdog passes, stopping early at
    /// SIMQ_SOAK_WALL_SECONDS (default 840) of wall time per mode, or once the soak tests
    /// in this process have used SIMQ_SOAK_TOTAL_WALL_SECONDS (default: no total cap)
    /// between them.
    private var simulatedDays: Int? {
        ProcessInfo.processInfo.environment["SIMQ_SOAK_DAYS"].flatMap(Int.init)
    }

    private var busyMinutes: Double {
        ProcessInfo.processInfo.environment["SIMQ_SOAK_BUSY_MINUTES"].flatMap(Double.init) ?? 30
    }

    /// Per-resource cost bounds for the nightly soak, in microseconds per row.
    private var maxFullMicrosecondsPerRow: Double {
        ProcessInfo.processInfo.environment["SIMQ_SOAK_MAX_FULL_US_PER_ROW"].flatMap(Double.init) ?? 60
    }
    private var maxLightMicrosecondsPerRow: Double {
        ProcessInfo.processInfo.environment["SIMQ_SOAK_MAX_LIGHT_US_PER_ROW"].flatMap(Double.init) ?? 120
    }

    private var wallCapSeconds: Double {
        ProcessInfo.processInfo.environment["SIMQ_SOAK_WALL_SECONDS"].flatMap(Double.init) ?? 840
    }

    private var totalWallCapSeconds: Double? {
        ProcessInfo.processInfo.environment["SIMQ_SOAK_TOTAL_WALL_SECONDS"].flatMap(Double.init)
    }

    /// When the first soak test in this process started (the total cap runs from here).
    nonisolated(unsafe) private static var firstSoakStart: Date?

    private var seed: UInt64 {
        ProcessInfo.processInfo.environment["SIMQ_SOAK_SEED"].flatMap(UInt64.init) ?? 0x51_4D_51
    }

    func testSoakEnforceModeConvergesWithoutViolations() throws {
        try soak(mode: .enforce, seed: seed)
    }

    func testSoakReportOnlyModeNeverDestroysAnything() throws {
        try soak(mode: .reportOnly, seed: seed &+ 1, projectCap: 3)
    }

    // swiftlint:disable:next function_body_length
    private func soak(mode: CleanupMode, seed: UInt64, projectCap: Int? = nil) throws {
        var rng = SplitMix64(state: seed)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("simq-soak-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("state.sqlite").path

        var config = SchedulerConfig()
        if let projectCap { config.maxRunningPerProject = projectCap }
        let harness = Harness(
            path: path, config: config, reliability: ReliabilityConfig(cleanupMode: mode), preserveAdmissionPacing: true
        )
        // Other tools' resources: present the whole time, never touched. One is a lookalike.
        let foreignSims = [
            SimDevice(udid: "FOREIGN-1", name: "Other Tool Sim", isBooted: true),
            SimDevice(udid: "FOREIGN-2", name: "SimQ Pool 9", isBooted: false),
        ]
        let foreignGroup: Int32 = 77
        harness.sims.setDevices(foreignSims)
        harness.processes.spawn(foreignGroup)
        var executorDeletes = 0
        var store = try JobStore(path: path, maxQueuedPerSubmitterPerProject: 3)
        var (engine, _, _) = try harness.start(store: store)
        var running: [String: RunningJob] = [:]
        var nextSim = 0
        var nextPGID: Int32 = 1000
        var lastFence: Int64 = 0
        var lastAuditSeq: Int64 = 0
        var crashes = 0
        var submitted = 0
        let tick = 5.0
        let end = harness.clock.now() + simulatedHours * 3600
        // (exclusive, retryable, needs sims): every flag combination the scheduler must handle.
        let shapes: [(exclusive: Bool, retryable: Bool, sims: Bool)] = [
            (false, true, true), (false, true, true), (true, true, true), (false, false, false), (true, true, false),
            (false, false, true), (false, true, true),
        ]

        // Wall time per watchdog pass kind and per drift report, reset every 30-day line.
        var timing: [String: (count: Int, seconds: Double)] = [:]
        func timed<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
            let start = DispatchTime.now().uptimeNanoseconds
            defer {
                let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
                timing[label, default: (0, 0)].count += 1
                timing[label, default: (0, 0)].seconds += seconds
            }
            return try body()
        }
        func timingSummary(liveRows: Int) -> String {
            ["full", "light", "drift", "busy_window"].map { label in
                let entry = timing[label, default: (0, 0)]
                let average = entry.count == 0 ? 0 : entry.seconds / Double(entry.count)
                return "\(label)_ms=\(String(format: "%.2f", average * 1000))"
            }.joined(separator: " ")
                + " full_us_per_row=" + String(format: "%.1f", fullPassMicroseconds() / Double(max(1, liveRows)))
        }
        func fullPassMicroseconds() -> Double {
            let entry = timing["full", default: (0, 0)]
            return entry.count == 0 ? 0 : entry.seconds / Double(entry.count) * 1e6
        }

        func context() -> String { "seed=\(seed) t=\(harness.clock.now()) mode=\(mode.rawValue)" }

        func syncPoolAndHost() {
            let busy = running.values.reduce(0) { $0 + $1.resources.filter { $0.kind == .sim }.count }
            harness.sims.setPool(PoolSnapshot(busyRunning: busy))
            let used = UInt64(busy) * 4 * gib
            harness.probe.update { host in
                host.availableMemoryBytes = 24 * gib - min(24 * gib, used)
                host.load1 = Double(busy) * 4 + Double.random(in: 0...3, using: &rng)
                host.load5 = Double(busy) * 3 + 1
            }
        }

        func busyTick() throws {
            harness.clock.advance(by: tick)
            let now = harness.clock.now()

            // Arrivals.
            if Double.random(in: 0..<1, using: &rng) < 0.08 {
                let shape = shapes.randomElement(using: &rng)!
                let needsSims = shape.sims
                let minSims = needsSims ? Int.random(in: 1...2, using: &rng) : 0
                let resources = ResourceRequest(
                    minSims: minSims, maxSims: needsSims ? minSims + Int.random(in: 0...1, using: &rng) : 0,
                    memoryBytesPerSim: gib)
                do {
                    _ = try harness.submit(
                        store,
                        exclusive: shape.exclusive,
                        retryable: shape.retryable,
                        priority: Int.random(in: Priority.range, using: &rng),
                        project: ["app", "lib"].randomElement(using: &rng)!,
                        submitter: "s\(Int.random(in: 0..<4, using: &rng))",
                        resources: resources
                    )
                    submitted += 1
                } catch JobStoreError.queueFull {
                    // Backpressure is expected under load.
                }
            }

            // Executor: finish jobs that are due.
            for (id, job) in running where job.finishAt <= now {
                for resource in job.resources {
                    switch resource.kind {
                    case .sim:
                        try harness.sims.deleteDevice(udid: resource.externalID)
                        executorDeletes += 1
                    case .processGroup: harness.processes.exit(Int32(resource.externalID)!)
                    case .runDir, .derivedDataDir:
                        try harness.fileSystem.removeItem(resource.externalID)
                        executorDeletes += 1
                    case .lease, .template: break
                    }
                    try store.releaseResource(id: resource.id, generation: resource.generation, now: now)
                }
                let roll = Double.random(in: 0..<1, using: &rng)
                let result: ResultClass =
                    roll < 0.03 ? .runnerBootstrapFailure : (roll < 0.15 ? .testFailure : .success)
                try store.finish(jobID: id, result: result, now: now)
                running[id] = nil
            }
            syncPoolAndHost()

            // Scheduler pass.
            let result = try engine.tick()
            let charged = result.plan.admissions.reduce(UInt64(0)) { $0 + $1.chargedMemoryBytes }
            if !result.plan.admissions.isEmpty {
                XCTAssertLessThanOrEqual(
                    charged + config.reserveBytes, result.host.availableMemoryBytes, "reserve violated \(context())")
            }

            // Executor: start admitted jobs, creating owned resources first-class.
            for id in result.admitted {
                let job = try XCTUnwrap(try store.job(id: id))
                let token = try XCTUnwrap(job.fenceToken)
                XCTAssertGreaterThan(token, lastFence, "fencing tokens must strictly increase \(context())")
                lastFence = token
                var resources: [OwnedResource] = []
                for _ in 0..<job.grantedSims {
                    nextSim += 1
                    let udid = String(format: "SIM-%06d", nextSim)
                    var devices = try harness.sims.listDevices()
                    devices.append(SimDevice(udid: udid, name: "simq-pool-\(nextSim)", isBooted: true))
                    harness.sims.setDevices(devices)
                    resources.append(
                        try store.acquireResource(
                            kind: .sim, externalID: udid, owner: .job(id), epoch: engine.epoch, now: now))
                }
                nextPGID += 1
                harness.processes.spawn(nextPGID)
                resources.append(
                    try store.acquireResource(
                        kind: .processGroup, externalID: "\(nextPGID)", owner: .job(id), epoch: engine.epoch,
                        identity: try harness.processes.processIdentity(nextPGID), now: now))
                let runDir = harness.layout.runDir(jobID: "\(id)-a\(job.attempt)")
                try harness.fileSystem.createDirectory(runDir)
                resources.append(
                    try store.acquireResource(
                        kind: .runDir, externalID: runDir, owner: .job(id), epoch: engine.epoch, now: now))
                XCTAssertTrue(try store.markRunning(jobID: id, pid: nextPGID, epoch: engine.epoch, now: now))
                running[id] = RunningJob(finishAt: now + Double.random(in: 30...900, using: &rng), resources: resources)
            }
            syncPoolAndHost()

            // Invariants.
            let active = try store.activeJobs()
            XCTAssertLessThanOrEqual(
                active.filter(\.exclusive).count, config.maxConcurrentExclusive, context())
            XCTAssertLessThanOrEqual(
                active.reduce(0) { $0 + $1.grantedSims }, config.maxRunningSims, "sim cap \(context())")
            if config.maxRunningPerProject > 0 {
                for project in Set(active.map(\.project)) {
                    XCTAssertLessThanOrEqual(
                        active.filter { $0.project == project }.count, config.maxRunningPerProject, context())
                }
            }
            XCTAssertLessThanOrEqual(
                result.admitted.count, engine.scheduler.config.maxAdmissionsPerPass,
                "host-wide admission pace \(context())")
            let audit = try store.auditEntries(afterSeq: lastAuditSeq)
            if let last = audit.last {
                XCTAssertGreaterThan(last.seq, lastAuditSeq)
                lastAuditSeq = last.seq
            }

            // Watchdog passes, as the daemon runs them: light every minute, full every 15.
            if Int(now) % 60 == 0 {
                let kind: WatchdogPassKind = Int(now) % 900 == 0 ? .full : .light
                try timed(kind == .full ? "full" : "light") {
                    _ = try engine.watchdogPass(kind, config: WatchdogConfig())
                }
            }

            // Chaos: a stray sim in our namespace, or a daemon crash.
            if Double.random(in: 0..<1, using: &rng) < 0.002 {
                var devices = try harness.sims.listDevices()
                devices.append(SimDevice(udid: "LEAK-\(UUID().uuidString)", name: "simq-leak", isBooted: false))
                harness.sims.setDevices(devices)
            }
            if Double.random(in: 0..<1, using: &rng) < 0.0015 {
                crashes += 1
                running = [:]  // the executor's memory is gone; fakes keep the leftovers
                store = try JobStore(path: path, maxQueuedPerSubmitterPerProject: 3)
                (engine, _, _) = try harness.start(store: store)
            }
        }

        let wallStart = Date()
        if Self.firstSoakStart == nil { Self.firstSoakStart = wallStart }
        var daysDone = 0
        var truncated = false
        if let days = simulatedDays {
            let dayFormat = DateFormatter()
            dayFormat.dateFormat = "yyyy-MM-dd"
            dayFormat.timeZone = TimeZone(identifier: "UTC")
            for _ in 0..<days {
                let overTotal =
                    totalWallCapSeconds.map { cap in
                        Self.firstSoakStart.map { Date().timeIntervalSince($0) > cap } ?? false
                    } ?? false
                if Date().timeIntervalSince(wallStart) > wallCapSeconds || overTotal {
                    truncated = true
                    break
                }
                let dayStart = harness.clock.now()
                try timed("busy_window") {
                    while harness.clock.now() < dayStart + busyMinutes * 60 { try busyTick() }
                }
                // The quiet rest of the day: work finishes, queued work starts, full passes run.
                while harness.clock.now() < dayStart + 86_400 {
                    harness.clock.advance(by: 900)
                    let now = harness.clock.now()
                    for (id, job) in running where job.finishAt <= now {
                        for resource in job.resources {
                            switch resource.kind {
                            case .sim:
                                try harness.sims.deleteDevice(udid: resource.externalID)
                                executorDeletes += 1
                            case .processGroup: harness.processes.exit(Int32(resource.externalID)!)
                            case .runDir, .derivedDataDir:
                                try harness.fileSystem.removeItem(resource.externalID)
                                executorDeletes += 1
                            case .lease, .template: break
                            }
                            try store.releaseResource(id: resource.id, generation: resource.generation, now: now)
                        }
                        try store.finish(jobID: id, result: .success, now: now)
                        running[id] = nil
                    }
                    syncPoolAndHost()
                    for id in try engine.tick().admitted {
                        running[id] = RunningJob(finishAt: now + 600, resources: [])
                        _ = try store.markRunning(jobID: id, pid: nil, epoch: engine.epoch, now: now)
                    }
                    try timed("full") { _ = try engine.watchdogPass(.full, config: WatchdogConfig()) }
                }
                let date = dayFormat.string(from: Date(timeIntervalSince1970: harness.clock.now()))
                daysDone += 1
                if daysDone % 30 == 0 {
                    let liveRows = try store.liveResources().count
                    let lightRows = try store.liveResources(kinds: [.processGroup, .lease]).count
                    // Per-resource cost bound: a full pass probes every live row once and a
                    // light pass every process-group and lease row once, so cost per row must
                    // stay flat however many leftovers pile up. Bounds are ~10x the dev box
                    // (about 5-7 us per row for both) because hosted runners vary.
                    if liveRows >= 100 {
                        XCTAssertLessThanOrEqual(
                            fullPassMicroseconds() / Double(liveRows), maxFullMicrosecondsPerRow,
                            "full pass cost per live row \(context())")
                    }
                    if lightRows >= 50 {
                        let light = timing["light", default: (0, 0)]
                        let lightMicroseconds = light.count == 0 ? 0 : light.seconds / Double(light.count) * 1e6
                        XCTAssertLessThanOrEqual(
                            lightMicroseconds / Double(lightRows), maxLightMicrosecondsPerRow,
                            "light pass cost per covered row \(context())")
                    }
                    print(
                        "soak[\(mode.rawValue)] day \(daysDone) wall=\(Int(Date().timeIntervalSince(wallStart)))s "
                            + "live_rows=\(liveRows) anomalies=\(try store.anomalies().count) "
                            + timingSummary(liveRows: liveRows) + " light_rows=\(lightRows)")
                    timing = [:]
                }
            }
        } else {
            while harness.clock.now() < end { try busyTick() }
        }

        // Drain: no new arrivals; let running work finish and the queue empty.
        var drainSteps = 0
        func workRemains() throws -> Bool { try !running.isEmpty || !store.queuedJobs().isEmpty }
        while try workRemains(), drainSteps < 20_000 {
            drainSteps += 1
            harness.clock.advance(by: tick)
            let now = harness.clock.now()
            for (id, job) in running where job.finishAt <= now {
                for resource in job.resources {
                    switch resource.kind {
                    case .sim:
                        try harness.sims.deleteDevice(udid: resource.externalID)
                        executorDeletes += 1
                    case .processGroup: harness.processes.exit(Int32(resource.externalID)!)
                    case .runDir, .derivedDataDir:
                        try harness.fileSystem.removeItem(resource.externalID)
                        executorDeletes += 1
                    case .lease, .template: break
                    }
                    try store.releaseResource(id: resource.id, generation: resource.generation, now: now)
                }
                try store.finish(jobID: id, result: .success, now: now)
                running[id] = nil
            }
            syncPoolAndHost()
            for id in try engine.tick().admitted {
                // Short, resource-free completion during the drain.
                running[id] = RunningJob(finishAt: now + 10, resources: [])
                _ = try store.markRunning(jobID: id, pid: nil, epoch: engine.epoch, now: now)
            }
        }
        for job in try store.queuedJobs() {
            print(
                "stuck \(job.id) \(job.kind) sims=\(job.resources.minSims)...\(job.resources.maxSims) why=\(try store.explanation(jobID: job.id)?.reasons.map(\.summary) ?? [])"
            )
        }
        XCTAssertTrue(try store.queuedJobs().isEmpty, "queue drained \(context())")
        XCTAssertTrue(try store.activeJobs().isEmpty, "no job stuck active \(context())")

        // Converge cleanup: advance past grace, rate limits and breaker cool-downs.
        for _ in 0..<400 {
            harness.clock.advance(by: 3600 / 10)
            try engine.watchdogPass(.full, config: WatchdogConfig())
        }

        let destroyedTimes = try allAuditEntries(store).filter { $0.type == Engine.destructiveAuditType }.map(\.at)
        for time in destroyedTimes {
            let inHour = destroyedTimes.filter { $0 >= time && $0 < time + 3600 }.count
            XCTAssertLessThanOrEqual(
                inHour, harness.reliability.maxDestructiveActionsPerHour, "hourly destructive limit \(context())")
        }

        let liveSims = try harness.sims.listDevices()
        let liveGroups = try harness.processes.liveProcessGroups()
        let liveDirs = try harness.fileSystem.children(of: harness.layout.runsRoot)

        // Foreign resources: never touched, and the lookalike alerted exactly once.
        for sim in foreignSims {
            XCTAssertTrue(liveSims.contains(sim), "foreign sim \(sim.udid) gone \(context())")
            XCTAssertFalse(harness.sims.deletedUDIDs.contains(sim.udid), context())
        }
        XCTAssertTrue(liveGroups.contains(foreignGroup), context())
        XCTAssertFalse(harness.processes.terminated.contains(foreignGroup), context())
        XCTAssertFalse(harness.processes.signals.contains { $0.pgid == foreignGroup }, context())
        XCTAssertEqual(try store.alert(key: "lookalike_sim:FOREIGN-2")?.count, 1, context())
        XCTAssertNil(try store.alert(key: "lookalike_sim:FOREIGN-1"), context())

        // One audit entry for every action SimQueue took on the host.
        let engineActions =
            harness.sims.deletedUDIDs.count + harness.fileSystem.removed.count - executorDeletes
            + harness.processes.terminated.count
        let allAudit = try allAuditEntries(store)
        let audited = allAudit.filter {
            [Engine.destructiveAuditType, Engine.restartKillAuditType].contains($0.type)
        }.count
        XCTAssertEqual(engineActions, audited, "every host action is audited once \(context())")
        switch mode {
        case .enforce:
            XCTAssertEqual(
                try allAuditEntries(store).filter { $0.type == "breaker_opened" }.count, 0,
                "a backlog at the limits never trips the breaker \(context())")
            XCTAssertTrue(try store.liveResources().isEmpty, "no live ownership rows left \(context())")
            XCTAssertEqual(liveSims, foreignSims, "no sims of ours left \(context()): \(liveSims.count)")
            XCTAssertEqual(liveGroups, [foreignGroup], "no process groups of ours left \(context())")
            XCTAssertTrue(liveDirs.isEmpty, "no run dirs left \(context())")

            // Thrash: the same leak cleaned twice within the hour opens the breaker.
            let thrash = SimDevice(udid: "THRASH-1", name: "simq-thrash", isBooted: false)
            for _ in 0..<2 {
                harness.sims.setDevices(try harness.sims.listDevices() + [thrash])
                try engine.watchdogPass(.full, config: WatchdogConfig())
                harness.clock.advance(by: 601)
                try engine.watchdogPass(.full, config: WatchdogConfig())
            }
            XCTAssertEqual(
                try allAuditEntries(store).filter { $0.type == "breaker_opened" }.count, 1,
                "the breaker opens under thrash \(context())")
        case .reportOnly:
            XCTAssertTrue(destroyedTimes.isEmpty, "report-only mode destroyed something \(context())")
            XCTAssertEqual(
                try allAuditEntries(store).filter { $0.type == "breaker_opened" }.count, 0,
                "nothing acts in report-only mode, so the breaker never trips \(context())")
            // The only signals are restart recovery stopping SimQueue's own verified job
            // groups, which happens in every cleanup mode (each one audited `restart_kill`).
            XCTAssertEqual(
                harness.processes.terminated.count,
                allAudit.filter { $0.type == Engine.restartKillAuditType }.count, context())
            // Everything left behind is still accounted for: either a live row or a reported candidate.
            let owned = Set(try store.ownedSimUDIDs())
            for sim in liveSims where !owned.contains(sim.udid) {
                XCTAssertTrue(
                    sim.name == "simq-leak" || foreignSims.contains(sim), "unaccounted sim \(sim.udid) \(context())")
            }
        }
        XCTAssertGreaterThan(submitted, 0)
        print(
            "soak[\(mode.rawValue)] seed=\(seed) days=\(simulatedDays.map { "\(daysDone)/\($0)\(truncated ? " (wall cap)" : "")" } ?? "-") hours=\(simulatedHours) wall=\(Int(Date().timeIntervalSince(wallStart)))s submitted=\(submitted) crashes=\(crashes) destroyed=\(destroyedTimes.count) breaker_opened=\(try allAuditEntries(store).filter { $0.type == "breaker_opened" }.count)"
        )
    }

    /// The whole audit log; `auditEntries` pages at 10,000 rows and long soaks write more.
    private func allAuditEntries(_ store: JobStore) throws -> [AuditEntry] {
        var all: [AuditEntry] = []
        while true {
            let page = try store.auditEntries(afterSeq: all.last?.seq ?? 0, limit: 10_000)
            all += page
            if page.count < 10_000 { return all }
        }
    }
}
