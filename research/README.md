# Preserved upstream sources

The two `*-source.tar.gz` archives contain the complete pinned source trees, with upstream notices intact. They are research references, excluded from the application build. The corresponding manifests record original Git modes and blob hashes.

Extract from the repository root, then verify:

```sh
mkdir -p research/upstream
tar -xzf research/s3backer-source.tar.gz -C research/upstream
tar -xzf research/Infiniswap-source.tar.gz -C research/upstream
python3 scripts/verify-sources.py
```

See [the research register](RESEARCH.md) for pins, findings, attribution and per-component licensing notes. These archives are snapshots, not full Git histories. No upstream installer has been executed.
