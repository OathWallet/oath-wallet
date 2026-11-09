import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import sharp from 'sharp';
import worker from '../src/index.js';
import guidance from '../content/priority-guidance.json' with {type:'json'};
import manifest from '../src/tokens-manifest.json' with {type:'json'};
import {priorityUpdated} from '../src/seo-guidance.js';
const origin='https://oathwallet.org',root=new URL('../public/',import.meta.url);
const paths=['/tokens/usdt','/tokens/usdc','/tokens/usdt/tron','/tokens/usdc/base','/tokens/usdc/solana','/tokens/usdc/ethereum','/networks/bitcoin','/networks/bitcoin-cash','/networks/ethereum','/networks/solana'];
const read=p=>readFile(new URL('.'+p,root));
const env={ASSETS:{async fetch(req){const p=new URL(req.url).pathname;try{return new Response(await read(p),{headers:{'Content-Type':p.endsWith('.html')?'text/html':p.endsWith('.json')?'application/json':'text/plain'}});}catch{return new Response('Missing',{status:404});}}}};
const get=p=>worker.fetch(new Request(origin+p),env);
const escape=s=>s.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;').replaceAll("'",'&#39;');
test('ten reviewed guides have visible unique answers, examples, sources and complete Markdown',async()=>{
 assert.deepEqual(Object.keys(guidance.pages).filter(p=>guidance.pages[p].overview).sort(),[...paths].sort());
 assert.equal(new Set(paths.map(p=>guidance.pages[p].overview.answer)).size,10);
 for(const path of paths){
  const page=guidance.pages[path];assert.equal(page.version,'5.0.2');assert.equal(page.build,104);
  assert.equal(page.sourceCommit,'d039b009d8c81b0497f2ac7e6abebfdf54ff8612');
  const r=await get(path);assert.equal(r.status,200,path);assert.equal(r.headers.get('X-Robots-Tag'),null);
  const html=await r.text(),md=await(await get(path+'.md')).text();
  assert.equal((html.match(/<h1\b/g)||[]).length,1,path);
  assert.equal((html.match(/id="priority-overview"/g)||[]).length,1,path);
  assert.ok(html.includes(`rel="canonical" href="${origin+path}"`),path);
  assert.ok(html.includes(`content="${escape(page.description)}"`),path+' description');
  const detailAnchor=path.startsWith('/networks/')?'id="receive"':path.split('/').length===4?'class="token-identity"':'<h2>Choose your network</h2>';
  assert.ok(html.indexOf('id="priority-overview"')<html.indexOf(detailAnchor),path+' useful answer precedes generic detail');
  const texts=[page.overview.title,page.overview.answer,page.overview.example.title,page.overview.example.text,...page.overview.facts.flatMap(f=>[f.label,f.text]),...page.sections.flatMap(s=>[s.title,s.text])];
  for(const text of texts){assert.ok(html.includes(escape(text)),path+' HTML: '+text);assert.ok(md.includes(text),path+' Markdown: '+text);}
  assert.ok(page.sources.length>=4);
  for(const s of page.sources){assert.ok(s.url.startsWith('https://'));assert.ok(html.includes(`href="${s.url}"`),s.url);assert.ok(md.includes(s.url));}
  const nodes=[...html.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)].flatMap(m=>{const data=JSON.parse(m[1]);return data['@graph']||[data];});
  const node=nodes.find(n=>n['@type']==='WebPage'&&n.url===origin+path);assert.equal(node.dateModified,page.updated,path);
 }
});
test('review dates are assigned only to the pages actually reviewed',async()=>{
 const xml=(await Promise.all(['/sitemaps/pages.xml',...Array.from({length:4},(_,i)=>'/sitemaps/tokens-000'+(i+1)+'.xml')].map(async p=>(await read(p)).toString()))).join('\n');
 for(const path of paths){const entries=[...xml.matchAll(/<url>([\s\S]*?)<\/url>/g)].filter(m=>m[1].includes(`<loc>${origin+path}</loc>`));assert.equal(entries.length,1,path);assert.ok(entries[0][1].includes(`<lastmod>${guidance.pages[path].updated}</lastmod>`),path);}
 assert.equal(priorityUpdated('/networks/tron'),'2026-11-06');assert.equal(priorityUpdated('/features/walletconnect'),'2026-11-06');assert.equal(priorityUpdated('/tokens/nonexistent'),undefined);
 assert.doesNotMatch(xml,/<loc>https:\/\/oathwallet.org\/tokens\/treehouse\/ethereum<\/loc><lastmod>2026-11-09<\/lastmod>/);
});
test('screenshots preserve genuine capture identity and expose sample-data captions',async()=>{
 const captures=JSON.parse(await readFile(new URL('../content/captures/priority-2026-11-09.json',import.meta.url),'utf8'));
 assert.equal(captures.sourceCommit,'d039b009d8c81b0497f2ac7e6abebfdf54ff8612');
 for(const path of paths){
  const page=guidance.pages[path],html=await(await get(path)).text();assert.ok(page.images?.length>=1,path);
  for(const img of page.images){
   const evidence=captures.images.find(c=>c.path===img.path);assert.ok(evidence,path);assert.equal(evidence.sha256,img.sha256);
   const bytes=await read(img.path);assert.equal(createHash('sha256').update(bytes).digest('hex'),img.sha256);
   const info=await sharp(bytes).metadata();assert.equal(info.width,img.width);assert.equal(info.height,img.height);
   assert.match(img.caption,/mock/i);assert.match(img.caption,/never send/i);assert.match(img.version,/5\.0\.2/);assert.ok(html.includes(`width="${img.width}" height="${img.height}"`));
   assert.ok(html.includes(escape(img.caption)));assert.ok(html.includes(escape(img.alt)));
  }
 }
});
test('priority stablecoin references match the accepted catalog snapshot',async()=>{
 const expected={'/tokens/usdt/tron':'TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t','/tokens/usdc/base':'0x833589fcd6edb6e08f4c7c32d4f71b54bda02913','/tokens/usdc/ethereum':'0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48','/tokens/usdc/solana':'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v'};
 for(const [path,reference]of Object.entries(expected)){
  const slug=path.split('/')[2],shard=createHash('sha256').update(slug).digest('hex').slice(0,2),coin=JSON.parse(await read(manifest.prefix+'/coins/'+shard+'.json'))[slug];
  assert.equal(coin.assets.find(a=>a.path===path).reference,reference);const html=await(await get(path)).text();assert.ok(html.includes(reference));assert.match(html,/token identifier is not your receiving address/);
 }
});
