# Contributor and coding-agent guidance

Read `simq agent-guide` for the installed version before submitting managed work.
`simq docs` locates full offline documentation; optional skills are installed explicitly.

1. Follow the user's explicit task scope and repository instructions. Use the configured
   author identity; never invent a maintainer identity or approve on someone else's behalf.
2. Keep changes focused and generic. Project names are caller-supplied labels. A normal
   job runs its complete workload on one leased simulator; simulator-free work uses
   `--sims 0`. Do not introduce implicit test sharding or project-specific scheduling.
3. Prefer fake backends, injected clocks and isolated test state for development. Live
   simulator, service and host changes must stay within the user's authorized scope.
   Preserve unrelated devices, services, repositories and processes.
4. On a shared host managed by SimQueue, admit heavy work through its existing queue
   and bound compiler parallelism. Do not bypass resource gates or replace its daemon.
   Fresh disposable CI machines can build directly with bounded workers.
5. Use the supplied `SIMQ_UDID`, DerivedData and result-bundle paths for managed simulator
   jobs. Keep concurrent builds in separate checkouts. Never infer device ownership from
   a similar name, discard pending cleanup, or kill unrelated simulator services.
6. Push draft changes freely. Before landing Swift changes on main, required CI must
   pass on the current commit, including build, tests and formatting. Run focused local
   checks when they provide faster feedback or cover behavior CI cannot exercise.
   Before every push, run CI's formatter check (there is no hook): `swift format lint --strict
   --recursive Package.swift Sources Tests` (fix with `swift format format -i <files>`).
   Add regression coverage for behavior changes. Report commands, commit and results,
   including skips and limitations.
   Follow explicit user instructions about direct commits or pull requests.
7. Public CI must run untrusted contributions only on disposable GitHub-hosted runners.
   Never register a personal/shared Mac runner to this public repository. Workflows use
   least-privilege tokens; publishing is separate from read-only build/test jobs.
8. Commit source and useful regression tests, not credentials, host configuration,
   device identifiers, local paths, private validation data or generated build artifacts.
   Keep machine-specific deployment scripts and raw test evidence outside the repository.
9. Preserve truthful user-facing behavior and documentation. A passing fake test does not
   establish live simulator behavior; report the actual platform, workload and evidence.
10. Do not send messages, create releases, change external services or perform destructive
    repository operations beyond the user's authorization. A prior explicit authorization
    remains valid for the stated scope; routine reversible implementation needs no repeat
    confirmation.
