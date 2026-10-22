# GitHub Actions

Use SimQueue on a self-hosted Mac runner to coordinate independent builds and test jobs sharing that Mac. Each job submits its complete command to the local daemon. The runner must use the daemon's user account and have access to its Unix socket.

Complete [installation and template selection](INSTALL.md) first. Start the chosen service before accepting workflows. The example sets `SIMQ_NO_AUTOSTART=1` so a missing service produces a useful failure instead of starting a daemon with an unexpected CI environment. Clients retry a missing daemon for up to 10 minutes to ride out a restart; set `SIMQ_RECONNECT_SECONDS` to fail sooner. Only trusted workflows should use this runner: their commands execute as its user. Keep untrusted public pull requests on disposable GitHub-hosted runners. The SimQueue public repository itself does not accept jobs on personal self-hosted Macs.

## Run a test suite

Add this step to a job running on your Mac runner. Replace the workspace and scheme with yours:

```yaml
- name: Test through SimQueue
  timeout-minutes: 65
  env:
    SIMQ_NO_AUTOSTART: "1"
  run: |
    export DEVELOPER_DIR="$(xcode-select -p)"
    exec simq run --project "${GITHUB_REPOSITORY##*/}" \
      --cwd "$GITHUB_WORKSPACE" --sims 1 --memory-hint-mib 2048 \
      --timeout 30m --queue-timeout 30m \
      --env CI=true --env-from DEVELOPER_DIR \
      --result-file "$RUNNER_TEMP/simq-result.json" -- \
      /bin/sh -c 'xcodebuild test \
        -workspace App.xcworkspace -scheme App \
        -destination "id=$SIMQ_UDID" -parallel-testing-enabled NO \
        -maximum-concurrent-test-simulator-destinations 1 \
        -derivedDataPath "$SIMQ_DERIVED_DATA" \
        -resultBundlePath "$SIMQ_RESULT_BUNDLE"'
```

Keep Xcode's simulator test parallelism disabled so each job uses its single leased simulator. Independent SimQueue jobs provide concurrency.

The queued shell expands `SIMQ_UDID` and the per-job build paths after the daemon supplies them. `--memory-hint-mib` is an optional scheduling estimate, not an enforced memory limit or RAM reservation. Omission uses 512 MiB minimum accounting alongside live host checks; a realistic estimate helps with large builds. Exceeding the hint does not terminate the command. The workflow timeout covers queue time, execution, and cancellation cleanup, so leave a margin beyond the two SimQueue timeouts.

SimQueue can run independent jobs together when resources allow. Keep those jobs in separate checkouts. Using the same checkout or build directory concurrently can still cause conflicts inside your tools.

## Run builds and lint

Use `--sims 0` for work that needs no simulator and bound the tool's own worker count:

```sh
simq run --project "${GITHUB_REPOSITORY##*/}" --sims 0 \
  --cwd "$GITHUB_WORKSPACE" --memory-hint-mib 4096 \
  --timeout 20m --queue-timeout 30m -- swift build -j 4
```

A simulator waiter can leave room for a fitting simulator-free job. `--kind build` or `--kind lint` adds a display label; scheduling comes from resource requirements and priority.

## Results and cancellation

`simq run` streams command output and normally returns the command's own exit status. On workflow cancellation, it requests cancellation and waits for command cleanup. Keep the waiting client in the workflow's foreground so it receives cancellation signals.

`--result-file` writes the final job record, including `state`, `result_class`, `command_exit_code`, `run_dir`, and available artifacts. Preserve that JSON along with relevant logs and result bundles using your workflow's artifact-upload steps. Use `--exit-code mapped` when you want SimQueue's stable failure categories; see [exit codes](PROTOCOL.md#exit-codes). If the runner itself disappears, inspect the job through `simq jobs` or `simq explain` before resubmitting it.

## Environment and checkout assertions

Commands inherit the daemon's environment. Forward required caller variables individually with `--env-from NAME`, or provide explicit `--env NAME=value` values. The test example forwards the selected Xcode path and sets `CI=true`. A missing `--env-from` variable fails before submission; `SIMQ_*` names are reserved.

For an explicit commit assertion, use `submit`:

```sh
simq submit --project "${GITHUB_REPOSITORY##*/}" --sims 0 \
  --cwd "$GITHUB_WORKSPACE" --worktree "$GITHUB_WORKSPACE" \
  --git-sha "$GITHUB_SHA" --memory-hint-mib 4096 --timeout 20m \
  --wait -- swift build -j 4
```

HEAD is checked at submission and execution; files are not frozen. See [checkout assertions](PROTOCOL.md#working-directory-and-checkout-assertions) and the [artifact guide](PROOF-JOBS.md).

## Runner maintenance

Follow the [drain and Homebrew upgrade procedure](INSTALL.md#planned-upgrade). Waiting clients can reconnect to the same queued job across a brief service restart. Abruptly interrupted commands need deliberate recovery, and replay requires explicit retry permission. See [recovery](PROTOCOL.md#recovery) before enabling retries.
