#!/bin/bash
# Assemble an ad-hoc signed macOS app from an existing bounded Swift build.
set -euo pipefail
[ "$#" -ge 2 ] && [ "$#" -le 3 ] || { echo 'usage: package-app.sh <bin dir> <output dir> [version]' >&2; exit 64; }
bin=$1
out=$2
version=${3:-0.0.0}
# Info.plist versions use the numeric part of semantic versions.
bundle_version=${version%%[-+]*}
case "$bundle_version" in
  *[!0-9.]*|'') echo "Invalid bundle version: $version" >&2; exit 64 ;;
esac
app="$out/SimQueue.app"
[ ! -e "$app" ] || { echo "Already exists: $app" >&2; exit 1; }
[ -x "$bin/SimQueueApp" ] || { echo 'Build SimQueueApp first' >&2; exit 1; }
[ -x "$bin/simqd" ] || { echo 'Build simqd first' >&2; exit 1; }
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Library/LaunchAgents"
cp "$bin/simqd" "$app/Contents/Helpers/simqd"
cp "$(dirname "$0")/../deploy/launchd/dev.simqueue.app-daemon.plist" "$app/Contents/Library/LaunchAgents/"
/usr/bin/codesign --force --sign - --identifier dev.simqueue.app-daemon "$app/Contents/Helpers/simqd"
cp "$bin/SimQueueApp" "$app/Contents/MacOS/SimQueueApp"
[ -d "$bin/Sparkle.framework" ] || { echo 'Build the Sparkle dependency first' >&2; exit 1; }
mkdir -p "$app/Contents/Frameworks" "$app/Contents/Resources"
cp "$(dirname "$0")/../docs/licenses/Sparkle.txt" "$app/Contents/Resources/Sparkle-LICENSE.txt"
ditto "$bin/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
# SwiftPM executables normally resolve frameworks beside the executable. A
# distributed app resolves them from its signed Contents/Frameworks directory.
/usr/bin/install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/SimQueueApp"
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
<key>SUFeedURL</key><string>https://github.com/jayhickey/SimQueue/releases/latest/download/appcast.xml</string>
<key>SUPublicEDKey</key><string>MM5RFcBcSX29Kkd2031zP1DafxHx+hjEqcpb/L4kvRw=</string>
<key>SUAllowsAutomaticUpdates</key><false/>
<key>SUEnableAutomaticChecks</key><true/>
<key>SUSendProfileInfo</key><false/>
<key>SUAutomaticallyUpdate</key><false/>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $bundle_version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $bundle_version" "$app/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$app"
echo "$app"
