// URLs generated in App Store Connect. Each label measures a page group.
const campaignBase = 'https://apps.apple.com/app/apple-store/id6780187283?pt=128883369&ct=oath-web-';
const downloadPaths = new Set(['/app/id6780187283','/us/app/oath-bitcoin-crypto-wallet/id6780187283']);
export function storeCampaign(requestURL) {
  const {hostname, pathname} = new URL(requestURL);
  if (hostname === 'oathwallet.org') {
    if (/^\/tokens(?:\/|$)/.test(pathname) || /^\/networks\/[^/]+\/tokens$/.test(pathname)) return 'tokens';
    if (/^\/networks(?:\/|$)/.test(pathname)) return 'networks';
    if (/^\/compatibility(?:\/|$)/.test(pathname)) return 'guides';
  }
  if (hostname === 'articles.oathwallet.org' || (hostname === 'help.oathwallet.org' && pathname.startsWith('/articles/'))) return 'guides';
  return null;
}
export function campaignAnchors(html, group) {
  if (!group) return html;
  const destination = campaignBase + group + '&mt=8';
  // Rewrite only Oath's unparameterized download links. Retain previews, reviews and existing attribution.
  return html.replace(/(<a\b[^<>]*?\shref\s*=\s*)(["'])(https:\/\/apps\.apple\.com\/[^"'<>]+)\2/gi, (whole, prefix, quote, href) => {
    const url = new URL(href);
    return downloadPaths.has(url.pathname) && !url.search && !url.hash
      ? prefix + quote + destination.replaceAll('&','&amp;') + quote : whole;
  });
}
