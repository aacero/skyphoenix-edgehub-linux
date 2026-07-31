# Cross-Platform Theming Standard

Status: design specification, not implementation. Written 2026-07-20 by the ui-ux-designer role against `tokens/base.json`, `tokens/light.json`, `tokens/dark.json`, `tokens/high-contrast.json`, `brand-guidelines.md`, `component-principles.md`, `references/source-ledger.md` (all in this directory). Every color claim below either cites an existing token file or is computed in this document using the WCAG 2.2 relative-luminance formula, shown in full — no ratio is asserted without the calculation behind it. Values not already extracted are explicitly marked `$status: proposed-derived` and are **not approved for shipping** until a human brand-owner signs off, per `brand-guidelines.md:5` ("never invent colors, spacing, radii, or type values").

Scope: marketing website (PHP/Tailwind), internal web tools/portals, desktop apps, Android (APK), iOS (IPA), CLI/terminal tooling. None of the non-web platforms exist as code in this repository yet (verified: no `.gradle`/`.xcodeproj`/`.swift`/`.kt` files found 2026-07-20) — this document is the contract those future products must satisfy, not a description of something already built.

## 0. Governing decision (brand-owner-approved, 2026-07-20)

The brand owner resolved the long-flagged "logo palette vs UI palette" conflict (`brand-guidelines.md:17`, `base.json:11-13`) as follows. Treat this as **approved input**, not a design proposal:

| Hex | Extracted role (before) | New functional role (approved 2026-07-20) |
|---|---|---|
| `#1e3a5f` (`brand.color.primary`, `base.json:6`) | UI navy | **Unchanged.** Remains the primary structural/trust color — chrome, headers, nav, surfaces. |
| `#ed6d1f` (`brand.color.logo-orange`, `base.json:13`) | Logo-only, "never appears in UI CSS" | **Promoted.** Becomes the CTA / primary call-to-action fill color across all products. |
| `#b92d26` (`brand.color.logo-red`, `base.json:12`) | Logo-only | **Stays logo/brand-moment/marketing-gradient only.** MUST NOT become a functional UI color. This is not a stylistic preference: computed against the extracted danger hue `#dc2626` (`light.json:23`) using the WCAG relative-luminance formula, `#b92d26` vs `#dc2626` measures **1.25:1** — the two reds are effectively indistinguishable from each other. A red CTA or red status chip built from `#b92d26` would be read by users as the existing danger/error state, not as a new brand color. |
| `#231815` (`brand.color.logo-ink`, `base.json:11`) | Logo-only | Unchanged — logo wordmark only. |

**Naming collision — read before using the word "accent":** `base.json:10` already defines `brand.color.accent = #0ea5e9` (Tailwind sky-500, extracted, in active use as a border accent, `www/index.php:134`). The brand owner's brief calls the newly-promoted orange the "accent / primary CTA color," which would collide with this existing, different, already-shipping token if the name `accent` were reused for orange. **This document uses the term "CTA color" for the orange role throughout, specifically to avoid that collision.** The token-naming fix this implies is listed in the report below (not applied here — token files are not owned by this document).

**Hard boundary:** the four hexes above (`#1e3a5f`, `#ed6d1f`, `#b92d26`, `#231815`) plus the existing semantic/UI hexes in `tokens/*.json` are the complete palette. Any new hex — including a hover/pressed step for the CTA color — requires explicit brand-owner approval before it is anything more than a labeled, unverified proposal. Section 1 demonstrates why an algorithmically-derived CTA hover hex is risky enough that it should not be invented casually, even under the "proposed-derived" allowance.

## 1. Accessibility math for the CTA color (binding evidence)

`#ed6d1f` is a mid-saturation orange. Per the WCAG 2.2 relative-luminance formula (`L = 0.2126·R + 0.7152·G + 0.0722·B`, each channel linearized via `((c+0.055)/1.055)^2.4` for `c > 0.03928`), its relative luminance is **L = 0.2905**. All ratios below use `(L_lighter + 0.05) / (L_darker + 0.05)` and were independently computed twice (natural-log and log10 expansions) for cross-check.

### 1.1 Computed ratios

Confirmed by two independent computations (this document's own derivation, and the coordinating orchestrator's separately-run WCAG relative-luminance calculation) converging on the same figures — reported here as the authoritative set for this document:

