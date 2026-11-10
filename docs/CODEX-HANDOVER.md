# Codex handover
Updated 10 November 2026. Read this before continuing CLOUDSWAP.

## Current integration checkpoint

PR #8 (`feat/mac-integration-lab`) consolidates every change from PRs #2 through
#7, preserving their branch ancestry. It merged into `main` at `08e3e8637cbf63b8599fe2fb6c1583d61004b903`;
PRs #2 through #7 are also merged by ancestry.

That integration checkpoint had 57 passing XCTest tests, including loss/rollback of
an encrypted index during a session. Checkpoint reauthenticates and compares the
persisted index before acknowledging flush. This is not rollback prevention
across restarts without a trusted external generation counter.

`labs/macos-nfs` adds a Rust NFSv3 bridge using the same Swift encrypted helper.
Its wire test covers 4 MiB, pipelined FILE_SYNC writes, explicit COMMIT, process
death/reopen, malformed requests and fail-stop on authenticated index rollback.
The Mac mounted workflow separately tests actual mount, fsync, remount, mmap
reads and a one-second server pause on Intel and arm64 hosted Macs. Check its
latest result; wire success does not imply mount success.

No working-Mac swap configuration has been changed. The mounted NFS proof
passed on Intel macOS 15 and arm64 macOS 26; the extended Intel test also passed
dirty mmap/msync and cold remount verification. See [integration evidence](INTEGRATION-VALIDATION.md).
PR #9 separately observed real kernel page-out/page-in against a new APFS
disk-image volume on the hosted Intel Mac, with complete 8.0625 GiB workload
integrity. Physical external-drive use/unplug, cloud-backed Mac system swap,
live R2 and internal disk savings remain unverified. The prototype is not ready to carry private live application memory.
Read [CHAT-CONTEXT.md](CHAT-CONTEXT.md), [WORK-PACKAGES.md](WORK-PACKAGES.md),
[the NFS lab](../labs/macos-nfs/README.md) and the dated validation records.

The placement experiment also repeated successfully on Intel with 8.25 GiB
verified. See [its evidence and limitations](../labs/macos-swap-placement/README.md),
including the corrected thread-ID interpretation. Apple Silicon macOS 15.8.2
then also observed target-volume kernel page-out/page-in, verified 3.375 GiB
and restored its prefix. See [current placement results](MAC-PLACEMENT-VALIDATION.md).
No physical external SSD or live R2 result is implied.

PR #10 merged the [live R2 acceptance runner](LIVE-R2-ACCEPTANCE.md). Its CI
readiness check confirmed that all four required repository secrets are absent;
the live job correctly skipped. Configuration names, test commands and the
recorded result are in that document. Never put credential values in the repo.

## Growable storage increment

`feat/mac-sparse-volume` adds `SparseVolume`, `R2Lab --volume-server` and
`cloudswap-nfs-lab --sparse-lab`: encrypted sparse files with create/resize,
atomic multi-page mapping commits, truncate/regrow, rename/replacement and
persistent exclusive-create verifiers. See [SPARSE-VOLUME.md](SPARSE-VOLUME.md)
for exact limits. Objects are retained and capped, not garbage-collected; this
is still a synthetic laboratory. The existing fixed-file mode remains tested.
Check the branch/PR and hosted mounted results before claiming this increment
is merged or that it provides native system swap.

The new native suite has 73 passing tests, including uncertain multi-page
writes, restart, sparse holes, shrink/regrow, authenticated cross-file rejection,
single-writer ownership, overlapping operations and bounded object exhaustion.
The first mounted attempt caught a Darwin allocation-reporting assumption in
the test. Actual backing-file allocation and NFS GETATTR are now checked
separately from client `stat` output. Original failure reports are preserved in
`docs/evidence/mac-sparse/`.

## Earlier milestones and implementation map

The records below describe successive earlier milestones. Test counts and
statements that runtime prefix access or all native paging are unverified are
historical and superseded by the checkpoint above. References to separate
feature branches are superseded by PR #8.

## What works, precisely
| Capability | Status |
|---|---|
| Mac menu-bar monitor and labelled Rust policy simulation | Built and signed; interactive clicks not verified |
| Encrypted local/external folder storage | Implemented; temporary-file tests pass |
| Menu action to select an external-drive folder | Built; writes, reopens and checks 1 MiB of synthetic pages |
| R2 signed encrypted object probe and remote pager | Implemented; live R2 interoperability not tested |
| Full encrypted local mirror for remote pager | Library option; offline read/reopen tests pass |
| Actual kernel paging | Linux HTTP lab, plus separate APFS virtual-volume placement on hosted Intel and arm64 Macs |
| Existing Mac apps using external/cloud swap | Not implemented |
| Internal disk savings and app responsiveness | Not demonstrated |

External and cloud backends are not a finished automatic two-tier swap product. Mirror mode is `RemotePager(..., mirror: true)`, not a UI setting. Its local directory can be on an external drive. Writes require remote acknowledgement; mirrored reads do not require the network. A full mirror on the internal disk largely consumes the storage the project aims to save.

