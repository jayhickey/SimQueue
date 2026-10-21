#!/bin/bash
# stamp-version.sh <tag-or-version>: rewrite Sources/SimQueueCore/Version.swift for a release.
# Accepts "v1.2.3", "1.2.3", "1.2.3-rc.1" or "0.0.0-dev+abc1234". The release workflow runs it
# on the tag before `swift build -c release`; never commit the stamped file.
set -euo pipefail
[ $# -eq 1 ] || { echo "usage: $0 <tag-or-version>" >&2; exit 64; }
version="${1#refs/tags/}"
version="${version#v}"
re='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'
[[ "$version" =~ $re ]] || { echo "stamp-version: '$1' is not a semantic version" >&2; exit 65; }
file="$(cd "$(dirname "$0")/.." && pwd)/Sources/SimQueueCore/Version.swift"
grep -q '^    public static let current = "' "$file" || { echo "stamp-version: no version line in $file" >&2; exit 70; }
tmp="$(mktemp)"
sed -E "s/^(    public static let current = \")[^\"]*(\")/\1${version}\2/" "$file" >"$tmp"
cat "$tmp" >"$file"
rm -f "$tmp"
grep -q "public static let current = \"${version}\"" "$file"
echo "$version"
