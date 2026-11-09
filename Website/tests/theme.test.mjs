import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {runInNewContext} from 'node:vm';
import {themeCSS,themeDocument,paletteCSS,applyTheme} from '../src/theme.js';
const script=await readFile(new URL('../public/theme.js',import.meta.url),'utf8');
function client({cookie='',stored=null,blocked=false,host='oathwallet.org'}={}){
 const events={},attributes={},buttons=['light','dark'].map(theme=>({dataset:{oathThemeChoice:theme},setAttribute(n,v){this[n]=v;},getAttribute(n){return this[n];}}));
 let meta;
 const document={cookie,documentElement:{style:{},setAttribute(n,v){attributes[n]=v;},getAttribute(n){return attributes[n];}},head:{append(m){meta=m;}},querySelector(){return meta;},querySelectorAll(){return buttons;},createElement(){return {dataset:{}};},addEventListener(n,f){events[n]=f;}};
 const localStorage={getItem(){if(blocked)throw Error('blocked');return stored;},setItem(k,v){if(blocked)throw Error('blocked');stored=v;}};
 runInNewContext(script,{document,localStorage,location:{hostname:host,protocol:'https:'},window:{addEventListener(n,f){events[n]=f;}},MutationObserver:class{observe(){}},matchMedia(){throw Error('Must not follow OS appearance');}});
 return {document,attributes,buttons,events,click(theme){events.click({target:{closest(){return buttons.find(b=>b.dataset.oathThemeChoice===theme);}}});},get stored(){return stored;}};
}
test('first visit defaults to light independent of operating system, even with storage unavailable',()=>{
 for(const blocked of [false,true]){const c=client({blocked});assert.equal(c.attributes['data-oath-theme'],'light');assert.equal(c.buttons[0]['aria-pressed'],'true');}
 assert.match(paletteCSS(),/^:root\{--oath-color-scheme:light/);
});
test('footer selection persists and cross-subdomain cookie takes precedence over stale local state',()=>{
 const c=client();c.click('dark');assert.equal(c.attributes['data-oath-theme'],'dark');assert.equal(c.stored,'dark');assert.match(c.document.cookie,/Domain=oathwallet.org/);assert.match(c.document.cookie,/Secure/);assert.equal(c.buttons[1]['aria-pressed'],'true');
 const help=client({cookie:'oath-theme=dark',stored:'light',host:'help.oathwallet.org'});assert.equal(help.attributes['data-oath-theme'],'dark');help.click('light');assert.equal(help.stored,'light');
 assert.equal(client({cookie:'oath-theme=unexpected',stored:'invalid'}).attributes['data-oath-theme'],'light');
 assert.equal(client({stored:'dark'}).attributes['data-oath-theme'],'dark');
 const local=client({host:'localhost'});local.click('dark');assert.doesNotMatch(local.document.cookie,/Domain=/);
});
test('another tab changes appearance and persistence together',()=>{const c=client();c.events.storage({key:'oath-theme',newValue:'dark'});assert.equal(c.attributes['data-oath-theme'],'dark');assert.match(c.document.cookie,/oath-theme=dark/);});
test('palette conversion is idempotent and preserves artwork, content and black shadows',()=>{
 const css='body{background:#0A0A0B;color:#F2F0EA;box-shadow:0 2px 3px rgba(0,0,0,.4)}.x{color:white}';
 const result=themeCSS(css);assert.equal(themeCSS(result),result);assert.match(result,/rgba\(0,0,0,.4\)/);assert.match(result,/--oath-c-f2f0ea/);
 const html='<html><head><meta charset="utf-8"><style>'+css+'</style></head><body><p>#F2F0EA is a brand color</p><svg><path fill="#FFFFFF"/></svg><img src="art.png"></body></html>';
 const output=themeDocument(html);assert.equal(themeDocument(output),output);assert.match(output,/<meta charset="utf-8"><script data-oath-theme-bootstrap/);assert.match(output,/<p>#F2F0EA is a brand color<\/p>/);assert.match(output,/<path fill="#FFFFFF"/);
 assert.match(paletteCSS(),/\[data-preview-device\]/);
});
test('runtime pages retain status and CSP; API, HEAD and app artwork are untouched',async()=>{
 const notModified=new Response(null,{status:304,headers:{'Content-Type':'text/html'}});assert.equal(await applyTheme(new Request('https://oathwallet.org/'),notModified),notModified);
 const response=new Response('<html><head></head><body style="color:#F2F0EA">Missing</body></html>',{status:404,headers:{'Content-Type':'text/html','Content-Security-Policy':"script-src 'self'",ETag:'old'}});
 const themed=await applyTheme(new Request('https://help.oathwallet.org/missing'),response);assert.equal(themed.status,404);assert.equal(themed.headers.get('Content-Security-Policy'),"script-src 'self'");assert.equal(themed.headers.get('ETag'),null);assert.match(await themed.text(),/data-oath-theme-bootstrap/);
 for(const [url,method,type] of [['https://oathwallet.org/api','GET','application/json'],['https://oathwallet.org/','HEAD','text/html'],['https://oathwallet.org/Oath%20App%20Home.dc.html','GET','text/html'],['https://oathwallet.org/yandex_ab1234.html','GET','text/html']]){const res=new Response('unchanged',{headers:{'Content-Type':type}});assert.equal(await applyTheme(new Request(url,{method}),res),res);}
});
