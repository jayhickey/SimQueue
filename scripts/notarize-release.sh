#!/bin/bash
# Sign, notarize, staple, assess, and repackage an already-built release directory.
# Secrets and raw receipts stay outside the source tree. Never enable shell tracing.
set -euo pipefail
[ "$#" -eq 3 ] || { echo 'usage: notarize-release.sh <version> <release dir> <output dir>' >&2; exit 64; }
version=$1
release=$2
out=$3
: "${SIMQ_SIGNING_IDENTITY:?Set a Developer ID Application signing identity}"
[ -d "$release/SimQueue.app" ] || { echo 'Missing SimQueue.app' >&2; exit 1; }
[ "$(basename "$release")" = "simqueue-$version-macos-arm64" ] || { echo 'Unexpected release directory' >&2; exit 1; }
for tool in simq simqd; do
  [ -x "$release/bin/$tool" ] || { echo "Missing $tool" >&2; exit 1; }
  [ "$("$release/bin/$tool" --version)" = "$version" ] || { echo "Version mismatch: $tool" >&2; exit 1; }
done

# A Keychain profile is convenient locally; a dedicated API key works on CI.
auth=()
if [ -n "${SIMQ_NOTARY_PROFILE:-}" ]; then
  auth=(--keychain-profile "$SIMQ_NOTARY_PROFILE")
elif [ -n "${SIMQ_NOTARY_KEY_PATH:-}" ] && [ -n "${SIMQ_NOTARY_KEY_ID:-}" ]; then
  [ -f "$SIMQ_NOTARY_KEY_PATH" ] || { echo 'Notarization API key file is missing' >&2; exit 1; }
  auth=(--key "$SIMQ_NOTARY_KEY_PATH" --key-id "$SIMQ_NOTARY_KEY_ID")
  if [ -n "${SIMQ_NOTARY_ISSUER:-}" ]; then auth+=(--issuer "$SIMQ_NOTARY_ISSUER"); fi
else
  echo 'Set SIMQ_NOTARY_PROFILE or SIMQ_NOTARY_KEY_PATH and SIMQ_NOTARY_KEY_ID' >&2
  exit 1
fi
signing=(--force --options runtime --timestamp --sign "$SIMQ_SIGNING_IDENTITY")
if [ -n "${SIMQ_SIGNING_KEYCHAIN:-}" ]; then signing+=(--keychain "$SIMQ_SIGNING_KEYCHAIN"); fi
umask 077
mkdir -p "$out"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
name="simqueue-$version-macos-arm64"
# Avoid replacing an existing archive, including on failed/retried notarization.
[ ! -e "$out/$name.tar.gz" ] || { echo 'Output archive already exists' >&2; exit 1; }

for executable in "$release/bin/simq" "$release/bin/simqd" "$release/SimQueue.app"; do
  codesign "${signing[@]}" "$executable"
  codesign --verify --strict "$executable"
  codesign --display --verbose=4 "$executable" 2>"$work/signature.txt"
  grep -q '^Authority=Developer ID Application:' "$work/signature.txt" || {
    echo 'A Developer ID Application signature is required; refusing non-distribution identity' >&2; exit 1;
  }
  grep -q 'flags=.*runtime' "$work/signature.txt" || { echo 'Hardened runtime missing' >&2; exit 1; }
  grep -q '^Timestamp=' "$work/signature.txt" || { echo 'Secure timestamp missing' >&2; exit 1; }
done

# Submit all distributed Mach-O executables, not just the app bundle.
ditto -c -k --keepParent "$release" "$work/submission.zip"
xcrun notarytool submit "$work/submission.zip" "${auth[@]}" --wait --timeout 20m --output-format json >"$work/submission.json"
python3 - "$work/submission.json" <<'PY'
import json, sys
receipt = json.load(open(sys.argv[1]))
status = receipt.get("status")
print("Notarization submission:", receipt.get("id"))
print("Notarization status:", status)
if status != "Accepted":
    raise SystemExit("Apple did not accept the submission; no release archive will be created")
PY
xcrun stapler staple "$release/SimQueue.app"
xcrun stapler validate "$release/SimQueue.app"
codesign --verify --deep --strict "$release/SimQueue.app"
spctl --assess --type execute --verbose=2 "$release/SimQueue.app"
# Rebuild only after stapling: the downloadable app must contain the ticket.
COPYFILE_DISABLE=1 tar -C "$(dirname "$release")" -czf "$out/$name.tar.gz" "$name"
(cd "$out" && shasum -a 256 "$name.tar.gz" >"$name.tar.gz.sha256" && shasum -a 256 -c "$name.tar.gz.sha256")
echo "$out/$name.tar.gz"
