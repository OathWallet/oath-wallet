import {readFile,writeFile,readdir} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {themeCSS,themeDocument,paletteCSS} from '../src/theme.js';
const root=new URL('../public/',import.meta.url);
async function walk(dir){return(await Promise.all((await readdir(dir,{withFileTypes:true})).filter(e=>!e.name.startsWith('._')&&e.name!=='assets').map(e=>e.isDirectory()?walk(new URL(e.name+'/',dir)):[new URL(e.name,dir)]))).flat();}
for(const file of await walk(root)){
 if(file.pathname.endsWith('/Oath%20App%20Home.dc.html')||decodeURI(file.pathname).endsWith('/Oath App Home.dc.html')||file.pathname.endsWith('/theme.css'))continue;
 if(!/\.(html|css)$/.test(file.pathname)||/\/yandex_[a-f0-9]+\.html$/.test(file.pathname))continue;
 const original=await readFile(file,'utf8');
 const output=file.pathname.endsWith('.css')?themeCSS(original,/\/(?:news\/admin|newsletter|wallet-open)\.css$/.test(file.pathname)):themeDocument(original,{bootstrap:!file.pathname.endsWith('.dc.html')});
 if(output!==original)await writeFile(file,output);
}
await writeFile(new URL('theme.css',root),paletteCSS()+`\n.oath-theme-switch{display:inline-flex;align-items:center;gap:4px;padding:4px;border:1px solid rgba(var(--oath-rgb-f2f0ea),.16);border-radius:999px;width:fit-content;background:var(--oath-c-141416)}
.oath-theme-switch button{display:inline-flex;align-items:center;justify-content:center;gap:8px;min-height:40px;padding:10px 16px;border:0;border-radius:999px;background:transparent;color:var(--oath-c-b9b7b0);font:500 13px/1.2 'Instrument Sans',sans-serif;cursor:pointer}
.oath-theme-switch button[aria-pressed=true]{background:var(--oath-c-f2f0ea);color:var(--oath-c-0a0a0b)}
.oath-theme-switch button:focus-visible{outline:2px solid var(--oath-c-f2f0ea);outline-offset:3px}
.oath-theme-switch svg{width:16px;height:16px;fill:none;stroke:currentColor;stroke-width:1.6}
/* Brand actions keep white labels on Oath blue or dark green. */
.on-submit,.on-success a,.button.primary{--oath-day-c-ffffff:#ffffff;--oath-day-c-25432f:#25432f;--oath-day-c-345a3f:#345a3f;--oath-day-c-406547:#406547;--green:#2c4d35}
.on-launcher{--oath-day-c-edece5:#edece5;--oath-day-c-314635:#314635;--oath-day-c-3c443c:#3c443c}
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
