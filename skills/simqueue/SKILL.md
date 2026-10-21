---
name: simqueue
description: Coordinate builds and complete iOS simulator test suites on a Mac with SimQueue installed. Use for shared-Mac build/test execution, simulator-backed CI, and submitting, inspecting, or cancelling queued jobs.
license: MIT
---

# SimQueue

Before submitting work, read the installed version's instructions:

```sh
simq agent-guide
```

Use that guide as the authority for commands, simulator and artifact paths,
resource hints, waiting, cancellation, recovery, and structured results. Read
the project's own agent instructions for its workspace, scheme, toolchain, and
test command. Keep each queued command within the user's authorized task.

If `simq` is unavailable or the host has not been configured, report what setup
is missing; installing this skill does not install or configure SimQueue.

Use `simq docs` to locate the installed documentation when more detail is
needed. Follow the guide's JSON inspection and result-file examples rather than
parsing human-readable output or resubmitting work that is already queued.

Inspect and manage the jobs created for the current task. Draining the shared
host, replacing its template, or cancelling another caller's job requires that
action to be within the user's request.
