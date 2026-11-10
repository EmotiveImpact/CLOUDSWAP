#!/usr/bin/env python3
"""Sparse-file lifecycle over real NFS; optional disposable Mac mount. No swap changes."""
import argparse
import hashlib
import json
import mmap
import os
from pathlib import Path
import platform
import secrets
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
from lab import NFSClient, Server, opaque, u32

GIB = 1024 ** 3
SHARD = 4 * 1024 ** 2
CHUNK = 65536
CAPACITY = 4 * GIB
OFFSETS = (0, SHARD - 17, GIB - CHUNK)


class StatusError(OSError):
    def __init__(self, code): self.code = code; super().__init__('NFS status ' + str(code))


def success(response):
    status = response.uint()
    if status: raise StatusError(status)
    return response


def attrs(size=None, mode=None, modified=None):
    value = u32(0) if mode is None else u32(1) + u32(mode)
    value += u32(0) + u32(0)  # uid, gid unchanged
    value += u32(0) if size is None else u32(1) + struct.pack('>Q', size)
    value += u32(0)  # atime unchanged
    value += u32(0) if modified is None else u32(2) + struct.pack('>II', *modified)
    return value


class Client(NFSClient):
    def root(self): return success(self.call(100005, 1, opaque(b'/'))).opaque()
    def create(self, root, name, size=None, how=1, verifier=None):
        body = opaque(root) + opaque(name.encode()) + u32(how)
        body += verifier if how == 2 else attrs(size=size, mode=0o600)
        reply = success(self.call(100003, 8, body))
        if reply.uint() != 1: raise ValueError('Missing created handle')
        return reply.opaque()
    def lookup(self, root, name): return success(self.call(100003, 3, opaque(root) + opaque(name.encode()))).opaque()
    def stat(self, handle):
        raw = success(self.call(100003, 1, opaque(handle))).take(84)
        v = struct.unpack('>IIIIIQQIIQQIIIIII', raw)
        return dict(kind=v[0], mode=v[1], size=v[5], used=v[6], fileid=v[10], modified=(v[13], v[14]))
    def resize(self, handle, size, mode=None, modified=None):
        return success(self.call(100003, 2, opaque(handle) + attrs(size, mode, modified) + u32(0)))
    def remove(self, root, name): return success(self.call(100003, 12, opaque(root) + opaque(name.encode())))
    def rename(self, root, old, new):
        return success(self.call(100003, 14, opaque(root) + opaque(old.encode()) + opaque(root) + opaque(new.encode())))
    def stats(self, root):
        reply = success(self.call(100003, 18, opaque(root))); reply.attr()
        return struct.unpack('>QQQQQQI', reply.take(52))


def server(binary, helper, mode, path, env):
    return Server(binary, helper, mode, path, env, flag='--sparse-lab', capacity=CAPACITY, kind='sparse-volume-v1')


def expect_status(code, operation):
    try: operation()
    except StatusError as error:
        if error.code != code: raise
    else: raise ValueError('Expected NFS status ' + str(code))


def payload(offset):
    return hashlib.shake_256(('CLOUDSWAP sparse file ' + str(offset)).encode()).digest(CHUNK)


