"""nbdkit Python API v2. Run on a separate gateway, never in swap client."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from store import Store, R2
API_VERSION = 2
store = None

def get_ready():
    global store
    store = Store(R2())

def open(readonly):
    return store

def get_size(h):
    return h.size

def pread(h, buf, offset, flags):
    buf[:] = h.read(offset, len(buf))

def pwrite(h, buf, offset, flags):
    h.write(offset, bytes(buf))

def flush(h, flags):
    with h.lock:
        h.bounds(0, 0)
