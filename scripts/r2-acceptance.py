#!/usr/bin/env python3
"""Bounded synthetic R2 acceptance; never alters system swap or logs credentials."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import time

REQUIRED = ('R2_ENDPOINT', 'R2_BUCKET', 'R2_ACCESS_KEY_ID', 'R2_SECRET_ACCESS_KEY')
PROBES = (
    ('object_roundtrip', '--live', 'Verified 16384 synthetic bytes.'),
    ('pager_reopen', '--pager-live', 'PASS: encrypted remote page recovered after pager reopen.'),
)


def readiness(environment):
    missing = [name for name in REQUIRED if not environment.get(name, '').strip()]
    return {'schema_version': 1, 'scope': 'live_r2_synthetic_storage',
            'configured': not missing, 'missing_variables': missing,
            'state': 'ready' if not missing else 'configuration_unavailable',
            'live_r2_tested': False, 'passed': False,
            'system_swap_modified': False, 'cloud_system_swap_verified': False,
            'physical_disconnect_tested': False, 'probes': []}


def acceptance(helper, environment, report, persist, runner=subprocess.run):
    if not report['configured']:
        return 2
    helper = Path(helper).resolve(strict=True)
    if not os.access(helper, os.X_OK):
        raise ValueError('Helper must be executable')
    report['helper_sha256'] = hashlib.sha256(helper.read_bytes()).hexdigest()
    report['host'] = {'system': platform.system(), 'architecture': platform.machine(),
                      'macos': platform.mac_ver()[0]}
    report['state'] = 'running'
    report['live_r2_tested'] = True  # Attempted, not necessarily successful.
    persist()
    for name, flag, marker in PROBES:
        probe = {'name': name, 'passed': False, 'cleanup_confirmed': False}
        report['probes'].append(probe)
        persist()
        started = time.monotonic()
        try:
            result = runner([str(helper), flag], env=environment, capture_output=True,
                            text=True, timeout=120, check=False)
            probe['exit_code'] = result.returncode
            probe['passed'] = result.returncode == 0 and marker in result.stdout
            # Both known helper entrypoints only return success after cleanup.
            probe['cleanup_confirmed'] = probe['passed']
            if probe['passed']:
                probe['verified_synthetic_bytes'] = 16384
            else:
                probe['failure'] = 'helper_failed_or_missing_verification'
        except subprocess.TimeoutExpired:
            probe['failure'] = 'timeout_cleanup_unconfirmed'
        except OSError:
            probe['failure'] = 'helper_could_not_start'
        probe['elapsed_seconds'] = round(time.monotonic() - started, 3)
        if not probe['passed']:
            report['state'] = 'failed'
            persist()
            return 1
        persist()
    report['state'] = 'passed'
    report['passed'] = True
    persist()
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', required=True, type=Path)
    parser.add_argument('--readiness-only', action='store_true')
    parser.add_argument('--helper', type=Path)
    args = parser.parse_args()
    if not args.readiness_only and not args.helper:
        parser.error('--helper is required for a live test')
    report = readiness(os.environ)
    args.report.parent.mkdir(parents=True, exist_ok=True)

    def persist():
        temporary = args.report.with_suffix('.pending')
        temporary.write_text(json.dumps(report, indent=2) + '\n')
        temporary.replace(args.report)

    persist()
    if args.readiness_only:
        if os.environ.get('GITHUB_OUTPUT'):
            with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
                output.write('configured=' + str(report['configured']).lower() + '\n')
        status = 0
    else:
        try:
            status = acceptance(args.helper, dict(os.environ), report, persist)
        except (OSError, ValueError):
            report['state'] = 'helper_unavailable'; persist(); status = 1
    # Helper stdout/stderr, URLs, bucket names and credential values are omitted.
    print(json.dumps(report, indent=2))
    raise SystemExit(status)


if __name__ == '__main__':
    main()
