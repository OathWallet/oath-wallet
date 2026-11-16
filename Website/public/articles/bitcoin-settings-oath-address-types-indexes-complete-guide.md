# Bitcoin Address Types: SegWit, Taproot and Address Indexes

Oath Editorial · Originally published September 11, 2026 · Updated November 16, 2026

https://articles.oathwallet.org/bitcoin-settings-oath-address-types-indexes-complete-guide

To receive BTC in Oath, open Receive and choose Bitcoin. A standard seed wallet starts with Native SegWit (bc1q). Use an address format the sender accepts. When restoring an existing wallet, first match the address type and account you used before.

## Guide source version

Reviewed against Oath 5.0.2 (104) on November 16, 2026. The walkthrough uses historical screenshots. Check the available address types in your own wallet.

## Choose a Bitcoin receiving address

When multiple formats are available, use the address-type control in Receive, choose a format and copy the address or show its QR code. The choices depend on the wallet you opened.

- Native SegWit (BIP84) — bc1q. Oath creates a single-key SegWit receiving address for this format.
- Taproot (BIP86) — bc1p. Check that the sender accepts a Taproot destination.
- Nested SegWit (BIP49) — 3. Other Bitcoin scripts can also start with 3, so the prefix alone cannot identify an imported account.
- Legacy (BIP44) — 1. This is the available format for an uncompressed single private key.

Switching the format changes which address you display. It does not move BTC between addresses.


## Understand account, change and address indexes

For a standard Native SegWit account on Bitcoin mainnet, m/84'/0'/0'/0/1 means account 0, receiving branch 0, address index 1. Indexes start at zero. The first receiving address ends in /0/0 and the second in /0/1.

Change uses branch 1. For example, /1/0 is the first change address in that account. When a payment spends more input value than the amount and fee, the wallet can return the remainder to a change address it controls. Share a receiving address from Receive.


## Check what your import can restore

If a restored balance looks wrong, compare a previously used public address with the same format, account and branch in the original wallet. A fresh unused address can belong to the same wallet.

A single private key cannot recreate a sequence of HD addresses. An account-level extended key covers its branch of the derivation tree and cannot recreate other hardened accounts. Electrum and aezeed have their own recovery rules. Preserve any original seed extension or password. Aezeed recovery in Oath covers supported on-chain accounts only.


## Recognize unsupported addresses

Oath 5.0.2 does not receive or discover Bitcoin Silent Payments (sp1). A Taproot address beginning with bc1p is a different format. If a recovery format is unsupported, keep access to the original wallet.


## Before sharing an address

Choose Bitcoin mainnet on both sides, compare the complete destination and check the fee in the sending wallet. Use only an address displayed by your own wallet. Keep recovery words, private keys and backup passwords private, including when contacting support.

Sources: [Receive screen](https://github.com/OathWallet/oath-wallet/blob/d039b009d8c81b0497f2ac7e6abebfdf54ff8612/OathAtmosphere/Home/OathReceiveSheet.swift) · [Bitcoin address derivation](https://github.com/OathWallet/oath-wallet/blob/d039b009d8c81b0497f2ac7e6abebfdf54ff8612/Packages/OathBitcoin/Sources/OathBitcoin/BitcoinKeys.swift) · [BIP44 account and address indexes](https://bips.dev/44/) · [BIP84 Native SegWit](https://bips.dev/84/) · [BIP86 Taproot](https://bips.dev/86/) · [Release record](https://github.com/OathWallet/oath-wallet/releases/tag/v5.0.2-build104).

<!-- oath-walkthrough:start -->
## Bitcoin: know the address and recovery scope — visual walkthrough transcript

Guidance checked against 5.0.2 (104) source on November 16, 2026. Included screenshots are historical examples. This is an illustrated guide, not a recording of a current App Store test.

### 1. Match the address family

Use the Bitcoin address types offered for the imported material. Compatible wallets include Native SegWit, Taproot, nested SegWit and Legacy.

### 2. Understand receiving addresses

A fresh HD receiving address can belong to the same wallet. A single key or scoped extended key has narrower recovery scope.

### 3. Recognize change

Change returns unspent value to an address controlled by the wallet. Generated addresses are not evidence of received funds.

### 4. Check current limits

Silent Payments receiving and discovery are not supported in 5.0.2. Preserve the original format, account information and any required passphrase.

[Open the visual walkthrough](https://articles.oathwallet.org/bitcoin-settings-oath-address-types-indexes-complete-guide#visual-walkthrough)
<!-- oath-walkthrough:end -->
