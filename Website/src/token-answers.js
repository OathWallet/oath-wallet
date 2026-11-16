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
