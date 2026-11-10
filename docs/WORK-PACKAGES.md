# Work packages

| ID | Work | Acceptance | State |
|---|---|---|---|
| CS-01 | Pin and preserve upstream research | Full s3backer/Infiniswap tree blobs verify against Git IDs | Complete |
| CS-02 | Mac menu-bar foundation | Builds; displays actual metrics or unavailable; runs labelled simulation | Built with external-folder test; interactive UI verification pending |
| CS-03 | Portable Rust failure policy | Unit tests cover bounds, missing data, overwrite, uncertain writes | Complete for emulator scope |
| CS-04 | Native encrypted R2 probe | PUT/GET authentication, cleanup, actual timings | Built; live R2 credentials/access needed |
| CS-05 | Linux VM swap experiment | Nonzero swap I/O and post-page-in checksums under controlled memory pressure | Verified against loopback HTTP service; live R2 pending |
| CS-06 | Mac storage-adapter proof | Mounted reads/writes/flush verified; chosen runtime and kernel paging requirements resolved | Native encrypted file server and optional FUSE frontend implemented; callbacks/process recovery tested, actual mount unverified |
| CS-07 | Mac swap attachment proof | XNU measurably pages a sacrificial process through adapter | Unresolved; no supported registration route established |
| CS-08 | Production engine | Encrypted journal/index recovery, bounded caches, concurrency and failure tests | Native bounded stores and full mirror implemented; combined cloud/mirror trial added; production recovery/key management unfinished |
| CS-09 | Wi-Fi trials | 1/10/60 second outages, packet blackhole, reconnect, sleep/wake; integrity and stalls measured | Pending live trials |
| CS-10 | Usability and space trial | Saved allocated disk bytes net of fallback; p50/p95/p99 delays; app survival | Pending |
| CS-11 | Cairn storage integration | Durable file restore contract and separate consent/eviction design | Separate future track |

## Controlled experiment matrix

Run baseline local swap, remote-only, and bounded-cache configurations. Keep the gateway outside the constrained Linux VM. Use synthetic incompressible buffers and verify checksums after forced page-in. Record kernel logs and workload exit status, not just successful HTTP calls.

For every configuration measure logical offloaded bytes, allocated local bytes, metadata/cache bytes, HTTP count, read/write amplification, CPU, resident memory, throughput and latency percentiles. Confirm actual swap I/O before calling a run a swap test.

Faults: disconnected route, silently dropped packets, DNS failure, delayed response, committed PUT with lost acknowledgement, authentication failure, HTTP 429/5xx, corrupted/missing object, gateway restart, full local cache, machine sleep/wake. A successful retry at storage level does not establish application survival.

The Linux lab enables swap and injects faults only in its disposable test setup. No scripts change the user's macOS swap or apply faults to the user's Wi-Fi.

Current checkpoint and next actions are in [CODEX-HANDOVER.md](CODEX-HANDOVER.md). External storage and mirror behaviour are in [EXTERNAL-STORAGE.md](EXTERNAL-STORAGE.md).
