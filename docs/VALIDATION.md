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
| Linux kernel swap | Not run; no Linux VM runtime found |
| macOS system swap | Not redirected; no kernel/storage driver installed |
| Physical Wi-Fi loss | Not tested; simulations are not represented as physical trials |

These checks establish a buildable foundation, not useful cloud-backed system swap. No claims of disk-space savings or improved app performance are supported yet.
