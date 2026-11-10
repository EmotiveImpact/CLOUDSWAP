# Combined cloud and local-mirror trial

This increment connects the existing encrypted RemotePager, optional local mirror and R2 client into one reproducible trial. A selected existing folder can be on the internal disk or an external SSD. The tool does not classify the volume as external or attach storage to macOS system swap.

## Menu-bar app

Choose **Test offline mirror recovery…**, then a folder. This uses a synthetic in-memory remote backend and real encrypted files in the selected folder. It performs the same lifecycle as the command-line trial without contacting R2. The menu action compiles; interactive UI clicks have not been verified in this environment.

## Command-line modes

Build with `bash scripts/build-mac.sh`, then run:

```sh
# No credentials or network required; defaults to the system temporary directory.
dist/CLOUDSWAP.app/Contents/Helpers/R2Lab --tiered-self-test

# Real local files on your selected drive, with a synthetic remote service.
dist/CLOUDSWAP.app/Contents/Helpers/R2Lab --tiered-self-test --directory /Volumes/TestSSD/CloudswapTests

# Real R2 upload/read/delete, followed by an injected transport outage.
dist/CLOUDSWAP.app/Contents/Helpers/R2Lab --tiered-live --directory /Volumes/TestSSD/CloudswapTests
```

The parent folder must already exist. The live mode uses the existing `R2_ENDPOINT`, `R2_BUCKET`, `R2_ACCESS_KEY_ID` and `R2_SECRET_ACCESS_KEY` environment configuration. Use the dedicated synthetic-test bucket described in CODEX-HANDOVER.md. The trial generates its own UUID object names and only attempts deletion of keys it tried to upload, including uncertain PUTs. No credentials are printed. Live mode writes 64 encrypted pages totalling 1 MiB of plaintext, plus encryption overhead, and performs 64 reads and normally 64 deletes. These are billable operations subject to the account's allowances.

## Five checks

1. Write 64 random 16 KiB pages to remote storage and the encrypted local mirror. Retain hashes rather than a plaintext copy of all pages.
2. Reopen with mirroring disabled and verify every page through the remote backend. A correct local copy cannot hide corrupt remote data.
3. Block the trial's transport, reopen with mirroring enabled, then verify every page from the selected folder without remote reads.
4. Attempt an offline overwrite. It must fail and stop further use of that pager session.
5. Reopen again and verify the previous committed page remains intact. The uncommitted local ciphertext orphan is included in allocation measurement and cleanup.

Reopening is within the same process, with the same in-memory encryption key. This does not prove process-restart key recovery or power-loss durability. The injected outage blocks the trial backend only. It does not disable Wi-Fi or physically unplug the SSD. The mirror must remain available; removing both the network and the only local copy is not a supported recovery case.

## Reports and cleanup

The CLI emits JSON identifying live R2 versus simulated remote mode. Exit status 0 requires the storage checks and both cleanup steps to succeed; incomplete cleanup exits 1 and lists remaining remote keys. Invalid command syntax exits 2.

The report includes logical bytes, filesystem-reported allocated file bytes, forwarded remote GET/PUT counts, blocked operations, completed stages and p95 page-read times. Timing includes local page authentication/hash verification and is a small sequential trial, not a throughput or application-responsiveness benchmark. In-memory remote timings are not R2 latency measurements.

Allocated bytes sum `st_blocks * 512` for trial files, including index, lock and any orphan. Directory allocation, APFS shared/exclusive extent accounting, internal filesystem overhead and net system-disk savings are not measured. A full mirror necessarily retains approximately the full data size on the selected volume.

Cleanup operates on the trial's regular files through its pinned directory descriptor, rejects unexpected names/nonregular files, and preserves an empty test directory. It does not recursively remove a path that may have been replaced after a disconnect. On failure, encrypted synthetic files may remain at the reported path; the ephemeral trial key is not saved. They are disposable test data, not recoverable user documents.

## Verification on 10 November 2026

- 38 native XCTest tests passed on this branch, including eight lifecycle/failure tests and one R2 HTTP adapter integration test using URLProtocol stubs.
- Verified corruption is not masked by a mirror, ambiguous uploads are included in cleanup, cleanup failures cannot produce a pass, and replaced directories/unrelated local files are preserved.
- Release app built and passed deep/strict ad-hoc signature verification. Both pre-existing helper self-tests passed.
- Packaged release trial passed: 64 PUTs, 64 remote GETs, one blocked offline write, all five stages passed, no remote objects left and local trial files removed.
- Observed allocation was 1,335,296 bytes for 1,048,576 plaintext bytes in the local temporary directory. The saved report normalises only the temporary path.
- Live R2 was not run because configuration is absent. No physical external-drive, physical Wi-Fi or native Mac system-swap result is claimed.
