import verification from '../indexnow.json' with {type:'json'};
import providers from '../content/ai-providers.json' with {type:'json'};
export const publicOrigins=['https://oathwallet.org','https://help.oathwallet.org','https://articles.oathwallet.org','https://news.oathwallet.org'];
export const newsPublicPaths=['/$','/?','/news/$','/news/index.html','/newsletter$','/newsletter/$','/news/signup.css','/news/signup.js','/theme.css','/theme.js','/favicon.svg','/assets/fonts/','/assets/brand/','/assets/networks/','/site-chrome.js','/help/site-chrome.css','/newsletter.css','/newsletter.js','/.well-known/security.txt','/security.txt',`/${verification.key}.txt$`,'/BingSiteAuth.xml$','/llms.txt$','/llms-full.txt$','/agent-documents.json$','/release-status.json$','/ai-providers.json$','/sitemap.xml$','/index.md$','/agents.md$','/AGENTS.md$','/.well-known/mcp.json$','/.well-known/mcp/server-card.json$'];
// Robots directives are public usage preferences, never authentication.
export function publicSearchRobots(origin) {
  if(!publicOrigins.includes(origin))throw Error('Unknown public host');
  const paths=origin===publicOrigins[3]?'Disallow: /\n'+newsPublicPaths.map(p=>'Allow: '+p).join('\n'):'Allow: /';
  const agents=[...new Set(providers.providers.flatMap(p=>Object.keys(p.agents))), '*'];
  return `# Public content: search, user retrieval and training permitted.\n# Provider roles and dated sources: https://oathwallet.org/ai-providers.json\n# Permission does not guarantee indexing or citations.\n\n${agents.map(a=>`User-agent: ${a}\n${paths}\n`).join('\n')}\nSitemap: ${origin}/sitemap.xml\n`;
}
