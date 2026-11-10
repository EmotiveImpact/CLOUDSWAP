#!/usr/bin/env python3
"""Synthetic-data NFS acceptance: real wire protocol, optional actual Mac mount."""
import argparse
import hashlib
import json
import mmap
import os
from pathlib import Path
import platform
import secrets
import select
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time

CAPACITY = 4 * 1024 * 1024
CHUNK = 65536


def u32(value): return struct.pack('>I', value)
def opaque(data): return u32(len(data)) + data + bytes((-len(data)) % 4)


class XDR:
    def __init__(self, data): self.data, self.offset = data, 0
    def take(self, length):
        if length < 0 or self.offset + length > len(self.data): raise ValueError('Truncated XDR')
        data = self.data[self.offset:self.offset + length]
        self.offset += length
        return data
    def uint(self): return struct.unpack('>I', self.take(4))[0]
    def opaque(self):
        length = self.uint()
        data = self.take(length)
        self.take((-length) % 4)
        return data
    def attr(self):
        if self.uint(): self.take(84)
    def wcc(self):
        if self.uint(): self.take(24)
        self.attr()


class NFSClient:
    def __init__(self, port):
        self.socket = socket.create_connection(('127.0.0.1', port), timeout=5)
        self.xid = 0
    def close(self): self.socket.close()
    def exact(self, length):
        data = bytearray()
        while len(data) < length:
            part = self.socket.recv(length - len(data))
            if not part: raise OSError('NFS connection closed')
            data.extend(part)
        return bytes(data)
    def call(self, program, procedure, body=b''):
        self.xid += 1
        request = b''.join(u32(x) for x in [self.xid, 0, 2, program, 3, procedure, 0, 0, 0, 0]) + body
        self.socket.sendall(u32(0x80000000 | len(request)) + request)
        return self.response(self.xid)
    def response(self, xid):
        data = bytearray()
        for _ in range(16):
            header = struct.unpack('>I', self.exact(4))[0]
            size = header & 0x7fffffff
            if len(data) + size > 131072: raise ValueError('Oversized NFS response')
            data.extend(self.exact(size))
            if header & 0x80000000: break
        else: raise ValueError('Too many NFS fragments')
        response = XDR(bytes(data))
        if response.uint() != xid or response.uint() != 1 or response.uint() != 0: raise ValueError('Bad RPC response')
        response.uint(); response.opaque()
        if response.uint() != 0: raise OSError('RPC request rejected')
        return response
    def handle(self):
        response = self.call(100005, 1, opaque(b'/'))
        if response.uint(): raise OSError('NFS mount negotiation failed')
        root = response.opaque()
        response = self.call(100003, 3, opaque(root) + opaque(b'pages'))
        if response.uint(): raise OSError('NFS lookup failed')
        return response.opaque()
    def read(self, handle, offset, count):
        response = self.call(100003, 6, opaque(handle) + struct.pack('>QI', offset, count))
        if response.uint(): raise OSError('NFS read failed')
        response.attr()
        length, eof = response.uint(), response.uint()
        data = response.opaque()
        if length != len(data): raise ValueError('Short NFS read')
        return data, bool(eof)
    def write(self, handle, offset, data):
        response = self.call(100003, 7, opaque(handle) + struct.pack('>QII', offset, len(data), 2) + opaque(data))
        return self.write_response(response, len(data))
    def write_response(self, response, length):
        if response.uint(): raise OSError('NFS write failed')
        response.wcc()
        if response.uint() != length or response.uint() != 2: raise ValueError('NFS write was not FILE_SYNC')
        return response.take(8)
    def pipelined_writes(self, handle, data):
        ids = []
        # Exceeds the server's input pipe while replies are pending. This catches
        # a bounded-queue deadlock that sequential clients cannot expose.
        for offset in range(0, len(data), CHUNK):
            self.xid += 1; ids.append(self.xid)
            part = data[offset:offset + CHUNK]
            body = opaque(handle) + struct.pack('>QII', offset, len(part), 2) + opaque(part)
            request = b''.join(u32(x) for x in [self.xid, 0, 2, 100003, 3, 7, 0, 0, 0, 0]) + body
            self.socket.sendall(u32(0x80000000 | len(request)) + request)
        for xid in ids: self.write_response(self.response(xid), CHUNK)
    def commit(self, handle):
        response = self.call(100003, 21, opaque(handle) + struct.pack('>QI', 0, 0))
        if response.uint(): raise OSError('NFS COMMIT failed')
        response.wcc()
        return response.take(8)


