# Disaggregated memory research

Acquired 10 November 2026. This collection includes all 11 repositories returned by GitHub's `topic:memory-disaggregation` repository search and 12 related projects. It is a dated discovery snapshot, not a claim to cover every project in the field. The topic webpage was rate-limited; the GitHub API search supplied the topic list.

## What is saved

`manifest.json` records each repository URL, exact commit and tree, root document Git blob hashes, and initial licence-discovery status. `sources/` contains 23 pinned Git submodules. These preserve upstream identity and licence files when checked out; they are not 23 full source archives embedded in CLOUDSWAP. Availability still depends on upstream hosting. Infiniswap and s3backer also have the earlier source archives in `research/`.

Three source trees were downloaded and selected code inspected during this pass: r3map, ram-dl and fastswap. The other 20 have revision/root-document discovery evidence; their complete source has not been downloaded or audited in this pass. No upstream installation script or kernel code was executed. A licence notice at the root is not a completed licence audit; an absent root notice does not mean the entire repository is unlicensed. Check file headers, nested licences and dependencies before copying code into the product.

## Download source selectively

From the CLOUDSWAP repository root:

```sh
git submodule update --init --depth 1 -- research/disaggregation/sources/pojntfx--r3map
git submodule update --init --depth 1 -- research/disaggregation/sources/pojntfx--ram-dl
git submodule update --init --depth 1 -- research/disaggregation/sources/clusterfarmem--fastswap
python3 scripts/verify-disaggregation.py
```

To download all 23 top-level trees, use `git submodule update --init --depth 1 -- research/disaggregation/sources`. This can consume several gigabytes. Nested dependencies are deliberately not recursively initialised. Some research projects contain whole kernels, JDKs or additional submodules. Do not run a global recursive checkout on a space-constrained Mac. CI fetches only the kernel sources required by its source-map checks.

Read [FINDINGS.md](FINDINGS.md) for project selection, inspected-code findings and experiments. A downloaded Linux pager is not a native macOS pager. No project in this survey establishes working system swap for existing Mac applications.
