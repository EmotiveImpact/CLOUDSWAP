# Findings and reuse plan

Scope: source acquisition and design review, 10 November 2026. No new runtime performance or Mac system-swap claims are made. Links in the inventory resolve to the exact reviewed revision.

## Highest-value findings

1. **r3map** separates remote block backends from mounts, with background transfer and S3 support. Its example mount depends on Linux NBD. In the inspected `pkg/backend/s3.go`, object keys are prefix plus offset; writes call `PutObject` and `Sync` returns nil. `ReadAt` conditionally propagates errors only when the byte count equals the requested length, and missing-key handling can report success without filling the supplied buffer. This is a source-level correctness concern, not a reproduced upstream failure. Do not transplant this read path into CLOUDSWAP: require exact lengths, authenticated content, explicit unwritten-block metadata and errors for lost committed objects. Never silently turn missing encrypted pages into zeroes.
2. **ram-dl**, inspected `cmd/ram-dl/main.go`, calls `mkswap`, `swapon` and `swapoff` around its device lifecycle. It is a useful comparison for a Linux remote-swap lab. Replacing those command names will not provide the missing Darwin paging attachment.
3. **fastswap**, inspected `drivers/fastswap.c`, registers frontswap operations including asynchronous load and load polling. Its Linux kernel patch and RDMA backend are platform dependencies. Separate demand reads from speculative work in our transport scheduler; compare against the current simple queue before adopting the complexity.
4. **Eden and Umap** show application-owned, fault-driven remote/out-of-core memory. Their README requirements include Linux userfaultfd; Eden also expects RDMA, and describes unpublished kernel changes for best performance. They are useful alternatives for an app we control, not evidence that an unchanged Mac app can use remote RAM.
5. **SAFE / Carbink** motivate remote redundancy and recovery experiments. SAFE's README specifies one compute node and six memory nodes plus RDMA, and includes Carbink comparison settings. Inference: remote erasure coding can tolerate some remote failures but cannot supply an uncached page while the Mac has no route to any shard. Wi-Fi loss still needs local retained data, a bounded stall policy, or a failed workload.

## Experiments to build next

| Work | Implementation target | Acceptance evidence |
| --- | --- | --- |
| Strict read semantics | Existing encrypted ObjectBackend and fault-injection lab | Missing committed object, truncated ciphertext, stale generation and authentication failure must never return success; unwritten blocks handled separately |
| Demand priority | Transport queue, bounded prefetch budget | Compare no prefetch vs prefetch under injected latency; report p50/p95/p99 fault latency, memory overhead, request amplification and starvation |
| External SSD retention | Existing local encrypted store and mirror | Reopen after restart, unplug/replug, disk full and uncertain write tests; measure physical internal bytes saved, not logical data size |
| Cloud outage recovery | R2 lab and synthetic HTTP faults | 1/5/30-second outages, reconnect, credential expiry, timeout and process restart; verify every returned page against originals |
| Native Mac attachment | Existing XNU source map and disposable-Mac plan | Verify `vm.swapfileprefix` policy/runtime behaviour, then new-file placement on a test volume; source writability alone is not success |
| Application-owned paging | Optional future API for apps we control | Demonstrate lower resident memory and intact data without claiming system-wide swap |

Keep SwiftUI for the menu-bar app. Rust is suitable for shared storage, integrity and scheduling work if we move those components; use C/C++ only where a tested native interface or reusable library needs it. Linux kernel C and C++ far-pointer libraries do not become Darwin components through a language rewrite. Keep Cairn ordinary-file offloading separate from volatile memory paging.

## Acquisition inventory

