import {xstockReviewDate} from './xstock-guides.js';
import guidance from '../content/priority-guidance.json' with {type:'json'};
const h=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const absolute=url=>url.startsWith('/')?'https://oathwallet.org'+url:url;
export const priorityUpdated=path=>guidance.pages[path]?.updated||(guidance.pages[path]?guidance.updated:xstockReviewDate(path));
export const priorityDescription=path=>guidance.pages[path]?.description;
const images=p=>p.images||(p.image?[p.image]:[]);
const figure=image=>`<figure><a href="${h(image.path)}" aria-label="View full screenshot: ${h(image.alt)}"><img src="${h(image.path)}" alt="${h(image.alt)}" width="${image.width||1320}" height="${image.height||2868}" loading="lazy" decoding="async"></a><figcaption><strong>${h(image.version)} · App screenshot.</strong> ${h(image.caption)}</figcaption></figure>`;
const gallery=p=>images(p).length?`<div class="guidance-gallery">${images(p).map(figure).join('')}</div>`:'';
const attribution=p=>`Guidance reviewed for Oath ${h(p.version||guidance.version)} (${p.build||guidance.build}) · Updated ${h(p.updated||guidance.updated)}. <a href="https://oathwallet.org/about#editorial">How we review guides</a>.`;

// The practical answer and versioned app evidence appear before the detailed guide.
// Existing secondary guidance keeps its original layout and review date.
export function priorityOverviewHTML(path){
 const p=guidance.pages[path];if(!p?.overview)return '';
 const o=p.overview;
 return `<section class="oath-guidance oath-guidance-overview" aria-labelledby="priority-overview" data-priority-reviewed="${h(p.updated)}"><div><p class="guidance-kicker">In Oath · ${h(p.version)}</p><h2 id="priority-overview">${h(o.title)}</h2><p class="guidance-answer">${h(o.answer)}</p><dl class="guidance-facts">${o.facts.map(f=>`<div><dt>${h(f.label)}</dt><dd>${h(f.text)}</dd></div>`).join('')}</dl><div class="guidance-example"><h3>${h(o.example.title)}</h3><p>${h(o.example.text)}</p>${o.action?`<p><a href="${h(o.action.url)}">${h(o.action.label)}</a></p>`:''}</div><p class="guidance-source">${attribution(p)}</p></div>${gallery(p)}</section>`;
}
export function priorityHTML(path){
 const p=guidance.pages[path];if(!p)return '';
 return `<section class="oath-guidance" aria-labelledby="transfer-guidance"><div><p class="guidance-kicker">Practical next steps</p>${(p.sections||[]).map(s=>`<div class="guidance-explanation"><h2>${h(s.title)}</h2><p>${h(s.text)}</p></div>`).join('')}<h2 id="transfer-guidance">${h(p.title)}</h2>${p.questions.map(q=>`<details><summary>${h(q.q)}</summary><p>${h(q.a)}</p></details>`).join('')}<nav aria-label="Related practical guides"><ul>${p.links.map(l=>`<li><a href="${h(l.url)}">${h(l.label)}</a></li>`).join('')}</ul></nav>${p.sources?`<div class="guidance-sources"><h3>Sources and review</h3><p>App steps checked against the linked release source; token identities and network requirements checked against the sources below. Screenshots show the actual app interface with mock data, not completed live transfers.</p><ul>${p.sources.map(s=>`<li><a href="${h(s.url)}">${h(s.label)}</a></li>`).join('')}</ul></div>`:''}<p class="guidance-source">${attribution(p)}</p></div>${p.overview?'':gallery(p)}</section>`;
}
export function priorityMarkdown(path){
 const p=guidance.pages[path];if(!p)return '';
 const o=p.overview;
 return `\n\n${o?`## ${o.title}\n\n${o.answer}\n\n${o.facts.map(f=>`- **${f.label}:** ${f.text}`).join('\n')}\n\n### ${o.example.title}\n\n${o.example.text}\n\n`:''}${images(p).map(i=>`![${i.alt}](${absolute(i.path)})\n\n${i.version}. ${i.caption}`).join('\n\n')}\n\n${(p.sections||[]).map(s=>`## ${s.title}\n\n${s.text}`).join('\n\n')}\n\n## ${p.title}\n\n${p.questions.map(q=>`### ${q.q}\n\n${q.a}`).join('\n\n')}\n\n${p.links.map(l=>`- [${l.label}](${absolute(l.url)})`).join('\n')}${p.sources?`\n\n### Sources and review\n\nApp steps checked against the linked release source; token identities and network requirements checked against the sources below. Screenshots show the actual app interface with mock data, not completed live transfers.\n\n${p.sources.map(s=>`- [${s.label}](${s.url})`).join('\n')}`:''}\n\nGuidance reviewed for Oath ${p.version||guidance.version} (${p.build||guidance.build}); updated ${p.updated||guidance.updated}. [How we review guides](https://oathwallet.org/about#editorial).\n`;
}
