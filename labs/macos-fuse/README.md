# Native encrypted file adapter

This is an implemented experimental filesystem adapter, not macOS system swap.
It exposes one fixed 4 MiB file called `pages`, backed by the existing Swift
AES-GCM page store. Reads and writes support arbitrary byte offsets, including
partial pages. Python supplies the FUSE binding and bounded process transport;
Swift retains encryption, page commits, single-writer locking and R2 access.

The mounting entry point is implemented but **has not been mounted**. The
callback and native-helper tests below run without FUSE. They cannot establish
kernel ABI compatibility, vnode paging support, mmap support or swap eligibility.
The current test Mac is arm64 / macOS 14.5 and has no FUSE runtime. Nothing here
changes `vm.swapfileprefix`, moves macOS swap files or installs a driver.

## Build and reproduce without a driver

From the repository root:

```sh
bash scripts/build-mac.sh
export CLOUDSWAP_FILE_HELPER="$PWD/dist/CLOUDSWAP.app/Contents/Helpers/R2Lab"
python3 -m unittest discover -s labs/macos-fuse -v
python3 labs/macos-fuse/cloudswap_fuse.py --self-test --helper "$CLOUDSWAP_FILE_HELPER"
```

The tests require Python 3.9+ and a Mac-built helper. If `CLOUDSWAP_FILE_HELPER`
is omitted, native process integration tests are explicitly skipped. CI sets it.
The foundation workflow now runs Mac builds and these tests on `macos-latest`
(arm64) and `macos-15-intel`, recording the OS and toolchain. This checks software
portability across CI hosts; physical drive, Wi-Fi, mounting and swap trials still
require their own lab evidence. Runner labels are documented by
[GitHub](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job).
The standalone self-test always starts the real helper. It creates synthetic
pages, closes and relaunches the helper using the same caller-held key, verifies
the whole 4 MiB file, then deletes its temporary directory. It reports
`mounted: false`, `macos_system_swap: false` and `live_r2: false` explicitly.

Native tests additionally exercise remote read recovery, offline mirrored reads
and failed-write stops against an in-memory object service. These are simulated
transport failures, not physical Wi-Fi or drive unplug trials.

## Mount on a prepared lab Mac

