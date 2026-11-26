import compatibility from '../content/compatibility/catalog.json' with {type:'json'};
import decisionGuides from '../content/decision-guides.json' with {type:'json'};
import featureCatalog from '../content/features.json' with {type:'json'};
import networkCatalog from '../content/networks.json' with {type:'json'};
import help from './help/content.json' with {type:'json'};
import facts from '../public/oath-data.json' with {type:'json'};
import evidence from '../content/release-evidence.json' with {type:'json'};
import distribution from '../../releases/5.0.2-distribution.json' with {type:'json'};
import publishedSource from '../content/published-source-release.json' with {type:'json'};
import appStore from '../content/app-store-release.json' with {type:'json'};
import providers from '../content/ai-providers.json' with {type:'json'};
import {publicOrigins} from './search-crawlers.js';
import {migrateArticleLinks} from './article-host.js';
import {articleRoutes} from './article-routes.js';
export const tokenDiscovery={url:'https://oathwallet.org/tokens',documents:'https://oathwallet.org/tokens/documents.json',page_size:100,scope:'Released discovery catalog; inclusion is not issuer verification or tested sending.'};
const main='https://oathwallet.org', support='https://help.oathwallet.org', articles='https://articles.oathwallet.org';
const pages=['index','ai','features','about','networks','press','security','bug-bounty','terms','privacy'];
const articlePath=p=>p.replace(/\/articles(?=\/|$)/,'')||'/';
const pageSummaries={index:'Official Oath Wallet product information, features, downloads and self-custody guidance.',ai:'Official AI reader guide: accurate Oath facts, complete document discovery, Markdown, read-only MCP, provider policies and search indexing.',features:'Explore Oath wallet features and their network and release limitations.',about:'Learn about Oath, its supported platforms, product scope and official source.',networks:'Find network-specific Oath receiving, sending, fees and dApp connection guidance.',press:'Official Oath brand assets, product background and press contacts.',security:'Oath security model, scoped source evidence, review limitations and vulnerability reporting.','bug-bounty':'Oath vulnerability disclosure, program eligibility, evidence requirements and reward policy.',terms:'Read the Oath Wallet terms of service and product conditions.',privacy:'Read how Oath Wallet handles data and the privacy practices of its services.'};
export const documents=[
 ...compatibility.pages.map(p=>({url:main+p.path,markdown_url:main+p.path+'.md',title:p.title,summary:p.description,kind:'compatibility',file:p.path+'.md',updated_at:p.updated})),
 ...decisionGuides.pages.map(p=>({url:main+p.path,markdown_url:main+p.path+'.md',title:p.title,summary:p.description,kind:'decision-guide',file:p.path+'.md',updated_at:decisionGuides.updated})),
 ...featureCatalog.features.map(f=>({url:main+f.path,markdown_url:main+f.path+'.md',title:f.name,summary:f.description,kind:'feature',file:f.path+'.md',updated_at:featureCatalog.reviewed,app_version:featureCatalog.version})),
 ...networkCatalog.networks.map(n=>({url:main+'/networks/'+n.slug,markdown_url:main+'/networks/'+n.slug+'.md',title:n.name+' wallet: send, receive and dApp connections',summary:n.intro,kind:'network',file:'/networks/'+n.slug+'.md',updated_at:networkCatalog.reviewed})),
 ...pages.map(p=>({url:main+(p==='index'?'/':'/'+p),markdown_url:main+'/'+p+'.md',title:p==='index'?'Oath Wallet':p==='ai'?'Oath Wallet: official guide for AI readers and developers':p[0].toUpperCase()+p.slice(1),summary:pageSummaries[p],kind:'page',file:'/'+p+'.md',...(p==='ai'?{updated_at:'2026-11-25'}:{})})),
 {url:'https://news.oathwallet.org/',markdown_url:'https://news.oathwallet.org/index.md',title:'Oath Notes — The Oath Wallet newsletter',summary:'Wallet releases, security alerts, market context and practical guides from the Oath team, with email topic preferences.',kind:'newsletter',file:'/news/index.md',updated_at:'2026-11-25'},
 {url:support+'/',markdown_url:support+'/index.md',title:'Help Center',summary:'Find Oath Wallet instructions for setup, accounts, receiving, sending, backups, security and troubleshooting, with applicable app versions.',kind:'help-index'},
 ...help.categories.map(c=>({url:support+'/collections/'+c.id,markdown_url:support+'/collections/'+c.id+'.md',title:c.title,summary:c.description,kind:'collection',id:c.id})),
 ...help.articles.map(a=>({url:support+'/articles/'+a.slug,markdown_url:support+'/articles/'+a.slug+'.md',title:a.title,summary:a.summary,updated_at:a.updated_at,published_at:a.published_at,app_version:a.app_version,kind:'help',id:a.slug})),
 {url:articles+'/',markdown_url:articles+'/index.md',title:'Articles',summary:'Read Oath articles about self-custody, wallet security, network behavior, releases and practical crypto workflows, including available translations.',kind:'article-index',file:'/articles.md'},
 ...Object.entries(articleRoutes).filter(([,v])=>typeof v==='string').map(([p])=>{
  const url=articles+articlePath(p), a=facts.articles.find(a=>a.url===url || a.url===main+p);
  return {url,markdown_url:url+'.md',title:a?.title||p.split('/').pop().replaceAll('-',' '),summary:a?.description||a?.summary||a?.excerpt||'',updated_at:a?.updated_at,published_at:a?.published_at,language:a?.locale||'en',kind:'article',file:p+'.md'};
 })
];
export const publicDocument=d=>({language:'en',...Object.fromEntries(Object.entries(d).filter(([k,v])=>!['file','id'].includes(k)&&v!==undefined))});
export const evidenceScope={version:evidence.version,build:evidence.build,reviewed_on:evidence.reviewed_on,source_url:`https://github.com/OathWallet/oath-wallet/tree/${evidence.source_commit}`,scope:'Pinned source excerpts, not an independent audit or confirmation of the current App Store version.',app_store_url:facts.facts.download};
// Release identity, excerpt verification and review coverage are separate facts.
export const currentStatus={schema_version:2,checked_on:appStore.checked_on,name:facts.name,
 version:appStore.version,build:appStore.build,distribution_status:appStore.status,
 release_url:appStore.url,source_commit:null,distribution_evidence_url:appStore.evidence_url,
 app_store:appStore,
 published_source:publishedSource,
 guide_source:{version:distribution.version,build:distribution.build,source_commit:distribution.source_commit,
  release_url:facts.security.release_record,scope:'Pinned source used by the existing product guides; not a verified match to the current App Store binary.'},
 security_review:facts.security.published_review,review:facts.security.published_review,source_evidence:evidenceScope,
 compatibility:{deprecated_fields:['version','build','distribution_status','release_url','source_commit','distribution_evidence_url','review'],note:'Use app_store, published_source and security_review. An unknown App Store build or binary-to-source correspondence is null.'}};
