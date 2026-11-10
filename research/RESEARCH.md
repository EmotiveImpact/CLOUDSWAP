# Source review and Mac porting register

Reviewed 10 November 2026. Source snapshots preserve upstream bytes and licence notices; they are reference material and are not compiled into CLOUDSWAP. No claim of a complete audit of every upstream function.

## Acquisitions

| Source | Pin / evidence | What is reusable | What must change |
|---|---|---|---|
| [s3backer](https://github.com/archiecobbs/s3backer) | `76bab1493018e3388bf4da7ec714adb02ddd1d74`; all 49 source-tree blobs captured | Block/object mapping, cache design, flush/FUA semantics, sparse blocks, read-ahead | Linux NBD adapter is not a Mac swap adapter. Its FUSE/disk-image path is a virtual-disk candidate, not proof of swap eligibility |
| [Infiniswap](https://github.com/SymbioticLab/Infiniswap) | `da7c14bf749ccadb4ef44953579d55143e8e7182`; all 26 source-tree blobs captured | Paging workload methodology, device lifecycle, remote placement and fallback design | Linux kernel APIs, RDMA verbs and Mellanox assumptions require platform-specific replacement |
| [XNU swap syscall](https://github.com/apple-oss-distributions/xnu/blob/xnu-10063.121.3/bsd/vm/dp_backing_file.c) | Blob `120f18453e1666f9f0acc8c4fd7f8ee14bd2cfc7`; tag supplied by user | Establishes that `macx_swapon` and `macx_swapoff` return ENOTSUP | A user-space call cannot register our cloud backing file through these routines |
| [XNU backing-file I/O](https://github.com/apple-oss-distributions/xnu/blob/xnu-10063.121.3/bsd/vm/vm_compressor_backing_file.c) | Retrieved at the same tag | Kernel opens swap vnodes, rejects MNTK_NOSWAP mounts, preallocates files and uses vnode paging I/O | A mountable disk alone does not establish swap eligibility; all these interactions need a lab proof |
| [XNU backing store](https://github.com/apple-oss-distributions/xnu/blob/xnu-10063.121.3/osfmk/vm/vm_compressor_backing_store.c) | Retrieved at the same tag | `swapfilename` initialised from SWAP_FILE_NAME; internal file-creation path | No configurable external-pager interface established by this inspection |
| [Apple block-storage DriverKit](https://developer.apple.com/documentation/blockstoragedevicedriverkit) | Local Xcode IOUserBlockStorageDevice.iig inspected | C++ asynchronous read/write, synchronise, completion, geometry interfaces | Virtual provider matching, entitlements, activation and swap participation remain unproven |

Each upstream manifest records the commit, tree and original Git blob IDs. Archives contain complete source trees at those pins, not `.git` histories. `scripts/verify-sources.py` checks bytes against Git blob IDs after extraction. A full Git clone was attempted but local DNS access to github.com was unavailable; source acquisition used the connected GitHub API instead.

## Findings from source mining

### s3backer

`nbdkit.c` handles FUA writes by calling its block flush path, advertises native FUA, and propagates flush failures. `block_cache.c` coordinates dirty blocks and lower-layer flushing; `dcache.c` has a local fsync path. These are useful review targets for our eventual commit protocol. They must not be replaced by a successful acknowledgement before data is recoverable.

Its README describes a single file divided into S3 objects and a disk-image route on Mac OS X. That establishes historical Mac filesystem intent, not compatibility with current Apple Silicon swap. Some consistency discussion is historical; do not transplant its old S3 assumptions into R2 without checking current semantics.

### Infiniswap

The [authors' design explanation](https://infiniswap.github.io/) describes synchronous RDMA page-out with asynchronous local-disk backup; page-in selects the available source. `is_mq.c` includes stackbd backup I/O, while `is_main.c` contains device and RDMA lifecycle handling. Keeping a full local backup defeats our disk-space objective. We therefore need to measure the space-versus-offline-availability tradeoff explicitly rather than claiming equivalent reliability.

The [NSDI paper](https://www.usenix.org/system/files/conference/nsdi17/nsdi17-gu.pdf) and its [landing page](https://www.usenix.org/conference/nsdi17/technical-sessions/presentation/gu) returned HTTP 403 in this session. The full paper has not been reviewed; repository and author-site evidence were reviewed. No RDMA performance figures are treated as R2/Wi-Fi forecasts.

### macOS

The host reports macOS 14.5 / Darwin 23.5.0 / arm64. The supplied XNU tag is a research reference, not proven to be the exact source revision of that running kernel. No kernel change was attempted.

DriverKit's local header defines DoAsyncReadWrite, DoAsyncSynchronize, CompleteIO and device parameters including FUA support. This is a concrete C++ interface to investigate. It does not resolve whether a purely virtual provider can be shipped with the necessary entitlements or whether macOS will use that storage for swap. [Apple entitlement documentation](https://developer.apple.com/documentation/driverkit/requesting-entitlements-for-driverkit-development) is the next distribution dependency to verify in a developer account.

## Cloudflare sources supplied by the user

- [R2 API](https://developers.cloudflare.com/r2/api/) and [S3 compatibility](https://developers.cloudflare.com/r2/api/s3/api/): account endpoint, region `auto`, object operations. Used for the native probe and Python adapter. R2 is not a byte-addressable memory service.
- [R2 consistency](https://developers.cloudflare.com/r2/reference/consistency/): strong object consistency does not make several object updates one atomic block transaction, nor tell a timed-out caller whether its PUT committed. Immutable object versions plus explicit commit metadata are needed for a recoverable design.
- [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/): possible transport for a remote service, not an OS paging hook. Moving a workload is outside the primary requirement to support existing Mac apps.
- [Linux NBD](https://docs.kernel.org/admin-guide/blockdev/nbd.html): useful controlled block-device test interface. Its client kernel interface does not port directly to macOS.
- [nbdkit Python API](https://libguestfs.org/nbdkit-python-plugin.3.html): callback interface used by the preserved lab adapter.

## Economics to measure

[R2 Standard pricing](https://developers.cloudflare.com/r2/pricing/), checked 10 November 2026: storage $0.015/GB-month, Class A $4.50/million and Class B $0.36/million, before free allowances and billing rounding. One GiB written as independent 4 KiB objects is 262,144 PUTs, about $1.18 at the marginal Class A rate. At 16 KiB it is 65,536 PUTs, about $0.295. These are arithmetic examples, not bills or measured workloads. Rewriting pages repeatedly can dominate storage cost. Larger chunks reduce request count but increase read/write amplification.

## Licensing and provenance

s3backer includes GPL v2 text in COPYING and licence notices in source. Infiniswap is mixed per-file material: is_main.c includes a dual BSD/GPL notice, while other files require individual inspection before reuse. Apple files carry APSL notices. Do not assign a blanket permissive licence to the reference archive. New CLOUDSWAP code is independently written; no upstream driver has been linked into the app. Preserve original notices for any future adapted code and record its lineage.

## Additional Mac route discovered during review

[Apple DTS discussion](https://developer.apple.com/forums/thread/837879) identifies the DMA-only BlockStorage interface as an obstacle for software-backed devices and discusses a SCSI descriptor path and FSKit/raw-disk-image alternative. Those are block-storage candidates, not verified swap solutions.

A [newer Apple DTS announcement](https://developer.apple.com/forums/thread/856479) describes software-controller support in the initial macOS 27.3 beta. Detect the `Software I/O` capability property, set it before controller initialisation, and use `UserCopyDataBuffer` for request data. This is evidence for prioritising a C++ SCSIControllerDriverKit feasibility spike. It is not evidence of support on the inspected macOS 14.5 host. The local SDK exposes the older UserGetDataBuffer API; no newer beta SDK or OS has been installed.

Next experiment: entitlement and capability discovery in an isolated compatible Mac environment, then a small synthetic SCSI disk with correct request completion and buffer lifetime. Only after ordinary read/write/flush validation should swap routing be investigated. Do not rely solely on an OS version string or dereference DMA addresses as CPU pointers.
