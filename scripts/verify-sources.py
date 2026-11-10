"""Verify extracted upstream bytes against pinned Git blob IDs."""
import hashlib
import json
from pathlib import Path
root = Path(__file__).resolve().parents[1] / 'research'
count = 0
for name in ('s3backer', 'Infiniswap'):
    manifest = json.loads((root / f'{name}-manifest.json').read_text())
    for entry in manifest['files']:
        data = (root / 'upstream' / name / entry['path']).read_bytes()
        actual = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
        if actual != entry['sha']:
            raise SystemExit(f'Hash mismatch: {name}/{entry["path"]}')
        count += 1
print(f'Verified {count} upstream blobs')
