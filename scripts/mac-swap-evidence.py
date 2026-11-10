#!/usr/bin/env python3
"""Read-only swap-placement observations. Never configures swap or induces pressure."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import time

COMMANDS = {
    'prefix': ['/usr/sbin/sysctl', '-n', 'vm.swapfileprefix'],
    'boot_session': ['/usr/sbin/sysctl', '-n', 'kern.bootsessionuuid'],
    'vm_stat': ['/usr/bin/vm_stat'],
}

def observe(command, run=subprocess.run):
    try:
        result = run(command, capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return {'state': 'unavailable'}
    if result.returncode:
        denied = any(s in result.stderr.lower() for s in ('permission denied', 'operation not permitted'))
        return {'state': 'access_denied' if denied else 'unavailable'}
    return {'state': 'observed', 'value': result.stdout.strip()}

def counters(text):
    page = re.search(r'page size of (\d+) bytes', text)
    values = {k.lower(): int(v) for k, v in re.findall(r'^(Swapins|Swapouts):\s+(\d+)\.?\s*$', text, re.M)}
    if not page or set(values) != {'swapins', 'swapouts'}:
        return {'state': 'unavailable'}
    return {'state': 'observed', 'page_bytes': int(page.group(1)), **values}

def inventory(directory, basename='swapfile'):
    """Read names and metadata through a directory FD; never open a swap file."""
    fd = None
    try:
        fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        start = os.fstat(fd)
        files = []
        rejected = 0
        with os.scandir(fd) as entries:
            for i, entry in enumerate(entries):
                if i >= 4096:
                    return {'state': 'too_many_entries'}
                if not re.fullmatch(re.escape(basename) + r'\d+', entry.name):
                    continue
                item = entry.stat(follow_symlinks=False)
                if not stat.S_ISREG(item.st_mode):
                    rejected += 1
                    continue
                files.append({'name': entry.name, 'inode': item.st_ino, 'device': item.st_dev,
                              'logical_bytes': item.st_size, 'allocated_bytes': item.st_blocks * 512})
        end = os.stat(directory, follow_symlinks=False)
        if (start.st_dev, start.st_ino) != (end.st_dev, end.st_ino):
            return {'state': 'directory_changed'}
        return {'state': 'observed', 'device': start.st_dev, 'inode': start.st_ino,
                'files': sorted(files, key=lambda x: x['name']), 'rejected_entries': rejected,
                'allocated_bytes': sum(f['allocated_bytes'] for f in files)}
    except PermissionError:
        return {'state': 'access_denied'}
    except OSError:
        return {'state': 'unavailable'}
    finally:
        if fd is not None:
            os.close(fd)

def snapshot(directory, run=subprocess.run):
    prefix = observe(COMMANDS['prefix'], run)
    boot = observe(COMMANDS['boot_session'], run)
    if boot['state'] == 'observed':
        if not boot['value']:
            boot = {'state': 'unavailable'}
        else:
            boot['value'] = hashlib.sha256(boot['value'].encode()).hexdigest()
    vm = observe(COMMANDS['vm_stat'], run)
    target = os.path.abspath(directory)
    matched = False
    basename = 'swapfile'
    if prefix['state'] == 'observed' and os.path.isabs(prefix['value']):
        matched = os.path.realpath(os.path.dirname(prefix['value'])) == os.path.realpath(target)
        if matched:
            basename = os.path.basename(prefix['value'])
    return {'schema_version': 1, 'sample_monotonic_ns': time.monotonic_ns(),
            'target': target, 'boot_session': boot, 'prefix': prefix, 'prefix_matches_target': matched,
            'directory': inventory(target, basename),
            'paging': counters(vm['value']) if vm['state'] == 'observed' else vm,
            'system_swap_modified': False, 'native_external_swap_verified': False}

def compare(before, after):
    issues = []
    for label, report in [('before', before), ('after', after)]:
        if report.get('schema_version') != 1:
            issues.append(label + ':unsupported_schema')
        for field in ('boot_session', 'prefix', 'directory', 'paging'):
            if report.get(field, {}).get('state') != 'observed':
                issues.append(label + ':' + field + '_unavailable')
        if not report.get('prefix_matches_target'):
            issues.append(label + ':prefix_not_on_target')
        if report.get('directory', {}).get('rejected_entries', 0):
            issues.append(label + ':nonregular_swap_entries')
    if issues:
        return {'state': 'insufficient_evidence', 'reasons': issues, 'native_external_swap_verified': False}
    if before['boot_session']['value'] != after['boot_session']['value']:
        issues.append('different_boot_session')
    if before['prefix']['value'] != after['prefix']['value']:
        issues.append('prefix_changed_during_interval')
    if after['sample_monotonic_ns'] <= before['sample_monotonic_ns']:
        issues.append('samples_not_in_order')
    for field in ('device', 'inode'):
        if before['directory'][field] != after['directory'][field]:
            issues.append('target_' + field + '_changed')
    if before['paging']['page_bytes'] != after['paging']['page_bytes']:
        issues.append('page_size_changed')
    delta = {k: after['paging'][k] - before['paging'][k] for k in ('swapins', 'swapouts')}
    if any(v < 0 for v in delta.values()):
        issues.append('paging_counters_reset')
    if issues:
        return {'state': 'incomparable', 'reasons': issues, 'native_external_swap_verified': False}
    old = {(f['device'], f['inode']) for f in before['directory']['files']}
    new = [f['name'] for f in after['directory']['files'] if (f['device'], f['inode']) not in old]
    growth = after['directory']['allocated_bytes'] - before['directory']['allocated_bytes']
    return {'state': 'observed', 'paging_page_delta': delta, 'new_file_names': new,
            'target_allocated_byte_delta': growth,
            'candidate_placement_observed': delta['swapouts'] > 0 and bool(new or growth > 0),
            'native_external_swap_verified': False,
            'limitation': 'System-wide counters and file metadata cannot attribute page I/O to this volume or prove it is external. Target I/O traces and workload integrity evidence remain required.'}

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='operation', required=True)
    snap = sub.add_parser('snapshot')
    snap.add_argument('--directory', required=True)
    diff = sub.add_parser('compare')
    diff.add_argument('before', type=Path)
    diff.add_argument('after', type=Path)
    args = parser.parse_args()
    if args.operation == 'snapshot':
        report = snapshot(args.directory)
    else:
        report = compare(json.loads(args.before.read_text()), json.loads(args.after.read_text()))
    print(json.dumps(report, indent=2))
