# Local dashboard

Run `simq dashboard` to open a browser view. The foreground command prints
its private URL and serves until Ctrl-C. It uses an available port on `127.0.0.1`;
`--port 8765` selects a port, `--no-open` only prints the URL, and `--state-dir`
selects the daemon state directory. It does not start or replace the daemon. Start
or inspect your configured daemon with `simq status` if the view is disconnected.

The Runner vitals dashboard follows the system light/dark preference. Desktop
uses a job column and a supporting activity/storage/runner column; phone screens
stack cards without horizontally scrolling tables.

- A runner status sentence and warning chips show admission holds, low disk,
  memory pressure, health problems and recent failed jobs. Warning links open the
  relevant job or storage review. Runner status always describes the whole machine.
- Four cards show interval CPU utilization (separate from load average), available
  memory/pressure/swap, state-volume free space relative to the configured floor,
  and categorical thermal state. Missing readings display unavailable. Thermal
  state is not a temperature measurement.
- Small SVG trend lines labeled **this tab** retain at most 120 fresh samples per
  metric in memory. Duplicate samples are ignored and missing/disconnected periods
  leave gaps. They start with this tab, not daemon history, and are lost on reload.
- Running/preparing cards show elapsed time, wait/prep phases, priority and granted
  simulators. Waiting cards use the daemon's dispatch positions and explanations.
  No completion percentage is invented for arbitrary commands.
- Recent results show up to 12 rows initially, expandable to the available window.
  The API retains the last 100 terminal submissions; rows are ordered by completion
  within that window. Summary statistics apply to the displayed, filtered window.
  Pass rate includes successes and failures (including infrastructure, interruption
  and timeout), excludes canceled/expired jobs, and median execution uses only known
  valid start/end durations. Other outcomes remain separately counted.
- Search covers command, project, kind, submitter and ID, with project/state filters.
  The activity timeline shows execution overlap for up to 20 latest started jobs.
- Job details retain exact command argv, directories, commit, submitter, attempts,
  deadlines, simulator information, peak process-group memory and artifact paths.
  Artifacts are listed as paths, not served as files.

Labels combine the caller's project with its kind, falling back to the command
executable or job ID. No new naming or scheduling semantics are introduced.
Wait runs from submission to admission (or start on older daemons); prep runs
from admission to start; execution runs from start to completion. Missing phases
show a dash. Retries retain the original submission timestamp, so wait includes
prior attempts; prep, execution, simulator and memory details describe the latest
attempt. Snapshots make separate read requests and can briefly straddle a state
transition. The API bounds active jobs at 10,000; waiting cards render in batches
of 30. Runner counts can exceed the filtered/displayed list.

One shared snapshot poll runs three seconds after the previous request completes,
only while visible. Failures back off to at most 30 seconds. **Retry now** and
returning to the tab trigger a refresh without overlapping requests. On failure,
the last snapshot stays visible with a stale warning and disabled mutation controls;
timings freeze at that snapshot. Recovery requires no page reload. Job cards retain
DOM identity during updates, preserving normal scrolling and focus without scroll
restoration or touch-gesture hacks.

## Live run output

Open a job to see its live output. The viewer starts at the newest output and
refreshes a bounded 32 KiB window once per second, after each request completes.
It follows the bottom automatically. **Pause live output** freezes the view;
scrolling up pauses it too. **Resume live output** or **Jump to latest** resumes
following the newest output. Output emitted while paused may fall outside the
window; use `simq logs JOB` for the complete retained log.

The viewer stops polling when the daemon confirms both job completion and the
end of output, including executor cleanup. Empty output is shown explicitly.
A disconnect preserves the displayed text with a stale-output warning and retries.
Closing or switching job details discards late responses. Hidden tabs do not fetch
logs. Refreshing job metadata preserves the output panel and its paused state.
The bounded tail also handles a log file being shortened or replaced.

Live tailing requires an updated daemon that supports `tail_bytes`; older daemons
show an upgrade message instead of labeling the start of a log as its tail.
Follow the planned upgrade procedure before restarting a shared daemon.

