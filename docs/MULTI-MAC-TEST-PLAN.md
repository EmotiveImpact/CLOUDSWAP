# Multi-Mac verification plan

## Recommended sequence

Prove local external-SSD system paging first. Source mining found a writable vm.swapfileprefix registration worth investigating before a custom driver. This is an unverified research lead, not a setting to change on a working Mac. Read research/kernel/FINDINGS.md.

Use a disposable macOS VM for storage, crash/restart and virtual-volume experiments where the VM configuration supports them. Use a spare physical Mac and a dedicated disposable external SSD for actual USB/Thunderbolt disconnects, power behaviour, boot, sleep and wake. A VM passing cannot certify a real cable, controller or physical storage device. A GitHub macOS runner passing compilation does not certify kernel swap integration.

## Initial matrix

Do not buy a large hardware fleet before the first integration proof. Start with one accessible Apple silicon test Mac, then expand to distinct configurations.

| Cohort | Required coverage | Why |
|---|---|---|
| Baseline | Observed arm64 macOS 14.5 / 23F79 / XNU 10063.121.3, or another explicitly selected reproducible baseline | Establish an exact build and repeatable source map |
| Newer Apple silicon | Another chip generation, with an explicitly selected supported macOS build | Detect hardware, storage and kernel differences |
| OS-version coverage | Oldest version we intend to support plus current stable version on compatible hardware | Detect changed interfaces and policies; record exact builds |
| Intel, if offered | Separate x86_64 physical Mac, noting T2 presence and supported OS version | Architecture and startup-security differences require independent evidence |
| Storage coverage | Direct USB SSD and Thunderbolt SSD; add hub/dock only after direct connections pass | Disconnect, controller and latency behaviour can differ |

Record RAM, hardware page size, drive model/firmware, transport, filesystem, encryption, startup policy and exact app/driver commit. Do not assume the prototype's 16 KiB logical blocks equal the kernel page size on every architecture. Repeat tests after macOS updates affecting the supported builds. No configuration inherits a passed status merely because a different Mac passed.

Apple references:
- https://support.apple.com/en-gb/guide/security/sec8e454101b/web
- https://developer.apple.com/support/kernel-extensions
- https://developer.apple.com/documentation/virtualization

## Portable read-only inventory

On each Mac, from the feature-branch checkout:

```sh
python3 scripts/mac-capabilities.py > mac-capabilities.json
```

The script reads build/architecture and selected sysctls. It does not change swap, mounts, drivers or security settings, and does not collect serial numbers or hostnames. It distinguishes access denied, not exposed and unavailable. Readable configuration is never automatically reported as working external swap. Fill in the listed manual evidence separately; do not add secrets to reports.

The session report is in research/kernel/mac14.5-capabilities.json. It observes arm64, macOS 14.5/23F79 and XNU 10063.121.3. Sysctl access is denied in this execution environment, so hardware details and prefix capability remain unknown in that report.

## Acceptance stages per machine

1. **Backend baseline**: run native unit tests, release build, crypto self-test and 1 MiB folder test. Verify cleanup, wrong key, corruption, missing data and full-disk errors. This is not system paging.
2. **Integration feasibility**: read-only prefix/policy inspection, then a separately controlled disposable-system placement experiment. Record rejection details if it fails; do not silently alter security settings to get a pass.
3. **Actual paging proof**: baseline internal configuration versus external candidate. Use bounded synthetic incompressible allocations with a watchdog and independent observer. Require swap-out/in deltas, target-volume I/O evidence and complete post-page-in integrity. Memory pressure must be controlled; the harness is not yet implemented for Mac.
4. **Normal lifecycle**: close/reopen, app and service restart, full disk, reboot, sleep/wake and supported encryption modes. Record errors and recovery.
5. **Fault trials on disposable systems**: 1/10/60-second interruptions, device removal/reappearance, delayed requests, cloud blackholes, DNS/HTTP errors and uncertain writes. Cloud faults follow verified local integration. Do not unplug a live swap drive on a working machine. Capture stalls, process exits, kernel panics and data loss honestly.
6. **Useful-product trial**: representative applications only after synthetic integrity passes. Measure internal allocated bytes saved after caches/index/mirror, external/cloud usage, p50/p95/p99 page latency and user-visible stalls against the internal baseline. Full internal mirroring can erase the intended space saving.

A test bundle should contain inventory JSON, software commit, exact workload and seed, configuration, timestamped observations, before/after counters, per-volume evidence, checksums, exit/panic outcomes and recovery steps. Scrub private data from diagnostic logs before committing.

## Release policy

Maintain explicit supported combinations of architecture, OS build/range and backend. Unknown combinations remain unverified. Prefer capability checks to model-name guesses. Never enable system-swap relocation automatically because source code contains a potential control point.

Current result: all physical Mac system-paging cohorts are unverified. The Linux VM result and native storage tests remain useful evidence for their own scopes only.
