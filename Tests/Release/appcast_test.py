#!/usr/bin/env python3
"""Feed metadata checks; cryptographic verification uses Apple's CryptoKit separately."""
import base64
import importlib.util
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('appcast', ROOT / 'scripts/create-appcast.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class AppcastTests(unittest.TestCase):
    def test_feed_targets_exact_stable_archive_and_includes_signature(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / 'SimQueue-1.2.3.zip'
            archive.write_bytes(b'test archive')
            signature = base64.b64encode(bytes(64)).decode()
            tree = ET.fromstring(module.create('1.2.3', archive, signature, 'example/queue'))
            enclosure = tree.find('./channel/item/enclosure')
            self.assertEqual(enclosure.get('url'), 'https://github.com/example/queue/releases/download/v1.2.3/SimQueue-1.2.3.zip')
            self.assertEqual(enclosure.get('length'), str(archive.stat().st_size))
            self.assertEqual(enclosure.get(f'{{{module.SPARKLE}}}edSignature'), signature)
            self.assertEqual(tree.findtext(f'./channel/item/{{{module.SPARKLE}}}version'), '1.2.3')
            self.assertEqual(tree.findtext(f'./channel/item/{{{module.SPARKLE}}}minimumSystemVersion'), '14.0')
            for version, sig, repo in [('1.2.3-beta', signature, 'example/queue'), ('1.2.3', 'bad', 'example/queue'), ('1.2.3', signature, '../queue'), ('2.0.0', signature, 'example/queue')]:
                with self.subTest(version=version, repo=repo):
                    with self.assertRaises(ValueError):
                        module.create(version, archive, sig, repo)


if __name__ == '__main__':
    unittest.main()
