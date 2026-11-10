# Kernel projects assessed, 10 November 2026

## What we actually possess

The source verifier passed for both complete tracked XNU trees already checked out:

- `xnu-macos14.5`: commit `2c2f96dc2b9a4408a43d3150ae9c105355ca3daa`, 5,193 tracked files, host-matching release source.
- `xnu`: commit `f6217f891ac0bb64f3d375211650a4c1ff8ca1ea`, 5,698 tracked files, newer comparison source.

These are complete published source snapshots at those revisions, not all historical versions, complete macOS source, or built replacement kernels. The XNU README describes SDK/KDK-dependent builds. Possessing sources does not establish buildability with the installed tools, bootability on this Mac, availability of private drivers, or a working swap attachment.

## User-supplied candidates

| Source | Finding | Decision |
| --- | --- | --- |
| [apple-oss-distributions/xnu](https://github.com/apple-oss-distributions/xnu) | Primary published Mach/BSD/IOKit kernel source; already acquired twice | Continue tracing swapfileprefix, vnode paging and storage restrictions |
| [acidanthera/MacKernelSDK](https://github.com/acidanthera/MacKernelSDK) | Kext headers and libraries; README lists x86_64/universal kmod libraries and older compatibility targets | Useful header reference; do not assume Apple-silicon linking, driver loading or swap capability |
| [apple/darwin-xnu](https://github.com/apple/darwin-xnu) | Explicit legacy mirror replaced by apple-oss-distributions/xnu | Historical comparison only; not a new modern kernel implementation |
| [wolffcatskyy/linux-mac](https://github.com/wolffcatskyy/linux-mac) | Retired Linux/KVM Mac Pro 6,1 project | Does not attach remote storage to the running macOS host pager |
| [apple/containerization](https://github.com/apple/containerization) | Linux containers in lightweight VMs; current README requires Apple silicon, macOS 26 and Xcode 26 | Potential future Linux test harness; not supported on the previously inspected macOS 14.5 host and not native Mac application paging |
| [elliotnunn/NanoKernel](https://github.com/elliotnunn/NanoKernel) | Reverse-engineered classic PowerPC Mac OS kernel | Historically useful; unrelated architecture and OS for this implementation |
| [Apple releases](https://opensource.apple.com/releases/) | Release-indexed open-source distributions | Use for matching sources to each test OS |

The supplied kernel.org link is truncated, so the specific Linux commit cannot be identified. The Wikipedia/Hacker News snippets add no implementation proof beyond primary sources. Newly listed repositories were reviewed as references, not all cloned in this pass.

## Build decision

Continue the existing native Swift app and encrypted backend. This pass adds exact ciphertext-size validation shared by remote reads and mirrored-page reopening, plus regressions for missing committed pages, short/oversized data, stale generations and cross-block substitution. CryptoKit authentication already provided identity/integrity protection; the change makes the wire-size contract explicit before decryption and exercises the failure boundaries. This is storage integrity work, not a new kernel driver.

The decisive native experiment remains the existing isolated-system swapfileprefix test plan. Prove that new real swap files can be placed on the selected test volume, then test external SSD behaviour. Existing open swap files do not automatically migrate when a prefix changes. Cloud-backed block attachment, fault-path memory allocation/deadlock behaviour, outages and net internal-space savings remain separate gates. Do not alter the daily-use Mac's swap or startup security during routine prototype validation.
