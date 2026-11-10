"""Run baseline and outage cases with a fresh VM and object service per case."""
import argparse
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import re
import selectors
import socket
import subprocess
import tempfile
import threading
import time


class Objects(HTTPServer):
    def __init__(self, outage_seconds):
        super().__init__(('127.0.0.1', 0), Handler)
        self.objects = {}
        self.reads = 0
        self.writes = 0
        self.drops = 0
        self.arm = threading.Event()
        self.offline_until = 0.0
        self.outage_seconds = outage_seconds


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def drop(self):
        now = time.monotonic()
        if self.command == 'GET' and self.server.arm.is_set():
            self.server.arm.clear()
            self.server.offline_until = now + self.server.outage_seconds
        if now >= self.server.offline_until:
            return False
        self.server.drops += 1
        self.connection.shutdown(socket.SHUT_RDWR)
        self.close_connection = True
        return True

    def do_PUT(self):
        if self.drop():
            return
        size = int(self.headers.get('Content-Length', '0'))
        if size != 4124 or len(self.server.objects) >= 65536:
            self.send_error(400)
            return
        self.server.objects[self.path] = self.rfile.read(size)
        self.server.writes += 1
        self.send_response(200)
        self.end_headers()

    def do_GET(self):
        if self.drop():
            return
        value = self.server.objects.get(self.path)
        if value is None:
            self.send_error(404)
            return
        self.server.reads += 1
        self.send_response(200)
        self.send_header('Content-Length', str(len(value)))
        self.end_headers()
        self.wfile.write(value)


def observe(vm, log, objects, outage):
    deadline = time.monotonic() + 150
    ready = None
    reads_before = 0
    pending = b''
    with selectors.DefaultSelector() as selector:
        selector.register(vm.stdout, selectors.EVENT_READ)
        while time.monotonic() < deadline:
            if not selector.select(timeout=0.5):
                continue
            data = os.read(vm.stdout.fileno(), 8192)
            if not data:
                break
            log.write(data)
            log.flush()
            pending += data
            while b'\n' in pending:
                line, pending = pending.split(b'\n', 1)
                line = line.rstrip(b'\r')
                if line.startswith(b'PAGEOUT_READY ') and ready is None:
                    print(line.decode(), flush=True)
                    ready = time.monotonic()
                    reads_before = objects.reads
                    if outage:
                        objects.arm.set()
                    vm.stdin.write(b'verify\n')
                    vm.stdin.flush()
                if line.startswith(b'DATA_VERIFIED '):
                    print(line.decode(), flush=True)
    if vm.poll() is None:
        vm.wait(timeout=5)
    if ready is None:
        raise RuntimeError('guest never reached verified page-out readiness')
    return objects.reads - reads_before, round(time.monotonic() - ready, 3)


def run_case(args, name, outage_seconds, read_retry_seconds, expect_survival):
    objects = Objects(outage_seconds)
    worker = threading.Thread(target=objects.serve_forever, daemon=True)
    worker.start()
    port = str(objects.server_address[1])
    lab = Path(__file__).resolve().parent
    case_log = args.results / f'{name}-guest.log'
    try:
        with tempfile.TemporaryDirectory(prefix='cs-') as temp:
            nbd = Path(temp) / 'disk.sock'
            with (args.results / f'{name}-gateway.log').open('wb') as gateway_log:
                gateway = subprocess.Popen(['nbdkit', '-f', '-U', str(nbd), 'python', str(lab / 'gateway.py')],
                                           stdout=gateway_log, stderr=subprocess.STDOUT,
                                           env={**os.environ, 'CLOUDSWAP_LAB_PORT': port,
                                                'CLOUDSWAP_LAB_READ_RETRY': str(read_retry_seconds),
                                                'NO_PROXY': '127.0.0.1'})
                try:
                    for _ in range(100):
                        if nbd.exists():
                            break
                        if gateway.poll() is not None:
                            raise RuntimeError('nbdkit exited before serving its socket')
                        time.sleep(0.05)
                    else:
                        raise RuntimeError('nbdkit socket did not appear')
                    command = ['qemu-system-x86_64', '-machine', 'accel=tcg', '-m', '256', '-smp', '2',
                               '-nodefaults', '-display', 'none', '-serial', 'stdio', '-monitor', 'none',
                               '-no-reboot', '-nic', 'none', '-kernel', str(args.kernel), '-initrd', str(args.initrd),
                               '-append', 'console=ttyS0 rdinit=/init zswap.enabled=0 transparent_hugepage=never loglevel=4',
                               '-drive', f'file=nbd:unix:{nbd},if=virtio,format=raw,rerror=report,werror=report']
                    with case_log.open('wb') as log, subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                                                        stderr=subprocess.STDOUT) as vm:
                        try:
                            reads, elapsed = observe(vm, log, objects, outage_seconds > 0)
                        finally:
                            if vm.poll() is None:
                                vm.kill()
                finally:
                    if gateway.poll() is None:
                        gateway.terminate()
                        try:
                            gateway.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            gateway.kill()
                            gateway.wait()
    finally:
        objects.shutdown()
        objects.server_close()
        worker.join(timeout=5)
    report = case_log.read_text(errors='replace')
    status_match = re.search(r'PROBE_EXIT status=(\d+)', report)
    status = int(status_match.group(1)) if status_match else None
    verified = 'DATA_VERIFIED swapins=' in report
    result = {'case': name, 'verified': verified, 'guest_status': status, 'object_writes': objects.writes,
              'object_reads_during_verify': reads, 'dropped_http_requests': objects.drops, 'ready_to_exit_seconds': elapsed,
              'configured_outage_seconds': outage_seconds, 'read_retry_seconds': read_retry_seconds}
    print(json.dumps(result), flush=True)
    (args.results / f'{name}.json').write_text(json.dumps(result, indent=2) + '\n')
    if outage_seconds and objects.drops == 0:
        raise RuntimeError('outage was never exercised by guest page-in')
    if expect_survival:
        if status != 0 or not verified or reads == 0 or objects.writes == 0:
            raise RuntimeError('expected intact kernel swap read-back')
    elif status != 135 or verified:
        raise RuntimeError('expected a guest SIGBUS after a failed demand read')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--kernel', type=Path, required=True)
    parser.add_argument('--initrd', type=Path, required=True)
    parser.add_argument('--results', type=Path, required=True)
    args = parser.parse_args()
    args.results.mkdir(parents=True, exist_ok=True)
    cases = [
        ('baseline', 0, 0, True),
        ('fail-fast', 1, 0, False),
        ('retry-short', 1, 2.5, True),
        ('retry-long', 4, 2.5, False),
    ]
    for name, duration, retry, expect_survival in cases:
        try:
            run_case(args, name, duration, retry, expect_survival)
        except Exception:
            for kind in ('guest', 'gateway'):
                path = args.results / f'{name}-{kind}.log'
                if path.exists():
                    print(path.read_text(errors='replace')[-5000:], flush=True)
            raise


if __name__ == '__main__':
    main()
