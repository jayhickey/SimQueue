# Add a project to your queue

Once the Mac has a selected [host template](TEMPLATE.md), you can submit a project immediately. A project name labels jobs for display and optional concurrency limits; it does not select a different simulator runtime or template.

For machine setup, start with [installation](INSTALL.md). This guide covers the project command you put into the queue.

## Start with one complete job

From your checkout:

```sh
simq run --project myapp --sims 1 --timeout 30m -- \
  /bin/sh -c 'xcodebuild test -workspace MyApp.xcworkspace -scheme MyApp \
    -destination "id=$SIMQ_UDID" -parallel-testing-enabled NO \
    -maximum-concurrent-test-simulator-destinations 1 \
    -derivedDataPath "$SIMQ_DERIVED_DATA" \
    -resultBundlePath "$SIMQ_RESULT_BUNDLE"'
```

Replace the workspace and scheme. You can put this command in a project script and submit that script instead. The complete suite runs on the leased simulator. Check its output, result bundle, and memory use before queueing more independent jobs.

Use `--sims 0` for builds or lint. Optionally provide `--memory-hint-mib` to estimate command memory at scheduling time; it does not enforce a limit. Without it, the scheduler uses 512 MiB minimum accounting plus current host checks. Limit the command's own parallel workers where supported. Concurrent builds need separate checkouts and build directories.

## Decide how much simulator state to reset

A warm simulator retains previous state. For a job that requires a clean app installation, add `--reset-app com.example.myapp` and have the command install the app. Use `--fresh-sim` when a full erase is required. These preparations happen before the command starts; see [reuse and readiness](TEMPLATE.md#reuse-and-readiness).

Pass required environment values explicitly with `--env NAME=value` or selected caller variables with `--env-from NAME`. Job commands inherit the daemon's environment, which can differ from your terminal. The [Actions guide](ACTIONS.md) demonstrates forwarding the chosen Xcode path.

## Optional project metadata

You do not need a project record to run a command. To store repository and Xcode metadata in the host config:

```sh
simq project add myapp --repo /path/to/MyApp \
  --container MyApp.xcworkspace --scheme MyApp
```

The command writes `projects.myapp` in `config.json`, preserving other settings. If omitted, container and shared scheme are detected from files when unambiguous; otherwise supply them explicitly. `--test-plan NAME` records a plan name, and `--replace` replaces an existing entry. Drain and restart the daemon to load configuration changes.

Project records store metadata for callers. They do not generate or run an Xcode command, and they do not change the host's active template. Continue passing the actual command to `run` or `submit`.

## Inspect and scale up

Use `simq jobs`, `simq explain J-0001`, and `simq logs J-0001` to inspect the first job. For a waiting job, `explain` distinguishes host resource holds, pool preparation, and queue controls. See [common waiting reasons](INSTALL.md#waiting-and-recovery).

Once the first job works, submit additional independent jobs from separate terminals or CI jobs. The shared queue admits them gradually when the Mac has room. See [scheduling and capacity](ARCHITECTURE.md#admission-and-capacity) for limits and [artifacts](PROOF-JOBS.md) for evidence retention.
