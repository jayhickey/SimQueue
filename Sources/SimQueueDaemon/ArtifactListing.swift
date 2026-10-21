// SPDX-License-Identifier: MIT

import Foundation
import SimQueueProtocol

/// Lists the files a job left in its run directory (`SIMQ_RUN_DIR`) for job results.
/// Bounded: at most `cap` entries and `maxVisited` file-system nodes, so a huge tree
/// can't stall the daemon. Never follows symlinks.
public enum ArtifactListing {
    /// Top-level entries the daemon owns (`job.json`, `summary.md`, `events.jsonl`) or that
    /// are build products, not results. `tmp` is
    /// the job's own `TMPDIR`: scratch files there must not crowd out real artifacts (the
    /// entry cap) or use up the walk bound.
    public static let skippedTopLevel: Set<String> = ["DerivedData", "job.json", "tmp", "summary.md", "events.jsonl"]

    /// Absolute paths of the `*.xcresult` bundles among `entries` (listed under `runDir`).
    public static func resultBundles(runDir: String, entries: [ArtifactInfo]) -> [String] {
        entries.filter { $0.type == "xcresult" }.map { runDir + "/" + $0.path }
    }

    /// `info` with its run directory listed: artifacts, `artifacts_truncated` and
    /// `result_bundles`. Reads the disk, so callers run it outside the service lock.
    public static func attach(to info: JobInfo) -> JobInfo {
        guard let runDir = info.runDir else { return info }
        var info = info
        let listing = list(runDir: runDir)
        info.artifacts = listing.entries
        info.artifactsTruncated = listing.truncated ? true : nil
        info.resultBundles = resultBundles(runDir: runDir, entries: listing.entries)
        return info
    }

    public static func list(runDir: String, cap: Int = ArtifactInfo.listCap, maxVisited: Int = 20_000) -> (
        entries: [ArtifactInfo], truncated: Bool
    ) {
        let manager = FileManager.default
        var entries: [ArtifactInfo] = []
        var truncated = false
        var visited = 0

        func kind(_ path: String) -> FileAttributeType? {
            (try? manager.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
        }
        func size(_ path: String) -> UInt64 {
            ((try? manager.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value ?? 0
        }
        func treeSize(_ path: String) -> UInt64 {
            var total: UInt64 = 0
            guard let names = try? manager.contentsOfDirectory(atPath: path) else { return 0 }
            for name in names {
                visited += 1
                guard visited <= maxVisited else {
                    truncated = true  // the walk bound cut this bundle's size (and the listing) short
                    return total
                }
                let child = path + "/" + name
                switch kind(child) {
                case .typeRegular?: total += size(child)
                case .typeDirectory?: total += treeSize(child)
                default: break
                }
            }
            return total
        }
        func walk(_ path: String, relative: String) {
            guard let names = try? manager.contentsOfDirectory(atPath: path) else { return }
            for name in names.sorted() {
                guard !truncated else { return }
                visited += 1
                guard visited <= maxVisited else {
                    truncated = true
                    return
                }
                guard !name.hasPrefix(".") else { continue }
                if relative.isEmpty, skippedTopLevel.contains(name) { continue }
                let child = path + "/" + name
                let rel = relative.isEmpty ? name : relative + "/" + name
                switch kind(child) {
                case .typeRegular?:
                    guard entries.count < cap else {
                        truncated = true
                        return
                    }
                    entries.append(ArtifactInfo(path: rel, bytes: size(child), type: ArtifactInfo.type(forName: name)))
                case .typeDirectory?:
                    if ArtifactInfo.isBundle(name) {
                        guard entries.count < cap else {
                            truncated = true
                            return
                        }
                        entries.append(
                            ArtifactInfo(path: rel, bytes: treeSize(child), type: ArtifactInfo.type(forName: name)))
                    } else {
                        walk(child, relative: rel)
                    }
                default:
                    continue  // symlinks, sockets, devices: never followed or listed
                }
            }
        }
        walk(runDir, relative: "")
        return (entries, truncated)
    }
}
