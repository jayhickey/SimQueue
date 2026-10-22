# Set up the host template

SimQueue clones explicitly selected templates into one shared simulator pool. Each normal job runs its complete workload on one leased simulator. Project labels identify work; they do not select different devices or runtimes.

## Build and select

After `simq init`, build a stock candidate using detected host defaults:

```sh
simq template build host
simq template list
```

`host` identifies the candidate, not a routing rule. Building can take a few minutes and does not activate the result. Wait for `ready`, then copy its UDID into the existing `config.json`:

```json
{"simctl": {"template": "PASTE-READY-TEMPLATE-UDID"}}
```

Merge this key into the existing JSON; replace the placeholder. Drain/restart using the [chosen manager](INSTALL.md#choose-one-daemon-manager), then check `simq status` and `simq doctor`. A missing selection leaves simulator work waiting with guidance; SimQueue does not silently choose the newest candidate. Unverified/failed builds are not cloned.

For a specific installed target, use build flags or host-wide `template.device_type`/`template.runtime` defaults. Flags override defaults for that build:

```sh
simq template build host \
  --device-type INSTALLED_DEVICE_TYPE_ID \
  --runtime INSTALLED_RUNTIME_ID
simq template list --json
```

Replace the uppercase placeholders with identifiers available in the selected Xcode installation. Inspect Xcode's installed runtimes or its read-only simulator inventory. Jobs select a configured template label; each template fixes its device type and runtime. `STALE` indicates a toolchain/runtime difference from the recorded build and is a reason to review/rebuild. `--replace` creates a replacement candidate; it does not change selection or reassign existing clones.

## Named host templates

Build ready candidates with the installed iPhone and iPad device types, then map
labels to their simulator UDIDs in the existing configuration:

```json
{
  "host_templates": {
    "iphone": "READY-IPHONE-TEMPLATE-UDID",
    "ipad": "READY-IPAD-TEMPLATE-UDID"
  },
  "default_host_template": "iphone"
}
```

Use `simq run --sims 1 --template ipad -- <complete-command>` (or `submit`).
The MCP submit tool also accepts `template`. Unknown labels are rejected. Labels
are generic; projects never select a template implicitly. Omitting the flag uses
`default_host_template`, or the existing `simctl.template` when no named default
is configured. The legacy single-template configuration remains supported.

All labels share `pool.max_sims`, boot concurrency, memory, load and admission
limits. The pool prepares matching clones on demand and retires idle clones when
another requested template needs room. Each job runs its entire command on its
leased simulator; this does not shard tests. Results include the selected label,
simulator identity, clone source, device type and runtime when available. Older
pool rows can lack device/runtime metadata until those clones are recreated.
Manual leases use the default template.

Drain/restart after changing template configuration. Existing clones must belong
to a still-configured source; retire incompatible clones using the procedure below.
Slim profiles under `template.profiles` remain build-time service settings, separate
from the host template labels described here.

## Optional slimming

Stock templates use simctl and need no simslim installation. To deliberately slim a template, install simslim separately and opt in:

```sh
simq template build host --replace --slim
```

A failed slimming step leaves `slim_failed`, not ready for cloning. Inspect the error and rebuild/remove it. Configured slim profiles supply arguments when the template is built; they do not create separate pools.

Keep the services your tests use enabled. For example, this host-wide profile preserves
StoreKit and WidgetKit categories; `--keep` can preserve individual daemon labels too:

```json
{"template": {"profiles": {"default": ["--except", "store,widgets"]}}}
```

Profiles are read on startup. When changing an existing pool's profile, first finish or
cancel its queued work, then drain, stop and retire the old pool using steps 2–4 below.
Merge the profile into the configuration and restart to build the new candidate; finish
step 5 to select it and restart again. Keep callers paused during this transition.
Use the installed simslim category list to choose other services. Check a leased clone's
required features before a complete test run:

```sh
simq run --sims 1 -- sh -c 'simslim doctor "$SIMQ_UDID" --requires widgets,storekit'
```

Keep simslim installed while a slimmed template is selected. SimQueue uses `simslim clone` to copy the source’s actual disabled-service profile into new pool devices. This can temporarily boot the source and clone, so creation respects boot and host resource limits. Stock templates continue to use simctl without simslim. Existing clones made without profile preservation must be retired before using the slimmed selection; follow the drain/uninstall sequence below.

## Reuse and readiness

Use `simq run --sims 1 -- <command>` and pass the daemon-provided `SIMQ_UDID` to the test runner. See [the complete Xcode example](ONBOARDING.md). Completed jobs return warm simulators for reuse; installed apps, files and settings can persist.

| Option | Preparation before the command |
| --- | --- |
| No reset flag | Use the simulator as the previous job left it. |
| `--reset-app com.example.app` | Uninstall the app, reset its privacy permissions and reset the keychain. Repeat for more apps; a failed reset falls back to erasing. |
| `--fresh-sim` | Erase before the command; slower, with a cleaner starting state. |

Preparation retains the job's lease. This is trusted execution as the daemon's user, not security isolation between projects. Keep concurrent source checkouts and output directories separate.

Readiness supports `pool.settle.mode: load` and `off`; both require the backend's bounded boot-status step. Default `load` settling accepts load5 below the derived threshold, or recovered load1 at or below the host's derived clear threshold. This avoids waiting for five-minute history after current load recovers. Explicit `pool.settle.load_below` or `host.settle_load5_per_core` retains strict load5-only settling, including an explicitly supplied value equal to the default; omit those overrides to use default recovery. Configured scheduler `max_load5` and all other admission gates still apply before a job starts. `off` permits readiness after boot-status completes. `max_wait_seconds` bounds settling. `on_cap: fail` shuts down an unsettled simulator; `handoff` explicitly permits handoff with an audit entry. The [example config](config.example.json) chooses `fail`. Unsupported quiet-time modes/settings are rejected.

## Change the active template

This changes the environment for all projects. Existing incompatible clones must be removed first; startup refuses them before queue recovery.

1. Build the new candidate while the current selection stays in place. Review queued work: it will use the new contract after restart. Cancel/finish jobs that require the old environment.
2. Finish jobs, release manual leases and run `simq drain --timeout 30m`. Continue only after a successful drain; resolve pending cleanup/leases first.
3. Stop the Homebrew service if selected. Keep the current template configured while inspecting `simq uninstall`. On-demand uninstall stops its own drained daemon.
4. Run `simq uninstall --yes --force` to remove owned pool simulators while keeping templates, config and history. `--force` allows report-only cleanup/queued work; it cannot bypass active leases or cleanup. Do **not** add `--purge`.
5. Require successful verified removal, set `simctl.template` to the new ready UDID, restart the chosen manager and check status/doctor and the first job's recorded simulator provenance.

Confirmed removals retire their pool/ownership rows. Partial failures or unreadable inventory preserve those rows: fix the reported problem and retry rather than bypassing the guard. A newer candidate alone never changes selection.

Remove obsolete candidates with `simq template rm UDID` after their clones are gone. Removal follows the cleanup gate: report-only mode keeps the template, and rate limits can postpone deletion. Uninstall retains templates by default.
