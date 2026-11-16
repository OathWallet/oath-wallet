// Match the catalog identity before attaching a project's claims to a wallet page.
const answers = new Map([
  ['a0x', {
    network: 'base',
    reference: '0x820c5f0fb255a1d18fd0ebb0f1ccefbc4d546da7',
    title: 'A0x Token on Base – Contract Address & Receiving Guide | Oath',
    description: 'A0x (A0X) is an ERC-20 token on Base. Check the contract from its Clanker launch, find your Base receiving address in Oath and see when you need ETH.',
    heading: 'What is the A0x token?',
    answer: 'A0x (A0X) is an ERC-20 token launched on Base for A0x.co, a platform for building AI agents. The original Clanker launch record identifies it by the Base contract below.',
    receiving: 'To receive A0X, select Base in Oath and give the sender your own Base receiving address. If you later send A0X, the network fee is paid in ETH on Base.',
    sources: [{label: 'A0x launch record on Clanker', url: 'https://www.clanker.world/clanker/0x820C5F0fB255a1D18fd0eBB0F1CCefbC4D546dA7'}],
    updated: '2026-11-16'
  }],
  ['aussie-dollar-token', {
    network: 'ethereum',
    reference: '0xd687759f35bb747a29246a4b9495c8f52c49e00c',
    title: 'Aussie Dollar Token (AUDX) on Ethereum – Issuer & Contract | Oath',
    description: 'TAU Pty Ltd issues Aussie Dollar Token (AUDX). Check its Ethereum contract and find the address to share when you receive AUDX in Oath.',
    heading: 'Who issues AUDX on Ethereum?',
    answer: 'TAU Pty Ltd issues Aussie Dollar Token (AUDX), a stablecoin designed to track one Australian dollar. Its September 2026 assurance report lists the Ethereum mainnet contract below. The contract identifies itself as Aussie Dollar Token, with the symbol AUDX and 18 decimals.',
    receiving: 'To receive AUDX in Oath, select the Ethereum result in Receive and share your wallet address with the sender. The contract identifies the asset. Your wallet address is the destination.',
    receiveSteps: [
      'Open the wallet you want to fund, tap Receive and search for AUDX. Select Aussie Dollar Token on Ethereum.',
      'Tap Copy address or show the QR code. Ask the sender to choose Ethereum mainnet and match the full AUDX contract above.',
      'Compare the destination with your Oath address before the sender confirms. The same contract address appears on several networks, so check the network name as well. Keep ETH on Ethereum for the fee if you send AUDX later.'
    ],
    sources: [
      {label: 'AUDX issuer disclosure', url: 'https://www.audxtoken.com/product-disclosure-statement'},
      {label: 'Ethereum contract in the September assurance report (PDF)', url: 'https://www.audxtoken.com/_files/ugd/539754_db5ac3cd8ef94f5f923513d5708af3b3.pdf'},
      {label: 'View AUDX on Etherscan', url: 'https://etherscan.io/token/0xD687759f35bb747A29246a4b9495C8f52C49E00C'}
    ],
    updated: '2026-11-16'
  }],
  ['blackjack-fun', {
    network: 'ethereum',
    reference: '0xf434908dcf8206691bb99cae9232d4833ec257d4',
    title: 'How to Receive Blackjack.fun (JACK) on Ethereum | Oath',
    description: 'Find Blackjack.fun (JACK) in Oath on iPhone, check its Ethereum contract and copy your personal receiving address. See how to confirm a JACK transfer on Etherscan.',
    heading: 'How do I receive Blackjack.fun (JACK) in Oath?',
    answer: 'In Oath on iPhone, select the wallet you want to fund, tap Receive and search for JACK. Choose Blackjack.fun on Ethereum. Tap Copy address or show the QR code, then ask the sender to send JACK to that address on Ethereum mainnet.',
    receiving: 'Oath lists this token as Blackjack.fun. Its Ethereum contract reports the name Blackjack.fun Coin, symbol JACK and 18 decimals. Use the contract above to identify the token and your personal Oath address as the destination.',
    receiveSteps: [
      'If several JACK results appear, paste the full token contract into the Receive search field and select the Ethereum result.',
      'In the sending wallet, match the JACK contract, select Ethereum mainnet and paste or scan your Oath address. Compare the full recipient address and amount before confirming.',
      'After broadcast, open the transaction hash on Etherscan. Check its status and the JACK token transfer for your address and amount. The sender pays gas for an ordinary transfer. Keep ETH on Ethereum if you send JACK later.'
    ],
    sources: [
      {label: 'Blackjack.fun Coin (JACK) on Etherscan', url: 'https://etherscan.io/token/0xf434908dCf8206691bb99cae9232d4833ec257D4'},
      {label: 'Oath’s released Receive screen', url: 'https://github.com/OathWallet/oath-wallet/blob/d039b009d8c81b0497f2ac7e6abebfdf54ff8612/OathAtmosphere/Home/OathReceiveSheet.swift'}
    ],
    updated: '2026-11-16'
  }],
  ['pump-fun', {
    network: 'solana',
    reference: 'pumpCmXqMfrsAkQ5r49WcJnRayYRqmXz6ae8H7H9Dfn',
    title: 'How to Receive Pump.fun (PUMP) on Solana | Oath',
    description: 'Receive PUMP in Oath on iPhone. Find the Pump.fun token on Solana, check its official mint and copy the wallet address to give the sender.',
    heading: 'How do I receive PUMP in Oath?',
    answer: 'Open the wallet you want to fund on your iPhone, tap Receive and search for PUMP. Choose Pump.fun (PUMP) on Solana, then tap Copy address or show the QR code. Give that wallet address to the sender and ask them to send PUMP over Solana.',
    receiving: 'The mint above identifies the official Pump.fun token. Use it to check the asset in the sending app. Only the personal address shown in Oath belongs in the recipient field.',
    receiveSteps: [
      'In Oath, select the wallet that should receive the tokens. Open Receive and choose the Solana result for PUMP.',
      'In the sending wallet or exchange, select PUMP, match the mint above and choose Solana. Paste the receiving address copied from Oath and compare the full destination before confirming.',
      'After broadcast, use the transaction signature to check the transfer on Solana. If the sender has no signature yet, check the withdrawal status with the sending service before trying again. Keep SOL for fees when you later send PUMP from Oath.'
    ],
    sources: [
      {label: 'PUMP mint on Pump.fun', url: 'https://pump.fun/coin/pumpCmXqMfrsAkQ5r49WcJnRayYRqmXz6ae8H7H9Dfn'},
      {label: 'Oath’s released Receive screen', url: 'https://github.com/OathWallet/oath-wallet/blob/d039b009d8c81b0497f2ac7e6abebfdf54ff8612/OathAtmosphere/Home/OathReceiveSheet.swift'}
    ],
    updated: '2026-11-16'
  }],
  ['uniswap', {
    network: 'unichain',
    reference: '0x8f187aa05619a017077f5308904739877ce9ea21',
    title: 'How to Receive Uniswap (UNI) on Unichain | Oath',
    description: 'Receive UNI on Unichain in Oath on iPhone. Find your personal receiving address, match the Unichain mainnet contract and check which network the sender uses.',
    heading: 'How do I receive UNI on Unichain in Oath?',
    answer: 'Open the wallet you want to fund in Oath on iPhone. Tap Receive, search for UNI and choose Uniswap (UNI) on Unichain. Tap Copy address or show the QR code. Give the sender that wallet address and ask them to select Unichain mainnet.',
    receiving: 'Uniswap publishes the contract above for UNI on Unichain (chain ID 130). UNI also exists on Ethereum and other networks. Sending UNI on Ethereum mainnet delivers it there, even if the same wallet address appears on both networks.',
    receiveSteps: [
      'Check that the sending wallet holds UNI on Unichain, or that the exchange offers UNI withdrawals on Unichain. If the service only offers Ethereum, it cannot make this Unichain withdrawal.',
      'Match the UNI contract above in the sending app. Paste your personal address from Oath into the recipient field and compare it with the address on your iPhone.',
      'Once the sender has a transaction hash, look it up on the Unichain explorer and check the UNI transfer to your address. Ordinary transfers use ETH on Unichain for gas. The sender pays that fee when you receive.'
    ],
    sources: [
      {label: 'Uniswap’s official Unichain token contracts', url: 'https://developers.uniswap.org/docs/unichain/technical-information/contract-addresses'},
      {label: 'Unichain mainnet settings and fee currency', url: 'https://developers.uniswap.org/docs/unichain/technical-information/network-information'},
      {label: 'UNI on the Unichain explorer', url: 'https://unichain.blockscout.com/token/0x8f187aA05619a017077f5308904739877ce9eA21'}
    ],
    updated: '2026-11-16'
  }],
  ['wagmi-2', {
    network: 'base',
    reference: '0xaf20f5f19698f1d19351028cd7103b63d30de7d7',
    title: 'Wagmi Protocol on Base – WAGMI Token Contract | Oath',
    description: 'Identify the Wagmi protocol token on Base by its contract. Compare it with WAGMI by Virtuals and find the address to share when receiving Wagmi in Oath.',
    heading: 'Which WAGMI on Base is the Wagmi protocol token?',
    answer: 'The Wagmi protocol lists the Base contract below for its token. On Base mainnet it reports the name Wagmi, symbol WAGMI and 18 decimals.',
    receiving: 'WAGMI by Virtuals uses the same ticker on Base. Its separate contract is 0x2Ce1340F1d402aE75aFEb55003d7491645dB1857. Match the full contract for the token the sender holds before choosing a search result.',
    receiveSteps: [
      'In Oath, open the wallet you want to fund and tap Receive. Paste the full Wagmi protocol contract (ending in DE7d7) into search and select its Base result.',
      'Tap Copy address or show your QR code. Give the sender your personal Base address and confirm they selected the same WAGMI contract on Base mainnet.',
      'The sender pays the network fee on an ordinary transfer. Keep ETH on Base for fees if you send the tokens later.'
    ],
    sources: [
      {label: 'Wagmi’s published Base token entry', url: 'https://github.com/RealWagmi/tokenlists/blob/4f1ada470c991302bfc3659cb276cad20c5d489b/tokenlist.json#L1100-L1108'},
      {label: 'View the Wagmi contract on BaseScan', url: 'https://basescan.org/address/0xaf20f5f19698f1D19351028cd7103B63D30DE7d7'},
      {label: 'Compare WAGMI by Virtuals on Base', url: 'https://oathwallet.org/tokens/wagmi-5/base'}
    ],
    updated: '2026-11-16'
  }],
  ['wagmi-5', {
    network: 'base',
    reference: '0x2ce1340f1d402ae75afeb55003d7491645db1857',
    title: 'WAGMI by Virtuals on Base – Token Contract & How to Receive | Oath',
    description: 'Find the Base contract for WAGMI by Virtuals, listed as WAGMI in Oath. Match the token before you receive it and check which address to share with the sender.',
    heading: 'Which WAGMI token is this?',
    answer: 'This is WAGMI by Virtuals, an ERC-20 token on Base. Its contract reports the symbol WAGMI and 18 decimals. Oath lists it as WAGMI. Match the full Base contract below to distinguish it from other tokens with the same ticker.',
    receiving: 'To receive WAGMI, open Receive in Oath, choose Base and share your personal Base address with the sender. The contract above identifies the token. Keep ETH on Base for the fee if you send WAGMI later.',
    sources: [{label: 'View the WAGMI contract on BaseScan', url: 'https://basescan.org/token/0x2Ce1340F1d402aE75aFEb55003d7491645dB1857'}],
    updated: '2026-11-16'
  }],
  ['tetsuo-coin', {
    network: 'solana',
    reference: '8i51XNNpGaKaj4G4nDdmQh95v4FKAxw8mhtaRoKd9tE8',
    title: 'Tetsuo Coin (TETSUO) on Solana – Token Mint & Receiving Guide | Oath',
    description: 'Identify Tetsuo Coin (TETSUO) by its Solana mint, check it against the project’s published address and find the wallet address to share when receiving it.',
    heading: 'Which Solana token is Tetsuo Coin?',
    answer: 'Tetsuo Coin (TETSUO) is the Solana SPL token listed by the developer of Tetsuo Dox Agent. The project publishes the mint below so you can distinguish it from tokens with similar names.',
    receiving: 'To receive TETSUO, choose Solana in Oath and share the receiving address shown for your wallet. The mint identifies the token. An ordinary outgoing transfer uses SOL for the network fee.',
    sources: [{label: 'TETSUO mint in the developer’s README', url: 'https://github.com/7etsuo/tetsuo-dox-agent/blob/c999a04cc5d25389ba68c4f67fbe5d13f34f38ab/README.md'}],
    updated: '2026-11-16'
  }]
]);

export function tokenAnswer(asset) {
  const answer = answers.get(asset?.coinID);
  if (answer && asset.network === answer.network && asset.reference === answer.reference) return answer;
}
