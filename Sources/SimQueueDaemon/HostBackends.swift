// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueHost
import SimQueueSim

/// Which host probe the daemon samples.
public enum ProbeKind: String, Sendable, CaseIterable {
    /// A fixed, healthy fake host.
    case fake
    /// `SystemResourceProbe`: real load, memory, pressure, swap, disk, thermal (read-only).
    case system
}

/// The sim backend and host probe `simqd` runs with. The real sim backend is the default
/// on macOS (`BackendGate`); `simctl.template` optionally overrides the template it clones.
/// The probe defaults to the backend's (fake with fake sims, system with real ones).
/// With `dryRun`, host actions are wrapped so they are logged and never run.
public struct HostBackends {
    public var backend: BackendKind
    public var probeKind: ProbeKind
    public var sims: any SimBackend
    public var probe: any ResourceProbe

    public static func make(
        backend requested: BackendKind, probe: ProbeKind?, config: DaemonConfig, environment: [String: String],
        fakeHost: HostSnapshot, diskPath: String = "/", simctlAvailable: Bool = BackendKind.simctlAvailable,
        naming: SimNamingScheme = SimNamingScheme()
    ) throws -> HostBackends {
        let backend = try BackendGate.resolve(requested: requested, simctlAvailable: simctlAvailable)
        let runner = ToolRunner(environment: environment)
        let sims: any SimBackend
        switch backend {
        case .fake:
            sims = FakeSimBackend(pool: PoolSnapshot(idleRunning: 4))
        case .simctl:
            sims = try SimctlBackend(template: config.simctl?.template, runner: runner, naming: naming)
        }
        let probeKind = probe ?? (backend == .fake ? .fake : .system)
        let resourceProbe: any ResourceProbe =
            probeKind == .fake
            ? FakeResourceProbe(fixed: fakeHost)
            : SystemResourceProbe(
                runner: runner, diskPath: diskPath,
                nativeReadings: ProcessSpawner.resolveExecutable("sysctl", path: environment["PATH"], cwd: nil)
                    == "/usr/sbin/sysctl")
        return HostBackends(backend: backend, probeKind: probeKind, sims: sims, probe: resourceProbe)
    }
}
