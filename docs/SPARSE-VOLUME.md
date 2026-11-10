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

At the initial implementation checkpoint, 72 native tests (15 new sparse-volume
tests), four Rust tests, the sparse wire/crash/rollback lab and the original
4 MiB pipelined wire regression passed locally. Mounted results must be read
from the corresponding workflow artefacts before they are claimed.

## Next kernel gate

This completes a missing file lifecycle, but does not prove XNU accepts this
NFS filesystem for system swap. Before a new kernel trial: review allocation
and free-space requirements, the gateway's memory residency, timeout/recovery
behaviour and object reclamation. The current conservative object budget is
deliberately smaller than the advertised maximum sparse file size. No menu-bar
activation or working-Mac swap changes are included.
