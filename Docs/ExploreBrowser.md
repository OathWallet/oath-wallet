# Browser

History is the second Wallet tab and shows transactions for the selected wallet and account. The Browser tab and its Settings entry are enabled by default. Both are controlled by the `browserEnabled` initializer argument on `OathAppSettings`. The app preserves saved Browser data when its entry points are hidden.

When Browser is enabled, each visit starts on a native page with Favorites, Recent, the address bar and Tabs. Favorites share their storage with Library bookmarks. A long press removes an individual visit from browsing history after the user chooses Remove from Recents. The Clear button beside Recent asks for confirmation before clearing the full browsing history. In Settings → Browser, users can choose DuckDuckGo, Google, Bing or Brave Search and toggle Show Recent Sites. Turning it off hides the section on Start and preserves the history in Library. Private browsing never contributes to Recent and its Start page hides both collections.

Saving a favorite retrieves the website’s title and icon and preserves an optional name entered by the user. Start reads saved titles and cached icons first and fills in missing metadata for visible favorites. Recent shows the eight latest regular pages and uses titles from WebKit. The app tab bar stays expanded on Start, with the address field and Tabs directly above it. When the selected wallet has active WalletConnect sessions, Connected sites opens its connection manager. Visiting a site from Start resumes its matching tab in the current group or opens a new one. The tab overview’s plus opens Start for an explicitly new tab. Back returns to the screen that opened a website. Returning from the app switcher or unlocking resumes the current screen. The archive restores regular tabs and previews across launches. The private group lasts for the current app session.

## Browser and connections

Websites use Apple’s `WKWebView` with the main tab bar hidden. The page menu and tab overview provide access to the browser library. Normal/private tabs, bookmarks, recent history, back/forward, reload, sharing, address/search entry and explicit new-tab confirmation are included. At most eight tabs and three live web views are retained; inactive views are suspended, while a view with an approval is protected.

Private browsing uses a separate nonpersistent WebKit store. Its pages, history and direct EVM permissions are never written by `BrowserStorage`. Closing all private tabs releases that store and its permissions. **WalletConnect connections remain until explicitly disconnected**, including connections started from private tabs; the UI discloses this before forwarding the connection.

Normal history/restoration metadata is stored separately in Application Support, excluded from backup and protected with iOS file protection. It is not described as app-passcode encryption. History is bounded to 500 pages/30 days, bookmarks to 200. Sensitive callback queries and URL fragments are stripped from restoration. Clear Browsing Data closes tabs and removes cookies, storage, history and direct permissions; it preserves explicit bookmarks and WalletConnect sessions.

### Injected EVM provider

The top frame receives `window.oath`, `window.ethereum` when unoccupied, and EIP-6963 discovery. It supports EIP-1193 request/events, accounts, known-chain switching, personal signing, EIP-712 v4 signing and transaction submission. RPC reads have explicit method and payload bounds, two concurrent calls, and a 120/minute local ceiling. Raw transaction broadcast, unrestricted `eth_sign`, unknown chains and arbitrary RPC URLs are rejected.

Native code validates actual WebKit frame origin, HTTPS, document generation, selected tab, foreground state, unlocked wallet and account selection. The page gets neither private keys nor RPC credentials. Navigation, closing a tab, changing wallets/accounts, locking, or backgrounding cancels pending consent. Normal permissions are revalidated against the selected owned accounts when restored.

Connection and signing approvals identify the actual website. Each signature/send uses native authentication and the existing reviews. Browser and WalletConnect share `OathDAppEVMCoordinator`, the EVM fee/preparation service and durable submission journal. Browser IDs use a separate `browser:` namespace. An already committed transaction stays committed if its page disappears during broadcast. One approval gate prevents simultaneous browser and WalletConnect reviews.

All failures use OathDiagnostics and the existing outbox. Website URLs, titles, request bodies, wallet identifiers and signing material are excluded from diagnostics. Expected peer validation, cancellation, optional data absence and already-observed storage propagation are documented control flow.

## Validation and limits

Host tests cover ranking/identity rules, provider fallback, offline hydration, stale retention, refresh replacement, database races/recovery, quota/no-store/priority behavior, browser URL/storage/RPC bounds, and both browser and relay journal recovery. A real **macOS WebKit** host test exercises document-start requests, script replies, EIP-6963 announcements/events, no iframe injection and independent nonpersistent stores. It uses local fixture HTML and no wallet credentials or network calls.