## Implementation map
- `apps/macos/Sources/CloudSwap/CloudSwap.swift`: SwiftUI menu-bar app, actual metric queries, network-path monitor, Rust simulation launcher and external-folder test.
- `apps/macos/Sources/PagingStore/PagingStore.swift`: AES-GCM local pages and index, single-writer lock, 16 KiB pages, 256 logical pages.
- `StoreDirectory.swift`: directory descriptor, identity checks, relative I/O, bounded reads, symlink rejection, file fsync / atomic rename / directory fsync.
- `RemotePager.swift`: ObjectBackend protocol, actor, encrypted index, immutable object names, uncertain-write stop, optional full local mirror and committed ciphertext byte counter.
- `apps/macos/Sources/R2Lab/R2Lab.swift`: bounded SigV4 requests, redirect refusal, 2.5-second transient GET retry budget, crypto self-test, live object and integrated pager probes.
- `crates/cloudswap-core`: Rust policy emulator. Not the native Swift paging engine and not a kernel driver.
- `labs/linux-python`: original nbdkit/R2 reference experiment.
- `labs/linux-vm`: QEMU guest, C memory probe, Python encrypted NBD gateway and HTTP fault service. Gateway runs outside constrained guest.
- `research`: pinned s3backer and Infiniswap archives, provenance manifests, licences, research analysis. 75 source blobs were verified.
- `scripts/build-mac.sh`: bundles app and helpers with ad-hoc signatures. Not notarisation.

## Verified evidence
- 29 native XCTest tests passed locally on the implementation commit.
- Mac release build, packaged app signature verification and both bundled helpers passed locally.
- Foundation CI passed: https://github.com/EmotiveImpact/CLOUDSWAP/actions/runs/42819009576
- Linux kernel paging CI passed: https://github.com/EmotiveImpact/CLOUDSWAP/actions/runs/42819009535
- Previous detailed Linux run: https://github.com/EmotiveImpact/CLOUDSWAP/actions/runs/42817495281
- That previous run recorded 6,120 swap-outs and 6,153 swap-ins in baseline, with all 24 MiB verified. One-second outage with a 2.5-second retry budget recovered and verified all data. Fail-fast and four-second outage cases produced SIGBUS. Timings were approximately 3.325 seconds baseline and 4.272 seconds short-outage recovery, measured ready-to-exit. These are lab observations, not Mac app performance predictions.
- Native tests inject network responses and model drive-path disappearance by renaming directories. They do not prove physical USB/Wi-Fi disconnect behaviour.
- Local app launch failed with LaunchServices error -10822. DiskManagement/DiskArbitration access was unavailable. Do not mark GUI or physical drive acceptance complete.
- Required R2 environment configuration was absent. No live bucket test was run.

## Build and run
On a suitable Mac with Xcode command-line tools and Rust configured:
```sh
git clone --branch main https://github.com/EmotiveImpact/CLOUDSWAP.git
cd CLOUDSWAP
cargo test --offline
swift test --package-path apps/macos
bash scripts/build-mac.sh
dist/CLOUDSWAP.app/Contents/Helpers/R2Lab --self-test
dist/CLOUDSWAP.app/Contents/Helpers/cloudswap-lab
open dist/CLOUDSWAP.app
```
If an existing checkout is present, inspect it before switching or pulling. Never discard changes to reproduce these instructions.

In the prior restricted local environment, Swift tests needed `--disable-sandbox --cache-path /tmp/cloudswap-swift-cache -Xswiftc -module-cache-path -Xswiftc /tmp/cloudswap-module-cache`. This disables SwiftPM's nested sandbox only. Packaging required the installed Cargo directory on PATH and `RUSTUP_TOOLCHAIN=1.88.0-aarch64-apple-darwin`. These are environment-specific workarounds, not universal prerequisites.

