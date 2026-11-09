import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {applyAppBanner, appBanner} from '../src/app-banner.js';
import worker from '../src/index.js';

test('native banner is emitted once in the head without forwarding page parameters', async()=>{
  const request=new Request('https://oathwallet.org/?private=value');
  const html='<html><head><meta charset="utf-8"><meta content="app-id=old" name="apple-itunes-app"><title>Oath</title></head><body>Unchanged</body></html>';
  const response=await applyAppBanner(request,new Response(html,{headers:{'Content-Type':'text/html','Cache-Control':'no-store','Content-Security-Policy':"default-src 'self'",ETag:'old','Content-Length':'1'}}));
  const result=await response.text();
  assert.equal((result.match(/name="apple-itunes-app"/g)||[]).length,1);
  assert.ok(result.includes(appBanner+'</head>'));
  assert.ok(result.endsWith('<body>Unchanged</body></html>'));
  assert.doesNotMatch(result,/app-argument|private=value|app-id=old/);
  assert.equal(response.headers.get('ETag'),null);
  assert.equal(response.headers.get('Content-Length'),null);
  assert.equal(response.headers.get('Cache-Control'),'no-store');
  assert.equal(response.headers.get('Content-Security-Policy'),"default-src 'self'");
  assert.equal(await (await applyAppBanner(request,new Response(result,{headers:{'Content-Type':'text/html'}}))).text(),result);
});

test('banner leaves errors, redirects, assets, HEAD and embedded/verification documents untouched',async()=>{
  for(const [path,method,status,type] of [
    ['/','HEAD',200,'text/html'],['/missing','GET',404,'text/html'],['/swap','GET',410,'text/html'],
    ['/old','GET',301,'text/html'],['/api','GET',200,'application/json'],
    ['/Oath%20App%20Home.dc.html','GET',200,'text/html'],['/yandex_ab123.html','GET',200,'text/html'],
    ['/newsletter','POST',200,'text/html']
  ]) {
    const response=new Response('unchanged',{status,headers:{'Content-Type':type}});
    assert.equal(await applyAppBanner(new Request('https://oathwallet.org'+path,{method}),response),response,path);
  }
});

test('shared worker adds banner to main, network, Help Center and article pages',async()=>{
  const env={ASSETS:{async fetch(request){
    const path=new URL(request.url).pathname;
    try {return new Response(await readFile(new URL('../public'+path,import.meta.url)),{headers:{'Content-Type':path.endsWith('.html')?'text/html':'application/json'}});}
    catch{return new Response('Missing',{status:404});}
  }}};
  for(const url of ['https://oathwallet.org/','https://oathwallet.org/networks/ethereum','https://help.oathwallet.org/','https://articles.oathwallet.org/']) {
    const response=await worker.fetch(new Request(url),env,{waitUntil(){}});
    assert.equal(response.status,200,url);
    const html=await response.text();
    const head=html.match(/<head\b[^>]*>([\s\S]*?)<\/head>/i)?.[1];
    assert.ok(head?.includes(appBanner),url);
    assert.equal((html.match(/name="apple-itunes-app"/g)||[]).length,1,url);
  }
});
