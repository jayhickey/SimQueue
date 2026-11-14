// SPDX-License-Identifier: MIT

/// How long a client keeps reconnecting to a daemon that went away (a planned drain and
/// restart, a crash) before it gives up on its job.
public enum ClientReconnect {
    /// Ten minutes, unless `SIMQ_RECONNECT_SECONDS` says otherwise. The daemon's own
    /// "socket unusable" limit is kept well inside this window, so a daemon that restarts
    /// itself is answering again before its clients stop trying.
    public static let defaultSeconds: Double = 600
}
