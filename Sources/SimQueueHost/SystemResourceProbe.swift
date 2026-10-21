// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// The real host probe (spec §5c): load (getloadavg), memory (`vm_stat`, physical
/// memory), memory pressure (`sysctl kern.memorystatus_vm_pressure_level`), swap
/// (`sysctl vm.swapusage`), free disk on `diskPath`, and thermal state. Every tool call
/// has a timeout; a reading that fails throws, so admission holds rather than guessing.
/// Parsers are pure and tested against recorded macOS output.
public struct SystemResourceProbe: ResourceProbe {
    public var runner: ToolRunner
    public var diskPath: String
    #if canImport(Darwin)
        private static let hostPort = mach_host_self()
    #endif
    public var nativeReadings: Bool
    public var timeoutSeconds: Double

    public init(
        runner: ToolRunner = ToolRunner(), diskPath: String = "/", timeoutSeconds: Double = 5,
        nativeReadings: Bool = false
    ) {
        self.nativeReadings = nativeReadings
        self.runner = runner
        self.diskPath = diskPath
        self.timeoutSeconds = timeoutSeconds
    }

    public func sample(now: Double) throws -> HostSnapshot {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { throw ProbeError.reading("getloadavg") }
        let available: UInt64
        let swapUsed: UInt64
        let pressure: MemoryPressure
        #if canImport(Darwin)
            if nativeReadings {
                var stats = vm_statistics64_data_t()
                var count = mach_msg_type_number_t(
                    MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
                let result = withUnsafeMutablePointer(to: &stats) { pointer in
                    pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                        host_statistics64(Self.hostPort, HOST_VM_INFO64, $0, &count)
                    }
                }
                guard result == KERN_SUCCESS else { throw ProbeError.reading("host_statistics64") }
                var pageSize: vm_size_t = 0
                guard host_page_size(Self.hostPort, &pageSize) == KERN_SUCCESS else {
                    throw ProbeError.reading("host_page_size")
                }
                // speculative_count is included in free_count (vm_statistics.h).
                // Keep reclaimable estimates conservative rather than double count
                // overlapping purgeable/speculative categories.
                available = (UInt64(stats.free_count) + UInt64(stats.inactive_count)) * UInt64(pageSize)
                var swap = xsw_usage(); var swapSize = MemoryLayout<xsw_usage>.size
                guard sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 else {
                    throw ProbeError.reading("vm.swapusage")
                }
                swapUsed = swap.xsu_used
                var level: Int32 = 0; var levelSize = MemoryLayout<Int32>.size
                guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0,
                    let current = Self.pressure(String(level))
                else { throw ProbeError.reading("memorystatus_vm_pressure_level") }
                pressure = current
            } else {
                let readings = try toolReadings()
                available = readings.available; swapUsed = readings.swap; pressure = readings.pressure
            }
        #else
            let readings = try toolReadings()
            available = readings.available; swapUsed = readings.swap; pressure = readings.pressure
        #endif
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: diskPath)
        let freeDisk = (attributes[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
        return HostSnapshot(
            sampledAt: now, totalMemoryBytes: ProcessInfo.processInfo.physicalMemory, availableMemoryBytes: available,
            swapUsedBytes: swapUsed, memoryPressure: pressure, load1: loads[0], load5: loads[1],
            cpuCount: ProcessInfo.processInfo.activeProcessorCount, freeDiskBytes: freeDisk,
            thermalState: Self.currentThermal())
    }

    private func toolReadings() throws -> (available: UInt64, swap: UInt64, pressure: MemoryPressure) {
        let pageStats = try runner.check("vm_stat", [], timeoutSeconds: timeoutSeconds)
        guard let available = Self.availableBytes(vmStat: pageStats) else { throw ProbeError.reading("vm_stat") }
        let swap = try runner.check("sysctl", ["-n", "vm.swapusage"], timeoutSeconds: timeoutSeconds)
        guard let swapUsed = Self.swapUsedBytes(swap) else { throw ProbeError.reading("vm.swapusage") }
        let level = try runner.check(
            "sysctl", ["-n", "kern.memorystatus_vm_pressure_level"], timeoutSeconds: timeoutSeconds)
        guard let pressure = Self.pressure(level) else { throw ProbeError.reading("memorystatus_vm_pressure_level") }
        return (available, swapUsed, pressure)
    }

    /// Free + inactive + purgeable + speculative pages from `vm_stat` output.
    public static func availableBytes(vmStat: String) -> UInt64? {
        var pageSize: UInt64?
        var pages: [String: UInt64] = [:]
        for line in vmStat.split(separator: "\n") {
            if line.contains("page size of") {
                pageSize = line.split(separator: " ").compactMap { UInt64($0) }.first
                continue
            }
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " ."))
            if let count = UInt64(value) { pages[parts[0].trimmingCharacters(in: .whitespaces)] = count }
        }
        guard let pageSize, let free = pages["Pages free"] else { return nil }
        let keys = ["Pages inactive", "Pages purgeable", "Pages speculative"]
        return (free + keys.reduce(0) { $0 + (pages[$1] ?? 0) }) * pageSize
    }

    /// `used = 1024.50M` from `vm.swapusage` (`total = ... used = ... free = ...`).
    public static func swapUsedBytes(_ text: String) -> UInt64? {
        let tokens = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        guard let index = tokens.firstIndex(of: "used"), index + 2 < tokens.count, tokens[index + 1] == "=" else {
            return nil
        }
        var value = tokens[index + 2]
        let unit = value.last.map(String.init) ?? ""
        let multipliers: [String: Double] = ["K": 1024, "M": 1024 * 1024, "G": 1024 * 1024 * 1024]
        let multiplier = multipliers[unit] ?? 1
        if multipliers[unit] != nil { value.removeLast() }
        guard let number = Double(value) else { return nil }
        return UInt64(number * multiplier)
    }

    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warn, 4 critical.
    public static func pressure(_ text: String) -> MemoryPressure? {
        switch Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
        case 1: return .normal
        case 2: return .warn
        case 4: return .critical
        default: return nil
        }
    }

    static func currentThermal() -> ThermalState {
        #if canImport(Darwin)
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: return .nominal
            case .fair: return .fair
            case .serious: return .serious
            case .critical: return .critical
            @unknown default: return .critical
            }
        #else
            return .nominal  // no thermal API off Darwin
        #endif
    }
}

