import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import {gunzipSync} from 'node:zlib';
import {checkedIdentity, reviewedAssets, guidePreview, productIdentity} from '../src/xstock-guides.js';
import {escapeHTML} from '../src/tokens.js';
import {storeCampaign,campaignAnchors} from '../src/store-campaigns.js';
import {priorityUpdated} from '../src/seo-guidance.js';
import captures from '../content/captures/priority-2026-11-10.json' with {type:'json'};
import routes from '../content/tokens/routes.json' with {type:'json'};

const publicRoot=new URL('../public/',import.meta.url);
const readPublic=path=>readFile(new URL(path,publicRoot));

test('issuer evidence matches all 40 released entries and cannot verify replacements or new networks',async()=>{
  const snapshot=JSON.parse(gunzipSync(await readFile(new URL('../content/tokens/source.json.gz',import.meta.url))));
  const slugs=new Map(routes.coins);
  for(const [coinID,guide] of Object.entries(reviewedAssets)){
    const entries=snapshot.entries.filter(a=>a.coinID===coinID);
    assert.equal(entries.length,8);
    for(const entry of entries)assert.equal(checkedIdentity(guide,entry)?.reference,entry.reference);
    for(const entry of [{network:'ethereum',reference:'different'},{network:'unreviewed',reference:entries[0].reference}]){
      assert.equal(checkedIdentity(guide,entry),null);
      assert.match(productIdentity({coinID,slug:slugs.get(coinID)},entry,escapeHTML),/Catalog record only/);
    }
    assert.equal(priorityUpdated('/tokens/'+slugs.get(coinID)),'2026-11-10');
    assert.ok((await readPublic(guidePreview('/tokens/'+slugs.get(coinID)).slice(1))).length>0);
  }
});
test('simulator captures are the documented released build and match their published digests',async()=>{
  assert.equal(captures.version,'5.0.2');assert.equal(captures.build,104);
  for(const img of captures.images){
    assert.equal(createHash('sha256').update(await readPublic(img.path.slice(1))).digest('hex'),img.sha256);
    assert.equal(img.width,1320);assert.equal(img.height,2868);
  }
});
test('Apple campaign URLs preserve the app ID and existing attribution and review links',()=>{
  for(const [url,group] of [['https://oathwallet.org/networks/sui','networks'],['https://oathwallet.org/networks/tron/tokens','tokens'],['https://oathwallet.org/tokens','tokens'],['https://articles.oathwallet.org/a','guides'],['https://help.oathwallet.org/articles/a','guides'],['https://oathwallet.org/',''],['https://news.oathwallet.org/admin','']]){
    assert.equal(storeCampaign(url)||'',group);
    const link='<a href="https://apps.apple.com/app/id6780187283">Download</a>';
    const result=campaignAnchors(link,group);
    if(group)assert.ok(result.includes('id6780187283?pt=128883369&amp;ct=oath-web-'+group+'&amp;mt=8'));
    else assert.equal(result,link);
  }
  for(const target of ['?see-all=reviews','?ct=existing','#reviews']){
    const link='<a href="https://apps.apple.com/app/id6780187283'+target+'">Read</a>';
    assert.equal(campaignAnchors(link,'tokens'),link);
  }
});
test('edition describes both downloadable files and provides addressable evidence for the migration guides',async()=>{
  const html=(await readPublic('compatibility/2026-11-09.html')).toString();
  const graph=[...html.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)].flatMap(m=>JSON.parse(m[1])['@graph']||[]);
  const dataset=graph.find(x=>x['@type']==='Dataset');
  assert.equal(dataset.version,'2026-11-09');
  assert.equal(dataset.distribution.length,2);
  for(const download of dataset.distribution)assert.ok((await readPublic(new URL(download.contentUrl).pathname.slice(1))).length);
  for(const id of ['citation','trust-evm','metamask-later','electrum-segwit'])assert.ok(html.includes('id="'+id+'"'));
  assert.ok(!dataset.license);
});
