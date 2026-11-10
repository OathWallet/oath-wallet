import assert from 'node:assert/strict';
import test from 'node:test';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import {chromium} from 'playwright';

test('the standalone newsletter supports themes, topic selection, retries and accessible success', async () => {
  const server = createServer(async (req, res) => {
    const path = new URL(req.url, 'http://localhost').pathname;
    if (path === '/entry') {
      res.writeHead(200, {'Content-Type':'text/html'});
      res.end('<html><body><script src="/newsletter.js" defer></script></body></html>');
      return;
    }
    try {
      const body = await readFile(new URL('../public' + (path === '/' ? '/news/index.html' : path), import.meta.url));
      const types = {js:'application/javascript',css:'text/css',svg:'image/svg+xml',woff2:'font/woff2'};
      res.writeHead(200, {'Content-Type':types[path.split('.').at(-1)] || 'text/html'});
      res.end(body);
    } catch { res.writeHead(404); res.end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = 'http://127.0.0.1:' + server.address().port;
  const browser = await chromium.launch({channel:'chrome'});
  try {
    for (const width of [320, 390, 1280]) {
      const context = await browser.newContext({viewport:{width, height:844}});
      try {
        const page = await context.newPage(), sent = [];
        await page.route('**/_newsletter/signup', async route => {
          sent.push(route.request().postDataJSON());
          if (sent.length === 1) return route.fulfill({status:429, json:{error:'Try again in a minute.'}});
          return route.fulfill({json:{ok:true, subscribed:true, message:'You’re subscribed to Oath Notes. No email confirmation is needed — you’re all set.'}});
        });
        await page.goto(base+'/entry');
        assert.equal(await page.locator('.on-launcher').getAttribute('href'),'https://news.oathwallet.org/');
        assert.equal(await page.locator('dialog').count(),0);
        await page.goto(base);
        assert.equal(await page.locator('#notes-email').isVisible(), true);
        assert.equal(await page.getByRole('button',{name:'Join Oath Notes'}).isEnabled(), true);
        assert.equal(await page.locator('.on-launcher,dialog').count(),0);
        assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth <= innerWidth),true);
        await page.getByRole('button',{name:'Dark mode'}).click();
        assert.equal(await page.getByRole('button',{name:'Dark mode'}).getAttribute('aria-pressed'),'true');
        await page.reload();
        assert.equal(await page.locator('html').getAttribute('data-oath-theme'),'dark');
        await page.getByRole('button',{name:'Light mode'}).click();
        await page.locator('#notes-email').fill('bad');
        await page.locator('.notes-submit').click();
        assert.equal(await page.locator('#notes-email').evaluate(el=>el.validity.typeMismatch),true);
        await page.locator('#notes-email').fill('subscriber@example.invalid');
        await page.locator('summary').focus();
        await page.keyboard.press('Enter');
        for (const checkbox of await page.getByRole('checkbox').all()) await checkbox.uncheck();
        await page.locator('.notes-submit').click();
        assert.equal(await page.getByRole('status').textContent(),'Choose at least one topic.');
        assert.equal(sent.length,0);
        await page.getByLabel('Security brief').check();
        await page.getByLabel('Wallet guides').check();
        assert.equal(await page.locator('#notes-count').textContent(),'2 selected');
        await page.locator('.notes-submit').click();
        await page.getByText('Try again in a minute.').waitFor();
        assert.equal(await page.locator('#notes-email').inputValue(),'subscriber@example.invalid');
        await page.locator('.notes-submit').click();
        await page.getByRole('heading',{name:'You’re subscribed.'}).waitFor();
        assert.equal(await page.locator('#notes-success-title').evaluate(el=>el===document.activeElement),true);
        assert.equal(await page.locator('#notes-signup').isVisible(),false);
        assert.equal(await page.getByRole('link',{name:'Back to Oath'}).getAttribute('href'),'https://oathwallet.org/');
        assert.deepEqual(sent,[0,1].map(()=>({email:'subscriber@example.invalid',topics:['security','guides'],consent:true,website:'',source:'/newsletter'})));
      } finally { await context.close(); }
    }
  } finally { await browser.close(); await new Promise(resolve=>server.close(resolve)); }
});
