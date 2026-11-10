# CLOUDSWAP

Research towards cloud-backed swap for existing macOS applications, with a native menu-bar app and a portable Rust core.

**Current build does not redirect macOS swap or demonstrate reclaimed disk space.** It provides a native Mac menu-bar app, encrypted local/external storage, an R2 pager and optional full local mirror. Actual Linux kernel paging and controlled disconnects are verified against a loopback HTTP object service. Live R2, physical drive/Wi-Fi tests and native Mac swap attachment remain unverified.

**Continuing in Codex? Start with [CODEX-HANDOVER.md](docs/CODEX-HANDOVER.md) and [CHAT-CONTEXT.md](docs/CHAT-CONTEXT.md).** The implementation, research submodules and handover records are on `main`. [PR #1](https://github.com/EmotiveImpact/CLOUDSWAP/pull/1) was merged after all three CI workflows passed.

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

Pinned XNU, ipsw and symbolicator source checkouts are included as Git submodules. Run `git submodule update --init --depth 1 -- research/kernel-sources` to fetch them. Read the [kernel source findings](research/kernel/FINDINGS.md) and [multi-Mac test plan](docs/MULTI-MAC-TEST-PLAN.md). The newly identified `vm.swapfileprefix` candidate is unverified on a running target; no system swap changes have been made. `python3 scripts/mac-capabilities.py` collects a read-only report for each test Mac.

The [expanded disaggregated-memory collection](research/disaggregation/README.md) pins 23 upstream repositories and records their relevance, platform dependencies and reuse experiments. Download these selectively to avoid filling your Mac with upstream kernel trees.