def wire_trial(binary, helper, root, env):
    path = root / 'wire-store'
    running = server(binary, helper, 'local-create', path, env)
    client = None
    try:
        client = Client(running.port); directory = client.root()
        handle = client.create(directory, 'swapfile0', size=GIB)
        assert client.stat(handle)['size'] == GIB
        expect_status(17, lambda: client.create(directory, 'swapfile0', size=0))
        for offset in OFFSETS: client.write(handle, offset, payload(offset))
        client.commit(handle)
        for offset in OFFSETS: assert client.read(handle, offset, CHUNK)[0] == payload(offset)
        assert client.read(handle, 8 * SHARD, CHUNK)[0] == bytes(CHUNK)
        assert client.read(handle, 2 ** 64 - 1, 1) == (b'', True)
        # Exclusive CREATE must persist its verifier, not merely reject all retries.
        exclusive = client.create(directory, 'exclusive', how=2, verifier=b'12345678')
        assert client.create(directory, 'exclusive', how=2, verifier=b'12345678') == exclusive
        expect_status(17, lambda: client.create(directory, 'exclusive', how=2, verifier=b'87654321'))
        old_id = client.stat(handle)['fileid']
        client.rename(directory, 'swapfile0', 'renamed')
        client.rename(directory, 'renamed', 'exclusive')
        expect_status(70, lambda: client.stat(exclusive))
        handle = client.lookup(directory, 'exclusive')
        assert client.stat(handle)['fileid'] == old_id
        client.resize(handle, GIB, mode=0o640, modified=(1_600_000_000, 123456789))
        assert client.stat(handle)['mode'] == 0o640
        assert client.stat(handle)['modified'] == (1_600_000_000, 123456789)
        stats = client.stats(directory)
        assert stats[0] == CAPACITY and 0 < stats[1] < 256 * 1024 ** 2
        # Crash both real processes after FILE_SYNC/COMMIT; recover from disk.
        client.close(); client = None; running.stop(crash=True)
        running = server(binary, helper, 'local-open', path, env)
        client = Client(running.port); directory = client.root()
        handle = client.lookup(directory, 'exclusive')
        for offset in OFFSETS: assert client.read(handle, offset, CHUNK)[0] == payload(offset)
        client.resize(handle, 16387)
        client.resize(handle, GIB)
        expected = payload(0)[:16387] + bytes(CHUNK - 16387)
        assert client.read(handle, 0, CHUNK)[0] == expected
        for offset in OFFSETS[1:]: assert client.read(handle, offset, CHUNK)[0] == bytes(CHUNK)
        client.create(directory, 'exclusive', size=0, how=0)  # UNCHECKED truncation
        assert client.stat(handle)['size'] == 0
        client.remove(directory, 'exclusive')
        expect_status(70, lambda: client.stat(handle))
        replacement = client.create(directory, 'exclusive')
        assert client.stat(replacement)['fileid'] > old_id
        client.commit(replacement)
        return {'passed': True, 'sparse_size_bytes': GIB, 'payload_bytes_verified': len(OFFSETS) * CHUNK,
                'crash_reopen': True, 'shrink_regrow_zeroes': True, 'exclusive_retry': True,
                'rename_replacement_and_stale_handles': True, 'attributes_persisted': True,
                'quota_report_not_upstream_one_tib_default': True}
    finally:
        if client: client.close()
        running.stop()


def checkpoint_trial(binary, helper, root, env):
    path = root / 'rollback-store'
    running = server(binary, helper, 'local-create', path, env)
    client = None
    try:
        client = Client(running.port); handle = client.create(client.root(), 'a', size=GIB)
        index = path / 'catalogue.enc'; previous = index.read_bytes()
        client.write(handle, 0, b'committed')
        index.write_bytes(previous)
        try: client.commit(handle)
        except OSError: pass
        else: raise ValueError('Rolled-back catalogue acknowledged by COMMIT')
        try: client.read(handle, 128, 1)
        except OSError: pass
        else: raise ValueError('Failed session returned an unwritten hole')
        return {'passed': True, 'rollback_stopped_session': True}
    finally:
        if client: client.close()
        running.stop()


