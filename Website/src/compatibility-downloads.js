import catalog from '../content/compatibility/catalog.json' with {type:'json'};
// Static result exports only. No submitted recovery material is processed.
export async function handleCompatibilityDownload(request,env){
 const url=new URL(request.url),match=/^\/compatibility\/([^/]+)\.(json|csv)$/.exec(url.pathname);
 if(!match)return null;
 if(!catalog.editions.includes(match[1]))return new Response('Unknown compatibility edition',{status:404});
 if(!['GET','HEAD'].includes(request.method))return new Response('Method not allowed',{status:405,headers:{Allow:'GET, HEAD'}});
 const response=await env.ASSETS.fetch(new Request(url,{method:request.method}));
 if(!response.ok)return response;
 const headers=new Headers(response.headers);
 headers.set('Content-Type',match[2]==='json'?'application/json; charset=utf-8':'text/csv; charset=utf-8');
 headers.set('Link',`<https://oathwallet.org/compatibility/${match[1]}>; rel="canonical"`);
 headers.set('Cache-Control','public, max-age=3600');headers.set('X-Content-Type-Options','nosniff');
 headers.set('Access-Control-Allow-Origin','*');
 if(match[2]==='csv')headers.set('Content-Disposition',`attachment; filename="oath-compatibility-${match[1]}.csv"`);
 return new Response(request.method==='HEAD'?null:response.body,{status:response.status,headers});
}
