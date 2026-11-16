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
    sourceLabel: 'A0x launch record on Clanker',
    sourceURL: 'https://www.clanker.world/clanker/0x820C5F0fB255a1D18fd0eBB0F1CCefbC4D546dA7',
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
    sourceLabel: 'TETSUO mint in the developer’s README',
    sourceURL: 'https://github.com/7etsuo/tetsuo-dox-agent/blob/c999a04cc5d25389ba68c4f67fbe5d13f34f38ab/README.md',
    updated: '2026-11-16'
  }]
]);

export function tokenAnswer(asset) {
  const answer = answers.get(asset?.coinID);
  if (answer && asset.network === answer.network && asset.reference === answer.reference) return answer;
}
