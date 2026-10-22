# Releasing SimQueue

SimQueue publishes Apple Silicon binaries through GitHub Releases and Homebrew. The
release workflow runs only on disposable GitHub-hosted ARM64 runners. Public pull
requests must never execute on a personal or shared self-hosted Mac.

## Version and source

`SimQueueVersion.current` in `Sources/SimQueueCore/Version.swift` is `0.0.0-dev` in source.
`scripts/stamp-version.sh` stamps the build checkout from a semantic version tag:
`v0.1.0` produces version `0.1.0`. The stamped file is not committed. Both executables,
status and doctor report this version.

The first public release is `v0.1.0`. Before tagging, finish all source, workflow and
documentation changes and verify CI at that exact commit. Do not move a published tag
to a different tree or replace its assets silently. A rebuild can produce different
bytes even when source is unchanged; verify the actual package used for installation.

## Validate a release build

1. Run the full fake-backed test suite, strict format lint and executable smoke checks
   through CI. Record the exact source SHA, toolchain, test count and skip reasons.
2. Dispatch the Release workflow with `version=0.1.0` for a nonpublishing archive. Verify
   run head SHA, artifact identity, executable versions, ARM64-only architecture and
   archive checksum. A dispatch never publishes. By default its artifact is unsigned;
   add `-f notarize=true` to exercise the complete signing/notarization path.
3. Exercise representative real simulator work and resource-gated bursts on an authorized
   isolated host. Record the actual platform, inputs, outcomes and limits separately
   from fake tests. Keep live device identifiers and private host data out of Git.
4. Verify install, service setup, a complete job, drain/reconnect, upgrade/rollback and
   cleanup through Homebrew. Preserve the actual artifact and configuration used.

```sh
gh workflow run release.yml --ref main -f version=0.1.0 -f notarize=true
```

## Automatic release after main CI

The Release workflow listens for a completed `CI` workflow on `main`. A successful
push from this repository is eligible; pull-request, fork and failed CI runs are
not. It checks out the exact tested source SHA for both building and signing.

1. Skip a stale CI result when a newer main commit exists, or a source already
   associated with a release.
2. Select the next patch version after the highest stable semantic version tag.
   For example, `v0.1.5` becomes `v0.1.6`. Prerelease tags do not affect that choice.
3. Build and package ARM64 executables on a disposable hosted Mac.
4. Sign, notarize, staple and verify the distribution as described below.
5. Create the version tag at that exact source SHA only after all checks pass,
   then publish the notarized archive and checksum to GitHub Releases.

The release concurrency group serializes automatic, manually tagged and validation
runs. A retry skips a source already released; if tag creation succeeded but release
creation failed, it can reuse that tag only for the same commit. Existing tags and
published assets are never moved or overwritten. Version tags created with the
workflow token do not recursively start another tag workflow.

Every successful new main commit is eligible, including documentation-only changes.
Keep signing secrets configured before merging this workflow. Missing credentials,
Apple rejection, timeout, stapling or Gatekeeper failure stop publication before an
automatic tag is created. After stable publication, a separate job updates the Homebrew CLI formula and app
cask together using the signed archive checksum. It never forces a branch update
or downgrades a newer tap version. Manual validations and prereleases skip this job.
A tap failure leaves the published GitHub release available and makes the workflow
fail visibly; retry the tap update using the verified asset below.

Manual `workflow_dispatch` is a validation/recovery tool and never publishes. Its
optional version defaults to `0.0.0-dev+<source SHA>`; enable `notarize` to test the
full Apple flow without a release. Explicit `v*` tag pushes remain supported for
intentional major/minor/prerelease versions, but require successful main CI at that
exact source commit before building or publishing.

The workflow stamps the planned version, builds `swift build -c release --arch arm64`, and
runs `scripts/package-release.sh`. Packaging requires both executables to contain only
ARM64 code and report the tagged version. It writes
`simqueue-0.1.0-macos-arm64.tar.gz` and its `.sha256` file, containing `bin/simq`,
`bin/simqd`, `SimQueue.app`, `LICENSE`, `NOTICE`, `README.md`, `AGENTS.md`, full `docs/`, and the optional
`skills/simqueue/SKILL.md`.

## Developer ID signing and notarization

The release workflow has three separate phases: build an unsigned archive on a
disposable runner, sign/notarize on another disposable runner, then publish only
the notarized artifact. No public pull-request job receives signing credentials.
Tagged builds fail if credentials are missing or notarization fails; they never
publish an ad-hoc fallback. A plain manual dispatch remains an unsigned build
check, with an explicitly `unsigned` artifact name.

Use a dedicated notarization API key with the least privilege Apple permits.
Configure these repository Actions secrets before enabling the tagged path:

| Secret | Purpose |
| --- | --- |
| `MACOS_CERTIFICATE_P12_BASE64` | Base64 of an encrypted PKCS#12 export of only the Developer ID Application identity and private key |
| `MACOS_CERTIFICATE_PASSWORD` | Password used to encrypt that export |
| `MACOS_SIGNING_IDENTITY` | Identity fingerprint or exact Developer ID Application name in that certificate |
| `NOTARY_API_KEY_BASE64` | Base64 of the App Store Connect notarization API private key (`.p8`) |
| `NOTARY_API_KEY_ID` | That API key's ID |
| `NOTARY_API_ISSUER` | Issuer UUID for a Team API key; omit for an Individual key supported by the installed `notarytool` |

Export the specific identity with its private key from Keychain Access, encrypted
with a new export password. A `.cer` alone cannot sign: it has no private key.
Upload values with `gh secret set` using standard input or a private file, without
printing them or placing them in shell history. Never export all identities, commit
credentials, or upload key material as a workflow artifact. Keep the original
Keychain and unrelated identities unchanged.

