# Typography & Legibility (binding rules)

Status: binding rules with evidence, written 2026-08-01. Every rule below exists because a
SKYPhoenix product hit it in production CI, and each cites the measurement that produced
it. No value here is invented: this document adds **rules**, not tokens. Where a number is
needed it must be *measured* by the product, not copied from here — that is the whole
point of §2.

Companion documents: `brand-guidelines.md` (never invent values), `component-principles.md`
(extracted component patterns, including the recorded secondary-button contrast failure),
`cross-platform-standard.md` (WCAG math and per-platform contract), `tokens/`.

---

## 0. The rule that produced this document

**A font family you declare but do not ship is not a specification.**

`tokens/base.json` already records the failure mode in its own note on `font.family.sans`
(`"Inter, system-ui, -apple-system, sans-serif"`):

> "Declared in Tailwind config but Inter is never loaded (no @font-face/CDN link found);
> effective font is the system stack."

So the declared family is aspirational and the *rendered* family is whatever the machine
happens to have. Everything downstream — line boxes, wrapping, truncation, tile heights —
is computed from the rendered font's metrics, not the declared one's.

**Measured consequence.** `skyphoenix-edgehub-linux` declares
`"Inter, Segoe UI, Roboto, sans-serif"` and ships none of the three. Its CI runner had only
`fonts-dejavu-core`, so every string fell back to DejaVu Sans, whose line height is taller.
Its legibility matrix reported **370 failures**, all of the shape
`contentHeight N > height M` and overwhelmingly 2–4 px: 208 × `30 > 28`, 164 × `24 > 21`,
146 × `28 > 24`. Installing the declared families removed **46** of them (370 → 324) and
nothing else changed. The same commit passed on a workstation where the stack resolves
(1155 passed, 0 failed).

**Rule.** For any product surface, one of these must be true and recorded:

1. the family is **shipped with the product** (self-hosted `@font-face`, bundled font file,
   or platform-guaranteed family), or
2. the design explicitly targets the **generic stack** (`system-ui`/`sans-serif`) and its
   layouts are built for metric variability per §2.

Declaring a specific family and shipping nothing is neither, and is a finding.

---

## 1. Verify the font that RENDERED, not the one you asked for

Font fallback is silent. A layout or legibility check that does not confirm the resolved
family is measuring an unknown substitute, and its pass is worth nothing.

**Measured consequence.** In the run above, the test matrix asked for three faces —
`system`, `hyperlegible`, `lexend` — and its failures were spread almost evenly across all
three (115 / 123 / 130). That distribution is only explicable if the requested face was not
what rendered; a defect in one bundled face could not produce it.

**Rule.** Any automated typography, layout or screenshot check must assert the resolved
family (or log it as evidence). CI must record its font environment — e.g. `fc-match` for
each family in the stack — so a substitution is visible in the log rather than inferred
weeks later.

---

## 2. Never size a text box from `fontSize + constant`

A line box is `ascent + descent + leading` for the **rendered** face at the **rendered**
size. It is not the font size plus padding, and the difference is font-specific.

**Measured consequence.** `skyphoenix-edgehub-linux` reserved a caption line as
`historyCaptionPixelSize + 8` → 28 px, for text whose measured `contentHeight` was 30 px.
The section was therefore judged to fit when it could not, and the label clipped.

**Rule.** Derive reserved height from measured metrics — `FontMetrics`/`TextMetrics` in Qt,
`getComputedStyle().lineHeight` or a measured element on the web, `TextPaint.getFontMetrics`
on Android, `UIFont.lineHeight` on iOS. If a constant is unavoidable, it must be derived
from the metric at build time and re-derived when the family or scale changes, never
hand-tuned against one machine's rendering.

**Corollary.** Layout containers must not compress text below its implicit/content height.
A container that can shrink its children must set a minimum equal to the measured line box,
or reflow (drop optional content, wrap, or scroll) — silently clipping is not a layout.

---

## 3. User text scaling is a separate axis from zoom

`ui-ux-review` already requires that browser/OS **zoom** is never disabled. Zoom scales
everything uniformly and rarely clips. **Text scaling** — the OS or in-app "larger text"
setting — grows type while the container keeps its size, and is what actually breaks
layouts.

**Measured consequence.** In the run above, failures persisted across every text-scale step
including **1.0** (37 at ×1.0, 92 at ×1.15, 90 at ×1.3, 102 at ×1.45), so scaling amplifies
the defect rather than causing it — but the small-tile cases only fail at raised scale.

**Rule.** Every product states the text-scale range it supports and verifies its densest
surfaces at the top of that range. "Supported" means no clipping and no truncation of
meaning — not merely "does not crash". Where content genuinely cannot fit, the surface must
reflow deliberately (hide optional captions, wrap, or scroll) and that reflow is a designed
state, not an accident of the layout engine.

---

## 4. Contrast: record failures, do not retune them

Contrast rules themselves live in `cross-platform-standard.md` (WCAG 2.2 AA: 4.5:1 normal
text, 3:1 large text and non-text) and are not restated here. What belongs here is the
**house rule for what to do when a measurement fails**, which this repository already
follows twice:

- `component-principles.md` records the extracted secondary button at **3.68:1** and says
  plainly: "Extracted as-is (do not silently 'fix' the token value); this ratio MUST NOT be
  replicated for new text at this size/weight."
- `cross-platform-standard.md` records white-on-orange at **3.08:1** and forbids the
  pairing rather than nudging the hex until it passes.

**Measured third instance.** `skyphoenix-edgehub-linux` reports
`dark/amber/orbs secondary pixel minimum=3.76:1, needs 4.5:1`.

**Rule.** A failing ratio is recorded with its computed value and the pairing forbidden or
fixed by an approved token change. Lowering a threshold, blacklisting the assertion, or
adjusting a hex until the test passes are all findings, not fixes — a contrast gate is only
worth having while it is allowed to fail.

---

## 5. Accessibility faces are a feature, and must be shipped like one

Products offering an accessibility font choice (e.g. Atkinson Hyperlegible, Lexend) MUST
bundle those faces rather than name them and hope. A user who selects "hyperlegible" and
receives a fallback has been given a setting that does nothing, and the layout is then
measured against metrics nobody designed for.

**Rule.** Bundled faces load from product resources, the loader's success is checked, and a
failed load is surfaced (log, telemetry-free warning, or test failure) rather than silently
falling through to a literal family name that may not exist on the machine.

---

## Review hook

`ui-ux-review` carries these as checklist items. A change that adds or restyles text-bearing
UI is expected to answer §0 (is the family shipped?), §2 (is the box measured?) and §3
(what text-scale range, verified where?) with evidence, in the same way it already answers
contrast and focus.
