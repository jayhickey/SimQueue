#!/usr/bin/env python3
import base64
import hashlib
import json
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import patch

module = runpy.run_path(str(Path(__file__).resolve().parents[2] / 'scripts/update-homebrew.py'))
update = module['update_files']
FORMULA = 'class Simqueue < Formula\n  url "https://example/old"\n  sha256 "' + 'a' * 64 + '"\n  revision 1\n  service do\n  end\nend\n'
CASK = 'cask "simqueue-app" do\n  version "0.1.5"\n  sha256 "' + 'a' * 64 + '"\n  app "simqueue-#{version}-macos-arm64/SimQueue.app"\nend\n'


class HomebrewTests(unittest.TestCase):
    def test_updates_both_and_preserves_installation(self):
        formula, cask = update(FORMULA, CASK, '0.1.7', 'b' * 64, 'example/SimQueue')
        self.assertIn('/v0.1.7/simqueue-0.1.7-macos-arm64.tar.gz', formula)
        self.assertIn('  version "0.1.7"', cask)
        self.assertEqual(cask.count('  auto_updates true'), 1)
        self.assertIn('b' * 64, formula)
        self.assertIn('b' * 64, cask)
        self.assertNotIn('revision', formula)
        self.assertIn('service do', formula)
        self.assertIn('app "simqueue-#{version}', cask)
        self.assertEqual(update(formula, cask, '0.1.7', 'b' * 64, 'example/SimQueue'), (formula, cask))

    def test_rejects_invalid_inputs_and_downgrades(self):
        for version in ['0.1.4', '0.1.7-beta', '01.1.7', '0.1.7\nmalicious']:
            with self.assertRaises(ValueError):
                update(FORMULA, CASK, version, 'b' * 64, 'example/SimQueue')
        with self.assertRaises(ValueError):
            update(FORMULA, CASK, '0.1.7', 'bad', 'example/SimQueue')

    def test_unknown_or_ambiguous_layout_fails(self):
        for formula in ['', FORMULA + '  sha256 "' + 'a' * 64 + '"\n']:
            with self.assertRaises(ValueError):
                update(formula, CASK, '0.1.7', 'b' * 64, 'example/SimQueue')

    def test_single_atomic_commit_and_nonforcing_push(self):
        calls = []
        def api(path, payload=None):
            calls.append((path, payload))
            if path == 'repos/example/tap': return {'default_branch': 'main'}
            if '/git/ref/' in path: return {'object': {'sha': 'parent'}}
            if path.endswith('/git/commits/parent'): return {'tree': {'sha': 'tree'}}
            if '/contents/' in path:
                text = FORMULA if 'Formula/' in path else CASK
                return {'content': base64.b64encode(text.encode()).decode()}
            return {'sha': 'new'}
        with tempfile.TemporaryDirectory() as root:
            archive = Path(root) / 'simqueue-0.1.7-macos-arm64.tar.gz'
            archive.write_bytes(b'archive')
            checksum = hashlib.sha256(b'archive').hexdigest()
            Path(str(archive) + '.sha256').write_text(checksum + '  ' + archive.name + '\n')
            with patch.dict(module['publish'].__globals__, api=api), patch('subprocess.run') as run:
                module['publish']('example/tap', 'example/SimQueue', '0.1.7', archive)
                self.assertEqual(json.loads(run.call_args.kwargs['input']), {'sha': 'new', 'force': False})
            commit = [p for path, p in calls if path.endswith('/git/commits')][0]
            self.assertEqual(commit['parents'], ['parent'])
            tree = [p for path, p in calls if path.endswith('/git/trees')][0]
            self.assertEqual(len(tree['tree']), 2)
            Path(str(archive) + '.sha256').write_text('bad')
            with patch.dict(module['publish'].__globals__, api=api), self.assertRaises(ValueError):
                module['publish']('example/tap', 'example/SimQueue', '0.1.7', archive)


if __name__ == '__main__':
    unittest.main()
