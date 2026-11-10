import review from '../content/reviewed-xstocks.json' with {type:'json'};

export const reviewedAssets = review.assets;

export function checkedIdentity(guide, entry) {
  const checked = guide.networks[entry.network];
  return checked?.reference === entry.reference ? checked : null;
}

export function reviewedAssetForPath(path) {
  const [root, slug] = path.split('/').slice(1);
  return root === 'tokens' && Object.hasOwn(review.assets, slug) ? review.assets[slug] : undefined;
}

export function xstockReviewDate(path) {
  return reviewedAssetForPath(path) ? review.reviewed : undefined;
}

export function guidePreview(path) {
  if (['/networks/sui', '/networks/tron', '/networks/bitcoin-cash'].includes(path)) return '/og/guide-' + path.split('/')[2] + '.png';
  const guide = reviewedAssetForPath(path);
  return guide ? '/og/guide-' + guide.symbol.toLowerCase() + '.png' : undefined;
}

export function productIdentity(coin, asset, escape) {
  const guide = review.assets[coin.coinID];
  if (!guide) return '';
  const h = escape;
  const checked = asset && checkedIdentity(guide, asset);
  const overview = '/tokens/' + coin.slug;
  const underlying = guide.symbol === 'SNXXx' ? 'the SNXX leveraged ETF' : 'the underlying stock';
  const terms = guide.symbol === 'TXNx' ? 'https://assets.backed.fi/products/texas-instruments-xstock' : review.productSource;
  const scope = asset ? (checked
    ? 'The network and token identifier in this catalog entry match the issuer’s deployment record.' + (checked.issuerFormat ? ' The catalog displays the raw TON workchain and account ID. The issuer uses its checksummed, user-friendly representation.' : '')
    : 'Catalog record only. The current identifier has no exact match in our dated issuer check. Confirm the deployment directly with the issuer before using any receiving instructions.') :
    'Choose the network used by the sending service. The same EVM address can appear on multiple chains, so compare the network as well as the identifier.';
  return `<section class="token-identity"><h2>Identify ${h(guide.symbol)} before a transfer</h2><p>${h(guide.name)} is a tracker certificate issued by ${h(review.issuer)}. ${h(guide.underlying)} identifies ${underlying}. ${h(guide.symbol)} identifies the on-chain product, with ISIN <strong>${h(guide.isin)}</strong>.</p><p>${h(guide.identityNote)}</p><p>${h(scope)}</p><p>Issuer eligibility and distribution restrictions apply. A wallet listing does not establish eligibility to buy or redeem the certificate. <a href="${h(terms)}">Issuer product information and restrictions</a>.</p><p>Identity checked <time datetime="${review.reviewed}">${review.reviewed}</time> against the <a href="${h(guide.source)}">${h(guide.symbol)} issuer deployment record</a>.${asset ? ` <a href="${h(overview)}">Compare ${h(guide.symbol)} across Oath networks</a>.` : ''}</p></section>`;
}
