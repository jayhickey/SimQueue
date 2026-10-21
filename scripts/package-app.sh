#!/bin/bash
# Assemble an unsigned local macOS app from an existing bounded Swift build.
set -euo pipefail
[ "$#" -eq 2 ] || { echo 'usage: package-app.sh <bin dir> <output dir>' >&2; exit 64; }
bin=$1
out=$2
app="$out/SimQueue.app"
[ ! -e "$app" ] || { echo "Already exists: $app" >&2; exit 1; }
[ -x "$bin/SimQueueApp" ] || { echo 'Build SimQueueApp first' >&2; exit 1; }
mkdir -p "$app/Contents/MacOS"
cp "$bin/SimQueueApp" "$app/Contents/MacOS/SimQueueApp"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.simqueue.menubar</string>
<key>CFBundleName</key><string>SimQueue</string>
<key>CFBundleExecutable</key><string>SimQueueApp</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$app"
echo "$app"
