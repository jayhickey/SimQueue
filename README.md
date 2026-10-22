# SimQueue

**A local job queue and reusable iOS Simulator pool for your Mac.**

SimQueue coordinates builds, tests, and other commands sharing an Apple Silicon Mac. Submit work from your terminal, CI workflows, or coding agents, and it runs independent jobs together as host resources become available. Each test job runs its complete suite on its leased simulator.

If you use a Mac mini as a shared build machine, SimQueue gives all of those callers one place to coordinate. You can queue the next batch of work, see why a job is waiting, and reuse booted simulators between runs.

- **Use the Mac's available capacity.** Admission responds to current memory pressure, CPU load, swap growth, thermal state, disk space, and simulator availability. Builds and lint can run without a simulator.
- **Share a simulator pool.** Select one host template, then let SimQueue create, boot, lease, and reuse its clones. Request an app reset or a fresh simulator when your job needs it.
- **Keep your existing commands.** Wrap `xcodebuild`, a shell script, or another command with `simq run`. Output streams to your terminal, and the command's exit status reaches CI.
- **Manage work in one place.** Inspect the queue, explain a resource hold, cancel a job, retrieve logs and artifacts, or drain running work before maintenance.

SimQueue runs locally on one Mac. It executes trusted commands as the daemon's user; project names label jobs within the shared queue and pool.

## Get started

```sh
brew install jayhickey/tap/simqueue
simq init
simq template build host
```

Select the template UDID returned by the last command in `~/Library/Application Support/SimQueue/config.json`, then restart the daemon as described in the [installation guide](docs/INSTALL.md). Template creation and selection are separate steps; the guide also explains Xcode prerequisites and service setup.

From your project checkout, run a complete test suite on one simulator:

```sh
simq run --project app --sims 1 --timeout 30m -- \
  /bin/sh -c 'xcodebuild test -workspace App.xcworkspace -scheme App \
    -destination "id=$SIMQ_UDID" -parallel-testing-enabled NO \
    -maximum-concurrent-test-simulator-destinations 1 -derivedDataPath "$SIMQ_DERIVED_DATA" \
    -resultBundlePath "$SIMQ_RESULT_BUNDLE"'
```

Replace the workspace and scheme with yours. The single quotes let the queued shell expand the simulator and artifact paths supplied by SimQueue. `--memory-hint-mib` is optional: it tells the scheduler how much memory headroom to allow for the command. For example, `--memory-hint-mib 4096` requests roughly 4 GiB of headroom when scheduling. It **does not reserve RAM or enforce a memory limit**. A command can use more than its hint; host resource checks can then hold back additional starts.

Without a hint, SimQueue uses 512 MiB minimum accounting per command, alongside host resource checks and gradual admission. This is a fallback, not a measured estimate of your workload. A realistic hint can help schedule memory-heavy builds before their usage appears in host readings.

For slimmed simulators, you can tune the cold-boot memory allowance in the daemon config:

```json
{"host": {"sim_boot_cost_mib": 1024}}
```

Merge this into the existing config, then drain and restart the daemon as described in [installation](docs/INSTALL.md). The value is an integer in MiB per simulator that needs booting, including pool warmup. Omit it to keep the default 3 GiB (3,221,225,472 bytes); `0` disables this allowance. Already-running idle simulators do not incur it. Choose a value based on measurements of your template: this is a scheduling estimate, not a memory limit, and lowering it leaves less protection against memory pressure. Job estimates and the host reserve still apply.


For a command that needs no simulator:

```sh
simq run --project app --sims 0 --timeout 20m -- \
  swift build -j 4
```

Submit independent jobs from separate terminals or CI jobs to share the queue. Keep concurrent builds in separate checkouts and use bounded tool parallelism; SimQueue decides when a command starts, while the command controls its own workers.

## Use with coding agents