class Server:
    def __init__(self, binary, helper, mode, directory, env):
        self.process = subprocess.Popen([str(binary), '--synthetic-lab', str(helper), mode, str(directory)],
                                        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        try:
            ready, _, _ = select.select([self.process.stdout], [], [], 15)
            if not ready: raise OSError('NFS server startup timed out')
            line = self.process.stdout.readline(4096)
            hello = json.loads(line)
            if hello.get('capacity') != CAPACITY or hello.get('synthetic_only') is not True: raise ValueError('Invalid NFS handshake')
            self.port = int(hello['port'])
            if not 1024 <= self.port <= 65535: raise ValueError('Invalid NFS port')
        except Exception:
            self.stop()
            raise
    def stop(self, crash=False):
        if self.process.poll() is None:
            try: os.killpg(self.process.pid, signal.SIGKILL if crash else signal.SIGINT)
            except ProcessLookupError: pass
            try: self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait(timeout=5)
        self.process.stdout.close()
        self.process.stderr.close()


def expected_data():
    return hashlib.shake_256(b'CLOUDSWAP synthetic NFS acceptance v1').digest(CAPACITY)


def mounted_data():
    data = bytearray(expected_data())
    data[16380:16420] = bytes(x ^ 0xff for x in data[16380:16420])
    return bytes(data)


def checkpoint_trial(binary, helper, root, env):
    directory = root / 'checkpoint-store'
    server = Server(binary, helper, 'local-create', directory, env)
    client = None
    try:
        client = NFSClient(server.port); handle = client.handle()
        client.write(handle, 0, b'first')
        index = directory / 'index.enc'
        previous = index.read_bytes()
        client.write(handle, 0, b'newer')
        index.write_bytes(previous)
        try: client.commit(handle)
        except OSError: pass
        else: raise ValueError('COMMIT acknowledged an index rollback')
        try: client.read(handle, 0, 5)
        except OSError: pass
        else: raise ValueError('Poisoned session continued serving pages')
        return {'passed': True, 'authenticated_rollback_rejected': True, 'session_stopped': True}
    finally:
        if client: client.close()
        server.stop()


def wire_trial(binary, helper, root, env):
    server = Server(binary, helper, 'local-create', root / 'wire-store', env)
    client = None
    expected = expected_data()
    try:
        client = NFSClient(server.port)
        handle = client.handle()
        if client.read(handle, 0, 20)[0] != bytes(20): raise ValueError('Unwritten page is not zero')
        client.pipelined_writes(handle, expected[:CAPACITY // 2])
        for position in range(CAPACITY // 2, CAPACITY, CHUNK): client.write(handle, position, expected[position:position + CHUNK])
        client.commit(handle)
        client.close(); client = None
        server.stop(crash=True)
        # The entire isolated process group is dead before reopening its store.
        server = Server(binary, helper, 'local-open', root / 'wire-store', env)
        client = NFSClient(server.port); handle = client.handle()
        restored = b''.join(client.read(handle, position, CHUNK)[0] for position in range(0, CAPACITY, CHUNK))
        if restored != expected: raise ValueError('Post-crash NFS data differs')
        try:
            mismatch = client.call(100003, 7, opaque(handle) + struct.pack('>QII', 0, 0, 2) + opaque(b'bad'))
        except OSError: pass  # RPC GARBAGE_ARGS is also a valid rejection.
        else:
            if mismatch.uint() == 0: raise ValueError('NFS accepted mismatched write count')
        if client.read(handle, 0, 3)[0] != expected[:3]: raise ValueError('Invalid write changed committed data')
        try: client.write(handle, CAPACITY, b'x')
        except OSError: pass
        else: raise ValueError('NFS allowed file growth')
        # Invalid giant RPC lengths must be rejected without allocating their declared length.
        with socket.create_connection(('127.0.0.1', server.port), timeout=3) as bad:
            bad.sendall(u32(0xffffffff))
            try: reply = bad.recv(1)
            except ConnectionResetError: reply = b''
            if reply: raise ValueError('Oversized RPC fragment accepted')
        if client.read(handle, 16380, 40)[0] != expected[16380:16420]: raise ValueError('Server failed after malformed input')
        return {'passed': True, 'bytes_verified': CAPACITY, 'file_sync_acknowledgements': 64,
                'explicit_commit': True, 'crash_reopen': True, 'mounted': False,
                'mismatched_write_rejected': True, 'oversized_rpc_rejected': True,
                'pipelined_writes_verified': 32,
                'sha256': hashlib.sha256(restored).hexdigest()}
    finally:
        if client: client.close()
        server.stop()


def io_worker(stage, filename):
    expected = mounted_data()
    initial = expected_data()
    fd = os.open(filename, os.O_RDWR if stage == 'write' else os.O_RDONLY)
    try:
        if stage == 'write':
            for position in range(0, CAPACITY, CHUNK):
                count = os.pwrite(fd, initial[position:position + CHUNK], position)
                if count != CHUNK: raise OSError('Short mounted write')
            # Crosses two native pages and tests read-modify-write through the mount.
            patch = expected[16380:16420]
            if os.pwrite(fd, patch, 16380) != len(patch): raise OSError('Short unaligned write')
            os.fsync(fd)
        restored = b''.join(os.pread(fd, CHUNK, p) for p in range(0, CAPACITY, CHUNK))
        if restored != expected: raise ValueError('Mounted file integrity failure')
        with mmap.mmap(fd, CAPACITY, access=mmap.ACCESS_READ) as mapped:
            if mapped[:] != expected: raise ValueError('Mounted mmap integrity failure')
        return {'passed': True, 'bytes_verified': len(restored), 'mmap_read_verified': True,
                'sha256': hashlib.sha256(restored).hexdigest()}
    finally: os.close(fd)


def mount_trial(binary, helper, root, env, ci):
    if platform.system() != 'Darwin': raise ValueError('Mac mount test requires macOS')
    prefix = ['sudo', '-n'] if ci else []
    mountpoint = root / 'mount'; mountpoint.mkdir()
    server = None
    report = {'mounted': False, 'native_system_swap': False, 'live_r2': False}
    def unmount():
        if os.path.ismount(mountpoint):
            result = subprocess.run(prefix + ['/sbin/umount', '-f', str(mountpoint)], capture_output=True, timeout=20)
            if result.returncode or os.path.ismount(mountpoint): raise OSError('Lab mount could not be removed')
    try:
        for index, stage in enumerate(('write', 'verify', 'pause')):
            print('Mounted lab stage: ' + stage, file=sys.stderr, flush=True)
            server = Server(binary, helper, 'local-create' if index == 0 else 'local-open', root / 'mount-store', env)
            options = f'vers=3,tcp,nolocks,soft,timeo=10,retrans=1,rsize=65536,wsize=65536,actimeo=0,nosuid,nodev,port={server.port},mountport={server.port}'
            result = subprocess.run(prefix + ['/sbin/mount_nfs', '-o', options, '127.0.0.1:/', str(mountpoint)], capture_output=True, text=True, timeout=30)
            if result.returncode:
                report.update(state='mount_failed', exit_code=result.returncode, diagnostic=result.stderr.strip()[:2000])
                return report
            if not os.path.ismount(mountpoint): raise ValueError('Mount command succeeded without a mount')
            report['mounted'] = True
            worker_args = [sys.executable, __file__, '--worker', stage, str(mountpoint / 'pages')]
            if stage == 'pause':
                # Fresh mount: no data was read before pausing the whole server/helper group.
                os.killpg(server.process.pid, signal.SIGSTOP)
                started = time.monotonic()
                worker_process = subprocess.Popen(worker_args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                try:
                    time.sleep(1)
                    premature = worker_process.poll() is not None
                finally:
                    os.killpg(server.process.pid, signal.SIGCONT)
                try:
                    stdout, stderr = worker_process.communicate(timeout=90)
                except subprocess.TimeoutExpired:
                    unmount()
                    worker_process.kill()
                    worker_process.communicate(timeout=5)
                    raise
                if premature: raise ValueError('Cold mounted read did not wait for paused server')
                report['pause_observation'] = {'injected_server_pause_seconds': 1,
                    'worker_elapsed_seconds': round(time.monotonic() - started, 3),
                    'blocked_until_resumed': True, 'physical_wifi_drop': False}
                worker = subprocess.CompletedProcess(worker_args, worker_process.returncode, stdout, stderr)
            else:
                worker = subprocess.run(worker_args, capture_output=True, text=True, timeout=90)
            if worker.returncode: raise OSError('Mounted I/O worker failed: ' + worker.stderr[-500:])
            report[stage] = json.loads(worker.stdout)
            unmount(); server.stop(); server = None
        report.update(state='passed', passed=True, remount_reopen_verified=True)
        return report
    finally:
        unmount()
        if server: server.stop()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--server', type=Path)
    parser.add_argument('--helper', type=Path)
    parser.add_argument('--mount', action='store_true')
    parser.add_argument('--ci', action='store_true')
    parser.add_argument('--report', type=Path)
    parser.add_argument('--worker', nargs=2)
    args = parser.parse_args()
    if args.worker:
        print(json.dumps(io_worker(*args.worker))); return
    if not args.server or not args.helper: parser.error('--server and --helper are required')
    if args.ci and not (os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted'):
        parser.error('--ci is restricted to disposable GitHub-hosted runners')
    root = Path(tempfile.mkdtemp(prefix='cloudswap-nfs-lab-'))
    env = dict(os.environ, CLOUDSWAP_FILE_KEY_HEX=secrets.token_hex(32))
    report = {'schema_version': 1, 'host': {'os': platform.system(), 'version': platform.mac_ver()[0], 'architecture': platform.machine()},
              'synthetic_only': True, 'system_swap_modified': False, 'live_r2': False}
    try:
        report['wire'] = wire_trial(args.server.resolve(strict=True), args.helper.resolve(strict=True), root, env)
        report['checkpoint'] = checkpoint_trial(args.server.resolve(), args.helper.resolve(), root, env)
        if args.mount: report['mount'] = mount_trial(args.server.resolve(), args.helper.resolve(), root, env, args.ci)
        report['passed'] = report['wire']['passed'] and (not args.mount or report['mount'].get('passed', False))
    except Exception as error:
        report.update(passed=False, error_type=type(error).__name__, diagnostic=str(error)[:2000])
    finally:
        if not os.path.ismount(root / 'mount'): shutil.rmtree(root)
        else: report['retained_directory'] = str(root)
    text = json.dumps(report, indent=2)
    if args.report: args.report.write_text(text + '\n')
    print(text)
    if not report['passed']: raise SystemExit(1)


if __name__ == '__main__': main()
