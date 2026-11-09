import assert from 'node:assert/strict';

// Check every handler family that previously emitted an indexing exclusion.
export async function verifyIndexingPolicy() {
  const cases = [
    ['oathwallet.org', '/', 200],
    ['oathwallet.org', '/404.html', 404],
    ['oathwallet.org', '/tokens?q=USDC', 200],
    ['oathwallet.org', '/tokens/usdc/base.md', 200],
    ['oathwallet.org', '/tokens/documents.json', 200],
    ['oathwallet.org', '/tokens/nonexistent-test-token', 404],
    ['oathwallet.org', '/networks/choose-token-network?token=usdc&network=base', 200],
    ['oathwallet.org', '/features/walletconnect.md', 200],
    ['oathwallet.org', '/assets/press/2026-10/brand-guide.txt', 200],
    ['oathwallet.org', '/wc', 200],
    ['help.oathwallet.org', '/search?q=backup', 200],
    ['help.oathwallet.org', '/missing-test-page', 404],
    ['articles.oathwallet.org', '/', 200],
    ['articles.oathwallet.org', '/move-oath-to-new-iphone-direct-encrypted-serverless', 410],
    ['news.oathwallet.org', '/', 200],
    ['news.oathwallet.org', '/admin', 200],
    ['news.oathwallet.org', '/preferences', 200],
  ];
  for (const host of ['oathwallet.org', 'help.oathwallet.org', 'articles.oathwallet.org']) {
    for (const path of ['/llms.txt', '/release-status.json', '/agent-documents.json', '/.well-known/security.txt']) {
      cases.push([host, path, 200]);
    }
  }
  for (const [host, path, status] of cases) {
    const url = `https://${host}${path}`;
    const response = await fetch(url, {signal: AbortSignal.timeout(20000)});
    assert.equal(response.status, status, url);
    assert.doesNotMatch(response.headers.get('x-robots-tag') || '', /\b(?:noindex|none)\b/i, url);
    if (response.headers.get('content-type')?.includes('text/html')) {
      for (const tag of (await response.text()).match(/<meta\b[^>]*>/gi) || []) {
        if (/\bname\s*=\s*["'](?:robots|googlebot|bingbot)["']/i.test(tag)) {
          assert.doesNotMatch(tag, /\bcontent\s*=\s*["'][^"']*\b(?:noindex|none)\b/i, url);
        }
      }
    } else await response.arrayBuffer();
  }
  console.log(`Verified no indexing-exclusion headers or meta tags on ${cases.length} production routes across four hosts.`);
}
