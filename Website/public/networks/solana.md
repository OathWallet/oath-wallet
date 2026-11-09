# Solana wallet: send and receive SOL

Keep SOL and supported Solana tokens together, with receiving, sending and compatible dApp connections.

## Receive Solana

1. Open Oath, select your wallet and choose Solana in Receive.
2. Copy the receiving address or show its QR code. Confirm the exact network with the sender.
3. Use the Solana address in Receive. Match a token by its mint and network, not its symbol alone.
4. After the sender broadcasts the transfer, follow its status in Oath. Network confirmation can take time.

## Send SOL

1. Open Send and select the asset on Solana. Paste the recipient’s address or scan their QR.
2. Keep SOL for fees and any required token-account creation. Review the fee and remaining balance before confirming.
3. Enter the amount and any required memo or tag. Compare the complete destination with the recipient’s instructions.
4. Review the asset, network, amount and fee, then confirm in Oath. Follow the transaction status after broadcast.

## dApp connections

Connect to compatible Solana dApps through WalletConnect. The website must request a network and signing method supported by Oath. Review every connection and signing request in the app. A website that only detects browser extensions may not offer a compatible mobile connection.

1. Open a trusted dApp and choose Oath if it is listed, or choose WalletConnect.
2. On desktop, scan the connection QR with Oath. On iPhone or iPad, use a compatible app link or the connection option offered by the dApp.
3. Review the website, selected wallet, Solana network and requested permissions before approving.
4. Review each signing request separately. Disconnect the session from Oath when you are finished.

## Questions

### How do I receive Solana in Oath?

Open Oath, select your wallet and choose Solana in Receive. Copy the receiving address or show its QR code. Confirm the exact network with the sender. Use the Solana address in Receive. Match a token by its mint and network, not its symbol alone.

### What pays the Solana transaction fee?

SOL is the native fee asset for this network account. Keep SOL for fees and any required token-account creation. Review the fee and remaining balance before confirming.

### Can I connect Solana dApps?

Connect to compatible Solana dApps through WalletConnect. The website must request a network and signing method supported by Oath. Review every connection and signing request in the app. A website that only detects browser extensions may not offer a compatible mobile connection.

### Can I send to the same address on another network?

Only send using the network the recipient explicitly supports. A matching address or ticker does not bridge assets or make different chains interchangeable.

Features depend on the app version, network, wallet type and the service you connect to. Check the available actions in your installed app before transferring.

