# Local dashboard

Run `simq dashboard` to open a browser view. The foreground command prints
its private URL and serves until Ctrl-C. It uses an available port on `127.0.0.1`;
`--port 8765` selects a port, `--no-open` only prints the URL, and `--state-dir`
selects the daemon state directory. It does not start or replace the daemon. Start
or inspect your configured daemon with `simq status` if the view is disconnected.

The dashboard shows:

- Running, queued and preparing counts; admission state, health and global holds.
- Active jobs with dispatch position, priority and per-job waiting explanations.
- Up to 100 retained terminal jobs, ordered by submission (matching `simq jobs`).
- Search by command, project, kind, submitter or ID, plus project/state filters.
- When each job was queued and when it started, in your local time (`Oct 22, 12:43 PM`;
  a dash until it starts; hover for the exact timestamp).
- Separate queue wait, preparation and execution durations, and execution overlap
  for the latest 20 started jobs in the filtered window.
- Job details from `explain`: exact command argv, directory, commit, submitter,
  attempts, deadlines, simulators, peak process-group memory and artifact paths.
- A live tail of the latest 32 KiB of output for the selected job. Use `simq logs JOB`
  for the full output. Artifact paths are displayed, not served as files.

Labels combine the caller's project with its kind, falling back to the command
executable or job ID. No new naming or scheduling semantics are introduced.
Wait runs from submission to admission (or start on older daemons); prep runs
from admission to start; execution runs from start to completion. Missing phases
show a dash. Retries retain the original submission timestamp, so wait includes
prior attempts; prep, execution, simulator and memory details describe the latest
attempt. Snapshots make separate read requests and can briefly straddle a state
transition. Active lists are bounded at 10,000 entries; header counts come directly
from status and can exceed the displayed list.

Polling happens every three seconds after the previous request completes, while
the tab is visible. On failure, the last snapshot stays visible with a stale-data
warning. Timing values stop at that snapshot rather than suggesting fresh data.

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

## Job controls

Cancel waiting, preparing or running jobs using **Cancel**. The browser asks for
confirmation, then uses the daemon's existing cancellation and ownership-safe
cleanup. Cancellation acceptance does not mean cleanup has already finished.

Queued jobs also have **↑** and **↓** buttons to change base priority by 10 and a
**Priority…** button to enter an exact integer from 0 to 100. Higher runs first;
aging and host resource gates still apply. This does not preempt running jobs or
bypass admission holds. Once a job is admitted its priority cannot change. Races
with admission/completion return an error and the next snapshot updates the view.
The equivalent CLI is `simq bump JOB_ID PRIORITY`.

Mutations are sent once. A lost response is reported as unconfirmed; inspect the
refreshed job state before retrying. Priority changes require the updated daemon;
upgrade/restart the daemon along with the CLI.

The listener is loopback-only with a random per-session capability in its URL,
exact Host checking, no CORS, no external assets, and narrow API routes. Mutations require POST, the exact same Origin, and an
explicit action header; cross-origin requests have no CORS permission. Keep
the URL private: it permits controlling jobs and viewing commands and logs, which may contain secrets.
Other processes/users on the same host are not a security isolation boundary.
There are no retry, drain or arbitrary file/command endpoints.
No web dependencies or separate asset installation are required.

## Menu bar access

The optional [macOS menu bar app](MENU_BAR.md) opens this dashboard on click and
adds status counts, Launch at Login, and safe daemon stop options.
