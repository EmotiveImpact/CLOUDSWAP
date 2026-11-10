# CLOUDSWAP

Research towards cloud-backed swap for existing macOS applications, with a native menu-bar app and a portable Rust core.

**The menu-bar app does not redirect macOS swap or demonstrate reclaimed disk space.** It provides a native Mac menu-bar app, encrypted local/external storage, an R2 pager and optional full local mirror. Actual Linux kernel paging and controlled disconnects are verified against a loopback HTTP object service. Live R2, physical drive/Wi-Fi tests and native Mac external/cloud swap attachment remain unverified.

**Continuing in Codex? Start with [CODEX-HANDOVER.md](docs/CODEX-HANDOVER.md) and [CHAT-CONTEXT.md](docs/CHAT-CONTEXT.md).** PR #8 consolidates the subsequent research, storage integrity, tiered trial and native file adapters on `feat/mac-integration-lab`. Check its merge state before choosing a checkout. The menu-bar foundation is already on `main`.

## Build on a Mac

Requires macOS 13+, Xcode command-line tools and a Rust toolchain on PATH. No third-party Swift or Rust packages are required for this foundation.

```sh
cargo test --offline
bash scripts/build-mac.sh
open dist/CLOUDSWAP.app
```

The menu shows swap usage, available disk space and network-path availability. Its simulation button launches the bundled Rust helper. **Test external drive folder…** writes and verifies 1 MiB of encrypted synthetic pages in a selected folder. Interactive acceptance and physical unplug/replug remain pending. Network availability does not mean R2 is reachable. The app is ad-hoc signed for local development, not notarised for distribution.

## Native R2 experiment

```sh
.build-cache/package/release/R2Lab --self-test
.build-cache/package/release/R2Lab --live
.build-cache/package/release/R2Lab --pager-live
```

Live mode requires `R2_ENDPOINT`, `R2_BUCKET`, `R2_ACCESS_KEY_ID` and `R2_SECRET_ACCESS_KEY` supplied securely in the process environment. Do not commit secrets or paste them into an issue. Use a dedicated private test bucket and bucket-scoped object read/write credentials. The probe uploads 16 KiB of encrypted synthetic data, reads and authenticates it, then deletes only that unique test object. Cleanup failure reports the object key for later removal. It does not upload app memory or files.

The Swift R2 client is connected to the native RemotePager. The Rust component remains a separate policy simulator. Its SigV4 implementation is compiled but awaits live interoperability verification. This small bounded experiment is not a production R2 SDK.

## Layout

- `apps/macos`: SwiftUI menu-bar app and native CryptoKit/URLSession R2 probe.
- `crates/cloudswap-core`: Rust acknowledgement and failure policy; simulated transport only.
- `labs/linux-python`: original AES-GCM/R2 storage prototype and nbdkit adapter.
- `labs/linux-vm`: verified Linux kernel paging and controlled HTTP disconnect lab using QEMU and nbdkit.
- `research`: pinned upstream source archives, provenance manifests and porting analysis.
- `docs`: architecture, evidence and next verification gates.

See [research](research/RESEARCH.md), [architecture](docs/ARCHITECTURE.md), [validation](docs/VALIDATION.md), and [work packages](docs/WORK-PACKAGES.md).

Cairn may later reuse cloud storage and retrieval components for file offloading. That requires durable keys, metadata and restoration semantics beyond ephemeral swap. It remains a separate feature track.

## Kernel research and multiple Macs

Pinned XNU, ipsw and symbolicator source checkouts are included as Git submodules. Run `git submodule update --init --depth 1 -- research/kernel-sources` to fetch them. Read the [kernel source findings](research/kernel/FINDINGS.md) and [multi-Mac test plan](docs/MULTI-MAC-TEST-PLAN.md). The `vm.swapfileprefix` control has now been exercised on a disposable hosted Intel Mac, with separate APFS virtual-volume paging evidence in PR #9. No change was made to the working Mac's swap configuration. `python3 scripts/mac-capabilities.py` collects a read-only report for each test Mac.

The [expanded disaggregated-memory collection](research/disaggregation/README.md) pins 23 upstream repositories and records their relevance, platform dependencies and reuse experiments. Download these selectively to avoid filling your Mac with upstream kernel trees.

Additional [Mac kernel candidates](research/mac-candidates/README.md) are pinned separately. The [read-only swap-evidence collector](docs/MAC-SWAP-EVIDENCE.md) measures candidate placement without changing system swap.

Use the [combined cloud and local-mirror trial](docs/TIERED-STORAGE-TRIAL.md) to verify remote reads, simulated offline recovery, failed-write handling and allocated file sizes. Available through the Mac menu or R2Lab CLI.

See the [FUSE feasibility review](research/fuse/README.md) for six pinned filesystem candidates, cache-space risks, flush semantics and the remaining Mac paging gate.

### Native encrypted file adapter

`labs/macos-fuse` now provides an experimental fixed-size FUSE frontend and a
native helper protocol over local/external, remote and mirrored page backends.
[Run instructions and limits](labs/macos-fuse/README.md) and
[verification evidence](labs/macos-fuse/validation.json) distinguish tested
callbacks and process recovery from the still-unverified mount and Mac swap path.

### Rust bridge through the built-in Mac NFS client

[The NFS laboratory](labs/macos-nfs/README.md) exports the same encrypted file
without a third-party filesystem runtime. Its separate Cargo.lock pins a
BSD-licensed server and dependencies. The main app still builds offline without
those dependencies. The wire and mounted tests have separate results; neither
constitutes native system-swap attachment.

The [integration validation](docs/INTEGRATION-VALIDATION.md) now records actual
Mac NFS mounts and one-second server-pause recovery on Intel and Apple Silicon.
[PR #9](https://github.com/EmotiveImpact/CLOUDSWAP/pull/9) adds a separately guarded
native kernel placement experiment, with initial Intel APFS virtual-volume
paging evidence. Physical SSD and live R2 acceptance remain separate gates.
