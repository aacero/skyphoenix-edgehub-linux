---
name: ui-ux-review
description: Review user interfaces for accessibility (keyboard, contrast, focus), responsive behavior, error/loading/empty states, first-time-user clarity, expert efficiency, and design-token conformance, with visual regression evidence. Use when a change adds or modifies any user-facing UI, screen, component, or flow, or before shipping UI to users.
---


<!-- GENERATED from agent-framework/canonical/skills/ui-ux-review/SKILL.md — edit the canonical source, then run: python3 scripts/agent-framework/render.py -->
# UI/UX Review

## Purpose

Verify that a UI change is usable, accessible, consistent with the design system, and evidenced by screenshots — not just "looks fine on my machine". Findings are reported as Blocking / Important / Optional. This skill is the review *procedure*; it does not by itself satisfy the independent-gate requirement — the accessibility-reviewer role is the independent check that runs or verifies this procedure per the autonomy-policy continuation ladder (step 4), and a builder self-running this checklist on its own change does not substitute for that independent review.

## When to use

- A diff adds or modifies screens, components, styles, or user-facing copy.
- Before a release gate that includes user-facing UI.
- When a UI is reported as confusing, inaccessible, or visually broken.

## When not to use

- Pure backend/API changes with no rendered surface.
- Deep visual design exploration or rebranding — that is design work, not review.

## Design tokens — hard rule

All colors, spacing, typography, radii, and elevation values MUST come from the extracted design tokens in `agent-framework/design-system/tokens/`. NEVER invent colors, spacing values, font sizes, or one-off hex codes — a value not in the token set is a finding (Blocking if it breaks visual consistency on a shipped surface, Important otherwise). If a needed token does not exist, file a token request as a `Candidate` per the scope-control policy; do not improvise a value.

**Extracted vs proposed-derived governance:** only tokens carrying `$status: extracted` (currently `tokens/light.json`, `tokens/base.json`) are authoritative for shipping product. Tokens carrying `$status: proposed-derived` (currently `tokens/dark.json`, `tokens/high-contrast.json`) are brand-owner proposals, not certified values — they REQUIRE documented brand-owner approval before use in a shipped product. A change that uses `proposed-derived` token values without recorded brand-owner approval attached is a review FAILURE (Blocking), not a pass with a note — the mere existence of the `$status` field on the token file does not itself constitute approval.

## Procedure