[Network catalog](https://github.com/OathWallet/oath-wallet/blob/6ff671b3e8f2ca8b8388ddebbf95f783a6ea0c7a/OathAtmosphere/Import/OathImportCatalog.swift) · Updated 2026-10-31. Source review is not confirmation of App Store availability.

[Get Oath for iPhone and iPad](https://apps.apple.com/app/id6780187283) · [All networks](https://oathwallet.org/networks)


## Receive SOL and Solana tokens in the intended account.

Choose Solana in Oath’s Receive flow for SOL, or select the exact Solana token for a token payment. Copy the address from that account and make sure the sender uses Solana mainnet. Confirm the token mint when receiving USDC or another token.

- **Native coin:** SOL pays transaction fees in the ordinary Oath transfer flow.
- **Tokens:** Each token has a mint; a matching name or logo does not prove it is the intended asset.
- **Account:** When restoring a wallet, compare the selected Solana derivation with the source wallet.

### Example: the same phrase, a different address

An imported phrase can expose a different Solana account when a different derivation path is selected. Compare the public address with your source wallet and use Oath’s supported account options before asking the sender to transfer.

![Oath Solana asset screen with mock balance and sample sent and received activity](https://oathwallet.org/assets/guides/2026-11-09/solana.webp)

Oath 5.0.2 (104) · Mac simulator. Real app capture with mock balances, prices and transfer history. No live transfers were made. Always use your own receiving details; never send funds to an example address.

## SOL transfers and token transfers have different requirements

A token payment can involve a recipient token account as well as the transaction fee. If that account needs creating, the SOL requirement can be greater than the transaction fee alone. Review Oath’s estimate for the actual recipient and asset.

## Check mainnet before troubleshooting a balance

A transfer on Devnet or Testnet will not become mainnet SOL or USDC. Confirm the explorer’s cluster, the recipient and, for tokens, the mint. A transaction signature is useful evidence only when those details match.

## Questions before you transfer

### Can I use an Ethereum address to receive SOL?

No. Use the Solana receiving address shown in Oath. An EVM 0x address is not interchangeable with a Solana account.

### Does a USDC balance pay the SOL fee?

Oath’s ordinary Solana send flow needs SOL for fees and any applicable token-account creation. Holding USDC alone does not guarantee the send can proceed.

### What should I send to support about a missing transfer?

Share the public transaction signature, network/cluster and expected token mint. Those identify the transfer without sharing your private key or recovery phrase.

- [Receive USDC on Solana](https://oathwallet.org/tokens/usdc/solana)
- [Choose the matching Solana account](https://help.oathwallet.org/articles/solana-address-path)
- [Check the network fee asset](https://oathwallet.org/networks/fees)
- [Understand pending, confirmed and failed activity](https://help.oathwallet.org/articles/transaction-status)

### Sources and review

App steps checked against the linked release source; token identities and network requirements checked against the sources below. Screenshots show the actual app interface with mock data, not completed live transfers.

- [Solana: transaction fees](https://solana.com/docs/core/fees)
- [Solana: token accounts](https://solana.com/docs/tokens/basics/create-token-account)
- [Oath 5.0.2: receiving flow](https://github.com/OathWallet/oath-wallet/blob/d039b009d8c81b0497f2ac7e6abebfdf54ff8612/OathAtmosphere/Home/OathReceiveSheet.swift)
- [Oath 5.0.2: asset details and activity](https://github.com/OathWallet/oath-wallet/blob/d039b009d8c81b0497f2ac7e6abebfdf54ff8612/OathAtmosphere/Assets/OathAssetDetailScreen.swift)
- [Oath 5.0.2: supported send flows](https://github.com/OathWallet/oath-wallet/blob/d039b009d8c81b0497f2ac7e6abebfdf54ff8612/OathAtmosphere/Send/OathSendModel.swift)

Guidance reviewed for Oath 5.0.2 (104); updated 2026-11-09. [How we review guides](https://oathwallet.org/about#editorial).

<!-- token-catalog:start -->
## Tokens on Solana

Native coin: SOL. 7465 catalog token entries.

- [USDC (USDC) on Solana](https://oathwallet.org/tokens/usdc/solana)
- [Tether (USDT) on Solana](https://oathwallet.org/tokens/usdt/solana)
- [Jupiter (JUP) on Solana](https://oathwallet.org/tokens/jupiter-exchange-solana/solana)
- [Jito (JTO) on Solana](https://oathwallet.org/tokens/jito-governance-token/solana)
- [PayPal USD (PYUSD) on Solana](https://oathwallet.org/tokens/paypal-usd/solana)
- [Bonk (BONK) on Solana](https://oathwallet.org/tokens/bonk/solana)
- [Raydium (RAY) on Solana](https://oathwallet.org/tokens/raydium/solana)
- [Render (RENDER) on Solana](https://oathwallet.org/tokens/render-token/solana)
- [Pyth Network (PYTH) on Solana](https://oathwallet.org/tokens/pyth-network/solana)
- [dogwifhat (WIF) on Solana](https://oathwallet.org/tokens/dogwifcoin/solana)
- [.png (.PNG) on Solana](https://oathwallet.org/tokens/png/solana)
- ["　" ("　") on Solana](https://oathwallet.org/tokens/6/solana)

[Browse all Solana tokens](https://oathwallet.org/networks/solana/tokens). Catalog inclusion is not issuer verification or individually tested sending.
<!-- token-catalog:end -->