Run `simq agent-guide` for the installed version's concise operational instructions.
It works offline without starting the daemon. `simq docs` prints the installed full
documentation directory, including this README, the linked guides, and an optional
Agent Skill. See [offline docs and agents](docs/INSTALL.md#offline-docs-and-coding-agents)
for explicit skill installation; nothing is installed into agent directories automatically.

For a project's `AGENTS.md`, add:

```text
Use SimQueue for builds and simulator tests on this Mac.
Read simq agent-guide before submitting work.
```

## See what's happening

```sh
simq status                 # daemon, queue counts, and admission holds
simq jobs                   # job list
simq explain J-0001         # details and reasons a job is waiting
simq logs J-0001            # retained command output
simq cancel J-0001          # cancel queued or running work
simq doctor --json          # health and ownership diagnostics
```

For maintenance, `simq drain --timeout 30m` holds new starts and waits for running work and cleanup to finish. `simq resume` reopens admissions. Follow the [upgrade procedure](docs/INSTALL.md#planned-upgrade) before restarting a service.

## Choose the behavior your job needs

Warm simulators retain state from earlier jobs. Use `--reset-app your.bundle.id` to reset an app and keychain before execution, or `--fresh-sim` to erase the leased simulator. See [templates and reuse](docs/TEMPLATE.md).

Commands receive the daemon's environment. Forward selected caller variables with `--env-from NAME`, or set values with `--env NAME=value`. For automation, `--result-file result.json` records the result and artifact paths; `--exit-code mapped` distinguishes command failure from timeouts and infrastructure failures.

Waiting clients reconnect after a short service interruption. An abruptly interrupted command can have side effects: started commands require explicit retry permission to replay. See the [execution and recovery reference](docs/PROTOCOL.md#recovery) before enabling retries.

## Documentation

| I want to… | Guide |
| --- | --- |
| Install, configure a service, upgrade, or uninstall | [Installation](docs/INSTALL.md) |
| Choose a simulator template and control job state | [Templates and simulator reuse](docs/TEMPLATE.md) |
| Run jobs from GitHub Actions | [CI integration](docs/ACTIONS.md) |
| Look up flags, configuration, exit codes, and recovery | [CLI and protocol reference](docs/PROTOCOL.md) |
| Keep screenshots, videos, and result bundles | [Job artifacts](docs/PROOF-JOBS.md) |
| Connect an MCP client | [MCP integration](docs/MCP.md) |
| Understand scheduling, storage, and ownership | [Architecture](docs/ARCHITECTURE.md) |
| Build and publish a release | [Release process](docs/RELEASING.md) |

## Automated releases

Successful CI on `main` starts the release workflow for that exact commit. It
selects the next patch version, builds the ARM64 distribution, signs with
Developer ID, notarizes and staples the app, then creates the version tag and
GitHub Release. Credentials and all verification checks must succeed before
publication. See the [release guide](docs/RELEASING.md) for setup, retries and
nonpublishing validation runs.

## Contributing

Development requires Swift 6, SQLite headers, and the Xcode toolchain on macOS.

```sh
git clone https://github.com/jayhickey/SimQueue.git
cd SimQueue
swift build --build-tests -j 4
swift test --skip-build -j 4
```

Read [AGENTS.md](AGENTS.md) for contributor guidance and [backends](docs/BACKENDS.md) for fake-tool development.

Licensed under the [MIT License](LICENSE); see [NOTICE](NOTICE).

## Queue dashboard

Run `simq dashboard` for a live local browser view of the queue, recent
results, timings, waiting reasons, commands and bounded logs. Cancel jobs and
adjust queued-job priorities directly in the dashboard. See the
[dashboard guide](docs/DASHBOARD.md) for options, limits and privacy details.

### macOS menu bar app

Install the CLI and daemon with `brew install jayhickey/tap/simqueue`. Add the
optional app with `brew install --cask jayhickey/tap/simqueue-app`; the cask installs
it into `/Applications` and pulls in the CLI formula if missing.

The optional [SimQueue.app](docs/MENU_BAR.md) adds a `square.stack` menu bar item.
Click to open the dashboard; right-click for status, Launch at Login, and separate
options to quit the app or stop SimQueue after finishing/canceling active jobs.
Queued jobs stay saved. Release archives from v0.1.4 include the app. See the guide
for installation, local builds and service behavior.

Job output can use a dedicated [storage root](docs/JOB_STORAGE.md), and jobs can
select [named host templates](docs/TEMPLATE.md#named-host-templates) from one shared pool.

The default host memory reserve is 10% of total RAM with a 1 GiB minimum. For example, a 16 GiB Mac keeps about 1.6 GiB of reserve. `host.min_reserve_mib` overrides the minimum; `host.reserve_mib` sets a fixed reserve instead of the percentage. Existing explicit settings are preserved.
