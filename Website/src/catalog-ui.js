import {tokenArtwork} from './token-artwork.js';

export const escapeHTML = value => String(value ?? '').replace(/[&<>"']/g, char => ({
  '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;'
})[char]);

export function chainMark(network, size = 40) {
  return `<img class="chain-mark" src="${escapeHTML(network.icon)}" width="${size}" height="${size}" alt="">`;
}

export function pairedMark(asset, network) {
  return `<span class="asset-pair">${tokenArtwork(asset, 64, true)}${chainMark(network, 26)}</span>`;
}

export function catalogNav(active) {
  return `<nav class="catalog-nav" aria-label="Browse directories">${['Tokens','Networks'].map(label => {
    const path = '/' + label.toLowerCase();
    return `<a href="${path}"${label === active ? ' aria-current="page"' : ''}>${label}</a>`;
  }).join('')}</nav>`;
}

export function directoryHeading(title, summary, active, mark = '') {
  return `<div class="catalog-heading"><div class="catalog-heading-text">${mark}<div><h1>${escapeHTML(title)}</h1><p>${escapeHTML(summary)}</p></div></div>${catalogNav(active)}</div>`;
}

export function assetHeading(mark, title, caption) {
  return `<div class="asset-heading">${mark}<div><h1>${escapeHTML(title)}</h1><p>${escapeHTML(caption)}</p></div></div>`;
}

export function rowContents(mark, name, subtitle, trailing = '') {
  return `${mark}<span class="token-row-name"><strong>${escapeHTML(name)}</strong><span>${escapeHTML(subtitle)}</span></span>${trailing}<span class="row-chevron" aria-hidden="true"></span>`;
}
