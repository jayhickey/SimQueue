#!/usr/bin/env python3
"""Release control-flow checks with fake Apple tools; no signing credentials used."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

TOOL = '''#!/usr/bin/env python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["TOOL_LOG"], "a") as stream:
    stream.write(json.dumps([name] + args) + "\\n")
if name == "codesign" and "--display" in args:
    print("Authority=" + os.environ.get("FAKE_AUTHORITY", "Developer ID Application: Example"), file=sys.stderr)
    print("CodeDirectory flags=0x10000(runtime)", file=sys.stderr)
    print("Timestamp=Oct 21, 2026", file=sys.stderr)
if name == "ditto":
    pathlib.Path(args[-1]).write_bytes(b"fake archive")
if name == "xcrun" and args[:2] == ["notarytool", "submit"]:
    print(json.dumps({"status": os.environ.get("FAKE_NOTARY_STATUS", "Accepted"), "id": "test-submission"}))
if name == "xcrun" and args[:2] == ["stapler", "validate"] and os.environ.get("FAKE_STAPLE_FAIL"):
    sys.exit(1)
'''


class NotarizationTests(unittest.TestCase):
    def run_release(self, **overrides):
        temp = tempfile.TemporaryDirectory(prefix="simqueue-notary-test ")
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        release = root / "simqueue-1.2.3-macos-arm64"
        (release / "bin").mkdir(parents=True)
        helper_dir = release / "SimQueue.app/Contents/Helpers"
        helper_dir.mkdir(parents=True)
        helper = helper_dir / "simqd"
        helper.write_text("#!/bin/sh\necho 1.2.3\n")
        helper.chmod(0o700)
        for name in ("simq", "simqd"):
            executable = release / "bin" / name
            executable.write_text("#!/bin/sh\necho 1.2.3\n")
            executable.chmod(0o700)
        tools = root / "tools"
        tools.mkdir()
        for name in ("codesign", "xcrun", "ditto", "spctl"):
            tool = tools / name
            tool.write_text(TOOL)
            tool.chmod(0o700)
        log = root / "tools.jsonl"
        out = root / "out"
        env = {key: value for key, value in os.environ.items() if not key.startswith("SIMQ_")}
        env.update(PATH=str(tools) + os.pathsep + env["PATH"], TOOL_LOG=str(log),
                   SIMQ_SIGNING_IDENTITY="test-identity", SIMQ_NOTARY_PROFILE="test-profile")
        env.update(overrides)
        if env.get("FAKE_HELPER_VERSION"):
            helper.write_text("#!/bin/sh\necho " + env["FAKE_HELPER_VERSION"] + "\n")
        if env.get("FAKE_MISSING_HELPER"):
            helper.unlink()
        result = subprocess.run(["bash", str(ROOT / "scripts/notarize-release.sh"), "1.2.3", str(release), str(out)],
                                env=env, capture_output=True, text=True)
        calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        return result, calls, out

    def test_acceptance_staples_and_validates_before_archiving(self):
        result, calls, out = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        signs = [call for call in calls if call[0] == "codesign" and "--sign" in call]
        self.assertEqual(len(signs), 4)
        self.assertTrue(signs[0][-1].endswith("SimQueue.app/Contents/Helpers/simqd"))
        self.assertIn("dev.simqueue.app-daemon", signs[0])
        self.assertTrue(signs[-1][-1].endswith("SimQueue.app"))
        for call in signs:
            self.assertIn("--timestamp", call)
            self.assertEqual(call[call.index("--options") + 1], "runtime")
        staple = next(i for i, c in enumerate(calls) if c[:3] == ["xcrun", "stapler", "staple"])
        validate = next(i for i, c in enumerate(calls) if c[:3] == ["xcrun", "stapler", "validate"])
        assess = next(i for i, c in enumerate(calls) if c[0] == "spctl")
        self.assertLess(staple, validate)
        self.assertLess(validate, assess)
        self.assertTrue((out / "simqueue-1.2.3-macos-arm64.tar.gz.sha256").is_file())

    def test_rejection_never_staples_or_packages(self):
        result, calls, out = self.run_release(FAKE_NOTARY_STATUS="Invalid")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c[:2] == ["xcrun", "stapler"] for c in calls))
        self.assertFalse(list(out.glob("*.tar.gz")))

    def test_failed_staple_validation_never_packages(self):
        result, _, out = self.run_release(FAKE_STAPLE_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(list(out.glob("*.tar.gz")))

    def test_wrong_signing_identity_is_rejected_before_upload(self):
        result, calls, _ = self.run_release(FAKE_AUTHORITY="Apple Development: Example")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c[:2] == ["xcrun", "notarytool"] for c in calls))

    def test_missing_or_mismatched_helper_never_signs_or_publishes(self):
        for overrides in ({"FAKE_MISSING_HELPER": "1"}, {"FAKE_HELPER_VERSION": "0.0.0"}):
            with self.subTest(overrides=overrides):
                result, calls, out = self.run_release(**overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(calls)
                self.assertFalse(list(out.glob("*.tar.gz")))

    def test_missing_credentials_fail_before_signing(self):
        result, calls, _ = self.run_release(SIMQ_NOTARY_PROFILE="")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
