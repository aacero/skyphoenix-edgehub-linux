# Widget legibility remediation ledger

This ledger records the strict rendered-type and clipping findings discovered
while preparing the 1.0 candidate. It is a development backlog, not release
evidence. Formal results must be repeated from a clean committed SHA and stored
under its commit-keyed artifact directory.

## Diagnostic baseline

- Source state: dirty development tree after `64d4ca89fb9afa84ce623bc3f4a60a808d9998bf`
- Matrix: 30 first-party widgets, every declared size in portrait and landscape
- Bounded variants: text scales 1.0, 1.15, 1.30, 1.45; System,
  Atkinson Hyperlegible, and Lexend fonts; nominal, maximum, long, and error
  content; native and modeled 125 percent output scaling
- Rendered rows: 1,152
- Result after correcting the proven scrolling-boundary instrumentation error:
  834 passed, 318 failed
- Failure classes: 122 rows below the numeric type floor, 240 rows with visible
  clipping or truncation, 44 rows with both
- QML warnings: 0
- Runtime: 42.207 seconds

The matrix is deliberately pairwise rather than the 110,592-row Cartesian
product. The 125 percent case models reduced logical geometry offscreen and is
not a compositor DPR measurement. It checks visible editor viewport and type
size but does not replace editor selection, scrolling, or input-gesture tests.

The original diagnostic reported 343 failed rows. Twenty-five of those were
false positives caused by continuing the mapped-bounds scan above an intentional
ListView or Flickable boundary. The corrected scanner stops at that boundary.
It did not remove or relax the minimum-type, explicit `truncated`,
`contentWidth`, or `contentHeight` checks. The 318 remaining rows are treated as
real supported-size defects until fixed or the size contract is explicitly
changed.

## Per-widget backlog

