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

Place disposable build output, package build intermediates and tool environments under
`$SIMQ_DERIVED_DATA` (`$SIMQ_RUN_DIR/DerivedData`). This top-level directory gets the shorter
build-product retention; a nested `TestFlight/DerivedData`, for example, follows the enclosing
artifact directory's retention instead.

Host configuration can change these values and set `age_rules.artifact_budget_gib` to bound
retained job output by size. The budget removes eligible terminal output, successful jobs
first; active work and pins remain protected. It is a retention target, not a hard disk quota.
 Retention deletion requires cleanup enforcement; report-only mode only shows candidates. Inspect `simq gc` before applying `simq gc --apply`. Copy evidence you need to keep elsewhere before its retention period expires. Pins are retention controls, not permanent backups.

- The run dir belongs to the job: SimQueue never deletes it while the job is running, and
  eligible retention removes it according to `age_rules.artifact_retention_days`. DerivedData has its own shorter retention period.
- `simctl io ... recordVideo` and `screenshot` need a booted sim, which the lease guarantees.
  Their exact flags vary by Xcode release; check the host tool help. Run simulator operations inside the leased command and target its `SIMQ_UDID`. Warm state may persist from earlier jobs; choose [reset or fresh preparation](TEMPLATE.md) when needed.

## Durable output holds

Use an output hold when generated build products or evidence must survive between
explicit jobs, an upload, or a review. A hold protects the **whole job run directory**,
including its top-level DerivedData, from age, DerivedData TTL and budget deletion.
It also preserves the job's history even when no output directory exists. Normal
command finalization still cleans disposable `SIMQ_TMPDIR`; put reusable build products
in DerivedData or other persistent run-directory paths. Holds have no automatic expiry, heartbeat or PID lifetime. They survive cancellation, retries,
client disconnects and daemon restarts.

```sh
HOLD=$(uuidgen)
simq output-hold create --id "$HOLD" --label 'build and evidence' --json
simq run --sims 0 --output-hold "$HOLD" --result-file build-result.json -- ./build.sh
# Inspect build-result.json and explicitly pass needed paths to a later consumer.
simq run --sims 0 --output-hold "$HOLD" -- ./upload-and-verify.sh
simq output-hold show "$HOLD" --json
# Release only after upload, review and your workflow's grace period are complete.
simq output-hold release "$HOLD" --json
```

Each job still gets its own normal output paths. SimQueue does not route a later job
to an earlier job's DerivedData, adopt terminal jobs, register arbitrary paths, or
schedule dependencies. Prefer each job's own paths. Sequential consumers of an
explicit earlier path must finish before release; the caller must prevent concurrent
writes. This is a deletion veto, not a simulator lease, file lock, writer guard or
permission to own another job's output. Application/CI rules for worktrees, sessions,
PRs, upload verification and grace periods belong in the caller's adapter.

Attach at submission with `submit --output-hold UUID` or `run --output-hold UUID`.
Only a newly submitted job or an active dedupe match can join. Protected submission
is atomic and requires explicit daemon support; it fails rather than silently
submitting an unprotected job to an older daemon. A pending overlapping removal or
recovery intent rejects attachment. An acknowledgement does not restore previously
deleted output. Several active holds may protect one deduped job; all must be released
before the hold veto ends.

Release is permanent and idempotent. It is refused while any member is queued,
admitted or running, has unresolved command/spawn ownership, or has an executor or
preparation writer. A released UUID cannot be reused or reopened, even with the same
label. **Release resumes original age timestamps immediately**: sufficiently old output
may be deleted by the next cleanup pass. Release does not clear `submit --keep`; its
separate, age-limited pin continues to apply. Held bytes count toward total budget use
and may keep storage over its target. Storage reports identify protected output as
`Held`. Neither holds nor pins are backups.

UUIDs accept either letter case and are stored lowercase. Creation with the same
active UUID and exact label is idempotent; a different label conflicts. Labels are
printable, nonempty, without surrounding whitespace, at most 100 characters and
256 UTF-8 bytes. `output-hold list` includes released tombstones. Use `--limit 1...200`
(default 100), `list --after-id UUID` or `show UUID --after-job-id JOB` to page through
results. JSON exposes `next_id` / `next_job_id`; a full page returns a cursor and an
empty next page ends traversal. New hold creation observes database storage-pressure
backpressure; release remains available under that pressure. Released membership
history may be archived with its job; UUID tombstones remain live for this version.
Unknown managed output directories retain their existing age/budget policy.
