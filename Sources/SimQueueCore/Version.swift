// SPDX-License-Identifier: MIT

/// The SimQueue version string shared by `simq` and `simqd`.
///
/// One source: the release workflow runs `scripts/stamp-version.sh <tag>`, which rewrites
/// `current` from the tag before the release build. Source checkouts report the dev value.
public enum SimQueueVersion {
    public static let current = "0.0.0-dev"

    /// True for `MAJOR.MINOR.PATCH` with an optional `-prerelease` and `+build` suffix
    /// (dot-separated ASCII letters, digits and hyphens). The same rule the stamp script checks.
    public static func isValid(_ version: String) -> Bool {
        var rest = Substring(version)
        var build: Substring?
        if let plus = rest.firstIndex(of: "+") {
            build = rest[rest.index(after: plus)...]
            rest = rest[..<plus]
        }
        var prerelease: Substring?
        if let dash = rest.firstIndex(of: "-") {
            prerelease = rest[rest.index(after: dash)...]
            rest = rest[..<dash]
        }
        let numbers = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3, numbers.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } })
        else { return false }
        return [prerelease, build].compactMap { $0 }.allSatisfy { suffix in
            suffix.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { field in
                !field.isEmpty && field.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            }
        }
    }
}
