// SPDX-License-Identifier: MIT

import Foundation

/// `simq project add`: finds a project's Xcode container and schemes by listing files
/// (no xcodebuild), and writes its entry into `config.json`, keeping every other key.
public enum ProjectOnboarding {
    public struct Detected: Sendable, Equatable {
        /// `.xcworkspace` and `.xcodeproj` paths relative to the repo (top level only).
        public var containers: [String]
        /// Shared schemes per container (`xcshareddata/xcschemes/*.xcscheme`).
        public var schemes: [String: [String]]
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notADirectory(String)
        case ambiguous(String)
        case exists(String)
        case unreadableConfig(String)

        public var description: String {
            switch self {
            case .notADirectory(let path): return "\(path) is not a directory"
            case .ambiguous(let why): return why
            case .exists(let name): return "project \(name) already exists in config.json (pass --replace)"
            case .unreadableConfig(let why): return "config.json: \(why)"
            }
        }
    }

    public static func detect(repo: String) throws -> Detected {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repo, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure.notADirectory(repo)
        }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: repo)) ?? []
        let containers = entries.filter { $0.hasSuffix(".xcworkspace") || $0.hasSuffix(".xcodeproj") }.sorted()
        var schemes: [String: [String]] = [:]
        func shared(_ path: String) -> [String] {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: path + "/xcshareddata/xcschemes")) ?? []
            return files.filter { $0.hasSuffix(".xcscheme") }.map { String($0.dropLast(".xcscheme".count)) }
        }
        for container in containers {
            var found = shared(repo + "/" + container)
            // A workspace also offers the shared schemes of the projects it references.
            if container.hasSuffix(".xcworkspace") {
                for project in referencedProjects(workspace: repo + "/" + container, repo: repo) {
                    found += shared(project)
                }
            }
            schemes[container] = Array(Set(found)).sorted()
        }
        return Detected(containers: containers, schemes: schemes)
    }

    /// `.xcodeproj` paths a workspace's `contents.xcworkspacedata` references
    /// (`group:` and `container:` locations are relative to the workspace's folder,
    /// `absolute:` as is). Missing or unreadable: none.
    static func referencedProjects(workspace: String, repo: String) -> [String] {
        guard let text = try? String(contentsOfFile: workspace + "/contents.xcworkspacedata", encoding: .utf8) else {
            return []
        }
        let base = (workspace as NSString).deletingLastPathComponent
        var projects: [String] = []
        for part in text.components(separatedBy: "location = \"").dropFirst() {
            guard let end = part.firstIndex(of: "\"") else { continue }
            let location = String(part[..<end])
            guard location.hasSuffix(".xcodeproj"), let colon = location.firstIndex(of: ":") else { continue }
            let kind = location[..<colon]
            let path = String(location[location.index(after: colon)...])
            switch kind {
            case "absolute": projects.append(path)
            case "group", "container": projects.append(base + "/" + path)
            default: continue
            }
        }
        return projects
    }

    /// Fills in `container` and `scheme` from what's on disk when they weren't given.
    /// A workspace wins over projects (CocoaPods/SwiftPM layouts); anything still
    /// ambiguous is an error that lists the candidates.
    public static func resolve(repo: String, scheme: String?, container: String?) throws -> (
        container: String?, scheme: String
    ) {
        let found = try detect(repo: repo)
        var chosen = container
        if chosen == nil {
            let workspaces = found.containers.filter { $0.hasSuffix(".xcworkspace") }
            let candidates = workspaces.isEmpty ? found.containers : workspaces
            // With --scheme, the containers that share it; never silently none.
            let matching = scheme.map { scheme in candidates.filter { found.schemes[$0]?.contains(scheme) == true } }
            if candidates.count == 1 {
                chosen = candidates[0]
            } else if let matching, matching.count == 1 {
                chosen = matching[0]
            } else if candidates.count > 1 {
                throw Failure.ambiguous(
                    "several containers in \(repo): \(candidates.joined(separator: ", ")); pass --container")
            }
        }
        if let scheme { return (chosen, scheme) }
        let schemes = chosen.flatMap { found.schemes[$0] } ?? []
        guard schemes.count == 1 else {
            throw Failure.ambiguous(
                schemes.isEmpty
                    ? "no shared schemes found in \(chosen ?? repo); pass --scheme"
                    : "several shared schemes: \(schemes.joined(separator: ", ")); pass --scheme")
        }
        return (chosen, schemes[0])
    }

    /// Adds (or with `replace`, replaces) `projects.<name>` in the config file. The result
    /// must still parse as a valid `DaemonConfig`; the file is written atomically, mode 0600.
    public static func add(
        name: String, settings: DaemonConfig.ProjectSettings, configPath: String, replace: Bool
    ) throws {
        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: configPath) {
            guard let data = FileManager.default.contents(atPath: configPath),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw Failure.unreadableConfig("not a JSON object") }
            root = object
        }
        var projects = root["projects"] as? [String: Any] ?? [:]
        if projects[name] != nil, !replace { throw Failure.exists(name) }
        let encoder = JSONEncoder()
        projects[name] = try JSONSerialization.jsonObject(with: try encoder.encode(settings))
        root["projects"] = projects
        // Stable output: sorted keys, pretty-printed, `/` unescaped, so re-adding gives the
        // same bytes and diffs stay small.
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        _ = try DaemonConfig.parse(data)  // never write a config the daemon would reject
        // A symlinked config stays a symlink: write next to, and rename over, its target.
        let target = (configPath as NSString).resolvingSymlinksInPath
        let directory = (target as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = target + ".tmp-\(getpid())"
        guard FileManager.default.createFile(atPath: temporary, contents: nil, attributes: [.posixPermissions: 0o600]),
            let handle = FileHandle(forWritingAtPath: temporary)
        else { throw Failure.unreadableConfig("could not create \(temporary)") }
        do {
            try handle.write(contentsOf: data + Data("\n".utf8))
            try handle.synchronize()  // fsync before the rename, so a crash can't leave it empty
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(atPath: temporary)
            throw Failure.unreadableConfig("could not write \(temporary): \(error)")
        }
        if rename(temporary, target) != 0 {
            try? FileManager.default.removeItem(atPath: temporary)
            throw Failure.unreadableConfig("could not replace \(target) (errno \(errno))")
        }
        let directoryFD = open(directory, O_RDONLY)
        if directoryFD >= 0 {
            _ = fsync(directoryFD)  // and the rename itself
            close(directoryFD)
        }
    }
}
