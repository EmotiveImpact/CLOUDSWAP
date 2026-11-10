#!/usr/bin/env python3
"""Experimental fixed-size FUSE file over the native encrypted page store.

No system-swap configuration. --self-test exercises real callbacks and a real
helper process, but does not mount a filesystem or require a FUSE runtime.
"""
import argparse
import base64
import errno
import json
import os
from pathlib import Path
import random
import select
import secrets
import stat
import subprocess
import tempfile
import threading
import time

CAPACITY = 4 * 1024 * 1024
CHUNK = 65536
FRAME_LIMIT = 100000
MODES = ("local-create", "local-open", "remote-create", "remote-open", "mirror-create", "mirror-open")


def io_error():
    return OSError(errno.EIO, "Encrypted file backend unavailable")


class NativeClient:
    """Serial, bounded IPC. Transport uncertainty kills the helper; never replay writes."""
    def __init__(self, helper, mode, directory, *, env=None, timeout=30.0):
        if mode not in MODES or timeout <= 0 or timeout > 120:
            raise ValueError("Invalid file server mode or timeout")
        self.lock = threading.Lock()
        self.sequence = 0
        self.pending = bytearray()
        self.failed = False
        self.timeout = timeout
        self.process = subprocess.Popen(
            [str(helper), "--file-server", mode, str(directory)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            env=env, bufsize=0, close_fds=True)
        os.set_blocking(self.process.stdin.fileno(), False)
        os.set_blocking(self.process.stdout.fileno(), False)
        try:
            hello = self._read(time.monotonic() + timeout)
            if hello != {"id": 0, "ok": True, "capacity": CAPACITY}:
                raise io_error()
        except (OSError, ValueError, TypeError):
            self.abort()
            raise io_error() from None

    def _wait(self, deadline, *, writing=False):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise io_error()
        readable, writable, _ = select.select(
            [] if writing else [self.process.stdout],
            [self.process.stdin] if writing else [], [], remaining)
        if not (readable or writable):
            raise io_error()

    def _write(self, data, deadline):
        position = 0
        while position < len(data):
            self._wait(deadline, writing=True)
            try:
                count = os.write(self.process.stdin.fileno(), data[position:])
            except BlockingIOError:
                continue
            if count <= 0:
                raise io_error()
            position += count

    def _read(self, deadline):
        while True:
            newline = self.pending.find(b"\n")
            if newline >= 0:
                if newline > FRAME_LIMIT:
                    raise io_error()
                frame = bytes(self.pending[:newline])
                del self.pending[:newline + 1]
                value = json.loads(frame)
                if not isinstance(value, dict):
                    raise io_error()
                return value
            if len(self.pending) > FRAME_LIMIT:
                raise io_error()
            self._wait(deadline)
            try:
                part = os.read(self.process.stdout.fileno(), 4096)
            except BlockingIOError:
                continue
            if not part:
                raise io_error()
            self.pending.extend(part)

    def request(self, op, **fields):
        with self.lock:
            if self.failed:
                raise io_error()
            self.sequence += 1
            body = json.dumps(dict(fields, id=self.sequence, op=op), separators=(",", ":")).encode() + b"\n"
            if len(body) > FRAME_LIMIT:
                raise OSError(errno.EINVAL, "Request too large")
            try:
                deadline = time.monotonic() + self.timeout
                self._write(body, deadline)
                result = self._read(deadline)
                if type(result.get("id")) is not int or result["id"] != self.sequence or type(result.get("ok")) is not bool:
                    raise io_error()
            except (OSError, ValueError, TypeError):
                self.abort()
                raise io_error() from None
            if not result["ok"]:
                label = result.get("error")
                code = {"EINVAL": errno.EINVAL, "EBUSY": errno.EBUSY, "ENOTSUP": errno.ENOTSUP, "EIO": errno.EIO}.get(label) if isinstance(label, str) else None
                if code is None:
                    self.abort()
                    raise io_error()
                raise OSError(code, "Encrypted file request failed")
            return result

    def read(self, offset, count):
        result = self.request("read", offset=offset, count=count)
        try:
            data = base64.b64decode(result["data"], validate=True)
            expected = min(count, max(0, CAPACITY - offset))
            if type(result.get("count")) is not int or result["count"] != len(data) or len(data) != expected:
                raise ValueError()
            return data
        except (KeyError, ValueError, TypeError):
            self.abort()
            raise io_error() from None

    def write(self, offset, data):
        result = self.request("write", offset=offset, data=base64.b64encode(data).decode("ascii"))
        if type(result.get("count")) is not int or result["count"] != len(data):
            self.abort()
            raise io_error()
        return len(data)

    def flush(self):
        self.request("flush")

    def close(self):
        try:
            self.request("close")
            self.process.wait(timeout=2)
            if self.process.returncode != 0:
                raise io_error()
        finally:
            self.abort()

    def abort(self):
        self.failed = True
        if self.process.poll() is None:
            self.process.kill()
        self.process.wait(timeout=2)
        self.process.stdin.close()
        self.process.stdout.close()


class FileOperations:
    """Same operations are used by the mount and callback acceptance test."""
    def __init__(self, client):
        self.client = client
        self.modified = time.time()
        self.lock = threading.Lock()

    @staticmethod
    def _file(path):
        if path != "/pages":
            raise OSError(errno.ENOENT, "File not found")

    def getattr(self, path, fh=None):
        if path not in ("/", "/pages"):
            raise OSError(errno.ENOENT, "File not found")
        root = path == "/"
        return dict(st_mode=(stat.S_IFDIR | 0o700) if root else (stat.S_IFREG | 0o600),
                    st_nlink=2 if root else 1, st_size=0 if root else CAPACITY,
                    st_blocks=0 if root else CAPACITY // 512, st_blksize=16384,
                    st_uid=os.getuid(), st_gid=os.getgid(), st_atime=self.modified,
                    st_mtime=self.modified, st_ctime=self.modified)

    def readdir(self, path, fh):
        if path != "/":
            raise OSError(errno.ENOTDIR, "Not a directory")
        return [".", "..", "pages"]

    def opendir(self, path):
        if path != "/":
            raise OSError(errno.ENOTDIR, "Not a directory")
        return 0

    def statfs(self, path):
        self.getattr(path)
        # Virtual reserved capacity, not physical allocated bytes or free SSD space.
        return dict(f_bsize=16384, f_frsize=16384, f_blocks=CAPACITY // 16384,
                    f_bfree=0, f_bavail=0, f_files=2, f_ffree=0, f_favail=0, f_namemax=255)

    def utimens(self, path, times=None):
        raise OSError(errno.ENOTSUP, "Metadata changes are not implemented")

    def open(self, path, flags):
        self._file(path)
        if flags & (os.O_TRUNC | os.O_APPEND):
            raise OSError(errno.ENOTSUP, "Fixed-size file")
        return 0

    def read(self, path, size, offset, fh):
        self._file(path)
        if offset < 0 or size < 0 or size > CAPACITY:
            raise OSError(errno.EINVAL, "Invalid range")
        size = min(size, max(0, CAPACITY - offset))
        with self.lock:
            parts = []
            for position in range(0, size, CHUNK):
                parts.append(self.client.read(offset + position, min(CHUNK, size - position)))
            return b"".join(parts)

    def write(self, path, data, offset, fh):
        self._file(path)
        if offset < 0 or offset > CAPACITY or len(data) > CAPACITY - offset:
            raise OSError(errno.ENOSPC, "Fixed-size file boundary")
        with self.lock:
            for position in range(0, len(data), CHUNK):
                self.client.write(offset + position, data[position:position + CHUNK])
            self.modified = time.time()
            return len(data)

    def flush(self, path, fh):
        self._file(path)
        with self.lock:
            self.client.flush()
        return 0

    def fsync(self, path, datasync, fh):
        return self.flush(path, fh)

    def truncate(self, path, length, fh=None):
        self._file(path)
        if length != CAPACITY:
            raise OSError(errno.ENOTSUP, "Fixed-size file")
        return 0

    def release(self, path, fh):
        return 0


def self_test(helper):
    """Synthetic data only; real helper exit/relaunch with the same caller-held key."""
    env = dict(os.environ, CLOUDSWAP_FILE_KEY_HEX=secrets.token_hex(32))
    expected = bytearray(CAPACITY)
    rng = random.Random(1701)
    count = 0
    def check(condition):
        if not condition:
            raise io_error()
    with tempfile.TemporaryDirectory(prefix="cloudswap-file-test-") as temporary:
        directory = Path(temporary) / "encrypted"
        client = NativeClient(helper, "local-create", directory, env=env)
        try:
            ops = FileOperations(client)
            check(ops.read("/pages", 65536, 0, 0) == bytes(65536))
            ranges = [(0, 1), (16380, 40), (65530, 70000), (CAPACITY - 17, 17)]
            ranges += [(rng.randrange(0, CAPACITY - 70000), rng.randrange(1, 70000)) for _ in range(32)]
            for offset, length in ranges:
                data = bytes(rng.randrange(256) for _ in range(length))
                check(ops.write("/pages", data, offset, 0) == length)
                expected[offset:offset + length] = data
                check(ops.read("/pages", length, offset, 0) == data)
                count += 1
            ops.fsync("/pages", False, 0)
            check(ops.read("/pages", 64, CAPACITY, 0) == b"")
            check(ops.read("/pages", 64, CAPACITY - 17, 0) == expected[-17:])
            client.close()
            client = NativeClient(helper, "local-open", directory, env=env)
            ops = FileOperations(client)
            check(ops.read("/pages", CAPACITY, 0, 0) == expected)
            client.close()
        finally:
            client.abort()
    return dict(test="fuse_callbacks_without_mount", backend="native_local_encrypted",
                bytes_verified=CAPACITY, range_writes=count, helper_process_restart=True,
                mounted=False, macos_system_swap=False, live_r2=False, passed=True)


def validate_mount_paths(directory, mountpoint):
    store = Path(directory).resolve()
    mount = Path(mountpoint).resolve(strict=True)
    if not mount.is_dir() or any(mount.iterdir()):
        raise ValueError("Mountpoint must be an empty directory")
    if store == mount or store in mount.parents or mount in store.parents:
        raise ValueError("Store and mountpoint must be separate directory trees")
    return store, mount


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", required=True, type=Path)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--mode", choices=MODES, default="local-create")
    parser.add_argument("--directory", type=Path)
    parser.add_argument("--mountpoint", type=Path)
    args = parser.parse_args()
    if args.self_test:
        print(json.dumps(self_test(args.helper.resolve(strict=True)), sort_keys=True))
        return
    if args.directory is None or args.mountpoint is None:
        parser.error("Mounting requires --directory and --mountpoint")
    directory, mountpoint = validate_mount_paths(args.directory, args.mountpoint)
    try:
        from fuse import FUSE, Operations
    except (ImportError, OSError):
        parser.error("Mounting requires fusepy and an installed compatible macOS FUSE runtime; see README.md")
    class MountedOperations(FileOperations, Operations):
        pass
    client = NativeClient(args.helper.resolve(strict=True), args.mode, directory)
    try:
        # Direct I/O avoids a second file-data cache hiding backend failures.
        # No allow_other, writeback cache, background daemon or system-swap settings.
        FUSE(MountedOperations(client), str(mountpoint), foreground=True, nothreads=True,
             direct_io=True, default_permissions=True, fsname="CLOUDSWAP-lab")
    finally:
        client.close()


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError):
        raise SystemExit("CLOUDSWAP file operation failed. Check runtime, paths, key and backend configuration.") from None