Live R2 needs `R2_ENDPOINT`, `R2_BUCKET`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` supplied securely. Use a dedicated private test bucket with scoped credentials. Never commit values. Run the packaged R2Lab with `--live` for the object probe or `--pager-live` for integrated remote write/reopen/read/cleanup. Record cleanup failures.

## Kernel mining update

Pinned clones of XNU (host-matching and newer revisions), ipsw, symbolicator and Apple's system_cmds are now attached as submodules under `research/kernel-sources`. Initialise them with `git submodule update --init --depth 1 -- research/kernel-sources`. Read [kernel findings](../research/kernel/FINDINGS.md) and [multi-Mac testing](MULTI-MAC-TEST-PLAN.md).

Apple's dynamic_pager source also writes this prefix, but its cleanup can unlink swap-prefixed files and its exit code does not reliably indicate success. Do not run it as a casual live-migration command. Both reviewed XNU revisions register `vm.swapfileprefix` as a writable string. Investigate this existing control point on an isolated system before assuming a custom driver is mandatory. Local read access was denied, so runtime support remains unverified. The unsupported old swapon API alone does not rule this candidate out. No swap configuration has been changed.

Run `python3 scripts/mac-capabilities.py` on each target to collect a read-only report. Separate physical tests from VM/CI evidence. Source map generation, pinned-checkout checks and four diagnostic regression tests are included.

## Continue here
1. Review latest code and tests, then address recovery gaps: failed-write orphan accounting/reclamation, disk-full failures, abrupt process death, concurrency during awaited I/O, missing/corrupt objects and index rollback. Preserve uncertain-write fail-stop behaviour.
2. Provide durable key management before persistent real data. Current keys are caller-owned; synthetic UI test keys are ephemeral. Do not represent a saved encrypted directory as recoverable without its key.
3. Add persisted backend settings and accurate UI states only as corresponding capabilities become verified. Full-mirror byte reporting currently excludes allocation overhead, index and orphan files; measure actual allocated bytes.
4. On an accessible Mac, test the external-folder action and controlled unplug/replug with synthetic data. Record mount identity, errors, recovery and retained test files. Do not unplug a drive containing live application swap.
5. Run live R2 tests once credentials and network access exist, then measure latency, request amplification and cost, throttling and failure behaviour.
6. Continue from the now-proven disposable APFS placement, not the historical assumption that all prefix access is blocked. Review a separate physical-SSD installation/recovery design and the new growable NFS adapter. The original 4 MiB mode lacks the required lifecycle; the new sparse mode adds it but still needs object reclamation, memory-residency design, authentication and proof of kernel page-in/page-out compatibility. Apple mlockall returns ENOSYS in the pinned source. Prove each adapter and workload independently before exposing activation in the app. A block device appearing in Disk Utility is not proof of swap.
7. Only after isolated Mac kernel paging works, run application survival, 1/10/60-second outages, blackholes, sleep/wake, recovery and net-space trials. Do not change the user's working system swap merely to make a demonstration appear complete.
8. Keep Cairn file offloading separate until durable file restore, keys, metadata and consent are designed.

User expects continued implementation and testing without repeated requests to proceed. Report genuine missing access/hardware/credentials precisely. Do not equate passing storage tests with a completed Mac swap product.

## Expanded memory-disaggregation research

See [the 23-repository collection](../research/disaggregation/README.md) and [findings/reuse plan](../research/disaggregation/FINDINGS.md). All references are pinned; only r3map, ram-dl and fastswap were additionally downloaded and selectively code-reviewed in this pass. Avoid global recursive submodule checkout because several upstream projects contain complete kernels. Use the selective commands in that README. The survey does not change the unverified status of native Mac system-swap attachment.

## Kernel candidate assessment and integrity increment

See [kernel project assessment](../research/kernel/PROJECT-ASSESSMENT.md) for the user's XNU, MacKernelSDK, linux-mac, Containerization and NanoKernel links. Both existing full published XNU snapshots were reverified. RemotePager now checks the exact combined AES-GCM page size before decrypting, including mirror reopen. Four added native regressions cover missing, malformed, stale and cross-block payloads; all 33 XCTest tests passed. This does not implement native system-swap attachment.

## Mac candidate pins and placement evidence

Five additional repositories are pinned in research/mac-candidates; MacKernelSDK is downloaded and its bundled libraries verified as Intel-only (x86_64/i386). Use docs/MAC-SWAP-EVIDENCE.md and scripts/mac-swap-evidence.py for read-only native test observations. 18 Python tests passed. Live snapshots saw swap-file metadata and counters but prefix and boot-session reads were denied, so comparison remained insufficient_evidence. No privileged swap changes were made.

## Combined cloud and mirror trial

See [TIERED-STORAGE-TRIAL.md](TIERED-STORAGE-TRIAL.md). The menu now includes a synthetic remote/offline-mirror trial using a selected local/external folder. R2Lab accepts --tiered-self-test and --tiered-live --directory EXISTING_FOLDER; the latter uses the real R2 adapter and an injected outage. Shared TieredTrial verifies remote reads separately from mirror reads, rejects offline writes, reopens the last committed page, measures allocated trial-file bytes and reports cleanup failures. Keys are ephemeral and reopen is within-process only. 38 native tests, the release build/signature and packaged synthetic trial passed. No credentials were available for a live R2 run. Native system swap remains unattached.

## Native file adapter, 10 November 2026

Branch `feat/fuse-file-adapter` adds an executable FUSE frontend, a bounded
stdin/stdout server in R2Lab and `VirtualPageFile` over the local, remote and
mirrored encrypted stores. Read [the adapter instructions](../labs/macos-fuse/README.md)
for exact commands, key handling, storage contract and remaining gates. The adapter and PR #5's tiered trial are now combined in PR #8.

The actual filesystem callbacks and helper-process restart are tested without a
mount. The current Mac has no FUSE runtime, so mounting and compatibility of the
pinned Python binding remain unverified. No native swap attachment, physical
unplug result, live R2 result or internal-space saving is claimed. `*-create`
rejects existing directories; a missing committed remote object no longer has
unwritten-page semantics. The protocol and tests never persist the encryption key.
