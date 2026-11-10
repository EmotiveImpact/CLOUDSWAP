# Native Mac mount laboratory

A Rust NFSv3 bridge exports the same fixed 4 MiB encrypted virtual file through
macOS's built-in NFS client. It shares the Swift file-server protocol with the
FUSE adapter. No third-party filesystem runtime, kernel extension or system swap
configuration is needed for this file test. This is a laboratory, not a system
swap service or a production network export.

An additional opt-in `--sparse-lab` mode now supports growable encrypted files,
including create, resize, truncate/regrow, rename/replacement and deletion.
Its separate helper protocol, object limits, allocation measurements and
acceptance tests are documented in [SPARSE-VOLUME.md](../../docs/SPARSE-VOLUME.md).
The fixed-file contract below describes the original `--synthetic-lab` mode.

The loopback wire test passes locally: 64 FILE_SYNC writes (32 pipelined), explicit COMMIT,
server/helper process-group death and a full 4 MiB recovery from a fresh process.
Actual mounting is tested separately in the `Mounted Mac storage lab` workflow
on disposable Intel and arm64 Mac runners. Consult its result rather than
inferring mount success from the wire test.

## Run

```sh
swift build --package-path apps/macos --configuration release --product R2Lab
cargo test --locked --manifest-path labs/macos-nfs/Cargo.toml
cargo build --locked --release --manifest-path labs/macos-nfs/Cargo.toml
python3 labs/macos-nfs/lab.py \
  --server labs/macos-nfs/target/release/cloudswap-nfs-lab \
  --helper apps/macos/.build/release/R2Lab \
  --report nfs-wire-result.json
```

Adding `--mount` attempts an actual mount using `/sbin/mount_nfs`, writes via the
mounted path, calls fsync, unmounts, restarts the server/helper, remounts and
verifies the entire file again, including mmap reads. A further fresh mount
pauses the server/helper for one second and requires a cold read to block then
recover intact. This is a server pause, not a physical Wi-Fi test. The test never
configures system swap. `--ci`
permits passwordless sudo for mount/unmount only and is restricted to
GitHub-hosted disposable runners. Normal local execution never requests sudo.
A denied or failed mount is a failed test, not a simulated pass.

The harness generates an ephemeral encryption key in memory and operates on
synthetic data in a new private temporary directory. It does not print the key.
Cleanup refuses to recursively delete a directory that is still mounted.
The standalone bridge accepts `--synthetic-lab HELPER MODE DIRECTORY`; its modes
are the native helper's local, remote and mirror create/open modes. Live R2
requires the existing R2 environment configuration and has not been verified by
this NFS lab. Do not export an existing directory containing personal data.

## Contract and limits

- Loopback TCP only, dynamic port. NFS AUTH_SYS is not strong authentication.
  Other local processes may access the export. This interface is for synthetic
  experiments and must not serve private paging data as a shipping product.
- `pages` is the only file. Fixed capacity; 64 KiB request maximum; no namespace,
  size, ownership or permission mutations. Virtual capacity is not disk savings.
- Native writes finish their page/index commits and a checkpoint before NFS
  reports FILE_SYNC. Explicit COMMIT calls the native checkpoint. Checkpoint authenticates the persisted index and compares it with the current
  session. Loss or rollback stops the session. There is no deferred dirty-data queue. Multi-page writes remain non-atomic, and physical
  power-loss durability remains unproved.
- Helper IPC has a bounded frame and deadline. Uncertain writes stop the helper
  session. NFS file handles change after server restart; the test unmounts and
  remounts explicitly. It does not pretend transparent recovery of open handles.
- The pinned NFS implementation has local hardening: bounded RPC/XDR lengths,
  eight connections, serial processing per connection and a bounded reply queue,
  request-count validation, explicit COMMIT support and independent bounded TCP
  receive/reply flows to avoid pipelined-write deadlocks. See `UPSTREAM.json`.
- Client caching can affect reads. The acceptance test requires a clean unmount
  and fresh process/remount before its full-file verification. A warm cached read
  alone does not establish cloud availability or on-disk recovery.
- No evidence from this file test establishes XNU swap selection, anonymous
  memory paging, external SSD unplug behaviour or native application survival.

## Upstream and runtime decision

The vendored server is [huggingface/nfsserve](https://github.com/huggingface/nfsserve)
0.11.0 at commit `327b45530f04664da678297ce2568c47bf3fbf81`. Its BSD-3-Clause
licence and source are preserved; original and modified hashes are recorded in
`UPSTREAM.json`. Cargo.lock pins the other dependencies. No FUSE-T or macFUSE
binary is included or installed by this laboratory.

FUSE-T 1.2.9 was downloaded and inspected, not installed. Its package licence
requires a commercial licence for commercial use/bundling. macFUSE's licence
also places conditions on automated commercial distribution/installation.
Those are deployment decisions to resolve if adopting those runtimes. The
existing FUSE frontend remains available for a prepared, appropriately licensed
lab machine. The NFS laboratory gives us an independently testable mount path.
