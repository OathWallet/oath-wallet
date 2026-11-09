import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile, readdir} from 'node:fs/promises';
import worker from '../src/index.js';
import manifest from '../src/tokens-manifest.json' with {type:'json'};

const root = new URL('../', import.meta.url);
async function files(dir) {
  const entries = await readdir(dir, {withFileTypes:true});
  return (await Promise.all(entries.filter(e=>!e.name.startsWith('._')).map(e=>{
    const path = new URL(e.name + (e.isDirectory()?'/':''), dir);
    return e.isDirectory()?files(path):[path];
  }))).flat();
}
function assertAllowed(headers, body, label) {
  assert.doesNotMatch(headers.get('x-robots-tag')||'', /\b(?:noindex|none)\b/i, label);
  for (const tag of body.match(/<meta\b[^>]*>/gi)||[]) {
    if (/\bname\s*=\s*["'](?:robots|googlebot|bingbot)["']/i.test(tag))
      assert.doesNotMatch(tag, /\bcontent\s*=\s*["'][^"']*\b(?:noindex|none)\b/i, label);
  }
}

test('all generated HTML and deployment headers omit indexing exclusions', async()=>{
  for (const path of await files(new URL('public/',root))) {
    if (path.pathname.endsWith('.html')) assertAllowed(new Headers(),await readFile(path,'utf8'),path.pathname);
  }
  assert.doesNotMatch(await readFile(new URL('public/_headers',root),'utf8'),/X-Robots-Tag:[^\n]*\b(?:noindex|none)\b/i);
});

test('website generators and handlers cannot reintroduce noindex',async()=>{
  for(const dir of ['src/','scripts/']) for(const path of await files(new URL(dir,root))) {
    // Audit scripts and regression tests may name the forbidden directive.
    if(!/\.(?:js|mjs)$/.test(path.pathname) || (dir==='scripts/'&&!path.pathname.split('/').pop().startsWith('build-')))continue;
    assert.doesNotMatch(await readFile(path,'utf8'),/\bnoindex\b/i,path.pathname);
  }
});

const env={ASSETS:{async fetch(request){
  const path=new URL(request.url).pathname;
  try {return new Response(await readFile(new URL('public'+path,root)),{headers:{'Content-Type':path.endsWith('.html')?'text/html':path.endsWith('.json')?'application/json':'text/plain'}});}
  catch{return new Response('Missing',{status:404});}
}}};
test('GET and HEAD across website hosts omit exclusions and retain statuses',async()=>{
  const cases=[
    ['oathwallet.org','/',200],['oathwallet.org','/404.html',404],
    ['oathwallet.org','/tokens?q=USDC',200],['oathwallet.org','/tokens/usdc/base.md',200],
    ['oathwallet.org','/tokens/nonexistent-test-token',404],
    ['oathwallet.org','/tokens/documents.json',200],['oathwallet.org',manifest.prefix+'/manifest.json',200],
    ['oathwallet.org','/networks/choose-token-network?token=usdc&network=base',200],
    ['oathwallet.org','/networks/choose-token-network?token=missing&network=base',404],
    ['oathwallet.org','/features/walletconnect.md',200],['oathwallet.org','/wc',200],
    ['oathwallet.org','/news/admin.html',200],['oathwallet.org','/news/preferences.html',200],
    ['oathwallet.org','/assets/press/2026-10/brand-guide.txt',200],
    ['articles.oathwallet.org','/',200],['articles.oathwallet.org','/index.md',200],
    ['articles.oathwallet.org','/move-oath-to-new-iphone-direct-encrypted-serverless',410],
    ['help.oathwallet.org','/',200],['help.oathwallet.org','/search?q=backup',200],
    ['help.oathwallet.org','/missing-test-page',404],
  ];
  for(const host of ['oathwallet.org','help.oathwallet.org','articles.oathwallet.org']) {
    for(const path of ['/llms.txt','/release-status.json','/agent-documents.json','/.well-known/security.txt'])cases.push([host,path,200]);
  }
  for(const [host,path,status]of cases)for(const method of ['GET','HEAD']){
    const url='https://'+host+path,response=await worker.fetch(new Request(url,{method}),env),body=await response.text();
    assert.equal(response.status,status,url);assertAllowed(response.headers,body,url);
    if(method==='HEAD')assert.equal(body,'',url);
  }
});
