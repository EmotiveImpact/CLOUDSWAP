#!/usr/bin/env python3
"""Verify that the vendored source matches its recorded provenance inventory."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parent
manifest = json.loads((root / 'UPSTREAM.json').read_text())
vendor = root / 'vendor' / 'nfsserve'
recorded = manifest['files']
actual = {str(p.relative_to(vendor)) for p in vendor.rglob('*') if p.is_file()}
if actual != set(recorded):
    raise SystemExit('Vendored source inventory differs from UPSTREAM.json')
for name, hashes in recorded.items():
    path = vendor / name
    if path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != hashes['vendored_sha256']:
        raise SystemExit('Vendored source hash mismatch: ' + name)
print('Verified', len(recorded), 'vendored files at upstream', manifest['commit'])
