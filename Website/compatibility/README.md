# Oath release compatibility evidence

The current edition checks Oath **5.1.1 (111)** at source tag `v5.1.1-build111`.
Accepted evidence is in `../content/compatibility/2026-11-26.json`: 18 reference/source checks and 14 passing Mac host tests, with the funded test skipped.

Images are historical captures. No installed third-party app, simulator, physical device or funded-transfer check is claimed.

```sh
git worktree add --detach ../oath-release v5.1.1-build111
npm ci --prefix Website/compatibility --ignore-scripts
node Website/compatibility/run.mjs ../oath-release ../oath-lab-results
```

The runner requires the exact clean tagged source and a new output directory. It keeps dependency versions, source hashes, run times, skipped tests and coverage limits in its report. Earlier editions remain in Git history.