def mounted_worker(stage, path):
    flags = os.O_RDWR if stage in ('create', 'truncate') else os.O_RDONLY
    if stage == 'create': flags |= os.O_CREAT | os.O_EXCL
    fd = os.open(path, flags, 0o600)
    try:
        if stage == 'create':
            os.ftruncate(fd, GIB)
            for offset in OFFSETS:
                data = payload(offset)
                if os.pwrite(fd, data, offset) != len(data): raise ValueError('Short mounted write')
            with mmap.mmap(fd, CHUNK, access=mmap.ACCESS_WRITE) as mapped:
                mapped[16380:16420] = bytes(40)
                mapped.flush()
            os.fsync(fd)
            os.chmod(path, 0o640)
        if stage == 'truncate':
            os.ftruncate(fd, 17); os.ftruncate(fd, GIB); os.fsync(fd)
        truncated = stage in ('truncate', 'verify_truncated', 'pause')
        expected = bytearray(payload(0)); expected[16380:16420] = bytes(40)
        if truncated: expected[17:] = bytes(CHUNK - 17)
        with mmap.mmap(fd, CHUNK, access=mmap.ACCESS_READ) as mapped:
            if mapped[:] != expected: raise ValueError('Mounted mapped read differs')
        for offset in OFFSETS[1:]:
            data = bytes(CHUNK) if truncated else payload(offset)
            if os.pread(fd, CHUNK, offset) != data: raise ValueError('Mounted sparse tail differs')
        if os.pread(fd, CHUNK, 8 * SHARD) != bytes(CHUNK): raise ValueError('Sparse hole leaked data')
        stat = os.fstat(fd)
        if stat.st_size != GIB: raise ValueError('Sparse size lost')
        if stat.st_mode & 0o777 != 0o640: raise ValueError('Mode was not persisted')
        return {'passed': True, 'logical_size': GIB, 'payload_bytes_verified': len(OFFSETS) * CHUNK,
                'mmap_verified': True, 'truncated_tail_zeroed': truncated,
                # Darwin stat asks for va_total_alloc. NFSv3 only supplies
                # va_data_alloc, so VFS can synthesise this from logical size.
                # Measure actual backing files in the controller instead.
                'client_stat_allocated_bytes': stat.st_blocks * 512}
    finally: os.close(fd)


def backing_measurement(running, path):
    client = Client(running.port)
    try:
        handle = client.lookup(client.root(), 'swapfile0')
        client.commit(handle)
        allocation = client.stat(handle)['used']
    finally: client.close()
    if not 0 < allocation < 2 * 1024 ** 2:
        raise ValueError('Unexpected NFS committed payload allocation: ' + str(allocation))
    # Synthetic private directory; include metadata, retained versions and
    # catalogue rather than counting only the currently referenced payload.
    inventory = [entry.stat(follow_symlinks=False) for entry in path.iterdir()]
    logical = sum(item.st_size for item in inventory)
    allocated = sum(item.st_blocks * 512 for item in inventory)
    if len(inventory) > 512 or logical >= 4 * 1024 ** 2 or allocated >= 4 * 1024 ** 2:
        raise ValueError(f'Sparse backing unexpectedly grew: {len(inventory)} objects, '
                         f'{logical} bytes, {allocated} allocated bytes')
    return {'nfs_committed_payload_bytes': allocation,
            'backing_files': len(inventory), 'backing_file_bytes': logical,
            'backing_allocated_bytes': allocated,
            'backing_includes_metadata_and_retired_objects': True,
            'backing_excludes_filesystem_directory_overhead': True}


