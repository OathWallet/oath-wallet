# Wallet Compatibility Lab reproduction

The first edition reviews Oath 5.0.2 (104) at
`d039b009d8c81b0497f2ac7e6abebfdf54ff8612`. The website's current branch may contain
later app code; the runner refuses to test that code as the released edition.

Accepted evidence: `../content/compatibility/2026-11-09.json`. It records 14
reference-library vectors, four source assertions and 14 passing OathBitcoin host
tests. One funded integration test was skipped. Trust Wallet, MetaMask and
Electrum apps were not installed or executed. Wallet Core 4.8.4 is a reference
library, not an installed Trust Wallet version.

## Run

From the repository root on macOS with Xcode command-line tools and Node:

```sh
git worktree add --detach ../oath-5.0.2 d039b009d8c81b0497f2ac7e6abebfdf54ff8612
npm ci --prefix Website/compatibility --ignore-scripts
node Website/compatibility/run.mjs ../oath-5.0.2 ../oath-lab-results
```

Use the tooling revision that introduced the dated edition (inspect Git history
for its JSON) when reproducing it later. The report records actual host and
dependency versions; it does not assert every host is equivalent. The npm lockfile
pins package integrity; Swift uses the released package resolution. Dependencies
may be downloaded; test derivation is offline. No simulator, physical device or
transaction broadcast is used. The runner removes `OATH_ELECTRUM_REGTEST_DIR`
from the child environment to skip funded integration.

Only public synthetic fixtures from the pinned repository are used. Never modify
this runner to take a visitor's phrase, private key or wallet file. An optional
third argument selects an installed Wallet Core package folder and checks its
version; prefer the lockfile installation for independent reproduction.

Outputs in a new local folder:

- `reference.json`: reference vectors, source assertions and hashes.
- `host-tests.log`: local Swift output, not a public website download.
- `results.json`: successful expected inventory and execution metadata.

A failed run must not become a passing report. A prior successful `results.json`
is never overwritten. Compare case IDs, statuses, versions and hashes; durations
and timestamps differ. Results are not imported into the public edition
automatically. Review scope, limitations and fixture provenance before accepting
a snapshot. No secret values, recovery inputs or machine paths may enter it.

## Publish an edition

Keep accepted evidence in `Website/content/compatibility/<date>.json`. Add its
dated route and current pointer to `catalog.json`; preserve older editions.
Corrections need a dated note in `changes`. Matrix rows must reference passing
checks at their stated layer. A skipped test cannot support a passing result.

`npm run predeploy` validates the snapshot and builds HTML, Markdown, JSON and CSV.
The existing GitHub checks and Deploy website workflow publish it. Website CI
validates source hashes and evidence references; it does **not** rerun macOS host
tests or turn the saved run into a new observed result.