public enum ProbeError: Error, Equatable, CustomStringConvertible {
    case reading(String)
    public var description: String {
        switch self {
        case .reading(let what): "couldn't read \(what)"
        }
    }
}

/// Process scan (`ps`) for simulator users: which processes reference an owned sim's
/// UDID (unleased users when no live lease covers them), and how busy a sim's own
/// process tree is (the cheap sim-quiet settle signal).
public struct SimProcessProbe: Sendable {
    public var runner: ToolRunner
    public var timeoutSeconds: Double

    public init(runner: ToolRunner = ToolRunner(), timeoutSeconds: Double = 5) {
        self.runner = runner
        self.timeoutSeconds = timeoutSeconds
    }

    public struct ProcessLine: Sendable, Equatable {
        public var pid: Int32
        public var cpuPercent: Double
        public var command: String
    }

    public func processes() throws -> [ProcessLine] {
        Self.parsePS(try runner.check("ps", ["-axo", "pid=,%cpu=,command="], timeoutSeconds: timeoutSeconds))
    }

    public static func parsePS(_ text: String) -> [ProcessLine] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]), let cpu = Double(fields[1]) else { return nil }
            return ProcessLine(pid: pid, cpuPercent: cpu, command: String(fields[2]))
        }
    }

    /// Pids per UDID of processes outside the sim itself that reference it (for example
    /// `xcodebuild -destination id=<UDID>` or `simctl ... <UDID>`), excluding `exceptPIDs`.
    public static func users(of udids: Set<String>, in lines: [ProcessLine], exceptPIDs: Set<Int32> = [])
        -> [String: [Int32]]
    {
        var result: [String: [Int32]] = [:]
        for line in lines where !exceptPIDs.contains(line.pid) {
            for udid in udids where line.command.contains(udid) && !line.command.contains("/Devices/\(udid)/") {
                result[udid, default: []].append(line.pid)
            }
        }
        return result
    }

    /// Total %CPU of the sim's own processes (their command runs under `/Devices/<UDID>/`).
    public static func simCPUPercent(_ udid: String, in lines: [ProcessLine]) -> Double {
        lines.filter { $0.command.contains("/Devices/\(udid)/") }.reduce(0) { $0 + $1.cpuPercent }
    }
}