1. **Identify the surfaces.** List changed screens/components and the user flows they participate in. Capture BEFORE screenshots of each affected surface at the review breakpoints (or retrieve the prior baseline).
2. **Token conformance.** Diff the styles against `agent-framework/design-system/tokens/`. Flag every literal color/spacing/typography value that bypasses a token.
3. **Keyboard navigation.** Operate every changed flow with keyboard only: Tab/Shift-Tab order is logical, all interactive elements reachable and operable (Enter/Space/arrows as appropriate), no keyboard traps, skip mechanisms where flows are long.
4. **Focus visibility.** Focus indicator is clearly visible on every interactive element in every state and theme; focus is not lost or reset unexpectedly on dialogs, route changes, or list updates; focus returns sensibly when overlays close.
5. **Contrast (WCAG 2.2 AA).** Check text and meaningful non-text contrast against WCAG 2.2 AA (W3C Recommendation, 12 Dec 2024, https://www.w3.org/TR/WCAG22/, accessed 2026-07-18): 4.5:1 normal text, 3:1 large text and UI components/graphical objects. Record the tool used and measured ratios for anything near the limit.
6. **Typography & legibility (binding design-system rules — `agent-framework/design-system/typography-and-legibility.md`).** Confirm the font family the surface actually RENDERS, not the one it declares: fallback is silent, and a layout verified against a substituted face proves nothing. A family the product declares but does not ship is a finding unless the design explicitly targets the generic stack. Text boxes must be sized from measured font metrics, never `fontSize + constant`, and containers must not compress text below its measured line box. Verify the product's stated user-text-scale range on its densest surfaces — text scaling is a separate axis from zoom (step 8) and is what actually clips.
7. **Responsive checks at defined breakpoints.** Verify layout at the project's defined breakpoints from the design-system tokens; if the project defines none, review at minimum 360 px (small phone), 768 px (tablet), 1280 px (laptop), and 1920 px (desktop) widths. No horizontal body scroll, no clipped/overlapping controls, touch targets adequate on small sizes.
8. **Motion, zoom, and forced-colors (binding design-system rules).** `prefers-reduced-motion` is honored everywhere — verify with the OS/browser setting enabled that non-essential animation/transition/autoplay is removed or reduced. User zoom is never disabled — verify no `user-scalable=no` / `maximum-scale=1` in viewport meta and pinch-zoom actually works. `forced-colors` mode is respected — verify the surface remains usable and does not lose meaning under a forced-colors/system high-contrast palette (no `forced-color-adjust: none` without a documented reason). A skip link is present and operable on every page/entry surface (first Tab reaches it, activating it moves focus past repeated navigation).
9. **Error recovery.** Trigger realistic failures (validation errors, network failure, save conflict). Errors are visible, human-readable, non-destructive (user input preserved), and offer a way forward (retry/fix). No dead ends, no silent failures.
10. **Loading states.** Every async operation has a visible loading/progress state; UI prevents duplicate submissions; slow paths do not look frozen; skeletons/spinners appear where waits are perceptible.
11. **Empty states.** First-run and zero-data views explain what the area is for and offer the next action — never a blank panel or a raw "0 results" with no guidance.
12. **First-time-user clarity.** Walk the flow as a novice: is the next step obvious, is jargon avoided or explained, are destructive actions guarded and labeled by consequence?
13. **Expert efficiency.** Frequent tasks have short paths: sensible defaults, keyboard shortcuts where established, bulk operations where lists are large, no forced modal detours for routine actions.
14. **Visual regression evidence.** Capture AFTER screenshots at the same breakpoints/states as the BEFORE set and diff them. Every intentional visual change is listed; every unintentional difference is a finding.

## Verification checklist

- [ ] Keyboard navigation: full flows operable, no traps, logical order
- [ ] Contrast measured against WCAG 2.2 AA, tool + ratios recorded
- [ ] Focus visibility verified on all interactive elements and overlays
- [ ] Rendered font family confirmed (not just declared); shipped or generic stack by design
- [ ] Text boxes sized from measured metrics; no clipping at the stated text-scale range
- [ ] Responsive verified at the defined breakpoints (listed in the report)
- [ ] `prefers-reduced-motion` honored everywhere (verified with the setting enabled)
- [ ] User zoom is never disabled (no `user-scalable=no`/`maximum-scale=1`; pinch-zoom works)
- [ ] `forced-colors` mode respected; surface stays usable under system high-contrast
- [ ] Skip link present and operable on every page/entry surface
- [ ] Error recovery exercised with real failure injection
- [ ] Loading states present for all async operations
- [ ] Empty states informative with a next action
- [ ] First-time-user walkthrough performed
- [ ] Expert-efficiency pass performed
- [ ] Before/after screenshots captured, diffed, and attached
- [ ] All style values traced to `agent-framework/design-system/tokens/`; no invented values

## Evidence requirements

Follow `agent-framework/canonical/policies/evidence-policy.md`. Screenshot pairs (before/after, per breakpoint and state) are mandatory evidence and must be stored at a referenced path. Contrast claims carry measured ratios and the measuring tool. Checks not performed (e.g., no device available) are `NOT RUN` with a reason, never assumed to pass.

## Output format

```
## UI/UX Review: <change>
Surfaces: <screens/components>
Breakpoints used: <list>
Screenshots: <path to before/after sets>

### Blocking   (inaccessible, data-losing, dead-end, or token-breaking on shipped surface)
- <finding> — surface/breakpoint — evidence (screenshot/ratio) — required fix

### Important
- ...

### Optional
- ...

### Verdict
<pass | pass after Blocking fixes | fail>
```