| # | Pairing | Computed ratio | AA normal text (4.5:1) | AA large text / UI non-text (3:1) | Verdict |
|---|---|---|---|---|---|
| 1 | `#ed6d1f` text on `#ffffff` bg | **3.08:1** | Fail | **Pass** | passes for large text (≥18.66px bold / ≥24px regular) and clears the 3:1 non-text UI floor — it does **not** fail all text use, only normal-size text |
| 2 | `#ffffff` text on `#ed6d1f` fill | **3.08:1** (same pair as #1, roles swapped — ratio is symmetric) | **Fail** | Pass | **the CTA trap — see callout below** |
| 3 | `#231815` (`brand.color.logo-ink`, `base.json:11`) on `#ed6d1f` fill | **5.61:1** | **Pass** | Pass | **recommended CTA text pairing** — stays within the four hard-boundary hexes from §0, no new token needed |
| 4 | `#000000` on `#ed6d1f` fill | **6.81:1** | Pass | Pass | not an extracted or brand token; illustrative ceiling only, not a shipping recommendation |
| 5 | `#ed6d1f` vs `#1e3a5f` (navy, `base.json:6`) | **3.73:1** | Fail | Pass | orange icon/badge on navy chrome is viable; orange body text on navy is not |
| 6 | `#b92d26` (logo red) on `#ffffff` | **6.06:1** | Pass | Pass | only relevant to marketing brand-moment gradients per §0 — not functional UI |
| 7 | `#1e3a5f` (navy) vs `#ffffff` (either direction — ratio is symmetric) | **11.50:1** | Pass | Pass | independently confirmed twice (this document + coordinator). `high-contrast.json:20` previously stated ~10.9:1 for the same pair; **that figure has since been corrected in place to 11.50:1** — 10.9 matched no plausible surface (the nearest, `bg-subtle` `#f9fafb`, gives 11.01:1), so it was an arithmetic slip, not a different pairing |
| 8 | `#b92d26` (logo red) vs `#dc2626` (danger, `light.json:23`) | **1.25:1** | — (not a text pairing; a color-distinguishability check) | — | the two reds are visually near-identical to each other — this is the hard evidence behind §0's quarantine of logo-red from functional UI |

Superseded from an earlier draft of this document: rows previously citing `#111827` (5.75:1) and `#1f2937` (4.76:1) as CTA-text options are retired in favor of `#231815` above. Both older figures were independently re-verified as arithmetically correct (they are not wrong), but `#231815` is preferred because it is already one of the four brand-owner-approved hexes in §0's hard boundary — pairing CTA-fill with CTA-ink needs no additional UI-gray token. A team may still use `#111827`/`#1f2937` (both pass AA, 5.75:1 and 4.76:1 respectively) if it prefers to stay within the established UI-gray family instead of referencing logo ink; both are acceptable, `#231815` is the default.

> **The single most likely implementation mistake — read this before styling any CTA button on any platform:** row 2 above. White text on the resting orange fill is **3.08:1 and fails AA for normal text.** White-on-orange is the instinctive choice for a "primary button" pattern (it's how `button-primary`/`button-secondary`/`button-danger` all already work, `light.json:40,41,43`) and it is the one choice that does not work for this specific fill color. **Every CTA/primary-button specification on every platform (§2.3's code snippets, any future design spec, any implementation) MUST use `#231815` (or `#000000`) label text on the orange fill, never white.**

### 1.2 Usage matrix (binding for new products)

| Context | Rule |
|---|---|
| CTA button / filled chip / primary action surface | Fill = `#ed6d1f`. Text/icon on the fill = `#231815` (row 3, 5.61:1) — the recommended default. `#111827`/`#1f2937` (UI-gray family, 5.75:1/4.76:1) remain acceptable alternates. **Never** white text on the resting fill (row 2, 3.08:1 fails AA — see the callout above §1.2). |
| Orange as body/link text on a white or light surface | **Not recommended for normal-size text.** Row 1 (3.08:1) fails AA for normal text. It does legitimately pass at large-text size (≥18.66px bold / ≥24px regular) and clears the 3:1 UI-component floor — but the margin over 3.0 is only 0.08, inside typical rendering/anti-aliasing variance, so treat the large-text pass as marginal, not a safe general-purpose rule. |
| Orange as a thin icon stroke on white | **Avoid.** Row 1's raw number (3.08:1) technically clears the WCAG 1.4.11 non-text 3:1 floor, but thin strokes lose effective contrast to sub-pixel rendering and anti-aliasing in a way a flat luminance ratio does not capture. Use a filled/solid orange shape, or pair with a dark outline, or use the fill+dark-text pattern instead. |
| Orange as icon/badge/accent stripe on navy chrome | Permitted (row 5, 3.73:1 clears the 3:1 non-text/large-text floor with a real margin) — not for small body text on navy. |
| Orange directly as text/icon on a **dark-mode background** (`#111827`, the extracted footer-bg reused as `dark.json`'s app background, `dark.json:27`) | Permitted — this is the same numeric pair as row 3 (5.61:1 for `#231815`, or use `#111827`'s own 5.75:1 self-pairing if that reads confusingly, both pass), because contrast ratio is symmetric regardless of which side is "background." This is a genuinely different answer from the light-mode rule above and is easy to get wrong by assuming symmetry with light mode. **`dark.json` has no CTA entry yet; this is a proposal, see §2.5, pending the same brand-owner approval every other `dark.json` value requires (`dark.json:2`).** |
| Red (`#b92d26`) anywhere in product UI (buttons, badges, alerts, links) | **Forbidden** per §0 — reserved for logo and marketing-only brand moments. Row 6 shows it is contrast-safe for white text in that narrow context (e.g. a hero gradient stop); row 8's **1.25:1** against `danger` (`#dc2626`) is the reason it must stay confined to non-functional brand moments — the two reds are practically indistinguishable and would be read as an error state. |
| High-contrast mode (`forced-colors` / `tokens/high-contrast.json`) CTA | `high-contrast.json` targets **≥7:1 for normal text, 4.5:1 floor only for large text** (`high-contrast.json:6`). The best available CTA-on-fill pairing (row 3, 5.61:1) **does not clear 7:1** — it only clears the large-text floor. In high-contrast/forced-colors mode: either render CTA labels at the large-text threshold (≥18.66px bold / ≥24px regular) to legitimately use the 4.5:1 floor, or fall back to the navy+white pairing already certified in `high-contrast.json:20-21` (`brand-surface`/`text-on-brand`, **11.50:1**) and treat orange as a non-text accent only in this mode. |

### 1.3 CTA hover/pressed state — worked example, not a shipped value

No extracted hover hex exists for orange (unlike `button-primary`'s `primary-dark` or `button-secondary`'s `#2563eb`, both of which are separately extracted hexes, not algorithmic darkens — `light.json:40-41`, `component-principles.md:9`). To show why this file does **not** propose a specific hover hex as usable, two HSL-lightness-reduced candidates were computed (same hue 22.72°, same saturation 85.12%, only lightness reduced — method fully disclosed so it is falsifiable):

| Candidate | Method | Approx. hex (rounded) | White text on it | `#231815` text on it (recommended CTA-ink, §1.1 row 3) |
|---|---|---|---|---|
| A | L 52.55% → 42.55% (−10pt) | `#C95610` | 4.36:1 — fails | 3.98:1 — fails |
| B | L 52.55% → 39.55% (−13pt) | `#BB500F` | 4.92:1 — passes | 3.52:1 — fails |

Neither candidate keeps a single text color compliant across both the resting fill (which needs dark text, row 3) and a naively-darkened hover fill (which trends toward needing white text as it darkens). Swapping text color between resting and hover states is bad practice (flicker, inconsistent perceived brand color) — and note candidate A/white is itself right next to the same 3.08:1 white-on-orange trap flagged above, just shifted to a different fill lightness. **Recommendation: do not derive a CTA hover state by hue-darkening.** Reuse the extracted, hue-invariant hover pattern already used for cards (`component-principles.md:13`: soft shadow + ≤2px lift, `base.json` `motion.hover-lift`/`duration-fast`) — i.e., CTA hover = same fill, same `#231815` text, add elevation (`shadow.card-hover` family, `base.json:63-64`) and the existing `≤2px` lift. This requires no new hex and no new contrast verification because the fill/text pair does not change. If a brand-owner wants a genuine color-shift hover, request a specific supplied hex (like `primary-dark` and `#2563eb` were) and re-run this section's contrast math against it before shipping — candidates A/B above exist only to demonstrate the failure mode, not as shippable tokens (both marked `$status: proposed-derived`, **unverified**, not for use).

## 2. Token pipeline: one source, generated per-platform artifacts

### 2.1 Status: no generator exists

`tokens/base.json`, `tokens/light.json`, `tokens/dark.json`, `tokens/high-contrast.json` are hand-authored JSON with no build step. No script in `scripts/agent-framework/` or elsewhere in this repo reads them and emits platform artifacts (verified 2026-07-20). Every artifact shown in §2.3 is illustrative of the *contract* a future generator must satisfy — it is future work, not delivered functionality. Treat this whole section as a specification for whoever builds `scripts/design-tokens/generate.*` (or equivalent), not as evidence that generated files exist.

This is distinct from `agent-framework/design-system/brand/generate.py`, which **does exist and does work** (§5) — that script regenerates icon/logo raster and derived-variant *assets* from two vector masters. It solves a narrower problem (asset derivatives from fixed artwork) than the token-to-platform-artifact pipeline this section specifies (structured color/spacing/type values to per-language constants); the two should not be conflated or merged.

### 2.2 Generator contract (binding once built)

1. **Single source of truth.** Reads only `tokens/base.json` + one theme file (`light.json`/`dark.json`/`high-contrast.json`) per output; never hand-edits generated artifacts (generated files carry a header banner forbidding manual edits, mirroring `agent-framework/canonical/` → provider-file generation via `scripts/agent-framework/render.py`).
2. **Deterministic.** Same token input → byte-identical output; no timestamps or non-reproducible content in the generated file body (a header comment noting generation date/source commit is fine).
3. **Fails loudly, never silently substitutes.** A token referenced by an output template but missing from the JSON is a build error, not a fallback to a default or an invented value — this is the same "never invent" discipline as `brand-guidelines.md:5`, enforced mechanically instead of by review.
4. **Preserves provenance.** Each generated declaration carries a comment citing the token's `$extensions.source` (or `proposed-derived` status) from the JSON, so a platform engineer looking at `colors.xml` or `Color.kt` can trace a hex back to `path:line` in `CompanyWebsite` (or to this document's proposals) without opening the JSON.
5. **Emits all four themes** for platforms that support runtime theme switching (web, desktop, Android, iOS); emits **light only** for the ANSI/terminal target with a documented rationale (§3.5) rather than silently dropping dark/high-contrast.
6. **One template family per output shape** (CSS custom properties, Tailwind config fragment, Android XML, Kotlin, iOS asset catalog JSON, Swift, ANSI table) so adding a fifth platform means adding one template, not touching the other four.

