// Exhaustive, offline route/index validation; no credentials or network requests.
import assert from 'node:assert/strict';
import {readFile,readdir} from 'node:fs/promises';
import worker from '../src/index.js';
import {documents,publicDocument} from '../src/agent-content.js';
import {publicOrigins} from '../src/search-crawlers.js';
import manifest from '../src/tokens-manifest.json' with {type:'json'};
import {sitemapURLs} from './sitemaps.mjs';
const root=new URL('../public/',import.meta.url),cache=new Map();
const env={ASSETS:{async fetch(req){const path=new URL(req.url).pathname;try{
 let body=cache.get(path);if(!body){body=await readFile(new URL('.'+path,root));if(cache.size<2000)cache.set(path,body);}
 return new Response(body,{headers:{'Content-Type':path.endsWith('.html')?'text/html':path.endsWith('.md')?'text/markdown':path.endsWith('.json')?'application/json':path.endsWith('.xml')?'application/xml':'text/plain'}});
}catch{return new Response(null,{status:404});}}}};
const sitemap=new Set(await sitemapURLs());
for(const origin of publicOrigins.slice(1)){
 const r=await worker.fetch(new Request(origin+'/sitemap.xml'),env);assert.equal(r.status,200);
 for(const [,url]of(await r.text()).matchAll(/<loc>([^<]+)<\/loc>/g)){assert.ok(!sitemap.has(url));sitemap.add(url.replaceAll('&amp;','&'));}
}
const all=documents.map(publicDocument);
for(const d of all){assert.ok(d.title?.length>0,d.url+' title');assert.ok(d.summary?.length>0,d.url+' summary');assert.ok(d.language?.length>0,d.url+' language');}
for(let page=1;page<=manifest.documentPages;page++){
 const d=JSON.parse(await readFile(new URL('.'+manifest.prefix+`/documents/${page}.json`,root)));
 assert.equal(d.next,page<manifest.documentPages?`https://oathwallet.org/tokens/documents.json?page=${page+1}`:null);
 assert.ok(d.documents.length>0&&d.documents.length<=100);
 for(const item of d.documents){assert.ok(item.title?.length>0);assert.ok(item.summary?.length>40);assert.equal(item.language,'en');assert.equal(item.app_version,manifest.source.version);}
 all.push(...d.documents);
}
assert.equal(new Set(all.map(d=>d.url)).size,all.length,'Duplicate canonical document');
assert.equal(new Set(all.map(d=>d.markdown_url)).size,all.length,'Duplicate Markdown document');
assert.deepEqual(new Set(all.map(d=>d.url)),sitemap,'Sitemap and document inventory differ');
// A new static page with a canonical URL cannot silently bypass the inventory.
async function checkStatic(dir){for(const entry of await readdir(dir,{withFileTypes:true})){
 if(entry.name.startsWith('._')||['token-data','token-artwork-data','assets'].includes(entry.name))continue;
 const file=new URL(entry.name+(entry.isDirectory()?'/':''),dir);
 if(entry.isDirectory()){await checkStatic(file);continue;}
 if(!entry.name.endsWith('.html'))continue;
 const html=await readFile(file,'utf8');
 const canonical=html.match(/<link\b[^>]*rel="canonical"[^>]*href="([^"]+)"/)?.[1];
 if(canonical&&publicOrigins.includes(new URL(canonical).origin)&&!sitemap.has(canonical)){
  const response=await worker.fetch(new Request(canonical),env);
  assert.ok(!response.ok,`Unregistered canonical HTML page: ${canonical}`);
 }
}}
await checkStatic(root);
let checked=0;
const queue=[...all];
await Promise.all(Array.from({length:4},async()=>{while(queue.length){
 const d=queue.shift();
 const html=await worker.fetch(new Request(d.url,{headers:{Accept:'text/html'}}),env);
 assert.equal(html.status,200,d.url);assert.match(html.headers.get('Content-Type'),/text\/html/);
 const content=await html.text();
 assert.match(content,/<h1[\s>]/i,d.url);assert.match(content,/<title>[^<]+<\/title>/i,d.url);
 const canonical=content.match(/<link\b[^>]*rel="canonical"[^>]*href="([^"]+)"/)?.[1]?.replaceAll('&amp;','&');
 assert.equal(canonical,d.url,d.url);
 assert.ok(html.headers.get('Link')?.includes(d.markdown_url),d.url+' alternate');
 const md=await worker.fetch(new Request(d.markdown_url),env);
 assert.equal(md.status,200,d.markdown_url);assert.match(md.headers.get('Content-Type'),/text\/markdown/);
 const text=await md.text();assert.ok(text.includes('Canonical: '+d.url),d.markdown_url);assert.ok(text.length>80,d.markdown_url);
 assert.ok(md.headers.get('Link')?.includes(`<${d.url}>; rel="canonical"`));
 assert.doesNotMatch(html.headers.get('X-Robots-Tag')||'',/noindex|none/i);
 if(++checked%5000===0)console.log(`Checked ${checked}/${all.length} HTML and Markdown document pairs.`);
}}));
console.log(JSON.stringify({canonical_pages:sitemap.size,editorial:documents.length,catalog:all.length-documents.length,validated_pairs:checked,missing:0,duplicates:0,scope:'Offline generated routes and content; not search indexing.'}));
