# Polkadot Wallet for iPhone: Send DOT to a Polkadot.js Account

Oath receives and sends native DOT on Polkadot Asset Hub. To receive DOT on your iPhone, open Receive and choose Polkadot. To send DOT to someone who uses Polkadot.js, you only need their public Polkadot address.

## Use Oath as a Polkadot wallet on iPhone

1. In Oath, select the wallet you want to fund. Tap Receive, choose Polkadot and copy the address or show its QR code.
2. Ask the sender to select native DOT on Polkadot Asset Hub mainnet. If a withdrawal service only says “Polkadot,” check which chain it uses before continuing.
3. Once the transfer is confirmed on Asset Hub, check the DOT balance in the same Oath wallet.

## How to send DOT to a Polkadot.js account

1. In the Polkadot.js Apps interface, select Polkadot Asset Hub mainnet and open Accounts. Copy the public Polkadot address of the account that should receive the DOT. If someone else owns that account, ask them to copy and share it.
2. On your iPhone, open the wallet that holds the DOT. Tap Send, select native DOT on Polkadot, paste the recipient’s address and enter the amount.
3. On the review screen, compare the full destination with the address from Polkadot.js. Check the final amount and network fee in DOT. Leave enough DOT for the fee and the account minimum. A new recipient must receive enough to meet the network minimum.
4. Confirm in Oath. Follow the transaction in Activity. After confirmation, open Accounts in Polkadot.js Apps on Asset Hub and check the recipient’s balance.

## dApp connections

Connect to compatible Polkadot dApps through WalletConnect. The website must request a network and signing method supported by Oath. Review every connection and signing request in the app.

1. Open a trusted dApp and choose Oath if it is listed, or choose WalletConnect.
2. On desktop, scan the connection QR with Oath. On iPhone or iPad, use a compatible app link or the connection option offered by the dApp.
3. Review the website, selected wallet, Polkadot network and requested permissions before approving.
4. Review each signing request separately. Disconnect the session from Oath when you are finished.

## Questions

### How do I receive Polkadot in Oath?

Oath receives and sends native DOT on Polkadot Asset Hub. To receive DOT on your iPhone, open Receive and choose Polkadot. To send DOT to someone who uses Polkadot.js, you only need their public Polkadot address.

### What pays the Polkadot transaction fee?

DOT is the native fee asset for this network account. Keep enough DOT for applicable fees and account requirements. Check the chain and asset before confirming an Asset Hub transfer.

### Can I connect Polkadot dApps?

Connect to compatible Polkadot dApps through WalletConnect. The website must request a network and signing method supported by Oath. Review every connection and signing request in the app.

### Can I send to the same address on another network?

Only send using the network the recipient explicitly supports. A matching address or ticker does not bridge assets or make different chains interchangeable.

Features depend on the app version, network, wallet type and the service you connect to. Check the available actions in your installed app before transferring.

[Network catalog](https://github.com/OathWallet/oath-wallet/blob/6ff671b3e8f2ca8b8388ddebbf95f783a6ea0c7a/OathAtmosphere/Import/OathImportCatalog.swift) · Updated 2026-10-31. Source review is not confirmation of App Store availability.

[Get Oath for iPhone and iPad](https://apps.apple.com/app/id6780187283) · [All networks](https://oathwallet.org/networks)






## Polkadot.js transfer questions

### Why is the balance missing from the Polkadot.js extension?

The extension manages accounts and signs requests. To view the balance, open Polkadot.js Apps, select Polkadot Asset Hub and check the same account under Accounts. If a transfer is still pending, check its status before sending again.

### Which address should I copy?

Use the recipient’s Polkadot-format SS58 address for their account on Asset Hub. If Oath rejects the address, have the recipient copy it again from the correct network. Never edit an address by hand or share a recovery phrase to receive DOT.

- [Open Accounts in Polkadot.js Apps](https://polkadot.js.org/apps/#/accounts)
- [What the Polkadot.js extension does](https://polkadot.js.org/extension/)
- [Polkadot’s guide to Asset Hub](https://support.polkadot.network/support/solutions/articles/65000181800-what-is-statemint-and-statemine-and-how-do-i-use-them-)
- [Polkadot account minimums](https://support.polkadot.network/support/solutions/articles/65000168651-what-is-the-existential-deposit-Info)
- [How the released Oath app checks a DOT transfer](https://github.com/OathWallet/oath-wallet/blob/d039b009d8c81b0497f2ac7e6abebfdf54ff8612/Packages/OathAnkr/Sources/OathAnkr/PolkadotSendClient.swift)

Guidance reviewed for Oath 5.0.2 (104); updated 2026-11-16. [How we review guides](https://oathwallet.org/about#editorial).

<!-- token-catalog:start -->
## Tokens on Polkadot

Native coin: DOT. 4 catalog token entries.

- [USDC (USDC) on Polkadot](https://oathwallet.org/tokens/usdc/polkadot)
- [Tether (USDt) on Polkadot](https://oathwallet.org/tokens/usdt/polkadot)
- [Gavun Wud (WUD) on Polkadot](https://oathwallet.org/tokens/gavun-wud/polkadot)
- [My Paqman Coin (MPC) on Polkadot](https://oathwallet.org/tokens/my-paqman-coin/polkadot)

[Browse all Polkadot tokens](https://oathwallet.org/networks/polkadot/tokens). Catalog inclusion is not issuer verification or individually tested sending.
<!-- token-catalog:end -->
