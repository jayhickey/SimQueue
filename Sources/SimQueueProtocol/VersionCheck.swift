// SPDX-License-Identifier: MIT

extension DoctorCheck {
    /// The `version` line `simq doctor` adds: this `simq` and the daemon it reached. A
    /// mismatch warns (an upgrade swapped the binaries but simqd wasn't restarted, or a
    /// stale `simq` is first on PATH).
    public static func version(client: String, daemon: String?) -> DoctorCheck {
        guard let daemon else {
            return DoctorCheck(name: "version", level: .ok, detail: "simq \(client) (daemon not running)")
        }
        if daemon == client {
            return DoctorCheck(name: "version", level: .ok, detail: "simq \(client), simqd \(daemon)")
        }
        return DoctorCheck(
            name: "version", level: .warn,
            detail: "simq \(client), simqd \(daemon): they differ; restart simqd (or fix PATH) so both run one build")
    }
}