The signing job imports the identity into a temporary, explicitly selected Keychain,
grants access to Apple signing tools, and deletes the Keychain and private files
on exit. It does not change the default Keychain or its search list. Build and
signing jobs have read-only repository tokens; only the final publish job can
write a release.

`scripts/notarize-release.sh VERSION RELEASE_DIRECTORY OUTPUT_DIRECTORY`:

1. Checks release layout, executable versions (including the bundled daemon) and credentials.
   The app includes `Contents/Helpers/simqd` and its Service Management agent plist;
   sign the helper with identifier `dev.simqueue.app-daemon` before sealing the app.
2. Signs `simq`, `simqd` and the app with Developer ID, hardened runtime and a secure
   timestamp. Rejects development/ad-hoc identities.
3. Submits a ZIP of the signed distribution with `notarytool --wait` and requires
   an explicit `Accepted` result.
4. Staples and validates the ticket on `SimQueue.app`, verifies its signature, and
   assesses it with Gatekeeper.
5. Rebuilds the final archive and checksum after stapling. It refuses to overwrite
   an existing archive. CLI tools use Apple's online notarization records; they
   do not support stapling app tickets.

For local signing, set `SIMQ_SIGNING_IDENTITY` and `SIMQ_NOTARY_PROFILE` to an
existing `notarytool` Keychain profile. Alternatively set `SIMQ_NOTARY_KEY_PATH`,
`SIMQ_NOTARY_KEY_ID` and (for Team keys) `SIMQ_NOTARY_ISSUER`. Set
`SIMQ_SIGNING_KEYCHAIN` only when selecting a dedicated Keychain. These values
belong in private local configuration, not the repository. The script prints the
submission ID so a rejected submission can be inspected with `notarytool log`.
Do not enable shell tracing while signing or authenticating.

Local `package-app.sh` builds remain ad-hoc signed. Existing published versions
are immutable; implementing notarization does not retroactively notarize or replace
their assets. Confirm an actual Apple-accepted build and stapled downloaded app
before describing a release as notarized.

This follows the sign → notarize → staple → re-archive sequence used by
[XcodesApp](https://github.com/XcodesOrg/XcodesApp/blob/main/Scripts/notarize.sh),
with explicit acceptance/failure checks and Apple's current
[notarization guidance](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

The separate publish job alone receives `contents: write`. It verifies the uploaded
archive checksum before creating the public release. Build/test jobs have read-only
repository access. Check the actual release asset after publication; a dry-run artifact
is not a substitute for verifying its public URL.

## Update the public Homebrew tap

Maintain both `Formula/simqueue.rb` (CLI/daemon only) and
`Casks/simqueue-app.rb` (optional app, depending on the formula). Use the same
release version and verified checksum in both. Verify the cask app path against
the staged archive, keep installation free of service changes, and preserve all
shared state on app uninstall. Do not add daemon stop or shared-data zap hooks.


1. Download the actual public release asset anonymously, with no credentials or cached
   download, and check its SHA-256, archive contents, versions and ARM64 architecture.
2. Set the formula URL to the exact public tagged asset and its verified checksum. Use
   the standard Homebrew download strategy, `depends_on arch: :arm64`, and preserve
   optional simslim behavior. Public installation requires no GitHub authentication.
3. Install through `brew install jayhickey/tap/simqueue` using an empty download cache,
   verify offline `simq agent-guide`, `simq docs`, installed relative documentation links
   and the optional skill payload, then exercise setup, service start, a full job,
   drain/restart and uninstall. Verify
   only owned resources change; retain templates/state unless purge is explicit.
4. Check an upgrade and rollback with a consistent pre-upgrade state backup. Follow
   [planned upgrades](INSTALL.md#planned-upgrade); do not mix old binaries with a newer
   database schema or discard pending ownership to bypass cleanup.

Record whether testing used an existing account or a fresh environment. Do not infer
fresh-account onboarding from an existing-account run. Local builds are ad-hoc signed; newly tagged public builds require Developer ID
signing and notarization. Verify the actual release evidence and do not instruct
users to disable platform security controls.

## Release evidence

Keep source/run identities, source-to-artifact mapping, archive and executable hashes,
versions/architecture, test counts/skips, real workload inputs/outcomes and Homebrew
validation together outside the repository. Publish only concise sanitized results
that actually ran. Do not publish old private workflow links, local job IDs, device
identifiers or machine paths. A history reset changes commit identity: prior local
validation remains historical evidence and does not replace CI on the new public SHA.

If hosted builds are unavailable, a maintainer may build on an explicitly authorized
host using its existing queue and toolchain, validate the same archive contracts, and
upload that actual package. Never attach a personal Mac runner to this public repository
as a workaround. The public initial commit must still pass its required hosted CI.

### Automatic tap credentials

Set the repository Actions secret `HOMEBREW_TAP_TOKEN` to a fine-grained token restricted to the tap repository, with Contents read/write permission. The default Actions token cannot write to another repository. No tap credential is supplied to build, test, signing, or public pull request jobs. The token is used only after stable publication; missing or expired credentials fail the tap job explicitly.

The default target is `<repository owner>/homebrew-tap`; set the Actions variable `HOMEBREW_TAP_REPOSITORY` to override it. The updater modifies only `Formula/simqueue.rb` and `Casks/simqueue-app.rb` in one commit, preserves installation/service definitions, removes the previous formula revision, and refuses unexpected layouts or stale-version downgrades. Branch protection must permit the credential holder's update; the updater never bypasses protection. Re-running the updater for identical contents is a no-op. If another tap commit races it, rerun the updater so it reads the new branch head.
