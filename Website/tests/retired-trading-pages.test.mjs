import test from 'node:test';
import assert from 'node:assert/strict';
import {access, readFile} from 'node:fs/promises';
import worker from '../src/index.js';
import {handleRetiredTradingPages} from '../src/retired-trading-pages.js';

test('retired trading pages, assets and APIs cannot reach assets or external services', async () => {
  const env = new Proxy({}, {get() { throw new Error('Retired routes must not access services'); }});
  for (const host of ['oathwallet.org', 'www.oathwallet.org', 'articles.oathwallet.org', 'help.oathwallet.org', 'news.oathwallet.org', 'localhost']) {
    for (const path of ['/ousd', '/ousd/', '/ousd.html', '/ousd/index.html', '/ousd/app.js', '/ousd/style.css', '/ousd/config.json', '/ousd/token.json', '/ousd/api/rpc', '/ousd/api/route', '/ousd/api/reconcile', '/swap', '/swap/', '/swap.html', '/swap/index.html', '/swap/api/quote', '/swaps', '/OUSD']) {
      for (const method of ['GET', 'HEAD', 'POST']) {
        const response = await worker.fetch(new Request(`https://${host}${path}?legacy=1`, {method}), env);
        assert.equal(response.status, 410, `${method} ${host}${path}`);
        assert.equal(response.headers.get('Cache-Control'), 'no-store');
        assert.equal(response.headers.get('X-Robots-Tag'), null);
        assert.equal(await response.text(), method === 'HEAD' ? '' : 'This page is no longer available.');
      }
    }
  }
});

test('retirement is confined to the removed screens, not guides or asset catalog entries', () => {
  for (const path of ['/', '/networks/solana', '/help/walletconnect', '/articles/why-oath-has-no-swaps-perps-web3-walletconnect', '/tokens/ethereum/ousd', '/swap-guide', '/ousd-guide', '/theme.css']) {
    assert.equal(handleRetiredTradingPages(new Request('https://oathwallet.org'+path)), null, path);
  }
});

test('removed trading UI and proxy source are absent from the deployment', async () => {
  for (const path of ['public/ousd', 'src/ousd.js']) {
    await assert.rejects(access(new URL('../'+path, import.meta.url)), {code: 'ENOENT'});
  }
  for (const path of ['public/sitemap.xml', 'public/llms.txt', 'public/agent-documents.json']) {
    assert.doesNotMatch(await readFile(new URL('../'+path, import.meta.url), 'utf8'), /https:\/\/oathwallet\.org\/(?:ousd|swaps?)(?:[\/"<\s]|$)/);
  }
});
