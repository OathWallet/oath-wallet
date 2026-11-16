import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,readdir} from 'node:fs/promises';
import {tokenAnswer} from '../src/token-answers.js';
import {tokenLabel,tokenPageTitle} from '../src/token-titles.js';
import {qualifyTokenTitles,qualifyOverviewTitles} from '../scripts/token-titles.mjs';
import manifest from '../src/tokens-manifest.json' with {type:'json'};
import {escapeHTML} from '../src/tokens.js';
import worker from '../src/index.js';

const root=new URL('../public/',import.meta.url),origin='https://oathwallet.org';
const read=path=>readFile(new URL('.'+path,root),'utf8');
const coins=[];
for(const file of await readdir(new URL('.'+manifest.prefix+'/coins/',root)))coins.push(...Object.values(JSON.parse(await read(manifest.prefix+'/coins/'+file))));
const env={ASSETS:{async fetch(request){try{return new Response(await read(new URL(request.url).pathname));}catch{return new Response(null,{status:404});}}}};
const reviewedDetails=[
  ['a0x','base'],['tetsuo-coin','solana'],['wagmi-2','base'],['wagmi-5','base'],
  ['aussie-dollar-token','ethereum'],['pump-fun','solana']
];
const normalize=text=>text.normalize('NFC').replace(/\s+/g,' ').toLocaleLowerCase('en');

test('full names, symbols and bridge qualifiers stay readable while long titles shorten surrounding wording',()=>{
  const tether={name:'Tether',symbol:'USDT'};
  assert.equal(tokenPageTitle(tether,{name:'TRON'}),'Tether (USDT) Wallet on TRON: Send & Receive on iPhone | Oath');
  assert.equal(tokenPageTitle(tether),'Tether (USDT) Wallet: Send & Receive on iPhone | Oath');
  assert.equal(tokenLabel({name:'USDC',symbol:'USDC'}),'USDC');
  assert.equal(tokenLabel({name:'Token (ABC)',symbol:'ABC'}),'Token (ABC)');
  const bridged={name:'Bridged USDC (Base)',symbol:'USDBC'};
  assert.match(tokenPageTitle(bridged,{name:'Base'}),/^Bridged USDC \(Base\) \(USDBC\) Wallet on Base:/);
  const long={name:'Wrapped '+Array(16).fill('Distinct').join(' ')+' Token',symbol:'WDT'};
  const title=tokenPageTitle(long,{name:'Arbitrum'});
  assert.ok(title.includes(long.name));assert.ok(title.includes('(WDT)'));assert.ok(title.includes('Arbitrum'));
  assert.ok(title.endsWith('| Oath'));assert.ok(!title.includes('on iPhone'));
});

test('same-name identities have stable distinct titles even when their shortened references initially collide',()=>{
  const networks=[{id:'base',name:'Base'}];
  const rows=[
    {name:'Token',symbol:'TOK',network:'base',reference:'0x123456'+('a'.repeat(25))+'987654',coinID:'token-a'},
    {name:'Token',symbol:'TOK',network:'base',reference:'0x123456'+('b'.repeat(25))+'987654',coinID:'token-b'},
    {name:'Other Token',symbol:'TOK',network:'base',reference:'0x'+'c'.repeat(40),coinID:'token-c'}
  ];
  const qualified=qualifyTokenTitles(rows,networks);
  assert.notEqual(qualified[0].titleQualifier,qualified[1].titleQualifier);
  assert.equal(qualified[2].titleQualifier,undefined);
  assert.deepEqual(qualifyTokenTitles([...rows].reverse(),networks).reverse(),qualified);
  assert.deepEqual(qualifyTokenTitles(qualified,networks),qualified);
  assert.ok(rows.every(r=>!r.titleQualifier),'source records are not mutated');
  const hubs=rows.slice(0,2).map(r=>({...r,assets:[{},{}]}));qualifyOverviewTitles(hubs);
  assert.notEqual(tokenPageTitle(hubs[0]),tokenPageTitle(hubs[1]));
});

test('every published detail and multi-network overview has a distinct identity-preserving title',()=>{
  const seen=new Set();let details=0,hubs=0;
  const check=(asset,network)=>{
    const title=tokenPageTitle(asset,network),key=normalize(title);
    assert.ok(!seen.has(key),title);seen.add(key);
    assert.ok(title.includes(asset.name),asset.name);assert.ok(normalize(title).includes(normalize(asset.symbol)),asset.symbol);
    if(network)assert.ok(title.includes(network.name));assert.ok(title.endsWith('| Oath'));
  };
  for(const c of coins){
    if(c.assets.length>1){check(c);hubs++;}
    for(const a of c.assets){check(a,manifest.networks[a.network]);details++;}
  }
  assert.equal(details,manifest.count);assert.equal(hubs,manifest.hubCount);
});

