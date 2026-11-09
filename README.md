# Oath Wallet 5.0.3

A native multichain wallet for iPhone and iPad.

**Release: 5.0.3 (110).** Faster send preparation, clearer transaction totals, Manage Tokens, improved asset filtering and artwork performance, and updated wallet setup. This is a regular GitHub source release prepared for a separate App Store upload and review submission. The Apple-approved release record remains [5.0.2 (104)](releases/5.0.2.md) until delivery of a newer build is confirmed.

[Published security review and remaining scope](https://github.com/OathWallet/oath-wallet-security-review) · [Current release metadata](https://oathwallet.org/release-status.json)

[Release notes and verification](releases/5.0.3.md) · [Website](https://oathwallet.org) ·
[Security model](Documentation/SecurityModel.md) · [Reporting policy](SECURITY.md) · [Build configuration](Documentation/PublicBuild.md) ·
[MIT license](LICENSE)

## What's new

- Send begins preparing the selected asset's balance early and safely reuses fresh results across supported networks. Wallet, account, chain and asset changes cancel obsolete work.
- Send Review separates the native amount, transfer charges and network fee, retaining exact signing amounts and final authorization checks.
- Manage Tokens and asset filters make saved assets easier to find, track and organize. Reset restores the full asset list.
- Token and collectible artwork loads with bounded background work, downsampling and caching while preserving original export data.
- Wallet setup has refreshed welcome artwork and layout; Receive QR presentation retains its original export encoding.
- Monad account classification requires independent provider confirmation, and interrupted unsigned TRON sends can recover without altering signed or broadcast transactions.

Earlier improvements included in this release:

- Scanned addresses show their validated networks and logos, with clearer review actions and left-to-right address presentation.
- EVM send quotes can recover from a stale provider using a fresh, chain-verified fallback; broadcast retry rules remain unchanged.
- EVM quote preparation preserves insufficient-balance guidance without duplicate error records, and discards cancelled or stale completion results.
- Unichain and HyperEVM portfolio synchronization uses the configured ANKR RPC with each chain's existing indexer, without depending on Alchemy configuration.
- Story uses its dedicated RPC and explorer history path. Celo history uses smaller pages and individual receipt checks.
- NEAR history handles repeated indexed transaction versions without double-counting fees, and respects bounded rate-limit retry delays.
- XRP recovers an advancing recent-history window; THORChain refreshes finish cancelling earlier history work before starting a new generation.
- Restored wallets retain legacy passphrase metadata even when their passphrase is empty. Existing encrypted wallet formats remain readable.
- Retains the Solana WalletConnect delegate-approval review fix, including explicit allowance and unlimited-approval warnings.
- Solana WalletConnect rejects missing nonce-account values as malformed provider responses, preserving the distinction between an unavailable response and an explicitly closed account.
- Improves optional token artwork, native status-bar handling and expected authentication-error classification.
- Refresh completion and selection checkmarks keep their native shape in every language; directional layout follows the app’s selected language.
- Tiny fiat balances and fees preserve the mathematical meaning of their comparison signs in both left-to-right and right-to-left text.
- Tiny native balances, signed transaction amounts and below-cent send previews also preserve their comparison signs in right-to-left text, without changing editable amounts or signing.
- Wallet setup, settings, history and WalletConnect review use directional symbols and layout while keeping addresses and raw transaction data left-to-right.
- Asset rows show a unit price alongside the wallet’s fiat value and native quantity. Missing price coverage has a localized “Price Untracked” explanation. Public unit prices stay visible when balances are concealed.
- Switching wallets returns Home to the selected wallet’s balance header; updates to the same wallet preserve its scroll position.
- WalletConnect connection errors explain the cause and next step in all 57 supported languages, including expired codes, offline connections and unsupported requests. Price-coverage and Polkadot import/receive guidance is also updated.

Cronos infrastructure is included for compatibility testing but remains disabled in the app. It is not advertised as an enabled network.

## Public source boundaries

This public repository includes the app, bundled assets, local packages, patched
Reown dependency, tests, and the complete [website, Help Center and articles](Website/README.md).
Website service implementations and [deployment workflows](Distribution/README.md) are also public.
Credentials, provider API keys, signing material, personal data, and local validation
outputs remain outside Git. Website services are separate from the self-custodial iOS app. Remote recovery-phrase collection and its upload integration
are absent. Recovery input stays local; signing happens on the device.

Diagnostics retain the shared privacy filter and bounded local outbox. This public
build has no diagnostic upload transport or operator endpoint. Optional encrypted
iCloud backup is separate from diagnostics and requires your own Apple capability
configuration. Never put real wallet material in tests, issues, or support reports.

## Release verification

The [5.0.3 (110) release](https://github.com/OathWallet/oath-wallet/releases/tag/v5.0.3-build110) pins this version's source and build settings. Its [verification record](releases/5.0.3.md) provides reproducible commands, validation results, limitations, and the exact GitHub workflow inputs for later upload. Creating this release does not upload to Apple or submit it for review.

[Build 105's prerelease evidence](releases/5.0.3-build105.md) remains historical and is not evidence of build 110 delivery.

The [5.0.2 (104) release record](releases/5.0.2.md) retains its Apple approval status and original validation evidence.

The [5.0.0 (102) delivery record](releases/5.0.0.md) documents the earlier build delivered to Apple.

Source review, secret scanning, compilation and focused tests are performed during
release preparation. These are maintainer-directed checks, not an independent
security audit or a reproducible comparison of Apple's redistributed binary.

## Build

Use Xcode 27 and Swift 6. The app deployment target is iOS 17; individual visual
features use availability checks for newer system versions.

```sh
git clone https://github.com/OathWallet/oath-wallet.git
cd oath-wallet
sh Tools/PreparePublicBuild.sh
open OathAtmosphere.xcodeproj
```

Select the **OathAtmosphere** scheme, which builds **Oath Wallet**. Dependencies are
pinned by package manifests and `Package.resolved`. The checked-in project can be
regenerated with XcodeGen using `project.yml`.

The preparation script only creates an empty, ignored local provider configuration.
No API key is needed to compile. Network-backed features and WalletConnect require
your own provider configuration; see [PublicBuild.md](Documentation/PublicBuild.md).
Device signing and iCloud require your own Apple development team.

Compile without launching a simulator or installing on a device:

```sh
xcodebuild -project OathAtmosphere.xcodeproj -scheme OathAtmosphere \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/oath-public-build CODE_SIGNING_ALLOWED=NO build
```

## Validation

```sh
python3 Tools/ValidatePublicRelease.py --scan
python3 Tools/CheckDiagnosticsCoverage.py
swift test --package-path Packages/OathDiagnostics
python3 Tools/CheckMultiWallet.py --lifecycle
```

Secret-scanner exceptions are restricted to reviewed public fixtures and syntax
false positives. Their file hashes are checked by the release validator; changes
require renewed review. Live network tests are opt-in. Simulator, device, and
App Store results must be reported separately from source and host tests.

For security issues, use [private vulnerability reporting](https://github.com/OathWallet/oath-wallet/security/advisories/new).
See the bundled third-party notices and dependency licenses for attribution.

## Reproducible security review

A [maintainer-commissioned, Codex-led review](https://github.com/OathWallet/oath-wallet-security-review)
now tracks the [5.0.2 (104) release](https://github.com/OathWallet/oath-wallet/releases/tag/v5.0.2-build104).
Earlier audit results retain their original tested commits; the current target and remaining work are recorded in the review repository.
It publishes its exact source targets, findings, tests, and outstanding coverage.
The review is **in progress**, is not independent certification, and does not
establish equivalence with Apple's distributed binary. Later changes do not
automatically inherit its conclusions.
