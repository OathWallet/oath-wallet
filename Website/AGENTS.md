# Website design conventions

Do not add northeast/up-right arrow decorations to website links, buttons, cards,
or other interface elements. This includes the Unicode character U+2197, encoded
HTML/CSS/JavaScript equivalents, and SVG/icon equivalents. Keep link labels clear
without this decoration. Applies to the main website, Help Center, articles,
newsletter screens, and all page generators. Preserve functional navigation and
download controls using other directions.

# Search indexing directives

Do not emit `noindex` or the equivalent robots `none` directive in HTML,
HTTP headers or generated website assets on any website host or route.
Preserve canonical links, genuine 404/410/503 responses, authentication,
no-store caching and wallet-link privacy controls. Indexing directives are
not access controls. Run the indexing-policy tests after website changes.
