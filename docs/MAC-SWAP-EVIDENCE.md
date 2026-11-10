# Read-only Mac swap-placement evidence

This tool makes the next native experiment measurable. It records the current swap prefix, a hashed boot-session identifier, system swap-in/swap-out counters, and file metadata from a chosen directory. It never opens swap-file contents, configures swap, installs a driver, changes security policy, or allocates a pressure workload.

## Collect a baseline on a Mac

Run from the repository root in a normal terminal:

```sh
python3 scripts/mac-swap-evidence.py snapshot --directory /System/Volumes/VM > /tmp/cloudswap-before.json
# After an independently arranged test interval:
python3 scripts/mac-swap-evidence.py snapshot --directory /System/Volumes/VM > /tmp/cloudswap-after.json
python3 scripts/mac-swap-evidence.py compare /tmp/cloudswap-before.json /tmp/cloudswap-after.json
```

For a disposable-system external-volume experiment, pass the dedicated test directory instead. This option observes that directory; it does not select it as swap storage. The existing [multi-Mac test plan](MULTI-MAC-TEST-PLAN.md) governs the separate native attachment experiment. Do not run dynamic_pager or change the daily-use Mac's swap simply to satisfy this diagnostic.

Keep the two snapshots from the same Mac and boot, in order, across an interval where the selected prefix remains unchanged. Report files include the chosen path and file identifiers; inspect before sharing. No credentials or memory contents are collected.

## Interpretation

- `insufficient_evidence`: access was denied, a command was unavailable, the prefix was not on the target, or matching entries were nonregular files. Denied access is not evidence of an unsupported kernel feature.
- `incomparable`: boot, directory/device identity, prefix, page size, counter continuity or sample order changed.
- `observed`: both snapshots permit a comparison. Reports system-wide paging deltas, newly observed file identities and filesystem-reported allocation changes.
- `candidate_placement_observed`: target files appeared or allocation grew during system swap-out activity while the configured prefix matched the target. This is correlation only.
- `native_external_swap_verified` always remains false. File metadata and global counters cannot attribute page I/O to a volume, prove that a volume is external, or prove application integrity. These require independent target-volume I/O traces, volume topology and workload checks.

Snapshots are not atomic with respect to kernel activity. File deletion during enumeration causes an unavailable result rather than invented evidence. Directory descriptors pin metadata lookup; replaced directory identities and final-component symlinks are rejected. Ancestor symlinks are resolved by the OS. Only names matching the configured basename plus digits are inventoried, with a 4,096-entry cap. Allocated bytes use `st_blocks * 512`; this is not a measurement of live memory, exclusive APFS space, or net disk savings.

## Validation, 10 November 2026

18 Python tests passed: ten new diagnostic cases, four source-pin integrity cases and four existing capability cases. The cases include denied access, volume replacement, reboot, counter reset, reversed samples, malformed vm_stat output, symlinks and false-positive placement scenarios.

A read-only host sample observed 13 swap files with 13,958,643,712 filesystem-reported allocated bytes (13 GiB), and readable `vm_stat` swap counters. Prefix and boot-session sysctls were denied in the execution environment. Comparing two live samples correctly returned `insufficient_evidence`. No swap configuration or security policy was changed. This does not establish external/cloud swap operation.
