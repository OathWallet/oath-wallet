# Sui transaction approval

The approval screen shows simulated object effects before the fee and balance
summary. Each object card includes its complete ID, Move type, previous owner,
and resulting owner or recipient. Canonical Sui `TreasuryCap` objects carry a
mint-authority warning; `UpgradeCap` objects carry an upgrade-authority warning.
Other non-coin objects have an explicit permissions warning because a custom
Move type's authority cannot be inferred safely from its name.

The screen also lists every programmable transaction command. Direct
`TransferObjects` recipients are decoded as addresses. Commands and object
effects remain visible without opening the optional **Sign data** details.

Object metadata comes from the simulation's input and output states, alongside
coin balance changes. Missing or truncated results, duplicate objects, mismatched
input references, and incomplete transfer effects prevent approval preparation.
Before signing, the wallet re-simulates and compares the object effects with the
reviewed snapshot. Older saved reviews without object effects require a fresh
review.

## Validation

`WalletConnectSuiObjectReviewTests` uses synthetic transactions to cover mint and
upgrade authority, custom and misleading type names, direct and result-object
transfers, recipients, pagination, missing metadata, and changed object effects.
`Tools/CheckReviewLocalization.py` checks the production presentation code and
all 57 language catalogs, including placement on the approval surface.

Run the host package tests with:

```sh
python3 Tools/CheckPackageHost.py OathAnkr
python3 Tools/CheckReviewLocalization.py
```

An additional testnet-only simulation check requires an explicit
`OATH_SUI_OBJECT_REVIEW_FIXTURE` file. `Tools/PrepareSuiObjectReviewTestnet.mjs`
creates an unsigned disposable fixture when explicitly invoked with `--run`.
Neither the default host tests nor this fixture check broadcasts a transaction.
These checks do not establish native screen rendering or a live WalletConnect
session on an iPhone.
