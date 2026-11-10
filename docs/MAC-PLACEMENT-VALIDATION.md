# Native Mac placement evidence, 10 November 2026

The guarded experiment has observed native kernel paging on a separate APFS
disk-image volume on both Intel and Apple Silicon hosted Macs. This advances
the original hypothesis that macOS might ignore or reject the swap prefix.
It does not establish a supported production API or a working cloud swap product.

| Host | Verified synthetic memory | Target-volume trace | Recovery |
|---|---|---|---|
| Intel macOS 15.7.9, first run | 8.0625 GiB | 14 page-outs and 2 page-ins | Prefix restored; volume retained until runner teardown |
| Intel macOS 15.7.9, repeat | 8.25 GiB | 130 page-outs and 7 page-ins | Same |
| Intel macOS 15.7.9, schema 2 | 8.1875 GiB | 13 page-outs and 2 page-ins | Same |
| arm64 macOS 15.8.2 | 3.375 GiB | 50 page-outs and 1 page-in | Same |

Each trial began with the stock prefix and zero configured swap, created a
separate APFS volume, observed a new 1 GiB swapfile there and verified every word
of its synthetic allocation. The trace must name both the target swapfile and
the exact device. Global counters and workload size are separate observations:
this does **not** mean the entire allocation was swapped, or attribute particular
page I/O to that allocation. On arm64 the probe's own verification interval
reported zero global swap-ins; the broader volume trace still observed one
page-in. Do not collapse those different time windows into a workload-page claim.

Reports and revision/job/artifact identifiers are in `evidence/mac-placement`.
The first two reports are preserved with explicit corrections to historical
derived fields in [the experiment README](../labs/macos-swap-placement/README.md).
Schema 2 identifies thread IDs correctly and leaves workload attribution
unestablished. Raw target I/O and the memory integrity results are retained.

- [Initial Intel run](https://github.com/EmotiveImpact/CLOUDSWAP/actions/runs/42845793503)
- [Repeated Intel run](https://github.com/EmotiveImpact/CLOUDSWAP/actions/runs/42847101980)
- [Schema 2 Intel/arm64 run](https://github.com/EmotiveImpact/CLOUDSWAP/actions/runs/42849385474)

The schema 2 experiment completed successfully on both architectures at
`6db50c1198b00cfbca5c95667a254408b92eb8a9`. Intel foundation CI at that revision
also passed the native tests, release build, packaged probes and FUSE/helper
fault checks. The latest macOS 26 foundation rerun remained queued; the earlier
verified arm64 native/mounted results remain distinct evidence. The combined
final local diagnostic/R2 suite passed 28 tests.

Six safe local placement tests passed: actual trace format/path/device matching, memory
budget, 32 MiB integrity, bad allocation sizes, large-allocation refusal, and
refusal to change configuration outside the explicit disposable CI environment.
The privileged experiment was never executed on the user's working Mac.

## Remaining engineering and acceptance

1. **External SSD product integration:** select and verify a physical volume,
   preserve recovery/boot availability, handle future swap-file creation and
   prove application survival. Restoring the prefix does not migrate or drain
   existing pages. Never offer an eject action for a drive carrying live swap.
2. **Cloud kernel path:** the original NFS mode has a fixed 4 MiB file. The
   [growable mode](SPARSE-VOLUME.md) now implements creation, resizing and atomic
   catalogue commits. Resolve its retained-object cap, memory residency and
   recovery design before attempting kernel paging through it. A successful
   ordinary NFS mount is not sufficient. R2 object/pager probes are a separate
   interoperability gate.
3. **Live R2:** configure the four named repository secrets and run the existing
   acceptance workflow. Its current report records missing configuration.
4. **Physical trials:** dedicated Mac and external SSD, sustained pressure,
   reconnect, sleep/wake and controlled failure. Hosted disk images cannot
   establish physical connection or boot behaviour.
5. **User benefit:** measure actual internal allocated bytes saved after cache
   and metadata, app survival and latency percentiles for representative apps.

The menu-bar app remains a monitor and synthetic storage laboratory. It does
not yet redirect Chrome, Codex or Claude swap, and no internal-space saving is
claimed. These boundaries are implementation work as well as missing hardware
and configuration, not merely a request to switch on credentials.
