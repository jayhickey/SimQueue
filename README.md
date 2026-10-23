# SimQueue

**A shared build queue and reusable iOS Simulator pool for parallel iOS development.**

SimQueue coordinates builds, tests, and other commands sharing an Apple Silicon Mac. Submit work from your terminal, CI workflows, or coding agents, and it runs independent jobs together as host resources become available. Each test job runs its complete suite on its leased simulator.

Separate worktrees keep code changes apart, but their builds and simulator tests still share the Mac's CPU, memory, and devices. SimQueue gives coding-agent swarms, developers, and CI workflows one place to coordinate that work. More agents can submit jobs while execution stays bounded by host capacity; waiting jobs do not each need a booted simulator.

Whether you develop on your own Mac or use a Mac mini as a shared build machine, you can queue the next batch of work, see why a job is waiting, and reuse booted simulators between runs.

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

SimQueue supports two installation setups. Pick one; they conflict:

- **CLI only:** `brew install jayhickey/tap/simqueue` installs `simq` and `simqd`, updated with `brew upgrade`.
- **Mac app:** `brew install --cask jayhickey/tap/simqueue-app` installs `SimQueue.app` and links
  `simq` from `SimQueue.app/Contents/Helpers/simq`. The app's Sparkle updates replace the CLI and its
  bundled daemon together, so they always match. Run `brew uninstall simqueue` before switching to it.

The app can run its own signed daemon from a stable path inside
`SimQueue.app`. See [bundled daemon setup and safe migration](docs/MENU_BAR.md#use-the-daemon-bundled-with-the-app).
The app includes Sparkle update checks and waits for jobs before updating its
bundled daemon.

## Use with coding-agent swarms

SimQueue's goal is to let large agent swarms share a bounded pool of build and simulator capacity. Agents work in separate checkouts and submit independent jobs to the same local queue. SimQueue starts jobs as resources become available and leases simulators for the jobs that need them. A larger swarm can have more work waiting without running every build or booting a simulator for every agent at once.

SimQueue coordinates the commands agents submit; your agent harness manages the agents and their code changes. Route every build and simulator test through the queue, use the supplied simulator and artifact paths, and bound each command's compiler workers. Host admission checks do not enforce a command's memory or worker limits.

The queue is bounded too: default backlog limits are 128 queued jobs per submitter/project and 1024 globally. Handle queue-full responses as backpressure instead of repeatedly resubmitting. These limits describe queue capacity, not a validated agent count or a promise of build throughput. See [admission and capacity](docs/ARCHITECTURE.md#admission-and-capacity) for scheduling details.

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

Development requires Swift 6, Node 22 for dashboard asset generation, SQLite headers, and the Xcode toolchain on macOS.

```sh
git clone https://github.com/jayhickey/SimQueue.git
cd SimQueue
npm --prefix Web/dashboard ci --no-audit --no-fund
npm --prefix Web/dashboard run build
swift build --build-tests -j 4
swift test --skip-build -j 4
```

Read [AGENTS.md](AGENTS.md) for contributor guidance and [backends](docs/BACKENDS.md) for fake-tool development.

Licensed under the [MIT License](LICENSE); see [NOTICE](NOTICE).

## Queue dashboard

Run `simq dashboard` for Runner vitals: CPU, memory, disk and thermal state,
warning chips, running/waiting job cards, recent results, activity and managed
storage. The responsive dashboard follows the system light/dark setting and
updates through the local API, with bounded trends labeled “this tab.” Cancel jobs and
adjust queued-job priorities directly in the dashboard. Open a job for live log
tailing, with pause/resume and auto-follow controls. See the
[dashboard guide](docs/DASHBOARD.md) for options, limits and privacy details.

The dashboard includes machine health (memory pressure, CPU/load, swap and volume
free space) and an on-demand storage breakdown with a preview of safe artifact
cleanup, including separate DerivedData, result-bundle and owned simulator/template
accounting. Configurable age and size retention preserves active work; disk-aware
admission pauses new work until required volumes recover. Existing retention and disk admission policies remain the source of truth.

### macOS menu bar app

Install the CLI and daemon with `brew install jayhickey/tap/simqueue`, or the app
setup with `brew install --cask jayhickey/tap/simqueue-app`. The cask installs the
app into `/Applications` (or the `--appdir` you pass) and links the app's own `simq`;
it does not install or need the formula. Use one setup: see
[switching between the formula and the cask](docs/INSTALL.md#switching-between-the-formula-and-the-cask).

The optional [SimQueue.app](docs/MENU_BAR.md) adds a `square.stack` menu bar item.
Click to open the dashboard; right-click for status, Launch at Login, and separate
options to quit the app or stop SimQueue after finishing/canceling active jobs.
Queued jobs stay saved. Release archives from v0.1.4 include the app. See the guide
for installation, local builds and service behavior.

Job output can use a dedicated [storage root](docs/JOB_STORAGE.md), and jobs can
select [named host templates](docs/TEMPLATE.md#named-host-templates) from one shared pool.

The default host memory reserve is 10% of total RAM with a 1 GiB minimum. For example, a 16 GiB Mac keeps about 1.6 GiB of reserve. `host.min_reserve_mib` overrides the minimum; `host.reserve_mib` sets a fixed reserve instead of the percentage. Existing explicit settings are preserved.

Stable releases also update the Homebrew CLI formula and optional app cask through a separate publishing job. Maintainers configure a tap-only credential as described in [releasing](docs/RELEASING.md#automatic-tap-credentials).