### 2.3 Representative token → output-format mapping

Two representative tokens, chosen because they span "raw brand hex" (`brand.color.primary`) and "dimension" (`radius.md`), plus the CTA proposal from §1 for concreteness:

| Token | Value | Source |
|---|---|---|
| `brand.color.primary` | `#1e3a5f` | `base.json:6`, extracted |
| `radius.md` | `0.5rem` | `base.json:53`, extracted |
| `semantic.color.cta-fill` (proposed, §2.5) | `#ed6d1f` | reuses `base.json:13`'s extracted hex under a new semantic role — not a new hex |

**Web (CSS custom properties):**
```css
/* GENERATED — do not edit. Source: tokens/base.json (2026-07-20), theme=light */
:root {
  --color-brand-primary: #1e3a5f;   /* base.json:6 */
  --radius-md: 0.5rem;              /* base.json:53 */
  --color-cta-fill: #ed6d1f;        /* base.json:13, promoted role — see cross-platform-standard.md §0 */
  --color-cta-on-fill: #231815;     /* base.json:11 logo-ink, 5.61:1 on --color-cta-fill — §1.1 row 3 */
  /* NEVER pair --color-cta-fill with #ffffff text: 3.08:1, fails WCAG AA normal text — §1.1 row 2 */
}
```

