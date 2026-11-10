// All public marketing and editorial documents render the canonical components.
// Pairing/deep-link and authenticated utility screens remain isolated.
import {readFile,writeFile,readdir} from 'node:fs/promises';
import {brandUrls} from './brand-urls.mjs';
import {buildSiteChrome} from './build-help-chrome.mjs';
const root=new URL('../public/',import.meta.url);
const chrome=await buildSiteChrome();
await writeFile(new URL('site-chrome.css',root),chrome.css);
const header=`<!-- oath-shared-header:start -->${chrome.header}<!-- oath-shared-header:end -->`;
const footer=`<!-- oath-shared-footer:start -->${chrome.footer}<!-- oath-shared-footer:end -->`;
async function files(dir){const entries=await readdir(dir,{withFileTypes:true});return (await Promise.all(entries.map(e=>e.isDirectory()?files(new URL(e.name+'/',dir)):[new URL(e.name,dir)]))).flat();}
let count=0;
for(const file of await files(root)){
 if(!file.pathname.endsWith('.html') || file.pathname.endsWith('.dc.html'))continue;
 let html=await readFile(file,'utf8');
 const marked=html.includes('<!-- oath-shared-header:start -->');
 const legacy=html.includes('<header class="site-header">');
 const core=html.includes('id="oath-server-content"');
 const notFound=file.pathname.endsWith('/404.html');
 if(!marked&&!legacy&&!core&&!notFound)continue;
 if(marked)html=html.replace(/<!-- oath-shared-header:start -->[\s\S]*?<!-- oath-shared-header:end -->/,header).replace(/<!-- oath-shared-footer:start -->[\s\S]*?<!-- oath-shared-footer:end -->/,footer);
 else if(legacy)html=html.replace(/<header class="site-header">[\s\S]*?<\/header>/,header).replace(/<footer class="site-footer">[\s\S]*?<\/footer>/,footer);
 else if(notFound)html=html.replace(/<body([^>]*)>/,`<body$1>${header}`).replace('</body>',`${footer}</body>`);
 // Core pages already render these components in their server fallback and
 // client enhancement. Do not insert a second header/footer around that shell.
 const stylesheet='/site-chrome.css';
 if(!html.includes(`href="${stylesheet}"`))html=html.replace('</head>',`<link rel="stylesheet" href="${stylesheet}"></head>`);
 if(!html.includes('src="/site-chrome.js"'))html=html.replace('</body>','<script src="/site-chrome.js" defer></script></body>');
 if(!html.includes('fonts.googleapis.com/css2?'))html=html.replace('</head>','<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Instrument+Serif:ital@0;1&amp;family=Instrument+Sans:wght@400;500;600&amp;family=IBM+Plex+Mono:wght@400;500&amp;display=swap"></head>');
 html=brandUrls(html);
 await writeFile(file,html);count++;
}
console.log(`Applied shared navigation and the complete network footer to ${count} public documents.`);