| Repository | Use and constraint | Root licence discovery |
| --- | --- | --- |
| [SymbioticLab/Infiniswap](https://github.com/SymbioticLab/Infiniswap/tree/da7c14bf749ccadb4ef44953579d55143e8e7182) | Linux RDMA swap; existing archived baseline | No recognised root licence captured; inspect before reuse |
| [thustorage/Sherman](https://github.com/thustorage/Sherman/tree/9bca43141f487f7a1b0492b88f106476eb3dbbf6) | RDMA B+tree; database design reference | No recognised root licence captured; inspect before reuse |
| [purduedb/OpenAurora](https://github.com/purduedb/OpenAurora/tree/c16fc0f45b245e6e94ae80d9b4843476f00e6b25) | PostgreSQL storage disaggregation; not a Mac pager | No recognised root licence captured; inspect before reuse |
| [Amit-P89/-DRackSim](https://github.com/Amit-P89/-DRackSim/tree/7af5c2d6d570317aa8b00ab249597e05870618ad) | Rack-scale simulator; modelling reference | Notice found; review required |
| [uclasystem/MemLiner](https://github.com/uclasystem/MemLiner/tree/ea5a243cb5f021de26a41731f15ed63901faf837) | Managed-runtime GC and paging coordination | Notice found; review required |
| [uclasystem/Mako](https://github.com/uclasystem/Mako/tree/b5afd9e33a13f5096a9f4b39034afe1d1fa54c67) | Remote GC; specialised runtime | No recognised root licence captured; inspect before reuse |
| [eniac/TELEPORT](https://github.com/eniac/TELEPORT/tree/ff62861537a147fdfee5c2bf617bad7042149338) | Disaggregated compute/data processing | Notice found; review required |
| [Coekjan/CrossPool](https://github.com/Coekjan/CrossPool/tree/1e4b15f67cc01e1f363312a186f37568276f1fde) | CUDA/SGLang GPU memory pooling; not Mac system RAM | Notice found; review required |
| [DatabaseGroup/rdma-inverted-index](https://github.com/DatabaseGroup/rdma-inverted-index/tree/1a6635ef353877ac6dac527e1e691e8b27e31b2a) | RDMA inverted-index engine | Notice found; review required |
| [fukien/hashjoins-meet-cxl](https://github.com/fukien/hashjoins-meet-cxl/tree/0aeea0db2103d8706a6929f8d0e037bffd4e3623) | CXL hash joins; hardware-specific | Notice found; review required |
| [engrtarun/T9-VirtualRAM](https://github.com/engrtarun/T9-VirtualRAM/tree/868958a5d5ef411e502a070e9da45dac5df79be1) | Research aggregator with submodules; not a working Mac pager | No recognised root licence captured; inspect before reuse |
| [SymbioticLab/Leap](https://github.com/SymbioticLab/Leap/tree/13787f2bb5e4cf830e7ff05c189a81c295645022) | Linux remote-page prefetch and eviction | Notice found; review required |
| [clusterfarmem/fastswap](https://github.com/clusterfarmem/fastswap/tree/9cfc2adfc1653a0a93139da535e6364277566898) | Linux frontswap/RDMA; inspected selected code | Notice found; review required |
| [uclasystem/canvas](https://github.com/uclasystem/canvas/tree/4c51f0b9aa9081ae3ffefac7ad57d1bf1217094c) | Linux remote-swap isolation and scheduling | No recognised root licence captured; inspect before reuse |
| [AIFM-sys/AIFM](https://github.com/AIFM-sys/AIFM/tree/fa4f31ce827501ad52f5a5ca9249ef04ba92b467) | C++ far-memory APIs; application integration required | Notice found; review required |
| [compiler-disagg/TrackFM](https://github.com/compiler-disagg/TrackFM/tree/e4f8041231c6e6fe74c2b4b5c50f9787bc8e5b0d) | Compiler transformation plus far-memory runtime | Notice found; review required |
| [pojntfx/r3map](https://github.com/pojntfx/r3map/tree/a98a088b90933c546feb64459476f076c222b937) | S3/chunk/mount abstractions; inspected selected code | Notice found; review required |
| [pojntfx/ram-dl](https://github.com/pojntfx/ram-dl/tree/691e74893f0c09740bea3743d1b912a96e32c63d) | Linux remote-swap demo; inspected lifecycle | Notice found; review required |
| [eden-farmem/eden](https://github.com/eden-farmem/eden/tree/beca12a7af20bc30de0a3aae1edd2570bb09cee2) | Shenango/userfaultfd hybrid runtime | Notice found; review required |
| [rimimadision/safe](https://github.com/rimimadision/safe/tree/095cdd357015951f4a0c4df8d0f43f22ceea1583) | Erasure-coded far memory; recovery reference | No recognised root licence captured; inspect before reuse |
| [llnl/umap](https://github.com/llnl/umap/tree/9844588c66c1afd4f92c768a308146ce5fbf2e84) | Linux userfaultfd-backed out-of-core mappings | Notice found; review required |
| [dmemsys/awesome-disaggregated-memory](https://github.com/dmemsys/awesome-disaggregated-memory/tree/af74a73b8e69e19d8b781d43f938ff348a525242) | Discovery index; verify claims in primary sources | No recognised root licence captured; inspect before reuse |
| [eden-farmem/fltrace](https://github.com/eden-farmem/fltrace/tree/cf9f93f2e7c951c574955db660d65ef11b0c4796) | Linux page-fault/callsite profiling | Notice found; review required |

Additional primary reading: [Carbink, OSDI 2022](https://www.usenix.org/conference/osdi22/presentation/zhou-yang). This is a paper reference, not a claim that its original implementation was acquired.