**Web (Tailwind config fragment):**
```js
// GENERATED — do not edit.
module.exports = {
  theme: {
    extend: {
      colors: { 'brand-primary': '#1e3a5f', 'cta': '#ed6d1f' },
      borderRadius: { md: '0.5rem' },
    },
  },
};
```

**Android (`colors.xml`):**
```xml
<!-- GENERATED — do not edit. Source: tokens/base.json (2026-07-20) -->
<resources>
    <color name="brand_primary">#FF1E3A5F</color>
    <color name="cta_fill">#FFED6D1F</color>
</resources>
```

**Android (Compose `Color.kt` + Material3 mapping):**
```kotlin
// GENERATED — do not edit. Source: tokens/base.json (2026-07-20)
val BrandPrimary = Color(0xFF1E3A5F)
val CtaFill = Color(0xFFED6D1F)
val CtaOnFill = Color(0xFF231815) // base.json:11 logo-ink, 5.61:1 on CtaFill — see cross-platform-standard.md §1.1 row 3
// NEVER Color.White on CtaFill for label/icon text: measures 3.08:1, fails WCAG AA normal text (§1.1 row 2).

val SkyPhoenixLightColorScheme = lightColorScheme(
    primary = BrandPrimary,
    // Material3's `secondary`/`tertiary` roles are NOT a 1:1 map to our
    // `secondary`(#3b82f6)/`cta`(#ed6d1f) — role mapping needs an explicit
    // decision at generator-build time, not an assumption. Flagged, not resolved here.
)
```
`radius.md` (0.5rem = 8dp at the standard 1rem=16px/16dp base) maps to Compose `RoundedCornerShape(8.dp)`; Material3 also has its own named shape scale (`small`/`medium`/`large` corner tokens) that a real integration must reconcile with our four-step radius scale (`base.json:51-55`) rather than silently picking one.

**iOS (asset catalog `Colors.xcassets/BrandPrimary.colorset/Contents.json`):**
```json
{
  "colors": [
    { "idiom": "universal", "color": { "color-space": "srgb", "components": { "red": "0x1E", "green": "0x3A", "blue": "0x5F", "alpha": "1.000" } } },
    { "idiom": "universal", "appearances": [{ "appearance": "luminosity", "value": "dark" }],
      "color": { "color-space": "srgb", "components": { "red": "0x1E", "green": "0x3A", "blue": "0x5F", "alpha": "1.000" } },
      "$note": "dark-variant RGB placeholder — tokens/dark.json has no brand-hue override (brand hues are reused unchanged per dark.json:5); fill in from generator, not by hand" }
  ],
  "info": { "version": 1, "author": "generated" }
}
```

**iOS (SwiftUI `Color` extension):**
```swift
// GENERATED — do not edit. Source: tokens/base.json (2026-07-20)
extension Color {
    static let brandPrimary = Color("BrandPrimary") // resolves via asset catalog, honors system appearance
    static let ctaFill = Color("CtaFill")
    static let ctaOnFill = Color("CtaOnFill") // #231815, base.json:11 logo-ink — 5.61:1 on ctaFill, see §1.1 row 3
    // NEVER Color.white as CTA label/icon text on ctaFill: 3.08:1, fails WCAG AA normal text (§1.1 row 2).
}
```

**Terminal / ANSI subset:** ANSI's 16-color palette has no orange slot and its 8/16 base colors are themselves terminal-theme-dependent (not fixed hex) — any mapping is a best-effort semantic approximation, not a color match:

