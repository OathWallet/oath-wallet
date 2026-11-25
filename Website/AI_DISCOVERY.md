# Maintaining public AI discovery

The canonical reader guide is generated at `https://oathwallet.org/ai` from
`content/ai-guide.md`. Public `/agents.md` and `/AGENTS.md` aliases redirect to its
Markdown representation; repository `AGENTS.md` files remain coding instructions.

## Sources and generation

- `content/ai-providers.json` records official provider documentation, crawler
  roles, the review date, and unknown or retired identities. Verify the official
  source before adding a crawler. The wildcard public policy covers other readers.
- `content/app-store-release.json` records a dated public storefront observation.
  A store version does not establish its build number or a source/binary match.
- `content/published-source-release.json` records the verified public tag and
  commit. Older guide and security-review evidence retains its own version scope.
- `src/agent-content.js` registers editorial pages and generates host inventories.
  `scripts/build-tokens.mjs` generates every catalog document in bounded batches,
  with meaningful metadata and a terminal `next: null`.
- `scripts/build-agent-content.mjs` builds the guide, robots directives, compact
  reading indexes, host full-text bundles, release status and MCP cards. The full
  bundle on the main host contains all editorial documents; catalog text is read
  page by page. News exposes only its public signup page and discovery files.

Run `npm run predeploy`, `npm run test:unit` and `npm run check:discovery` before
publication. The exhaustive offline check compares all canonical sitemap entries
with discovery inventories, checks for unregistered HTML, and renders every HTML
and Markdown pair. It verifies content and delivery, not search-engine indexing.

## HTTP and MCP

Explicit `.md` URLs and `Accept: text/markdown` return Markdown with a canonical
HTML Link header. Ordinary browser requests return HTML. Discovery files support
GET and bodyless HEAD. Missing resources use 404; temporary failures use 503.
Preserve authenticated newsletter operations, real error statuses and no-store
responses. Robots rules are preferences, not access controls.

The read-only `/mcp` endpoint supports 2026-07-28 per-request metadata and the
2025-11-25, 2025-06-18 and 2025-03-26 initialization flows. Resources are paginated
in batches of at most 100; cursors are tied to the published inventory. Never add
arbitrary URL fetching, wallet inputs or mutation tools to this public service.

## Cloudflare public reads

The deployed configuration rule `Public AI documentation — non-browser readers`
extends the existing public-document rule. It turns off Browser Integrity Check
only for HTTPS GET/HEAD of these exact public paths on oathwallet.org, www,
help, articles and news:

```
/ai /ai/ /ai.md /agents.md /AGENTS.md
/llms.txt /llms-full.txt /agent-documents.json /ai-providers.json
/release-status.json /sitemap.xml /index.md
/.well-known/mcp.json /.well-known/mcp/server-card.json
/BingSiteAuth.xml /7d93de9ae34be367679f8751b73eaa75.txt
/yandex_c0e2f76d0a57a2e5.html /yandex_650043df6dfe689a.html
/yandex_cc4674c827ce2f19.html
```

It does not change authentication, POST operations or private routes. Keep the
separate main-host JSON POST `/mcp` rule scoped to that endpoint. To roll back the
new edge exception, disable only the rule named above, then verify both public
reads and a private-route control. Worker rollback uses the prior deployment
version recorded in the release evidence; never substitute an unrelated build.

## Deployment and search notifications

Merge through the normal website checks and deployment workflow. Post-deployment
checks verify the exact catalog, public files, default HTTP clients and agent
workflows. Run `npm run check:discovery:live` for exhaustive live pairs; its bounded
four-worker scan resumes successful checks using an inventory-specific JSONL
ledger under ignored `Reports/ai-discovery-live/`. Review any failures before
claiming complete delivery. Do not commit local receipts or account information.

All four hosts publish sitemaps. IndexNow submits changed canonical HTML URLs after
successful deployment and caches only successful notification hashes. Add new
host sitemaps in Google Search Console and Bing Webmaster Tools. Inspect their
processing/indexing states separately and request indexing for priority new pages
within service quotas. Do not submit Markdown aliases as duplicate landing pages,
use Google's restricted Indexing API for ordinary content, or imply that an
accepted notification guarantees indexing, ranking or AI citations.
