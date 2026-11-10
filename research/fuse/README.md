# FUSE feasibility for CLOUDSWAP

Reviewed 10 November 2026 from [the supplied topic page](https://github.com/topics/fuse) and primary project documentation. Six selected repositories are pinned as Git submodules in `sources/`, with commit/tree identities in `manifest.json`. This is a shortlist, not acquisition of the entire topic. None of these six source trees was downloaded, built or mounted in this pass. A pin preserves a source reference; it does not supply closed-source components or guarantee continued upstream availability.

## What this changes

FUSE supplies an existing way to make application-provided storage visible as a filesystem. We do not need to invent that whole layer to expose encrypted chunks as files on a Mac. It does not by itself redirect anonymous memory from Chrome/Claude into those files or make a mount eligible for XNU system swap.

| Candidate | Useful contribution | Verified boundary or unresolved question |
| --- | --- | --- |
| macfuse/macfuse | Mac filesystem bridge and Swift/Objective-C-facing framework | README says current kernel component is closed-source. Umbrella Git pin includes references to open subcomponents, not the complete runtime implementation. |
| macos-fuse-t/fuse-t | Userspace mounting alternatives without a third-party kext | Project advertises NFS, SMB and FSKit backends. None establishes swap eligibility. Runtime/embedding terms require separate review before shipping. |
| rclone/rclone | Existing R2 access and Mac filesystem mounting | VFS disk-cache limits can be exceeded by open files; cached writes upload after close/write-back delay. A permanently open swap-style file could retain local cache, defeating internal-space savings. |
| s3fs-fuse/s3fs-fuse | S3-compatible object-to-file interface | README describes object rewrites for random changes and no atomic rename. Avoid treating one large S3 object as an efficient random-write swap disk. |
| Barre/ZeroFS | Rust S3-backed filesystems and NBD exports, compression/encryption and explicit durability mechanisms | README distinguishes NBD FLUSH/FUA durability from NFS, where buffered writes can be reported stable. Mac server availability is not a Mac NBD client or host-swap attachment. |
| cberner/fuser | Rust FUSE implementation API | README labels macOS untested and describes Linux/FreeBSD testing. It also says pull requests are no longer accepted; evaluate maintenance and alternatives before selecting it. |

The already acquired s3backer is also directly relevant to block-sized cloud storage. Ceph/SeaweedFS/CubeFS are broader distributed-storage platforms; WinFsp/Dokany target Windows; read-only filesystems cannot provide writable swap. These topic entries are not all interchangeable Mac components.

## Findings that affect the design

1. **Cache placement is part of the product.** rclone's open-file cache behaviour could consume the disk space the user wants back. A useful experiment must record allocated cache bytes on internal and external volumes during prolonged open-file writes, not just check that Finder shows a cloud drive.
2. **A successful flush needs a precise meaning.** ZeroFS's documented NFS caveat rules out assuming `fsync` establishes remote durability. Its NBD FLUSH/FUA claims are promising research leads, not measured CLOUDSWAP results. Test an acknowledged flush followed by service termination before adopting it.
3. **Mac support is version-specific.** macFUSE introduced an FSKit route for macOS 15.4+, with evolving limitations; this route is absent on the previously inspected 14.5 host. Verify the selected runtime release and SDK against the exact target OS. Kernel-backed macFUSE is a separate route, with separate installation requirements.
4. **System paging is an additional acceptance gate.** Host-matching XNU source at `2c2f96dc2b9a4408a43d3150ae9c105355ca3daa`, `bsd/vm/vm_compressor_backing_file.c`, rejects a mount carrying `MNTK_NOSWAP` and uses vnode paging operations. No evidence here proves a current FUSE backend's runtime flags or paging behaviour. Failed retrieval of an old osxfuse source URL is not evidence that modern macFUSE prohibits swap.
5. **Memory pressure needs its own test.** Engineering inference: a userspace filesystem servicing paging must not depend on allocations/pages whose retrieval requires that same blocked server. Reserved resources and failure behaviour need demonstration under pressure; ordinary file I/O tests cannot establish this.

## Concrete next experiment

First expose one bounded, synthetic file on a supported Mac filesystem backend. Check random aligned and unaligned writes, reopen/read integrity, flush semantics, server termination, offline recovery and allocated cache growth. Use encrypted chunks rather than assuming a whole-object random-write interface is efficient. Keep this file test distinct from system swap.

Only then test whether the mount is accepted by XNU in the disposable-system plan and whether actual page-in/page-out reaches it. Preserve the external APFS experiment as the simpler native baseline. A separate Cairn ordinary-file offload feature can reuse filesystem mounting without claiming to solve system paging.

## Source references

- [macFUSE source/component disclosure](https://github.com/macfuse/macfuse#source-code)
- [macFUSE backend documentation](https://github.com/macfuse/macfuse/wiki/FUSE-Backends)
- [FUSE-T project](https://www.fuse-t.org/)
- [Rclone mount/cache semantics](https://rclone.org/commands/rclone_mount/)
- [Cloudflare R2 rclone integration](https://developers.cloudflare.com/r2/examples/rclone/)
- [s3fs limitations](https://github.com/s3fs-fuse/s3fs-fuse#limitations)
- [ZeroFS durability and NBD](https://github.com/Barre/ZeroFS#mounting)
- [fuser compatibility](https://github.com/cberner/fuser#compatibility)

Project pages and wikis can change; the Git manifest fixes the repository revisions. Review component licences and pin nested dependencies before incorporating code. To acquire one selected tree, run `git submodule update --init --depth 1 -- research/fuse/sources/Barre--ZeroFS`, substituting the desired path. Avoid a global recursive download of all research repositories on a space-constrained Mac. No FUSE runtime was installed and no mounts or system swap settings were changed.
