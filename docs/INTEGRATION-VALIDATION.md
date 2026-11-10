# Mac integration validation, 10 November 2026

PR #8 combines PRs #2 through #7 and adds a Rust bridge to the built-in Mac NFS
client. It preserves the six branch heads as ancestors. This is a tested storage
prototype; existing Mac applications do not yet use it for anonymous system swap.

## Mounted proof

[Workflow 42842730223](https://github.com/EmotiveImpact/CLOUDSWAP/actions/runs/42842730223)
passed on both hosted Mac architectures at revision
`858b0172ee9efb8fead5743b36ad1acec5dbb925`.

| Test host | Mounted operations | One-second server pause |
|---|---|---|
| Intel, macOS 15.7.9 / 24G830 | 4 MiB write, fsync, unmount, process restart, remount and complete readback | Cold worker blocked then verified all bytes, 1.666 seconds total |
| arm64, macOS 26.7.2 / 25G332 | Same operations and file-backed mmap read verification | Cold worker blocked then verified all bytes, 1.201 seconds total |

The pause used SIGSTOP/SIGCONT on the server/helper process group. It was not a
physical Wi-Fi interruption. The clean remount preceded the paused read; this
was not a successful read from an already warmed file in the worker. These
runs used encrypted local page storage, not a live R2 bucket or external SSD.
Neither architecture inherits a physical-device or system-swap acceptance result.

Machine-readable reports are preserved in `docs/evidence/nfs`, including
run/revision provenance. The fixed file's apparent 4 MiB capacity is not evidence
of internal disk space reclaimed.

## Integrity and regression coverage

- 57 native XCTest tests passed locally, including missing and authenticated
  rolled-back index checks in both native stores.
- 18 FUSE/helper process tests and 22 diagnostic/research Python tests passed.
- The signed release app rebuilt and passed deep/strict signature verification.
- Two Rust NFS bounds tests and the real 4 MiB wire test passed. The wire test
  includes 32 pipelined writes, 64 FILE_SYNC acknowledgements, explicit COMMIT,
  process-group death/reopen, malformed write lengths and oversized RPC rejection.
- Restoring an older correctly authenticated index during a session makes NFS
  COMMIT fail and stops further page service. This does not establish rollback
  detection across restarts without an independently trusted generation counter.
- The new pipelined test times out against the earlier `e58429d2` source tree and
  passes after separating bounded TCP intake, processing and reply flows.

The initial mounted run timed out before this deadlock fix. Its timeout remains
part of the record; a sequential wire pass had not detected that failure.

## Scope still requiring proof

Live R2 interoperability, physical external-drive removal, physical Wi-Fi drops,
long outages, sleep/wake, persistent keys, production authentication, a gateway
memory-reservation strategy, XNU swap attachment, native application survival and
net internal-space savings are not demonstrated by these results.

The current laboratory has only a fixed-size file. It does not implement XNU's
create/truncate/resize swap-file lifecycle. Read-only root capability reports
show the prefix is exposed on both hosted architectures. Writing the unchanged
stock value is a separate capability probe, not a placement or migration test.

## Extended mapped-write and prefix-control result

[Intel job 129926827079](https://github.com/EmotiveImpact/CLOUDSWAP/actions/runs/42844108611/job/129926827079)
at `97d4fe13303bd9a5a67b4c19b53812fbb3d34f92` additionally passed a dirty
file-backed mmap, msync/fsync, remount and cold mapped reads. Its one-second
pause recovered in 1.456 seconds. Root accepted a write of the unchanged stock
swap prefix. Reports use the `intel-extended-` prefix in the evidence directory.

The separate native placement experiment in
[PR #9](https://github.com/EmotiveImpact/CLOUDSWAP/pull/9) subsequently observed
actual kernel PgOut/PgIn events against a separate APFS disk-image volume on
Intel macOS 15.7.9. It verified an 8.0625 GiB synthetic workload and restored the
original prefix. This is a virtual-volume result, not a physical SSD or R2 result.
The menu-bar app still does not redirect system swap.

The mounted matrix now explicitly tests macOS 15 Intel and arm64. The earlier
macOS 26 arm64 mount result remains a separate verified cohort. Additional
queued coverage does not invalidate those recorded results or certify a new host.


The [final placement record](MAC-PLACEMENT-VALIDATION.md) now includes successful
Intel and arm64 schema 2 runs. These independently demonstrate paging on their
APFS disk-image volumes. They do not turn the fixed NFS adapter into a kernel
swap implementation. The live R2 acceptance workflow is merged and its saved
readiness report confirms missing configuration, with the live test skipped.