Recent activity names wrap instead of truncating. Hovering also shows the full
name, and clicking opens the same job details and output.

Activity uses a shared time axis with light-blue queue wait, amber preparation, and
green command execution. A failed command's execution stays green because the
bar represents a phase; its outcome is shown separately. Hovering a desktop row or
focusing it with the keyboard reveals the phase durations. Clicking it opens job
details with the same durations first, followed by live output; exact commands,
paths, scheduling fields and artifacts remain in a collapsible technical section.
Queued and preparing jobs appear even before execution begins. Missing or
inconsistent timestamps remain unavailable rather than becoming zero-length runs.
The first attempt is numbered zero. On retries, the original submission timestamp
cannot establish actual queue wait, so queue wait is explicitly unavailable and
its bar is omitted; preparation and runtime describe the latest attempt. Older
daemons without admission timestamps show combined before-start time with a note.

## Job controls

Cancel waiting, preparing or running jobs using **Cancel**. The browser asks for
confirmation, then uses the daemon's existing cancellation and ownership-safe
cleanup. Cancellation acceptance does not mean cleanup has already finished.

Queued jobs also have **↑** and **↓** buttons to change base priority by 10 and a
**P…** button to enter an exact integer from 0 to 100. Higher runs first;
aging and host resource gates still apply. This does not preempt running jobs or
bypass admission holds. Once a job is admitted its priority cannot change. Races
with admission/completion return an error and the next snapshot updates the view.
The equivalent CLI is `simq bump JOB_ID PRIORITY`.

Mutations are sent once. A lost response is reported as unconfirmed; inspect the
refreshed job state before retrying. Priority changes require the updated daemon;
upgrade/restart the daemon along with the CLI.

The listener defaults to loopback with a persistent capability in its URL,
one valid Host header, no CORS, no external assets, and narrow API routes. Mutations require POST, an HTTP(S) Origin matching the request Host, and an
explicit action header; cross-origin requests have no CORS permission. Keep
the URL private: it permits controlling jobs and viewing commands and logs, which may contain secrets.
Other processes/users on the same host are not a security isolation boundary.
There are no retry, drain or arbitrary file/command endpoints.
No runtime web dependencies or separate asset installation are required.

## Menu bar access

The optional [macOS menu bar app](MENU_BAR.md) opens this dashboard on click and
adds status counts, Launch at Login, and safe daemon stop options.

## Private access through Tailscale Serve

The listener stays on loopback, but accepts reverse-proxied hostnames. To expose it
only within your tailnet, keep this command running:

```sh
simq dashboard --port 8765 --no-open
```

In another terminal, configure Tailscale Serve (not public Funnel):

```sh
tailscale serve --bg --https=8765 http://127.0.0.1:8765
```

Use the HTTPS hostname and port printed by Tailscale, followed by the entire private
path printed by SimQueue. Retain the trailing slash. Both devices must have
Tailscale connected and the tailnet policy must permit access. Follow Tailscale's
HTTPS setup prompt if needed. An extra rewriting proxy is not required.
The Serve configuration persists, but the dashboard process must remain running;
restarting it reuses the saved private path. Share the link only with trusted users:
it grants access to logs and job controls. This does not configure Tailscale or
change existing Serve routes automatically.

## Install as a web app

Open the complete private dashboard link over Tailscale HTTPS. On iPhone or iPad,
use Safari’s Share menu → Add to Home Screen (enable Open as Web App if offered).
On desktop browsers, use Install app or Add to Dock when available. The installed
web app opens in its own window with the SimQueue icon. It does not change the
native menu bar app or its Dock visibility.

