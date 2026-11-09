# Bitcoin Cash wallet: send and receive BCH

Send and receive BCH on Bitcoin Cash with a dedicated network account.

## Receive Bitcoin Cash

1. Open Oath, select your wallet and choose Bitcoin Cash in Receive.
2. Copy the receiving address or show its QR code. Confirm the exact network with the sender.
3. Use the Bitcoin Cash address shown in Receive. Bitcoin Cash and Bitcoin are separate networks; do not send BTC to a BCH deposit.
4. After the sender broadcasts the transfer, follow its status in Oath. Network confirmation can take time.

## Send BCH

1. Open Send and select the asset on Bitcoin Cash. Paste the recipient’s address or scan their QR.
2. Review the BCH amount, destination and network fee. A familiar address format does not make a Bitcoin transfer compatible.
3. Enter the amount and any required memo or tag. Compare the complete destination with the recipient’s instructions.
4. Review the asset, network, amount and fee, then confirm in Oath. Follow the transaction status after broadcast.

## dApp connections

Bitcoin Cash send and receive support does not include a supported dApp connection route in this guide. Use Oath for transfers; do not import your recovery phrase into a website to connect.



## Questions

### How do I receive Bitcoin Cash in Oath?

Open Oath, select your wallet and choose Bitcoin Cash in Receive. Copy the receiving address or show its QR code. Confirm the exact network with the sender. Use the Bitcoin Cash address shown in Receive. Bitcoin Cash and Bitcoin are separate networks; do not send BTC to a BCH deposit.

### What pays the Bitcoin Cash transaction fee?

BCH is the native fee asset for this network account. Review the BCH amount, destination and network fee. A familiar address format does not make a Bitcoin transfer compatible.

### Can I connect Bitcoin Cash dApps?

Bitcoin Cash send and receive support does not include a supported dApp connection route in this guide. Use Oath for transfers; do not import your recovery phrase into a website to connect.

### Can I send to the same address on another network?

Only send using the network the recipient explicitly supports. A matching address or ticker does not bridge assets or make different chains interchangeable.

Features depend on the app version, network, wallet type and the service you connect to. Check the available actions in your installed app before transferring.

[Network catalog](https://github.com/OathWallet/oath-wallet/blob/6ff671b3e8f2ca8b8388ddebbf95f783a6ea0c7a/OathAtmosphere/Import/OathImportCatalog.swift) · Updated 2026-10-31. Source review is not confirmation of App Store availability.

[Get Oath for iPhone and iPad](https://apps.apple.com/app/id6780187283) · [All networks](https://oathwallet.org/networks)


## Receive Bitcoin Cash with BCH selected on both sides.

Open Oath, select your wallet and choose Bitcoin Cash in Receive. Share the receiving address or QR code from that screen. The sender must use Bitcoin Cash (BCH), not Bitcoin (BTC).

- **Asset:** BCH on Bitcoin Cash. BTC is a different asset on a different network.
- **Address:** Keep the Bitcoin Cash address format shown by Oath, including its bitcoincash: prefix when present.
- **Fee:** Oath’s ordinary BCH send uses BCH for the network fee; it does not require ETH or TRX.

### Example: a sender asks for a “Bitcoin” address

Confirm whether they mean BTC or BCH before copying anything. If the intended payment is BCH, both sides must select Bitcoin Cash. Similar names and legacy address formats are not a reason to skip the network check.

![Oath Bitcoin Cash asset screen with mock balance and sample sent and received activity](https://oathwallet.org/assets/guides/2026-11-09/bitcoin-cash.webp)

Oath 5.0.2 (104) · Mac simulator. Real app capture with mock balances, prices and transfer history. No live transfers were made. Always use your own receiving details; never send funds to an example address.

## An address format is not a bridge

CashAddr helps identify a Bitcoin Cash destination. Converting a textual address format does not move funds between Bitcoin and Bitcoin Cash. If a sending service rejects the address, consult that service’s BCH requirements rather than removing characters by guesswork.

## Check the payment before sending again

Ask for the public BCH transaction ID. Compare the destination, amount and confirmation status on a Bitcoin Cash explorer. If the expected transfer is confirmed, refresh the matching Oath wallet. Repeating a payment is not a repair for a display delay.

## Questions before you transfer

### Can I receive BCH without first buying another fee token?

An ordinary incoming BCH transfer does not require you to hold ETH, TRX or another network’s coin. The sender funds their transaction; your own later BCH send uses BCH for its network fee.

### Why is the incoming amount different from the exchange request?

The exchange may deduct a withdrawal fee or enforce a minimum. Check its final confirmation and the actual on-chain amount, rather than assuming the amount typed into the withdrawal form is what will arrive.

### What if BCH was sent on the wrong network?

Stop before another transfer. Identify the actual transaction and contact the receiving service about its recovery policy. Similar addresses do not guarantee recovery; never give support a recovery phrase or private key.

- [Compare the Bitcoin receiving flow](https://oathwallet.org/networks/bitcoin)
- [Open Receive in Oath](https://help.oathwallet.org/articles/receive-crypto)
- [Check the network fee asset](https://oathwallet.org/networks/fees)
- [Understand pending, confirmed and failed activity](https://help.oathwallet.org/articles/transaction-status)

### Sources and review

App steps checked against the linked release source; token identities and network requirements checked against the sources below. Screenshots show the actual app interface with mock data, not completed live transfers.

- [Bitcoin Cash: network information](https://bitcoincash.org/)
- [Bitcoin Cash: CashAddr specification](https://github.com/bitcoincashorg/bitcoincash.org/blob/master/spec/cashaddr.md)
- [Oath 5.0.2: Bitcoin Cash address handling](https://github.com/OathWallet/oath-wallet/blob/d039b009d8c81b0497f2ac7e6abebfdf54ff8612/Packages/OathBitcoin/Sources/OathBitcoin/CashAddress.swift)
- [Oath 5.0.2: receiving flow](https://github.com/OathWallet/oath-wallet/blob/d039b009d8c81b0497f2ac7e6abebfdf54ff8612/OathAtmosphere/Home/OathReceiveSheet.swift)
- [Oath 5.0.2: asset details and activity](https://github.com/OathWallet/oath-wallet/blob/d039b009d8c81b0497f2ac7e6abebfdf54ff8612/OathAtmosphere/Assets/OathAssetDetailScreen.swift)
- [Oath 5.0.2: supported send flows](https://github.com/OathWallet/oath-wallet/blob/d039b009d8c81b0497f2ac7e6abebfdf54ff8612/OathAtmosphere/Send/OathSendModel.swift)

Guidance reviewed for Oath 5.0.2 (104); updated 2026-11-09. [How we review guides](https://oathwallet.org/about#editorial).
