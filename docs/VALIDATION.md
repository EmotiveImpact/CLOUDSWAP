# Validation record: 10 November 2026

| Check | Result |
|---|---|
| Rust unit tests | 6 passed, including five outage-policy scenarios within one test |
| Rust bundled helper | Five scenarios passed; output explicitly reports simulation and system_swap_active=false |
| Original Python storage tests | 10 passed on macOS |
| Native R2 local self-test | AES-GCM round trip, object-identity authentication rejection and SHA-256 known answer passed |
| Upstream provenance | All 75 source blobs matched original Git SHA-1 IDs |
| Native Mac release build | SwiftUI application and R2 probe compiled on arm64 macOS |
| App signing | Ad-hoc signing and strict signature verification passed; not notarised |
| GUI launch | Attempted; LaunchServices returned kLSServerCommunicationErr (-10822) in the tool environment. Interactive menu appearance/clicks not verified |
| Swap metric query | Sandbox denied direct sysctl query. App displays unavailable on failure rather than a fabricated value |
| Real R2 calls | Not run; credentials not available in this session |
| Linux kernel swap | Verified guest swap-out and swap-in through encrypted NBD and a loopback HTTP object service |
| macOS system swap | Not redirected; no kernel/storage driver installed |
| Physical Wi-Fi loss | Not tested; simulations are not represented as physical trials |

These checks establish a buildable foundation, not useful cloud-backed system swap. No claims of disk-space savings or improved app performance are supported yet.

## Native transport follow-up

Added a Swift XCTest suite exercising request scope and size limits, endpoint validation, a known-answer HMAC vector, signature payload binding, offline/reconnect, timeout propagation and HTTP failure rejection. URLSession uses a redirect-refusing delegate. Test responses are injected using URLProtocol; no physical network loss or live R2 is claimed. CI now executes the Swift suite before building the Mac application.

Still required: secure bucket-scoped R2 credentials and permitted R2 network access; and a compatible isolated Mac with driver-development provisioning for the SCSI experiment. The native adapter and system-swap attachment remain unimplemented, not completed by these tests.

## Encrypted native reference store

Added PagingStore, a bounded 16 KiB block / 256-block local reference backend. Blocks and the index use AES-GCM; block identity is authenticated. Immutable object writes precede atomic index replacement. A file lock excludes concurrent writers. A write error poisons that instance rather than acknowledging an uncertain result.

Seven additional tests cover close/reopen with the same key, overwrite/reopen, wrong-key rejection, simultaneous writer rejection, corruption, missing-index rejection and bounds. These are real temporary-file tests. They do not yet test abrupt process termination, power loss, rollback of an older valid index, or cloud persistence. Keys are caller-owned and are not saved by the library. This module is not connected to the UI, Rust engine, R2 or a driver yet. Failed writes can leave orphan objects; automatic reclamation remains pending. No system swap configuration changes are made.

## Integrated remote pager and external storage

RemotePager now connects the native encryption/index module to ObjectBackend, with R2Client implementing that interface. Only the encrypted index stays local; page payloads go to the backend. The actor rejects overlapping operations while awaiting network I/O. Failed writes poison the session; reads recover after connectivity returns. Immutable old objects are retained until explicit lab cleanup; production garbage collection and abrupt-crash/power-loss guarantees remain pending.

Five new tests exercise remote round trip with a small local index, reopen, offline/reconnect, lost write acknowledgements and corrupted objects. These use an in-memory object service. `R2Lab --pager-live` exercises the same path with R2, including reopen and tracked synthetic-object cleanup. It requires the existing R2 environment settings and has not been run live here.

The local PagingStore accepts a directory on an external drive as well as an internal one. That is a storage-backend capability, not automatic macOS swap relocation. Physical unplug/replug and volume-identity validation are not yet tested. Do not use it for real application memory. Abrupt device loss must fail visibly rather than recreate storage at an unmounted path.

## Linux kernel paging and disconnects

The [Linux kernel swap lab](https://github.com/EmotiveImpact/CLOUDSWAP/actions/workflows/linux-swap-lab.yml) boots a disposable QEMU guest and limits the probe to 12 MiB of RAM while it fills and verifies 24 MiB of synthetic data. The guest swaps to a virtio disk backed by nbdkit. The gateway encrypts blocks and sends them over HTTP to a test object service outside the guest.

The [first run](https://github.com/EmotiveImpact/CLOUDSWAP/actions/runs/42817073745) recorded 6,120 page-outs and 6,151 page-ins in the healthy case. The probe verified all 24 MiB. With an immediate read failure during a one-second service disconnect, the workload received SIGBUS. The outage harness interrupts HTTP connections on loopback. R2 and physical network or drive loss still require separate trials.

The lab compares a 2.5-second retry budget against one-second and four-second service outages. The native R2 pager applies the same budget to immutable page reads after transient network errors. HTTP responses such as 404 propagate immediately. Writes retain their existing uncertain-acknowledgement policy.
