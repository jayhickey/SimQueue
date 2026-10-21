# Job artifacts: logs, results, screenshots, and video

Each command gets a directory at `SIMQ_RUN_DIR`. Write useful output there so it appears with the job: test result bundles, build logs, screenshots, recordings, or your own reports. `simq explain <job> --json`, MCP's `simq_explain`/`simq_wait`, and `simq run --result-file` expose the directory and a bounded artifact listing.

SimQueue supplies suggested `SIMQ_DERIVED_DATA` and `SIMQ_RESULT_BUNDLE` paths inside that directory. Your command creates the build output and result bundle. The [test example](ACTIONS.md#run-a-test-suite) shows `xcodebuild test`; the example below builds and launches an app to capture visual evidence.

## Capture a simulator run

Save this as `proof.sh`, make it executable with `chmod +x proof.sh`, and adjust its scheme, app product name, and bundle ID. Add `-workspace YourApp.xcworkspace` or `-project YourApp.xcodeproj` to the build command when needed.

```sh
#!/bin/sh
# proof.sh: run by SimQueue with SIMQ_UDID, SIMQ_RUN_DIR and SIMQ_DERIVED_DATA set.
set -eu
: "${SIMQ_UDID:?needs a pool sim (simq run --sims 1)}"
SCHEME=${SCHEME:-MyApp}
APP_NAME=${APP_NAME:-MyApp}
BUNDLE_ID=${BUNDLE_ID:-com.example.myapp}
mkdir -p "$SIMQ_RUN_DIR/screenshots"

# 1. Build for the leased sim. DerivedData stays inside the run dir (kept 1 day by default).
xcodebuild build -scheme "$SCHEME" -configuration Debug \
  -sdk iphonesimulator -destination "id=$SIMQ_UDID" \
  -derivedDataPath "$SIMQ_DERIVED_DATA" -jobs 4 \
  > "$SIMQ_RUN_DIR/build.log" 2>&1
APP="$SIMQ_DERIVED_DATA/Build/Products/Debug-iphonesimulator/$APP_NAME.app"
[ -d "$APP" ] || { echo "App product missing: $APP" >&2; exit 1; }

# 2. Install and start recording before launch.
xcrun simctl install "$SIMQ_UDID" "$APP"
xcrun simctl io "$SIMQ_UDID" recordVideo --codec h264 "$SIMQ_RUN_DIR/proof.mp4" &
REC=$!
trap 'kill -INT "$REC" 2>/dev/null || true; wait "$REC" 2>/dev/null || true' EXIT
sleep 1

# 3. Launch and capture the screens you want as proof.
xcrun simctl launch "$SIMQ_UDID" "$BUNDLE_ID"
sleep 3
xcrun simctl io "$SIMQ_UDID" screenshot "$SIMQ_RUN_DIR/screenshots/01-launch.png"
# ...drive the app (UI test, deep link: xcrun simctl openurl "$SIMQ_UDID" myapp://screen)...
xcrun simctl io "$SIMQ_UDID" screenshot "$SIMQ_RUN_DIR/screenshots/02-after.png"

# 4. Stop the recording cleanly (SIGINT finalizes the file).
kill -INT "$REC"; wait "$REC" || true
trap - EXIT
```

## Running it

```sh
simq run --sims 1 --memory-hint-mib 2048 --timeout 30m \
  --exit-code mapped --result-file proof-result.json -- ./proof.sh
```

- On success `simq run` lists the files on stderr, one `=== simq` line each, e.g.
  `=== simq artifacts in /…/jobs/2026-10-20/<job-id>:` then `=== simq   proof.mp4  4311744 B  video`.
- `proof-result.json` is the final job record. Read the evidence back from it:

```sh
jq -r '.run_dir as $d | .artifacts[] | select(.type == "video" or .type == "image")
  | "\($d)/\(.path)\t\(.bytes)"' proof-result.json
```

Each entry is `{path, bytes, type}`, with `path` relative to `run_dir`. `DerivedData` and
`job.json` (with `summary.md` and `events.jsonl`) are never listed; a `*.xcresult` bundle is one entry. At most 200 entries are
listed (`artifacts_truncated` says when there were more), so keep proof output to the files
you'd actually look at.

## Retention and listing limits

| Artifact category | Default retention after the job ends |
| --- | --- |
| DerivedData | 1 day |
| Successful job output | 7 days |
| Failed, cancelled, interrupted, or timed-out job output | 14 days |
| Job directory without a matching record | 30 days |
| Output pinned with `submit --keep` | At least 90 days; exempt from the configured size budget |

Host configuration can change these values. Retention deletion requires cleanup enforcement; report-only mode only shows candidates. Inspect `simq gc` before applying `simq gc --apply`. Copy evidence you need to keep elsewhere before its retention period expires. Pins are retention controls, not permanent backups.

- The run dir belongs to the job: SimQueue never deletes it while the job is running, and
  eligible retention removes it according to `age_rules.artifact_retention_days`. DerivedData has its own shorter retention period.
- `simctl io ... recordVideo` and `screenshot` need a booted sim, which the lease guarantees.
  Their exact flags vary by Xcode release; check the host tool help. Run simulator operations inside the leased command and target its `SIMQ_UDID`. Warm state may persist from earlier jobs; choose [reset or fresh preparation](TEMPLATE.md) when needed.
