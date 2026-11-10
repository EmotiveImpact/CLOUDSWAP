"""Test-only nbdkit gateway, with encrypted payloads sent over loopback HTTP."""
import os
from pathlib import Path
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'linux-python'))
from store import Store

API_VERSION = 2


class LoopbackObjects:
    def __init__(self):
        self.base = f"http://127.0.0.1:{int(os.environ['CLOUDSWAP_LAB_PORT'])}"
        self.read_retry_seconds = float(os.environ["CLOUDSWAP_LAB_READ_RETRY"])

    def put(self, key, value):
        with urlopen(Request(f'{self.base}/{key}', data=value, method='PUT'), timeout=3):
            pass

    def get(self, key):
        deadline = time.monotonic() + self.read_retry_seconds
        while True:
            remaining = deadline - time.monotonic()
            timeout = max(0.001, remaining) if self.read_retry_seconds else 3
            try:
                with urlopen(f'{self.base}/{key}', timeout=timeout) as response:
                    return response.read(8192)
            except HTTPError:
                raise
            except (URLError, ConnectionError, TimeoutError):
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise
                time.sleep(min(0.05, remaining))


def get_ready():
    global store
    store = Store(LoopbackObjects(), 64 * 1024 * 1024)


def open(readonly):
    return store


def get_size(handle):
    return handle.size


def pread(handle, buf, offset, flags):
    buf[:] = handle.read(offset, len(buf))


def pwrite(handle, buf, offset, flags):
    handle.write(offset, bytes(buf))


def flush(handle, flags):
    with handle.lock:
        handle.bounds(0, 0)
