import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {runInNewContext} from 'node:vm';
import {themeCSS,themeDocument,paletteCSS,applyTheme,palette,themeVersion} from '../src/theme.js';
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

test('light surfaces use the shared website neutrals while dark mode and brand colors stay intact',()=>{
 assert.equal(palette['0a0a0b'],'ffffff');
 assert.equal(palette['0b0b0d'],'ffffff');
 assert.equal(palette['111112'],'f6f7f8');
 assert.equal(palette['f2f0ea'],'000000');
 assert.equal(palette['a5a39d'],'636363');
 const [light,dark]=paletteCSS().split('\n');
 assert.match(light,/--oath-day-c-fafbf7:#ffffff;/);
 assert.match(light,/--oath-day-c-f2f2f7:#f6f7f8;/);
 assert.match(dark,/--oath-c-0a0a0b:#0a0a0b;/);
 assert.match(dark,/--oath-c-f2f0ea:#f2f0ea;/);
 assert.match(dark,/--oath-day-c-fafbf7:#0a0a0b;/);
 assert.equal(themeCSS('.brand{color:#244de0}'),'.brand{color:#244de0}');
 assert.match(script,/'#ffffff'/);
});

test('token and transfer field surfaces follow the theme instead of retaining dark literals',()=>{
 const input='.token-search input{background:#171719;color:#F2F0EA}.decision-controls select{background:#19191a}';
 const themed=themeCSS(input);
 assert.match(themed,/background:var\(--oath-c-171719\)/);
 assert.match(themed,/background:var\(--oath-c-19191a\)/);
 assert.equal(themeCSS(themed),themed);
 const [light,dark]=paletteCSS().split('\n');
 for(const color of ['171719','19191a']){
  assert.ok(light.includes(`--oath-c-${color}:#f6f7f8;`));
  assert.ok(dark.includes(`--oath-c-${color}:#${color};`));
 }
});

test('already generated pages refresh cached theme assets without duplicating the bootstrap',()=>{
 const old='<html><head><script data-oath-theme-bootstrap src="/theme.js?v=20261109"></script><link rel="stylesheet" href="/theme.css?v=20261109"></head><body>Theme</body></html>';
 const updated=themeDocument(old);
 assert.ok(updated.includes(`/theme.js?v=${themeVersion}`));
 assert.ok(updated.includes(`/theme.css?v=${themeVersion}`));
 assert.equal(updated.match(/data-oath-theme-bootstrap/g).length,1);
 assert.equal(themeDocument(updated),updated);
});

test('network cards use one borderless surface in both themes and retain a keyboard focus indicator',async()=>{
 const css=await readFile(new URL('../public/network-guides.css',import.meta.url),'utf8');
 const base=css.match(/\.network-card\{([^}]+)\}/)?.[1];
 assert.ok(base);
 assert.match(base,/background:var\(--oath-card\)/);
 assert.match(base,/border:0(?:;|$)/);
 assert.doesNotMatch(base,/inset/);
 assert.doesNotMatch(css,/\.network-card:nth-child/);
 assert.match(css,/focus-visible[^}]+outline:/);
 const [light,dark]=paletteCSS().split('\n');
 for(const token of ['--oath-surface','--oath-surface-hover','--oath-card-ink','--oath-card-muted']){
  const value=new RegExp(token+':(#[a-f0-9]{6});');
  assert.ok(value.test(light)&&value.test(dark),token);
  assert.notEqual(light.match(value)[1],dark.match(value)[1],token);
 }
});

test('the network and review carousels share a borderless control in both themes',async()=>{
 const homepage=await readFile(new URL('../public/index.html',import.meta.url),'utf8');
 for(const label of ['Previous networks','Next networks','Previous review','Next review']){
  const button=homepage.match(new RegExp('<button[^>]*aria-label="'+label+'"[^>]*>'))?.[0];
  assert.match(button,/class="carousel-arrow"/);
  assert.doesNotMatch(button,/ style(?:-hover)?=/);
 }
 const css=await readFile(new URL('../public/network-guides.css',import.meta.url),'utf8');
 const normal=css.match(/\.carousel-arrow\{([^}]+)\}/)?.[1];
 assert.match(normal,/background:var\(--oath-surface\)/);
 assert.match(normal,/border:0;/);
 assert.doesNotMatch(normal,/box-shadow/);
 assert.match(css,/\.carousel-arrow:hover[^}]*background:var\(--oath-surface-hover\)/);
 assert.match(css,/\.carousel-arrow:focus-visible[^}]+outline:/);
 for(const scheme of paletteCSS().split('\n').slice(0,2)){
  assert.ok(scheme.includes('--oath-card:var(--oath-surface);'));
  assert.ok(scheme.includes('--oath-card-hover:var(--oath-surface-hover);'));
 }
});

test('the Articles language selector leaves chevron and end spacing to the shared select rules',async()=>{
 const html=await readFile(new URL('../public/articles.html',import.meta.url),'utf8');
 const select=html.match(/<select\b[^>]*aria-label="Article language"[^>]*>/)?.[0];
 assert.ok(select,'The language selector must exist');
 const styles=select.match(/\bstyle="([^"]+)"/)?.[1]||'';
 assert.doesNotMatch(styles,/(?:^|;)\s*(?:background|background-image|padding|padding-inline-end)\s*:/i);
});
