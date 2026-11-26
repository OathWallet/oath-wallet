# Approved Oath artwork

The installed app icon and all existing Appearance choices are the approved logos.
`oath-solid-blue.svg` is the canonical Signal Blue / white vector. Preserve its
exact silhouette. Use a single-color white or ink version when a transparent mark
is needed. Do not restore the retired multicolor logo or the removed Brand Kit.

`Tools/BuildRefreshMark.py` derives the refresh outline from this vector.
`Tools/CheckAppIcons.py` validates the installed icon and all Appearance choices.
Website branding and share previews must derive from this same approved artwork.

## Vice Sunset

`svg/11-oath-vice-sunset.svg` is the editable master for the user-requested
sunset edition. It uses the exact canonical Oath ring path, vector gradients,
purple outline/depth layers, and individually editable palm leaves clipped
inside the mark. It contains no raster images, fonts, scripts, or external assets.
The earlier generated raster was a visual exploration; it is not the shipping
source. The final SVG was authored directly from the canonical Oath vector.

The installed alternate icon and picker preview are identical opaque 1024px PNG
exports from this SVG, following the existing asset-catalog workflow. Export with:

```sh
inkscape Design/AppIcons/svg/11-oath-vice-sunset.svg \
  --export-area-page --export-width=1024 --export-height=1024 \
  --export-png-color-mode=RGB_8 \
  --export-filename=OathApp/Assets.xcassets/AppIconViceSunset.appiconset/icon.png
cp OathApp/Assets.xcassets/AppIconViceSunset.appiconset/icon.png \
  OathApp/Assets.xcassets/IconPreview-vice-sunset.imageset/icon.png
```

After editing/exporting, update this entry's SVG and PNG SHA-256 hashes in
`icon-manifest.json`, then run `python3 Tools/CheckAppIcons.py`.
