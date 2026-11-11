[Home](https://oathwallet.org/) / [Compatibility Lab](https://oathwallet.org/compatibility) / Methods

Oath Wallet Compatibility Lab · 2026-11-11

# A result is only as useful as its evidence.

How Oath reviews wallet recovery: pinned versions, public fixtures, reproducible checks and clear boundaries between source, core tests and observed behavior.

[Compatibility matrix](https://oathwallet.org/compatibility)[Results · 2026-11-09](https://oathwallet.org/compatibility/2026-11-09)[Methods & reproduction](https://oathwallet.org/compatibility/methodology)

Keep your recovery material private. This is a reference, not an import tool. It never asks for a recovery phrase or private key. Use the installed wallet’s recovery flow; never send recovery material with a correction or support request.

## Five questions behind each result

- What exact code? Pin Oath’s released source, dependency versions and relevant file hashes. Do not use an unreleased branch to describe an App Store release.
- Which account convention? Record the seed format, derivation path, script type and account range. Compare public addresses, not just symbols, wallet brands or the number of phrase words.
- Which execution layer? Label a source assertion, reference-library vector and actual Oath core test separately. Installed-app checks need their own app version, OS, steps and observed result.
- What could the check miss? List account-discovery, script-policy, extension, provider and transfer limits next to the result. Skipped tests stay visible.
- Can another person inspect it? Publish the input revision, test names, run metadata, source hashes and a reproduction runner. Use repository-owned public fixtures, never a visitor’s wallet.

## Read the evidence, not just the result.

### Source reviewed

Read or asserted against the pinned released source. This does not run an importer.

### Reference-library checks

Public fixtures executed in Wallet Core 4.8.4 WASM, with Oath path declarations checked separately. This does not execute the Oath app importer.

### Oath core host tests

Actual released OathBitcoin Swift code executed on a Mac, using public fixtures and mocked discovery where specified. This does not launch the iPhone app.

### Limited checks; migration unverified

Some cryptographic fixtures pass, but the original account policy or full restoration workflow is not established.

### Not evaluated

No compatibility result is asserted. A missing check is not a passing result.

## Reproduce this edition on a Mac

The accepted run used macOS 27.0, Apple Swift version 6.4.2 (swiftlang-6.4.2.1.9 clang-2100.4.1.1), Node v26.5.0, Wallet Core 4.8.4 and BitcoinDevKit 3.1.1. Use a current Xcode command-line toolchain compatible with the pinned package. Different host versions should be recorded as a new run.

The runner uses only public fixtures already in the repository. Package installation may access the network. It does not launch a simulator, connect a wallet or broadcast a transaction. The funded-test environment switch is explicitly removed.

```sh
git clone https://github.com/OathWallet/oath-wallet.git oath-lab
cd oath-lab
git worktree add --detach ../oath-5.0.2 d039b009d8c81b0497f2ac7e6abebfdf54ff8612
npm ci --prefix Website/compatibility --ignore-scripts
node Website/compatibility/run.mjs ../oath-5.0.2 ../oath-lab-results
```
[Runner, pinned npm lockfile and reproduction notes](https://github.com/OathWallet/oath-wallet/tree/main/Website/compatibility). The runner accepts only the recorded clean source revision and refuses to overwrite an existing successful result. For an exact reproduction, use the tooling commit recorded in that folder’s history.

### Interpret the output

`reference.json` records the 18 reference/source checks. `host-tests.log` records the Swift run. `results.json` is written only after the expected test inventory passes, including the explicitly skipped funded test. Compare test IDs, statuses, versions and source hashes; timestamps and durations will differ.

A failing or incomplete run is not evidence of compatibility. Review the error and retain the original result. Do not change expected addresses merely to make a test pass. Results from a reference engine do not substitute for executing Oath’s importer.

## Check an Electrum restore in the installed apps

This is a procedure for reviewers. The November 9 edition records core tests and public fixtures. Installed-app observations belong in a separately dated result.

- Record the Electrum version and OS, the Oath App Store version and the iOS version. Create a new, unfunded single-signature Standard or SegWit Electrum test wallet. Record its account type and whether a seed extension was used.
- In Electrum’s Addresses view, record receiving addresses at indexes 0 and 1 and the first change address. Use only this disposable wallet throughout.
- Restore the same test wallet inside Oath using its Electrum import and the matching extension. Compare the same Bitcoin address type, branch and index. Mark an address unavailable if the installed UI cannot show it. A matching balance is insufficient evidence.
- Publish versions, steps, public test addresses, and a match, mismatch or unobserved result for each row. Include any unexpected behavior. Keep all seed words, extensions, private keys and wallet files out of the report. No transfer is needed.

[Read the Electrum restoration guide](https://articles.oathwallet.org/restore-electrum-bitcoin-wallet-on-iphone) and compare your observations with the [dated core results](https://oathwallet.org/compatibility/2026-11-09).

## Version and correction policy

The current comparison links to dated results. A newly reviewed Oath release, added account format or new installed-app test gets a new edition with its own source revision and changes. Older editions retain the versions they actually checked.

If a published statement is wrong, correct it with a dated note on that edition; do not quietly upgrade the evidence level. Source and machine-readable result changes remain reviewable in GitHub. The website build validates references and test statuses before publishing.

### Report a mismatch safely

[Open a public issue](https://github.com/OathWallet/oath-wallet/issues) or [contact Oath support](mailto:care@oathwallet.org) with the edition, wallet/app versions, account type and the result ID. Describe the mismatch using public documentation or synthetic fixtures. Do not include a phrase, private key, passphrase, wallet file, personal address history or screenshots containing secrets.

For a vulnerability, use the [security reporting guidance](https://oathwallet.org/security). This Lab is maintained by Oath; references to other wallets are for interoperability research and do not imply endorsement.
