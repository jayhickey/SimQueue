# Backends and host probes

The supported release target is an Apple Silicon Mac with Xcode and an installed simulator runtime. The simulator backend decides how devices are observed/managed; the resource probe independently decides which host readings gate admissions. Neither choice changes the submitted command into a test orchestrator: the job runs its complete command on its leased simulator, or uses `--sims 0`.

For normal setup, use [installation](INSTALL.md) and [the host template contract](TEMPLATE.md). This page explains backend behavior, test isolation and the limits of each mode.

## Selecting a backend

| Setting | Behavior |
| --- | --- |
| `--backend simctl` | Real macOS simulators through `xcrun simctl` |
| `--backend fake` | In-memory simulator devices; no CoreSimulator operations |
| `--probe system` | Real read-only resource measurements |
| `--probe fake` | A fixed healthy test host |

An explicit backend flag wins. Otherwise a dry run selects fake, then the configured `backend` is used, then the platform default: simctl on macOS and fake elsewhere. The probe normally follows the backend (system for simctl, fake for fake), but an explicit probe flag can override it. In particular, fake simulators with a system probe still respect the real host’s resource conditions.

For tests that must avoid real simulator access, pass both `--backend fake --probe fake`, use a dedicated state directory and disable client autostart with `SIMQ_NO_AUTOSTART=1`. Fake simulator selection alone does not turn arbitrary submitted shell commands into mocks; the process executor still executes them as the daemon user. Never submit simulator commands merely because the backend is fake.

`--dry-run` uses a private database copy and wrapped simulator/process/filesystem operations that report intended changes. It is distinct from a fake-backend daemon running real commands. Do not use a dry-run result as evidence that a host operation, upgrade or workload succeeded.

## Real simulator lifecycle

The production backend builds templates and clones the explicitly configured `simctl.template`. Stock templates use `simctl clone`; registered templates built with `--slim` use simslim to preserve their disabled-service profile. A new template candidate does not automatically become active. One selected device/runtime/template serves the host; project labels do not select different simulators. Pool compatibility is checked before a clone is handed out.

`simctl clone` does not itself boot the source or clone. Stock pool creation leaves the template shut down. Cloning a slimmed template can temporarily boot the source and clone while simslim copies and verifies the profile; this work consumes a boot slot and respects host admission gates. Normal pool boot then starts the owned clone and waits for `bootstatus`; pool settling is a separate readiness step. Every external tool call has a timeout. A failed or unparseable call fails the operation rather than being treated as success.

Creation records a unique intended name and clone source before host work starts. The backend compares before/after inventory and confirms a newly created device under that exact name. If clone output supplies a UDID, that UDID must match; an old lookalike is not an acceptable fallback. Deletion checks ownership, refuses template names, and confirms the exact UDID is absent in a fresh listing before recording release.

Pool names live in the SimQueue namespace and carry a persisted state-directory owner tag. Another daemon’s tagged devices are excluded from ownership/adoption. A name prefix alone is not a general permission to delete every matching device: stored ownership, action intents, process identity and cleanup gates govern the caller’s decision. Templates and unrelated devices are not automatically reaped.

External-device inventory is queried when a create/boot might act, not on every idle pass. A slow query requires fresh resource gates before action. Full watchdog reconciliation and startup still inspect real inventory. An unavailable inventory can delay the operation that needs it; no stale listing is proof that a device has disappeared.

## Optional simslim

Stock templates and their clones do not require simslim. Install it separately and explicitly request `simq template build --slim` to opt in. Keep it installed while that template is selected: new clones use `simslim clone` to preserve the template’s actual disabled-service profile. A plain `simctl clone` does not preserve that profile. Missing or unsupported tooling fails the operation instead of silently producing a stock clone. Template metadata records successful slimming; clone provenance records how the profile was preserved. Use the [template guide](TEMPLATE.md) for the supported build/selection sequence.

## Resource readings

The system probe reads load averages, physical/available memory, memory pressure, swap usage, free space on the state filesystem and thermal state. Admission holds when a required reading fails. Memory admission is an estimate from current host readings plus conservative explicit charges, not an operating-system reservation or a learned per-job model.

On macOS, when `sysctl` resolves to `/usr/sbin/sysctl`, the daemon uses native Mach/sysctl memory, pressure and swap readings, plus `getloadavg`, filesystem and thermal APIs. This avoids launching a probe subprocess for each reading. The tool-backed path remains for injected executable fixtures: bounded `vm_stat` and `sysctl` calls allow parsing/failure tests. A custom PATH can therefore change which reading path is exercised; keep production tool selection deliberate.

Load recovery, boot thresholds, memory reserve, swap growth, thermal and disk gates are described in [architecture](ARCHITECTURE.md). Probe failures are not a reason to increase limits until a job starts. Inspect `simq explain`, `simq status` and `simq doctor` to distinguish resource holds, pool warm-up and ownership cleanup.

## What tests establish

Fake backends support controlled devices, resource snapshots, clock progression and host-operation failures. Fake executable tools additionally exercise real command construction, parsing, timeouts and returned-identity confirmation without operating CoreSimulator. Slow-operation tests cover independent scheduling/supervision and in-flight ownership races.

These tests do not prove real clone/boot performance, simulator-hosted XCTest cancellation, published release-asset access, Homebrew service behavior or a clean-account installation. Real read-only calls establish only inventory/parser compatibility; they do not boot a device or establish workload success. Record live host/Xcode/runtime evidence separately using the [release process](RELEASING.md#release-evidence).

Linux can exercise pure policy and fake-backed development tests. It is not a supported simulator host, and an arm64 release artifact does not establish Intel or older macOS/Xcode runtime support.
