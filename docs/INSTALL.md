# Install, maintain and remove SimQueue

Homebrew installs `simq` and its daemon, `simqd`. Start with on-demand startup, select one host template, then run your project's complete test command through the queue.

## Install a published build

Use an Apple Silicon Mac, Homebrew, and Xcode with an installed iOS Simulator runtime. Complete Xcode's first-launch setup and select the intended Xcode with `xcode-select`. The formula requires Apple Silicon and macOS 14 or later; select an Xcode version supported by your macOS installation.

Validation environments:

| Architecture | macOS | Toolchain/runtime | Coverage |
| --- | --- | --- | --- |
| Apple Silicon | 26.6.2 | Xcode 27.0, iOS 27.0 | Real simulator UI suites, parallel jobs and lifecycle tests |
| Apple Silicon | 27.0.1 | Swift 6.4, hosted Xcode 27 image | Executable builds and the full fake-backed test suite |

The formula's macOS 14 minimum is a packaging requirement. The table records the environments exercised; it does not establish runtime validation on every older macOS/Xcode combination. Intel Macs are unsupported.

```sh
brew install jayhickey/tap/simqueue
simq --version
simq init
```

### Optional menu bar app

CLI-only users can keep using the formula above. To add `SimQueue.app` in
`/Applications`, install the optional cask:

```sh
brew install --cask jayhickey/tap/simqueue-app
```

The cask also installs the CLI formula if it is missing. Launch the app through
Spotlight or Applications; Launch at Login is opt-in. Installation does not start
or restart the daemon. Configure it with `simq init` and the steps below first.
App shutdown controls require daemon v0.1.4 or later; existing installations should
follow the planned upgrade procedure. App installation, upgrades, uninstall and
migration from a manually copied app are covered in the [menu bar guide](MENU_BAR.md).
Uninstalling only the cask leaves the CLI, daemon and queue data intact.

The public formula downloads the tagged release archive without GitHub authentication. Homebrew is the supported installation path; changing Gatekeeper/quarantine settings is not part of installation.

`simq init` checks Xcode and writes `~/Library/Application Support/SimQueue/config.json`. It keeps an existing config; `--force` replaces it. Missing simslim is only a warning: stock templates work without it.

The starter config operates owned pool simulators with `pool.mode: active`, boots on demand, and leaves orphan cleanup in `cleanup_mode: report-only`. These controls are separate. Set `cleanup_mode: enforce` when you want verified orphan cleanup and artifact retention to take action. See [config.example.json](config.example.json).

## Select the host template

```sh
simq template build host
simq template list
```

Building does not select the result. Copy the ready template's UDID into `simctl.template` in the existing config, then drain and restart using the method below. All projects share this selected template/device/runtime. [Template setup](TEMPLATE.md) covers selection, replacement and warm reuse; [onboarding](ONBOARDING.md) walks through the first job.

## Offline docs and coding agents

`simq agent-guide` prints version-matched operational instructions without starting a
daemon or creating state. `simq docs` prints the installed full documentation root;
open its `README.md` for relative links to all guides. Homebrew places these files under
its `share/doc/simqueue` tree, alongside the optional `skills/simqueue/SKILL.md`.

Agents can read `simq agent-guide` directly. To add the optional skill, choose the
skills directory documented by your agent and copy it explicitly. For example:

```sh
simqueue_docs="$(simq docs)"
agent_skills_dir="$HOME/.agents/skills"  # replace for your chosen agent
mkdir -p "$agent_skills_dir"
test ! -e "$agent_skills_dir/simqueue"
cp -R "$simqueue_docs/skills/simqueue" "$agent_skills_dir/simqueue"
```

An existing target makes this example stop; review it before replacing a skill. The
package never auto-installs skills into an agent directory. The skill is a discovery
pointer to the installed binary guide, which remains the authority for version-specific
flags and behavior. [MCP integration](MCP.md) is an alternative interface.

A project can provide this short `AGENTS.md` instruction:

```text
Use SimQueue for builds and simulator tests on this Mac.
Read simq agent-guide before submitting work.
```

