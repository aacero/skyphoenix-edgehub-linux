# SKYPhoenix Brand Guidelines (Extracted)

- Extracted from `~/IdeaProjects/CompanyWebsite` (read-only) on 2026-07-18. Every value carries `path:line` evidence — see `tokens/*.json` and `references/source-ledger.md`.
- Token layers: **immutable brand tokens** (`tokens/base.json`, extracted) → **semantic tokens** (`tokens/light.json` extracted; `dark.json` / `high-contrast.json` proposed-derived) → **component tokens** (`component-principles.md`) → **product-specific overrides** (live in the product repo, never here).
- Rule for agents: **never invent colors, spacing, radii, or type values.** If a needed token is missing, file a backlog candidate for the brand owner; do not improvise.

## Brand principles

1. **Calm enterprise navy.** The UI identity is deep navy `#1e3a5f` with functional blue `#3b82f6` — professional, restrained, content-first (white/near-white surfaces, generous section spacing `py-16 lg:py-24`).
2. **One brand gradient.** `linear-gradient(135deg, #1e3a5f 0%, #152a45 100%)` for hero/identity moments only (hero, login, avatars) — not for content surfaces.
3. **Soft geometry.** Cards `0.75rem`/rounded-xl, controls `0.5rem`, pills full-round. 1px quiet borders (`#e5e7eb`) with `shadow-sm` at rest; elevation appears on hover (small lift + soft shadow), not at rest.
4. **Subtle motion.** 0.15–0.3s ease transitions; hover lift ≤2px; a single spinner keyframe. Nothing attention-seeking; `prefers-reduced-motion` must be honored everywhere (currently www-only — portal gap flagged).
5. **System typography in practice.** Config declares Inter but never loads it; the shipped experience is the system UI stack. Weights: 500 controls/nav, 600 headings/table-headers, 700 display/stat values. Decide deliberately: either actually load Inter or standardize on the system stack — do not cargo-cult `Inter` into new products without loading it.

## Brand assets

Official logo, mark and icon assets live in `brand/` — see `brand/README.md` for the
variant matrix, clear space, minimum sizes and web wiring. Supplied by the brand owner on
2026-07-20; these are authoritative source artwork, not extracted values.

## Audience scope

SKYPhoenix is **B2B-first and also ships consumer products.** Most of this design system was
extracted from enterprise surfaces and reads as enterprise-only; that is a property of where
the values came from, not a statement that consumer products are out of scope.

- Identity-level rules — logo, colour roles, the CTA contrast rule, the accessibility floor,
  token discipline — apply to **everything**.
- Audience-dependent rules — language, register, information density, proof style, buying
  flow — are set out in `consumer-products.md`. Sections below that are marked as
  B2B-scoped say so explicitly.

## Logo vs UI palette — RESOLVED 2026-07-20 (brand owner)

Previously flagged as an unresolved inconsistency: the logo is near-black/brick-red/orange
(`#231815`, `#b92d26`, `#ed6d1f`), the UI is navy/blue, and neither palette appeared in the
other. The brand owner resolved it by assigning each colour a **role** rather than picking
a winner:

| Colour | Role | Rules |
|---|---|---|
| `#1e3a5f` navy | **Primary structural / trust.** Chrome, headers, nav, hero surfaces, primary buttons | Unchanged — remains the dominant UI colour |
| `#ed6d1f` phoenix orange | **Accent / call-to-action.** The one colour that says "act here" | Fill only, never as text on white — see below |
| `#b92d26` phoenix red | **Logo and brand moments only.** Marketing gradients, splash | MUST NOT become a functional UI colour |
| `#231815` logo ink | Logo wordmark only | Body text keeps the extracted `light.json` text tokens |

Two constraints that make this safe rather than decorative:

- **Orange is a fill colour, and the text on it must be dark.** Ratios computed with the
  WCAG relative-luminance formula on 2026-07-20:

  | Pairing | Ratio | AA normal (4.5) | AA large (3.0) |
  |---|---|---|---|
  | `#ed6d1f` on white | 3.08:1 | FAIL | PASS |
  | **white text on `#ed6d1f` fill** | **3.08:1** | **FAIL** | PASS |
  | `#231815` text on `#ed6d1f` fill | 5.61:1 | PASS | PASS |
  | `#000000` text on `#ed6d1f` fill | 6.81:1 | PASS | PASS |
  | `#ed6d1f` on navy `#1e3a5f` | 3.73:1 | FAIL | PASS |

  **The trap: white-on-orange is the instinctive CTA button and it fails.** An orange
  button MUST carry near-black or black label text, not white. Orange as *text* on white
  is limited to large/bold (≥24px, or ≥18.66px bold); never for body copy, and never as a
  thin meaning-bearing icon on its own.
- **Red is quarantined from UI semantics.** `#b92d26` against the established error colour
  `#dc2626` measures **1.25:1** — they are effectively indistinguishable. Letting brand red
  into buttons or borders would make "brand" and "destructive" the same signal, which an
  enterprise UI cannot afford. Red stays in the logo and in marketing surfaces where no
  error semantics exist.

Scope note: this decision governs *new* work and the design system. It does not retro-fit
the existing site — that is a separate, tracked change, not a silent sweep.

## Known brand inconsistencies (flagged, not resolved here)

- `container-wide` diverges at ≥1920px: www 1600px vs portal 1800px.
- `primary-light #2d5a8a` is defined but unused.
- ~~Footer uses `brightness-0 invert` on the logo instead of a real light variant.~~
  **A real white variant now exists** (`brand/logo/skyphoenix-logo-white.svg`). The filter
  technique is now a defect wherever it still appears (`www/partials/footer.php:14`), not a
  workaround — it flattens all three brand colours to white.
