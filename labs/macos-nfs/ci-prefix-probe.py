#!/usr/bin/env python3
"""Disposable hosted-Mac probe: write only the unchanged stock swap prefix."""
import argparse
import json
import os
import platform
import subprocess

STOCK = '/System/Volumes/VM/swapfile'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ci', action='store_true', required=True)
    parser.parse_args()
    if not (platform.system() == 'Darwin' and os.geteuid() == 0
            and os.environ.get('GITHUB_ACTIONS') == 'true'
            and os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted'
            and os.environ.get('GITHUB_REPOSITORY') == 'EmotiveImpact/CLOUDSWAP'):
        parser.error('Restricted to an explicitly invoked disposable hosted CLOUDSWAP Mac job running as root')
    def read():
        result = subprocess.run(['/usr/sbin/sysctl', '-n', 'vm.swapfileprefix'],
                                capture_output=True, text=True, timeout=10)
        return result.stdout.strip() if result.returncode == 0 else None
    before = read()
    report = {'schema_version': 1, 'scope': 'unchanged_stock_prefix_write_probe',
              'prefix_before': before, 'write_attempted': False,
              'placement_tested': False, 'memory_pressure_applied': False}
    # Refuse an unexpected value; do not restore or redirect someone else's setup.
    if before != STOCK or read() != STOCK:
        report['state'] = 'skipped_unexpected_or_unreadable_prefix'
    else:
        result = subprocess.run(['/usr/sbin/sysctl', 'vm.swapfileprefix=' + STOCK],
                                capture_output=True, text=True, timeout=10)
        report.update(write_attempted=True, exit_code=result.returncode,
                      prefix_after=read(), diagnostic=result.stderr.strip()[:500])
        report['state'] = 'unchanged_write_accepted' if result.returncode == 0 else 'write_rejected'
        if report['prefix_after'] != STOCK:
            report['state'] = 'unexpected_prefix_after_probe'
            print(json.dumps(report, indent=2))
            raise SystemExit(1)
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
