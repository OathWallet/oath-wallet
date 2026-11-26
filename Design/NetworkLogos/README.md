# Network artwork provenance

The active runtime source is `OathApp/Assets.xcassets/Networks`. Every chain has
one asset-catalog entry; Home, import, receive, and EVM stacks display it through
the shared `OathNetworkLogo` view. The earlier 42-chain design set uses full-bleed,
opaque square source backgrounds, high-quality interpolation, and one native
continuous rounded-square mask with a corner radius of 22% of the displayed
size. There is no backing circle. Network badges use the same rounded-square
presentation. Existing symbols and brand palettes were used as the edit
references; this is a shape adaptation of the previously designed artwork.
There are no runtime logo downloads or separate per-screen image copies.
Small views use shared display renditions, described below; original artwork
remains available for larger views.

## Plasma, World Chain and Elysium — November 17, 2026

The user's three supplied 1254px PNGs replace the previous upstream artwork:
first attachment Elysium, second Plasma, third World Chain. Runtime source
PNGs are exact, byte-for-byte copies, including their backgrounds and alpha.
These three explicitly approved designs retain their supplied rounded edges
instead of being regenerated. `provided-mainnet-logos.json` pins the source
hashes and records this narrow transparency exception to the older opaque set.

Home, import, receive, network pickers and badges continue using the existing
shared `OathNetworkLogo`. Matching 128/256/384px display renditions use the same
ImageIO preparation as the other chains. No per-screen copies or new runtime
image handling are introduced. Refresh/check only this set with:

```sh
swift Tools/PrepareNetworkDisplayLogos.swift --generate --networks=plasma,worldchain,elysium
swift Tools/PrepareNetworkDisplayLogos.swift --check --networks=plasma,worldchain,elysium
```

The scoped option preserves the other networks' files and manifest entries.
The source hashes and all nine display renditions passed validation. Native
macOS SwiftUI host renders at 38pt and 15.2pt (@3x) were inspected on light
and dark backgrounds alongside the existing Ethereum icon. These are host
previews, not screenshots from a running iOS app. No simulator or device was
launched.