A compatible installed macOS FUSE runtime and library are prerequisites. No runtime
is installed automatically. `fusepy` is a small experimental binding, not the
chosen production driver architecture. Its pinned 2018 release does not establish
Apple Silicon or current macFUSE compatibility; verify that combination on the
lab Mac before treating a mount as working. FSKit and FUSE-T compatibility are
also unverified. See [upstream fusepy](https://github.com/fusepy/fusepy) and its
[3.0.1 release](https://pypi.org/project/fusepy/3.0.1/).

Use a virtual environment for the optional Python dependency:

```sh
python3 -m venv .venv-fuse
.venv-fuse/bin/python -m pip install --require-hashes -r labs/macos-fuse/requirements.txt
```

Supply a random 32-byte key as 64 hexadecimal characters through
`CLOUDSWAP_FILE_KEY_HEX`, without putting it in command arguments, logs or source.
The caller must securely retain the same key for reopen. The prototype has no
Keychain integration or key recovery. Loss of the key makes the store unreadable.
Only synthetic data belongs in this prototype. In the self-test the key stays in
the parent process and helper environment; it is never written to a key file.

Create an empty mountpoint separate from the backend tree. The backend directory
for a `*-create` session must **not exist**. Example with an already prepared
runtime, key and the two parent directories:

```sh
.venv-fuse/bin/python labs/macos-fuse/cloudswap_fuse.py \
  --helper dist/CLOUDSWAP.app/Contents/Helpers/R2Lab \
  --mode local-create \
  --directory /Volumes/LabSSD/cloudswap-file-store \
  --mountpoint /Volumes/cloudswap-file-lab
```

The mount runs in the foreground. Unmount using the host's normal unmount command
before terminating it. Use `local-open` with the same directory and key to reopen.
No automatic remount or retry of an uncertain write occurs. The example paths
are placeholders, not paths discovered or modified on the user's Mac.

| Mode | Payload location | Reads with network unavailable | Writes |
|---|---|---|---|
| `local-create` / `local-open` | Selected directory, which may be external | No network required | Require directory to remain available |
| `remote-create` / `remote-open` | R2, encrypted index in selected directory | Committed page reads fail | Require R2 acknowledgement and local index commit |
| `mirror-create` / `mirror-open` | R2 plus full encrypted local mirror | Read the local mirror | Still require R2 acknowledgement and local index commit |

Remote modes use `R2_ENDPOINT`, `R2_BUCKET`, `R2_ACCESS_KEY_ID` and
`R2_SECRET_ACCESS_KEY`, with the existing R2 client. They are wired but have not
been tested with a live bucket. Use a dedicated private lab bucket. Immutable
objects use `cloudswap-lab/<uuid>/probe`. Rewrites and failed writes may leave
unreferenced objects: this adapter does not garbage-collect remote objects or
remove its persistent directory. The 4 MiB logical capacity does not bound remote
storage consumed by repeated overwrites. Do not use it as a background service.

## Contract and failure behaviour

- One file with fixed capacity. No create, truncate-to-other-size, append, rename,
  unlink or directory mutation. No ordinary file offloading UI.
- FUSE uses direct I/O, foreground operation, one request thread and owner-only
  permissions. No `allow_other`, background write-back cache or paging hook.
  mmap and kernel swap cannot be inferred from this read/write interface.
- Byte writes become 16 KiB page commits. Every page write completes the existing
  backend commit before acknowledgement. A multi-page write is **not atomic**.
  Earlier pages may commit before a later page fails. Such a failure stops the
  session; reopening is explicit and must verify whichever data actually committed.
- `flush` and `fsync` validate the backend after the already-synchronous writes.
  There is no deferred dirty-data queue. Local persistence uses file and directory
  `fsync`, not a claim of physical power-loss durability or `F_FULLFSYNC` support.
- A never-written page is zero-filled. Missing committed ciphertext, bad
  authentication or a detached directory returns an error, never fabricated zeros.
- IPC frames are bounded to 100,000 bytes and page-range requests to 64 KiB.
  Larger filesystem requests are split. IPC has a 30-second deadline including
  pipe writes. Timeout, malformed response, process death or mismatched request ID
  kills the helper; writes are never replayed automatically. This is a lab bound,
  not a target acceptable stall time for interactive applications.
- A transient remote read error can be retried by a later caller. A failed write
  poisons the native session. Full-mirror reads work offline, but the first offline
  write stops that session. A mirror does not provide indefinite offline operation.
- Directory identity is checked on native I/O. Replacement at the same path is
  rejected. Path-rename tests do not reproduce every physical disconnection mode.
- `statfs` and file block counts describe reserved virtual capacity. They are not
  physical allocation measurements or evidence of reclaimed internal SSD space.

## Native protocol

`R2Lab --file-server MODE DIRECTORY` reads newline-delimited JSON from stdin and
writes JSON responses to stdout. Startup returns ID 0 and capacity 4,194,304.
Positive request IDs are echoed. Operations are `read` (offset/count), `write`
(offset/base64 data), `flush` and `close`. Errors carry only `EINVAL`, `EBUSY`,
`ENOTSUP` or `EIO`. Keys, endpoint URLs, payloads and raw errors are not logged.
The interface is a private local child-process pipe, not a network listener.

## Remaining acceptance gates

1. Run an actual mount with the pinned binding and a compatible runtime. Record
   runtime versions, host model, architecture, OS build, ordinary file I/O and
   unmount behaviour. Fix ABI/runtime issues found there.
2. Verify external SSD I/O and controlled synthetic-data disconnect/reconnect on
   a spare Mac. Run live R2 and blackhole tests with scoped credentials.
3. Separately prove the kernel's vnode/page-in/page-out requirements and swap
   selection on an isolated system. The fixed `pages` file is not an XNU swapfile
   namespace; it is not ready for pointing `vm.swapfileprefix` at it.
4. Resolve daemon memory-pressure dependency/deadlock risks, durable keys,
   orphan reclamation, partial-write recovery and power-failure semantics before
   considering a real system paging service. Kernel callers waiting on a pageable
   user-space daemon are an unresolved design risk.

The original goal remains native Mac app swap. This adapter makes the encrypted
storage path executable through file operations; it does not complete that goal.