The iOS interface is compiled for the generic iOS destination. No physical-device installation, simulator launch or mainnet transaction is part of this implementation validation. Third-party dApp behavior still varies; this does not promise compatibility with every site or constitute App Review approval. Popup destinations require confirmation and open without an opener relationship. HTTP-only sites, unrestricted custom schemes, browser extensions and non-EVM injected providers are outside this first version. Other supported networks can connect through the existing WalletConnect implementation.

## Historical Explore feed

The former Explore landing page used the following discovery services and presentation. Browser has no dependency on these feeds.

### Discovery

Explore shows horizontal card previews for market rankings, dApps, bookmarks
and search suggestions. Tapping a market heading opens the full ranking in a
plain iOS list. Each row shows one asset and opens its price chart and details.

- Top assets, Trending, Gainers and Losers filter to enabled Oath networks. Assets are identified by network and canonical contract/mint/issuer; ticker text never establishes identity.
- CoinPaprika bulk tickers are the primary top/mover feed. CoinLore is the fallback. If global CoinLore movers do not contain mapped assets, its top-100 cohort supplies a clearly scoped ranking.
- GeckoTerminal supplies trending pools, filtered to at least $100,000 liquidity, $100,000 daily volume and 24 hours of age. Base-token prices are never assigned to quote tokens. Missing market cap remains absent, not FDV.
- DexPaprika's first-page public screener is a fallback labelled **Active on-chain**, because activity is not equivalent to a provider's trending ranking. It only admits exact contracts already known to Oath.
- Whole provider snapshots are retained together in the indexed `publicMarketCache` SQLite table, keyed by section and sorted network scope. On entry, saved lists are published before catalogue initialization or API requests. Rankings refresh after 10 minutes and trending after 2 minutes. The last valid observation remains available offline with its original source and fetch date stored in the cache. A recent GeckoTerminal snapshot is preferred to a different ranking definition for 15 minutes. All four providers' normalized display models, including CoinLore, are saved for the explicitly requested private offline feature; HTTP response caching remains disabled.
- CoinPaprika identity enrichment checks explicit platform/contract metadata against Oath's catalogue, with at most two calls per refresh and 50 per UTC day. Its metadata cache lasts seven days. The initial explicit native/contract mapping works without enrichment.
- A reviewed, bundled catalogue links Uniswap, Aave, Lido, Curve, PancakeSwap and 1inch. Optional aggregate TVL comes from DefiLlama, hydrates from SQLite before refresh, and refreshes after six hours. Failed refreshes preserve the last valid value. The aggregate is not a per-network TVL. The screen model owns these requests, so row appearance cannot race service initialization.
- Local token suggestions use the existing token catalogue. Opening a token uses existing asset details or the verified add-token flow. Discovery never adds an asset automatically. Quotes and rankings are displayed in USD.

Loading placeholders use the same cards as the previews and the same rows as the full rankings. dApp descriptions and bundled artwork appear immediately, while only unsaved TVL content shimmers. Cached lists never become skeletons during refresh. The shared SwiftUI shimmer uses a soft opacity mask, follows layout direction, and stops for Reduce Motion, inactive scenes and a hidden Explore tab/browser. Skeletons are noninteractive and expose a single localized loading announcement. Browser uses the outlined `safari` symbol in both native tab implementations.

Cache writes preserve the database's monotonic winner, so an older response cannot overwrite a newer one. Requests for the same section/network or dApp coalesce; cancellation preserves saved observations and a new screen visit can replace a cancelled request. Malformed cache entries are reported through OathDiagnostics and removed only if unchanged since reading. Database read/write failures are reported without discarding successfully fetched in-memory content. Expected cache misses, empty qualified rankings, optional absent TVL and navigation/typing cancellation remain normal control flow. No user search terms, wallet identity, or browser pages enter the public market cache. Search remains local to the existing persisted, indexed token catalogue; artwork uses the shared persistent image pipeline.

### Public API budgets and release setting

Every added discovery request is anonymous and keyless. Existing wallet RPC and WalletConnect configuration remain unchanged.

