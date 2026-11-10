#!/usr/bin/env python3
"""Verify the pinned source checkouts; does not execute upstream code."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--sources', type=Path, default=root / 'research/kernel-sources')
a = p.parse_args()
manifest = json.loads((root / 'research/kernel/sources.json').read_text())
for entry in manifest['repositories']:
    directory = a.sources / entry['name']
    def git(*args):
        return subprocess.check_output(['git', '-C', str(directory), *args], text=True).strip()
    if git('rev-parse', 'HEAD') != entry['commit']:
        raise SystemExit('Revision mismatch: ' + entry['name'])
    if git('status', '--porcelain', '--untracked-files=all'):
        raise SystemExit('Modified checkout: ' + entry['name'])
    licence = (directory / entry['licence_file']).read_bytes()
    if hashlib.sha256(licence).hexdigest() != entry['licence_sha256']:
        raise SystemExit('Licence mismatch: ' + entry['name'])
    if len(git('ls-files').splitlines()) != entry['tracked_files']:
        raise SystemExit('File-count mismatch: ' + entry['name'])
    print('Verified', entry['name'], entry['commit'], entry['tracked_files'], 'tracked files')
