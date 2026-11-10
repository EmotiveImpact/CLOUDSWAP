# Project conversation context
Saved 10 November 2026 at the user's request for continuation in Codex.

This is a structured preservation of the available project conversation, decisions and engineering outcomes. It is not a verbatim message export. Earlier conversation portions available only as summaries cannot be reproduced word for word. No credentials or unrelated personal context are included.

## User objective and scope
The user's Mac is bogged down by swap and losing internal drive space. The desired product makes existing Mac applications, including Codex, Claude and Chrome, usable while storing paging data on external storage and/or Cloudflare R2.

CLOUDSWAP is the working product/repository name. The wider project context also uses ISWAP. Do not silently rename the repo or product.

The user initially accepted a small Linux VM experiment with Wi-Fi-drop testing, then emphasised that the destination is Mac and asked for native Mac work. Linux work should be cloned/preserved and ported where useful. It is a proving ground, not the final deliverable.

The requested interface is a small Mac application with a top-bar icon and menu. The user asked whether C++ and Rust should be used. The implementation currently uses SwiftUI and Swift/CryptoKit for the native app and storage prototype, Rust for portable failure policy, Python for reference/gateway tools, and C for the guest memory probe. A C++ driver bridge remains a possible research route, not built code.

The user asked that the research and upstream repositories be mined and adapted, with work stored in https://github.com/EmotiveImpact/CLOUDSWAP. Preserve source provenance and licences. The user repeatedly instructed the assistant to build, continue improving, finish the next tasks and test, rather than stop at plans or seek repeated permission.

The user subsequently asked about an external hard drive. External-drive storage support is now a first-class prototype requirement alongside cloud storage. Actual macOS system-swap relocation remains the same unresolved integration gate.

Cairn may later use cloud storage to move ordinary files off a full disk. The user was undecided whether to combine projects. Keep this future reuse path documented without treating file offloading as equivalent to paging.

## Research provided and explored
- Cloudflare R2 API: https://developers.cloudflare.com/r2/api/
- Infiniswap presentation: https://www.usenix.org/conference/nsdi17/technical-sessions/presentation/gu
- Infiniswap paper: https://www.usenix.org/system/files/conference/nsdi17/nsdi17-gu.pdf
- Linux NBD: https://docs.kernel.org/admin-guide/blockdev/nbd.html
- Original Apple XNU source reference: https://github.com/apple-oss-distributions/xnu/blob/xnu-10063.121.3/bsd/vm/dp_backing_file.c
- s3backer: https://github.com/archiecobbs/s3backer
- Cloudflare Tunnel: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/
- Additional Apple driver candidate discussed: https://developer.apple.com/forums/thread/856479
- External boot was considered as a separate possible route: https://support.apple.com/en-gb/111336

Initial research established that R2 is HTTP object storage, while swap requires reliable access to requested pages. Infiniswap's data-centre networking does not establish responsiveness over ordinary Wi-Fi. s3backer demonstrates object-to-disk concepts, not native macOS swap integration.

The reviewed XNU code has an unsupported old swap registration entry point and kernel-managed swap files. Merely changing Linux interfaces to Mac names cannot create supported kernel integration. DriverKit capability, provisioning and swap selection require distinct proofs. Earlier discussion of newer/beta Apple driver APIs is a research lead; reverify current availability and SDK support before designing against it.

Moving heavy workloads to a remote Mac via Cloudflare Tunnel was proposed as an alternative. It was not accepted as a substitute for this project's native Mac objective. App-controlled data offloading would only benefit participating apps.

## Decisions and demonstrated outcomes
- Preserve upstream research and Linux experiments alongside native work.
- Label simulations, HTTP lab results, real kernel paging and physical tests separately.
- Encrypt pages and metadata and authenticate object identity.
- Stop on uncertain writes rather than acknowledge data that may not be recoverable.
- Retry immutable reads for a bounded period; long outages remain consequential.
- Add a full local mirror as an explicit protection/capacity tradeoff. It cannot simultaneously retain every page internally and claim equivalent internal space savings.
- Pin external-directory identity to prevent path reuse from redirecting storage.
- Measure actual reclaimed space net of fallback, stalls and application survival before claiming usefulness.
- Continue autonomously within authorised development scope, communicating actual blockers rather than requesting routine confirmation.

Implementation proceeded through the menu-bar foundation, native R2 transport tests, encrypted local store, integrated remote pager, real Linux swap/fault tests, bounded read retries, external-directory protection and optional local mirroring. See CODEX-HANDOVER.md for current evidence and exact file locations.

## Most recent status answers
The project is not done. External folder storage works as a tested backend and has a built UI test. Cloud/R2 code exists and has mock/crypto tests but no live bucket verification. A full local mirror can serve synthetic pages offline. Neither backend yet replaces existing Mac applications' system swap. No internal-space savings are demonstrated.

The user explicitly requested that the project information from this chat be saved in the repo so work can continue in Codex. This document and CODEX-HANDOVER.md fulfil that handover as structured project records, not a claim that every historical message is archived.

## Working preferences
Use British English. Communicate plainly and concisely. Avoid unnecessary em dashes and en dashes. Keep building and testing the authorised work; don't repeatedly ask whether to continue. Do not claim background work continues after a turn unless an actual running system supports it.

## FUSE implementation follow-through

The user supplied https://github.com/topics/fuse and asked to keep building.
Research led to a native encrypted file adapter with an optional FUSE frontend,
without replacing the native Mac swap objective with ordinary file offloading.
The current development Mac lacks a FUSE runtime. Direct callback tests and real
helper-process restart/failure tests are therefore recorded separately from a
mounted filesystem and from kernel paging. The adapter is deliberately fixed at
4 MiB while its failure semantics are tested. See `labs/macos-fuse/README.md`.

## Integration follow-through

The user again instructed us to complete the authorised work without stopping.
PR #8 combines all six pending feature/research branches. A Rust bridge through
macOS's built-in NFS client was added to obtain a real mount proof without
installing a third-party filesystem runtime on the working Mac. FUSE-T's binary
licence was inspected before adoption and contains commercial-use restrictions.
No binary was installed. This is still aimed at proving the storage path before
the separate, unresolved native Mac kernel swap gate.

The integrated NFS storage path subsequently passed real mounted read/write,
flush, process restart, remount and one-second server-pause recovery tests on
Intel and Apple Silicon hosted Macs. Root prefix writes were then tested using
the unchanged stock value on Intel. PR #9 builds on that with a disposable APFS
virtual-volume experiment: actual kernel page-out/page-in traces were captured,
and all 8.0625 GiB of the synthetic workload verified. This is not yet physical
external-SSD certification, cloud-backed system swap or a product activation
feature. The working Mac's swap configuration remains unchanged.
