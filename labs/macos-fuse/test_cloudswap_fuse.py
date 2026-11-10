import base64
import errno
import json
import os
from pathlib import Path
import secrets
import stat
import sys
import tempfile
import time
import unittest

from cloudswap_fuse import CAPACITY, CHUNK, FileOperations, NativeClient, validate_mount_paths


class BufferClient:
    def __init__(self):
        self.data = bytearray(CAPACITY)
        self.requests = []
        self.flushes = 0
    def read(self, offset, count):
        self.requests.append(count)
        return bytes(self.data[offset:offset + count])
    def write(self, offset, data):
        self.requests.append(len(data))
        self.data[offset:offset + len(data)] = data
        return len(data)
    def flush(self):
        self.flushes += 1


class CallbackTests(unittest.TestCase):
    def setUp(self):
        self.client = BufferClient()
        self.ops = FileOperations(self.client)
    def test_bounded_chunking_and_unaligned_roundtrip(self):
        data = b"abc" * 50000
        self.assertEqual(self.ops.write("/pages", data, 100, 0), len(data))
        self.assertEqual(self.ops.read("/pages", len(data), 100, 0), data)
        self.assertLessEqual(max(self.client.requests), CHUNK)
    def test_permissions_and_namespace(self):
        self.assertEqual(stat.S_IMODE(self.ops.getattr("/pages")["st_mode"]), 0o600)
        self.assertEqual(self.ops.getattr("/pages")["st_size"], CAPACITY)
        self.assertEqual(self.ops.readdir("/", 0), [".", "..", "pages"])
        with self.assertRaises(OSError) as error:
            self.ops.open("/private", os.O_RDONLY)
        self.assertEqual(error.exception.errno, errno.ENOENT)
    def test_no_truncate_append_or_growth(self):
        for flag in (os.O_TRUNC, os.O_APPEND):
            with self.assertRaises(OSError): self.ops.open("/pages", flag)
        with self.assertRaises(OSError): self.ops.truncate("/pages", 0)
        with self.assertRaises(OSError): self.ops.write("/pages", b"x", CAPACITY, 0)
        self.assertEqual(self.client.requests, [])
    def test_eof_and_invalid_read(self):
        self.assertEqual(self.ops.read("/pages", 10, CAPACITY - 1, 0), b"\0")
        self.assertEqual(self.ops.read("/pages", 10, CAPACITY + 10, 0), b"")
        for size, offset in [(-1, 0), (1, -1), (CAPACITY + 1, 0)]:
            with self.assertRaises(OSError): self.ops.read("/pages", size, offset, 0)
    def test_fsync_reaches_backend(self):
        self.ops.flush("/pages", 0)
        self.ops.fsync("/pages", True, 0)
        self.assertEqual(self.client.flushes, 2)
    def test_filesystem_metadata_has_valid_block_size(self):
        values = self.ops.statfs("/")
        self.assertEqual(values["f_blocks"] * values["f_bsize"], CAPACITY)
        self.assertEqual(values["f_bavail"], 0)
        with self.assertRaises(OSError): self.ops.opendir("/pages")
        with self.assertRaises(OSError): self.ops.utimens("/pages")
    def test_mount_path_separation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            mount = root / "mount"
            mount.mkdir()
            validate_mount_paths(root / "store", mount)
            for store in [mount, mount / "store", root]:
                with self.assertRaises(ValueError): validate_mount_paths(store, mount)
            (mount / "existing").write_text("keep")
            with self.assertRaises(ValueError): validate_mount_paths(root / "store", mount)


class IPCFaultTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.helper = Path(self.tmp.name) / "fault-helper"
        self.helper.write_text("#!" + sys.executable + "\n" + '''
import json, sys, time
mode = sys.argv[-1]
if mode == "bad-hello":
    print('{"id": 0, "ok": true, "capacity": 0}', flush=True)
else:
    print('{"id": 0, "ok": true, "capacity": 4194304}', flush=True)
for line in sys.stdin:
    request = json.loads(line)
    if mode == "stall": time.sleep(5)
    if mode == "crash": sys.exit(1)
    if mode == "oversize":
        print("x" * 110000, flush=True)
        continue
    result = {"id": request["id"], "ok": True}
    if mode == "wrong-id": result["id"] += 1
    if mode == "bad-base64": result.update(data="!", count=1)
    if mode == "short-read": result.update(data="", count=0)
    if mode == "short-write": result.update(count=0)
    print(json.dumps(result), flush=True)
''')
        self.helper.chmod(0o700)
    def test_bad_handshake(self):
        with self.assertRaises(OSError):
            NativeClient(self.helper, "local-create", "bad-hello", timeout=1)
    def test_transport_failures_are_bounded_and_terminal(self):
        for fault in ("stall", "crash", "oversize", "wrong-id"):
            with self.subTest(fault=fault):
                client = NativeClient(self.helper, "local-create", fault, timeout=2)
                client.timeout = 0.3
                self.addCleanup(client.abort)
                started = time.monotonic()
                with self.assertRaises(OSError): client.flush()
                self.assertLess(time.monotonic() - started, 2)
                self.assertIsNotNone(client.process.poll())
                with self.assertRaises(OSError): client.flush()
    def test_invalid_payload_and_short_write_are_terminal(self):
        for fault in ("bad-base64", "short-read", "short-write"):
            with self.subTest(fault=fault):
                client = NativeClient(self.helper, "local-create", fault, timeout=1)
                self.addCleanup(client.abort)
                with self.assertRaises(OSError):
                    if fault == "short-write": client.write(0, b"x")
                    else: client.read(0, 1)
                self.assertIsNotNone(client.process.poll())