- **No stacked lockup and no wordmark-only asset** exist; narrow contexts use the mark
  alone. Composing one would mean inventing artwork — brand owner must supply it.

## Voice and content rules (German-language B2B surfaces)

These are design-system concerns, not just marketing copy concerns — they apply to product
UI strings, error messages, emails and app-store listings, which is exactly where an
inconsistent register shows up first. Sourced in
`../reports/brand-positioning-research-2026-07-20.md`.

**Scope:** this section governs **German-language B2B** surfaces. SKYPhoenix is B2B-first
but also ships consumer products, whose language and register defaults differ — see
`consumer-products.md`. Do not apply the DACH-B2B rules below to an English-language
consumer tool by reflex.

- **Always "Sie", never "Du"** in German B2B copy. Convergent evidence across DACH sources:
  informal address at first contact in IT consulting reads as a credibility mistake. This
  binds product UI, not only the marketing site. A German-language *consumer* product may
  revisit the register — but only as a deliberate, recorded brand decision, never as a
  default drift.
- **German-primary, English mirror** for B2B. Consumer products are usually the reverse:
  English-primary, because that market is global rather than DACH. Human-reviewed either
  way, not machine-translated.
- **Factual over aspirational.** DACH enterprise buyers signal trust through completeness
  and precision — named entities, real numbers, verifiable references — rather than the
  emotive brand storytelling common in US B2B SaaS.
- **Every product that has a public surface needs a reachable Impressum** (legally required
  in DE and AT regardless of a B2B audience) and, if it sets any non-essential cookie, a
  consent layer whose reject option is as prominent as accept.

## Semantic color roles

See `tokens/light.json` for the extracted mapping (text, backgrounds, surfaces, borders, brand-surface, focus, danger, and the four alert sets success/warning/info/error). Status badges follow the extracted convention in `portal/includes/functions.php:227-236`.

## Typography, spacing, radii, borders, shadows, motion, breakpoints

All in `tokens/base.json` with sources. Key scale anchors: container `max-w-7xl` + `px-4/6/8`; sections `py-16 lg:py-24`; cards `p-6/p-8` (portal stat cards 1.5rem); buttons `0.5rem 1rem` (44px min touch target on mobile); breakpoints 640/768/1024 + wide-screen tiers 1920/2560 and compact 375.

## Theming

- **Light:** the extracted, shipping theme (`tokens/light.json`).
- **Dark:** `tokens/dark.json` is a *proposal* derived only from extracted hues — the site has no dark theme. Requires brand-owner approval before use.
- **System/default:** products should follow `prefers-color-scheme` once dark is approved; until then, light is the only certified theme.
- **High contrast:** `tokens/high-contrast.json` (proposal) fixes documented AA failures; respect `forced-colors` and never override system high-contrast palettes.

## Accessibility requirements (binding for new products)

Extracted failures that MUST NOT be replicated:

| Extracted usage | Problem | Binding rule |
|---|---|---|
| `#3b82f6` links on white (`www/index.php:57`) | ~3.7:1, fails AA normal text | Links in text ≥4.5:1 (use `#1e40af`/`#2563eb` family) or large/bold only |
| `#9ca3af` secondary text (83× www) | ~2.5:1, fails AA | Only for disabled/decorative; never for information |
| Portal viewport `user-scalable=no` (`portal/includes/header.php:93`) | Blocks zoom | Never disable user zoom |
| Portal: no skip link, no reduced-motion rule | Gaps | Both required in every new product |

Positive extracted patterns to keep: visible 2px focus outline with offset (`custom.css:40-47`, `portal.css:4-7`); 44px touch targets; `lang` attribute; alt text on logos; keyboard-reachable mobile nav with `aria-expanded`.

### Quiet borders vs WCAG 1.4.11 (internal tension, documented)

The extracted "quiet" borders — `border` `#e5e7eb` and `border-strong` `#d1d5db` (`tokens/light.json`) — measure (WCAG relative-luminance formula, recomputed 2026-07-18) **~1.24:1** and **~1.47:1** on white respectively, well below the WCAG 2.2 §1.4.11 (Non-text Contrast) 3:1 target for UI-component boundaries. Whether §1.4.11 applies to a default, non-interactive-state input border is a genuinely debated interpretation in the accessibility community (some read it as applying only to the boundary that conveys the "this is a control" affordance in an active/focus state; others read it as applying to any border needed to perceive a control's extent at rest). This design system does not resolve that debate; it states a project position:

- **Default (resting) input borders follow the extracted values as-is** (`#e5e7eb` / `#d1d5db`) — they are not "fixed" unilaterally, per the "never invent colors" rule and the extracted-value provenance discipline.
- **Focus and error states MUST meet 3:1** against their surrounding surface — the extracted focus pattern already exceeds this (secondary-brand focus ring, `custom.css:40-47`) and the error pattern uses `#dc2626`/`#991b1b` text plus icon/label, not border color alone.
- A ui-ux-review finding against a *resting* extracted-token input border alone (no focus/error state involved) is **not** a token defect under this position; a finding against a missing or sub-3:1 focus/error indicator **is**.

## Charts / data visualization

No charting exists on either site (nothing to extract). Principles for new products: build on semantic tokens (brand primary/secondary + alert hues) with AA-compliant text/label pairings; never encode meaning by color alone (pair with labels/shape); empty/loading/error states per `component-principles.md`. Concrete chart palettes require a brand-owner-approved extension to `base.json`.
