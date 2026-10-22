#!/usr/bin/env python3
"""Plan releases from a successful main CI run; never tag or publish here."""
import json
import os
import re
import subprocess

STABLE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
VERSION = re.compile(r"^\d+\.\d+\.\d+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$")
SHA = re.compile(r"^[0-9a-f]{40}$")


def plan(event_name, event, source, main_sha, tags, releases, repo):
    result = dict(run="false", source=source, version="", publish="false", notarize="false")
    if not SHA.fullmatch(source):
        raise ValueError("Invalid source commit")
    if event_name == "workflow_run":
        run = event["workflow_run"]
        if not (run.get("conclusion") == "success" and run.get("event") == "push"
                and run.get("head_branch") == "main" and run.get("head_sha") == source
                and run.get("head_repository", {}).get("full_name") == repo):
            return result, "Ignoring CI that is not a successful push to this repository's main"
        if source != main_sha:
            return result, "A newer main commit exists; wait for its CI instead"
        matching = sorted((tag for tag, sha in tags.items() if sha == source and STABLE.fullmatch(tag)),
                          key=lambda tag: tuple(map(int, STABLE.fullmatch(tag).groups())))
        if any(tag in releases for tag in matching):
            return result, "This source commit already has a release; nothing to publish"
        if matching:
            version = matching[-1][1:]  # Recover a tag whose release creation failed.
        else:
            versions = [tuple(map(int, STABLE.fullmatch(tag).groups())) for tag in tags if STABLE.fullmatch(tag)]
            major, minor, patch = max(versions, default=(0, 1, -1))
            version = f"{major}.{minor}.{patch + 1}"
        result.update(run="true", version=version, publish="true", notarize="true")
        return result, "Release the tested main commit with the next patch version"
    if event_name == "push":
        tag = event.get("ref", "").removeprefix("refs/tags/")
        version = tag.removeprefix("v")
        if not event.get("ref", "").startswith("refs/tags/v") or not VERSION.fullmatch(version):
            raise ValueError("Expected a semantic version tag")
        if tag in releases:
            return result, "This tag already has a release; nothing to publish"
        result.update(run="true", version=version, publish="true", notarize="true")
        return result, "Release the explicitly tagged and CI-verified commit"
    if event_name == "workflow_dispatch":
        inputs = event.get("inputs", {})
        version = inputs.get("version") or f"0.0.0-dev+{source[:12]}"
        if not VERSION.fullmatch(version):
            raise ValueError("Invalid manual build version")
        notarize = inputs.get("notarize") in (True, "true")
        result.update(run="true", version=version, notarize=str(notarize).lower())
        return result, "Manual validation build only; it will not tag or publish"
    raise ValueError("Unsupported release event")


def api(repo, endpoint):
    return json.loads(subprocess.check_output(["gh", "api", f"repos/{repo}/{endpoint}"], text=True))


def main():
    repo = os.environ["GITHUB_REPOSITORY"]
    name = os.environ["GITHUB_EVENT_NAME"]
    with open(os.environ["GITHUB_EVENT_PATH"]) as stream:
        event = json.load(stream)
    source = event["workflow_run"]["head_sha"] if name == "workflow_run" else os.environ["GITHUB_SHA"]
    if name == "push":
        tag = event["ref"].removeprefix("refs/tags/")
        if not tag.startswith("v") or not VERSION.fullmatch(tag[1:]):
            raise SystemExit("Expected a semantic version tag")
        source = api(repo, "commits/" + tag)["sha"]
        # A manually pushed tag must not bypass the same exact-commit CI requirement.
        runs = api(repo, f"actions/runs?head_sha={source}&event=push&status=completed&per_page=100")["workflow_runs"]
        if not any(r["name"] == "CI" and r["head_branch"] == "main"
                   and r["head_sha"] == source and r["conclusion"] == "success" for r in runs):
            raise SystemExit("Tagged source must have successful main CI before release")
    main_sha = api(repo, "commits/main")["sha"]
    # Paginate tags: old or prerelease tags must not cause version reuse.
    raw_tags = subprocess.check_output(["gh", "api", "--paginate", f"repos/{repo}/tags?per_page=100",
                                       "--jq", '.[] | [.name, .commit.sha] | @tsv'], text=True)
    tags = dict(line.split("\t", 1) for line in raw_tags.splitlines())
    raw_releases = subprocess.check_output(["gh", "api", "--paginate", f"repos/{repo}/releases?per_page=100",
                                           "--jq", '.[].tag_name'], text=True)
    releases = set(raw_releases.splitlines())
    result, reason = plan(name, event, source, main_sha, tags, releases, repo)
    with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
        for key, value in result.items():
            stream.write(f"{key}={value}\n")
    print(reason)
    if result["run"] == "true":
        print(f"Source: {source}; version: {result['version']}; publish: {result['publish']}")


if __name__ == "__main__":
    main()
