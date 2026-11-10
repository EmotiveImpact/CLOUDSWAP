#!/usr/bin/env python3
"""Read-only inventory. Does not change swap, mounts, boot policy or drivers."""
import datetime
import json
import re
import subprocess

COMMANDS = {
    'architecture': ['/usr/bin/uname', '-m'],
    'darwin_release': ['/usr/bin/uname', '-r'],
    'kernel_build': ['/usr/bin/uname', '-v'],
    'macos_version': ['/usr/bin/sw_vers', '-productVersion'],
    'macos_build': ['/usr/bin/sw_vers', '-buildVersion'],
    'model': ['/usr/sbin/sysctl', '-n', 'hw.model'],
    'memory_bytes': ['/usr/sbin/sysctl', '-n', 'hw.memsize'],
    'page_bytes': ['/usr/sbin/sysctl', '-n', 'hw.pagesize'],
    'swapfileprefix': ['/usr/sbin/sysctl', '-n', 'vm.swapfileprefix'],
    'swap_usage': ['/usr/sbin/sysctl', '-n', 'vm.swapusage'],
}

def classify(code, stdout, stderr):
    if code == 0:
        return {'state': 'observed', 'value': stdout.strip()}
    message = stderr.lower()
    if 'operation not permitted' in message or 'permission denied' in message:
        state = 'access_denied'
    elif 'unknown oid' in message or 'unknown key' in message:
        state = 'not_exposed'
    else:
        state = 'unavailable'
    # Do not include arbitrary command stderr, hostnames or local paths.
    return {'state': state, 'exit_code': code}

def collect(run=subprocess.run):
    results = {}
    for name, command in COMMANDS.items():
        try:
            p = run(command, capture_output=True, text=True, timeout=10)
            result = classify(p.returncode, p.stdout, p.stderr)
            if name == 'kernel_build' and result['state'] == 'observed':
                match = re.search(r'xnu-([0-9.]+)', p.stdout)
                result = {'state': 'observed', 'xnu_version': match.group(1) if match else None,
                          'release_kernel': 'RELEASE_' in p.stdout}
            results[name] = result
        except (OSError, subprocess.TimeoutExpired):
            results[name] = {'state': 'unavailable'}
    return {'schema_version': 1, 'collected_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'observations': results, 'system_swap_modified': False,
            'external_swap_verified': False, 'cloud_swap_verified': False,
            'capability_verdict': 'unverified',
            'manual_evidence_needed': ['startup security policy', 'physical or virtual machine',
                'external drive protocol and filesystem', 'actual target-volume paging traces']}

if __name__ == '__main__':
    print(json.dumps(collect(), indent=2))
