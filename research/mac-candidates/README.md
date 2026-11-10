# Additional Mac kernel candidates

Five additional user-supplied GitHub repositories are pinned in `sources/`; the two complete published XNU snapshots remain pinned under `research/kernel-sources`. `manifest.json` records exact commits, tree hashes and root-document hashes. This acquisition does not merge upstream code into the app.

| Repository | What it contributes | What it does not solve |
| --- | --- | --- |
| acidanthera/MacKernelSDK | Kext headers, compatibility definitions and kmod support source | Bundled universal libraries contain x86_64 and i386, not arm64; no remote pager or proven swap attachment |
| apple/darwin-xnu | Historic Darwin source for comparisons | Superseded mirror; no new current integration path |
| wolffcatskyy/linux-mac | Retired Mac Pro 6,1 Linux/KVM configuration research | Does not redirect a running macOS host's swap |
| apple/containerization | Swift/Linux VM infrastructure for future test harnesses | Current README requires macOS 26/Xcode 26; not a macOS app pager or a harness usable on the inspected 14.5 host |
| elliotnunn/NanoKernel | Classic PowerPC Mac OS kernel research | Different OS and CPU architecture from modern Apple-silicon macOS |

The authoritative XNU project is already acquired. Its source led to the `vm.swapfileprefix` candidate and the vnode paging path described in `research/kernel/FINDINGS.md`. This makes a focused experiment possible, not a claim that external/cloud system swap works.

## Download status

MacKernelSDK was fully checked out at the pinned revision and its root-document hashes and compiled library architectures inspected. The other four are pinned Git references with root documents reviewed; full source trees were not downloaded in this pass. Pins depend on continued upstream availability and are not independent source archives. Existing XNU checkouts were verified in the earlier working directory; this new worktree does not duplicate them.

From the repository root:

```sh
git submodule update --init --depth 1 -- research/mac-candidates/sources/acidanthera--MacKernelSDK
python3 scripts/verify-mac-candidates.py
```

Fetch another source by substituting its exact path from `manifest.json`. Fetch all five with `git submodule update --init --depth 1 -- research/mac-candidates/sources` if enough disk space is available. Nested dependencies are not initialised automatically. Licences remain upstream, unchanged. Presence of a root notice is not a complete licence audit or permission to combine all code under CLOUDSWAP's licence.

Wikipedia, Apple release-index pages and news comments are references rather than Git repositories. The supplied kernel.org URL was truncated and cannot identify a specific commit.

## Implemented from this investigation

[`mac-swap-evidence.py`](../../scripts/mac-swap-evidence.py) collects read-only before/after evidence for the native Mac test. See [usage and interpretation](../../docs/MAC-SWAP-EVIDENCE.md). The diagnostic does not change swap, create memory pressure or claim that filenames alone prove kernel I/O. Source pinning, encrypted-page integrity work (PR #3) and this diagnostic are separate from the still-unimplemented native swap attachment.
