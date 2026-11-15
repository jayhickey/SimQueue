<!-- kit:agents-base v0.1.0 -->
## Contribution guidance

Preserve existing work. Use an isolated branch, keep changes scoped, and explain the reason and validation in the PR. Open drafts early and request independent review at the final head. Required checks must pass before the repository's normal merge process.

Use SimQueue by default for iOS builds, tests and simulator proof. Read `simq agent-guide`, use the assigned device and output paths, bound compiler workers to four and disable parallel simulator testing. Do not bypass admission or manipulate unowned simulators. Record run IDs and relevant logs. Retry diagnosed infrastructure failures at most once; never retry run timeouts or cancellations.

For visible changes, inspect final-head screenshots in light and dark mode and attach proof to the PR. Describe the device, OS and tested commit. Never commit proof media. Nonvisual changes need relevant check results. Keep credentials and personal data out of files, logs and attachments.
<!-- /kit:agents-base -->

<!-- kit:project-start -->
# SimQueue project guidance

## Build and test

Read `simq agent-guide` for the installed version before submitting managed work.
`simq docs` locates the full offline documentation.

Use SimQueue by default for builds and iOS simulator tests on shared Macs. Keep
concurrent work in separate checkouts and bound compiler parallelism. For work
that needs no simulator, submit with `--sims 0`:

```sh
simq run --project simqueue --sims 0 --timeout 20m -- swift build -j 2
simq run --project simqueue --sims 0 --timeout 20m -- swift test -j 2
```

Build the embedded dashboard before building the Swift package:

```sh
npm --prefix Web/dashboard ci --no-audit --no-fund
npm --prefix Web/dashboard run build
```

Before each push, run the formatter checks used by CI:

```sh
swift format lint --strict --recursive Package.swift Sources Tests
swift format lint --strict --recursive Plugins
swift format lint --strict scripts/verify-sparkle-update.swift
```

For dashboard changes, also run:

```sh
node Tests/Dashboard/dashboard.test.cjs
npm --prefix Web/dashboard run format:check
npm --prefix Web/dashboard test
```

The complete build, packaging, release-control and browser checks are defined in
`.github/workflows/ci.yml`. Extended fake soak checks are in
`.github/workflows/nightly-soak.yml`; publishing is in `.github/workflows/release.yml`.
Fresh disposable CI machines may build directly with bounded workers.

## Simulator and host safety

- Run a job's complete simulator suite on one leased simulator. Use the supplied
  `SIMQ_UDID`, `SIMQ_DERIVED_DATA` and `SIMQ_RESULT_BUNDLE` paths; expand them in
  the queued command. Do not infer ownership from a device name.
- Prefer fake backends, injected clocks and isolated test state. A passing fake
  test does not establish live simulator behavior; describe the actual evidence.
- Preserve existing host configuration, services, devices and unrelated processes.
  Do not bypass admission gates or replace the running daemon to accelerate a build.
- Inspect an existing job after a disconnect before resubmitting. Do not retry
  timeout (3 or 143) or cancellation (5) results. Daemon-unavailable (69) and
  queue-full (73) results may be retried after checking job state and backpressure.
  Interpret codes using the selected exit-code mode and recorded result class.
- Keep project labels caller-supplied and scheduling generic; do not introduce
  implicit test sharding or project-specific scheduling.

## Pull requests

- Keep changes focused, preserve unrelated work and add regression coverage for
  behavior changes. Use the configured author identity.
- Open draft pull requests for review. Describe what changed, why, commands run,
  results, skips and limitations. Required CI must pass at the current head before
  maintainers squash-merge. Do not merge without maintainer authorization.
- Keep credentials, machine configuration, local paths, device identifiers,
  generated artifacts and private validation data out of commits. Keep proof
  media outside Git.
- Run untrusted public contributions only on disposable GitHub-hosted runners.
  Never attach a personal or shared Mac runner to this public repository. Use
  least-privilege workflow tokens and separate publishing from build/test jobs.
- Keep repository instructions and workflow dependencies usable by public
  contributors. Do not add dependencies that require private repository access.
<!-- kit:project-end -->
