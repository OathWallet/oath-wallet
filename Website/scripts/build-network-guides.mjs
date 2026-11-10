import {assetHeading, chainMark, directoryHeading, rowContents} from '../src/catalog-ui.js';
import {guidePreview} from '../src/xstock-guides.js';
import priorityGuidance from '../content/priority-guidance.json' with {type:'json'};
import {priorityHTML,priorityMarkdown,priorityOverviewHTML,priorityUpdated,priorityDescription} from '../src/seo-guidance.js';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {buildSiteChrome} from './build-help-chrome.mjs';
import catalog from '../content/networks.json' with {type:'json'};
const {networks,sourceCommit,reviewed}=catalog;
const root=new URL('../public/',import.meta.url);
const read=p=>readFile(new URL(p,root),'utf8');
const write=(p,v)=>writeFile(new URL(p,root),v);
const esc=v=>String(v).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;');
const json=v=>JSON.stringify(v).replaceAll('<','\\u003c');
const app='https://apps.apple.com/app/id6780187283';
const source=`https://github.com/OathWallet/oath-wallet/blob/${sourceCommit}/OathAtmosphere/Import/OathImportCatalog.swift`;
const scope='Features depend on the app version, network, wallet type and the service you connect to. Check the available actions in your installed app before transferring.';
const chrome=await buildSiteChrome();
const header='<a class="skip" href="#content">Skip to content</a><!-- oath-shared-header:start -->'+chrome.header+'<!-- oath-shared-header:end -->';
const footer='<!-- oath-shared-footer:start -->'+chrome.footer+'<!-- oath-shared-footer:end -->';
const sourceNote=`<p class="network-source">${scope} <a href="${source}">View the network catalog</a> · Updated ${reviewed}. Availability can differ between app releases.</p>`;
function page(title,description,path,body,schema={}){description=priorityDescription(path)||description;const url='https://oathwallet.org'+path;return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${esc(title)}</title><meta name="description" content="${esc(description)}"><meta name="robots" content="index,follow,max-image-preview:large"><link rel="canonical" href="${url}"><link rel="alternate" type="text/markdown" href="${path}.md"><link rel="icon" href="/favicon.svg"><link rel="stylesheet" href="/assets/fonts/oath-fonts.css"><link rel="stylesheet" href="/article.css"><link rel="stylesheet" href="/network-guides.css"><link rel="stylesheet" href="/seo-guidance.css"><link rel="stylesheet" href="/wallet-catalog.css"><script src="/network-guides.js" defer></script><meta property="og:type" content="website"><meta property="og:site_name" content="Oath Wallet"><meta property="og:title" content="${esc(title)}"><meta property="og:description" content="${esc(description)}"><meta property="og:url" content="${url}"><meta property="og:image" content="https://oathwallet.org${guidePreview(path)||'/og/home.png'}"><meta name="twitter:card" content="summary_large_image"><script type="application/ld+json">${json({'@context':'https://schema.org','@graph':[{'@type':'WebPage','@id':url,url,name:title,description,dateModified:priorityUpdated(path)||reviewed,isPartOf:{'@id':'https://oathwallet.org/#site'}},...schema.graph||[]]})}</script></head><body>${header}<main id="content" class="network-page wallet-catalog">${body}</main>${footer}</body></html>\n`;}
function card(n){return `<a class="network-card" href="/networks/${n.slug}" data-network-group="${esc(n.group)}" data-network-keywords="${esc(n.name+' '+n.symbol+' '+n.group+(n.id==='ton'?' TON Toncoin':'')+' '+n.id)}"><img src="${n.icon}" alt="" width="56" height="56" loading="lazy"><div><div class="network-card-meta">${esc(n.symbol)} · ${esc(n.group)}</div><h3 class="network-card-title">${esc(n.name)}</h3></div><p class="network-card-copy">${n.walletConnect?'Send, receive and connect to compatible dApps.':'Send and receive with Oath.'}</p><span class="network-card-link">Explore ${esc(n.name)}</span></a>`;}
const slider=`<!-- oath-networks:start --><section id="ton" class="network-showcase" aria-labelledby="network-heading"><div class="network-head"><div><span class="network-kicker">Your assets. Your networks.</span><h2 id="network-heading">Find your network.<br><em>Make it yours.</em></h2><p class="network-intro">From Bitcoin to Gram, find the right address, understand the fee and explore how to connect.</p></div><div class="network-controls"><button class="network-arrow" onClick="{{ networkPrev }}" aria-label="Previous networks" aria-controls="network-track">←</button><button class="network-arrow" onClick="{{ networkNext }}" aria-label="Next networks" aria-controls="network-track">→</button></div></div><div id="network-track" class="network-track" ref="{{ r.networkTrack }}" role="region" aria-label="Supported networks, scroll to explore" tabindex="0" onKeyDown="{{ networkKey }}">${networks.map(card).join('')}</div></section><!-- oath-networks:end -->`;
let home=await read('index.html');
if(home.includes('<!-- oath-networks:start -->'))home=home.replace(/<!-- oath-networks:start -->[\s\S]*?<!-- oath-networks:end -->/,slider);
else home=home.replace(/  <section id="ton"[\s\S]*?<\/section>/,slider);
if(!home.includes('href="/network-guides.css"'))home=home.replace('</head>','<link rel="stylesheet" href="/network-guides.css"><link rel="stylesheet" href="/seo-guidance.css"></head>');
if(!home.includes('networkTrack: React.createRef()'))home=home.replace('revTrack: React.createRef()','revTrack: React.createRef(), networkTrack: React.createRef()');
if(!home.includes('scrollNetworks(direction)'))home=home.replace('  revTo(i) {',`  scrollNetworks(direction) {
    const el = this.r.networkTrack.current; if (!el) return;
    const card = el.querySelector('.network-card'); if (!card) return;
    const distance = card.getBoundingClientRect().width + 20;
    el.scrollBy({ left: direction * distance, behavior: window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' });
  }

  revTo(i) {`);
if(!home.includes('networkNext:'))home=home.replace('      revGo: null,',`      networkNext: () => this.scrollNetworks(1),
      networkPrev: () => this.scrollNetworks(-1),
      networkKey: e => { if (e.target !== e.currentTarget) return; if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') { e.preventDefault(); this.scrollNetworks(e.key === 'ArrowRight' ? 1 : -1); } },
      revGo: null,`);
if(!home.includes("window.location.hash === '#ton'"))home=home.replace('  componentDidMount() {',"  componentDidMount() {\n    if (window.location.hash === '#ton') requestAnimationFrame(() => document.getElementById('ton')?.scrollIntoView({behavior:'instant',block:'start'}));");
await write('index.html',home);
let homeMD=await read('index.md');
homeMD=homeMD.replace(/## TON(?: in Oath Wallet|, in your wallet)[\s\S]*?(?=\n## |\n<!--|$)/,'');
const networkLinks='<!-- oath-network-links:start -->\n## Find your network\n\nExplore send, receive and compatible dApp guidance for each network. Gram is the native coin of the TON blockchain.\n\n'+networks.map(n=>`- [${n.name}: send, receive and connection guide](https://oathwallet.org/networks/${n.slug})`).join('\n')+'\n\n[Oath on TON App](https://ton.app/app/oath-wallet)\n<!-- oath-network-links:end -->';
if(homeMD.includes('<!-- oath-network-links:start -->'))homeMD=homeMD.replace(/<!-- oath-network-links:start -->[\s\S]*?<!-- oath-network-links:end -->/,networkLinks);
else homeMD=homeMD.trimEnd()+'\n\n'+networkLinks+'\n';
homeMD=homeMD.replace(/\n{3,}/g,'\n\n');
await write('index.md',homeMD);
await mkdir(new URL('networks/',root),{recursive:true});
for(const n of networks){
 const title=`${n.name} Wallet: Send & Receive ${n.symbol} on iPhone | Oath`;
 const description=`Learn how to receive ${n.name}, send ${n.symbol}, review network fees and check dApp connection support in Oath Wallet for iPhone and iPad.`;
 const receive=[`Open Oath, select your wallet and choose ${n.name} in Receive.`,`Copy the receiving address or show its QR code. Confirm the exact network with the sender.`,n.receive,'After the sender broadcasts the transfer, follow its status in Oath. Network confirmation can take time.'];
 const send=[`Open Send and select the asset on ${n.name}. Paste the recipient’s address or scan their QR.`,n.send,'Enter the amount and any required memo or tag. Compare the complete destination with the recipient’s instructions.','Review the asset, network, amount and fee, then confirm in Oath. Follow the transaction status after broadcast.'];
 const connect=n.walletConnect?['Open a trusted dApp and choose Oath if it is listed, or choose WalletConnect.','On desktop, scan the connection QR with Oath. On iPhone or iPad, use a compatible app link or the connection option offered by the dApp.',`Review the website, selected wallet, ${n.name} network and requested permissions before approving.`,'Review each signing request separately. Disconnect the session from Oath when you are finished.']:[];
 const steps=(title,items,id)=>`<section id="${id}" class="wallet-steps"><h2>${esc(title)}</h2>${items.length?'<ol>'+items.map(s=>'<li>'+esc(s)+'</li>').join('')+'</ol>':'<p>'+esc(n.connection)+'</p>'}</section>`;
 const faq=[
 [`How do I receive ${n.name} in Oath?`,receive[0]+' '+receive[1]+' '+n.receive],
 [`What pays the ${n.name} transaction fee?`,`${n.symbol} is the native fee asset for this network account. ${n.send}`],
 [`Can I connect ${n.name} dApps?`,n.connection],
 ['Can I send to the same address on another network?','Only send using the network the recipient explicitly supports. A matching address or ticker does not bridge assets or make different chains interchangeable.'],
 ];
 if(n.id==='bitcoincash')faq.splice(faq.findIndex(([q])=>q.startsWith('Can I connect')),1);
 if(n.id==='ton')faq.unshift(['Is Gram the same as TON?','Gram (GRAM) is the native coin formerly called Toncoin. The blockchain remains The Open Network (TON). Confirm you are selecting the native coin, not a similarly named jetton.']);
 const related=networks.filter(x=>x.id!==n.id&&x.group===n.group).slice(0,4);
 const overview=priorityOverviewHTML('/networks/'+n.slug);
 const receiving=steps('Receive '+n.name,receive,'receive');
 const identity=`<aside class="wallet-panel"><h2>Network details</h2><dl><dt>Native asset</dt><dd>${esc(n.symbol)}</dd><dt>Network family</dt><dd>${esc(n.group)}</dd>${n.chainId?`<dt>Chain ID</dt><dd><code>${n.chainId}</code></dd>`:''}</dl><a class="token-button" href="${app}">Get Oath for iOS</a><!-- wallet-token-directory:start --><!-- wallet-token-directory:end --></aside>`;
 const body=`<nav class="network-crumbs" aria-label="Breadcrumb"><a href="/">Home</a><span>/</span><a href="/networks">Networks</a><span>/</span><span aria-current="page">${esc(n.name)}</span></nav>
 ${assetHeading(chainMark(n,64),n.name,n.symbol+' · '+n.group)}
 ${n.id==='tron'?'<nav class="receive-choices" aria-label="Choose an asset to receive"><a href="#receive">Receive TRX</a><a href="/tokens/usdt/tron">Receive USDT on TRON</a></nav>':''}
 <div class="wallet-split network-first"><div>${overview||receiving}</div>${identity}</div>
 <nav class="wallet-anchors" aria-label="On this page"><a href="#receive">Receive</a><a href="#send">Sending and fees</a><!-- catalog-link:start --><!-- catalog-link:end -->${n.walletConnect?'<a href="#dapps">dApp connections</a>':''}<a href="#questions">Questions</a></nav>
 ${overview?receiving:''}${steps('Send '+n.symbol+' and pay network fees',send,'send')}
 <!-- wallet-featured-tokens -->
 ${steps(n.walletConnect?'Connect to dApps':'Connection availability',connect,'dapps')}
 <section class="network-faq" id="questions"><h2>Questions</h2>${faq.map(([q,a])=>`<details><summary>${esc(q)}</summary><p>${esc(a)}</p></details>`).join('')}</section>
 <div class="network-note"><strong>Keep recovery details private.</strong><p>Oath’s website never needs your recovery phrase or private key. Share only the receiving address when someone needs to send you crypto.</p><a href="https://help.oathwallet.org/articles/receive-crypto">Read the receiving guide</a>${n.id==='ton'?'<p><a href="https://ton.org/">About Gram and TON</a> · <a href="https://ton.app/app/oath-wallet">Oath on TON App</a></p>':''}</div>
 ${priorityHTML('/networks/'+n.slug)}${sourceNote}
 <nav class="wallet-anchors" aria-label="Explore related guides">${related.map(x=>`<a href="/networks/${x.slug}">${esc(x.name)}</a>`).join('')}<a href="/networks">All networks</a><a href="/tokens">All tokens</a></nav>`;
 const breadcrumb={'@type':'BreadcrumbList',itemListElement:[{name:'Home',item:'https://oathwallet.org/'},{name:'Networks',item:'https://oathwallet.org/networks'},{name:n.name,item:`https://oathwallet.org/networks/${n.slug}`}].map((x,i)=>({'@type':'ListItem',position:i+1,...x}))};
 await write(`networks/${n.slug}.html`,page(title,description,`/networks/${n.slug}`,body,{graph:[breadcrumb]}));
 const md=`# ${n.name} wallet: send and receive ${n.symbol}\n\n${n.intro}\n\n## Receive ${n.name}\n\n${receive.map((x,i)=>`${i+1}. ${x}`).join('\n')}\n\n## Send ${n.symbol}\n\n${send.map((x,i)=>`${i+1}. ${x}`).join('\n')}\n\n## dApp connections\n\n${n.connection}\n\n${connect.map((x,i)=>`${i+1}. ${x}`).join('\n')}\n\n## Questions\n\n${faq.map(([q,a])=>`### ${q}\n\n${a}`).join('\n\n')}\n\n${scope}\n\n[Network catalog](${source}) · Updated ${reviewed}. Source review is not confirmation of App Store availability.\n\n[Get Oath for iPhone and iPad](${app}) · [All networks](https://oathwallet.org/networks)\n`;
 await write(`networks/${n.slug}.md`,md+priorityMarkdown("/networks/"+n.slug));
}
const groups=[...new Set(networks.map(n=>n.group))];
const featured=['bitcoin','ethereum','solana','tron','sui','bitcoincash'].map(id=>networks.find(n=>n.id===id)).filter(Boolean);
function directoryCard(n){
 const keywords=[n.name,n.symbol,n.group,n.id,n.id==='ton'?'TON Toncoin':''].join(' ');
 return `<a class="network-directory-row" href="/networks/${n.slug}" data-network-group="${esc(n.group)}" data-network-keywords="${esc(keywords)}">${rowContents(chainMark(n,40,{lazy:true}),n.name,n.group,'<span class="network-ticker">'+esc(n.symbol)+'</span>')}</a>`;
}
const directory=`${directoryHeading('Networks',networks.length+' network guides for receiving, sending and fees','Networks')}
 <section id="browse-networks" aria-label="Browse networks">
 <div class="network-controls-panel" data-network-controls hidden>
 <label for="network-search" class="catalog-sr">Search networks</label><input class="wallet-search-input" type="search" id="network-search" data-network-search placeholder="Search by network name or symbol" autocomplete="off" aria-controls="network-results">
 <div class="directory-filters" role="group" aria-label="Filter networks"><button type="button" data-network-filter="all" aria-pressed="true">All</button>${groups.map(g=>`<button type="button" data-network-filter="${esc(g)}" aria-pressed="false">${esc(g)}</button>`).join('')}</div></div>
 <nav class="featured-networks" data-network-featured aria-label="Featured network guides">${featured.map(n=>`<a class="network-tile" href="/networks/${n.slug}">${chainMark(n,44)}<strong>${esc(n.name)}</strong><span>${esc(n.symbol)}</span></a>`).join('')}</nav>
 <div class="results-heading"><h2>All networks</h2><span data-network-count aria-live="polite">${networks.length} networks</span></div>
 <div class="network-directory-list" id="network-results">${networks.map(directoryCard).join('')}</div>
 <div class="catalog-empty" data-network-empty hidden><h3>No networks found</h3><p>Try another name or symbol.</p><button type="button" class="token-button" data-network-reset>Show all networks</button></div></section>
 <nav class="wallet-anchors" aria-label="Transfer planning"><a href="/networks/choose-token-network">Choose a USDT or USDC network</a><a href="/networks/fees">Find the fee asset</a><a href="https://help.oathwallet.org/articles/receive-crypto">Receiving guide</a></nav>${sourceNote}`;
await write('networks.html',page('Supported Crypto Networks & Wallet Guides | Oath','Explore Oath’s supported networks. Learn to send and receive Bitcoin, Ethereum, Gram and more, and check compatible dApp connections.','/networks',directory));
await write('networks.md',`# Oath Wallet Supported Networks\n\n${scope}\n\n${networks.map(n=>`- [${n.name} — ${n.symbol}](https://oathwallet.org/networks/${n.slug}): send, receive${n.walletConnect?' and compatible WalletConnect dApps':''}.`).join('\n')}\n\nGram is the native coin of the TON blockchain, formerly known as Toncoin.\n\n## Source and availability\n\nThis ${networks.length}-network catalog was checked ${reviewed} against [the public app source](${source}). Availability can differ between app releases.\n`);
console.log(`Built ${networks.length} network guides, directory and manual homepage carousel.`);

let networkMD=await read('networks.md');
networkMD+='\n## Plan a transfer\n\n[Choose a USDT or USDC network](https://oathwallet.org/networks/choose-token-network) · [Find your fee asset](https://oathwallet.org/networks/fees)\n';
await write('networks.md',networkMD);
