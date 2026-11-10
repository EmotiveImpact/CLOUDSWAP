# External storage and offline protection

The Mac menu-bar app includes **Test external drive folder…**. Choose a folder on an attached drive. The test creates a unique subdirectory, writes 64 encrypted 16 KiB pages, closes and reopens the store, verifies every byte, then removes the synthetic files. The key exists only for that test. If the drive disappears, the test reports failure and encrypted test files may remain. It does not redirect macOS swap.

## Directory identity and recovery

Local pages and the remote pager's index now use a pinned directory descriptor. Reads, writes, renames and object deletion are relative to that descriptor. The original path must still identify the same device and inode before operations proceed. Replacing the mount path cannot redirect those operations into another directory. Symlink objects and non-regular files are rejected; reads are size-bounded.

Writes use exclusive temporary files, file fsync, atomic rename and directory fsync. Any uncertain write stops the session. Observed directory loss also stops the session, requiring explicit reopening after access returns. These are filesystem flush operations, not proof of hardware power-loss durability. The local store will not create missing parent directories beneath a disappeared mount.

## Optional full local mirror

`RemotePager(..., mirror: true)` writes encrypted page copies locally before uploading and committing its index. Reads use the local copies, including while the network is unavailable. Reopening in this mode verifies that every committed page has an authenticated local copy. Switching an existing cloud-only store to mirrored mode therefore fails until its pages have been provisioned locally. The option is currently a library API, not a menu toggle.

This mode protects reads during network outages. Writes still require remote acknowledgement and an index commit. An uncertain upload stops the session. It does not protect against simultaneous loss of the mirror drive. The key must be retained by the caller; production key management remains unfinished.

`localProtectionBytes()` reports committed ciphertext payload bytes, 16,412 bytes per page. It excludes the encrypted index, allocation overhead, and temporary or orphan files after a failed write. Successful overwrites remove the previous local page. A failed operation can leave an orphan, and reopening does not yet reclaim it automatically. Capacity is bounded to 256 logical pages per store, not an unlimited swap device or a global disk quota.

A full mirror on the internal SSD consumes approximately the same page storage we hoped to reclaim. A mirror on an external SSD can move that storage off the internal drive for this prototype's pages. Neither configuration proves that native macOS application swap can use the store.

## Verification

29 native XCTest tests passed locally on 10 November 2026, including seven new cases for directory replacement, observed disconnect and reopen, symlink rejection, remote-index replacement, offline mirrored recovery, missing mirror rejection and ciphertext corruption. Latest R2 retry tests were included. Directory renaming models path loss in these tests; it is not a physical USB disconnect test.

Still required: physical external-drive unplug/replug under load, power interruption, live R2 credentials and interoperability, native macOS swap attachment, and interactive menu testing. Linux kernel paging evidence is recorded separately in VALIDATION.md.
