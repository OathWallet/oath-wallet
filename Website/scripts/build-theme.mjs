import {readFile,writeFile,readdir} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {themeCSS,themeDocument,paletteCSS,formControlCSS} from '../src/theme.js';
const root=new URL('../public/',import.meta.url);
async function walk(dir){return(await Promise.all((await readdir(dir,{withFileTypes:true})).filter(e=>!e.name.startsWith('._')&&e.name!=='assets').map(e=>e.isDirectory()?walk(new URL(e.name+'/',dir)):[new URL(e.name,dir)]))).flat();}
for(const file of await walk(root)){
 if(file.pathname.endsWith('/Oath%20App%20Home.dc.html')||decodeURI(file.pathname).endsWith('/Oath App Home.dc.html')||file.pathname.endsWith('/theme.css'))continue;
 if(!/\.(html|css)$/.test(file.pathname)||/\/yandex_[a-f0-9]+\.html$/.test(file.pathname))continue;
 const original=await readFile(file,'utf8');
 const output=file.pathname.endsWith('.css')?themeCSS(original,/\/(?:news\/admin|newsletter|wallet-open)\.css$/.test(file.pathname)):themeDocument(original,{bootstrap:!file.pathname.endsWith('.dc.html')});
 if(output!==original)await writeFile(file,output);
}
await writeFile(new URL('theme.css',root),paletteCSS()+formControlCSS()+`\n.oath-theme-switch{display:inline-flex;align-items:center;gap:4px;padding:4px;border:0;border-radius:999px;width:fit-content;background:var(--oath-surface)}
.oath-theme-switch button{display:inline-flex;align-items:center;justify-content:center;gap:8px;min-height:40px;padding:10px 16px;border:0;border-radius:999px;background:transparent;color:var(--oath-c-b9b7b0);font:500 13px/1.2 'Instrument Sans',sans-serif;cursor:pointer}
.oath-theme-switch button:hover{background:var(--oath-surface-hover)}
.oath-theme-switch button[aria-pressed=true]{background:var(--oath-c-f2f0ea);color:var(--oath-c-0a0a0b)}
.oath-theme-switch button:focus-visible{outline:2px solid var(--oath-c-f2f0ea);outline-offset:3px}
.oath-theme-switch svg{width:16px;height:16px;fill:none;stroke:currentColor;stroke-width:1.6}
/* Card surfaces are independent of the canvas, input fields and product artwork. */
.oath-card{background:var(--oath-card);color:var(--oath-card-ink);border:0;box-shadow:none}
:is(a,button).oath-card:hover,.oath-card[aria-pressed=true]{background:var(--oath-card-hover)}
.oath-card[aria-pressed=true]{color:var(--oath-c-6da7ff)}
:is(a,button).oath-card:focus-visible{outline:2px solid currentColor;outline-offset:4px}
/* Brand actions keep white labels on Oath blue or dark green. */
.button.primary{--oath-day-c-ffffff:#ffffff;--oath-day-c-25432f:#25432f;--oath-day-c-345a3f:#345a3f;--oath-day-c-406547:#406547;--green:#2c4d35}
@media print{.oath-theme-switch{display:none}}
`);
const articleHash=createHash('sha256').update(await readFile(new URL('article.css',root))).digest('hex').slice(0,12);
for(const file of await walk(root)){
 if(!file.pathname.endsWith('.html'))continue;
 const original=await readFile(file,'utf8');
 const updated=original.replace(/article\.css\?v=[a-f0-9]+/g,'article.css?v='+articleHash);
 if(updated!==original)await writeFile(file,updated);
}
console.log('Built shared light/dark appearance across website documents.');
