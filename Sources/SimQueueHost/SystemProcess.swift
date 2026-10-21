// SPDX-License-Identifier: MIT

import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

public enum ProcessControlError: Error, Equatable, CustomStringConvertible {
    case refused(String)
    case system(call: String, errno: Int32)

    public var description: String {
        switch self {
        case .refused(let reason): return "refused: \(reason)"
        case .system(let call, let code): return "\(call) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// The host's real process groups. Only ever signals a group it is told to (never a pid,
/// never group 0 or 1, never its own group), and treats zombies as gone: a group whose
/// members have all exited but not yet been reaped is not "live".
public final class SystemProcessTable: ProcessTable, @unchecked Sendable {
    /// How often `terminateGroup` checks whether the group is gone.
    public var pollInterval: Double = 0.02

    public init() {}

    public func liveProcessGroups() throws -> Set<Int32> {
        #if os(Linux)
            return try Self.linuxLiveGroups()
        #elseif canImport(Darwin)
            return try Self.darwinLiveGroups()
        #else
            return []
        #endif
    }

    public func residentBytes(ofGroups groups: Set<Int32>) throws -> [Int32: UInt64] {
        guard !groups.isEmpty else { return [:] }
        #if os(Linux)
            return Self.linuxResidentBytes(ofGroups: groups)
        #elseif canImport(Darwin)
            return try Self.darwinResidentBytes(ofGroups: groups)
        #else
            return [:]
        #endif
    }

    public func signalGroup(_ pgid: Int32, _ signal: ProcessSignal) throws {
        try Self.checkTarget(pgid)
        let number = signal == .term ? SIGTERM : SIGKILL
        if killpg(pgid, number) != 0 {
            let code = errno
            // Already gone: nothing to signal.
            if code == ESRCH { return }
            throw ProcessControlError.system(call: "killpg(\(pgid), \(signal.rawValue))", errno: code)
        }
    }

    public func terminateGroup(_ pgid: Int32, graceSeconds: Double) throws {
        try signalGroup(pgid, .term)
        if try waitUntilGone(pgid, seconds: graceSeconds) { return }
        try signalGroup(pgid, .kill)
        _ = try waitUntilGone(pgid, seconds: max(1, graceSeconds))
    }

    /// True if no live (non-zombie) process remains in the group within `seconds`.
    public func waitUntilGone(_ pgid: Int32, seconds: Double) throws -> Bool {
        let deadline = Date().addingTimeInterval(max(0, seconds))
        while true {
            if try !isGroupLive(pgid) { return true }
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }

    public func isGroupLive(_ pgid: Int32) throws -> Bool {
        try liveProcessGroups().contains(pgid)
    }

    /// `linux:<boot id>:<start ticks>` from `/proc/<pid>/stat` and the kernel boot id, or
    /// `darwin:<start sec>.<usec>` from `sysctl(KERN_PROC_PID)`. Zombies still have an
    /// identity (their start time is valid until reaped).
    public func processIdentity(_ pid: Int32) throws -> String? {
        guard pid > 0 else { return nil }
        #if os(Linux)
            guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
                let start = Self.parseStartTime(stat)
            else { return nil }
            return "linux:\(Self.bootID):\(start)"
        #elseif canImport(Darwin)
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
            let start = info.kp_proc.p_un.__p_starttime
            return "darwin:\(start.tv_sec).\(start.tv_usec)"
        #else
            return nil
        #endif
    }

    /// True when `processes(withEnvironmentEntry:)` can actually see other processes'
    /// environments. Always on Linux. On macOS it is probed once (see
    /// `darwinEnvironmentReadable`), because recent releases hide them from
    /// `KERN_PROCARGS2` even for the same user, and an empty scan must not be read as
    /// "the command never started" (#47).
    public var supportsEnvironmentScan: Bool {
        #if os(Linux)
            return true
        #elseif canImport(Darwin)
            return Self.darwinEnvironmentReadable
        #else
            return false
        #endif
    }

    #if canImport(Darwin)
        /// Spawns a short-lived `/bin/sleep` (its own process group, no inherited
        /// descriptors) carrying a unique marker, checks whether the marker is readable,
        /// then kills and reaps it. Computed once per process.
        static let darwinEnvironmentReadable: Bool = {
            let value = "\(getpid())-\(UInt64.random(in: 1...UInt64.max))"
            let marker = "SIMQ_ENV_PROBE=\(value)"
            guard
                let pid = try? ProcessSpawner.spawn(
                    executable: "/bin/sleep", argv: ["/bin/sleep", "5"], environment: ["SIMQ_ENV_PROBE": value],
                    cwd: nil, outputPath: "/dev/null")
            else { return false }
            defer {
                kill(pid, SIGKILL)
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0, errno == EINTR {}
            }
            for _ in 0..<20 {
                if darwinEnvironment(pid).contains(marker) { return true }
                usleep(10_000)
            }
            return false
        }()
    #endif

    /// Reads each process's initial environment: `/proc/<pid>/environ` on Linux,
    /// `sysctl(KERN_PROCARGS2)` on macOS. Only processes of the same user are readable,
    /// which covers everything SimQueue spawns. Zombies are skipped.
    public func processes(withEnvironmentEntry entry: String) throws -> [ProcessMatch] {
        var matches: [ProcessMatch] = []
        #if os(Linux)
            let needle = Array(entry.utf8)
            for name in try FileManager.default.contentsOfDirectory(atPath: "/proc") where name.first?.isNumber == true
            {
                guard let pid = Int32(name),
                    let environ = FileManager.default.contents(atPath: "/proc/\(name)/environ"),
                    environ.split(separator: 0).contains(where: { Array($0) == needle }),
                    let stat = try? String(contentsOfFile: "/proc/\(name)/stat", encoding: .utf8),
                    let parsed = Self.parseStat(stat), parsed.state != "Z", parsed.state != "X"
                else { continue }
                matches.append(ProcessMatch(pid: pid, pgid: parsed.pgid))
            }
        #elseif canImport(Darwin)
            for process in try Self.darwinProcesses() where process.kp_proc.p_stat != 5 {
                let pid = process.kp_proc.p_pid
                guard pid > 0, Self.darwinEnvironment(pid).contains(entry) else { continue }
                matches.append(ProcessMatch(pid: pid, pgid: process.kp_eproc.e_pgid))
            }
        #endif
        return matches.sorted { $0.pid < $1.pid }
    }

    /// Splits a `/proc/<pid>/environ` or procargs block into NUL-terminated strings.
    public static func nulSeparated(_ bytes: some Collection<UInt8>) -> [String] {
        bytes.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The environment part of a `KERN_PROCARGS2` buffer: `argc` (Int32), the exec path,
    /// NUL padding, `argc` argument strings, then the environment strings.
    public static func environment(fromProcArgs buffer: [UInt8]) -> [String] {
        guard buffer.count > 4 else { return [] }
        let argc = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var index = 4
        // Exec path, then any NUL padding.
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        while index < buffer.count, buffer[index] == 0 { index += 1 }
        var skipped = 0
        while index < buffer.count, skipped < argc {
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            index += 1
            skipped += 1
        }
        var result: [String] = []
        while index < buffer.count {
            let start = index
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            if index == start { break }  // the environment ends at an empty string
            result.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return result
    }

    #if canImport(Darwin)
        static func darwinEnvironment(_ pid: Int32) -> [String] {
            var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
            var size = 0
            guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
            var buffer = [UInt8](repeating: 0, count: size)
            guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
            return environment(fromProcArgs: Array(buffer.prefix(size)))
        }
    #endif

    #if os(Linux)
        /// Changes on every boot, so start ticks from different boots never compare equal.
        static let bootID: String =
            (try? String(contentsOfFile: "/proc/sys/kernel/random/boot_id", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown-boot"
    #endif

    /// Field 22 (`starttime`, clock ticks since boot) of a `/proc/<pid>/stat` line.
    public static func parseStartTime(_ line: String) -> UInt64? {
        guard let close = line.lastIndex(of: ")") else { return nil }
        let fields = line[line.index(after: close)...].split(separator: " ", omittingEmptySubsequences: true)
        // fields[0] is field 3 (state), so field 22 is fields[19].
        guard fields.count > 19 else { return nil }
        return UInt64(fields[19])
    }

    static func checkTarget(_ pgid: Int32) throws {
        guard pgid > 1 else {
            throw ProcessControlError.refused("process group \(pgid) is not a job group")
        }
        guard pgid != getpgrp() else {
            throw ProcessControlError.refused("process group \(pgid) is the daemon's own")
        }
    }

    #if os(Linux)
        /// Scans `/proc/<pid>/stat` and collects the group of every process that is not a
        /// zombie (`Z`) or dead (`X`).
        static func linuxLiveGroups() throws -> Set<Int32> {
            var groups = Set<Int32>()
            let entries = try FileManager.default.contentsOfDirectory(atPath: "/proc")
            for entry in entries where entry.first?.isNumber == true {
                guard let stat = try? String(contentsOfFile: "/proc/\(entry)/stat", encoding: .utf8),
                    let parsed = parseStat(stat), parsed.state != "Z", parsed.state != "X"
                else { continue }
                groups.insert(parsed.pgid)
            }
            return groups
        }
    #endif

    #if os(Linux)
        /// One `/proc` walk: sums `/proc/<pid>/statm` resident pages of live members, by group.
        static func linuxResidentBytes(ofGroups groups: Set<Int32>) -> [Int32: UInt64] {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else { return [:] }
            let page = UInt64(max(1, sysconf(Int32(_SC_PAGESIZE))))
            var totals: [Int32: UInt64] = [:]
            for entry in entries where entry.first?.isNumber == true {
                guard let stat = try? String(contentsOfFile: "/proc/\(entry)/stat", encoding: .utf8),
                    let parsed = parseStat(stat), groups.contains(parsed.pgid), parsed.state != "Z",
                    parsed.state != "X",
                    let statm = try? String(contentsOfFile: "/proc/\(entry)/statm", encoding: .utf8)
                else { continue }
                let fields = statm.split(separator: " ")
                guard fields.count >= 2, let pages = UInt64(fields[1]) else { continue }
                totals[parsed.pgid, default: 0] += pages * page
            }
            return totals
        }
    #endif

    #if canImport(Darwin)
        /// One `sysctl(KERN_PROC_ALL)` walk: sums `proc_pidinfo(PROC_PIDTASKINFO)` resident sizes
        /// of live members, by group.
        static func darwinResidentBytes(ofGroups groups: Set<Int32>) throws -> [Int32: UInt64] {
            var totals: [Int32: UInt64] = [:]
            for process in try darwinProcesses()
            where groups.contains(process.kp_eproc.e_pgid) && process.kp_proc.p_stat != 5 {
                var info = proc_taskinfo()
                let size = Int32(MemoryLayout<proc_taskinfo>.size)
                guard proc_pidinfo(process.kp_proc.p_pid, PROC_PIDTASKINFO, 0, &info, size) == size else { continue }
                totals[process.kp_eproc.e_pgid, default: 0] += info.pti_resident_size
            }
            return totals
        }
    #endif

    /// Parses the state and process group out of a `/proc/<pid>/stat` line. The command
    /// name is in parentheses and may itself contain spaces or parentheses, so fields are
    /// counted from the last `)`.
    static func parseStat(_ line: String) -> (state: Character, pgid: Int32)? {
        guard let close = line.lastIndex(of: ")") else { return nil }
        let fields = line[line.index(after: close)...].split(separator: " ", omittingEmptySubsequences: true)
        // state, ppid, pgrp, ...
        guard fields.count >= 3, let state = fields[0].first, let pgid = Int32(fields[2]) else { return nil }
        return (state, pgid)
    }

    #if canImport(Darwin)
        static func darwinLiveGroups() throws -> Set<Int32> {
            var groups = Set<Int32>()
            // p_stat 5 is SZOMB (sys/proc.h).
            for process in try darwinProcesses() where process.kp_proc.p_stat != 5 {
                groups.insert(process.kp_eproc.e_pgid)
            }
            return groups
        }

        static func darwinProcesses() throws -> [kinfo_proc] {
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else {
                throw ProcessControlError.system(call: "sysctl(KERN_PROC_ALL)", errno: errno)
            }
            let stride = MemoryLayout<kinfo_proc>.stride
            // Leave room for processes started between the two calls.
            var capacity = size / stride + 64
            var processes = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
            size = capacity * stride
            let result = processes.withUnsafeMutableBytes { buffer in
                sysctl(&mib, u_int(mib.count), buffer.baseAddress, &size, nil, 0)
            }
            guard result == 0 else {
                throw ProcessControlError.system(call: "sysctl(KERN_PROC_ALL)", errno: errno)
            }
            capacity = size / stride
            return Array(processes.prefix(capacity))
        }
    #endif
}

/// How a child process ended.
public enum ChildExit: Sendable, Equatable {
    case exited(Int32)
    case signaled(Int32)

    /// Shell convention: the exit code, or 128 + signal number.
    public var shellStatus: Int32 {
        switch self {
        case .exited(let code): return code
        case .signaled(let signal): return 128 + signal
        }
    }

    public var description: String {
        switch self {
        case .exited(let code): return "exited with status \(code)"
        case .signaled(let signal): return "killed by signal \(signal)"
        }
    }
}

/// Starts job commands as the leader of a new process group and reaps them one pid at a
/// time (never `waitpid(-1)`, so it can't steal another component's children).
public enum ProcessSpawner {
    /// Finds the executable for `name` the way a shell would: a name containing `/` is a
    /// path (relative to `cwd`); otherwise each `PATH` entry is tried in order. Nil if
    /// nothing executable is found.
    public static func resolveExecutable(_ name: String, path: String?, cwd: String?) -> String? {
        let base = cwd ?? FileManager.default.currentDirectoryPath
        func absolute(_ candidate: String) -> String {
            candidate.hasPrefix("/") ? candidate : base + "/" + candidate
        }
        func isExecutableFile(_ candidate: String) -> Bool {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory)
                && !isDirectory.boolValue && access(candidate, X_OK) == 0
        }
        if name.contains("/") {
            let candidate = absolute(name)
            return isExecutableFile(candidate) ? candidate : nil
        }
        let entries = (path ?? "/usr/bin:/bin").split(separator: ":", omittingEmptySubsequences: false)
        for entry in entries {
            let directory = entry.isEmpty ? "." : String(entry)
            let candidate = absolute(directory + "/" + name)
            if isExecutableFile(candidate) { return candidate }
        }
        return nil
    }

    /// Spawns `executable` with `argv` (argv[0] is passed through unchanged when there is
    /// no `cwd`) in a new process group whose id is the returned pid. stdin is
    /// `/dev/null`; stdout and stderr append to `outputPath`. The working directory is
    /// `cwd` if given. Signal mask and dispositions are reset to defaults. With
    /// `newSession` the child leads a new session (setsid, so also its own group) instead,
    /// with no controlling terminal: used to detach an auto-started simqd.
    public static func spawn(
        executable: String, argv: [String], environment: [String: String], cwd: String?, outputPath: String,
        newSession: Bool = false
    ) throws -> Int32 {
        precondition(!argv.isEmpty, "argv must not be empty")
        var file = executable
        var arguments = argv
        if let cwd {
            // posix_spawn has no portable chdir, so a tiny sh wrapper changes directory and
            // then execs the command in place: same pid, same process group.
            file = "/bin/sh"
            arguments =
                ["/bin/sh", "-c", "cd -- \"$1\" || exit 126; shift; exec \"$@\"", "simq-job", cwd, executable]
                + argv.dropFirst()
        }
        let outputFD = open(outputPath, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard outputFD >= 0 else {
            throw ProcessControlError.system(call: "open \(outputPath)", errno: errno)
        }
        defer { close(outputFD) }

        #if canImport(Darwin)
            var actions: posix_spawn_file_actions_t? = nil
            var attributes: posix_spawnattr_t? = nil
        #else
            var actions = posix_spawn_file_actions_t()
            var attributes = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outputFD, 1)
        posix_spawn_file_actions_adddup2(&actions, outputFD, 2)

        var flags = Int32(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        flags |= newSession ? Self.spawnSetSID : Int32(POSIX_SPAWN_SETPGROUP)
        #if canImport(Darwin)
            // Close every other descriptor the daemon holds (socket, database, lock).
            flags |= Int32(POSIX_SPAWN_CLOEXEC_DEFAULT)
        #endif
        posix_spawnattr_setflags(&attributes, Int16(truncatingIfNeeded: flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attributes, &emptyMask)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for number in [SIGPIPE, SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGCHLD] {
            sigaddset(&defaults, number)
        }
        posix_spawnattr_setsigdefault(&attributes, &defaults)

        let env = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let status = withCStrings(arguments) { argvPointers in
            withCStrings(env) { envPointers in
                posix_spawn(&pid, file, &actions, &attributes, argvPointers, envPointers)
            }
        }
        guard status == 0 else {
            throw ProcessControlError.system(call: "posix_spawn \(executable)", errno: status)
        }
        return pid
    }

    /// `POSIX_SPAWN_SETSID` (macOS 10.15+, glibc 2.26+); spelled out because glibc only
    /// exposes the macro under `_GNU_SOURCE`.
    #if canImport(Darwin)
        static let spawnSetSID: Int32 = 0x0400
    #else
        static let spawnSetSID: Int32 = 0x80
    #endif

    /// Observes an exited child without reaping it. Its PID and leader start time
    /// remain reserved until verified process-group cleanup finishes.
    public static func peekExit(_ pid: Int32) throws -> ChildExit? {
        var info = siginfo_t()
        while true {
            let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
            if result == 0 {
                guard info.si_signo != 0 else { return nil }
                #if canImport(Darwin)
                    let status = info.si_status
                #else
                    let status = info._sifields._sigchld.si_status
                #endif
                return info.si_code == CLD_EXITED ? .exited(status) : .signaled(status)
            }
            if errno == EINTR { continue }
            throw ProcessControlError.system(call: "waitid(\(pid))", errno: errno)
        }
    }

    /// Non-blocking reap of one child. Nil while it is still running.
    public static func reap(_ pid: Int32) throws -> ChildExit? {
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == 0 { return nil }
            if result == pid { return decode(status) }
            if errno == EINTR { continue }
            throw ProcessControlError.system(call: "waitpid(\(pid))", errno: errno)
        }
    }

    static func decode(_ status: Int32) -> ChildExit {
        // WIFEXITED / WEXITSTATUS / WTERMSIG, spelled out (the macros aren't imported).
        let low = status & 0x7f
        if low == 0 {
            return .exited((status >> 8) & 0xff)
        }
        return .signaled(low)
    }

    private static func withCStrings<R>(
        _ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R
    ) -> R {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeBufferPointer { buffer in
            // Never empty: it always holds at least the terminating nil.
            guard let base = buffer.baseAddress else { preconditionFailure("empty argument vector") }
            return body(base)
        }
    }
}

extension ProcessSpawner {
    /// Spawns a tool in its own process group (pgid = the returned pid) with stdin
    /// `/dev/null` and stdout/stderr on new pipes, whose read ends are returned. Used by
    /// `ToolRunner`, so a timeout can signal the tool and everything it forked.
    static func spawnTool(executable: String, argv: [String], environment: [String: String]) throws -> (
        pid: Int32, stdout: Int32, stderr: Int32
    ) {
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { throw ProcessControlError.system(call: "pipe", errno: errno) }
        guard pipe(&errPipe) == 0 else {
            let code = errno
            close(outPipe[0])
            close(outPipe[1])
            throw ProcessControlError.system(call: "pipe", errno: code)
        }
        // The parent's read ends must not leak into the child (or later children).
        _ = fcntl(outPipe[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(errPipe[0], F_SETFD, FD_CLOEXEC)
        #if canImport(Darwin)
            var actions: posix_spawn_file_actions_t? = nil
            var attributes: posix_spawnattr_t? = nil
        #else
            var actions = posix_spawn_file_actions_t()
            var attributes = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        var flags = Int32(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        #if canImport(Darwin)
            flags |= Int32(POSIX_SPAWN_CLOEXEC_DEFAULT)
        #else
            posix_spawn_file_actions_addclose(&actions, outPipe[1])
            posix_spawn_file_actions_addclose(&actions, errPipe[1])
        #endif
        posix_spawnattr_setflags(&attributes, Int16(truncatingIfNeeded: flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attributes, &emptyMask)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for number in [SIGPIPE, SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGCHLD] { sigaddset(&defaults, number) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        let env = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let status = withCStrings(argv) { argvPointers in
            withCStrings(env) { envPointers in
                posix_spawn(&pid, executable, &actions, &attributes, argvPointers, envPointers)
            }
        }
        close(outPipe[1])
        close(errPipe[1])
        guard status == 0 else {
            close(outPipe[0])
            close(errPipe[0])
            throw ProcessControlError.system(call: "posix_spawn \(executable)", errno: status)
        }
        return (pid, outPipe[0], errPipe[0])
    }

    /// Blocking reap of one child (retries on EINTR). Nil if it can't be reaped.
    static func waitBlocking(_ pid: Int32) -> ChildExit? {
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, 0)
            if result == pid { return decode(status) }
            if result < 0, errno == EINTR { continue }
            return nil
        }
    }
}
