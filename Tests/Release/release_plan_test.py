#!/usr/bin/env python3
import runpy
from pathlib import Path
import unittest

plan = runpy.run_path(str(Path(__file__).resolve().parents[2] / "scripts/release-plan.py"))["plan"]
SOURCE = "a" * 40
OTHER = "b" * 40
REPO = "example/simqueue"


def event(**changes):
    run = dict(conclusion="success", event="push", head_branch="main", head_sha=SOURCE,
               head_repository=dict(full_name=REPO))
    run.update(changes)
    return {"workflow_run": run}


class ReleasePlanTests(unittest.TestCase):
    def test_successful_main_gets_next_patch_and_requires_notarization(self):
        result, _ = plan("workflow_run", event(), SOURCE, SOURCE,
                         {"v0.1.9": OTHER, "v0.1.10": OTHER, "v2.0.0-beta": OTHER}, set(), REPO)
        self.assertEqual(result["version"], "0.1.11")
        self.assertEqual(result["publish"], "true")
        self.assertEqual(result["notarize"], "true")
        self.assertEqual(result["source"], SOURCE)

    def test_failed_pull_request_or_foreign_ci_never_releases(self):
        for changes in [dict(conclusion="failure"), dict(event="pull_request"), dict(head_branch="feature"),
                        dict(head_repository=dict(full_name="other/simqueue"))]:
            result, _ = plan("workflow_run", event(**changes), SOURCE, SOURCE, {}, set(), REPO)
            self.assertEqual(result["run"], "false")

    def test_explicit_skip_release_does_not_publish(self):
        result, reason = plan("workflow_run", event(head_commit={"message": "Add icon [skip release]"}),
                              SOURCE, SOURCE, {}, set(), REPO)
        self.assertEqual(result["run"], "false")
        self.assertIn("skips", reason)

    def test_stale_ci_is_skipped(self):
        result, _ = plan("workflow_run", event(), SOURCE, OTHER, {}, set(), REPO)
        self.assertEqual(result["run"], "false")

    def test_retry_skips_published_source_or_recovers_unpublished_tag(self):
        tags = {"v0.1.5": SOURCE}
        result, _ = plan("workflow_run", event(), SOURCE, SOURCE, tags, {"v0.1.5"}, REPO)
        self.assertEqual(result["run"], "false")
        result, _ = plan("workflow_run", event(), SOURCE, SOURCE, tags, set(), REPO)
        self.assertEqual(result["version"], "0.1.5")

    def test_manual_runs_never_publish(self):
        for notarize in (True, False):
            result, _ = plan("workflow_dispatch", {"inputs": {"notarize": notarize}}, SOURCE, SOURCE, {}, set(), REPO)
            self.assertEqual(result["publish"], "false")
            self.assertEqual(result["notarize"], str(notarize).lower())
            self.assertEqual(result["version"], "0.0.0-dev+" + SOURCE[:12])

    def test_manual_validation_defaults_to_signed_and_notarized(self):
        result, _ = plan("workflow_dispatch", {"inputs": {}}, SOURCE, SOURCE, {}, set(), REPO)
        self.assertEqual(result["notarize"], "true")
        self.assertEqual(result["publish"], "false")

    def test_invalid_version_or_commit_is_rejected(self):
        with self.assertRaises(ValueError):
            plan("workflow_dispatch", {"inputs": {"version": "1.2.3\nsource=oops"}}, SOURCE, SOURCE, {}, set(), REPO)
        with self.assertRaises(ValueError):
            plan("workflow_run", event(), "bad", SOURCE, {}, set(), REPO)


if __name__ == "__main__":
    unittest.main()