## Choose one daemon manager

**On demand (default):** the first `simq` command that needs the daemon starts it. To apply config changes, run `simq drain --timeout 30m`, inspect `simq status`, then send SIGTERM to that daemon's displayed PID (`kill -TERM PID`, replacing `PID`). Wait for it to stop before running `simq status` to start the configured version. `SIMQ_NO_AUTOSTART=1 simq status` checks availability without starting a replacement.

**Homebrew login service:** drain and stop the on-demand daemon first, set `"autostart": false` in config, then:

```sh
brew services start simqueue
simq status
simq doctor
```

Use `brew services restart simqueue` for this mode's restarts and `brew services stop simqueue` to stop it. Keep auto-start disabled so clients cannot start a competing daemon. The service runs as the current user after login, not as a root service.

Persistent output uses the internal rotating `simqd.log` writer, four 5 MiB segments. Foreground terminal output stays under the caller's control. `simq init --launchd` is a separate advanced LaunchAgent option; Homebrew users should use `brew services` rather than combining managers.

## Planned upgrade

1. Keep the old version installed while running `simq drain --timeout 30m`. Continue only after **“Drained; safe to restart simqd.”** Running commands finish; queued/new work waits. A timeout exits 7 and leaves the gate set. Inspect the remaining work, retry, or cancel the planned restart with `simq resume`.
2. Make a consistent backup. The simplest method is to stop the drained daemon using its chosen manager, then copy the **entire** state directory, including SQLite sidecars. For a running drained daemon, use the advanced backup below.
3. Run `brew upgrade simqueue`.
4. Start the selected manager: `brew services start simqueue`, or `simq status` for on-demand startup.
5. Check `simq --version`, `simq status` and `simq doctor`. Restart clears the maintenance drain and resumes queued work.

Stop-and-copy example, **only after the drained daemon has stopped**:

```sh
simqueue_state="$HOME/Library/Application Support/SimQueue"
simqueue_backup="$HOME/SimQueue-backup-$(date +%Y%m%d-%H%M%S)"
ditto "$simqueue_state" "$simqueue_backup"
```

Protect the backup like the original state. Waiting clients recover unanswered observations or reconnect to the same job for up to 30 seconds after a transport interruption. A longer backup/download can exhaust that client budget while the job remains queued; inspect `simq jobs` and reattach with `simq wait JOB_ID` instead of submitting a duplicate. Prepare large backups/downloads before the short handoff when possible. Reconnect cannot preserve arbitrary running commands across an abrupt restart.

Before upgrading an older installation to v1:

