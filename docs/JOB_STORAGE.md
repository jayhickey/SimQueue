# Job output storage

By default, job output stays in `<state directory>/jobs`. To move bulky output, set
one dedicated absolute directory in `config.json`:

```json
{"job_output_root": "/Volumes/BuildSSD/SimQueue/jobs"}
```

The database, configuration, socket, daemon log and internal health/history files
remain in the state directory. Per-job logs, temporary files, DerivedData and result
bundles live beneath the configured output root. Continue passing
`$SIMQ_DERIVED_DATA` and `$SIMQ_RESULT_BUNDLE` to your build command. `SIMQ_RUN_DIR`,
`SIMQ_TMPDIR` and the default `TMPDIR` also use that job's directory. Existing age,
pinning and size-budget retention policies apply across current and previous roots.

For a running installation, drain successfully with `simq drain --timeout 30m`, stop
the chosen daemon manager, change the setting, and restart. The daemon records a
completed drain and rejects subsequent root changes without one. For the first
upgrade from a version without storage configuration, it verifies no active jobs,
leases, process ownership or pending cleanup remain. Existing output is not moved;
old job evidence paths remain valid. Keep previous output volumes available until
retention has removed their data. Do not edit the internal `job-output.json` routing
history or manually move job directories.

`simq status` and `simq doctor` show the internal state path, output root,
availability/writability and free bytes. Unavailable storage holds new admission.
Both also run a bounded real-I/O probe of the output root: a tiny file is written,
read back uncached and removed on a separate thread. A probe still pending after 5 s
reports the root unavailable ("reads and writes there may be hung") even when the
volume is mounted and its metadata looks writable. Results are reused for 30 s.
While the probe reports a root hung, or has not finished a probe of it yet (as
right after the daemon starts), the daemon treats it as unavailable storage:
nothing new is admitted (so no pool sims are leased for work that cannot start),
an admitted job is not prepared and keeps its attempt, and `explain` and `wait`
return the job without walking its run directory, with `artifacts_unavailable`
saying why. Requests therefore keep answering instead of each holding a connection
slot in a blocked walk until new ones are refused as "request limit reached". A
finished job's `job.json`, `summary.md` and `events.jsonl` are written within 2 s
or left to finish in the background, so the daemon's state lock is never held by a
blocked write.

Jobs admitted before a hang keep their leased sims until the volume answers or the
job is canceled (cancel releases them), as with a disconnected volume. A probe
passes for 30 s, so for up to about 35 s after a passing probe a newly hung volume
can still block a run-directory listing or a start preparation already under way;
a start preparation inside a blocked call waits for the volume, and the jobs
queued behind it wait too.

On macOS a volume can behave this way without any hardware fault: opening files on
an external or removable volume waits for the privacy consent ("access files on a
removable volume") of the process's responsible app, so a prompt left unanswered on
a headless host blocks every such open while `stat` and free-space calls still
succeed. Grant the daemon's app access (or Full Disk Access) ahead of time, or keep
job output on the internal volume.
A configured `/Volumes/<name>/...` path requires that mount to use a separate
filesystem from `/Volumes` before directories are created; an absent mount is never
intentionally recreated on the internal disk. Cleanup checks availability too.

Each root is pinned to its filesystem UUID in `storage-volumes.json` in the state
folder. On first use (including upgrade from older releases), an available root is
bound to the drive currently mounted there. Existing bindings survive daemon
restarts. A different drive with the same mount name is rejected; admission,
preparation, and cleanup require the original volume. An unreadable identity or a
binding that cannot be saved fails closed. Offline historical roots remain
recorded and are skipped during discovery, rather than treated as deleted.

Reconnect the original drive at the configured mount path to recover. Queued and
admitted-but-unstarted jobs resume without resubmission; a prepared log descriptor
is revalidated before spawn. Running commands retain their normal exit/result
semantics: filesystem errors may fail them, and SimQueue does not replay commands
or recover lost writes merely because the drive returned. The database remains on
the state volume. A recovered admission hold schedules another retention pass.
For an intentional replacement disk, drain, stop the daemon, and configure a new
dedicated `job_output_root` before restarting. The old root's binding remains to
protect retained evidence; do not edit the internal identity map to adopt a drive.

Identity checks narrow replacement risks but cannot make an unplug during an
individual filesystem syscall atomic or guarantee recovery of in-flight writes.
Do not disconnect storage during jobs or cleanup. The existing disk admission
threshold (`host.min_free_disk_gib`, default 20 GiB, 0 disables) also applies to the
system and required job-output volumes. Low or unreadable output free space holds
new work without interrupting running jobs; admission resumes automatically once
space recovers. The dashboard shows the actual hold and offers a background storage
review with a cleanup preview (see [the dashboard guide](DASHBOARD.md)). A command
may still choose its own output paths outside managed storage.

On macOS, available bytes include space the system can reclaim for important
writes (`volumeAvailableCapacityForImportantUsage`). Dashboard reporting and disk
admission checks use the same measurement, falling back to raw filesystem free
bytes when that capacity is unavailable. This can exceed the free space shown by
`df`; it is an OS estimate, not a guarantee that a later write will succeed.
