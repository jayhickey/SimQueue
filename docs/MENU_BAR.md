# macOS menu bar app

SimQueue.app is an optional macOS 14+ companion to the existing daemon. Its
`square.stack` SF Symbol shows running/queued counts. Click it to open the local
browser dashboard; right-click for the menu. The dashboard retains its private,
per-session loopback URL, job cancellation and queued-job priority controls.

## Install a published version

Choose either installation:

```sh
# CLI and daemon only
brew install jayhickey/tap/simqueue

# Optional app, with the CLI formula installed as a dependency if missing
brew install --cask jayhickey/tap/simqueue-app
```

The formula installs only the command-line tools and documentation. The cask
installs `SimQueue.app` into `/Applications`; launch it through Spotlight or
Applications. Launch at Login is opt-in. The app uses your existing daemon;
installing it does not start or restart services or change host configuration.
New users still need `simq init` and the setup steps in [INSTALL.md](INSTALL.md).

Keep the app and CLI/daemon on matching releases when available. An already
running older daemon is not replaced by installing the cask: follow the
[planned upgrade](INSTALL.md#planned-upgrade) before using app shutdown controls,
which require daemon v0.1.4 or later. Quit the app before upgrading it:

```sh
brew upgrade --cask simqueue-app
```

Upgrade the CLI separately with `brew upgrade simqueue` using the planned daemon
upgrade procedure. `brew uninstall --cask simqueue-app` removes the app but leaves
the CLI, daemon, simulator pool and queue data intact. The cask has no shared-data
cleanup hooks. Disable Launch at Login in the app before uninstalling it.

If you previously copied a development app into `/Applications` or
`~/Applications`, quit it and move it aside before installing the cask. Homebrew
will not overwrite an existing unmanaged app automatically. Avoid keeping two
copies of the companion app installed.

Starting with v0.1.4, the release archive also contains `SimQueue.app` alongside
the CLI tools for manual installation. The app is ad-hoc signed, not notarized;
follow macOS security policy rather than disabling Gatekeeper or removing
quarantine attributes.

## Build and install

On a shared SimQueue host, build through the queue with bounded workers:

```sh
simq run --project SimQueue --sims 0 --timeout 20m -- swift build -j 2
scripts/package-app.sh .build/debug /tmp/simqueue-app
open /tmp/simqueue-app/SimQueue.app
```

The packaging script creates an ad-hoc signed app, suitable for local development.
Copy it to `/Applications` before enabling **Launch at Login**.
Public archives and the optional cask include the same app bundle.
Install/configure SimQueue first (see [INSTALL.md](INSTALL.md)).
The app connects to the default state directory, or `SIMQ_STATE_DIR` when launched
with that environment. It does not replace the daemon, reconfigure its service,
or launch a second daemon. Start the installed daemon using `simq status` or your
existing login service before opening the dashboard.

## Quit and stop

- **Quit Menu Bar App** exits the app and its dashboard server. The daemon and jobs
  continue. Browser tabs remain open but their old dashboard URL stops responding.
- **Stop SimQueue… → Finish Jobs and Quit** gates new starts, waits for active jobs
  and owned cleanup to finish, stops the daemon, then exits the app.
- **Stop SimQueue… → Cancel Active Jobs and Quit** sets that same gate, requests
  cancellation only for admitted/running jobs, waits for ownership-safe cleanup,
  stops the daemon, then exits the app. Queued jobs remain saved in both modes.

While stopping, the menu bar says “Stopping”. Quitting just the app during this
wait leaves the daemon draining and does not complete the pending stop. It may wait indefinitely when a
job or cleanup cannot finish safely; it never kills unrelated processes or
bypasses cleanup. Errors stay visible and do not silently retry mutations.
If stopping is interrupted before its final acknowledgement, inspect `simq status`
and use `simq resume` to reopen admission when appropriate. After a final stop
acknowledgement, admissions are sealed: if service unloading failed, restart the
daemon through its service manager rather than resuming it.

For the standard Homebrew or `simq init --launchd` user service, the app matches
the service's PID against the connected daemon, seals its admission gate, then
unloads that exact service with `launchctl bootout`. This prevents KeepAlive from
restarting it immediately. Other service managers are not supported: stop those
through their own manager. Launch at Login controls only the companion app.
After stopping a standard login service, restart it with `brew services start simqueue`
or `simq init --launchd`, respectively. For an on-demand daemon, `simq status`
starts it again when autostart is enabled. Queued work can then resume.

The additive `stop` protocol requires a matching daemon epoch and a completed
drain, including all leases, process groups and pending cleanup. Older daemons
reject it without being signaled; upgrade the CLI/daemon before using app shutdown.
