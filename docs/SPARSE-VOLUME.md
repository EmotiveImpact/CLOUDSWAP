# Growable Mac storage laboratory

The original NFS adapter exposed one fixed 4 MiB file. The new opt-in
`--sparse-lab` mode supports regular-file creation, sparse growth, partial
writes, shrink, rename/replacement, deletion and stable file identities.
It connects to `R2Lab --volume-server` and the new Swift `SparseVolume`.
The original fixed-file mode and its tests remain available.

## Storage and commit contract

- Logical quota: eight files, at most 2 GiB each, at most 4 GiB combined.
- I/O requests: at most 64 KiB; authenticated pages: 16 KiB.
- Encrypted leaf maps cover 256 pages each. The encrypted catalogue references
  immutable leaf identities and remains bounded to 256 KiB. Operations load
  only the relevant leaf maps and pages; no gigabyte buffer is allocated for
  sparse growth. This is not a measured or wired-memory guarantee.
- Writes create new page objects and leaf maps, then atomically replace the
  catalogue. A failed multi-page write cannot publish half a new mapping.
  An uncertain write stops the session; reopening selects the last committed
  catalogue. The caller must retain the same encryption key.
- Shrinking removes higher mappings and writes a zeroed partial boundary page
  before committing the shorter size. Regrowth therefore cannot expose the old
  tail. Unwritten holes return zeroes; missing committed objects are failures.
- Local, remote and full-mirror payload modes share this catalogue. Remote
  writes record encrypted local intents before PUT so ambiguous uploads remain
  identifiable. Mirror reads use the local authenticated payload.
- Catalogue changes are checked against the current session's expected digest.
  COMMIT also authenticates the referenced leaf maps. This is not anti-rollback
  protection across restarts or protection against physical power loss.

Retired pages, leaf maps and remote objects are deliberately retained in this
increment. A 16,384-object limit counts local payloads/intents/leaves, including
uncertain writes and interrupted temporary files on reopen. It can be reached
through overwrites as well as new data. There is no production garbage collector.
NFS reports conservative writable headroom from that budget rather than the
upstream server's invented 1 TiB free capacity. Sparse logical file size does
not reserve backing space, guarantee full materialisation, or demonstrate savings.

## Filesystem protocol

NFS CREATE supports UNCHECKED, atomic GUARDED and persisted EXCLUSIVE verifier
retries. The vendor previously discarded exclusive verifiers; the adapter now
passes them through. Removed/replaced handles become stale and file IDs are
never reused within the volume. SETATTR supports length, ordinary permissions,
owner/group and timestamps. Rename replacement commits one catalogue update.
Hard links, symlinks, subdirectories, special permissions and arbitrary Unicode
names remain unsupported. Names are bounded ASCII file components.

