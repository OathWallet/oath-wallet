import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import reviews from '../content/reviewed-xstocks.json' with {type:'json'};
import captures from '../content/captures/priority-2026-11-10.json' with {type:'json'};
import networks from '../content/networks.json' with {type:'json'};
import {guidePreview} from '../src/xstock-guides.js';
import {stripCloudflareLabyrinth} from './cloudflare-html.mjs';

const origin='https://oathwallet.org';
const networkSlugs=new Map(networks.networks.map(n=>[n.id,n.slug]));
async function fetchOK(url){
  const response=await fetch(url,{redirect:'manual',signal:AbortSignal.timeout(20000)});
  assert.equal(response.status,200,url);
  return response;
}
const checked=[];
async function page(url,group,terms){
  const response=await fetchOK(url);
  const html=stripCloudflareLabyrinth(await response.text(),new URL(url).origin);
  assert.ok(html.includes(`rel="canonical" href="${url}"`),url+' canonical');
  assert.doesNotMatch(response.headers.get('x-robots-tag')||'',/noindex|none/i);
  assert.doesNotMatch(html,/<meta[^>]+name="robots"[^>]+content="[^"]*(noindex|none)/i);
  for(const term of [...terms,'pt=128883369&amp;ct=oath-web-'+group])assert.ok(html.includes(term),url+' missing '+term);
  checked.push(url);
  return html;
}
export async function verifySearchRelease(){
  for(const [coinID,guide] of Object.entries(reviews.assets)){
    const path='/tokens/'+coinID;
    const terms=[guide.isin,guide.source,guidePreview(path)];
    await page(origin+path,'tokens',terms);
    await Promise.all(Object.entries(guide.networks).map(([net,identity])=>
      page(origin+path+'/'+networkSlugs.get(net),'tokens',[...terms,identity.reference,'Compare '+guide.symbol+' across Oath networks','match the issuer’s deployment record'])));
  }
  for(const [slug,terms] of [['sui',['How to receive SUI on iPhone',captures.images[0].path]],['tron',['withdraw-usdt-binance-to-oath-tron',captures.images[1].path]],['bitcoin-cash',['Receive Bitcoin Cash']]]){
    const path='/networks/'+slug;await page(origin+path,'networks',[...terms,guidePreview(path)]);
  }
  const edition='/compatibility/2026-11-09';
  const html=await page(origin+edition,'guides',['Cite this edition','"Dataset"','"DataDownload"']);
  const graph=[...html.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)].flatMap(m=>JSON.parse(m[1])['@graph']||[]);
  for(const distribution of graph.find(n=>n['@type']==='Dataset').distribution){
    const response=await fetchOK(distribution.contentUrl);
    const expected=await readFile(new URL('../public'+new URL(distribution.contentUrl).pathname,import.meta.url));
    assert.deepEqual(Buffer.from(await response.arrayBuffer()),expected,distribution.contentUrl);
    checked.push(distribution.contentUrl);
  }
  for(const [slug,id] of [['move-from-trust-wallet-to-oath','trust-evm'],['use-metamask-wallet-in-oath','metamask-later'],['restore-electrum-bitcoin-wallet-on-iphone','electrum-segwit']]){
    await page('https://articles.oathwallet.org/'+slug,'guides',[edition+'#'+id]);
  }
  for(const image of captures.images){
    const response=await fetchOK(origin+image.path);
    assert.equal(createHash('sha256').update(Buffer.from(await response.arrayBuffer())).digest('hex'),image.sha256);
    checked.push(origin+image.path);
  }
  for(const path of new Set([...Object.keys(reviews.assets).map(slug=>guidePreview('/tokens/'+slug)),...['sui','tron','bitcoin-cash'].map(slug=>guidePreview('/networks/'+slug))])){
    const response=await fetchOK(origin+path);
    assert.match(response.headers.get('content-type')||'',/image\/png/);
    assert.ok((await response.arrayBuffer()).byteLength>1000);
    checked.push(origin+path);
  }
  console.log('Verified search release URLs\n'+checked.sort().join('\n'));
}
