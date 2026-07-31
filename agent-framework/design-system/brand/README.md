# SKYPhoenix brand assets

Official logo, mark, icon and social assets. Supplied by the brand owner on **2026-07-20**
and therefore **authoritative** — unlike the token files, these are not "extracted with
evidence", they are the source of truth itself.

Everything except the two masters is generated. Run `python3 generate.py` after changing a
master; never hand-edit a derived file.

## What is here

| Path | Use |
|---|---|
| `logo/skyphoenix-logo-color.svg` | **Master.** Full lockup, phoenix + "SKY PHOENIX IT" wordmark |
| `logo/skyphoenix-logo-{black,white,mono}.svg` | Single-colour lockups (`mono` = `currentColor`) |
| `mark/skyphoenix-mark-color.svg` | **Master.** Phoenix alone, no wordmark |
| `mark/skyphoenix-mark-{black,white,mono}.svg` | Single-colour marks |
| `raster/skyphoenix-logo-{variant}-{256,512,1024}w.png` | Where SVG cannot go: email signatures, Office, app-store listings |
| `icons/favicon.svg` | Primary favicon — square, ink-centred, scales to any size |
| `icons/favicon.ico` | Legacy fallback, 6 sizes (16–256) |
| `icons/favicon-{16..256}.png` | Explicit PNG sizes for `<link rel="icon">` |
| `icons/apple-touch-icon-180.png` | iOS home screen — opaque, no baked corner radius |
| `icons/icon-{192,512}.png` | PWA / Android, transparent |
| `icons/icon-maskable-{192,512}.png` | PWA maskable — opaque, content inside the 80% safe zone |
| `icons/icon-monochrome-512.png` | Android themed icons / notification tinting |
| `social/og-image-1200x630.png` | Open Graph + `summary_large_image` share preview |

## Which variant on which background

| Background | Variant | Why |
|---|---|---|
| White / light surface (`#ffffff`–`#f9fafb`) | **colour** | Default. Full brand recognition |
| Navy brand surface (`#1e3a5f`), photo, dark UI | **white** | Never the colour logo — the `#231815` wordmark disappears |
| Single-colour print, fax, engraving, stamps | **black** | |
| Inline in a themed component | **mono** | Inherits CSS `color`, so it follows light/dark/forced-colors automatically |

**Do not** recreate a light logo with a CSS filter. `brightness-0 invert` — the technique
currently used at `www/partials/footer.php:14` — forces the artwork to flat white and
destroys all three brand colours. A real white variant now exists; use it.

## Rules

- **Never redraw, restretch or recolour.** Scale proportionally only. The three brand
  hues (`#231815`, `#b92d26`, `#ed6d1f`) are fixed; see `../tokens/base.json`.
- **Clear space:** keep free space around the lockup equal to the height of the "S" in
  SKY on all sides. Nothing — text, rule, image edge, button — intrudes.
- **Minimum sizes:** full lockup ≥ 120px wide on screen (24mm print). Below that the
  wordmark stops resolving — use the mark alone instead.
- **The mark is theme-safe by construction:** it contains only `#b92d26` and `#ed6d1f`,
  no near-black ink, so it reads on both light and dark browser chrome without a
  theme-switched asset. This is why `favicon.svg` ships in colour rather than as a
  silhouette. If the mark ever gains ink, `build_favicon_svg()` in `generate.py` is where
  the `prefers-color-scheme` handling belongs.
- **Accessible naming:** the standalone SVGs carry a `<title>`. When inlining, either
  supply the accessible name on the host element or mark the graphic `aria-hidden="true"`
  if it is decorative and the company name is already adjacent as text — do not announce
  "SKYPhoenix IT" twice to a screen reader.

## Web wiring

```html
<link rel="icon" href="/assets/brand/icons/favicon.svg" type="image/svg+xml">
<link rel="icon" href="/assets/brand/icons/favicon-32.png" sizes="32x32">
<link rel="apple-touch-icon" href="/assets/brand/icons/apple-touch-icon-180.png">
<link rel="manifest" href="/site.webmanifest">
<meta property="og:image" content="https://skyphoenix-it.com/assets/brand/social/og-image-1200x630.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta name="twitter:card" content="summary_large_image">
```

`favicon.ico` should additionally be served from the domain root (`/favicon.ico`) — some
crawlers and older clients request only that path and never read the `<link>` tags.

Manifest icon entries:

```json
{
  "icons": [
    { "src": "/assets/brand/icons/icon-192.png", "sizes": "192x192", "type": "image/png", "purpose": "any" },
    { "src": "/assets/brand/icons/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any" },
    { "src": "/assets/brand/icons/icon-maskable-512.png", "sizes": "512x512", "type": "image/png", "purpose": "maskable" }
  ]
}
```

## Provenance and verification

The brand owner supplied `logo bunt.png`, `logo schwarz.png`, `logo weiss.png`
(2084×1384 RGBA, transparent). Rather than shipping those rasters as the source, they
were **verified against** the existing vector artwork and the mono variants were then
derived from the vector — which keeps them scalable. Verification, 2026-07-20:

| Check | Result |
|---|---|
| Supplied colour PNG vs vector render — content aspect ratio | 1.5080 vs 1.5077 |
| Supplied colour PNG — solid colours | `#b92d26`, `#231815`, `#ed6d1f` (exact match to tokens) |
| Derived black SVG vs supplied `logo schwarz.png` — shape | 1.24% differing pixels (edge anti-aliasing only) |
| Derived white SVG vs supplied `logo weiss.png` — shape | 1.24% differing pixels (edge anti-aliasing only) |
| Derived black / white — solid colours | exactly `#000000` / `#ffffff`, matching the supplied files |

Note the supplied black is pure `#000000`, **not** the wordmark's `#231815`. That is
intentional in the supplied artwork and is preserved: the black variant is a true
single-colour reproduction asset, not a darkened colour logo.

Generated icon geometry was verified too — every icon centred to within 0.5px, the
apple-touch icon opaque, and both maskable icons at ~59.9% coverage, inside the 80% safe
zone.

## Known gaps

- **No stacked/vertical lockup.** Only the horizontal lockup exists. Narrow contexts
  (square avatars, mobile splash) currently use the mark alone. If a stacked lockup is
  wanted it must come from the brand owner — per the "never invent" rule it will not be
  composed here.
- **No wordmark-only asset.**
- **Raster tier caps at 1024w** by design (see the comment in `generate.py`). Large-format
  print needs a local render, not a committed file.