def mount_trial(binary, helper, root, env, report):
    if platform.system() != 'Darwin': raise ValueError('Mac mount required')
    mountpoint = root / 'mount'; mountpoint.mkdir()
    running = None
    report.update(passed=False, system_swap_modified=False, live_r2=False)
    def unmount():
        if os.path.ismount(mountpoint):
            result = subprocess.run(['sudo', '-n', '/sbin/umount', '-f', str(mountpoint)], capture_output=True, timeout=20)
            if result.returncode or os.path.ismount(mountpoint): raise OSError('Lab unmount failed')
    try:
        for stage in ('create', 'verify', 'truncate', 'verify_truncated', 'pause'):
            report['active_stage'] = stage
            print('Sparse mounted stage: ' + stage, file=sys.stderr, flush=True)
            running = server(binary, helper, 'local-create' if stage == 'create' else 'local-open', root / 'mount-store', env)
            options = f'vers=3,tcp,nolocks,soft,timeo=10,retrans=1,rsize=65536,wsize=65536,actimeo=0,nosuid,nodev,port={running.port},mountport={running.port}'
            result = subprocess.run(['sudo', '-n', '/sbin/mount_nfs', '-o', options, '127.0.0.1:/', str(mountpoint)], capture_output=True, text=True, timeout=30)
            if result.returncode or not os.path.ismount(mountpoint): raise OSError('Sparse mount failed: ' + result.stderr[-1000:])
            paused = stage == 'pause'
            started = time.monotonic()
            if paused: os.killpg(running.process.pid, signal.SIGSTOP)
            worker = None
            try:
                worker = subprocess.Popen([sys.executable, __file__, '--worker', stage, str(mountpoint / 'swapfile0')],
                                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                if paused:
                    time.sleep(1)
                    premature = worker.poll() is not None
            finally:
                if paused: os.killpg(running.process.pid, signal.SIGCONT)
            try: stdout, stderr = worker.communicate(timeout=90)
            except subprocess.TimeoutExpired:
                unmount(); worker.kill(); worker.communicate(timeout=5); raise
            if worker.returncode: raise OSError('Mounted worker failed: ' + stderr[-1000:])
            if paused and premature: raise ValueError('Fresh read did not wait for the paused server')
            report[stage] = json.loads(stdout)
            report[stage].update(backing_measurement(running, root / 'mount-store'))
            if paused:
                report['pause_observation'] = {'server_pause_seconds': 1, 'blocked_until_resumed': True,
                    'worker_elapsed_seconds': round(time.monotonic() - started, 3), 'physical_wifi_drop': False}
            unmount(); running.stop(); running = None
        report.update(passed=True, fresh_mount_and_process_reopen=True)
        report.pop('active_stage')
        return report
    finally:
        unmount()
        if running: running.stop()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--server', type=Path)
    parser.add_argument('--helper', type=Path)
    parser.add_argument('--ci-mount', action='store_true')
    parser.add_argument('--report', type=Path)
    parser.add_argument('--worker', nargs=2)
    args = parser.parse_args()
    if args.worker:
        print(json.dumps(mounted_worker(*args.worker))); return
    if not args.server or not args.helper: parser.error('--server and --helper required')
    if args.ci_mount and not (os.environ.get('GITHUB_ACTIONS') == 'true'
            and os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted'
            and os.environ.get('GITHUB_REPOSITORY') == 'EmotiveImpact/CLOUDSWAP'):
        parser.error('Privileged mounts restricted to disposable CLOUDSWAP CI')
    root = Path(tempfile.mkdtemp(prefix='cloudswap-sparse-nfs-'))
    env = dict(os.environ, CLOUDSWAP_FILE_KEY_HEX=secrets.token_hex(32))
    report = {'schema_version': 1, 'synthetic_only': True, 'system_swap_modified': False,
              'live_r2': False, 'host': {'architecture': platform.machine(), 'macos': platform.mac_ver()[0]}}
    try:
        binary, helper = args.server.resolve(strict=True), args.helper.resolve(strict=True)
        report['wire'] = wire_trial(binary, helper, root, env)
        report['checkpoint'] = checkpoint_trial(binary, helper, root, env)
        if args.ci_mount:
            # Keep completed stages and the failing stage if a later operation
            # raises, so the saved artefact remains useful after cleanup.
            report['mount'] = {}
            mount_trial(binary, helper, root, env, report['mount'])
        report['passed'] = True
    except Exception as error:
        report.update(passed=False, error_type=type(error).__name__, diagnostic=str(error)[:1500])
    finally:
        if os.path.ismount(root / 'mount'): report['retained_directory'] = str(root)
        else: shutil.rmtree(root)
    text = json.dumps(report, indent=2)
    if args.report: args.report.write_text(text + '\n')
    print(text)
    if not report['passed']: raise SystemExit(1)


if __name__ == '__main__': main()