| Widget | Failed rows | Status | Required remediation |
|---|---:|---|---|
| CPU | 0 | Complete | Reflowed the critical-temperature and source detail in half-height and tall projections. Focused suite: 57 passed; matrix: 40/40 rows passed; QML warnings: 0. |
| GPU | 0 | Complete | Reflowed narrow thermal, load, unsupported, and disconnected status while retaining complete accessible wording. Focused suite: 76 passed; matrix: 40/40 rows passed; QML warnings: 0. |
| Memory | 0 | Complete | Added concise narrow status and history copy, responsive detail rows and columns, and non-duplicative roomy-ring context. Focused suite: 56 passed; matrix: 40/40 rows passed; QML warnings: 0. |
| Network | 0 | Complete | Raised rate typography to the active floor and added arrow-led half-size rate labels plus concise compact history and direction copy. Focused suite: 45 passed; matrix: 40/40 rows passed; QML warnings: 0. |
| Disk | 0 | Complete | Added geometry-aware compact capacity, threshold, activity, and composition tiers while retaining every supported size. Focused suite: 43 passed; visible GUI suite: 33 passed; matrix: 40/40 rows passed; QML warnings: 0. |
| Sensors | 0 | Complete | Added concise narrow status, body-width-aware rows, bounded two-line sources, and tighter wide-row spacing. Focused suite: 38 passed; matrix: 32/32 rows passed; QML warnings: 0. |
| Packages | 0 | Matrix clear | No minimum-type or clipping failure in this matrix. Other functional and visual gates still apply. |
| System Age | 0 | Matrix clear | No minimum-type or clipping failure in this matrix. Other functional and visual gates still apply. |
| Clock | 0 | Complete | Stacked narrow calendar cards, corrected fitted-time layout height, and bounded short-wide time sizing so every painted line stays inside the body. Focused suite: 58 passed; matrix: 40/40 rows passed; QML warnings: 0. |
| Analog Clock | 0 | Matrix clear | No minimum-type or clipping failure in this matrix. Other functional and visual gates still apply. |
| Moon Phase | 0 | Complete | Added a compact detail tier, token-sized phase text, constrained disc sizing, responsive date and event wording, wrapped locality copy, and a large-layout-only cycle gauge. Focused suite: 75 passed; matrix: 40/40 rows passed; QML warnings: 0. |
| Focus Timer | 0 | Complete | Added a width-budgeted three-column runway whose maximum-duration and rhythm labels wrap at constrained high-scale projections while retaining touch-safe controls. Focused suites: 62, 18, and 6 passed; matrix: 16/16 rows passed; QML warnings: 0. |
| Tasks | 0 | Complete | Raised checkmarks to the active floor, added two-line responsive rows, and compacted constrained footer, Clear, and Add controls. Focused suite: 59 passed; matrix: 48/48 rows passed; QML warnings: 0. |
| Right Now | 0 | Complete | Added a size-aware micro excerpt with an explicit “Tap to read all” continuation while retaining the full text for accessibility and editing. Focused suite: 36 passed; matrix: 40/40 rows passed; QML warnings: 0. |
| Quick Note | 0 | Complete | Replaced silent preview elision with a complete-text vertical viewport, persistent overflow disclosure, vertical-only gestures, and a named editor viewport. Focused suite: 64 passed; GUI suite: 18 passed; matrix: 56/56 rows passed; QML warnings: 0. |
| Habit Streak | 0 | Complete | Raised heatmap state marks to the active floor, added accessible compact streak notation, moved constrained custom names into a wrapping body heading, and derived the complete 28-day heatmap from available geometry. Focused suite: 76 passed; matrix: 40/40 rows passed; QML warnings: 0. |
| Hydration | 0 | Complete | Bounded external goal, count, and serving values, derived grid columns from real body width and spacing, and responsively reflowed tile actions. Focused suite: 57 passed; matrix: 32/32 rows passed; QML warnings: 0. |
| Break Reminder | 0 | Complete | Raised state copy to the active type floor, let duplicate narrow-header status and icon yield to the full title, and reflowed short-wide due actions without shrinking their touch targets. Focused suites: 72 and 8 passed; visible GUI suites: 16 and 30 passed; matrix: 32/32 rows passed; QML warnings: 0. |
| Meds | 0 | Complete | Raised status, summary, names, times, and icons to active tokens; reflowed rows into responsive time/state and wrapped-name tiers; added touch-safe dynamic rows, scrolling disclosure, and safe partially clipped-row behavior. Focused suite: 58 passed; Meds GUI rows: 39 passed; matrix: 40/40 rows passed; QML warnings: 0. |
| Braindump | 0 | Complete | Made timestamp and capture typography token-sized, sized time columns from content, wrapped saved thoughts in per-row scrollers, and made long drafts scrollable. Focused suite: 55 passed; matrix: 40/40 rows passed; QML warnings: 0. |
| Routine | 0 | Complete | Raised summaries and completion marks to the active floor, added responsive one-to-three-line rows, and grew row height with typography while preserving touch targets and overflow disclosure. Focused suite: 39 passed; matrix: 40/40 rows passed; QML warnings: 0. |
| Now Playing | 0 | Complete | Reflowed artwork and complete metadata across narrow and landscape micro layouts, raised time and disconnected states to active type tokens, removed duplicate constrained-header status, and retained the full player/track/artist/album/state summary in accessibility. Focused suite: 55 passed; responsive combinations: 120 passed; visual size suite: 12 passed; matrix: 40/40 rows passed; QML warnings: 0. |
| HTTP / JSON | 0 | Complete | Gave wide readings and trends explicit space, stacked long units, wrapped complete errors and recovery context, and moved the full path and unit into a wrapping chart legend with numeric axes and statistics. The constrained header uses a complete short visual label while accessibility retains the full identity. Focused suite: 51 passed; GUI size, config, and state suite: 54 passed; network suites: 37 and 4 passed; matrix: 48/48 rows passed; QML warnings: 0. |
| KPI | 0 | Complete | Wrapped full labels and recovery guidance, kept the normal wide composition stable as chart history arrives, made error states reclaim the unused chart column, sized headlines from the real content box, kept the touch-sized refresh action with local footprint reservation, and retained detailed axes or compact statistics only where they fit. Full reading, error, recovery, and chart statistics remain accessible. Focused suite: 41 passed; Sparkline suite: 33 passed; matrix: 56/56 rows passed; QML warnings: 0. |
| Calendar | 0 | Complete | Narrow titles now wrap without losing their full accessible event summary, row capacity is derived from the real agenda viewport and font metrics, and empty or error content uses one bounded state. Focused suites: 78 and 24 passed; Calendar logic: 6 passed; visible GUI suite: 35 passed; matrix: 40/40 rows passed; QML runtime warnings: 0. |
| Now / Next | 0 | Matrix clear | No minimum-type or clipping failure in this matrix. Injected live-event coverage remains separate. |
| Weather | 0 | Complete | Wrapped configured locations and provider states with geometry-backed height, replaced squeezed wide-column ranges with floor-sized high/low stacks, and retained complete location and recovery context in accessibility. Focused suite: 60 passed; matrix: 40/40 rows passed; QML warnings: 0. |
| Countdown | 0 | Complete | Reflowed event names, removed duplicate unbounded copy outside micro tiles, added concise local target context, and retained the full label, timezone, and occurrence in the accessible summary. Focused suite: 56 passed; matrix: 32/32 rows passed; QML warnings: 0. |
| End of Day | 0 | Complete | Added a constrained-header state tier and a complete accessible state/progress summary so the full title remains visible at maximum type and modeled 125 percent geometry. Focused suite: 87 passed; matrix: 40/40 rows passed; QML warnings: 0. |
| Daily Quote | 0 | Matrix clear | No minimum-type or clipping failure in this matrix. Other functional and visual gates still apply. |

## Per-widget completion rule

A widget is complete only when:

1. its implementation uses the active type and density tokens rather than a
   smaller hard-coded fallback;
2. every catalog-declared size provides a useful hierarchy in both
   orientations;
3. system labels, state, errors, values, and controls neither truncate nor
   escape their visible container in the matrix;
4. unbounded user content has a clear wrapping, scrolling, excerpt, or
   continuation behavior;
5. touch targets and editor viewports remain usable;
6. the focused widget behavior suite passes with zero unexpected QML warnings;
7. every previously failing matrix row for that widget passes; and
8. no supported size is removed merely to hide a regression without a reviewed
   product and migration decision.

The combined widget gate is complete only when all 1,152 rows pass, editor
coverage accounting passes, the enumerated-requirements matrix is complete, the
compiled-resource QML suites emit no unexpected warnings, and the clean-SHA
visual baseline comparison passes.
