import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile} from 'node:fs/promises';
import {chromium} from 'playwright';
import worker from '../src/index.js';

const main = 'https://oathwallet.org';
const help = 'https://help.oathwallet.org';
const files = new URL('../public/', import.meta.url);
const types = {html:'text/html', css:'text/css', js:'application/javascript', json:'application/json',
  woff2:'font/woff2', webp:'image/webp', svg:'image/svg+xml', png:'image/png'};
const assets = {async fetch(request) {
  const pathname = new URL(request.url).pathname;
  try {
    const file = await readFile(new URL('.' + pathname, files));
    return new Response(file, {headers:{'Content-Type':types[pathname.split('.').pop()] || 'application/octet-stream'}});
  } catch {
    return new Response(null, {status:404});
  }
}};

async function rect(page, selector) {
  const bounds = await page.locator(selector).boundingBox();
  assert.ok(bounds, selector);
  return bounds;
}

test('eligibility, related guides, filter feedback and walkthroughs keep related content together', async () => {
  const browser = await chromium.launch({channel:'chrome'});
  try {
    for (const color of ['light', 'dark']) {
      const context = await browser.newContext({colorScheme:color, reducedMotion:'reduce'});
      await context.addInitScript(theme => localStorage.setItem('oath-theme', theme), color);
      if (process.env.OATH_GRID_TEST_LIVE !== '1') {
        await context.route('**/*', async route => {
          const request = route.request();
          if (![main, help].includes(new URL(request.url()).origin) || request.method() !== 'GET') {
            return route.fulfill({status:204});
          }
          const result = await worker.fetch(new Request(request.url(), {headers:request.headers()}), {ASSETS:assets});
          return route.fulfill({status:result.status, headers:Object.fromEntries(result.headers), body:Buffer.from(await result.arrayBuffer())});
        });
      }
      const page = await context.newPage();
      async function open(url) {
        const result = await page.goto(url, {waitUntil:'domcontentloaded'});
        assert.equal(result.status(), 200, url);
        await page.evaluate(() => document.fonts.ready);
        assert.equal(await page.locator('html').getAttribute('data-oath-theme'), color);
      }
      for (const width of [320, 768, 1440]) {
        await page.setViewportSize({width, height:900});
        await open(main + '/bug-bounty');
        await page.locator('.bounty-nav a[href="#eligibility"]').click();
        const intro = await rect(page, '.bounty-eligibility-intro');
        const list = await rect(page, '#eligibility ul');
        const bar = await rect(page, '.oath-site-header > header');
        assert.ok(bar.y + bar.height <= intro.y && intro.y >= 0 && intro.y < 180);
        assert.equal(await page.locator('#eligibility li').count(), 5);
        if (width > 760) assert.ok(list.x > intro.x + intro.width && Math.abs(intro.y - list.y) < 2);
        else assert.ok(list.y >= intro.y + intro.height + 20);

        await open(main + '/networks/choose-token-network?token=usdt&network=tron');
        const feedback = page.locator('.transfer-feedback');
        assert.match(await feedback.getByRole('status').innerText(), /1 exact token/);
        const fields = await rect(page, '.transfer-controls');
        const row = await rect(page, '.transfer-feedback');
        assert.ok(row.width > fields.width * 0.75);
        await feedback.getByRole('button', {name:'Clear selection'}).click();
        assert.match(await feedback.getByRole('status').innerText(), /Choose a token/);
        assert.equal(await page.locator('#transfer-token').inputValue(), '');

        await open(main + '/features/revoke-token-approvals');
        const first = await rect(page, '.feature-guides a:first-child');
        const last = await rect(page, '.feature-guides a:last-child');
        if (width >= 960) assert.ok(Math.abs(first.y - last.y) < 2);
        else if (width > 700) assert.ok(last.width > first.width * 1.9);
        else assert.ok(last.y >= first.y + first.height);

        for (const slug of ['create-wallet', 'permanently-delete-wallet']) {
          await open(help + '/articles/' + slug);
          const gallery = await rect(page, '.walkthrough-grid');
          const figure = await rect(page, '.walkthrough-grid figure:last-child');
          const image = await rect(page, '.walkthrough-grid figure:last-child .capture-link');
          const caption = await rect(page, '.walkthrough-grid figure:last-child figcaption');
          assert.ok(Math.abs(figure.width - gallery.width) < 2);
          if (gallery.width >= 560) assert.ok(caption.x >= image.x + image.width);
          else assert.ok(caption.y >= image.y + image.height - 1);
        }
      }
      await context.close();
    }
  } finally {
    await browser.close();
  }
});
