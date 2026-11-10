# Live R2 acceptance

The native encrypted object and pager probes now have a repeatable runner:

```sh
python3 scripts/r2-acceptance.py --readiness-only --report /tmp/r2-readiness.json
python3 scripts/r2-acceptance.py --helper dist/CLOUDSWAP.app/Contents/Helpers/R2Lab --report /tmp/r2-live.json
```

Configuration uses `R2_ENDPOINT`, `R2_BUCKET`, `R2_ACCESS_KEY_ID` and
`R2_SECRET_ACCESS_KEY` in the environment. Use a dedicated private test bucket
and scoped credentials. Do not put values in source or command arguments.
The GitHub workflow uses repository secrets with these same names. It runs on
relevant `main` changes or manual dispatch, never automatically on PR code.
Missing configuration produces a readiness artefact and skips the live job;
a green readiness job is **not** live R2 acceptance.

Each probe writes 16 KiB of encrypted synthetic data under a unique
`cloudswap-lab/<uuid>/probe` key, verifies readback, then attempts deletion of its
own object. The second closes and reopens the remote pager before reading.
Success requires both probes to verify and confirm cleanup. Failure or timeout
is recorded without printing helper output, credentials, account endpoints or
bucket names. A timeout or cleanup failure can leave encrypted synthetic
objects in the test bucket; inspect its lab prefix before removing test data.
Do not use this prefix for unrelated objects.

Six runner regressions cover missing configuration, redaction, verification
markers, cleanup failure and timeouts. These are simulated process outcomes,
not network acceptance. The actual helper transport already has native tests.

This proves storage interoperability only when a live report passes. It does
not attach R2 to macOS system swap, exercise a physical Wi-Fi drop, preserve
real application memory, or establish useful performance and disk savings.


## Recorded configuration result, 10 November 2026

[Main run 42849542676](https://github.com/EmotiveImpact/CLOUDSWAP/actions/runs/42849542676)
passed the six runner tests and recorded all four required secrets as absent.
The live Mac job skipped. `docs/evidence/r2/readiness.json` preserves the report
and provenance. No live R2 request or successful cloud acceptance is claimed.
