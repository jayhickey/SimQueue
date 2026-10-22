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
A configured `/Volumes/<name>/...` path requires that mount to use a separate
filesystem from `/Volumes` before directories are created; an absent mount is never
intentionally recreated on the internal disk. Cleanup checks availability too.

This is basic availability protection. It does not pin a volume UUID, detect a
replacement disk, or guarantee writes/cleanup through a disconnect/replacement race.
Do not disconnect storage during jobs or cleanup. The state-volume disk admission
threshold (`host.min_free_disk_gib`, default 20 GiB) is the only disk floor; output free
space is diagnostic, not an additional threshold. A command may still choose its own output paths outside managed storage.
