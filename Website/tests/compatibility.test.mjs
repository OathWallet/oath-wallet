import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {runInNewContext} from 'node:vm';
import worker from '../src/index.js';
import {documents} from '../src/agent-content.js';
import catalog from '../content/compatibility/catalog.json' with {type:'json'};
import edition from '../content/compatibility/2026-11-09.json' with {type:'json'};
import {validateEdition,matrixCSV} from '../compatibility/validate.mjs';
const root=new URL('../public/',import.meta.url),origin='https://oathwallet.org';
const read=path=>readFile(new URL('.'+path,root),'utf8');
const env={ASSETS:{async fetch(req){try{const p=new URL(req.url).pathname;const body=await read(p);return new Response(req.method==='HEAD'?null:body,{headers:{'Content-Type':p.endsWith('.html')?'text/html':'text/plain'}});}catch{return new Response(null,{status:404});}}}};
const get=(path,options)=>worker.fetch(new Request(origin+path,options),env);
test('accepted compatibility edition retains exact released sources and truthful execution layers',()=>{
 validateEdition(edition);
 for(const source of edition.evidence.sources){const data=execFileSync('git',['show',edition.evidence.versions.sourceCommit+':'+source.path],{cwd:new URL('../../',import.meta.url)});assert.equal(createHash('sha256').update(data).digest('hex'),source.sha256,source.path);}
 assert.equal(edition.evidence.oathCore.passed,14);assert.equal(edition.evidence.oathCore.skipped,1);
 assert.equal(edition.evidence.referenceLibrary.checks.filter(c=>c.kind==='library-vector').length,14);
 assert.equal(edition.rows.length,12);assert.equal(edition.bitcoin.length,4);
});
test('publication rejects unsupported claims, skipped evidence and accidental secret fields',()=>{
 const broken=fn=>{const d=structuredClone(edition);fn(d);assert.throws(()=>validateEdition(d));};
 broken(d=>d.rows[0].checks.push('missing-test'));
 broken(d=>d.rows[0].checks.push('ElectrumMnemonicTests.testCoreFundedRecoveryAndTransfersForEverySeedType'));
 broken(d=>d.evidence.referenceLibrary.checks[6].status='failed');
 broken(d=>d.evidence.oathCore.failed=1);broken(d=>d.evidence.oathCore.passed=99);
 broken(d=>d.thirdPartyApps[0].testedVersion='1.0');broken(d=>d.privateKey='sensitive-input');
 broken(d=>d.rows[0].evidenceLevel='core');broken(d=>d.rows[0].id=d.rows[1].id);
});
test('lab routes expose canonical HTML and Markdown without recovery collection',async()=>{
 const sitemap=await read('/sitemaps/pages.xml');
 for(const page of catalog.pages){
  const r=await get(page.path),html=await r.text();assert.equal(r.status,200,page.path);
  assert.ok(html.includes(`<link rel="canonical" href="${origin+page.path}">`));
  assert.doesNotMatch(html,/<(?:input|textarea|iframe)\b/i);
  assert.ok(html.includes('never asks for a recovery phrase or private key'));
  assert.doesNotMatch(r.headers.get('X-Robots-Tag')||'',/noindex|none/i);
  assert.ok(sitemap.includes('<loc>'+origin+page.path+'</loc>'));
  assert.ok(documents.some(d=>d.url===origin+page.path));
  const md=await get(page.path+'.md');assert.equal(md.status,200);const text=await md.text();
  assert.match(text,/Canonical: https:\/\/oathwallet.org\/compatibility/);
  assert.doesNotMatch(text,/<select|<table|<script|abandon abandon/);
  for(const suffix of ['/', '.html']){const alias=await get(page.path+suffix);assert.equal(alias.status,308);assert.equal(alias.headers.get('Location'),origin+page.path);}
 }
 const html=await(await get('/compatibility')).text();assert.equal((html.match(/data-lab-row/g)||[]).length,12);
 for(const row of edition.rows)assert.ok(html.includes(row.id));
 assert.equal((await get('/compatibility/2099-01-01')).status,404);
});
test('data exports preserve evidence, canonical headers and method boundaries',async()=>{
 for(const ext of ['json','csv']){
  const path='/compatibility/'+edition.edition+'.'+ext,response=await get(path);
  assert.equal(response.status,200);assert.match(response.headers.get('Link'),/2026-11-09>; rel="canonical"/);
  assert.equal(response.headers.get('X-Content-Type-Options'),'nosniff');
  assert.match(response.headers.get('Content-Type'),ext==='json'?/application\/json/:/text\/csv/);
  if(ext==='json')assert.deepEqual(await response.json(),edition);else assert.equal(await response.text(),matrixCSV(edition));
  const head=await get(path,{method:'HEAD'});assert.equal(head.status,200);assert.equal(await head.text(),'');
  assert.equal((await get(path,{method:'POST',body:'not accepted'})).status,405);
  assert.equal((await get('/compatibility/2099-01-01.'+ext)).status,404);
 }
 const d=structuredClone(edition);d.rows[0].result='=1+1';assert.ok(matrixCSV(d).includes('"\'=1+1"'));
 const unavailable=await worker.fetch(new Request(origin+'/compatibility/2026-11-09.json'),{ASSETS:{fetch:async()=>new Response(null,{status:503})}});assert.equal(unavailable.status,503);
});
test('filters intersect, announce empty results and reset without secret input',async()=>{
 const event=o=>Object.assign(o,{events:{},addEventListener(n,fn){this.events[n]=fn;}});
 const wallet=event({value:''}),evidence=event({value:''}),reset=event({}),count={},empty={hidden:true};
 const controls={hidden:true,querySelector:()=>reset};
 const rows=edition.rows.map(r=>({hidden:false,dataset:{wallet:r.wallet,evidence:r.evidenceLevel}}));
 const document={getElementById:id=>id==='lab-wallet'?wallet:evidence,querySelector:q=>({'[data-lab-controls]':controls,'[data-lab-count]':count,'[data-lab-empty]':empty}[q]),querySelectorAll:()=>rows};
 runInNewContext(await read('/compatibility-lab.js'),{document});
 assert.equal(controls.hidden,false);assert.equal(rows.filter(r=>!r.hidden).length,12);
 wallet.value='Trust Wallet';wallet.events.change();assert.equal(rows.filter(r=>!r.hidden).length,4);
 evidence.value='core';evidence.events.change();assert.equal(rows.filter(r=>!r.hidden).length,1);
 wallet.value='MetaMask';wallet.events.change();assert.equal(empty.hidden,false);assert.match(count.textContent,/0 of 12/);
 reset.events.click();assert.equal(rows.filter(r=>!r.hidden).length,12);assert.equal(empty.hidden,true);
});
