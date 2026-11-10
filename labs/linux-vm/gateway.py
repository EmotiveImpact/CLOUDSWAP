"""Test-only nbdkit gateway, with encrypted payloads sent over loopback HTTP."""
import os
from pathlib import Path
import sys
from urllib.request import Request, urlopen

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'linux-python'))
from store import Store

API_VERSION = 2


class LoopbackObjects:
    def __init__(self):
        self.base = f"http://127.0.0.1:{int(os.environ['CLOUDSWAP_LAB_PORT'])}"

    def put(self, key, value):
        with urlopen(Request(f'{self.base}/{key}', data=value, method='PUT'), timeout=3):
            pass

    def get(self, key):
        with urlopen(f'{self.base}/{key}', timeout=3) as response:
            return response.read(8192)


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