- Update caller scripts from `--memory-mib` to `--memory-hint-mib` if they use the old spelling. The hint is optional and does not reserve RAM or enforce a limit; ordinary jobs can omit it.
- Finish/cancel legacy shard groups with the previous version. The new daemon refuses unfinished groups before migration/recovery; sharding commands are removed.
- Remove `drift`/`alerts`, per-project `template`/`golden`, `quiet`/`both` readiness and `quiet_window_seconds`, and `pool.prewarm_on_release`. The config loader reports those settings; healthy simulators now return warm automatically.
- Select one explicit host template. Reset a pool with a different or unknown clone source using the previous version before upgrading. Follow [template changes](TEMPLATE.md#change-the-active-template).

### Advanced: back up while the drained daemon stays available

SQLite's online backup API captures committed WAL contents. Never copy only a live database or copy its database and WAL independently. A complete backup image can retain a WAL-format header; normalize **the backup target only** to DELETE journal mode before closing it for offline/read-only validation. Never edit the source header or remove live sidecars.

Run this after a successful drain, avoiding concurrent config/retention changes:

```sh
python3 - <<'PY'
from datetime import datetime
from pathlib import Path
import shutil, sqlite3

state = Path.home() / "Library/Application Support/SimQueue"
backup = Path.home() / ("SimQueue-backup-" + datetime.now().strftime("%Y%m%d-%H%M%S"))
shutil.copytree(state, backup, ignore=shutil.ignore_patterns(
    "simqueue.sqlite", "simqueue.sqlite-*", "simq.sock", "simqd.lock"))
source = sqlite3.connect((state / "simqueue.sqlite").as_uri() + "?mode=ro", uri=True)
target = sqlite3.connect(backup / "simqueue.sqlite")
try:
    source.backup(target)
    target.execute("PRAGMA journal_mode=DELETE").fetchall()
finally:
    target.close()
    source.close()
print(backup)
PY
```

Then upgrade Homebrew while the old daemon remains drained and available, followed by a short stop/start. Keep the backup's config, ownership metadata and artifacts with its database.

### Recover a failed upgrade

Stop the new service and preserve its state for diagnosis. Restore the known previous binary/formula version **and its matching pre-upgrade state backup** before starting it. An older binary can refuse a newer schema; never lower `user_version` or assume an in-place downgrade is safe. Keep failed state separate instead of mixing backup files. Review command side effects before resubmitting interrupted work: retries do not undo external effects.

## Waiting and recovery

Inspect `simq status`, `simq explain JOB_ID`, `simq logs JOB_ID` and `simq doctor`.

| Reason | Next step |
| --- | --- |
| No selected template or incompatible clones | Select a ready template; reset the old pool before changing the contract. |
| Pool warming/readiness | Allow bounded clone/boot/settle work to finish; inspect failures and daemon logs. |
| Memory, swap growth, load or thermal gate | Reduce work or wait for recovery. Stable historical swap alone does not stop admission. Explicit load limits remain binding. |
| Drain or pause | Inspect work, then deliberately `simq resume`. |
| Version mismatch | Align CLI/daemon versions and restart the chosen manager. |
| Unknown process ownership or pending cleanup | Follow `simq doctor`; resources stay held until cleanup is proven. Do not discard the ledger to bypass it. |

For disk pressure, inspect artifacts, rotating logs and history archives. `simq gc` previews retention candidates; `simq gc --apply` requires cleanup enforcement. Keep needed artifacts elsewhere before unpinning them. At the 256 MiB live-database submission guard, inspect retention/pins and verify archival before resuming. Back up a drained database before compaction; deleting live SQLite/WAL files is not cleanup.

## Uninstall

```sh
simq drain --timeout 30m
brew services stop simqueue   # only when this is the chosen manager
simq uninstall               # inspect the plan
simq uninstall --yes
brew uninstall simqueue
```

Uninstall stops an on-demand daemon itself. It refuses active work, held leases and pending process/host cleanup. Report-only cleanup keeps owned simulators. After inspecting the plan, `--force` permits owned-simulator deletion despite that mode/rate limits and allows queued work to remain in the database. It never overrides active work, leases, ownership checks or pending cleanup.

Templates, config, queue history and artifacts remain by default. `--purge` also removes state and queued/history data; take a backup first. Purge refuses to discard ownership when cleanup kept/rate-limited simulators; review and explicitly force their cleanup first. Unrelated simulators remain outside the ownership boundary.

### Simulator boot memory estimate

The optional `host.sim_boot_cost_mib` config key overrides the memory allowance per simulator that must boot, for both job admission and pool warmup. For example, `"host": {"sim_boot_cost_mib": 1024}` budgets 1 GiB per boot. Merge this into your existing config; drain and restart the daemon using the procedure above to apply it.

Omitting the key preserves the default 3 GiB (3,221,225,472 bytes). Valid values are integers from 0 to 16,777,216 MiB; zero disables this allowance. Slimmed templates do not automatically change the estimate. Measure your template before reducing it. This estimate is added to job memory accounting alongside the host reserve, is not a memory limit, and does not apply to already-running idle simulators.

The default host memory reserve is 10% of total RAM with a 1 GiB minimum. For example, a 16 GiB Mac keeps about 1.6 GiB of reserve. `host.min_reserve_mib` overrides the minimum; `host.reserve_mib` sets a fixed reserve instead of the percentage. Existing explicit settings are preserved.
