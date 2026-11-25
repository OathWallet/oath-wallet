[Home](https://oathwallet.org/) / Compatibility Lab

Oath Wallet Compatibility Lab · 2026-11-09

# Same keys. Different accounts?

Compare Trust Wallet, MetaMask and Electrum account recovery with Oath. Explore versioned derivation results, Bitcoin address types, methods and limitations.

[Compatibility matrix](https://oathwallet.org/compatibility)[Results · 2026-11-09](https://oathwallet.org/compatibility/2026-11-09)[Methods & reproduction](https://oathwallet.org/compatibility/methodology)

**Reviewed release**

Oath 5.0.2 (104)

**Reference-library checks**

14 + 4 source assertions

**Oath core host tests**

14 passed · 1 skipped

**Installed-app / funded tests**

Not performed

Keep your recovery material private. This is a reference, not an import tool. It never asks for a recovery phrase or private key. Use the installed wallet’s recovery flow; never send recovery material with a correction or support request.12 scoped comparisons · edition 2026-11-09

## Start with the account you have.

A wallet name alone cannot establish compatibility. Read the account type, path and limitation together. Each result links to its dated evidence.

Account restoration scope against Oath 5.0.2; not a blanket wallet certification

Wallet / account

Finding

Evidence

Key limitation

Trust Wallet[First ordinary EVM account](https://oathwallet.org/compatibility/2026-11-09#trust-evm)

Default path aligns

Reference-library checks

Covers the first ordinary BIP39 account. It does not establish every Trust Wallet app version, account index, token discovery result or smart account.

Trust Wallet[Bitcoin native SegWit, account 0](https://oathwallet.org/compatibility/2026-11-09#trust-bitcoin)

Default path aligns

Oath core host tests

Other address types have separate core checks below. This is not a balance-discovery or funded-transfer test of Trust Wallet.

Trust Wallet[First TRON account](https://oathwallet.org/compatibility/2026-11-09#trust-tron)

Default path aligns

Reference-library checks

A matching address does not verify every TRC-20 contract, available TRX/resources or sending behavior.

Trust Wallet[Solana account convention](https://oathwallet.org/compatibility/2026-11-09#trust-solana)

Different defaults; compare the address

Reference-library checks

Use the matching account convention in Oath and compare its public address with the original wallet. An automatic match or full historical-account discovery was not tested.

MetaMask[First ordinary EVM account](https://oathwallet.org/compatibility/2026-11-09#metamask-first)

First-account derivation agrees

Reference-library checks

Only ordinary phrase-derived EVM accounts are covered. Social-login recovery, hardware wallets, smart accounts and non-EVM/Snap accounts are outside this result.

MetaMask[Later or separately imported EVM account](https://oathwallet.org/compatibility/2026-11-09#metamask-later)

A different account needs its own key or matching path

Reference-library checks

This does not show that phrase import automatically restores all accounts. An individual key covers one account, not the other accounts derived from the phrase or a separately imported key.

Electrum[Electrum-generated standard seed](https://oathwallet.org/compatibility/2026-11-09#electrum-standard)

Legacy derivation fixtures pass

Oath core host tests

This is Electrum’s own versioned seed format, not a BIP39 phrase merely used inside Electrum. No installed Electrum app or funded migration was exercised.

Electrum[Electrum-generated SegWit seed](https://oathwallet.org/compatibility/2026-11-09#electrum-segwit)

Native SegWit derivation fixtures pass

Oath core host tests

Do not infer the seed format from the address prefix alone. Multisig and Lightning state are outside this ordinary single-wallet result.

Electrum[Old Electrum seed encoding](https://oathwallet.org/compatibility/2026-11-09#electrum-old)

Old-format fixtures pass

Oath core host tests

Old seeds do not support an extra seed extension in this implementation. An encrypted wallet-file password is not the same as a seed extension.

Electrum[Standard or SegWit seed with extension](https://oathwallet.org/compatibility/2026-11-09#electrum-extension)

Normalization and account isolation checks pass

Oath core host tests

The website cannot recover a forgotten extension. Oath 5.0.2 excludes Electrum-derived wallets from its encrypted iCloud export; retain the original seed and extension backup privately.

Electrum[2FA / TrustedCoin or custom multisig](https://oathwallet.org/compatibility/2026-11-09#electrum-two-factor)

Outside this migration scope

Limited checks; migration unverified

Do not use this row as a supported migration procedure. TrustedCoin interaction, original 2FA protection and custom multisig recovery were not validated end to end.

Other account types[Hardware, smart accounts, social login, custom scripts](https://oathwallet.org/compatibility/2026-11-09#other-accounts)

Not evaluated

Not evaluated

No installed-app compatibility claim is made for hardware pairing, smart-account deployment/owners, social login, Snap accounts or custom scripts. Consult the original wallet’s recovery method.

No comparisons match both filters. Reset the filters to see every result.

[Download comparison CSV](https://oathwallet.org/compatibility/2026-11-09.csv) · [Download full evidence JSON](https://oathwallet.org/compatibility/2026-11-09.json)

Why an address can change

## The phrase is only part of the map.

A recovery phrase is used with a seed format, any additional passphrase, a derivation path and an account/address index. Bitcoin also needs the right script type. Change one of those inputs and the visible account may change.

### Different account index

For ordinary MetaMask EVM accounts, the leaf ending in `/0` is different from `/1`. Restoring the first account is not proof that a later or separately imported account was restored.

### Different Solana convention

The reviewed Trust Wallet convention ends at `m/44'/501'/0'`. Oath’s default ends at `m/44'/501'/0'/0'`. Our reference check produced distinct addresses.

### Different Bitcoin format

A BIP39 native SegWit account and an Electrum-generated SegWit account can both show `bc1q` addresses while using different seed and path rules. A prefix is not a recovery recipe.

### Same address, missing balance?

First compare the public address, exact network and asset identifier with the original wallet and a suitable explorer. A network not being displayed, token-discovery limits, an address gap or an account beyond the checked range can hide history without changing the keys. The Lab has not tested live balance discovery for every wallet.

[Check the token’s network](https://oathwallet.org/networks/choose-token-network) · [Review Oath’s refresh guidance](https://help.oathwallet.org/articles/refresh-balances)

## Import keys. Don’t expect a cloned app.

### Access that can carry over

Matching keys and account rules can restore control of the corresponding on-chain account. Its assets stay on their original networks. Importing does not send funds or move them to a new address.

The original wallet can still use the same keys. On-chain approvals, delegations or restrictions are not revoked by an import.

### Settings that do not follow the phrase

Local labels, contacts, saved RPC endpoints, custom-token lists, app preferences, dApp sessions and hardware pairing are app-specific. They are not encoded in a recovery phrase.

Lightning channel state, smart-account policies and multisig cosigner arrangements need their own recovery procedures. A matching address alone does not establish that these are preserved.

### What to compare before relying on it

- Identify the original account type and recovery method.
- Compare the expected public address on the exact network.
- Review receive and change history where applicable.
- Keep the original backup until the relevant accounts are independently checked.

Never paste recovery material into this website, an explorer, a support message or a search engine.

## Bitcoin: four address types checked in core code.

These tests execute OathBitcoin on macOS. They do not demonstrate an installed wallet migration or a funded spend. A Bitcoin address beginning with 3 or bc1 can represent other scripts outside this single-key scope.

### Legacy

P2PKH · starts with 1

`m/44'/0'/0'/change/index`Account 0: initial receiving address matches a fixed published expectation; seed and mnemonic-derived branches agree for receive/change indexes 0–19.

### Nested SegWit

P2SH-P2WPKH · starts with 3

`m/49'/0'/0'/change/index`Account 0: initial receiving address matches a fixed published expectation; seed and mnemonic-derived branches agree for receive/change indexes 0–19.

### Native SegWit

P2WPKH · starts with bc1q

`m/84'/0'/0'/change/index`Account 0: initial receiving address matches a fixed published expectation; seed and mnemonic-derived branches agree for receive/change indexes 0–19.

### Taproot

Single-key P2TR · starts with bc1p

`m/86'/0'/0'/change/index`Account 0: initial receiving address matches a fixed published expectation; seed and mnemonic-derived branches agree for receive/change indexes 0–19.

Here, `change` is 0 for receiving and 1 for change. Additional tests cover compressed versus uncompressed single keys, extended-key version families and rejection of invalid inputs. These helper tests do not establish a watch-only public-key import feature in the app.

[Inspect the exact test inventory](https://oathwallet.org/compatibility/2026-11-09#test-inventory)

## Ready to check your starting wallet?

[

### Trust Wallet to Oath

Read the recovery steps, supported scope and backup limitations.

](https://articles.oathwallet.org/move-from-trust-wallet-to-oath)[

### MetaMask to Oath

Read the recovery steps, supported scope and backup limitations.

](https://articles.oathwallet.org/use-metamask-wallet-in-oath)[

### Electrum to Oath

Read the recovery steps, supported scope and backup limitations.

](https://articles.oathwallet.org/restore-electrum-bitcoin-wallet-on-iphone)

## Keep a result you can cite.

[Edition 2026-11-09](https://oathwallet.org/compatibility/2026-11-09) includes every result, the exact versions, test inventory and limits. [Read the methods and reproduce the run.](https://oathwallet.org/compatibility/methodology)
