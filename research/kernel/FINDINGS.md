# XNU swap path findings

Source review on 10 November 2026. Pins and automated anchors are in sources.json and xnu-*-map.json. This report revises the earlier assumption that a driver or kernel modification must necessarily be the first experiment.

## First experiment: investigate the existing swap prefix

Both pinned versions register `vm.swapfileprefix` using `SYSCTL_STRING` with `CTLFLAG_RW | CTLFLAG_KERN | CTLFLAG_LOCKED`, backed by `swapfilename`. In the host-matching version this is at [kern_sysctl.c line 4516](https://github.com/apple-oss-distributions/xnu/blob/2c2f96dc2b9a4408a43d3150ae9c105355ca3daa/bsd/kern/kern_sysctl.c#L4516); in the newer source it is at line 4703. The registration is not enclosed by a DEVELOPMENT/DEBUG conditional in either file.

`CTLFLAG_KERN` means the OID is valid for calls originating in the kernel. It does not by itself mean user-space access is forbidden. The [dispatch code](https://github.com/apple-oss-distributions/xnu/blob/2c2f96dc2b9a4408a43d3150ae9c105355ca3daa/bsd/kern/kern_newsysctl.c#L1706) checks write flags and privilege and later applies the MAC policy hook. Ordinary writes without CTLFLAG_ANYBODY require privilege. This source observation does not establish which sandbox/security policies permit access on a shipping Mac.

A read-only `sysctl vm.swapfileprefix` attempt in this session returned Operation not permitted. Other hardware and swap sysctls also returned permission errors. This is an access-denied observation, not evidence that the OID is absent or that an ordinary terminal/root session must fail. No write was attempted.

**Hypothesis to test:** the existing prefix may allow future swap files to be placed on another acceptable local filesystem, without a custom driver. This is not a supported public configuration contract or verified product capability. Investigate boot timing, privilege, filesystem acceptance, and concurrent file creation on an isolated installation before enabling any change.

## Source-derived route

| Stage | Source | Finding / consequence |
|---|---|---|
| Default path | osfmk/vm/vm_compressor_backing_store.h in host pin; *_internal.h in newer pin | macOS default is /System/Volumes/VM/swapfile |
| Prefix registration | bsd/kern/kern_sysctl.c | Writable string registration is a candidate control point |
| File creation | osfmk/vm/vm_compressor_backing_store.c | Builds new file paths from swapfilename and an index; existing swapfile structures retain paths/vnodes |
| Filesystem acceptance | bsd/vm/vm_compressor_backing_file.c | Opens a vnode, then rejects mounts carrying MNTK_NOSWAP |
| Allocation | same backing-file source | Sets file size, marks VSWAP; optional pinning failure is explicitly nonfatal in the host pin |
| Page writes | vm_swap_put -> vm_swapfile_io -> vnode_pageout | Must satisfy filesystem paging I/O, not merely normal file writes |
| Page reads | vm_swap_get -> vm_swapfile_io -> vnode_pagein | A missing page has consequences beyond an ordinary failed HTTP read |
| Old registration API | bsd/vm/dp_backing_file.c | macx_swapon and macx_swapoff return ENOTSUP in reviewed source |

The unsupported old swapon API does not prove that every other placement mechanism is impossible. Conversely, seeing a writable prefix does not prove safe relocation. Existing pages are not visibly migrated by the generic string handler. Changing or restoring the prefix must not be treated as draining existing swap. Initialisation also records a swap mount and SSD/HDD-related behaviour, which makes timing and cross-volume state a required investigation.

A regular external APFS volume should be investigated before inventing a cloud block driver. The MNTK_NOSWAP check is a filesystem/mount gate, not evidence that all removable drives are automatically rejected. Relevant proprietary filesystem behaviour remains outside this source review.

## ipsw and symbolicator mining

`ipsw` implements kernel symbol-map construction in cmd/ipsw/cmd/kernel/kernel_symbolicate.go, including signature parsing and JSON export. The signature corpus includes vm_swap_get, vm_swap_put and vm_swapfile_open entries in several version directories (for example kernel/24.2/xnu.json). Their existence does not verify matching on this Mac. Use the exact kernel binary and matching signatures; save binary hash, OS build and match confidence. Do not reuse absolute addresses across builds or machines.

## Concrete next proof

1. Collect read-only capability JSON in a normal terminal on the isolated target. A denied result stays unknown.
2. Match its OS/XNU build to source and inspect policy/initialisation before any mutation.
3. On a disposable VM where supported, use a second virtual local disk to investigate prefix placement and page traffic. This proves virtual-volume behaviour only.
4. On a spare physical Mac with a dedicated test installation and disposable external SSD, test real external placement. Any privileged prefix experiment must be a separately reviewed lab procedure with recovery access. Do not run it on the working Mac.
5. Require both target-volume file/I/O evidence and actual system swap counters, followed by synthetic data integrity checks. A file existing on the external disk is insufficient.
6. Reboot into a known-good environment for recovery when appropriate; do not unplug a drive holding live pages or assume restoring the prefix makes unplugging safe.

If the prefix path works safely, build the narrowly scoped privileged integration around the proven mechanism. If it fails, record the exact policy/filesystem/initialisation blocker and then assess DriverKit or other approaches. Cloud remains a later storage and failure-handling problem. No claim of Mac swap relocation is made by this report.

## Apple userspace implementation found during follow-up

A fourth upstream repository, [apple-oss-distributions/system_cmds](https://github.com/apple-oss-distributions/system_cmds), is pinned at 408bba7453608006b89772db185defbac8fe2fd0. Its [dynamic_pager.c](https://github.com/apple-oss-distributions/system_cmds/blob/408bba7453608006b89772db185defbac8fe2fd0/dynamic_pager/dynamic_pager.c#L73) writes vm.swapfileprefix when passed a filename prefix. The accompanying manual documents the -F option. The manual's default path is historical, so the kernel source and actual target must determine the current default.

This strengthens the candidate beyond an isolated sysctl declaration: Apple has userspace code that uses it. It still does not establish externally mounted volume acceptance, live migration, supported startup integration or safe recovery on any shipping build.

The same source deliberately exits successfully even on certain failures. It also unlinks directory entries whose names start with swap. Therefore a zero exit status cannot establish that placement worked, and invoking it against an ordinary directory could delete unrelated files with matching names. It is intended for boot-time use; do not casually restart it or use it as a live migration tool.

Read-only inspection of /sbin/dynamic_pager on the observed 14.5 host found the swapfileprefix and error-message strings. Its SHA-256 was 9bf7cbf5ac838a6e6a3cae4bb50881df3f84b46ab0851ccde0e0e8c14bc82817. The executable was not run, decompiled or proved identical to the pinned source. No privileged write was attempted.

## Apple NFS client source and mapped-file gate

Apple publishes its NFS client separately from the reviewed XNU snapshots in
[apple-oss-distributions/NFS](https://github.com/apple-oss-distributions/NFS).
The complete checkout is pinned at `93733ffccece4daee73bf6306b291d1ae69130c0`
(tag `NFS-343.100.5`) under `research/kernel-sources/apple-nfs`, with provenance
in `sources.json`. It has not been binary-matched to a test Mac.

`kext/nfs_vnops.c` registers `nfs_vnop_pagein` and `nfs_vnop_pageout` and contains
their implementations at lines 8263 and 8648. `kext/nfs_vfsops.c` calls
`vflush(..., SKIPSWAP | flags)` during unmount at line 4592. These are useful
source leads, not proof that a shipping kernel will select an NFS file as swap.
No `vfs_setnoswap` call was found in this pinned client source; absence alone
does not establish swap eligibility or policy access.

The Rust NFS lab now tests dirtying a file-backed mmap, msync/fsync, a cold
remount and mapped reads. This exercises a narrower contract than redirecting
an existing application's anonymous-memory swap. Our fixed 4 MiB file cannot
yet satisfy XNU's create/truncate/resize swap-file lifecycle. A user-space
gateway also requires a separately proven memory-reservation strategy to avoid
depending on its own remote pages under pressure.

Read-only codesign inspection of the working Mac's `/sbin/dynamic_pager` found
`com.apple.rootless.volume.VM` in its entitlements. It was not run. This does not
prove that the entitlement controls `vm.swapfileprefix`; root capability results
and an isolated placement experiment remain necessary.
