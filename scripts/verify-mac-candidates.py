#!/usr/bin/env python3
"""Verify pinned research references without fetching or executing upstream code."""
import configparser
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def verify(root=ROOT):
    manifest = json.loads((root / 'research/mac-candidates/manifest.json').read_text())
    modules = configparser.ConfigParser(interpolation=None)
    modules.read(root / '.gitmodules')
    entries = subprocess.check_output(['git', 'ls-files', '--stage', '-z'], cwd=root).decode().split('\0')
    index = {}
    for entry in filter(None, entries):
        metadata, path = entry.split('\t', 1)
        mode, sha, stage = metadata.split()
        if stage != '0':
            raise ValueError('Unmerged index')
        index[path] = (mode, sha)
    seen = set()
    checked_out = 0
    for record in manifest['repositories']:
        repo, path, sha = record['repository'], record['path'], record['commit']
        if path != 'research/mac-candidates/sources/' + repo.replace('/', '--') or path in seen:
            raise ValueError('Invalid or duplicate source path: ' + path)
        seen.add(path)
        if not re.fullmatch(r'[0-9a-f]{40}', sha):
            raise ValueError('Invalid revision: ' + repo)
        if index.get(path) != ('160000', sha):
            raise ValueError('Gitlink mismatch: ' + repo)
        section = modules['submodule "' + path + '"']
        if section['path'] != path or section['url'] != 'https://github.com/' + repo + '.git' or section['url'] != record['url']:
            raise ValueError('Submodule URL/path mismatch: ' + repo)
        checkout = root / path
        if not (checkout / '.git').exists():
            continue
        head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=checkout).decode().strip()
        if head != sha:
            raise ValueError('Checkout revision mismatch: ' + repo)
        for doc in record['root_documents']:
            name = doc['path']
            if '/' in name or name in ('.', '..'):
                raise ValueError('Invalid root document path')
            data = (checkout / name).read_bytes()
            digest = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
            if digest != doc['blob'] or len(data) != doc['size']:
                raise ValueError('Document hash mismatch: ' + repo + '/' + name)
        checked_out += 1
    actual = {p for p, (mode, _) in index.items() if p.startswith('research/mac-candidates/sources/') and mode == '160000'}
    if actual != seen:
        raise ValueError('Unregistered research gitlinks')
    return len(seen), checked_out

if __name__ == '__main__':
    count, checked = verify()
    print(f'Verified {count} pinned references; {checked} local checkouts and their root document hashes. No upstream code executed.')
