"""Ephemeral encrypted block store. One process/export; no restart recovery."""
import os
import threading
import uuid
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

BLOCK = 4096

class Store:
    def __init__(self, backend, size=16*1024*1024):
        if size <= 0 or size % BLOCK:
            raise ValueError('size must be a positive multiple of 4096')
        self.backend, self.size = backend, size
        self.session = uuid.uuid4().hex
        self.cipher = AESGCM(AESGCM.generate_key(bit_length=256))
        self.index = {}
        self.lock = threading.Lock()
        self.failed = False

    def bounds(self, offset, count):
        if offset < 0 or count < 0 or offset + count > self.size:
            raise ValueError('out of bounds')
        if self.failed:
            raise OSError('export poisoned by uncertain write; discard test VM')

    def block(self, i):
        if i not in self.index:
            return bytes(BLOCK)
        key = self.index[i]
        blob = self.backend.get(key)
        data = self.cipher.decrypt(blob[:12], blob[12:], key.encode())
        if len(data) != BLOCK:
            raise OSError('invalid block length')
        return data

    def read(self, offset, count):
        with self.lock:
            self.bounds(offset, count)
            if not count:
                return b''
            first, last = offset // BLOCK, (offset + count - 1) // BLOCK
            data = b''.join(self.block(i) for i in range(first, last + 1))
            return data[offset % BLOCK:offset % BLOCK + count]

    def write(self, offset, data):
        with self.lock:
            self.bounds(offset, len(data))
            if not data:
                return
            pending = {}
            try:
                for i in range(offset // BLOCK, (offset + len(data) - 1) // BLOCK + 1):
                    lo, hi = max(offset, i*BLOCK), min(offset+len(data), (i+1)*BLOCK)
                    block = bytearray(BLOCK) if hi-lo == BLOCK else bytearray(self.block(i))
                    block[lo-i*BLOCK:hi-i*BLOCK] = data[lo-offset:hi-offset]
                    key = f'iswap-lab/{self.session}/{i}/{uuid.uuid4().hex}'
                    nonce = os.urandom(12)
                    self.backend.put(key, nonce + self.cipher.encrypt(nonce, bytes(block), key.encode()))
                    pending[i] = key
            except Exception:
                # A timed-out PUT might have reached R2. Never claim success or
                # continue with an uncertain, partially committed write.
                self.failed = True
                raise
            self.index.update(pending)

class R2:
    def __init__(self):
        import boto3
        from botocore.config import Config
        endpoint = os.environ['R2_ENDPOINT']
        if not endpoint.startswith('https://') or not endpoint.endswith('.r2.cloudflarestorage.com'):
            raise ValueError('expected HTTPS R2 account endpoint')
        self.bucket = os.environ['R2_BUCKET']
        self.client = boto3.client('s3', endpoint_url=endpoint, region_name='auto',
            aws_access_key_id=os.environ['R2_ACCESS_KEY_ID'],
            aws_secret_access_key=os.environ['R2_SECRET_ACCESS_KEY'],
            config=Config(connect_timeout=2, read_timeout=3, retries={'total_max_attempts':1},
                          request_checksum_calculation='when_required', response_checksum_validation='when_required'))
    def put(self, key, value):
        self.client.put_object(Bucket=self.bucket, Key=key, Body=value)
    def get(self, key):
        body = self.client.get_object(Bucket=self.bucket, Key=key)['Body']
        try:
            return body.read()
        finally:
            body.close()
