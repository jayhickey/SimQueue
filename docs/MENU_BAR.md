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

# Or the app, which links its own bundled simq (uninstall the formula first)
brew install --cask jayhickey/tap/simqueue-app
```

The formula installs only the command-line tools and documentation. The cask
installs `SimQueue.app` into `/Applications` (or the folder given by `--appdir`, for
example `--appdir=~/Applications`; keep the same one for every reinstall and upgrade)
and links `simq` from `SimQueue.app/Contents/Helpers/simq`, so Sparkle updates the
CLI with the app. The two setups conflict over `simq`; see
[switching](INSTALL.md#switching-between-the-formula-and-the-cask) if both ended up
installed. Launch the app through Spotlight or
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

The cask's `simq` is inside the app, so it upgrades with the app; there is no
separate CLI package to upgrade. `brew uninstall --cask simqueue-app` removes the
app and its `simq` link, leaving no `simq` on `PATH`; the simulator pool and queue
data stay intact. The cask has no shared-data cleanup hooks. Disable Launch at Login
and stop the bundled daemon (see [switching back](#updates-and-switching-back))
before uninstalling it.

If you previously copied a development app into `/Applications` or
`~/Applications`, quit it and move it aside before installing the cask. Homebrew
will not overwrite an existing unmanaged app automatically. Avoid keeping two
copies of the companion app installed.

Starting with v0.1.4, the release archive also contains `SimQueue.app` alongside
the CLI tools for manual installation. Local builds and older release archives use ad-hoc signing. The release pipeline
now requires Developer ID signing, Apple notarization, and a stapled app ticket
for new tagged builds. Check the release notes for the actual validation of a
particular download; do not disable Gatekeeper or remove quarantine attributes.

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
The dashboard connects to the default state directory, or `SIMQ_STATE_DIR` when
launched with that environment. The optional bundled background service uses only
the default state directory. A custom-state app can still monitor an externally
managed daemon, but cannot register the bundled service.

## Use the daemon bundled with the app

The app contains `Contents/Helpers/simqd` and a per-user background agent managed
by macOS Service Management (`dev.simqueue.app-daemon`). The executable keeps the
same location across updates when the app stays in the same Applications folder.
The helper has its own stable code-signing identifier. This improves identity
continuity; permission persistence across macOS versions and future updates still
needs live verification. A first external-drive permission request may still occur.
Full Disk Access is not required for this installation.

Install the app in `/Applications` or `~/Applications` before enabling the service,
and keep it in that folder for reinstalls and upgrades.
Right-click the menu bar icon and choose **Use Bundled Daemon…**. If macOS asks for
approval, enable it under **System Settings → General → Login Items & Extensions**;
the app's **Background Service Settings…** command opens that page. The service
continues running after **Quit Menu Bar App**, including without the menu bar app
at login. Launch at Login controls only the menu bar app.

### Migrate from Homebrew's daemon service

The app's own `simq` connects to the same socket and queue. Coming from the
formula, keep it installed until its service is stopped (step 4), then switch to the
cask (step 5). Only one manager should run the daemon. The app refuses to take over a responding
foreign daemon, a held daemon lock, or an installed legacy LaunchAgent.

1. Run `simq drain --timeout 30m` and wait for **Drained; safe to restart simqd.**
2. Take a consistent backup following [planned upgrades](INSTALL.md#planned-upgrade).
3. Keep `"autostart": false` in the existing config. Do not replace other settings.
4. Run `brew services stop jayhickey/tap/simqueue`. For `simq init --launchd`, unload
   its `dev.simqueue.simqd` agent and move that plist aside. For an on-demand daemon,
   stop the exact drained PID. Check that the old daemon has exited before continuing.
5. Run `brew uninstall simqueue`, then `brew install --cask jayhickey/tap/simqueue-app`.
   If the cask was already installed, restore its `simq` link as described in
   [switching](INSTALL.md#switching-between-the-formula-and-the-cask).
6. If an old SimQueue LaunchAgent plist remains in `~/Library/LaunchAgents`, move it
   into your backup rather than leaving it to restart at next login. The app checks
   `sh.brew.simqueue`, `homebrew.mxcl.simqueue`, and `dev.simqueue.simqd`.
7. Choose **Use Bundled Daemon…**, approve background activity if required, and
   verify `simq status` and `simq doctor`. The new daemon reopens queue admission.

For scripted registration after those same migration checks, run the installed
app executable with `--register-daemon`; it performs the same configuration,
location, manager and lock checks. This command does not grant macOS permissions. For scripted app upgrades,
`--stop-bundled-daemon` performs the same epoch/PID-checked finish-and-unregister
handoff, waiting up to 30 minutes without canceling jobs. It refuses foreign
daemons. After installing the new app at the same path, register it again.

### Updates and switching back

Quit the menu bar app before `brew upgrade --cask jayhickey/tap/simqueue-app`, then
relaunch it and choose **Use Bundled Daemon…** again. This drains the app-managed
queue, waits for running work and owned cleanup, and restarts the service using
the updated bundled daemon. It never cancels active jobs for an update. Keep the
app at its original path: use the same `--appdir` for every upgrade. Upgrading or restarting a service does not prove that
macOS retained external-drive permission; verify access after each update.

The app's `simq` upgrades with the app. Don't install the formula alongside the
cask: it takes over the `simq` link. Do not run `brew services start/restart
simqueue` while the bundled agent is enabled.

### Sparkle updates

The menu has **Check for Updates…** and **Automatically Check for Updates**.
Automatic checks default to on; installations require the user's confirmation.
The app uses Sparkle 2.10.0 to download and verify updates from the stable GitHub
release feed. Every update ZIP contains only the signed, notarized app with its
matching bundled daemon. Archives use a separate Ed25519 signature checked against
the public key embedded in the app. System-profile reporting defaults to off.

When Sparkle asks the app to quit for an installation (including install-on-quit),
the app drains its own daemon, waits up to 30 minutes for active work and cleanup,
then unregisters the matching service before allowing replacement. The relaunched
app registers the new bundled daemon at the same path and reopens admission. An update canceled while waiting resumes admission before the final stop
acknowledgement; if the service already stopped, the old app starts it again.
Existing paused/draining maintenance must finish before starting an update. A
failed handoff cancels termination and reports an error; a timeout leaves the queue
drained. Inspect `simq status` before resuming or retrying. Never force-quit the app
to bypass a waiting update. A CLI-managed daemon is left running when only its
companion app updates.

The Homebrew app cask is marked `auto_updates true`, following Xcodes' packaging
model. Sparkle manages app updates; Homebrew normally skips self-updating casks
unless explicitly requested with `--greedy`. The cask's `simq` is the app's own, so
it updates with the app. Don't keep the formula installed as well: its `simq` takes
over the link and can lag the app's daemon. CLI-only users do not need Sparkle or the app.

The first Sparkle-enabled release must be installed using Homebrew or its direct
app download. Earlier versions cannot update themselves through Sparkle. Before
that release is published, the production appcast URL may return 404. A local or
fake signing test does not establish that a public two-version update has run.

Before uninstalling the cask or switching back, use **Stop SimQueue… → Finish Jobs
and Quit**. That unregisters the app-owned agent after drain completion. To go
back to the CLI-only setup, run `brew uninstall --cask simqueue-app`, then
`brew install jayhickey/tap/simqueue`, then start your chosen CLI daemon manager. App uninstall still preserves queue data;
uninstalling a registered app without stopping its service first is unsupported.

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

For the bundled app agent, the app matches its service PID, seals admission, and
unregisters it through Service Management. For the standard Homebrew or
`simq init --launchd` user service, the app matches
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

## Dashboard listen settings

Right-click the menu bar icon and choose **Dashboard Settings…**. Set a numeric
IPv4 listen address and a port (0 chooses an available port). Values persist in
the app’s preferences across launches and app updates. Defaults are `127.0.0.1`
and port `0`. Saved non-default settings start the listener when the app launches,
without opening a browser. Use this Mac’s Tailscale or LAN IP for a proxy on another machine;
`0.0.0.0` listens on all IPv4 interfaces. Share the private URL only with trusted
users and restrict who can reach a network listener.

Applying opens the dashboard with a new private URL and restarts only its HTTP
listener; the daemon and jobs continue. A failed bind leaves preferences unchanged
and attempts to restore the previous listener. Reopen the dashboard after a failed
change because its private path may have changed. These preferences apply to the
menu bar app’s own dashboard; separately launched `simq dashboard` processes and
launch agents continue to use their command-line flags.
