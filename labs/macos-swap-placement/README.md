# Disposable Mac swap-placement experiment

This is a separately scoped kernel experiment, not an app feature or a command
to run on a working Mac. The previous hosted Intel test read `vm.swapfileprefix`
and successfully wrote its unchanged stock value. Apple source shows that the
kernel uses this prefix when creating future swap files. Neither observation
proves that another volume can carry actual pages.

The CI workflow now investigates a separate APFS **disk-image volume** on a
disposable hosted Intel Mac. It does not use a physical external SSD, change
startup security, install a driver, run dynamic_pager or remove live swap files.
The Apple Silicon placement trial remains a separate unverified cohort.

## Reviewed execution and recovery boundaries

1. Require the explicit disposable-test CLI flag, root and the hosted CLOUDSWAP
   CI environment. These are accident-prevention checks, not authentication
   against a person deliberately forging their own environment.
2. Require the stock prefix and zero configured swap before setup, then check
   both again immediately before changing the prefix. Refuse an existing setup.
3. Require at least 8 GiB free disk space. Create a new 6 GiB sparse APFS image
   and verify a different filesystem device identity from the internal VM volume.
4. Change only the prefix to the unique mounted volume. Preserve a report before
   pressure. A bounded C process writes deterministic, incompressible synthetic
   anonymous memory, then verifies every word. It stops growing after observing
   swap-out activity or reaching its limit. It reserves at least 2 GiB of RAM,
   uses at most 85% of physical RAM, caps touched memory at 12 GiB and has a
   120-second alarm. The Python supervisor has its own 150-second deadline.
5. Record same-boot paging snapshots, target-file identities/allocation changes,
   workload integrity, global swap-in/out deltas and filtered fs_usage lines.
   The trace stores at most 200 target-volume lines and excludes other paths.
6. Restore the original prefix if it still equals our test prefix. This only
   controls future files; it is **not a drain or migration**. After any attempted
   prefix change, leave the volume mounted and its image intact until the hosted
   runner is destroyed. Never detach a possible live swap volume during cleanup.

An interrupted or failed experiment may leave the test volume mounted until
runner teardown. It must not be reused as a local-machine installation procedure.
This code was reviewed for the mutation boundary, timeout path and retained-volume
behaviour before its first CI run. No placement experiment was run on the user's Mac.

## Result interpretation

`candidate_observed` requires both growing/new target swap files and global
swap-out activity while the prefix points at that volume. It is correlation,
as defined by `scripts/mac-swap-evidence.py`; do not promote it to an external
SSD certification or native app survival claim. Inspect the target I/O trace,
counter deltas and exact workload result separately. The workload reports global
counters, not per-process attribution.

`no_candidate_observed`, skipped preconditions and rejected control writes are
valid negative observations, never positive acceptance. Integrity failures,
exceptions and inability to confirm prefix restoration fail the workflow.
The JSON always leaves physical external/cloud swap unverified. CI completion
alone is not a paging proof, and this experiment measures no net disk saving.

## Safe local checks

The small workload uses 32 MiB and does not change swap configuration:

```sh
clang -O2 -Wall -Wextra -Werror labs/macos-swap-placement/probe.c -o /tmp/cloudswap-memory-probe
CLOUDSWAP_MEMORY_PROBE=/tmp/cloudswap-memory-probe \
  python3 -m unittest discover -s labs/macos-swap-placement -v
```

The tests verify the memory limits, every word of the small allocation, invalid
size rejection, refusal of a large workload without the explicit CI flag, and
refusal of the placement harness before writing any report or changing settings.
Do not copy the privileged workflow invocation into a normal terminal.