@unittest.skipUnless(os.environ.get("CLOUDSWAP_FILE_HELPER"), "Set CLOUDSWAP_FILE_HELPER for native process integration")
class NativeIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="cloudswap-ipc-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "store"
        self.env = dict(os.environ, CLOUDSWAP_FILE_KEY_HEX=secrets.token_hex(32))
        self.helper = Path(os.environ["CLOUDSWAP_FILE_HELPER"]).resolve(strict=True)
    def start(self, mode="local-create", env=None):
        client = NativeClient(self.helper, mode, self.root, env=env or self.env, timeout=2)
        self.addCleanup(client.abort)
        return client
    def test_create_cannot_reopen_existing_store(self):
        client = self.start()
        client.write(0, b"preserve")
        client.close()
        with self.assertRaises(OSError): self.start()
        reopened = self.start("local-open")
        self.assertEqual(reopened.read(0, 8), b"preserve")
        reopened.close()
    def test_wrong_key_cannot_reopen(self):
        client = self.start()
        client.write(0, b"secret synthetic page")
        client.close()
        with self.assertRaises(OSError):
            self.start("local-open", dict(self.env, CLOUDSWAP_FILE_KEY_HEX=secrets.token_hex(32)))
    def test_invalid_key_is_rejected_before_store_creation(self):
        for key in ["", "a" * 63, "g" * 64, "a" * 64 + "\n"]:
            with self.subTest(key_length=len(key)):
                with self.assertRaises(OSError):
                    self.start(env=dict(self.env, CLOUDSWAP_FILE_KEY_HEX=key))
                self.assertFalse(self.root.exists())
    def test_acknowledged_data_survives_abrupt_process_death(self):
        client = self.start()
        client.write(16380, b"synthetic cross-page data")
        client.abort()
        reopened = self.start("local-open")
        self.assertEqual(reopened.read(16380, 26), b"synthetic cross-page data" + b"\0")
        reopened.close()
    def test_corrupt_committed_data_never_becomes_zeros(self):
        client = self.start()
        client.write(0, b"committed")
        objects = [p for p in self.root.iterdir() if p.name not in ("writer.lock", "index.enc")]
        self.assertEqual(len(objects), 1)
        objects[0].write_bytes(b"broken ciphertext")
        with self.assertRaises(OSError): client.read(0, 9)
    def test_missing_committed_data_never_becomes_zeros(self):
        client = self.start()
        client.write(0, b"committed")
        for path in self.root.iterdir():
            if path.name not in ("writer.lock", "index.enc"): path.unlink()
        with self.assertRaises(OSError): client.read(0, 9)
    def test_directory_detachment_fails_and_requires_new_helper(self):
        client = self.start()
        client.write(0, b"keep")
        moved = self.root.with_name("detached")
        self.root.rename(moved)
        self.root.mkdir()
        with self.assertRaises(OSError): client.write(0, b"lose")
        self.assertEqual(list(self.root.iterdir()), [])
        self.root.rmdir()
        moved.rename(self.root)
        with self.assertRaises(OSError): client.read(0, 4)
        client.abort()
        reopened = self.start("local-open")
        self.assertEqual(reopened.read(0, 4), b"keep")
        reopened.close()
    def test_invalid_request_does_not_destroy_committed_data(self):
        client = self.start()
        client.write(0, b"keep")
        for fields in [dict(offset=-1, count=1), dict(offset=0, count=65537)]:
            with self.assertRaises(OSError) as error: client.request("read", **fields)
            self.assertEqual(error.exception.errno, errno.EINVAL)
        self.assertEqual(client.read(0, 4), b"keep")
        client.close()


if __name__ == "__main__":
    unittest.main()