export const statusText=()=>`Latest source release: Oath Wallet ${publishedSource.version}, build ${publishedSource.build}.\nCurrent App Store listing: Oath Wallet ${currentStatus.version}. Checked ${currentStatus.checked_on} (${appStore.storefront} storefront). Approved build number: not publicly verified.\nApp Store: ${appStore.url}\nDistribution evidence: ${appStore.evidence_url}\nRelease metadata: ${main}/release-status.json\nPublished source release: ${publishedSource.version} (${publishedSource.build}); ${publishedSource.release_url}\nGuide source: ${distribution.version} (${distribution.build}); ${currentStatus.guide_source.release_url}\nPublished security review: ${currentStatus.review.url}\nReview scope: ${currentStatus.review.kind}. ${currentStatus.review.limitations}\nEach result retains its tested source revision. Historical articles, screenshots and catalog snapshots retain their recorded versions.\n`;
const link=d=>`- [${d.title}](${d.markdown_url})${d.summary?': '+d.summary:''}`;
export function guide(origin) {
 if(!publicOrigins.includes(origin))throw Error('Unknown documentation host');
 const local=documents.filter(d=>new URL(d.url).origin===origin);
 const selected=origin===main?local.filter(d=>d.kind!=='network'):origin===support?local.filter(d=>d.kind!=='help'):origin===articles?local.filter(d=>d.kind==='article-index').concat(local.filter(d=>d.kind==='article').slice(0,8)):local;
 return `# Oath Wallet — public documentation\n\n> Official, source-attributed wallet documentation. Public content is available for search, user-requested reading and training; this does not guarantee indexing or citations.\n\n${statusText()}\n## Start here\n\n- [AI reader and developer guide](${main}/ai.md): source selection, limitations and MCP examples.\n- [This host's document index](${origin}/agent-documents.json): complete local editorial inventory${origin===main?', including all public hosts':''}.\n- [All public documents](${main}/agent-documents.json): editorial documents plus the paginated token catalog.\n- [Token catalog documents](${main}/tokens/documents.json): follow next until null; catalog presence is not issuer verification or tested sending.\n- [Read-only MCP](${main}/.well-known/mcp.json): explicit client configuration and supported protocol versions.\n\n## Selected documents\n\n${selected.map(link).join('\n')}\n\n## Other official sites\n\n${publicOrigins.filter(o=>o!==origin).map(o=>`- [${new URL(o).hostname}](${o}/llms.txt)`).join('\n')}\n\n## Optional\n\n- [Full editorial text](${origin}/llms-full.txt): editorial and Help content only; token documents remain paginated.\n- [Provider registry](${main}/ai-providers.json): dated official documentation and verified crawler roles.\n\nNever send recovery phrases, private keys, passcodes, wallet backups or subscriber tokens to these interfaces.\n`;
}
export function documentIndex(origin=main) {
 return {schema_version:1,current_status:currentStatus,source_evidence:evidenceScope,token_catalog:tokenDiscovery,
  documents:documents.filter(d=>origin===main||new URL(d.url).origin===origin).map(publicDocument)};
}
export async function documentText(d,env,asset) {
 let body;
 if(d.kind==='help') {
  const a=help.articles.find(a=>a.slug===d.id);
  body=`# ${a.title}\n\n${a.summary}\n\n${a.body.join('\n\n')}\n\n## Steps\n\n${a.steps.map((s,i)=>`${i+1}. ${s}`).join('\n')}\n\n${a.note}\n\n## Related\n\n${a.related.map(id=>documents.find(d=>d.kind==='help'&&d.id===id)).filter(Boolean).map(link).join('\n')}`;
 } else if(d.kind==='help-index'||d.kind==='collection') {
  const selected=documents.filter(x=>d.kind==='help-index'?x.kind==='collection':x.kind==='help'&&help.articles.find(a=>a.slug===x.id).category_id===d.id);
  body=`# ${d.title}\n\n${d.summary||'Official Oath Wallet instructions.'}\n\n${selected.map(link).join('\n')}`;
 } else {
  const r=asset || await env.ASSETS.fetch(new Request(main+d.file));
  if(!r.ok)throw new Error('Published Markdown missing: '+d.file);
  body=await r.text();
 }
 body=migrateArticleLinks(body).replace(/\]\((\/[^)]+)\)/g,(_,path)=>`](${new URL(path,main).href})`);
 body=body.replace(/^[-*][ \t]*\n(?:[ \t]*\n)+(?=\S)/gm,'- ').replace(/[ \t]+$/gm,'');
 return `Canonical: ${d.url}\n${d.updated_at?'Updated: '+d.updated_at+'\n':''}${d.app_version?'Applies to app version: '+d.app_version+'\n':''}\n${body.trim()}\n`;
}
export function searchHelp(query) {
 const words=query.toLowerCase().match(/[\p{L}\p{N}]+/gu)||[];
 if(!words.length)return [];
 return help.articles.map(a=>{
  const title=(a.title+' '+a.tags.join(' ')).toLowerCase(),body=[a.summary,...a.body,...a.steps,a.note].join(' ').toLowerCase();
  return {a,score:words.reduce((n,w)=>n+(title.includes(w)?4:0)+(body.includes(w)?1:0),0)};
 }).filter(x=>x.score>0).sort((a,b)=>b.score-a.score||a.a.slug.localeCompare(b.a.slug)).slice(0,10).map(({a})=>({...publicDocument(documents.find(d=>d.kind==='help'&&d.id===a.slug)),excerpt:a.summary}));
}
// Explicit MIME preferences only; ordinary browsers and wildcard Accept keep HTML.
export function wantsMarkdown(accept='') {
 const entries=accept.toLowerCase().split(',').map(x=>{
  const [type,...params]=x.trim().split(';'),raw=params.map(p=>p.trim()).find(p=>p.startsWith('q='))?.slice(2);
  return {type:type.trim(),q:raw===undefined?1:/^(?:0(?:\.\d{0,3})?|1(?:\.0{0,3})?)$/.test(raw)?Number(raw):0};
 });
 const quality=type=>{
  for(const range of [type,type.split('/')[0]+'/*','*/*']){
   const matches=entries.filter(x=>x.type===range);
   if(matches.length)return Math.max(...matches.map(x=>x.q));
  }
  return 0;
 };
 // Require explicit Markdown preference; a stronger wildcard HTML preference
 // must not accidentally switch a browser or search client to another format.
 return entries.some(x=>x.type==='text/markdown')&&quality('text/markdown')>Math.max(quality('text/html'),quality('application/xhtml+xml'));
}
export async function handleAgentContent(request,env) {
 const u=new URL(request.url);
 if(!publicOrigins.includes(u.origin)||!['GET','HEAD'].includes(request.method))return null;
 const headers={'Content-Type':'text/markdown; charset=utf-8','Cache-Control':'public, max-age=60, stale-while-revalidate=120','X-Content-Type-Options':'nosniff','Access-Control-Allow-Origin':'*'};
 let body;
 if(['/agents.md','/AGENTS.md'].includes(u.pathname))return Response.redirect(main+'/ai.md',308);
 if(u.origin!==main&&['/.well-known/mcp.json','/.well-known/mcp/server-card.json'].includes(u.pathname))return Response.redirect(main+u.pathname,308);
 if(u.pathname==='/ai-providers.json') {
  body=JSON.stringify(providers);headers['Content-Type']='application/json; charset=utf-8';
 } else if(u.pathname==='/llms-full.txt') {
  const path=u.origin===main?'/llms-full.txt':'/agent-bundles/'+new URL(u.origin).hostname.split('.')[0]+'.txt';
  const r=await env.ASSETS.fetch(new Request(main+path)).catch(()=>new Response(null,{status:503}));
  if(!r.ok)return new Response(request.method==='HEAD'?null:'Documentation temporarily unavailable.',{status:503,headers:{'Cache-Control':'no-store','Retry-After':'60'}});
  body=await r.text();headers['Content-Type']='text/plain; charset=utf-8';
 } else if(u.pathname==='/llms.txt') {
  body=guide(u.origin);headers['Content-Type']='text/plain; charset=utf-8';
 } else if(u.pathname==='/release-status.json') {
  body=JSON.stringify(currentStatus);headers['Content-Type']='application/json; charset=utf-8';
 } else if(u.pathname==='/agent-documents.json') {
  body=JSON.stringify(documentIndex(u.origin));headers['Content-Type']='application/json; charset=utf-8';
 } else {
  const d=documents.find(d=>d.markdown_url===u.origin+u.pathname || d.url===u.origin+u.pathname);
  if(!d)return null;
  const negotiated=d.url===u.origin+u.pathname;
  if(negotiated&&!wantsMarkdown(request.headers.get('Accept')||''))return null;
  if(negotiated)headers.Vary='Accept';
  try {
   const asset=d.file?await env.ASSETS.fetch(new Request(main+d.file)):undefined;
   if(asset){for(const [k,v] of asset.headers)if(!['content-length','content-encoding','etag','last-modified','content-type','link','vary','cache-control','access-control-allow-origin','x-content-type-options','x-robots-tag'].includes(k))headers[k]=v;}
   body=await documentText(d,env,asset);headers.Link=`<${d.url}>; rel="canonical"`;
  } catch {
   // A temporary asset failure is retryable, not an empty published document.
   return new Response(request.method==='HEAD'?null:'Documentation temporarily unavailable. Please try again shortly.',{status:503,headers:{'Content-Type':'text/plain; charset=utf-8','Cache-Control':'no-store','Retry-After':'60',...(negotiated?{Vary:'Accept'}:{})}});
  }
 }
 return new Response(request.method==='HEAD'?null:body,{headers});
}
export function addAgentDiscovery(request,response) {
 const u=new URL(request.url),d=documents.find(d=>d.url===u.origin+u.pathname);
 if(!d||!response.ok||!response.headers.get('Content-Type')?.includes('text/html'))return response;
 const r=new Response(response.body,response);
 const vary=new Set((r.headers.get('Vary')||'').split(',').map(s=>s.trim()).filter(Boolean));vary.add('Accept');r.headers.set('Vary',[...vary].join(', '));
 r.headers.append('Link',`<${d.markdown_url}>; rel="alternate"; type="text/markdown", <${u.origin}/llms.txt>; rel="describedby"; type="text/plain"`);
 return r;
}