test('page titles, social previews and structured metadata agree across networks and title edge cases',async()=>{
  const rows=coins.flatMap(c=>c.assets),cases=new Map();
  for(const network of Object.keys(manifest.networks)){const a=rows.find(a=>a.network===network);cases.set(a.path,[a,manifest.networks[network]]);}
  for(const a of [rows.find(a=>a.titleQualifier),rows.find(a=>a.name.length>70),rows.find(a=>a.name.includes('&')),rows.find(a=>a.path==='/tokens/usdt/aptos'),rows.find(a=>a.path==='/tokens/usdt/tron'),...reviewedDetails.map(([slug,network])=>rows.find(a=>a.path==='/tokens/'+slug+'/'+network))])cases.set(a.path,[a,manifest.networks[a.network]]);
  for(const c of [coins.find(c=>c.slug==='usdt'),coins.find(c=>c.slug==='usdc'),coins.find(c=>c.titleQualifier)])cases.set('/tokens/'+c.slug,[c]);
  for(const [path,[asset,network]]of cases){
    const r=await worker.fetch(new Request(origin+path),env);assert.equal(r.status,200,path);
    const html=await r.text(),title=tokenPageTitle(asset,network),escaped=escapeHTML(title);
    assert.equal(html.match(/<title>(.*?)<\/title>/s)[1],escaped,path);
    assert.ok(html.includes(`<meta property="og:title" content="${escaped}">`),path);
    assert.ok(html.includes(`<meta name="twitter:title" content="${escaped}">`),path);
    const graph=JSON.parse(html.match(/<script type="application\/ld\+json">(.*?)<\/script>/s)[1]);
    assert.equal(graph['@graph'][0].name,title,path);
    assert.ok(html.includes(`<link rel="canonical" href="${origin+path}">`));
    const heading=network?`${asset.symbol} on ${network.name}`:asset.name;
    assert.ok(html.includes(`<h1>${escapeHTML(heading)}</h1>`),path+' visible heading changed');
    assert.ok(html.includes(escapeHTML(asset.name)),path+' full token name');
    if(network)assert.ok(html.includes(escapeHTML(network.symbol)),path+' fee asset');
    assert.ok(html.includes('does not mean issuer verification, safety approval or individually tested sending'));
  }
});

test('the Base WAGMI comparison points to two distinct released contracts',async()=>{
  const record=slug=>coins.find(c=>c.slug===slug).assets.find(a=>a.network==='base');
  const protocol=record('wagmi-2'),virtuals=record('wagmi-5');
  assert.notEqual(protocol.reference,virtuals.reference);
  const answer=tokenAnswer(protocol);
  assert.ok(answer.receiving.toLowerCase().includes(virtuals.reference));
  assert.ok(answer.sources.some(s=>s.url===origin+virtuals.path));
  assert.equal(tokenAnswer({...protocol,reference:virtuals.reference}),undefined);
  assert.equal(tokenAnswer({...virtuals,reference:protocol.reference}),undefined);
});

test('reviewed introductions, metadata and sitemap dates follow the exact project token identity',async()=>{
  const sitemaps=await readdir(new URL('sitemaps/',root));
  const xml=(await Promise.all(sitemaps.filter(name=>name.startsWith('tokens-')).map(name=>read('/sitemaps/'+name)))).join('');
  for(const [slug,network] of reviewedDetails){
    const path='/tokens/'+slug+'/'+network;
    const coin=coins.find(c=>c.slug===slug);
    const asset=coin.assets.find(a=>a.path===path);
    const answer=tokenAnswer(asset);
    assert.ok(answer,path);
    for(const mismatch of [{reference:asset.reference+'1'},{network:'other'},{coinID:'other'}]){
      const other={...asset,...mismatch};
      assert.equal(tokenAnswer(other),undefined);
      assert.notEqual(tokenPageTitle(other,manifest.networks[network]),answer.title);
    }
    const fetchPage=suffix=>worker.fetch(new Request(origin+path+suffix),env);
    const html=await (await fetchPage('')).text();
    const md=await (await fetchPage('.md')).text();
    for(const doc of [html,md]){
      const start=doc.indexOf(answer.heading),receive=doc.indexOf('Receive '+asset.symbol+' on ');
      const opening=doc.slice(start,receive);
      assert.ok(start>=0 && receive>start,path);
      for(const value of [answer.answer,asset.reference,answer.receiving,...answer.sources.map(source=>source.url)]){
        assert.ok(opening.includes(value),path+' opening: '+value);
      }
      for(const step of answer.receiveSteps||[])assert.ok(doc.slice(receive).includes(step),path+' receiving steps');
    }
    const page=JSON.parse(html.match(/<script type="application\/ld\+json">(.*?)<\/script>/s)[1])['@graph'][0];
    assert.equal(page.description,answer.description);
    assert.equal(page.dateModified,answer.updated);
    assert.ok(html.includes(`<meta name="description" content="${escapeHTML(answer.description)}">`));
    assert.ok(xml.includes(`<loc>${origin+path}</loc><lastmod>${answer.updated}</lastmod>`));
    const alias=await worker.fetch(new Request(origin+'/tokens/'+slug),env);
    if(coin.assets.length===1){
      assert.equal(alias.status,308);
      assert.equal(alias.headers.get('location'),origin+path);
    }else{
      assert.equal(alias.status,200);
      const overview=await alias.text();
      assert.ok(overview.includes('href="'+path+'"'));
      assert.ok(!overview.includes(answer.heading));
      for(const other of coin.assets.filter(row=>row.network!==network))assert.equal(tokenAnswer(other),undefined,other.path);
    }
  }
});