The installation and service worker are scoped to the private URL path. No queue
responses, logs, actions or app shell are stored in an offline cache. An offline
launch shows a connection message; there is no offline job control, background
sync or push notification support. Tailscale must be connected for remote access.
The private path is saved as `dashboard_token` in the daemon's `config.json` and
survives dashboard restarts, app updates, and machine reboots. Keep the same
hostname and port (use `--port` or the app's saved settings) for a stable PWA URL.
The default CLI port 0 still chooses a new available port.

On the first app launch (or CLI dashboard launch) after upgrading, a missing token is generated and
written automatically, preserving the other config values. A missing config file
is created. CLI and menu bar dashboards using the same state directory share this
token. The config is kept owner-only (0600); protect backups too. No daemon restart
is needed to initialize or rotate the token.

Older releases kept tokens only in memory. To preserve an existing legacy PWA
link, copy its UUID path segment into the `dashboard_token` JSON string before
starting the upgraded dashboard. Otherwise this first upgrade creates a new path
once; subsequent upgrades keep it. Do not commit this credential to Git.

To deliberately revoke existing links:

```sh
simq dashboard --rotate-token
```

Use the same `--state-dir` if you configured one. Reopen the menu bar dashboard or
rerun `simq dashboard` to obtain the new URL, then replace installed PWA links.
Running dashboards read the saved token on requests, so rotation also invalidates
the old path without restarting them. Invalid/unreadable configuration fails
closed rather than silently issuing a replacement token or accepting an old one.

## Reverse proxy on another machine

To let a separate proxy machine reach the dashboard, bind to this Mac’s numeric
IPv4 LAN or Tailscale address instead of the default `127.0.0.1`:

```sh
simq dashboard --bind 100.101.102.103 --port 8765 --no-open
```

Replace that example with an address actually assigned to the dashboard Mac.
Use its Tailscale IP for private tailnet access, or its LAN IP for local-network
access. `--bind 0.0.0.0` listens on every IPv4 interface; the printed localhost URL
is for the hosting Mac, so use its reachable address from another machine.
Hostnames and IPv6 bind addresses are not supported. An invalid or unavailable
address fails startup rather than falling back to another interface.

Point the remote proxy at `http://<dashboard-ip>:8765`, preserve the browser’s
Host header, and forward the complete private path (including the trailing slash).
For Caddy, `reverse_proxy <dashboard-ip>:8765` preserves Host by default for an HTTP
upstream. Terminate HTTPS at the proxy. Restrict access to trusted devices: the URL
grants job controls and access to logs. The app’s own dashboard and existing local
Tailscale Serve setups keep their loopback default.

## Machine health and managed storage

Machine health shows the daemon’s latest resource sample: available/reclaimable
memory and pressure, total RAM, swap, interval CPU utilization, one/five-minute
load averages, core count and thermal state. CPU percent is a tick delta (first
sample unavailable); load average is a different measure, not CPU percent. Sample
time and stale readings are visible. System and job-output free space are shown
separately even when they share a volume. Admission holds show the daemon’s actual
reasons. Missing metrics from older daemons display unavailable, never zero.

**Review storage** schedules a background pass on the daemon’s existing artifact
retention lane. Polling reads the cached report; it does not scan directories.
The report separates DerivedData and top-level `.xcresult` bundles from the rest
of each run so they are not counted twice, distinguishes successful/other/active/pinned/untracked managed artifacts,
and lists up to 100 eligible cleanup targets. Additional accounting samples at
most 200 run directories; unreadable or unmeasured sizes remain explicitly unknown.
Sizes are logical file bytes, so APFS cloning/compression can make actual free-space
changes differ. Managed simulator and template data sizes come from `simctl` device inventory,
matched only to live ownership ledger IDs. Missing size readings remain unknown;
shared simulator runtimes and global Xcode caches are excluded. Simulator data is
visibility-only here: artifact cleanup never deletes a simulator or template.

**Review cleanup** opens the same read-only review with eligible targets, unknown
sizes, retention/pin policy, cleanup mode and last-pass failures. It does not delete
files. Use `simq gc` to review current candidates and `simq gc --apply` to apply the
existing retention policy from the command line. The existing backend cleanup API
is unchanged; this UI does not invoke it. Review requests are sent once, never
retried automatically after an ambiguous response. Maintenance blocks new storage
requests. An individual existing filesystem size walk can still be slow on a large
or unhealthy volume.

The storage card shows the last completed cleanup even before an inventory review.
The report is a single small `last-cleanup.json` file on the state volume, retained
across restarts. It reports confirmed removed targets and their measured logical
bytes, separately counts unknown removed sizes, and lists deferred/protected
candidates, failures (at most 100 details), and unavailable roots. Failed removals
are never counted as reclaimed bytes. Shared APFS blocks, compression, and
concurrent writes mean logical bytes removed are not a measured free-space gain.
Read-only reviews do not reset the last cleanup result.

The review also groups protected/retained run data by active work or pending
process cleanup, pins, and retention eligibility. These totals include each run's
DerivedData and results and subtract eligible DerivedData subtrees; they are a
separate explanation of protection, not extra bytes to add to the composition bar.
Accounting remains bounded to 200 runs and explicitly marks unknown sizes.
Missing or replacement drives appear with recovery guidance, never as empty roots.

Retention already runs automatically under `age_rules.artifact_retention_days` and
`age_rules.artifact_budget_gib` in config.json. The report shows the actual policy,
not an independent dashboard policy. The existing `host.min_free_disk_gib` threshold
(default 20 GiB, 0 disables) now protects both the system and output volumes; low or
unreadable output space holds new admissions without interrupting running jobs.


Configure retention in the daemon's existing `config.json` (see
[the configuration example](config.example.json)). For example:

