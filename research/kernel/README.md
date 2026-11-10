# Pinned kernel research

Three upstream repositories have been cloned and inspected, with two XNU revisions preserved as separate submodules. Source is fetched through pinned Git submodules rather than flattening upstream projects into the application. This preserves repository identity, exact revisions and licence files. The development acquisitions are shallow clones; this is not a full-history archive.

```sh
git submodule update --init --recursive -- research/kernel-sources
python3 scripts/verify-kernel-sources.py
python3 scripts/map-xnu-swap.py research/kernel-sources/xnu-macos14.5
python3 scripts/map-xnu-swap.py research/kernel-sources/xnu
```

| Checkout | Revision | Purpose |
|---|---|---|
| xnu-macos14.5 | 2c2f96dc2b9a4408a43d3150ae9c105355ca3daa | Published xnu-10063.121.3 source, matching the observed host's XNU version |
| xnu | f6217f891ac0bb64f3d375211650a4c1ff8ca1ea | Upstream main snapshot acquired 10 November 2026 |
| ipsw | e5a578c6f2f48be177fddf200d435d83cab1c38c | Kernel extraction, inspection and symbolication tooling |
| symbolicator | 08dbc783663750530d655cb88c1e755aefa10950 | Symbolication signature corpus |

`sources.json` records exact commits, trees, tracked-file counts and licence hashes. Local verification checked clean checkouts, revisions and licences for 20,590 tracked files across these four checkouts. XNU has APPLE_LICENSE plus per-file notices; both blacktop repositories have MIT licence files. Preserve all notices. Inclusion as research does not automatically establish that copying any file into a distributed driver is appropriate.

Read [FINDINGS.md](FINDINGS.md) for source-derived findings and [the multi-Mac plan](../../docs/MULTI-MAC-TEST-PLAN.md) for experiments. JSON maps are reproducible source anchors, not complete call graphs or proof of runtime support.

The tools and signature corpus were inspected, not installed or run against a kernel binary. A version-matching published XNU source tag does not guarantee that every shipping binary or proprietary filesystem component is represented identically.
