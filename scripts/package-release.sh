#!/bin/bash
# package-release.sh <version> <bin dir> <out dir>: check and package an Apple silicon build.
#
# Checks that simq and simqd in <bin dir> contain only Mach-O arm64 code and report
# <version>, then writes <out dir>/simqueue-<version>-macos-arm64.tar.gz (bin/simq,
# bin/simqd, LICENSE, NOTICE, README.md, AGENTS.md, docs/ and skills/) and a .sha256 file next to it ("<hash>  <file>",
# the format `shasum -a 256 -c` reads). Prints the tarball path. macOS only (lipo, shasum).
set -euo pipefail
[ $# -eq 3 ] || { echo "usage: $0 <version> <bin dir> <out dir>" >&2; exit 64; }
version=$1 bin=$2 out=$3
root="$(cd "$(dirname "$0")/.." && pwd)"

for tool in simq simqd; do
  [ -x "$bin/$tool" ] || { echo "package-release: $bin/$tool is missing" >&2; exit 1; }
  archs="$(/usr/bin/lipo -archs "$bin/$tool")"
  [ "$archs" = arm64 ] || {
    echo "package-release: $tool must contain only arm64 code (lipo: $archs)" >&2
    exit 1
  }
  reported="$("$bin/$tool" --version)"
  [ "$reported" = "$version" ] || {
    echo "package-release: $tool --version says '$reported', expected '$version'" >&2
    exit 1
  }
  echo "$tool: $archs, version $reported" >&2
done

name="simqueue-$version-macos-arm64"
stage="$(mktemp -d)"
stage="$(cd "$stage" && pwd -P)"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/$name/bin" "$out"
cp "$bin/simq" "$bin/simqd" "$stage/$name/bin/"
cp "$root/LICENSE" "$root/NOTICE" "$root/README.md" "$root/AGENTS.md" "$stage/$name/"
# Export only committed documentation: local notes and editor files must never
# become part of an installed release. Version stamping changes code, not docs.
git -C "$root" ls-files --error-unmatch docs/INSTALL.md skills/simqueue/SKILL.md >/dev/null
git -C "$root" archive HEAD -- docs skills | tar -x -C "$stage/$name"
# Exercise offline discovery from the staged release, rather than accidentally
# finding documentation in the build checkout or the caller's working directory.
documentation="$("$stage/$name/bin/simq" docs)"
# Foundation and pwd may spell macOS's /var symlink differently. Require the
# discovered directory to be the staged directory, regardless of that spelling.
[ "$documentation" -ef "$stage/$name" ] || {
  echo "package-release: staged documentation discovery returned '$documentation'" >&2
  exit 1
}
guide="$("$stage/$name/bin/simq" agent-guide)"
case "$guide" in
  "SimQueue $version agent guide"*) ;;
  *) echo "package-release: staged agent guide does not match $version" >&2; exit 1 ;;
esac
tarball="$(cd "$out" && pwd)/$name.tar.gz"
# COPYFILE_DISABLE: no AppleDouble ._ files from macOS tar.
COPYFILE_DISABLE=1 tar -C "$stage" -czf "$tarball" "$name"
(cd "$out" && shasum -a 256 "$name.tar.gz" >"$name.tar.gz.sha256" && shasum -a 256 -c "$name.tar.gz.sha256" >&2)
echo "$tarball"