```json
{
  "host": {"min_free_disk_gib": 20},
  "age_rules": {
    "artifact_budget_gib": 20,
    "artifact_retention_days": {"derived_data": 0.0833333333, "succeeded": 2, "other": 7, "kept": 90}
  }
}
```

Merge these keys into your existing configuration; retain other settings. Apply
configuration changes during a normal drained daemon restart, preserving running
work. These settings persist in the configuration file. Result bundles follow their
parent run's policy, so failed-run evidence lasts longer than successful output in
this example. The artifact budget excludes simulator/template data and protects
active work and pinned runs; it is a cleanup target rather than a hard quota.
Admission automatically resumes on a subsequent tick once free space is readable
and above the threshold on all required volumes. It never cancels running jobs to
recover space. The dashboard reports the effective policy and the actual hold.

## Frontend development and packaging

Node 22 is a development dependency, not a dashboard runtime. The generated JavaScript
and stylesheet have gzip size budgets of 24 KiB and 6 KiB respectively (enforced by
the build). The server continues to serve the embedded assets directly. Before a Swift build:

```sh
cd Web/dashboard
npm ci --no-audit --no-fund
npm run build
cd ../..
```

The TypeScript/Preact entry point, CSS, manifest and network-only service worker live
in `Web/dashboard/src`. esbuild writes minified assets to `.build/dashboard`. The
SwiftPM `DashboardAssetsPlugin` embeds those assets in a generated Swift source in
the build directory, so copied executables still serve the whole app without a
resource bundle. Generated assets, npm dependencies and browser evidence are ignored.
CI, release and nightly workflows prepare assets before compiling Swift. Rebuild
web assets after frontend changes; SwiftPM tracks their contents as build inputs.

```sh
npm --prefix Web/dashboard test
node Tests/Dashboard/dashboard.test.cjs
cd Web/dashboard
npx playwright install chromium webkit
npm run test:browser
```

Browser tests serve disposable fixtures with the dashboard's content-security
policy. They never reach the daemon or simulators. They cover light/dark responsive
states, missing metrics, offline recovery, focus/scroll retention, safe text,
confirmation/priority races, storage review and log interactions. WebKit emulation
is useful browser evidence, not a claim of validation on a physical iPhone.

For an opt-in 60-second Chromium heap/main-thread profile against the synthetic
fixture, run `npm run profile` in `Web/dashboard`. `-- --baseline-ref REF` also
profiles a historical revision that still embeds assets in DashboardAssets.swift.
The profile uses a separate loopback fixture port and writes ignored evidence to
`.build/dashboard/performance.json`; no daemon or simulator is contacted.
