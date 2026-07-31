# Design-System Source Ledger

Extraction target: `/home/simon/IdeaProjects/CompanyWebsite` (READ-ONLY sibling repository; not modified).
Extraction date: **2026-07-18**. Method: full read of all custom CSS + partials/templates; grep sweep of all remaining PHP pages for hex literals, inline styles, `<style>` blocks, Tailwind color/radius/shadow/gradient/motion classes, and font references.

## Primary sources (read in full)

| Source | Role | Key extractions |
|---|---|---|
| `www/assets/css/custom.css` (379 lines) | Marketing-site custom CSS | CSS variables :7-16; skip link :19-32; focus :40-47; card hover :57-62; hero gradient :67-72; hero buttons :77-96 (+ `!important` overrides :98-176); mobile type :262-284; wide-screen :293-325; touch :329-366; reduced motion :369-378 |
| `portal/assets/css/portal.css` (449 lines) | Portal custom CSS | focus-visible :4-7; card hover :11-15; tables :19-39; forms :65-77,172-183; time widget :79-170; buttons :186-228; stat cards :231-245; alerts :248-274; progress/spinner :277-301; mobile :308-383; wide :395-413; print :416; iOS :426-448 |
| `www/partials/header.php` | Tailwind config + top nav | brand colors :66-71; font declaration :74; nav bar :118-190; skip link :115; meta/favicon :46-56 |
| `portal/includes/header.php` | Portal Tailwind config + sidebar | brand colors :110-112; theme-color :96; viewport (user-scalable=no) :93; sidebar :126-143; role legend :246-249; flash :329-339 |
| `www/partials/footer.php` | Footer + mobile nav JS | dark footer :5-75; logo invert :14; menu toggle :91-104 |
| `portal/login.php` | Login page | gradient card :36-37; standalone Tailwind config :22-33 (accent omitted) |
| `www/index.php` | Homepage patterns | hero :11-33; sections :36-288; cards :47,126-142; CTA band :275-288 |
| `www/assets/logos/skyphoenix-logo.svg`, `favicon.svg` | Brand mark | logo palette #231815 / #b92d26 / #ed6d1f (:5-23 / :37-55) |
| `portal/pages/exports.php` | Only inline `<style>` block | print export styles :223-237 |
| `portal/includes/functions.php` | Status badge conventions | :227-236, :238 |

## Brand-owner supplied artwork (2026-07-20) — not an extraction

Everything above is *extracted* evidence. This section is different in kind: the brand
owner supplied official artwork directly, so it is authoritative source material rather
than a value inferred from a shipped site.

| Supplied | Received as | Disposition |
|---|---|---|
| `logo bunt.png` | 2084×1384 RGBA, transparent | Verified against the vector master; not shipped as source |
| `logo schwarz.png` | 2084×1384 RGBA, pure `#000000` | Verified against derived black variant |
| `logo weiss.png` | 2084×1384 RGBA, pure `#ffffff` | Verified against derived white variant |

Decision: the supplied PNGs were **verified against**, not substituted for, the existing
vector artwork — the mono variants are derived from the vector so they stay scalable.
Verification performed 2026-07-20 (numbers reproduced in `../brand/README.md`): content
aspect ratio 1.5080 (supplied) vs 1.5077 (vector render); solid colours in the supplied
colour PNG exactly `#b92d26` / `#231815` / `#ed6d1f`; derived black and white variants
differ from the supplied files by 1.24% of pixels, all edge anti-aliasing from resampling.

Note `logo schwarz.png` uses pure `#000000`, **not** the wordmark's extracted `#231815`.
That distinction is preserved rather than normalised — see `brand.color.logo-ink` in
`../tokens/base.json`.

Generated assets and the regeneration script live in `../brand/`. The two vector masters
there are the only hand-authored files; everything else is reproducible via
`python3 ../brand/generate.py`.

## Secondary sources (grep-swept; cited where values were found)

`www/dienstleistungen/*`, `www/tools/integrated-toolchain.php` (decorative gradients :40,:161,:263,:349,:533), `portal/pages/team.php` (avatar gradients :90-94), `portal/pages/birthdays.php` (:74), `portal/pages/admin/users.php` (default department color :44,:664,:746), `www/kontakt.php` (form inputs :221-249), `www/referenzen.php` (alt-text usage). Remaining ~35 PHP pages contained no additional custom values.

## Framework context

Both sites load **Tailwind CSS via Play CDN** (unpinned v3.x — `www/partials/header.php:59`, `portal/includes/header.php:104`). All `gray-*`/`blue-*`/etc. classes are Tailwind defaults; only the inline `tailwind.config` blocks and the two custom CSS files carry brand decisions. Tokens marked "utility" in `base.json` record the class-level convention rather than a resolved pixel value.

## Negative findings (checked, absent — recorded so they are not silently invented)

- **No dark theme**: no `prefers-color-scheme`, no `darkMode` config, no toggle → `tokens/dark.json` is proposed-derived, not extracted.
- **No high-contrast mode** → `tokens/high-contrast.json` proposed-derived.
- **Inter never loaded** despite config declaration; no `@font-face`, no font CDN.
- **No charting/data-viz** anywhere.
- **No PNG/ICO favicon fallback; no OG image** (TODO comment `www/partials/header.php:46-47`).
- **No photography assets** (`www/assets/img/` holds only placeholder.txt).
- Portal: **no skip link, no reduced-motion rule**; user zoom disabled (accessibility defects, flagged in brand-guidelines.md).

## Derivation provenance

- `tokens/base.json`, `tokens/light.json`: extracted values only, each with `path:line`.
- `tokens/dark.json`, `tokens/high-contrast.json`: `$status: proposed-derived`; derivation rules stated in-file; only extracted hues or single-step lighter/darker variants of them; **pending brand-owner approval**.

## Coverage note

No files in CompanyWebsite were unreadable; none were modified. Extraction performed by a read-only agent; verified against `.claude/settings.local.json` read-only permission scope.
