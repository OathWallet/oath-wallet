import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import worker from '../src/index.js';
import {documents,currentStatus,documentText} from '../src/agent-content.js';
import {publicOrigins,publicSearchRobots} from '../src/search-crawlers.js';
import {versions} from '../src/mcp.js';
import providers from '../content/ai-providers.json' with {type:'json'};
import manifest from '../src/tokens-manifest.json' with {type:'json'};
const env={ASSETS:{async fetch(req){const path=new URL(req.url).pathname;try{return new Response(await readFile(new URL('../public'+path,import.meta.url)),{headers:{'Content-Type':path.endsWith('.html')?'text/html':path.endsWith('.md')?'text/markdown':'application/json'}});}catch{return new Response(null,{status:404});}}}};
const meta={'io.modelcontextprotocol/protocolVersion':'2026-07-28','io.modelcontextprotocol/clientInfo':{name:'OathInteropTest',version:'1'},'io.modelcontextprotocol/clientCapabilities':{}};
async function rpc(method,params={},version='2026-07-28',headers={}){
 const modern=version==='2026-07-28';
 const name=method==='resources/read'?params.uri:params.name;
 const r=await worker.fetch(new Request('https://oathwallet.org/mcp',{method:'POST',headers:{'Content-Type':'application/json','Mcp-Protocol-Version':version,...modern?{Accept:'application/json, text/event-stream','Mcp-Method':method,...name?{'Mcp-Name':name}:{}}:{},...headers},body:JSON.stringify({jsonrpc:'2.0',id:1,method,params:{...modern?{_meta:meta}:{},...params}})}),env);
 return {status:r.status,body:await r.json()};
}
test('all four hosts expose scoped discovery, aliases, full text and dated release records',async()=>{
 for(const origin of publicOrigins){
  for(const path of ['/llms.txt','/llms-full.txt','/agent-documents.json','/release-status.json','/ai-providers.json','/sitemap.xml']){
   const get=await worker.fetch(new Request(origin+path),env);assert.equal(get.status,200,origin+path);assert.ok((await get.text()).length>30);
   const head=await worker.fetch(new Request(origin+path,{method:'HEAD'}),env);assert.equal(head.status,200);assert.equal(await head.text(),'');
  }
  for(const path of ['/agents.md','/AGENTS.md']){const r=await worker.fetch(new Request(origin+path),env);assert.equal(r.status,308);assert.equal(r.headers.get('Location'),'https://oathwallet.org/ai.md');}
  const index=await(await worker.fetch(new Request(origin+'/agent-documents.json'),env)).json();
  assert.deepEqual(index.current_status,currentStatus);
  for(const d of index.documents)assert.ok(origin===publicOrigins[0]||new URL(d.url).origin===origin);
  const text=await(await worker.fetch(new Request(origin+'/llms-full.txt'),env)).text();
  for(const d of documents.filter(d=>origin===publicOrigins[0]||new URL(d.url).origin===origin))assert.ok(text.includes(await documentText(d,env)));
 }
});
test('provider identities are sourced and News retains private-path restrictions',()=>{
 const names=providers.providers.flatMap(p=>{assert.match(p.documentation,/^https:\/\//);return Object.keys(p.agents);});
 for(const name of ['OAI-SearchBot','Claude-SearchBot','Meta-WebIndexer','MistralAI-Index','Amzn-SearchBot','Googlebot','bingbot'])assert.ok(names.includes(name));
 assert.equal(providers.providers.find(p=>p.name==='DeepSeek').agents.DeepSeekBot,undefined);
 for(const origin of publicOrigins){const text=publicSearchRobots(origin);for(const name of [...names,'*'])assert.ok(text.includes('User-agent: '+name+'\n'));}
 const news=publicSearchRobots(publicOrigins[3]);
 for(const path of ['/admin','/api/','/preferences','/confirm','/unsubscribe','/t/','/_newsletter/'])assert.ok(!news.includes('Allow: '+path));
 assert.ok(news.includes('Disallow: /'));assert.ok(news.includes('Allow: /llms.txt$'));
});
test('release facts keep the App Store version, unknown build and reviewed source separate',()=>{
 assert.equal(currentStatus.published_source.version,'5.1.1');assert.equal(currentStatus.published_source.build,111);assert.equal(currentStatus.app_store.version,null);assert.equal(currentStatus.app_store.build,null);
 assert.equal(currentStatus.guide_source.version,'5.1.1');assert.equal(currentStatus.guide_source.build,111);
 assert.equal(currentStatus.source_commit,currentStatus.published_source.source_commit);assert.equal(currentStatus.security_review.independent_certification,false);
});
test('MCP legacy clients retain initialization and current clients discover capabilities',async()=>{
 for(const v of versions.slice(1)){
  const r=await rpc('initialize',{protocolVersion:v,capabilities:{},clientInfo:{name:'legacy',version:'1'}},v);
  assert.equal(r.status,200);assert.equal(r.body.result.protocolVersion,v);
  assert.equal((await rpc('tools/call',{name:'get_release_status'},v)).body.result.structuredContent.app_store.version,null);
 }
 const r=await rpc('server/discover');assert.equal(r.status,200);assert.deepEqual(r.body.result.supportedVersions,versions);assert.equal(r.body.result.resultType,'complete');
 assert.equal((await rpc('not/a/method')).status,404);
});
test('MCP rejects inconsistent modern headers, unsupported versions and foreign origins',async()=>{
 for(const headers of [{'Mcp-Method':'resources/read'},{'Mcp-Protocol-Version':'2025-06-18'},{'Mcp-Name':'wrong'}]){
  const r=await rpc('tools/call',{name:'get_release_status'},'2026-07-28',headers);assert.equal(r.status,400);assert.equal(r.body.error.code,-32020);
 }
 const unsupported=await rpc('tools/list',{},'2099-01-01');assert.equal(unsupported.status,400);assert.equal(unsupported.body.error.code,-32022);assert.deepEqual(unsupported.body.error.data.supported,versions);
 assert.equal((await rpc('tools/list',{},'2026-07-28',{Origin:'https://untrusted.invalid'})).status,403);
 assert.equal((await rpc('tools/list',{},'2026-07-28',{Accept:'text/html'})).status,406);
 const name='get_release_status',encoded='=?base64?'+Buffer.from(name).toString('base64')+'?=';
 assert.equal((await rpc('tools/call',{name},'2026-07-28',{'Mcp-Name':encoded})).body.result.structuredContent.version,'5.1.1');
});
test('MCP resource pagination covers every editorial and catalog identity once',async()=>{
 const seen=new Set();let cursor;let pages=0;
 do{const r=await rpc('resources/list',cursor?{cursor}:{});assert.equal(r.status,200);const result=r.body.result;assert.ok(result.resources.length<=100&&result.resources.length>0);
  for(const row of result.resources){assert.ok(!seen.has(row.uri));seen.add(row.uri);}
  cursor=result.nextCursor;assert.ok(++pages<1000);
 }while(cursor);
 const expected=new Set(documents.map(d=>d.markdown_url));
 for(let page=1;page<=manifest.documentPages;page++){const j=JSON.parse(await readFile(new URL('../public'+manifest.prefix+'/documents/'+page+'.json',import.meta.url)));for(const d of j.documents)expected.add(d.markdown_url);}
 assert.deepEqual(seen,expected);
 for(const cursor of ['../private','expired:tokens:1',null,42])assert.equal((await rpc('resources/list',{cursor})).body.error.code,-32602);
});
test('MCP reads registered token resources and rejects arbitrary URLs, searches and private documents',async()=>{
 const uri='https://oathwallet.org/tokens/usdt/tron.md';
 const r=await rpc('resources/read',{uri});assert.match(r.body.result.contents[0].text,/Canonical: https:\/\/oathwallet.org\/tokens\/usdt\/tron/);
 for(const url of ['http://169.254.169.254/','https://oathwallet.org/tokens/documents.json','https://oathwallet.org/tokens?q=private','https://news.oathwallet.org/preferences?token=private','https://oathwallet.org/tokens/usdt/tron?unexpected=value'])assert.equal((await rpc('tools/call',{name:'read_document',arguments:{url}})).body.result.isError,true,url);
});

test('modern client identity is optional and missing resources use the current error code',async()=>{
 const minimal={...meta};delete minimal['io.modelcontextprotocol/clientInfo'];
 assert.equal((await rpc('server/discover',{_meta:minimal})).status,200);
 const missing={...minimal};delete missing['io.modelcontextprotocol/clientCapabilities'];
 const r=await rpc('tools/list',{_meta:missing});assert.equal(r.status,400);assert.equal(r.body.error.code,-32602);
 assert.equal((await rpc('resources/read',{uri:'https://oathwallet.org/not-a-resource.md'})).body.error.code,-32602);
 assert.equal((await rpc('resources/read',{uri:'https://oathwallet.org/not-a-resource.md'},'2025-06-18')).body.error.code,-32002);
});
