#!/usr/bin/env python3
"""Explicit, disposable hosted-Mac experiment. Never run on a working Mac."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import selectors
import shutil
import signal
import subprocess
import tempfile
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
STOCK = '/System/Volumes/VM/swapfile'
MIB = 1024 * 1024


def command(args, timeout=20):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout)


def sysctl(name):
    result = command(['/usr/sbin/sysctl', '-n', name])
    if result.returncode: raise OSError('Cannot read ' + name)
    return result.stdout.strip()


def workload_mib(ram):
    return max(0, min(ram * 85 // 100, ram - 2048 * MIB, 12288 * MIB) // (64 * MIB) * 64)


def evidence_module():
    spec = importlib.util.spec_from_file_location('mac_evidence', ROOT / 'scripts/mac-swap-evidence.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


def page_io(line, target, device):
    event = re.search(r'\b(PgOut|PgIn)(?:\[[^\]]*\])?\s+.*?\bB=0x([0-9a-fA-F]+)\s+(/dev/\S+)\s+(\S+)', line)
    if not event or event[3] != '/dev/' + device: return None
    paths = (str(target) + '/swapfile', '/System/Volumes/Data' + str(target) + '/swapfile')
    if not any(re.fullmatch(re.escape(prefix) + r'[0-9]+', event[4]) for prefix in paths): return None
    thread = re.search(r'\.(\d+)\s*$', line)
    return {'direction': 'out' if event[1] == 'PgOut' else 'in',
            'bytes': int(event[2], 16), 'device': device, 'path': event[4],
            'thread_id': int(thread[1]) if thread else None}


class Trace:
    def __init__(self, target, device):
        self.lines = []
        self.page_lines = []
        self.counts = {'in': 0, 'out': 0}
        self.byte_counts = {'in': 0, 'out': 0}
        self.device = device
        self.target = str(target)
        self.process = subprocess.Popen(['/usr/bin/fs_usage', '-w', '-f', 'filesys'],
                                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        self.thread = threading.Thread(target=self.read, daemon=True); self.thread.start()
    def read(self):
        for line in self.process.stdout:
            text = line.decode(errors='replace').strip()
            event = page_io(text, self.target, self.device)
            if event:
                self.counts[event['direction']] += 1
                self.byte_counts[event['direction']] += event['bytes']
                if len(self.page_lines) < 200: self.page_lines.append(text[:2000])
            elif self.target in text and len(self.lines) < 40: self.lines.append(text[:2000])
    def stop(self):
        if self.process.poll() is None:
            os.killpg(self.process.pid, signal.SIGINT)
            try: self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL); self.process.wait(timeout=5)
        self.thread.join(timeout=2)
        self.process.stdout.close()
        return {'exit_code': self.process.returncode, 'target_lines': self.page_lines,
                'target_metadata_lines': self.lines, 'target_pageout_lines': self.counts['out'],
                'target_pagein_lines': self.counts['in'], 'observed_page_io_bytes': self.byte_counts,
                'workload_page_attribution': 'not_established',
                'page_line_limit': 200, 'metadata_line_limit': 40,
                'limitation': 'Observed trace events only; counts do not establish complete tracing or identify which allocation faulted.'}


def memory_trial(binary, maximum, env, report, persist, snapshot):
    process = subprocess.Popen([str(binary), str(maximum)], env=env, stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    report['workload_pid'] = process.pid
    selector = selectors.DefaultSelector(); selector.register(process.stdout, selectors.EVENT_READ)
    buffer = bytearray(); deadline = time.monotonic() + 150
    events = []
    try:
        while time.monotonic() < deadline:
            selected = selector.select(timeout=1)
            if not selected:
                if process.poll() is not None: break
                continue
            data = os.read(process.stdout.fileno(), 65536)
            if not data: break
            buffer.extend(data)
            if len(buffer) > 65536: raise ValueError('Memory probe frame too large')
            while b'\n' in buffer:
                line, _, remainder = buffer.partition(b'\n'); buffer = bytearray(remainder)
                event = json.loads(line)
                if event.get('event') == 'allocated':
                    report['bytes_touched'] = event['bytes']
                else:
                    events.append(event)
                    if len(events) > 4: raise ValueError('Unexpected memory probe events')
                if event.get('event') == 'ready':
                    report['before_verify'] = snapshot()
                    report['memory_events'] = list(events); persist()
                    process.stdin.write(b'verify\n'); process.stdin.flush()
                if event.get('event') == 'verified':
                    process.wait(timeout=10)
                    if process.returncode: raise OSError('Memory probe did not exit successfully')
                    report['memory_events'] = events
                    report['synthetic_integrity_verified'] = True
                    return
        raise OSError('Memory probe exited or timed out before integrity verification')
    finally:
        selector.close()
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL); process.wait(timeout=10)
        for stream in (process.stdin, process.stdout, process.stderr): stream.close()


def run(args):
    if not (platform.system() == 'Darwin' and os.geteuid() == 0
            and os.environ.get('GITHUB_ACTIONS') == 'true'
            and os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted'
            and os.environ.get('GITHUB_REPOSITORY') == 'EmotiveImpact/CLOUDSWAP'
            and os.environ.get('CLOUDSWAP_CI_PLACEMENT') == 'explicit-disposable-test'):
        raise SystemExit('Refused: this experiment requires an explicitly selected disposable hosted CI Mac')
    evidence = evidence_module()  # Fail before mutation if integration is missing.
    probe = args.probe.resolve(strict=True)
    if not os.access(probe, os.X_OK): raise SystemExit('Memory probe is not executable')
    report_path = args.report.resolve()
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report = {'schema_version': 2, 'scope': 'disposable_virtual_volume_placement',
              'host': {'os': platform.mac_ver()[0], 'architecture': platform.machine()},
              'native_external_swap_verified': False, 'cloud_swap_verified': False,
              'physical_disconnect_tested': False, 'synthetic_integrity_verified': False,
              'native_virtual_volume_paging_observed': False,
              'candidate_placement_observed': False, 'prefix_changed': False}
    def persist():
        temporary = report_path.with_suffix('.pending'); temporary.write_text(json.dumps(report, indent=2) + '\n')
        temporary.replace(report_path)
    mount = None; trace = None; changed = False; original = None
    try:
        original = sysctl('vm.swapfileprefix')
        usage = sysctl('vm.swapusage')
        report['original_prefix'] = original; report['initial_swap_usage'] = usage
        if original != STOCK or not re.search(r'total\s*=\s*0\.00M', usage):
            report['state'] = 'skipped_existing_or_unexpected_swap'; return report
        maximum = workload_mib(int(sysctl('hw.memsize')))
        if maximum < 256: raise ValueError('Insufficient reserved headroom')
        if shutil.disk_usage(os.environ['RUNNER_TEMP']).free < 8 * 1024 * MIB:
            report['state'] = 'skipped_insufficient_disk_headroom'; return report
        report['workload_limit_mib'] = maximum; persist()
        work = Path(tempfile.mkdtemp(prefix='cloudswap-placement-', dir=os.environ['RUNNER_TEMP']))
        mount = Path('/Volumes/CloudSwapLab-' + uuid.uuid4().hex[:10]); mount.mkdir(mode=0o700)
        image = work / 'swap-lab.sparseimage'
        create = command(['/usr/bin/hdiutil', 'create', '-size', '6g', '-type', 'SPARSE',
                          '-fs', 'APFS', '-volname', mount.name, str(image)], timeout=60)
        if create.returncode: raise OSError('Cannot create disposable APFS disk image: ' + create.stderr[:500])
        attach = command(['/usr/bin/hdiutil', 'attach', '-nobrowse', '-mountpoint', str(mount), str(image)], timeout=60)
        if attach.returncode or not os.path.ismount(mount): raise OSError('Disposable APFS mount failed')
        info = subprocess.run(['/usr/sbin/diskutil', 'info', '-plist', str(mount)], capture_output=True, timeout=20)
        if info.returncode: raise OSError('Cannot verify target volume')
        volume = plistlib.loads(info.stdout)
        report['volume'] = {key: volume.get(key) for key in ('DeviceIdentifier', 'FilesystemType', 'VolumeUUID', 'MountPoint')}
        if str(volume.get('FilesystemType', '')).lower() != 'apfs': raise ValueError('Target is not APFS')
        if os.stat(mount).st_dev == os.stat('/System/Volumes/VM').st_dev: raise ValueError('Target is not a separate volume')
        target = str(mount / 'swapfile')
        report['target_prefix'] = target; report['retained_image'] = str(image); persist()
        if sysctl('vm.swapfileprefix') != original or not re.search(r'total\s*=\s*0\.00M', sysctl('vm.swapusage')):
            report['state'] = 'skipped_swap_changed_during_setup'; return report
        # A command timeout or unexpected result must never lead to detaching a
        # possible live swap volume. Keep it mounted until runner teardown.
        changed = True
        report['prefix_change_attempted'] = True
        report['prefix_changed'] = None
        result = command(['/usr/sbin/sysctl', 'vm.swapfileprefix=' + target])
        report['prefix_change_exit_code'] = result.returncode
        current = sysctl('vm.swapfileprefix')
        report['prefix_changed'] = current == target
        if result.returncode or current != target:
            report['state'] = 'placement_control_rejected'; report['diagnostic'] = result.stderr[:500]; return report
        def snapshot():
            result = evidence.snapshot(str(mount))
            result['collector_changed_system_swap'] = result.pop('system_swap_modified')
            result['experiment_changed_system_swap'] = True
            return result
        report['before_workload'] = snapshot(); persist()
        trace = Trace(mount, volume['DeviceIdentifier'])
        memory_trial(probe, maximum, dict(os.environ), report, persist, snapshot)
        report['after_verify'] = snapshot()
        report['comparison'] = evidence.compare(report['before_workload'], report['after_verify'])
        report['candidate_placement_observed'] = report['comparison'].get('candidate_placement_observed', False)
        report['final_swap_usage'] = sysctl('vm.swapusage')
        report['state'] = 'candidate_observed' if report['candidate_placement_observed'] else 'no_candidate_observed'
        return report
    except Exception as error:
        report.update(state='experiment_failed', error_type=type(error).__name__, diagnostic=str(error)[:1000])
        return report
    finally:
        if trace:
            try: report['target_io_trace'] = trace.stop()
            except Exception: report['trace_cleanup_failed'] = True
        io = report.get('target_io_trace', {})
        report['native_virtual_volume_paging_observed'] = bool(
            report['candidate_placement_observed'] and report['synthetic_integrity_verified']
            and io.get('target_pageout_lines', 0) > 0 and io.get('target_pagein_lines', 0) > 0)
        if changed:
            # Restoring the prefix selects future files only. It does not drain
            # pages or make detachment safe, even after the workload exits.
            try:
                if sysctl('vm.swapfileprefix') == report.get('target_prefix'):
                    restore = command(['/usr/sbin/sysctl', 'vm.swapfileprefix=' + original])
                    report['prefix_restored'] = restore.returncode == 0 and sysctl('vm.swapfileprefix') == original
                else: report['prefix_restored'] = sysctl('vm.swapfileprefix') == original
            except Exception: report['prefix_restored'] = False
            report['volume_left_mounted_until_runner_teardown'] = True
        elif mount and os.path.ismount(mount):
            try:
                detached = command(['/usr/bin/hdiutil', 'detach', str(mount)])
                report['unused_volume_detached'] = detached.returncode == 0
            except Exception: report['unused_volume_detached'] = False
        persist()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ci-change-prefix-on-disposable-runner', action='store_true', required=True)
    parser.add_argument('--probe', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    result = run(args)
    print(json.dumps(result, indent=2))
    if result['state'] == 'experiment_failed' or result.get('prefix_restored') is False: raise SystemExit(1)


if __name__ == '__main__': main()
