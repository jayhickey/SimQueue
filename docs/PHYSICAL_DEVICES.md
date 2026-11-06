# Physical iOS devices

Physical devices are an opt-in resource, separate from the simulator pool. They are only leased: SimQueue never creates, clones, erases, slims, pairs, unpairs or reboots them. Pair/trust the device and enable Developer Mode yourself before adding it. Both wired and already-established network connections work when devicectl reports a connected tunnel.

Merge a `devices` array into the daemon config and deploy/restart through your normal operator workflow:

```json
{
  "devices": [
    {
      "udid": "REPLACE-WITH-PHYSICAL-UDID",
      "name": "iPhone 15 Pro (2)",
      "labels": ["device:iphone15pro", "physical", "ios27"],
      "enabled": true
    }
  ]
}
```

`udid` and `name` are required. UDIDs must be unique. `labels` defaults to `[]`; `enabled` defaults to `true`. Labels are exact, case-sensitive matches supplied by the operator; no device model or OS labels are inferred. Omitted `devices` keeps existing simulator behavior unchanged. This example contains a placeholder intentionally; personal device identifiers belong in local configuration, never git.

## Queue commands

```sh
simq devices
simq devices --json
simq run --device device:iphone15pro --timeout 30m -- \
  xcodebuild test -project App.xcodeproj -scheme App -allowProvisioningUpdates
simq run --device physical -- xcodebuild build -scheme App
simq submit --device ios27 -- xcodebuild build -scheme App
simq run --device REPLACE-WITH-PHYSICAL-UDID -- \
  xcrun devicectl device install app /absolute/path/App.app
simq run --device device:iphone15pro -- \
  xcrun devicectl device process launch example.app -- --benchmark 'argument with spaces'
simq run --device physical -- xcrun devicectl device info processes
```

`--device` accepts an exact configured UDID or one label. The CLI implies zero simulators; raw socket/MCP submissions must specify zero simulator counts. A job gets one exclusive phone lease, held until its host process group and pending preparation are gone. Jobs wait in ordinary priority order; busy or unhealthy phones do not reserve unrelated host capacity. Host memory, CPU/load, thermal, disk, project and exclusive-slot gates still apply. Cancel, timeout, completion and restart recovery release the phone after verified host-process cleanup. An unverifiable old process keeps its lease for operator inspection rather than permitting overlapping work.

Direct `xcodebuild` commands receive `-destination id=<leased UDID>` (replacing a supplied `-destination` pair). Other flags, including `-allowProvisioningUpdates`, pass through unchanged. Direct `xcrun devicectl device install app`, `device process launch`, and `device info processes` commands receive `--device <leased UDID>`; launch also receives `--terminate-existing`. Arguments after launch's `--` keep their order and boundaries. Process info output, including PIDs, is in the job log.

Arbitrary scripts retain the existing command contract. They receive `SIMQ_UDID`, `SIMQ_DEVICE_UDID`, `SIMQ_RESOURCE_TYPE=physical` and the normal job/output variables. Use that UDID explicitly inside scripts:

```sh
simq run --device physical -- sh -c \
  'xcodebuild test -scheme App -destination "id=$SIMQ_UDID" -derivedDataPath "$SIMQ_DERIVED_DATA" -resultBundlePath "$SIMQ_RESULT_BUNDLE"'
```

Simulator flags (`--fresh-sim`, `--reset-app`, `--template`) are rejected for physical jobs. No phone UI automation or pairing automation is provided. A launched app can remain running on the device after the host command completes; the next launch uses `--terminate-existing`.

## Health and waiting states

Health uses bounded, read-only devicectl `device info details` and `device info lockState` probes. Admission requires affirmative pairing, Developer Mode and a connected tunnel. An explicitly locked device blocks admission; unavailable, missing or unknown lock state permits admission after the other checks pass. Details can be cached by devicectl, so connection status is checked explicitly. Unknown/missing pairing, Developer Mode or connection fields still block admission. Thermal state is recorded when present, not inferred when absent.

| Code | Meaning |
| --- | --- |
| `ready` | Connected, paired, Developer Mode enabled; unlocked or lock state unavailable |
| `device_busy` | All matching healthy phones are leased (`waiting:device_busy`) |
| `device_locked` | Unlock the phone (`waiting:device_locked`) |
| `device_unavailable` | Offline, disabled, tool error or unverifiable health (`blocked:device_unavailable`) |
| `device_unpaired` | Pairing is absent or not confirmed |
| `developer_mode_disabled` | Developer Mode is disabled or not confirmed |

Failures retain tool errors and back off for 30 seconds; there is no immediate retry loop. Status observations may reuse a sample for up to 30 seconds. Ready, unleased devices are probed again when a queued device job is considered. Operator fixes are picked up after the backoff. Health errors leave jobs queued, subject to their normal queue deadline. A real locked error during a failed install, launch or test command fails that job with an unlock-and-retry message, releases its lease after normal process cleanup, and records `device_locked` health for the probe backoff.

`simq status --json`, job `device`/`physical_udid` fields, and the dashboard show physical jobs and exclusive leases. MCP adds `simq_devices`; `simq_submit` takes `device` and optional `device_artifact: {"bundle": "example.app", "path": "Library/Caches/EncoderANEBenchmark"}`. Existing MCP status/jobs/explain/wait/cancel tools retain parity through the same daemon.

## Pull local artifacts

```sh
simq run --device device:iphone15pro \
  --device-artifact-bundle example.app \
  --device-artifact-path Library/Caches/EncoderANEBenchmark -- \
  xcrun devicectl device process launch example.app -- --benchmark
```

After the command returns, SimQueue runs `devicectl device copy from --domain-type appDataContainer --domain-identifier <bundle> --source <path> --destination <job run dir>/device-artifacts`. The source must be a nonempty relative container path without `..`. The copy shares the supervised process group and timeout, so cancellation stops the host copy before the phone is re-leased. This copies the state present when the launch command returns; to collect results of a long-running app, use a script that waits for benchmark completion before returning.

Artifacts remain inside the normal job directory, appear in artifact listings, and use existing budget accounting, pins and retention. The budget is the existing retention budget, not a streaming transfer-size limit; devicectl does not provide a byte-limit option. Copy failure after a successful command reports `artifact_failure`; an earlier command failure preserves its status. Cancellation/timeout may leave partial local output and does not initiate another copy.

**Privacy:** artifacts from personal phones may contain private media. Keep device artifacts local. Never commit device data, raw live validation evidence, personal UDIDs or local config to git; do not upload personal artifacts to CI or PRs. Unit tests use synthetic identifiers and fake tools only.