| Semantic token | Truecolor (24-bit, when supported) | 256-color fallback | 16-color fallback | Notes |
|---|---|---|---|---|
| `brand.color.primary` (#1e3a5f) | `\x1b[38;2;30;58;95m` | `\x1b[38;5;24m` (~closest 256-palette navy) | `\x1b[34m` (blue) | 16-color has no navy; falls back to plain blue |
| `semantic.color.cta-fill` (#ed6d1f, proposed) | `\x1b[38;2;237;109;31m` | `\x1b[38;5;208m` (`#ff8700`, closest 256-color orange) | `\x1b[33m` (yellow) | 16-color has no orange either; yellow is the least-wrong slot |
| `semantic.color.danger` (#dc2626) | `\x1b[38;2;220;38;38m` | `\x1b[38;5;196m` | `\x1b[31m` (red) | |
| `semantic.color.success-text` (#166534) | — | `\x1b[38;5;22m` | `\x1b[32m` (green) | |
| `semantic.color.warning-text` (#92400e) | — | `\x1b[38;5;130m` | `\x1b[33m` (yellow) — collides with the CTA fallback above | 16-color mode cannot distinguish CTA-orange from warning; CLI tools MUST NOT rely on color alone to distinguish these two roles at the 16-color tier (consistent with `component-principles.md:29`'s "status must also be readable as text" rule) |
| `semantic.color.info-text` (#1e40af) | — | `\x1b[38;5;25m` | `\x1b[34m` (blue) | |

Every CLI tool MUST respect `NO_COLOR` (unset or empty disables all color, per the community `NO_COLOR` convention) and `TERM=dumb`, and MUST NOT be the sole channel for any state (see the 16-color collision above).

### 2.4 Platform artifact status table

| Platform | Artifact | Format | Status |
|---|---|---|---|
| Marketing site / portal (web) | CSS custom properties + Tailwind config fragment | `.css` / `.js` | Not generated; hand-authored today (`www/assets/css/custom.css`, inline Tailwind configs) — generator is future work |
| Desktop (stack TBD — Electron/Tauri/native, not yet chosen at the template level) | CSS custom properties (Electron/Tauri, web-based UI) or platform-native color assets (fully native) | varies by stack | No desktop product exists yet; contract only |
| Android | `colors.xml`, Compose `Color.kt`, Material3 `ColorScheme` | XML / Kotlin | No Android product exists yet; contract only |
| iOS | Asset catalog color sets, SwiftUI `Color` extension | `.xcassets` JSON / Swift | No iOS product exists yet; contract only |
| CLI/terminal | ANSI escape table (above) | shell-embeddable constants (language TBD per tool) | No CLI product exists yet; contract only |

### 2.5 New tokens this document needs (proposed, not applied — see closing report)

None of these exist in `tokens/*.json` today. Listed here so implementers know what to ask the token owner for; **not created by this document** (out of owned-files scope):

- `semantic.color.cta-fill` (light) = `{brand.color.logo-orange}` — reuses the existing extracted hex under a new role name, no new hex.
- `semantic.color.cta-text-on-fill` (light) = `{brand.color.logo-ink}` (`#231815`, 5.61:1, §1.1 row 3) — deliberately references the existing brand-ink hex rather than a UI-gray token (`text-heading`/`text-primary`, both also computed as passing, 5.75:1/4.76:1, and acceptable alternates) so the CTA pairing stays inside the four brand-owner-approved hexes from §0 without introducing a new UI-gray dependency.
- `semantic.color.cta-fill-hover` — **intentionally not proposed** (§1.3); either request a brand-owner hex or use the elevation-only hover pattern that needs no new token.
- `dark.json` equivalents of the two `cta-*` tokens above, reusing the same hexes unchanged (consistent with `dark.json:5`'s own stated derivation rule that brand hues are never altered between themes) — still requires the same brand-owner approval every other `dark.json` entry requires, per `dark.json:2`.
- `high-contrast.json` has no CTA concept at all today; per §1.2's high-contrast row, this needs an explicit decision (large-text-only orange CTA, or navy+white fallback), not a silent addition.

## 3. Light / dark / high-contrast per platform

| Platform | System-theme signal | How it's applied | Maturity |
|---|---|---|---|
| Marketing site (www) | `prefers-color-scheme` media query (not implemented — site is light-only, `references/source-ledger.md:31`) | CSS custom-property swap under the media query, once `dark.json` is approved | Light is the only certified theme (`brand-guidelines.md:34`) |
| Portal (internal web) | Same as above; portal has neither a toggle nor a media query today | Same swap mechanism as www, applied consistently — do not let the two web surfaces diverge in *how* they switch even before either has a dark theme | Same as above |
| Desktop (stack TBD) | Illustrative only (no product exists): Electron's `nativeThemeSource`/`nativeTheme.shouldUseDarkColors`; a fully native shell would read macOS `NSApplication.effectiveAppearance` or Windows `UISettings`/`AppsUseLightTheme` registry value | Same generated CSS-custom-property or native-color-asset swap as the chosen shell supports | Not built; stack decision deferred to the product repo, not this document |
| Android | `Configuration.uiMode` / Compose `isSystemInDarkTheme()` | Material3 `ColorScheme` swap (light/dark `ColorScheme` objects built from the generated `Color.kt` constants) | Not built. **Material You dynamic color** (Android 12+, wallpaper-derived palette) is a genuine platform capability — see §4 for the ALLOWED/FORBIDDEN ruling on it |
| iOS | `UITraitCollection.userInterfaceStyle` / SwiftUI `@Environment(\.colorScheme)` | Asset-catalog color sets carry both appearances (see §2.3 example); no manual `if` branching on color needed if assets are built correctly | Not built |
| High contrast — web | `forced-colors` media query (Windows High Contrast) + explicit `prefers-contrast: more` | Respect system colors under `forced-colors`; never override the OS palette (`high-contrast.json:8`, `brand-guidelines.md:35`) | Proposed theme only |
| High contrast — Android | System "High contrast text" accessibility setting | Material3 supports a high-contrast `ColorScheme` variant; must map to our `high-contrast.json`, not invent a separate one | Not built |
| High contrast — iOS | `UIAccessibility.isDarkerSystemColorsEnabled` / Increase Contrast | Asset catalog "high contrast" appearance variant | Not built |
| CLI/terminal | No reliable OS-level signal exists; terminals own their own color palette | Do not attempt to detect/override the terminal's theme at all — emit the semantic ANSI/truecolor codes in §2.3 and let the terminal's own palette (which the user or terminal emulator already controls, including any high-contrast terminal theme) render them | The terminal case is effectively always "system," by design — there is no meaningful "our app's dark mode" distinct from the terminal's own |

## 4. Platform-native divergence: allowed vs forbidden

Enterprise users expect native affordances. Forcing pixel-identical UI across Android/iOS is itself a usability defect, not consistency. This section draws the line explicitly.

### 4.1 ALLOWED (native idiom takes precedence)

| Platform | Allowed native divergence |
|---|---|
| Android | Material 3 components (FAB, bottom navigation, snackbars, ripple feedback), Material's tonal-elevation surfaces instead of literal `box-shadow` values, system back gesture, Material type scale mechanics (the concrete weight/size *roles* in §4.2 still apply, the pixel implementation doesn't have to match CSS). **Material You dynamic color may be offered as an explicit opt-in** (a settings toggle a user turns on), but **must not be the default** — the default theme is always the brand `ColorScheme` built from our tokens, because dynamic color would silently replace the CTA-orange role with a wallpaper-derived hue with no contrast guarantee, undoing §1's work. |
| iOS | HIG components (large titles, tab bar, swipe-back gesture, native sheet presentations, SF Symbols instead of a custom icon font), Dynamic Type as the primary text-scaling mechanism, native corner-curve rendering ("squircle" continuous corners) for the *rendering* of our radius tokens — using the platform's native corner algorithm at our radius values is allowed; using a different radius scale is not. |
| Desktop | Native window chrome, OS-native file/print dialogs, platform keyboard-shortcut conventions (Cmd vs Ctrl), OS menu-bar conventions on macOS. |
| CLI | No visual system beyond §2.3's ANSI subset; Unix CLI conventions (`--help`, exit codes, `--no-color`) govern, not "brand" affordances. |
| All | Localized microcopy, locale-appropriate date/number/currency formatting. |

### 4.2 FORBIDDEN — must stay invariant across every platform

- **Logo integrity.** Correct variant (color/black/white/mono) for the background it sits on, per `brand/README.md`'s own "Which variant on which background" table (color on light surfaces; white — never color — on navy/photo/dark UI, because the `#231815` wordmark disappears on navy; black for single-color print; `mono`, which resolves via CSS `currentColor`, for inlining into themed components). No stretching, no recoloring outside the four brand hexes (`#231815`/`#b92d26`/`#ed6d1f`, plus pure black/white for the single-color variants). Clear space: free space around the lockup equal to the height of the "S" in "SKY" on all sides (`brand/README.md:45-46`, brand-owner-supplied, no longer an open item). Minimum size: full lockup ≥120px wide on screen / 24mm print; below that, use the mark alone (`brand/README.md:47-48`).
- **Color roles**, per §0: navy = structural/trust, orange = CTA, red = logo/marketing-only, `#dc2626` family = danger. No platform may silently reassign these (the Material You caveat in §4.1 is the one explicit, opt-in exception, and even it must default off).
- **Type hierarchy** — the weight/role semantics (500 controls/nav, 600 headings, 700 display/stat, `brand-guidelines.md:13`) even though the concrete typeface differs per platform (system UI font on each). New products must decide deliberately whether to load a real webfont or standardize on system stack — "cargo-cult `Inter`" without loading it (the extracted site's own bug, `brand-guidelines.md:13`) must not be repeated on any platform, including a similarly-unloaded custom font on Android/iOS.
- **Spacing rhythm** — the `base.json` spacing scale, converted to each platform's native unit (Android dp, iOS pt) at the 1rem = 16px/16dp/16pt base already implied by the extracted rem values.
- **Radius family** — the four-step scale (`0.375rem`/`0.5rem`/`0.75rem`/pill, `base.json:51-55`) must still read as "soft," even where the native corner-rendering algorithm differs (§4.1's iOS allowance is about *rendering*, not about picking sharper or larger radii).
- **Motion budget** — `0.15–0.3s` ease, `≤2px` hover lift, the single spinner style, and `prefers-reduced-motion` honored everywhere (`base.json:69-73`; currently a real gap even on web — portal has no reduced-motion rule, `brand-guidelines.md:12`, `references/source-ledger.md:37`). Every platform must map this to its own reduced-motion signal (Android's "Remove animations" accessibility setting / `Settings.Global.ANIMATOR_DURATION_SCALE`, iOS `UIAccessibility.isReduceMotionEnabled`) rather than only supporting the web media query.
- **Accessibility floor** (§6) — non-negotiable regardless of platform idiom.

## 5. App icon, launch screen, and splash requirements

**Assets now exist.** `agent-framework/design-system/brand/` was populated by the brand owner on 2026-07-20 (`brand/README.md:3`) — this is no longer a forward-looking contract for an empty directory; the concrete files below are real, verified (`brand/README.md:87-108`), and generated from two vector masters by `brand/generate.py` (a real, working *asset* generator — distinct from the design-*token* generator described in §2, which still does not exist). Every path below was confirmed present in this repository on 2026-07-20.

### 5.1 Android — adaptive icons

- Adaptive icon canvas: **108×108dp**, two layers (foreground + background).
- **Safe zone: a 66dp-diameter circle centered in the canvas.** Only content inside that circle is guaranteed visible after the system applies its mask (circle, squircle, rounded-square, or manufacturer-specific shape) — logo mark must stay inside it; the background layer may bleed to the canvas edge since it's the part that gets cropped by the mask. `brand/icons/icon-{192,512}.png` (transparent, `brand/README.md:23`) are the source rasters for the foreground layer; the background layer is a solid navy `#1e3a5f` fill (§0's structural role) — do not default to orange as the background fill, since it has not been evaluated as an icon-chrome color, only as a CTA fill.
- Legacy/round launcher icon export table (48dp base grid): mdpi 48px, hdpi 72px, xhdpi 96px, xxhdpi 144px, xxxhdpi 192px, derived from the same rasters. Play Store listing icon: 512×512px (`brand/icons/icon-512.png` is already at this size).
- **Themed/monochrome icons (Android 13+):** `brand/icons/icon-monochrome-512.png` (`brand/README.md:25`) is the dedicated asset for Android's system icon theming (the OS tints this single-color icon to match the user's wallpaper-derived palette). This is an OS-level *icon* affordance, not the in-app Material You dynamic-color question decided in §4.1 — the app's own UI palette is unaffected; only the launcher icon is tinted. Ship it, since it is opt-in at the OS level and does not touch the app's CTA/structural color roles.

### 5.2 iOS — app icon

- `brand/icons/apple-touch-icon-180.png` (`brand/README.md:22`) is already opaque with no baked corner radius, verified (`brand/README.md:106`) — use it (or a same-master 1024×1024 export) as the single master in the asset catalog's App Icon set. **No alpha channel — must be fully opaque.** If a target still requires the legacy multi-size set, generate 20/29/40/60/76/83.5pt at @1x/@2x/@3x from the same master, never hand-authored per size.
- **No pre-baked rounded corners** — iOS applies its own corner mask at render time; the supplied asset already respects this (verified, `brand/README.md:106`).
- No drop shadows, no borders baked into the icon.
- Splash / narrow contexts: `brand/README.md:112-114` records that **no stacked/vertical lockup and no wordmark-only asset exist** — only the horizontal lockup (`logo/skyphoenix-logo-*.svg`) and the mark (`mark/skyphoenix-mark-*.svg`). A portrait iOS launch screen or square avatar context MUST use the mark alone, per the brand owner's own stated pattern — **do not compose a stacked lockup from the horizontal one**; if a real stacked lockup is needed, that is a brand-owner request, not something to improvise here (same "never invent" discipline as `brand-guidelines.md:5`).

### 5.3 PWA — maskable and non-maskable icons

- Per the W3C maskable-icon spec: safe zone is a centered circle at 80% of the icon's width/height. The supplied `brand/icons/icon-maskable-{192,512}.png` are verified at **~59.9% actual coverage, inside that 80% safe zone** (`brand/README.md:107-108`) — comfortably safe, not edge-hugging.
- Manifest must declare both `"purpose": "any"` (`brand/icons/icon-192.png` / `icon-512.png`, transparent, natural padding, `brand/README.md:23`) and `"purpose": "maskable"` (`brand/icons/icon-maskable-192.png` / `icon-maskable-512.png`, opaque, `brand/README.md:24`) — use `brand/README.md:75-85`'s manifest JSON verbatim as the reference shape.
- `apple-touch-icon` 180×180 is `brand/icons/apple-touch-icon-180.png` (§5.2) — iOS does not follow the W3C maskable spec but does apply its own rounding, and the asset is already safe-zone-respecting.
- Favicon: `brand/icons/favicon.svg` (primary, square, ink-centred — actually ink-free: the mark uses only `#b92d26`/`#ed6d1f`, no near-black, so it is "theme-safe by construction" and reads on both light and dark browser chrome without a separate dark-mode favicon, `brand/README.md:49-53`) plus `brand/icons/favicon.ico` (legacy, 16–256px, `brand/README.md:20`) and the explicit `brand/icons/favicon-{16..256}.png` PNG sizes. This resolves the extraction's **negative finding** of "no PNG/ICO favicon fallback, no OG image" (`references/source-ledger.md:35`, `www/partials/header.php:46-47` TODO) — the fix now exists as an asset; wiring it into `CompanyWebsite` (a separate, read-only sibling repo, not part of this template) is out of this document's scope but should be flagged to that product's owner. Use `brand/README.md:59-73`'s HTML wiring block verbatim (`<link rel="icon">`, `apple-touch-icon`, `manifest`, `og:image` meta tags) — do not hand-roll a different favicon `<link>` set.
- Open Graph / social preview: `brand/social/og-image-1200x630.png` (`brand/README.md:26`), wired via the same HTML block (`og:image`, `og:image:width/height`, `twitter:card`).

### 5.4 Launch / splash screens

| Platform | Rule |
|---|---|
| Android 12+ | Use the system Splash Screen API (icon + solid background color derived from the adaptive icon's foreground/background layers, §5.1) — do not hand-roll a custom splash Activity/image; Material guidance is themed system splash, not custom art. |
| iOS | Static launch screen (Storyboard or SwiftUI launch screen), brand navy `#1e3a5f` background with the **mark alone** centered (§5.2 — no stacked lockup exists) — no loading text, no progress indicator, no marketing copy, per HIG (a launch screen is meant to look like the app's first frame, not a splash ad). |
| PWA | `manifest.json` `"background_color"` = `#1e3a5f` (matches the extracted hero-gradient identity color, `base.json:16`), `"theme_color"` = `#1e3a5f` — do not use orange for either; these are structural/chrome roles per §0, not CTA roles. |

### 5.5 Accessible naming (reused from `brand/README.md`, not restated with different rules)

`brand/README.md:54-57` already states the rule: standalone SVGs carry a `<title>`; when inlining, either supply an accessible name on the host element or mark the graphic `aria-hidden="true"` if decorative and the company name is already adjacent as visible text — never announce the name twice to a screen reader. This document points to that rule rather than duplicating it, consistent with §6's "reused not restated" approach to accessibility rules generally.

## 6. Accessibility floor (binding, reused not restated)

This section maps the accessibility rules that are **already binding** in `brand-guidelines.md` to each platform's equivalent mechanism. The rules themselves are not restated with different numbers here — that would risk drift between two "sources of truth." Where a platform needs a different *mechanism* to satisfy the same rule, that mechanism is named; the underlying number always traces back to `brand-guidelines.md`.

| Rule (binding, see citation) | Web mechanism | Android mechanism | iOS mechanism |
|---|---|---|---|
| 44px minimum touch target (`base.json:49`, `brand-guidelines.md:48`) | `min-height`/`min-width: 44px` (already the extracted mobile pattern, `portal.css:310-311`) | 48dp minimum touch target (Material's own floor, slightly larger than 44px/44dp — use 48dp, the stricter of the two, don't downgrade to 44dp on Android) | 44pt minimum (Apple HIG's own stated floor — matches the extracted value exactly, no conversion needed) |
| Visible 2px focus outline + 2px offset (`component-principles.md:50-52`, `custom.css:40-47`) | CSS `:focus-visible` outline, never `outline: none` without an equal-or-better replacement | Compose/View focus-highlight ring (system-provided on TV/keyboard-nav contexts; must not be suppressed) — touch-primary Android has no persistent focus ring by convention, but any keyboard/switch-access user must get one | Focus ring for keyboard/Full Keyboard Access and Switch Control; VoiceOver's own focus indicator must never be suppressed |
| `prefers-reduced-motion` honored (`base.json:73`, gap on portal flagged `brand-guidelines.md:12`) | `@media (prefers-reduced-motion: reduce)` — currently only implemented on www, portal gap is a known defect to fix, not a pattern to copy | `Settings.Global.ANIMATOR_DURATION_SCALE` / "Remove animations" accessibility setting | `UIAccessibility.isReduceMotionEnabled` |
| Never block user zoom (`brand-guidelines.md:45`, portal's `user-scalable=no` defect, `portal/includes/header.php:93`) | Never set `user-scalable=no` or `maximum-scale=1` in the viewport meta tag — this is a defect in the extracted portal to fix, not inherit | Respect system font-scale (`fontScale`) and display-size settings; do not clip text at 200% scale | Support Dynamic Type up to accessibility sizes; do not disable pinch-to-zoom in any `WKWebView` content |
| Contrast rules (§1 of this document + `brand-guidelines.md:41-46`) | As computed in §1 | Same computed values apply — a hex is a hex regardless of platform; Android must not re-derive its own contrast numbers | Same computed values apply |
| Status/meaning never conveyed by color alone (`component-principles.md:29`) | Text + color for badges/alerts | Same — plus: do not let Material You dynamic color (§4.1) become the only signal for a status role, since a dynamic palette can shift the danger/success hues relative to each other in ways not contrast-checked here | Same |

## 7. How to add a new product — checklist

1. Read this document, `brand-guidelines.md`, and the relevant `tokens/*.json` files before writing any UI code. Do not start from a competitor's or a generic template's design system.
2. Confirm which theme(s) the product ships: light is the only certified theme today (`brand-guidelines.md:34`); dark/high-contrast require brand-owner approval before use, regardless of platform.
3. Consume tokens through the generated per-platform artifact (§2) once the generator exists; until it exists, hand-transcribe token values with a comment citing the exact `path:line` source, the same discipline `tokens/*.json` itself uses — never eyeball a color from a screenshot or a competing app.
4. Apply the CTA color rules from §1.1–1.2 exactly — fill `#ed6d1f` + `#231815` text (never white — 3.08:1 fails AA, this is the single most common implementation mistake, §1.1 row 2), never orange as normal-size body/link text on light backgrounds, never a color-shifted hover without a supplied, re-verified hex.
5. Decide the platform-native divergence line using §4 before building components — write down (in the product's own design-spec, not here) which components will be platform-native (Material3/HIG) and which will follow the shared visual language, and why.
6. Verify the accessibility floor (§6) with actual computed contrast ratios for anything not already covered in §1 — do not assert a ratio you did not compute, and do not accept another role's or another product's contrast claim as evidence without re-running it, per the evidence policy.
7. Ship app icons/splash per §5, using the real assets at `agent-framework/design-system/brand/` — do not regenerate, redraw, or re-derive icon variants by hand; if a needed asset is missing (e.g. a stacked lockup, §5.2), request it from the brand owner rather than composing one.
8. Run the `ui-ux-review` skill checklist (per `AGENTS.md`'s "UI work" section) including accessibility and visual-regression evidence before calling any screen done.
9. If the product introduces a genuinely new color, spacing, radius, or type value not covered by `tokens/base.json` or this document, stop and file it as a brand-owner-approval request — do not add it to product code as a local override and do not add it to `tokens/*.json` yourself.