The shared public-market scheduler coalesces requests, gives queued interactive wallet reads priority over discovery, and applies host-wide cooldowns. GeckoTerminal is paced at eight requests/minute; DexPaprika at six/minute, with an additional 200/day budget. A 402 response suspends the host for a day. A 429 uses Retry-After with a bounded delay. Normal transport failures do not become zero prices. The scheduler does not promise provider uptime or unlimited free capacity.

`OathExplorePersonalDataAllowed` is **true in this private checkout**. CoinPaprika's free plan is personal-use; CoinLore's redistribution terms also require review. Set the flag false before public distribution until suitable rights or an approved replacement are in place. With the flag false, personal-use top/mover feeds and their persisted snapshots are disabled; public on-chain discovery remains available. This flag does not purport to grant a data licence.

## Recorded verification (2026-11-21)

- Generic iOS Release build via `Tools/BuildiOS.py`: passed; isolated build cache, signing disabled.
- OathBrowser host suite: 6 tests passed, including real macOS WebKit.
- Explore market-data suite: 10 tests passed.
- Public-market/Explore transport regression selection: 33 executed, 2 explicitly skipped, no failures.
- EVM send journal regression selection: 26 tests passed, including browser IDs.
- OathDiagnostics host suite: 165 executed, 6 explicitly skipped, no failures.
- `Tools/CheckDiagnosticsCoverage.py` and `git diff --check`: passed.
- Simulator/device UI, external dApp pairing/signing, and mainnet broadcasts: **NOT TESTED**.

The public-market diagnostics test had old expectations that suppressed real HTTP 429/timeouts. It now matches the existing whole-app reporting policy and isolates assertions by operation ID; production suppression was not broadened.

## Cache and loading verification (2026-11-23)

Cache/loading update verified on 2026-11-23: 22 targeted OathMarketData host tests passed (including parameterized provider/section cases); the OathDiagnostics host suite executed 165 tests with six existing skips and no failures; diagnostics coverage and `git diff --check` passed. The final generic iOS Release build via `Tools/BuildiOS.py` passed with signing disabled. Simulator/device visuals and live provider calls were not tested for this update; network recovery tests use deterministic fixtures and real SQLite storage.

## References and artwork

- [SwiftUI redaction](https://developer.apple.com/documentation/swiftui/view/redacted(reason:)), [opacity masks](https://developer.apple.com/documentation/swiftui/view/mask(alignment:_:)), [animation timeline](https://developer.apple.com/documentation/swiftui/timelineschedule/animation(minimuminterval:paused:)), [Reduce Motion](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion), [explicit symbol variants](https://developer.apple.com/documentation/swiftui/environmentvalues/symbolvariants). These APIs are available before the app's iOS 17 deployment target; declarations were checked in the installed iOS 27.2 SDK.
- [Apple WKWebView](https://developer.apple.com/documentation/webkit/wkwebview), [script messages with replies](https://developer.apple.com/documentation/webkit/wkscriptmessagehandlerwithreply), [nonpersistent stores](https://developer.apple.com/documentation/webkit/wkwebsitedatastore/nonpersistent()), [native Search tab role](https://developer.apple.com/documentation/swiftui/tabrole/search).
- [EIP-1193](https://eips.ethereum.org/EIPS/eip-1193), [EIP-6963](https://eips.ethereum.org/EIPS/eip-6963).
- [CoinPaprika pricing](https://coinpaprika.com/api/pricing), [identity metadata](https://docs.coinpaprika.com/api-reference/coins/get-coin-by-id), [CoinLore API](https://www.coinlore.com/cryptocurrency-data-api), [CoinLore terms](https://www.coinlore.com/terms-of-use).
- [GeckoTerminal API](https://api.geckoterminal.com/docs/index.html), [DexPaprika limits](https://docs.dexpaprika.com/knowledge-base/rate-limits), [token screener](https://docs.dexpaprika.com/tutorials/token-screener), [DefiLlama free API](https://api-docs.defillama.com/llms-free.txt).

The six bundled dApp logos were retrieved from DefiLlama's protocol icon directory (`https://icons.llamao.fi/icons/protocols/{catalogue-id}`) on 2026-11-21 and converted to PNG for the asset catalogue. They identify their respective third-party services and do not imply endorsement. Branding belongs to the respective projects; review distribution terms before a public release.
