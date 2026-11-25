// Exhaustive live HTML/Markdown verification. Receipts are local, resumable and
// identify the deployed inventory; they never mean search-engine indexing.
import {mkdir,readFile,appendFile,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {setTimeout as delay} from 'node:timers/promises';
import manifest from '../src/tokens-manifest.json' with {type:'json'};
const origin='https://oathwallet.org';
const dir=new URL('../Reports/ai-discovery-live/',import.meta.url);await mkdir(dir,{recursive:true});
async function get(url){
 let last;
 for(let n=0;n<4;n++)try{
  const r=await fetch(url,{redirect:'manual',headers:{'User-Agent':'OathPublicDocumentationCheck/2.0 (+https://oathwallet.org/ai)'},signal:AbortSignal.timeout(30000)});
  if([429,500,502,503,504].includes(r.status)){const wait=Math.min(60000,Math.max(1000,Number(r.headers.get('retry-after')||0)*1000,1000*2**n));await r.body?.cancel();await delay(wait);throw Error(`HTTP ${r.status}`);}
  const text=await r.text();return {status:r.status,type:r.headers.get('content-type')||'',link:r.headers.get('link')||'',robots:r.headers.get('x-robots-tag')||'',challenge:r.headers.get('cf-mitigated'),text};
 }catch(e){last=e;if(n<3)await delay(500*2**n);}
 throw last;
}
async function json(url){const r=await get(url);if(r.status!==200)throw Error(url+': '+r.status);return JSON.parse(r.text);}
const index=await json(origin+'/agent-documents.json'),all=[...index.documents];
const catalogManifest=await json(origin+manifest.prefix+'/manifest.json');
if(catalogManifest.version!==manifest.version)throw Error('The expected catalog has not deployed yet.');
let next=index.token_catalog.documents;const visited=new Set();
while(next){if(visited.has(next)||visited.size>=1000)throw Error('Invalid document pagination');visited.add(next);const page=await json(next);all.push(...page.documents);next=page.next;}
if(new Set(all.map(d=>d.url)).size!==all.length)throw Error('Duplicate canonical documents');
const signature=createHash('sha256').update(JSON.stringify({all,status:index.current_status,manifest:catalogManifest})).digest('hex').slice(0,16);
const ledger=new URL(signature+'.jsonl',dir),done=new Set();
try{for(const line of(await readFile(ledger,'utf8')).trim().split('\n')){try{const row=JSON.parse(line);if(row.status==='validated')done.add(row.url);}catch{}}}catch(e){if(e.code!=='ENOENT')throw e;}
const queue=all.filter(d=>!done.has(d.url)),failed=[];let completed=done.size;
console.log(`Validating ${all.length} live document pairs; resuming ${done.size} completed pairs.`);
await Promise.all(Array.from({length:4},async()=>{while(queue.length){const d=queue.shift();let row;
 try{
  const html=await get(d.url);if(html.status!==200||!html.type.includes('text/html')||html.challenge)throw Error('HTML status/type/challenge: '+html.status);
  const canonical=html.text.match(/<link\b[^>]*rel=["']canonical["'][^>]*href=["']([^"']+)/i)?.[1]?.replaceAll('&amp;','&');
  if(canonical!==d.url||!/<h1[\s>]/i.test(html.text)||!html.link.includes(d.markdown_url)||/noindex|none/i.test(html.robots))throw Error('HTML canonical/discovery/content mismatch');
  const md=await get(d.markdown_url);if(md.status!==200||!md.type.includes('text/markdown')||md.challenge||!md.text.includes('Canonical: '+d.url)||!md.link.includes(`<${d.url}>; rel="canonical"`)||md.text.length<80)throw Error('Markdown status/type/canonical mismatch: '+md.status);
  row={url:d.url,markdown_url:d.markdown_url,status:'validated',checked_at:new Date().toISOString()};
 }catch(e){row={url:d.url,status:'failed',error:String(e.message),checked_at:new Date().toISOString()};failed.push(row);}
 await appendFile(ledger,JSON.stringify(row)+'\n');
 if(++completed%1000===0)console.log(`${completed}/${all.length} checked; ${failed.length} failed.`);
}}));
const summary={inventory_signature:signature,total:all.length,checked:completed,validated:completed-failed.length,failed,checked_at:new Date().toISOString(),scope:'Live canonical HTML and Markdown delivery. Search indexing is separately verified in webmaster tools.'};
await writeFile(new URL('summary.json',dir),JSON.stringify(summary,null,2)+'\n');console.log(JSON.stringify({...summary,failed:failed.length}));
if(failed.length)process.exitCode=1;
