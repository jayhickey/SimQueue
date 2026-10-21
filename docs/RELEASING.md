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
   archive checksum. A dispatch never publishes.
3. Exercise representative real simulator work and resource-gated bursts on an authorized
   isolated host. Record the actual platform, inputs, outcomes and limits separately
   from fake tests. Keep live device identifiers and private host data out of Git.
4. Verify install, service setup, a complete job, drain/reconnect, upgrade/rollback and
   cleanup through Homebrew. Preserve the actual artifact and configuration used.

```sh
gh workflow run release.yml --ref main -f version=0.1.0
```

## Publish v0.1.0

Tag the verified public commit and push the tag:

```sh
git fetch origin
RELEASE_SHA=REPLACE_WITH_VERIFIED_COMMIT
git tag -a v0.1.0 "$RELEASE_SHA" -m "SimQueue 0.1.0"
git push origin v0.1.0
```

The tag workflow stamps the version, builds `swift build -c release --arch arm64`, and
runs `scripts/package-release.sh`. Packaging requires both executables to contain only
ARM64 code and report the tagged version. It writes
`simqueue-0.1.0-macos-arm64.tar.gz` and its `.sha256` file, containing `bin/simq`,
`bin/simqd`, `LICENSE`, `NOTICE`, `README.md`, `AGENTS.md`, full `docs/`, and the optional
`skills/simqueue/SKILL.md`.

The separate publish job alone receives `contents: write`. It verifies the uploaded
archive checksum before creating the public release. Build/test jobs have read-only
repository access. Check the actual release asset after publication; a dry-run artifact
is not a substitute for verifying its public URL.

## Update the public Homebrew tap

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
fresh-account onboarding from an existing-account run. Signing/notarization are not
part of this release; do not instruct users to disable platform security controls.

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