The server is loopback-only and still an unauthenticated synthetic-data lab.
It is not suitable for private application memory. The [NFSv3 specification](https://www.rfc-editor.org/rfc/rfc1813)
is the reference for create modes, SETATTR, stable writes and COMMIT; vendored
changes and hashes are recorded in `labs/macos-nfs/UPSTREAM.json`.

## Verification

Run native tests, build the helper/server, then:

```sh
python3 labs/macos-nfs/sparse_lab.py \
  --server labs/macos-nfs/target/debug/cloudswap-nfs-lab \
  --helper apps/macos/.build/debug/R2Lab \
  --report /tmp/sparse-wire.json
```

The wire lab creates a 1 GiB sparse file, verifies three 64 KiB payloads, tests
holes, actual NFS create modes, rename replacement, stale handles, timestamps,
crash/reopen, truncate/regrow and catalogue rollback. These are actual local
process and NFS protocol tests, not live R2 or native anonymous-memory paging.

The hosted Mac workflow separately runs real mounted create/ftruncate, writes,
dirty mmap/msync, fsync, five unmount/restart/remount phases and a one-second
server pause on Intel and arm64. `--ci-mount` is restricted to disposable
CLOUDSWAP hosted CI. No system swap setting is changed by this laboratory.

The first mounted run exposed a test-accounting error on both architectures:
`stat().st_blocks` was treated as the committed payload allocation. Apple's
NFSv3 source returns `va_data_alloc`, while `vn_stat` requests `va_total_alloc`;
VFS can synthesise the latter from logical file size. The test now records the
client stat value separately, checks NFS GETATTR `used`, and bounds the actual
backing files' lengths and allocated blocks, including metadata and retained
versions. Directory/filesystem overhead is excluded from that measurement.
See pinned [NFS getattr](https://github.com/apple-oss-distributions/NFS/blob/93733ffccece4daee73bf6306b291d1ae69130c0/kext/nfs_vnops.c#L2134),
[vn_stat](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/vfs/vfs_vnops.c#L1537)
and [VFS fallback](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/vfs/kpi_vfs.c#L2968).

At the implementation checkpoint, 73 native tests (16 new sparse-volume tests),
four Rust tests, the sparse wire/crash/rollback lab and the original 4 MiB
pipelined wire regression passed locally.

### Mounted results, 10 November 2026

[Run 42855793571](https://github.com/EmotiveImpact/CLOUDSWAP/actions/runs/42855793571)
passed both hosted Mac jobs at source commit
`9d304ea3db009731b53a4e66243cf568ca36a9e7`:

| Host | Lifecycle and cold verification | Allocated backing files after creation | One-second pause cycle |
|---|---|---|---|
| Intel macOS 15.7.9 | All five mounted phases passed | 331,776 bytes | Recovered; worker cycle 1.566 s |
| arm64 macOS 15.8.2 | All five mounted phases passed | 331,776 bytes | Recovered; worker cycle 1.125 s |

Each file had a **logical** size of 1 GiB, with three 64 KiB payload regions and
a dirty mapped-write modification. This does not mean 1 GiB of data was stored
or memory was offloaded. Both clients reported 1 GiB through `stat`, while
NFS GETATTR reported 213,356 bytes of referenced encrypted payload and the
backing-file inventory occupied 331,776 allocated bytes. After truncation to
17 bytes and regrowth, NFS referenced one encrypted page (16,412 bytes); retained
versions increased backing-file allocation to 356,352 bytes. This explicitly
shows why reclamation is still needed. Filesystem/directory overhead is excluded.

Every phase verified mapped and positioned reads; fresh unmount/process restart
and remount separated the phases. Cleared tails remained zero after regrowth.
The paused worker could not finish until the server resumed. Its cycle includes
startup and verification; it is not a page-fault latency or app responsiveness
measurement. The original fixed 4 MiB mounted regression also passed on both.

The unmodified JSON reports, original failed attempts, source/job/artifact IDs
and SHA-256 digests are preserved in [evidence/mac-sparse](evidence/mac-sparse).
The sparse wire test additionally covers actual process-group crash/reopen and
authentication failures. No live R2, physical Wi-Fi loss, physical external SSD
or native anonymous-memory swap through NFS was exercised here.

At the same source revision, Intel foundation CI passed the native tests,
release packaging and helper/FUSE checks; Linux kernel-swap CI passed. The
macOS-latest foundation job remained queued at this checkpoint. Its result must
not be inferred from the separate passing arm64 macOS 15 mounted job.

## Next kernel gate

This completes a missing file lifecycle, but does not prove XNU accepts this
NFS filesystem for system swap. Before a new kernel trial: review allocation
and free-space requirements, the gateway's memory residency, timeout/recovery
behaviour and object reclamation. The HTTP transport also needs a streamed
response-size bound: `R2Client.request` currently calls `URLSession.data(for:)`
before page-size validation, so its response buffering is not yet a guaranteed
bounded-memory path. The current conservative object budget is
deliberately smaller than the advertised maximum sparse file size. No menu-bar
activation or working-Mac swap changes are included.


## Kernel source follow-through

Pinned XNU `f6217f891ac0bb64f3d375211650a4c1ff8ca1ea`,
[`bsd/vm/vm_compressor_backing_file.c`](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/vm/vm_compressor_backing_file.c),
opens future swap files with create/truncate, rejects a mount marked NOSWAP,
sets their size and uses vnode page-in/page-out. The optional pin ioctl failing
is not fatal in that source. This supports testing the file lifecycle built
here, but does not prove the running NFS client accepts encrypted swap UPLs.

The same XNU snapshot's
[`bsd/kern/kern_mman.c`](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/kern_mman.c#L1738)
returns ENOSYS from mlockall/munlockall. Do not port a Linux gateway by assuming
mlockall makes its complete Swift/Rust runtime resident on Mac. Explicit
critical-region residency or an independently hosted gateway needs a separate
implementation and measurement. No mlockall call or pressured NFS kernel swap
experiment was run on the working Mac.

The object-budget regression fills the retained-entry budget with zero-data
hard links, verifies that further writes are rejected before publication, and
checks that committed data and checkpoint remain readable. Catalogue commits
reserve a temporary-file slot so a crash at the budget boundary does not exceed
the bounded recovery inventory. Native release packaging, signature checks,
18 existing helper/FUSE tests and 28 diagnostic/R2 tests also passed locally.
