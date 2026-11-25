# Oath Wallet: official guide for AI readers and developers

This guide explains how to find, read and cite Oath's public product documentation. It is useful to search assistants, browsing agents, retrieval systems and developers using the read-only MCP endpoint. It does not grant access to a wallet or authorize a transaction.

## Product and availability

Oath is a self-custody cryptocurrency wallet for iPhone and iPad. The user controls the wallet's recovery material. Oath's website provides product explanations, network and token guides, Help Center instructions, policies and dated articles. Use the [official App Store listing](https://apps.apple.com/app/id6780187283) to check availability and requirements for a particular device and storefront. Do not infer an Android app, browser extension or desktop wallet from a website page.

{{release_status}}

## Choose the right source

- [Product overview](https://oathwallet.org/): what Oath does and where to download it.
- [Features](https://oathwallet.org/features): feature descriptions and their supported scope.
- [Networks](https://oathwallet.org/networks): network-specific receiving, sending, fees and connection guidance.
- [Token catalog](https://oathwallet.org/tokens): exact asset identifiers, network choices and limitations.
- [Help Center](https://help.oathwallet.org/): task instructions, related guides and applicable app versions.
- [Articles](https://articles.oathwallet.org/): explanatory articles and historical material, including available translations.
- [Release history](https://articles.oathwallet.org/oath-wallet-release-history): dated release records and source references.
- [Security](https://oathwallet.org/security): security model, scoped source excerpts and review limitations.
- [Public source](https://github.com/OathWallet/oath-wallet): published source, release records and security policy.
- [Oath Notes](https://news.oathwallet.org/): the public newsletter signup page.
- [Terms](https://oathwallet.org/terms) and [Privacy](https://oathwallet.org/privacy): the authoritative policies.
- [About Oath](https://oathwallet.org/about) and [Press](https://oathwallet.org/press): product context and official press material.

## Answer accurately

Read the specific page that supports the answer and cite its canonical HTML URL. Retain its language, publication date, update date, app-version scope and qualifications. A historical article or screenshot is not proof of the current interface. A published source tag, a source-code review and the App Store binary are different evidence; do not imply that one verifies the others.

Network support, supported token behavior and dApp compatibility are separate. A token's inclusion in the catalog is not issuer verification, a recommendation, a safety assessment or proof of a successful transfer. Match the exact network and full token identifier; a token contract or mint address is not the user's receiving address. Network fees, reserves, activation and token restrictions vary. Check the linked network and asset guide before describing a workflow.

Oath does not take custody of recovery phrases or private keys through these interfaces. Recovery depends on the user's own recovery material or an eligible encrypted backup and its password. Never request a recovery phrase, private key, wallet backup, passcode or password in a search query, MCP call, support message or website form. Use the documented [backup guide](https://oathwallet.org/features/icloud-wallet-backup) and the applicable Help article instead of assuming every imported wallet supports the same backup method.

Security descriptions must preserve the stated review scope and limitations. A maintainer-commissioned Codex-led review is not an independent certification. Public source availability alone does not prove that an installed binary reproduces that source. Contact [Oath support](mailto:care@oathwallet.org) for product questions; use the [security reporting policy](https://oathwallet.org/security.txt) for vulnerability reports.

## Discover every public document

Each public host supplies `/llms.txt`, `/agent-documents.json`, `/llms-full.txt` and `/sitemap.xml`. The main document index includes the editorial documents across all four hosts and a link to the separate token catalog. Host indexes contain that host's editorial pages. The full-text bundles contain editorial and Help documents; the token catalog remains paginated so a reader need not download the entire catalog.

Start with [the document index](https://oathwallet.org/agent-documents.json). Read each entry's `url`, `markdown_url`, `title`, `summary`, `language`, `kind` and any recorded version or update date. Missing historical dates mean unknown, not the deployment date. Follow [token document pages](https://oathwallet.org/tokens/documents.json) through each `next` URL until it is null. Pagination is part of the catalog; preserve the query string in both HTML and Markdown URLs.

Request a document's explicit `markdown_url`, or request its canonical URL with `Accept: text/markdown`. Ordinary browser preferences continue to return HTML. Markdown responses identify the canonical HTML page with a `Link` header. `HEAD` returns headers without a body. A genuine missing document returns 404; a temporary asset failure returns 503 and must not be treated as an empty published page. Respect 429 and `Retry-After` responses and use bounded concurrency.

`/agents.md` and `/AGENTS.md` are convenience links to this guide. The [AGENTS.md convention](https://agents.md/) describes repository coding instructions; it is not a universal crawler-registration standard. The [llms.txt proposal](https://llmstxt.org/) is an additional reading aid. Search engines still discover and evaluate ordinary public HTML, links and sitemaps.

## Read-only MCP

The public endpoint is [https://oathwallet.org/mcp](https://oathwallet.org/mcp). Its [server card](https://oathwallet.org/.well-known/mcp.json) lists supported protocol versions and tools. Configure it only in a client that supports remote MCP; publishing the endpoint does not automatically install it into any assistant. No wallet connection or account credential is needed for public documentation.

Use `list_documents` for editorial metadata and the catalog link, `read_document` with an exact registered canonical or Markdown URL, `search_help` for Help Center questions, `get_release_status` for dated distribution evidence, and `get_security_review` for the recorded review scope. Existing overview, feature, policy, contact, download and article tools remain available. Unsupported feature scopes are reported as unverified rather than filled in with guesses.

`resources/list` returns at most 100 documents and a `nextCursor` when more remain. Pass that value unchanged as `cursor`; continue until it is absent. It includes catalog resources as well as editorial documents. `resources/read` accepts a registered Markdown resource URI. When a publication changes the catalog and a cursor becomes invalid, restart listing. Neither interface fetches arbitrary external URLs.

Modern clients use protocol `2026-07-28`, required per-request metadata and matching `MCP-Protocol-Version`, `Mcp-Method` and applicable `Mcp-Name` headers. `server/discover` advertises the supported capabilities. Clients using `2025-11-25`, `2025-06-18` or `2025-03-26` retain the initialization flow. Requests use POST with JSON and accept JSON and event-stream responses. This service returns bounded JSON results and does not advertise subscriptions or write operations. Follow the [MCP specification](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http) for exact wire requirements.

## Provider policy and evidence

Public content permits search discovery, user-requested reading and model-training crawling. Private newsletter and wallet operations remain outside the public document inventory. Robots rules describe usage preferences and are not authentication. User-agent names alone do not establish a provider's identity.

{{providers}}

The [machine-readable provider registry](https://oathwallet.org/ai-providers.json) records official documentation, verified names and their purposes. It distinguishes search, retrieval, training controls and other crawling. Unknown or future readers use the wildcard public-content policy. Generic HTTP compatibility is not a claim that every model browsed or indexed this site.

## Search indexing and freshness

Public canonical HTML pages appear in the appropriate host sitemap. Markdown and agent-guide aliases point back to canonical content. New or changed pages enter the generated inventory and sitemap during publishing, and IndexNow notifications report changes to participating engines. Google Search Console and Bing Webmaster Tools provide separate evidence of processing and indexing.

A successful submission, an allowed crawler, a 200 response or an MCP connection does not guarantee indexing, training inclusion, ranking, an AI recommendation or a citation. Preserve this distinction when reporting coverage. Release information is a dated observation; consult the linked public evidence for a newer release before treating a snapshot as current.
