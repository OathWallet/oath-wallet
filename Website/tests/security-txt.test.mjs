import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import worker from '../src/index.js';
import {handleSecurityTxt, renderSecurityTxt, securityHosts, securityTxtPath} from '../src/security-txt.js';

test('all configured website hosts have a security discovery route before HTML routing', async () => {
  const config = JSON.parse(await readFile(new URL('../wrangler.jsonc', import.meta.url), 'utf8'));
  assert.deepEqual([...securityHosts].sort(), config.routes.map(r => r.pattern).sort());
  for (const host of securityHosts.filter(h => !h.startsWith('www.'))) {
    const url = `https://${host}${securityTxtPath}`;
    // An empty environment catches accidental dependency on assets, credentials,
    // newsletter storage or live providers, especially on the subdomains.
    const response = await worker.fetch(new Request(url, {headers: {Accept: 'text/html, application/json'}}), {});
    assert.equal(response.status, 200, host);
    assert.equal(response.headers.get('Content-Type'), 'text/plain; charset=utf-8');
    assert.equal(response.headers.get('X-Content-Type-Options'), 'nosniff');
    assert.match(response.headers.get('Strict-Transport-Security'), /max-age=31536000/);
    assert.equal(response.headers.get('X-Robots-Tag'), null);
    assert.equal(response.headers.get('Link'), `<${url}>; rel="canonical"`);
    assert.match(response.headers.get('Cache-Control'), /max-age=3600.*must-revalidate/);
    assert.equal(response.headers.get('Set-Cookie'), null);
    const body = await response.text();
    assert.equal(body, renderSecurityTxt(host));
    assert.ok(body.endsWith('\n'));
    assert.equal(body.match(/^Canonical: /gm).length, 1);
    assert.ok(body.includes(`Canonical: ${url}\n`));
    assert.equal(body.match(/^Expires: /gm).length, 1);
    assert.match(body, /^Contact: https:\/\/github.com\/OathWallet\/oath-wallet\/security\/advisories\/new$/m);
    assert.match(body, /^Policy: https:\/\/oathwallet.org\/bug-bounty$/m);
    assert.doesNotMatch(body, /<html|<script|Encryption:|BEGIN PGP/);
    const head = await worker.fetch(new Request(url, {method: 'HEAD'}), {});
    assert.equal(head.status, 200);
    assert.equal(await head.text(), '');
    assert.deepEqual([...head.headers], [...response.headers]);
  }
});

test('legacy, HTTP and www security locations converge without forwarding queries', async () => {
  for (const host of securityHosts) for (const protocol of ['https:', 'http:']) {
    for (const path of ['/security.txt', securityTxtPath]) {
      if (protocol === 'https:' && path === securityTxtPath && !host.startsWith('www.')) continue;
      const response = await worker.fetch(new Request(`${protocol}//${host}${path}?redirect=https://example.com`), {});
      const canonicalHost = host.startsWith('www.') ? 'oathwallet.org' : host;
      assert.equal(response.status, 308);
      assert.equal(response.headers.get('Location'), `https://${canonicalHost}${securityTxtPath}`);
      assert.equal(await response.text(), '');
    }
  }
});

test('security.txt rejects writes and cannot claim unrelated hosts or routes', async () => {
  for (const host of securityHosts) for (const method of ['POST', 'PUT', 'DELETE', 'OPTIONS']) {
    const response = await worker.fetch(new Request(`https://${host}${securityTxtPath}`, {method}), {});
    assert.equal(response.status, 405);
    assert.equal(response.headers.get('Allow'), 'GET, HEAD');
    assert.equal(response.headers.get('Cache-Control'), 'no-store');
  }
  for (const url of ['https://example.com/.well-known/security.txt', 'https://oathwallet.org/security.txt/extra', 'https://oathwallet.org/security', 'https://help.oathwallet.org/articles/security']) {
    assert.equal(handleSecurityTxt(new Request(url)), null);
  }
  assert.throws(() => renderSecurityTxt('example.com'), /Unknown/);
});

test('static fallback matches the reviewed runtime contact document', async () => {
  assert.equal(await readFile(new URL('../public/.well-known/security.txt', import.meta.url), 'utf8'), renderSecurityTxt('oathwallet.org'));
});
