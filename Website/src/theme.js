// The legacy site uses several template renderers. This shared palette adapter
// gives their CSS the same semantic appearance without changing image pixels.
// Match OathNeutralColors in OathAtmosphere/OathColorway.swift: white canvas,
// #F0F0F0 fields. Neutral labels approximate native light appearance.
export const palette = {
 '0d0d0f':'f0f0f0','131315':'f0f0f0','1b1b1f':'f0f0f0','2b2b2e':'d5d5d5','444448':'d5d5d5','83838e':'636363','88888f':'636363','888890':'636363','888892':'636363','8f8f99':'636363','92929c':'636363','97979f':'636363','9999a1':'636363','9db9ff':'494949','a2a2aa':'636363','a9a9ae':'636363','a9a9b1':'636363','aaa9ae':'636363','aaaab4':'636363','b5b5bc':'494949','bcce98':'494949','bdbdc2':'494949','c3d2f4':'494949','c4c1b8':'494949','c8c7c2':'494949',
 '0a0a0b':'ffffff','0b0b0d':'ffffff','000000':'ffffff','111111':'f0f0f0',
 '111112':'f0f0f0','111113':'f0f0f0','101011':'f0f0f0','141416':'f0f0f0',
 '151516':'f0f0f0','151517':'f0f0f0','171719':'f0f0f0','181819':'f0f0f0','19191a':'f0f0f0','1a1a1d':'ebebeb',
 '1b1b1c':'e8e8e8','1b1b1e':'e8e8e8','202023':'e5e5e5','242425':'e2e2e2',
 '242426':'e2e2e2','242427':'e2e2e2','282829':'d9d9d9','303034':'d2d2d2',
 '333333':'d5d5d5','333337':'d5d5d5','393938':'c4c4c4','39393d':'c4c4c4',
 '434340':'b7b7b7','f2f0ea':'000000','ffffff':'000000','eeece6':'252525',
 'd6d4cd':'3c3c3c','d6d3cd':'3c3c3c','c5c3bd':'494949','b9b7b0':'555555',
 'a5a39d':'636363','aaa8a2':'636363','aaaaaa':'636363','96948c':'666666',
 '8e8c86':'6b6b6b','6e6c67':'737373','777777':'737373','77756f':'737373',
 '62605a':'b9b9b9','383735':'d6d6d6',
 '1a1c19':'edf2e9','353b32':'c7d3bf','d4decf':'35462e','bdc5b9':'4d5e46',
 'b8d2bc':'315d3b','edbaab':'8c3d26','ed9c8c':'983a27','91caa8':'286341',
 '6da7ff':'175fc2','b7d5ff':'174c9b','b3c6ff':'314ea5'
};
function expanded(hex) {
 return hex.length===3||hex.length===4 ? [...hex].map(c=>c+c).join('') : hex;
}
const rgb = hex => [0,2,4].map(i=>parseInt(hex.slice(i,i+2),16)).join(',');
export const dayPalette={
 '25432f':'e5eddf','274420':'e5eddf','294e35':'e5eddf','304c27':'e5eddf','314635':'e5eddf','31543b':'e5eddf','344f38':'e5eddf','345a3f':'e5eddf','3c443c':'e5eddf','3c5630':'e5eddf','3c5d2e':'e5eddf','3f5034':'e5eddf','406547':'e5eddf','41643c':'e5eddf','424f3c':'e5eddf','45754d':'e5eddf','46563c':'e5eddf','4a6439':'e5eddf','4b7040':'e5eddf','4c5945':'e5eddf','4d5f42':'e5eddf','516340':'e5eddf','536049':'e5eddf','536e45':'e5eddf','566944':'e5eddf','596a40':'e5eddf','596e46':'e5eddf','5b7447':'e5eddf','647754':'e5eddf','65834e':'e5eddf','678151':'e5eddf','687761':'bdc9b6','6b7566':'bdc9b6','6b8057':'bdc9b6','6c7b42':'e5eddf','71865f':'bdc9b6','72905c':'bdc9b6','738168':'bdc9b6','748468':'bdc9b6','758e5d':'bdc9b6','793e2a':'e5eddf','7a8276':'bdc9b6','7ba46a':'bdc9b6','7c8a70':'bdc9b6','7c8d6d':'bdc9b6','7e8f5f':'bdc9b6','7e916c':'bdc9b6','81916e':'bdc9b6','838d7a':'bdc9b6','859679':'bdc9b6','869875':'bdc9b6','87927c':'bdc9b6','88a66c':'bdc9b6','8a936f':'bdc9b6','8a9384':'bdc9b6','8b9385':'bdc9b6','8b9580':'bdc9b6','8b977d':'bdc9b6','8b9a7b':'bdc9b6','8c7148':'bdc9b6','8c987e':'bdc9b6','8c9f70':'bdc9b6','8d9a7d':'bdc9b6','8d9b7f':'bdc9b6','8e9688':'bdc9b6','90ac73':'bdc9b6','91a27f':'bdc9b6','929c86':'bdc9b6','939b8d':'bdc9b6','93a281':'bdc9b6','94a382':'bdc9b6','95a187':'bdc9b6','96b782':'bdc9b6','97a888':'bdc9b6','9a664c':'bdc9b6','9aa191':'bdc9b6','9aa38f':'bdc9b6','9aa58c':'bdc9b6','9aaa8f':'bdc9b6','9b8451':'bdc9b6','9ba591':'bdc9b6','9ba98d':'bdc9b6','9ca58f':'bdc9b6','9d8a68':'bdc9b6','9e3826':'e5eddf','9eab92':'bdc9b6','9fac92':'bdc9b6','a0a995':'bdc9b6','a0ab93':'bdc9b6','a0ac92':'bdc9b6','a1ac96':'bdc9b6','a1af92':'bdc9b6','a2724b':'bdc9b6','a27657':'bdc9b6','a2ad97':'bdc9b6','a2ae96':'bdc9b6','a2ae98':'bdc9b6','a2b78a':'bdc9b6','a4ac9c':'bdc9b6','a4aca1':'bdc9b6','a5b293':'bdc9b6','a6b492':'bdc9b6','a7b29c':'bdc9b6','a8bd8d':'bdc9b6','a9b19d':'bdc9b6','aa7051':'bdc9b6','aabd94':'bdc9b6','b5c59e':'bdc9b6','bc995d':'bdc9b6','bccaaa':'414e3d','bdcdb6':'414e3d','becdb4':'414e3d','c69b86':'bdc9b6','ccd5c7':'1b241c','cedabd':'414e3d','d2dacb':'1b241c','d4dcc8':'1b241c','d9e2cb':'1b241c','dbe8cd':'1b241c','dce3d6':'1b241c','dde3d7':'1b241c','dfe5ce':'1b241c','e0e7d8':'1b241c','e2e9d6':'1b241c','e3ead9':'1b241c','e5eacb':'1b241c','e7eedf':'1b241c','e9eedf':'1b241c','e9efdf':'1b241c','ead9c5':'1b241c','ece1c0':'1b241c','ede2c8':'1b241c','edece5':'1b241c','edf2e5':'1b241c','edf4e5':'1b241c','eed8c8':'1b241c','eef2e8':'1b241c','eef3e6':'1b241c','f0f3eb':'1b241c','f0f4e9':'1b241c','f0f4eb':'1b241c','f1f3e8':'1b241c','f1f4eb':'1b241c','f1f4ed':'1b241c','f3f4f0':'1b241c','f3f6ed':'1b241c','f4f6ee':'1b241c','f8faf3':'1b241c','f9f4e6':'1b241c','fafcf6':'1b241c','fcf0e8':'1b241c','fcf6e9':'1b241c','fcf6eb':'1b241c',
 'ffffff':'0a0a0b','fafbf7':'0a0a0b','f6f7f3':'111112','edf2e7':'1b241c','e8eee3':'18221b','e7ebe3':'243025','edf0e8':'242d25','f0f3e9':'202820','f2f2f7':'1c1c1f','e5e5ea':'303034',
 '111111':'f2f0ea','25312a':'f2f0ea','1d2921':'f2f0ea','1b3023':'f2f0ea','314a36':'d6e0d1','475640':'c2cdbb','57655b':'b9c5b5','61705f':'b9c5b5','6e7b66':'b9c5b5','788077':'aab6a4','7c847c':'aab6a4','68686e':'b9b7b0','777777':'aab6a4',
 'd5dbd2':'394237','b8c5b1':'414e3d','e1e6dc':'353e32','2c4d35':'b4d3a8','a74630':'f1b3a3'
};
export function themeCSS(css,day=false) {
 const colors=day?dayPalette:palette;
 const prefix=day?'oath-day':'oath';
 return css.replace(/color-scheme\s*:\s*(?:dark|light)\b/g,'color-scheme:var(--oath-color-scheme)')
 .replace(/#[\da-f]{3,8}\b|rgba?\(\s*\d+\s*,\s*\d+\s*,\s*\d+(?:\s*,\s*[\d.]+)?\s*\)/gi, color=>{
  let hex,alpha;
  if(color[0]==='#') {const full=expanded(color.slice(1).toLowerCase());hex=full.slice(0,6);if(full.length===8)alpha=+(parseInt(full.slice(6),16)/255).toFixed(4);}
  else {const values=color.match(/[\d.]+/g);hex=values.slice(0,3).map(n=>(+n).toString(16).padStart(2,'0')).join('');alpha=values[3];}
  if(!colors[hex] || (hex==='000000'&&alpha!==undefined))return color; // Shadows stay shadows.
  return alpha===undefined?`var(--${prefix}-c-${hex})`:`rgba(var(--${prefix}-rgb-${hex}),${alpha})`;
 }).replace(/((?:^|[;{])\s*(?:color|background(?:-color)?|border-color)\s*:\s*)(white|black)(?=\s*(?:[;}]|$))/gi,(_,prefix,color)=>prefix+`var(--${day?'oath-day':'oath'}-c-${color.toLowerCase()==='white'?'ffffff':'111111'})`);
}
export const themeVersion='20261110-cards';
export function themeDocument(html,{bootstrap=true}={}) {
 html=html.replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi,block=>themeCSS(block))
 .replace(/\sstyle(?:-hover)?=(['"])([\s\S]*?)\1/gi,(attribute,quote,value)=>attribute.replace(value,themeCSS(value)))
 .replace(/<script\b[^>]*data-dc-script[^>]*>[\s\S]*?<\/script>/gi,block=>block.replace(/(['"])(#[\da-f]{3,8}|rgba?\([\d., ]+\))\1/gi,(_,q,color)=>q+themeCSS(color)+q));
 if(!bootstrap||!/<head\b/i.test(html)||!/<body\b/i.test(html))return html;
 if(!html.includes('data-oath-theme-bootstrap'))html=html.replace(/<head([^>]*)>(\s*<meta\s+charset=[^>]+>)?/i,`<head$1>$2<script data-oath-theme-bootstrap src="/theme.js?v=${themeVersion}"></script><link rel="stylesheet" href="/theme.css?v=${themeVersion}">`);
 // Generated documents may already contain the bootstrap from an earlier build.
 // Refresh both URLs so returning visitors receive the same shared control styles.
 html=html.replace(/((?:src|href)=["'])\/theme\.(js|css)\?v=[^"']+(?=["'])/g,`$1/theme.$2?v=${themeVersion}`);
 // Theme color follows the selected appearance; the pre-paint bootstrap adds it.
 return html.replace(/<meta\s+name=['"]theme-color['"][^>]*>/gi,'');
}
// Already-light utility pages share the same neutral surfaces and labels.
const lightUtilityPalette = {
 'fafbf7':'ffffff','f6f7f3':'f0f0f0','edf2e7':'f0f0f0','e8eee3':'f0f0f0',
 'e7ebe3':'ebebeb','edf0e8':'f0f0f0','f0f3e9':'f0f0f0','f2f2f7':'f0f0f0','e5e5ea':'e5e5e5',
 '25312a':'000000','1d2921':'000000','1b3023':'000000','475640':'494949',
 '57655b':'636363','61705f':'636363','6e7b66':'636363','788077':'737373',
 '7c847c':'737373','d5dbd2':'d5d5d5','e1e6dc':'e5e5e5'
};
export function paletteCSS() {
 const dayValues=light=>Object.entries(dayPalette).map(([day,dark])=>{const color=light?(lightUtilityPalette[day]||day):dark;return `--oath-day-c-${day}:#${color};--oath-day-rgb-${day}:${rgb(color)};`;}).join('');
 const values = light=>Object.entries(palette).map(([dark,day])=>`--oath-c-${dark}:#${light?day:dark};--oath-rgb-${dark}:${rgb(light?day:dark)};`).join('');
 return `:root{--oath-color-scheme:light;color-scheme:light;--oath-card:#f6f7f8;--oath-card-hover:#eceef0;--oath-card-ink:#202227;--oath-card-muted:#555a62;${values(true)}${dayValues(true)}}\n:root[data-oath-theme="dark"]{--oath-color-scheme:dark;color-scheme:dark;--oath-card:#1b1c1e;--oath-card-hover:#242629;--oath-card-ink:#f3f4f6;--oath-card-muted:#b2b6be;${values(false)}${dayValues(false)}}\n/* Product screenshots and press-kit specimens retain their exact brand colors. */\n:is([data-preview-device],.press-art,.press-swatch,.press-cover,.press-demonstrations,.press-donts){${values(false)}}\n`;
}
export function formControlCSS() {
 const arrow=color=>`url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='16' height='16' viewBox='0 0 16 16'%3E%3Cpath d='m4 6 4 4 4-4' fill='none' stroke='%23${color}' stroke-width='1.5' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E")`;
 // Keep real select controls and native menus. Reserve room for the chevron
 // independently of browser-native arrow positioning and page padding rules.
 const select=':root select:not([multiple]):not([size]),:root select:not([multiple])[size="1"]';
 return `:root{--oath-select-arrow:${arrow('636363')}}
:root[data-oath-theme="dark"]{--oath-select-arrow:${arrow('b9b7b0')}}
${select}{-webkit-appearance:none;appearance:none;padding-inline-end:44px;background-image:var(--oath-select-arrow);background-repeat:no-repeat;background-position:right 14px center;background-size:16px 16px}
:is(${select}):dir(rtl){background-position:left 14px center}
@media(forced-colors:active){${select}{-webkit-appearance:auto;appearance:auto;background-image:none;padding-inline-end:12px}}
`;
}
export async function applyTheme(request,response) {
 const pathname=new URL(request.url).pathname;
 let decodedPath=pathname;try{decodedPath=decodeURIComponent(pathname);}catch{}
 if(decodedPath.endsWith('/Oath App Home.dc.html')||/\/yandex_[a-f0-9]+\.html$/.test(pathname))return response;
 if(request.method==='HEAD'||response.body===null||!response.headers.get('Content-Type')?.includes('text/html'))return response;
 const html=await response.text();
 const headers=new Headers(response.headers);headers.delete('Content-Length');headers.delete('ETag');
 return new Response(themeDocument(html,{bootstrap:!decodedPath.endsWith('.dc.html')}),{status:response.status,statusText:response.statusText,headers});
}
