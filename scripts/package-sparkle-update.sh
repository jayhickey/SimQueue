#!/bin/bash
# Package the already notarized/stapled app and sign the immutable update ZIP.
set -euo pipefail
[ "$#" -eq 4 ] || { echo 'usage: package-sparkle-update.sh <stable version> <release dir> <out dir> <Sparkle SDK>' >&2; exit 64; }
version=$1 release=$2 out=$3 sdk=$4
root="$(cd "$(dirname "$0")/.." && pwd)"
app="$release/SimQueue.app"
archive="$out/SimQueue-$version.zip"
[ ! -e "$archive" ] && [ ! -e "$out/appcast.xml" ] || { echo 'Updater assets already exist' >&2; exit 1; }
codesign --verify --deep --strict "$app"
xcrun stapler validate "$app"
mkdir -p "$out"
ditto -c -k --keepParent "$app" "$archive"
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
  signature="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$sdk/bin/sign_update" --ed-key-file - -p "$archive")"
else
  signature="$("$sdk/bin/sign_update" --account dev.simqueue.sparkle -p "$archive")"
fi
public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist")"
/usr/bin/swift -j 2 "$root/scripts/verify-sparkle-update.swift" "$public_key" "$archive" "$signature"
python3 "$root/scripts/create-appcast.py" "$version" "$archive" "$signature" "$out/appcast.xml"
(cd "$out" && shasum -a 256 "SimQueue-$version.zip" >"SimQueue-$version.zip.sha256")
