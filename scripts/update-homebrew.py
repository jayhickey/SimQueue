#!/usr/bin/env python3
"""Update a tap atomically after a stable release; token is supplied via GH_TOKEN."""
import base64
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path


def update_files(formula, cask, version, checksum, source):
    if not re.fullmatch(r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)", version):
        raise ValueError("Homebrew updates require a stable semantic version")
    if not re.fullmatch(r"[0-9a-f]{64}", checksum):
        raise ValueError("Invalid archive checksum")
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", source):
        raise ValueError("Invalid source repository")

    def replace(pattern, value, text):
        result, count = re.subn(pattern, lambda _: value, text, flags=re.MULTILINE)
        if count != 1:
            raise ValueError(f"Expected exactly one match: {pattern}")
        return result

    old = re.search(r'^  version "(\d+\.\d+\.\d+)"$', cask, re.MULTILINE)
    if not old:
        raise ValueError("Missing stable cask version")
    numbers = lambda v: tuple(map(int, v.split('.')))
    if numbers(old[1]) > numbers(version):
        raise ValueError("Refusing to downgrade the tap")
    url = f"https://github.com/{source}/releases/download/v{version}/simqueue-{version}-macos-arm64.tar.gz"
    formula = replace(r'^  url "[^"]+"$', f'  url "{url}"', formula)
    formula = replace(r'^  sha256 "[0-9a-f]{64}"$', f'  sha256 "{checksum}"', formula)
    formula = re.sub(r'^  revision \d+\n', '', formula, flags=re.MULTILINE)
    cask = replace(r'^  version "[^"]+"$', f'  version "{version}"', cask)
    cask = replace(r'^  sha256 "[0-9a-f]{64}"$', f'  sha256 "{checksum}"', cask)
    if not re.search(r"^  auto_updates true$", cask, re.MULTILINE):
        cask = replace(r'^  sha256 "[0-9a-f]{64}"$', f'  sha256 "{checksum}"\n\n  auto_updates true', cask)
    cask = cask.replace(
        '    This app is ad-hoc signed and is not notarized. macOS may require explicit\n'
        '    approval under its normal security policy. Do not disable Gatekeeper.',
        '    This app is Developer ID signed and notarized by Apple.')
    return formula, cask


def api(path, payload=None):
    args = ['gh', 'api', path]
    if payload is not None:
        args += ['--method', 'POST', '--input', '-']
    result = subprocess.run(args, input=json.dumps(payload) if payload is not None else None,
                            text=True, capture_output=True, check=True)
    return json.loads(result.stdout)


def publish(tap, source, version, archive):
    if not re.fullmatch(r'[\w.-]+/[\w.-]+', tap):
        raise ValueError('Invalid tap repository')
    checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
    line = Path(str(archive) + '.sha256').read_text().split()
    if len(line) != 2 or line != [checksum, archive.name]:
        raise ValueError('Archive checksum does not match')
    prefix = f'repos/{tap}'
    branch = api(prefix)['default_branch']
    parent = api(f'{prefix}/git/ref/heads/{branch}')['object']['sha']
    commit = api(f'{prefix}/git/commits/{parent}')
    paths = ['Formula/simqueue.rb', 'Casks/simqueue-app.rb']
    files = [api(f'{prefix}/contents/{p}?ref={parent}') for p in paths]
    originals = [base64.b64decode(f['content']).decode() for f in files]
    updated = update_files(*originals, version, checksum, source)
    entries = []
    for path, before, after in zip(paths, originals, updated):
        if before != after:
            blob = api(f'{prefix}/git/blobs', {'content': after, 'encoding': 'utf-8'})
            entries.append({'path': path, 'mode': '100644', 'type': 'blob', 'sha': blob['sha']})
    if not entries:
        print('Homebrew already matches the release')
        return
    tree = api(f'{prefix}/git/trees', {'base_tree': commit['tree']['sha'], 'tree': entries})
    new = api(f'{prefix}/git/commits', {'message': f'Update SimQueue to {version}',
                                     'tree': tree['sha'], 'parents': [parent]})
    # Fast-forward only: concurrent tap edits must never be overwritten.
    subprocess.run(['gh', 'api', f'{prefix}/git/refs/heads/{branch}', '--method', 'PATCH',
                    '--input', '-'], input=json.dumps({'sha': new['sha'], 'force': False}),
                   text=True, capture_output=True, check=True)
    print(f'Updated Homebrew formula and cask: https://github.com/{tap}/commit/{new["sha"]}')


if __name__ == '__main__':
    publish(sys.argv[1], sys.argv[2], sys.argv[3], Path(sys.argv[4]))
