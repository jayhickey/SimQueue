// SPDX-License-Identifier: MIT

import Foundation

/// Checks that a job's `git_sha` is what is checked out in its worktree (spec §5k), so a
/// bot that moves its worktree between submit and start can't get a different commit
/// tested under the submitted sha. Read-only: runs `git rev-parse` with a timeout.
public struct GitCheckout: Sendable {
    public var runner: ToolRunner
    public var timeoutSeconds: Double

    public init(runner: ToolRunner = ToolRunner(), timeoutSeconds: Double = 10) {
        self.runner = runner
        self.timeoutSeconds = timeoutSeconds
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// The directory isn't a git checkout (or git couldn't read it).
        case notACheckout(path: String, detail: String)
        /// The sha doesn't name a commit in that checkout.
        case unknownCommit(sha: String, path: String)
        /// HEAD is a different commit.
        case mismatch(sha: String, head: String, path: String)
        case gitUnavailable(String)

        public var description: String {
            switch self {
            case .notACheckout(let path, let detail):
                "\(path) is not a git checkout (\(detail)); git_sha can't be checked"
            case .unknownCommit(let sha, let path):
                "git_sha \(sha) is not a commit in \(path); fetch it or pass the sha that's checked out"
            case .mismatch(let sha, let head, let path):
                "git_sha \(GitCheckout.short(sha)) is not what's checked out in \(path) (HEAD is "
                    + "\(GitCheckout.short(head))); check out \(GitCheckout.short(sha)) there or pass "
                    + "--git-sha \(GitCheckout.short(head))"
            case .gitUnavailable(let detail): "git is unavailable: \(detail)"
            }
        }
    }

    static func short(_ sha: String) -> String { String(sha.prefix(12)) }

    /// A sha as git would accept it: 4...64 hex digits.
    public static func isPlausibleSHA(_ text: String) -> Bool {
        (4...64).contains(text.utf8.count)
            && text.unicodeScalars.allSatisfy {
                ("0"..."9").contains($0) || ("a"..."f").contains($0) || ("A"..."F").contains($0)
            }
    }

    /// The full sha of HEAD in `path`.
    public func head(in path: String) throws -> String {
        try revParse(["HEAD"], in: path) ?? { throw Failure.notACheckout(path: path, detail: "no HEAD") }()
    }

    /// Start-time check for a job that already stored its full sha: one `rev-parse HEAD`.
    /// Throws `mismatch` when HEAD moved, `notACheckout`/`gitUnavailable` when git can't say.
    public func requireHead(_ fullSHA: String, in path: String) throws {
        let head = try head(in: path)
        guard head.lowercased() == fullSHA.lowercased() else {
            throw Failure.mismatch(sha: fullSHA, head: head, path: path)
        }
    }

    /// Resolves `sha` in `path` and checks it is HEAD there. Returns the full sha.
    public func verify(sha: String, in path: String) throws -> String {
        let head = try head(in: path)
        guard let full = try revParse(["--verify", "--quiet", "\(sha)^{commit}"], in: path) else {
            throw Failure.unknownCommit(sha: sha, path: path)
        }
        guard full == head else { throw Failure.mismatch(sha: full, head: head, path: path) }
        return full
    }

    /// `git -C path rev-parse args...`: the first output line, or nil when git says no.
    private func revParse(_ arguments: [String], in path: String) throws -> String? {
        let result: ToolResult
        do {
            result = try runner.run("git", ["-C", path, "rev-parse"] + arguments, timeoutSeconds: timeoutSeconds)
        } catch {
            throw Failure.gitUnavailable("\(error)")
        }
        if result.status == 128 {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.notACheckout(path: path, detail: String(detail.prefix(200)))
        }
        guard result.succeeded else { return nil }
        let line = result.stdout.split(separator: "\n").first.map(String.init) ?? ""
        return line.isEmpty ? nil : line
    }
}
