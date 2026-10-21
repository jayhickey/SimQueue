// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore

/// The daemon's pool-sim owner tag (`SimNamingScheme.ownerTag`), kept in `<state>/owner-tag`.
/// The first start hashes the state dir's resolved path (tilde expanded, made absolute,
/// standardized, symlinks resolved) and writes the result; every later start reuses the
/// file. So however the state dir is spelled (relative, through a symlink, with `~`), the
/// daemon keeps one tag and never mistakes its own sims for another daemon's.
public enum OwnerTagFile {
    public static let fileName = "owner-tag"

    /// The tag in `stateDirectory`'s file, else a new one from its resolved path, written
    /// there when `persist` (a dry run never writes). A file with anything but a valid tag
    /// is replaced (when persisting) by the computed one. A failed write is logged and the
    /// computed tag is still used (the next start computes the same one from the same path).
    public static func resolve(
        stateDirectory: String, persist: Bool, cwd: String? = nil, log: (String) -> Void = { _ in }
    ) -> String {
        let path = stateDirectory + "/" + fileName
        if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            let tag = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if SimNamingScheme.ownerTag(of: "simq-x-" + tag) == tag { return tag }
        }
        let tag = SimNamingScheme.ownerTag(stateDirectory: resolvedPath(stateDirectory, cwd: cwd))
        if persist {
            do {
                try FileManager.default.createDirectory(
                    atPath: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try Data((tag + "\n").utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch {
                log("simqd: couldn't save the owner tag to \(path) (\(error)); using \(tag) from the resolved path")
            }
        }
        return tag
    }

    /// Tilde expanded, absolute (against `cwd`, default the process's), standardized, and
    /// with symlinks resolved.
    public static func resolvedPath(_ path: String, cwd: String? = nil) -> String {
        var expanded = (path as NSString).expandingTildeInPath
        if !expanded.hasPrefix("/") {
            expanded = (cwd ?? FileManager.default.currentDirectoryPath) + "/" + expanded
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
