#!/usr/bin/env python3
"""Exercise Sparkle's real parser against a temporary loopback metadata feed."""
import base64
import functools
import http.server
import json
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import threading

create = runpy.run_path(str(Path(__file__).resolve().parents[2] / 'scripts/create-appcast.py'))['create']
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    archive = root / 'SimQueue-9.9.9.zip'
    archive.write_bytes(b'metadata fixture, never install')
    (root / 'appcast.xml').write_bytes(create('9.9.9', archive, base64.b64encode(bytes(64)).decode(), 'example/queue'))
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=directory)
    with http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            url = f'http://127.0.0.1:{server.server_port}/appcast.xml'
            result = subprocess.run([sys.argv[1], sys.argv[2], url], text=True, capture_output=True, timeout=40)
            if result.returncode:
                raise RuntimeError(result.stdout + result.stderr)
            loaded = json.loads(result.stdout)
            assert loaded['versions'] == ['9.9.9'], loaded
            assert loaded['feed'] == url, loaded
            print('Sparkle loaded staged feed versions:', loaded['versions'])
        finally:
            server.shutdown()