Apple references: [ImageIO thumbnail preparation](https://developer.apple.com/documentation/imageio/cgimagesourcecreatethumbnailatindex(_:_:_:))
and [SwiftUI named image lookup](https://developer.apple.com/documentation/swiftui/image/init(_:bundle:)).

## Six additional designs — October 29, 2026

The approved 0G (`zerog`), Chiliz, Filecoin, Sei, Polkadot, and IoTeX designs
are installed in their existing `network-` catalog entries. Their preview
backgrounds were extended with imagegen into opaque squares so the shared
native view supplies the only rounded mask. 0G now uses PNG artwork instead
of its previous SVG. Chain identities, loading behavior and badge placement
are unchanged.

`output/six-chain-logos-integrated` contains the integrated sources, the exact
generation prompt and source paths, previous asset backups, and light/dark
host SwiftUI previews at 60pt, 38pt and 15.2pt. `manifest.json` records the six
source hashes and approved preview paths. The display catalog and its hash
manifest have been regenerated and checked for all 42 chains (126 renditions).
The host previews use the native continuous rounded-square shape; they are
not screenshots from a running iOS app.

## Square artwork — October 25, 2026

The user requested square versions of the existing designs for every chain.
Each existing bundled PNG was edited separately using the image-generation
tool to extend its background to the square edges. Intrinsically circular
parts of a symbol, such as Base's white disc, remain part of that symbol.
The user subsequently requested rounded squares. The shared view now rounds
network artwork at its final display size with antialiasing, so rows and small
badges use the same proportions. Source PNGs remain intact; non-network token
artwork is not given this new shape.

`output/network-logos-square/logos` contains the deliverable PNGs, copied
byte-for-byte into the main catalog. `previous-app-assets` preserves the
previous circular runtime assets. `generated.json` records generated source
paths; `manifest.json` here records active hashes and previous provenance.
The display catalog is regenerated from the square sources at all three
screen scales. Token-logo processing is unchanged; OathTokenDesign remains
removed.

Validation of this square set: all 35 catalog chains have matching source
PNGs; all full-resolution pixels are opaque; all 105 display renditions pass
the size, opacity, scale and hash checks. Host SwiftUI renders of all 35 logos
at 38pt and 15.2pt (@3x) were reviewed on light and dark backgrounds. The generic
iOS Debug build with signing disabled succeeded. The diagnostics coverage
guard passed; OathDiagnostics reported 83 tests, two skipped and zero failures.
No simulator or physical-device runtime check was performed for this change.

## Small-display rendering

Before display renditions were added, large PNG artwork was scaled directly
into small scrolling rows. The previous 35 circular originals totaled about
2,066 MiB of decoded pixels (an aggregate asset measurement, not simultaneous
app memory). Small network
logos and badges now use `NetworkDisplay` catalog renditions at 128pt, with
128/256/384px files for 1x/2x/3x screens. The shared `OathNetworkLogo` selects
these through UIKit's named-image cache for sizes up to 128pt and retains the
original source for larger views or assets without a display rendition.

Run `swift Tools/PrepareNetworkDisplayLogos.swift --generate` after replacing
source artwork, then run the same tool with `--check`. The checked-in manifest
verifies source and rendition hashes, square dimensions, full opacity and
catalog scale mappings. Generation preserves source files; it does not add
clipping, backgrounds or recoloring. Missing
optional display artwork uses the original existing image path; this is not an
app error or a new diagnostics boundary.

A host ImageIO benchmark of the previous circular set reduced aggregate decoded size
from 2,066 MiB to 19.7 MiB at 3x and full-image decode time from approximately
4.1–4.7 seconds to 60–111 milliseconds. This measures image decoding, not app
frame rate. Host-rendered comparisons at 38pt and 15.2pt were inspected for
eleven logos. No simulator or physical-device scrolling check was performed.

On October 10, 2026, twelve entries were replaced with the user's supplied files:

| Chain | Supplied file |
|---|---|
| Gram | `gram logo.png` |
| Base | `base logo.svg` |
| Ethereum | `Ethereum_Logo.png` |
| XRP Ledger | `xrp-xrp-logo-png_seeklogo-452462.png` |
| Sui Network | `sui logo.png` |
| Stellar | `xlm logo.png` |
| Polygon | `poygon logo.png` |
| NEAR Protocol | `near logo.png` |
| Arc | `arc logo.jpg` |
| TRON | `tron logo.png` |
| BNB Smart Chain | `images.png` |
| Solana | `Solana_logo.png` |

Each file was copied without resampling, recoloring, or redrawing. The supplied
`gram.svg.webp` is a second rendering of the Gram design; only the PNG is bundled.
The twelve replaced PDFs were removed from the app's asset catalog.
`manifest.json` records the supplied paths and SHA-256 hashes of active files.

Linea, Optimism, Scroll, Taiko, Telos, and X Layer retained their original
artwork until the third circular redesign set on October 25, described below.

On October 24, 2026, Litecoin was replaced with the user's supplied 500 × 500
blue-and-white PNG, copied without modification. The shared `network-litecoin`
catalog entry now uses `logo.png`; the superseded bundled PDF was removed.
The original historical SVG remains in `Originals`.

`Originals` and `LICENSES.md` preserve the historical October 5 collection and
its provenance; they do not override the active asset catalog. Manifest original
paths are relative to `Design`.

The app displays Gram / GRAM while retaining the `ton` network ID, `ton:native`
asset ID, and existing derivation path. [TON's official documentation](https://docs.ton.org/start-here)
identifies Gram as its native currency and TON as the underlying blockchain.
Startup refreshes branding in SQLite before screens read the stored catalog.

On October 11, 2026, the Ankr account integration added Fantom, Flare, Somnia,
and Story. Fantom uses the original Trust Wallet asset-repository PNG. The
other three use the original SVGs referenced by Ankr's native-asset metadata.
Their source URLs and SHA-256 hashes are recorded in `manifest.json`. The
runtime still uses bundled artwork through the same shared logo view.

Validation: 198 host catalog/search/artwork checks, two host database branding
tests, and unsigned generic-iOS Debug compilation with test targets passed.
Simulator and physical-device runtime/visual checks were not run for this change.

Robinhood Chain (mainnet 4663): original artwork from the official Robinhood Chain documentation, retrieved 2026-10-12. Source: https://cdn.robinhood.com/assets/generated_assets/hoodchain_docsite/rh_favicon_152.png. SHA-256: 274ddce8e6fcec2a48dc88b290b91f79e178cb34b1b3d0360b33db882399fd69.

THORChain: `network-thorchain` uses the THORChain logo from https://github.com/trustwallet/assets/blob/master/blockchains/thorchain/info/logo.png (retrieved 2026-10-15).

On October 25, 2026, Bitcoin and Litecoin were replaced with the user-approved
circle designs generated with imagegen: an orange gradient for Bitcoin and a blue
gradient for Litecoin, each with its white symbol. The 1254 × 1254 transparent
PNGs from `output/bitcoin-logo-variants/bitcoin-circle.png` and
`output/litecoin-logo-variants/litecoin-circle.png` were copied byte-for-byte into
the shared catalog entries as `logo.png`. Bitcoin’s superseded runtime PDF was
removed. Historical SVG originals remain unchanged. The shared rendering and
diagnostics paths are unchanged.

October 25 validation: exact-source/hash and catalog checks passed for both
replacements; diagnostics coverage passed; OathDiagnostics host tests passed
(72 executed, 2 skipped, zero failures) using an isolated scratch directory;
unsigned generic-iOS Debug build passed. The initial host-test attempt hit an
existing external-volume bundle-signing error; the isolated build resolved it.
Simulator and physical-device runtime/visual checks were not run.

On October 25, 2026, the added canvas circles were removed from shared network
artwork, token artwork (including receipt exports), and token network badges.
Circular clipping and existing image sizing remain in place for all source
shapes; the original artwork pixels and image-loading diagnostics are unchanged.

On October 25, 2026, BNB, Aptos, Arbitrum, Arc, and Avalanche (AVAX) were
replaced with the user-approved circular redesigns from
`output/network-logo-redesigns-4k/*-circle-4096.png`. Each 4096 × 4096 PNG is an
enlarged export of a 1254 × 1254 generated design, copied byte-for-byte into its
existing shared `network-*` catalog entry. White details are opaque; outer
corners are transparent. Superseded PDFs and the Arc JPEG were removed from
the runtime catalog, with the previous assets preserved in
`output/network-logo-redesigns-4k/previous-app-assets`. Historical SVG sources
remain unchanged. The shared circular clipping, absence of an added background,
and existing image-loading diagnostics are preserved.

Five-logo integration validation: exact-source, 4096 × 4096 dimensions, catalog,
and manifest-hash checks passed. Diagnostics coverage passed; OathDiagnostics
host tests passed (72 executed, 2 skipped, zero failures). Unsigned generic-iOS
Debug build passed. Simulator and physical-device runtime/visual checks were
not run.

On October 25, 2026, the second circular redesign set replaced Base, Bitcoin
Cash, Dogecoin, Ethereum, Fantom, Flare, and Gnosis using the user-supplied
references. The seven `output/network-logo-redesigns-set2-4k/*-circle-4096.png`
exports are copied unchanged into the existing shared catalog entries. These
4096 × 4096 PNGs are enlarged generated designs, not native 4K renders. White
details are opaque; Ethereum retains its opaque pale-lavender facets. Dogecoin
and Gnosis use white symbols. Outside corners remain transparent. Historical
sources and previous app assets are preserved in the design folders and
`output/network-logo-redesigns-set2-4k/previous-app-assets`. Obsolete PDFs/SVGs
were removed from the affected runtime catalog entries. Shared circular
clipping and the absence of a separate backing circle remain unchanged.

Second-set validation: all seven exports decoded at 4096 × 4096; sampled white
and interior pixels were opaque and corner pixels transparent. Installed
files matched exports byte-for-byte, and catalog/manifest checks passed.
Diagnostics coverage passed; OathDiagnostics host tests passed (72 executed,
2 skipped, zero failures). Unsigned generic-iOS Debug build passed. No simulator
or physical-device runtime/visual checks were run.

On October 25, 2026, the third circular redesign set replaced HyperEVM, Linea,
Monad, NEAR, Optimism, Polygon, Robinhood, Scroll, Solana, Somnia, Stellar,
Story, Sui, Taiko, Telos, THORChain, TRON, Unichain, X Layer, and XRP Ledger.
The twenty `output/network-logo-redesigns-set3-4k/*-circle-4096.png` exports
are copied byte-for-byte into their existing `network-*` asset entries. The
4096 × 4096 images are enlarged generated designs, not native 4K renders.
Generation prompts and source paths are recorded in that folder's
`generation.json`; generated originals and previous app assets are preserved.

The references retain their recognizable geometry and brand palettes, with
consistent circular presentation and balanced symbol padding. White details
are opaque. Telos uses a solid white center and opaque source corners, which
the existing shared circular clip removes; the other nineteen sources use
transparent outer corners. Native circular clipping also removes generated
edge fringe. No additional white or dark UI backing circle is introduced.
Unichain's grid was removed. Existing image-loading and diagnostics behavior
is unchanged; these are bundled artwork substitutions, with no new runtime
image pipeline or failure boundary.

Third-set validation: all twenty exports decoded at 4096 × 4096; sampled white
details were opaque. Interior alpha sampling found two sub-250 alpha samples
for Robinhood and eight for Taiko out of roughly 181,000 samples per image;
the remaining eighteen had none. Telos intentionally has opaque source
corners; other sampled corner alpha values were 0 or 1. Catalog mappings,
manifest hashes, installed/export byte equality, and prior-asset backups were
verified for all twenty. Diagnostics coverage passed (627 catch sites).
OathDiagnostics host tests passed (72 executed, 2 skipped, zero failures), and
the unsigned generic-iOS Debug build passed. Generated artwork was inspected;
simulator and physical-device runtime/visual checks were not run.

On October 25, 2026, Gram was replaced using the user's blue gem-and-star
reference. `output/gram-logo-redesign-4k/gram-circle-4096.png` is copied
byte-for-byte into `network-ton/logo.png`; the existing Gram display name,
`ton` chain ID, and shared circular presentation remain unchanged. This is a
4096 × 4096 enlarged export of the generated design, not a native 4K render.
The generated original, prompt, and previous app asset are preserved in that
output folder. The white gem and blue star are opaque, outer corners are
transparent, and no separate UI backing is added. Existing diagnostics and
image-loading behavior are unchanged.

Gram validation: the export decoded at 4096 × 4096; sampled white and interior
pixels were opaque, with transparent corner pixels. Installed bytes and the
manifest hash matched the export. Diagnostics coverage passed (627 catch
sites), OathDiagnostics host tests passed (72 executed, 2 skipped, zero
failures), and the unsigned generic-iOS Debug build passed. No simulator or
physical-device runtime/visual checks were run.

## October 25 — jagged-edge rendering repair

A host SwiftUI ImageRenderer reproduction at 38pt × 3 showed the existing
large-PNG/default-interpolation/circle-clip path producing visibly aliased edges
and symbols, matching the user screenshot. OathNetworkLogo now explicitly uses
`.interpolation(.high)` and omits `.clipShape(Circle())`, as requested. The source
artwork defines its silhouette. This applies to all chain-logo call sites and
small chain badges. No extra UI background was added.

A scan of bundled PNG corners found one exception to source transparency:
Telos had opaque white corners hidden by the old clip. Imagegen repaired its
outer transparency while retaining the gradient ring and opaque white center.
The 1254px result is used directly without upscaling; the former PNG is preserved
in `output/network-logo-edge-check/telos-before.png`. Manifest hashes identify
the corrected source. All other source images remain untouched.

`Tools/RenderNetworkLogoEdges.swift` reproduces the before/after view modifiers
using the same source PNGs in a macOS host renderer. Its light/dark comparison
sheets in `output/network-logo-edge-check` cover eleven logos at 38pt × 3 plus
15.2pt × 3 badges. These are host visual checks, not iPhone screenshots. Both
sheets were inspected: edges and symbols are smoother, and Telos has no white
square corners on the dark surface. Native device rendering was not tested.

Validation after repair: all 35 bundled PNGs passed the corner-transparency scan;
the Telos asset hash matches the manifest. Diagnostics coverage passed (631
observed catch sites), and OathDiagnostics host tests passed (72 executed,
2 skipped, zero failures). The final unsigned generic-iOS app build, including
the corrected Telos asset, passed. No simulator or physical device was launched.

Cronos sending (2026-11-05): `network-cronos.imageset/logo.png` preserves the source
from https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/cronos/info/logo.png.
It uses the existing shared network presentation; no generated replacement was introduced.
