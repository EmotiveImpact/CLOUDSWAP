import os
import unittest
from store import Store, BLOCK

class Backend:
    def __init__(self):
        self.objects = {}
        self.offline = False
        self.ambiguous = False
    def get(self, key):
        if self.offline:
            raise TimeoutError('simulated connection loss')
        return self.objects[key]
    def put(self, key, value):
        if self.offline:
            raise TimeoutError('simulated connection loss')
        self.objects[key] = value
        if self.ambiguous:
            raise TimeoutError('response lost after PUT committed')

class Tests(unittest.TestCase):
    def setUp(self):
        self.b = Backend()
        self.s = Store(self.b)
    def test_roundtrip_and_ciphertext(self):
        data = os.urandom(3*BLOCK)
        self.s.write(0, data)
        self.assertEqual(self.s.read(0, len(data)), data)
        self.assertNotIn(data[:BLOCK], b''.join(self.b.objects.values()))
    def test_partial_cross_block_write(self):
        self.s.write(BLOCK-2, b'abcdef')
        self.assertEqual(self.s.read(BLOCK-4, 10), b'\0\0abcdef\0\0')
    def test_unwritten_is_zero(self):
        self.assertEqual(self.s.read(0, BLOCK), bytes(BLOCK))
    def test_missing_written_object_is_error(self):
        self.s.write(0, b'x')
        self.b.objects.clear()
        with self.assertRaises(KeyError): self.s.read(0, 1)
    def test_outage_read_and_reconnect(self):
        self.s.write(0, b'hello')
        self.b.offline = True
        with self.assertRaises(TimeoutError): self.s.read(0, 5)
        self.b.offline = False
        self.assertEqual(self.s.read(0, 5), b'hello')
    def test_failed_write_poisons_export(self):
        self.b.offline = True
        with self.assertRaises(TimeoutError): self.s.write(0, b'x')
        self.b.offline = False
        with self.assertRaises(OSError): self.s.read(0, 1)
    def test_ambiguous_write_poisons_export(self):
        self.b.ambiguous = True
        with self.assertRaises(TimeoutError): self.s.write(0, b'x')
        self.assertTrue(self.b.objects)
        with self.assertRaises(OSError): self.s.write(0, b'y')
    def test_corruption_rejected(self):
        self.s.write(0, b'x')
        key = self.s.index[0]
        blob = self.b.objects[key]
        self.b.objects[key] = blob[:-1] + bytes([blob[-1]^1])
        with self.assertRaises(Exception): self.s.read(0, 1)
    def test_bounds(self):
        for offset, size in [(-1, 1), (self.s.size, 1), (0, -1)]:
            with self.assertRaises(ValueError): self.s.read(offset, size)
    def test_overwrite_uses_new_object(self):
        self.s.write(0, b'a')
        old = self.s.index[0]
        self.s.write(0, b'b')
        self.assertNotEqual(old, self.s.index[0])
        self.assertEqual(self.s.read(0, 1), b'b')

if __name__ == '__main__': unittest.main(verbosity=2)
