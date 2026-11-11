# Oath Wallet

A native multichain wallet for iPhone and iPad.

**Available on the App Store:** [Oath 5.0.2 (104)](https://apps.apple.com/app/id6780187283) for iPhone and iPad, iOS/iPadOS 17 or later. [Distribution evidence](releases/5.0.2-distribution.json).

[Is Oath right for me?](https://oathwallet.org/about#wallet-fit) · [Dated wallet compatibility results](https://oathwallet.org/compatibility/2026-11-09)

[Published security review and remaining scope](https://github.com/OathWallet/oath-wallet-security-review) · [Current release metadata](https://oathwallet.org/release-status.json)

[Release notes and verification](releases/5.0.2.md) · [Website](https://oathwallet.org) ·
[Security model](Documentation/SecurityModel.md) · [Reporting policy](SECURITY.md) · [Build configuration](Documentation/PublicBuild.md) ·
[MIT license](LICENSE)

## Latest source release

[Oath 5.1.0 (110)](https://github.com/OathWallet/oath-wallet/releases/tag/v5.1.0-build110) identifies the current release source. See its [changes and build-verification record](releases/5.1.0.md). Apple upload, processing and public availability are recorded separately.

## In Oath 5.0.2

- Check the transferred asset and network fee in their native units on a transaction receipt.
- Identify an asset by its symbol, full name and network before selecting it.
- Review [WalletConnect requests](https://oathwallet.org/features/walletconnect) and [token permissions](https://oathwallet.org/features/revoke-token-approvals) for the networks each tool supports.

## Public source boundaries

This public repository includes the app, bundled assets, local packages, patched
Reown dependency, tests, and the complete [website, Help Center and articles](Website/README.md).
Website service implementations and [deployment workflows](Distribution/README.md) are also public.
Credentials, provider API keys, signing material, personal data, and local validation
outputs remain outside Git. Website services are separate from the self-custodial iOS app. Recovery input stays local; signing happens on the device.

Diagnostics use privacy filtering and bounded on-device storage. Optional encrypted
iCloud backup is separate from diagnostics and requires your own Apple capability
configuration. Never put real wallet material in tests, issues, or support reports.

## Release verification

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
