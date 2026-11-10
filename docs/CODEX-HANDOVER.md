# Codex handover
Updated 10 November 2026. Read this before continuing CLOUDSWAP.

## Checkout and source of truth
- Repository: https://github.com/EmotiveImpact/CLOUDSWAP
- Integration branch: `main` (PR #1 merged on 10 November 2026).
- Merged PR: https://github.com/EmotiveImpact/CLOUDSWAP/pull/1
- Last tested implementation commit: `dc57860314fb3a16468fd23258770610f6e111ad`.
- PR #1 merged at `7baee59f386abfb391cd6a377228a4034880da18`. All three CI workflows passed on its final head `1448df929e44dadabfe5dfa5c0464eb7eed95665`. Start new work from current `main`, inspect the working tree, and use a new feature branch.
- Read [chat context](CHAT-CONTEXT.md), [external storage](EXTERNAL-STORAGE.md), [validation](VALIDATION.md), [work packages](WORK-PACKAGES.md) and [research](../research/RESEARCH.md).
- The original session's local checkout was behind the remote branch, with tracked edits and untracked Linux lab files. Prefer a fresh checkout of remote main. Preserve local changes if reusing that checkout.

## What works, precisely
| Capability | Status |
|---|---|
| Mac menu-bar monitor and labelled Rust policy simulation | Built and signed; interactive clicks not verified |
| Encrypted local/external folder storage | Implemented; temporary-file tests pass |
| Menu action to select an external-drive folder | Built; writes, reopens and checks 1 MiB of synthetic pages |
| R2 signed encrypted object probe and remote pager | Implemented; live R2 interoperability not tested |
| Full encrypted local mirror for remote pager | Library option; offline read/reopen tests pass |
| Actual kernel paging | Proven in isolated Linux VM against loopback HTTP object service |
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
6. First investigate the existing swapfileprefix candidate using the kernel findings and isolated-system test plan. If it fails, identify the exact blocker, then resolve the native Mac storage-adapter gate and separately prove that XNU actually selects it for swap. Original research considered SCSIControllerDriverKit software I/O; verify SDK, OS support and entitlements against current Apple sources. No adapter implementation or supported swap registration route has been demonstrated. A block device appearing in Disk Utility is not proof of swap.
7. Only after isolated Mac kernel paging works, run application survival, 1/10/60-second outages, blackholes, sleep/wake, recovery and net-space trials. Do not change the user's working system swap merely to make a demonstration appear complete.
8. Keep Cairn file offloading separate until durable file restore, keys, metadata and consent are designed.

User expects continued implementation and testing without repeated requests to proceed. Report genuine missing access/hardware/credentials precisely. Do not equate passing storage tests with a completed Mac swap product.
