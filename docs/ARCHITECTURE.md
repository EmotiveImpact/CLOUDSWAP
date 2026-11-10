# Architecture and language decision

## Product target

Free internal Mac disk space consumed by swap while unmodified applications remain usable. The success criterion is measured reduction in allocated local swap plus bounded stalls and verified data integrity, not a mounted cloud disk or an attractive monitor.

## Language boundaries

| Component | Language | Reason / status |
|---|---|---|
| Menu-bar application | SwiftUI / Swift | Native macOS status UI, Network path monitoring, sysctl; compiled |
| Paging policy and future storage engine | Rust | Portable ownership and error handling; dependency-free policy core implemented |
| R2 transport experiment | Swift + CryptoKit | Native Mac experiment without external packages; compiled, local crypto verified, live R2 pending |
| Native storage driver | C++ / SCSIControllerDriverKit candidate | Apple software-controller route identified; adapter not implemented or entitled |
| Linux reference | Python / nbdkit | Preserved original experiment; not yet running as kernel swap |

Do not duplicate the entire engine in C++ and Rust. The native probe is an interoperability experiment; production transport, encryption and persistent metadata should eventually sit behind one reviewed Rust interface. Swift can communicate with a helper over versioned IPC. No production IPC or FFI is claimed yet.

## Implemented behaviour

Rust Pager accepts opaque payloads and commits the block index only after backend acknowledgement. The current backend is a deterministic in-memory emulator, not encryption or R2. Any write error poisons this ephemeral export; reads then fail visibly. Read-only transport outages may be retried after connectivity returns. The menu-bar app runs this same executable and labels its results as a simulation.

The Python reference encrypts blocks with AES-GCM and unique nonces, authenticates object identity, uses immutable keys and bounds requests. Its session key/index are RAM-only. The Swift probe independently encrypts a small synthetic object with CryptoKit, signs R2 HTTP requests, verifies the result and cleans up. Neither implementation supports durable restart recovery.

## Proposed data path and gates

1. Mac application page fault -> XNU paging subsystem. The attachment point remains unresolved.
2. Native adapter -> bounded resident request queue. Kernel/driver transport must not depend on memory that it is itself paging out.
3. Rust engine -> authenticated encrypted chunks -> R2; local cache bounded by explicit byte budget.
4. Read completes only after successful authentication of the expected generation. Missing previously written data is never substituted with zeros.

Prioritise capability-gated SCSIControllerDriverKit software I/O after the Apple DTS finding in the research register. The inspected BlockStorage DMA-only interface is not the preferred software adapter. FSKit/FUSE-backed disk images and kernel-level research remain separate candidate routes. Prove ordinary block I/O first, then independently prove swap participation. Do not claim DriverKit solves swap routing. No changes to live swap paths, SIP, startup configuration or disk volumes are included in this build.

## Failure policy still to design

Stopping an export prevents false success, but is not transparent application survival. Kernel paging errors may terminate applications or panic the machine. Infinite retries may hang the machine. A local mirror provides availability at the expense of disk space. No implementation can fetch a cloud-only page during a complete network outage.

Before system attachment: persistent metadata/journal, crash consistency, authenticated generations, bounded memory, cancellation/deadlines, low-disk reserve, read priority, concurrent access, sleep/wake, network transitions, credential expiry, R2 throttling, cleanup and request-cost limits must be verified.

The 4 KiB Python block is a storage test granularity, not an assumption about the Mac's native VM page size. Discover native page size and test 4/16/64 KiB and larger object packing separately.

## Cairn reuse

Share transport, encryption, quota accounting and restoration verification later. File offloading requires durable keys and manifests, metadata/xattrs, placeholders or explicit restore paths, and upload verification before local eviction. Ephemeral swap sessions cannot be reused as a durable file archive. No Cairn code, automatic file movement or deletion is part of this project change.
