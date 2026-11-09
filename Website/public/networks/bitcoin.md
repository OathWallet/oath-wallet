# Bitcoin wallet: send and receive BTC

Receive native BTC with your Oath address and review your Bitcoin network fee before sending.

## Receive Bitcoin

1. Open Oath, select your wallet and choose Bitcoin in Receive.
2. Copy the receiving address or show its QR code. Confirm the exact network with the sender.
3. Choose a Bitcoin address format the sending service supports. Oath supports compatible Taproot, SegWit and Legacy accounts; the available choices depend on your wallet.
4. After the sender broadcasts the transfer, follow its status in Oath. Network confirmation can take time.

## Send BTC

1. Open Send and select the asset on Bitcoin. Paste the recipient’s address or scan their QR.
2. Bitcoin fees depend on transaction size and selected inputs. Max accounts for the fee. This is on-chain Bitcoin, not a Lightning invoice.
3. Enter the amount and any required memo or tag. Compare the complete destination with the recipient’s instructions.
4. Review the asset, network, amount and fee, then confirm in Oath. Follow the transaction status after broadcast.

## dApp connections

Connect to compatible Bitcoin dApps through WalletConnect. The website must request a network and signing method supported by Oath. Review every connection and signing request in the app.

1. Open a trusted dApp and choose Oath if it is listed, or choose WalletConnect.
2. On desktop, scan the connection QR with Oath. On iPhone or iPad, use a compatible app link or the connection option offered by the dApp.
3. Review the website, selected wallet, Bitcoin network and requested permissions before approving.
4. Review each signing request separately. Disconnect the session from Oath when you are finished.

## Questions

### How do I receive Bitcoin in Oath?

Open Oath, select your wallet and choose Bitcoin in Receive. Copy the receiving address or show its QR code. Confirm the exact network with the sender. Choose a Bitcoin address format the sending service supports. Oath supports compatible Taproot, SegWit and Legacy accounts; the available choices depend on your wallet.

### What pays the Bitcoin transaction fee?

BTC is the native fee asset for this network account. Bitcoin fees depend on transaction size and selected inputs. Max accounts for the fee. This is on-chain Bitcoin, not a Lightning invoice.

### Can I connect Bitcoin dApps?

Connect to compatible Bitcoin dApps through WalletConnect. The website must request a network and signing method supported by Oath. Review every connection and signing request in the app.

### Can I send to the same address on another network?

Only send using the network the recipient explicitly supports. A matching address or ticker does not bridge assets or make different chains interchangeable.

Features depend on the app version, network, wallet type and the service you connect to. Check the available actions in your installed app before transferring.

[Network catalog](https://github.com/OathWallet/oath-wallet/blob/6ff671b3e8f2ca8b8388ddebbf95f783a6ea0c7a/OathAtmosphere/Import/OathImportCatalog.swift) · Updated 2026-10-31. Source review is not confirmation of App Store availability.

[Get Oath for iPhone and iPad](https://apps.apple.com/app/id6780187283) · [All networks](https://oathwallet.org/networks)


## Receive Bitcoin on iPhone with the account checked.

Open your wallet in Oath, choose Bitcoin in Receive and copy the address shown for that account. Ask the sender to use the Bitcoin network. A Bitcoin Cash transfer, a wrapped BTC token and a Lightning payment are different transfer types.

- **Asset:** BTC on the Bitcoin network.
- **Address:** Use the current receiving address inside Oath and an address type the sender supports.
- **Fee:** An outgoing on-chain transaction pays a BTC network fee from the available spendable inputs.

### Example: an imported wallet looks empty

Before treating the balance as missing, compare the source wallet’s Bitcoin account and address type with the account shown in Oath. A valid phrase can lead to different derived accounts. Use the existing import guide for the source wallet and never enter recovery credentials into a web checker.

![Oath Bitcoin asset screen with mock balance and sample sent and received activity](https://oathwallet.org/assets/guides/2026-11-09/bitcoin.webp)

Oath 5.0.2 (104) · Mac simulator. Real app capture with mock balances, prices and transfer history. No live transfers were made. Always use your own receiving details; never send funds to an example address.

## What an on-chain confirmation tells you

A transaction may first appear pending and later gain confirmations in mined blocks. A screenshot or a sender’s withdrawal label is not confirmation. Check the public transaction ID in a Bitcoin explorer and follow the confirmation requirement of the receiving service.

## Why two Bitcoin sends can have different fees

A Bitcoin transfer spends unspent transaction outputs. The fee depends on the transaction’s size and chosen fee rate, not simply the fiat amount being sent. Many small inputs can make a transaction larger. Read Oath’s review before signing.

## Questions before you transfer

### Can I send Bitcoin Cash to this Bitcoin address?

No. BTC and BCH use separate networks. Choose the Bitcoin Cash guide when receiving BCH and the Bitcoin guide when receiving BTC.

### Does this page describe Lightning?

No. These receiving instructions cover Oath’s Bitcoin on-chain flow. A Lightning invoice is a different payment request and should not be substituted for this address.

### Should I reuse an address from a screenshot?

No. Screenshots contain public examples and mock data. Copy the address from your own selected wallet in Oath, then compare it at the sending service.

- [Understand Bitcoin address types](https://help.oathwallet.org/articles/bitcoin-address-types)
- [Restore a compatible Electrum Bitcoin wallet](https://articles.oathwallet.org/restore-electrum-bitcoin-wallet-on-iphone)
- [Bitcoin Cash receiving guide](https://oathwallet.org/networks/bitcoin-cash)
- [Understand pending, confirmed and failed activity](https://help.oathwallet.org/articles/transaction-status)

### Sources and review

App steps checked against the linked release source; token identities and network requirements checked against the sources below. Screenshots show the actual app interface with mock data, not completed live transfers.

- [Bitcoin developer guide: payments and confirmations](https://developer.bitcoin.org/devguide/payment_processing.html)
- [Oath 5.0.2: Bitcoin send review](https://github.com/OathWallet/oath-wallet/blob/d039b009d8c81b0497f2ac7e6abebfdf54ff8612/OathAtmosphere/Send/OathBitcoinSendModel.swift)
- [Oath 5.0.2: receiving flow](https://github.com/OathWallet/oath-wallet/blob/d039b009d8c81b0497f2ac7e6abebfdf54ff8612/OathAtmosphere/Home/OathReceiveSheet.swift)
- [Oath 5.0.2: asset details and activity](https://github.com/OathWallet/oath-wallet/blob/d039b009d8c81b0497f2ac7e6abebfdf54ff8612/OathAtmosphere/Assets/OathAssetDetailScreen.swift)
- [Oath 5.0.2: supported send flows](https://github.com/OathWallet/oath-wallet/blob/d039b009d8c81b0497f2ac7e6abebfdf54ff8612/OathAtmosphere/Send/OathSendModel.swift)

Guidance reviewed for Oath 5.0.2 (104); updated 2026-11-09. [How we review guides](https://oathwallet.org/about#editorial).
