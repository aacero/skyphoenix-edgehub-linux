# Widget Delivery Specification

Date: 2026-07-23

Scope: all 30 first-party widgets in the Hub, their Manager configuration,
every catalog size, portrait and landscape presentation, accessibility,
lifecycle behavior, persistence, permissions, and Hub to Manager consistency.

This document converts the widget audit into implementation-ready stories and
bugs. Items are completed sequentially. A widget cannot move to Done until its
own focused tests and review pass.

## Severity and priority

- P0: security, privacy, data loss, dangerous activation, or incorrect core result
- P1: serious functional, synchronization, accessibility, layout, or legibility issue
- P2: configuration, resilience, information-design, or usability improvement
- P3: useful expansion or visual polish

## Common Definition of Done for one widget

Every widget-specific Definition of Done below includes all of these conditions:

1. Purpose, user, displayed data, source, refresh behavior, permissions, and
   limitations are documented.
2. Every catalog size has an intentional information hierarchy. Larger sizes
   add useful information rather than only scaling the smallest design.
3. Portrait and landscape layouts contain all visible text and controls without
   overlap, clipping, accidental scrolling, or unexplained dead space.
4. Essential Hub text is readable at arm's length. Supporting text is removed
   before essential text is reduced below the shared legibility floor.
5. Every action has an approximately 48 logical pixel target, an accessible
   name and role, keyboard fallback, visible state, and accidental-activation
   protection proportional to its consequence.
6. Loading, empty, unavailable, stale, disconnected, invalid-configuration,
   success, warning, and error states are distinct wherever applicable. Meaning
   never depends on color alone.
7. Configuration uses the correct control type, validates before persistence,
   explains units and scope, conditionally hides irrelevant fields, and has
   equivalent effects from Hub and Manager.
8. Runtime state is scoped by widget instance and shared correctly between tile,
   expanded view, Manager preview, and Hub. Reopening or resizing does not reset
   or duplicate state.
9. Polling and animation stop or reduce when inactive, respect reduced motion,
   remain bounded, and never block the UI thread.
10. Network, filesystem, process, and secret access use the shared policy layer,
    least privilege, bounded input, redacted diagnostics, and explicit failure.
11. Focused QML tests cover behavior, boundaries, every supported size,
    configuration, accessibility, lifecycle, and relevant failure states.
12. The widget's focused source test and affected compositor test pass with no
    new runtime diagnostics. The final diff is reviewed before the next widget.

## 1. CPU

Status: Done

Verification:

- Focused source suite: 54 passed, 0 failed, 0 skipped
- Real-compositor system suite: 106 passed, 0 failed, 0 skipped
- Portrait and landscape evidence inspected at every declared CPU size
- Final CPU diff and em-dash scan passed

### User story

As a Linux workstation user, I want CPU load, temperature, frequency, and recent
behavior to remain readable at a glance so I can distinguish a short spike from
a sustained problem and understand which sensor produced the reading.

### Bugs and backlog

- CPU-01 P1: Detail labels are too small at normal viewing distance.
- CPU-02 P1: The ring consumes space that larger layouts should use for context.
- CPU-03 P1: Warning meaning is primarily encoded by color.
- CPU-04 P2: History has no displayed time window or summary.
- CPU-05 P3: Frequency, load average, and per-core inspection are missing.

### Widget-specific Definition of Done

- Baseline shows load and sensor identity; wide and tall add temperature,
  frequency, load average, and named history without duplicated values.
- Warning and critical states include text or icons and accessible descriptions.
- Missing frequency, temperature, or core data says unavailable without showing zero.
- History states its duration and provides current, average, and peak where space allows.

## 2. GPU

Status: Done

Verification:

- Focused source suite: 74 passed, 0 failed, 0 skipped, covering discovered-device, disconnect recovery,
  unsupported telemetry, warning semantics, configuration, and size coverage
- Real-compositor system suite passed for GPU and its CPU and Memory siblings
- Portrait and landscape evidence inspected at every declared GPU size
- Final GPU diff and em-dash scan passed

### User story

As a gamer or graphics professional, I want the selected GPU and supported
telemetry to be explicit so multi-GPU systems and disconnected devices never
show misleading data.

### Bugs and backlog

- GPU-01 P1: Configuration presents generic choices instead of discovered identity.
- GPU-02 P1: A disconnected selected GPU lacks a clear recovery workflow.
- GPU-03 P2: Driver, clock, fan, power source, and support details are incomplete.
- GPU-04 P2: Unsupported telemetry can look like ordinary missing data.

### Widget-specific Definition of Done

- GPU selection lists stable discovered identity and retains selection across refresh.
- Disconnect and reconnect preserve intent and present a clear fallback action.
- Each telemetry field reports value, unit, source, and unsupported or unavailable reason.
- Device changes reset or separate all history and never blend devices.

## 3. Memory

Status: Done

Verification:

- Focused source suite: 53 passed, 0 failed, 0 skipped
- Real-compositor system suite: 106 passed, 0 failed, 0 skipped
- Portrait and landscape evidence inspected at every declared Memory size
- Final Memory diff and em-dash scan passed

### User story

As a system user, I want to understand used, available, cached, swap, and
pressure memory so a high utilization percentage is not mistaken for a problem.

### Bugs and backlog

- RAM-01 P1: Larger cards over-emphasize the ring.
- RAM-02 P1: Used, available, cache, swap, and pressure hierarchy is weak.
- RAM-03 P2: History lacks a named time window and summary statistics.
- RAM-04 P2: Binary capacity values are not consistently labeled GiB.

### Widget-specific Definition of Done

- Baseline distinguishes used from available; larger sizes add cache, buffers,
  swap, pressure, and history summaries.
- All binary quantities use GiB and are derived from unrounded source values.
- Pressure is explained in plain language and is not treated as utilization.
- History shows its duration plus minimum, average, and peak.

## 4. Network

Status: Done

Verification:

- Rust metrics suite: 255 passed, 0 failed, 0 skipped
- Focused source suite: 37 passed, 0 failed, 0 skipped
- Real-compositor system suite: 102 passed, 0 failed, 0 skipped
- Portrait and landscape evidence inspected at every declared Network size
- Rust formatting, Clippy, final Network diff, and em-dash scan passed

### User story

As a network user, I want to know which interface is measured, whether it is
connected, and how upload and download compare over time without double counting.

### Bugs and backlog

- NET-01 P0: Aggregate and selected-interface modes can double count traffic.
- NET-02 P1: Interface identity and link state are not prominent.
- NET-03 P1: Graph scale and history duration are not identified.
- NET-04 P1: Direction is too dependent on color.
- NET-05 P2: Interface and virtual-interface configuration relies on free text.

### Widget-specific Definition of Done

- Aggregate and selected modes use mutually exclusive, tested counters.
- Discovered interfaces show stable name, friendly identity, type, and link state.
- Upload and download have non-color labels and accessible descriptions.
- Graph scale, unit basis, and time window are visible in every history layout.

## 5. Disk

Status: Done

Verification:

- Rust metrics suite: 257 passed, 0 failed, 0 skipped
- Focused source suite: 37 passed, 0 failed, 0 skipped
- Focused C++ metrics tests: 2 passed, 0 failed
- Real-compositor system suite: 102 passed, 0 failed, 0 skipped
- Portrait and landscape evidence inspected at every declared Disk size
- Release build, Rust formatting, Clippy, final Disk diff, and em-dash scan passed

### User story

As a Linux user, I want accurate capacity and activity for a chosen mount so I
can act before it fills and understand which filesystem is being measured.

### Bugs and backlog

- DISK-01 P1: Used bytes are reconstructed from rounded percentage data.
- DISK-02 P1: The capacity ring dominates larger layouts.
- DISK-03 P1: Capacity labels remain too small.
- DISK-04 P2: Mount, filesystem, I/O, and threshold preview are missing.
- DISK-05 P2: The tall size is under-filled.

### Widget-specific Definition of Done

- Used, free, and total values come from direct byte counters and reconcile.
- Mount selector uses discovered filesystems and shows mount plus filesystem identity.
- Larger layouts add read/write activity and threshold context.
- Every threshold is reachable, previewed, and represented without color alone.

## 6. Sensors

Status: Done

Verification:

- Rust metrics suite: 257 passed, 0 failed, 0 skipped
- Focused Sensors suite: 36 passed, 0 failed, 0 skipped
- Shared accessible config-control suite: 63 passed, 0 failed, 0 skipped
- Focused C++ metrics tests: 2 passed, 0 failed
- Real-compositor system suite: 99 passed, 0 failed, 0 skipped
- Portrait and landscape evidence inspected at every declared Sensors size
- Release build, Rust formatting, Clippy, final Sensors diff, and em-dash scan passed

### User story

As a hardware enthusiast, I want a readable, configurable sensor board that
shows only supported sources and clearly identifies warning conditions.

### Bugs and backlog

- SENSOR-01 P1: Small layouts attempt to carry too many rows.
- SENSOR-02 P1: Warnings rely on color.
- SENSOR-03 P2: Row order uses CSV rather than direct manipulation.
- SENSOR-04 P2: Fan and power ranges are not source-aware.
- SENSOR-05 P2: Multi-GPU sensor selection is missing.

### Widget-specific Definition of Done

- Small sizes show a prioritized readable subset; hidden-row count is disclosed.
- Every row has value, unit, source, availability, and semantic warning state.
- Row order uses an accessible reorder control with persisted stable row IDs.
- Power, fan, and temperature ranges derive from source capability where available.

## 7. Packages

Status: Done

### User story

As a Linux distribution user, I want an honest package inventory and update
summary that never mutates my system and clearly states what was counted.

### Bugs and backlog

- PKG-01 P1: Count scope is insufficiently explained.
- PKG-02 P2: RPM-family support is absent.
- PKG-03 P2: Manual refresh is missing.
- PKG-04 P2: Large sizes are under-filled.
- PKG-05 P3: Available and security update counts are absent.

### Widget-specific Definition of Done

- The widget states package manager, database source, count scope, and last refresh.
- Arch, Debian, and safely detectable RPM-family systems report explicit support.
- Refresh is read-only, bounded, accessible, and never invokes package mutation.
- Large sizes add update and security context or are removed from the catalog.

### Completion evidence

- Arch and Debian counts come directly from their installed-package databases.
- RPM-family systems are identified explicitly and explain that a safe count is
  unavailable instead of displaying a false zero.
- Update and security state is deliberately shown as `Not checked`, with the
  reason that stale package-manager caches cannot provide a trustworthy result.
- The manual refresh action is read-only, has a 52 px touch target, and records
  its completion time.
- Focused Packages QML suite: 14 passed.
- Distro bridge QtTest suite: 1 passed.
- Full Rust suite: 257 passed; Clippy and formatting checks passed.
- Shared widget configuration suite: 3 passed.
- Compositor-backed System Info suite: 110 passed.
- Release build completed, and all declared landscape and portrait sizes were
  visually reviewed.

## 8. System Age

Status: Done

### User story

As a Linux user, I want to know how system age was inferred and how reliable it
is so an estimate is never presented as an authoritative install date.

### Bugs and backlog

- AGE-01 P1: Date, source, and estimate status are inconsistent across sizes.
- AGE-02 P1: Rotated or incomplete logs can imply false precision.
- AGE-03 P2: Some supported sizes add scale rather than information.
- AGE-04 P3: The concept overlaps a broader System Identity widget.

### Widget-specific Definition of Done

- Every detailed size labels the exact derived date, source, and confidence.
- Incomplete evidence says earliest recorded evidence rather than install date.
- Unit choices remain consistent and calendar-correct.
- Unsupported large sizes are removed unless they add distribution and source context.

### Completion evidence

- Confirmed distribution-installer records and package-history estimates are
  presented as different evidence classes.
- Pacman and dpkg readers select the oldest readable uncompressed rotation,
  name the exact source path, and disclose when compressed or deleted history
  can make an estimate younger than the system.
- Package-count errors no longer leak into the System Age unavailable state.
- Automatic, days, months, and years modes use completed calendar months for
  month and year presentation.
- Rich 1x1 tiles now use their space for distribution, exact date, source,
  confidence, and completeness context. Expanded mode presents the same facts
  without duplicated cards.
- Focused System Age QML suite: 17 passed.
- Focused distro Rust suite: 42 passed; full Rust suite: 258 passed.
- Distro bridge QtTest suite: 1 passed.
- Shared configuration schema suite: 6 passed; all-widget configuration suite:
  3 passed.
- Compositor-backed System Info suite: 110 passed.
- Clippy and formatting checks passed, the Release build completed without Rust
  warnings, and all declared landscape and portrait sizes were visually reviewed.

## 9. Clock

Status: Done

### User story

As an international user, I want a locale-correct clock with trustworthy
timezones and readable secondary zones.

### Bugs and backlog

- CLOCK-01 P1: Short dates use a fixed day and month ordering.
- CLOCK-02 P1: IANA mode leaves irrelevant fixed-offset fields visible.
- CLOCK-03 P1: Custom date patterns have no live preview or validation.
- CLOCK-04 P2: Secondary zones use CSV.
- CLOCK-05 P2: Secondary text is too small at display distance.

### Widget-specific Definition of Done

- Locale, 12/24-hour preference, IANA zone, and fixed offset produce tested output.
- Only fields relevant to the selected timezone mode are visible.
- Custom formats validate and preview before persistence.
- Secondary zones use a searchable structured picker and remain readable.

### Completion evidence

- Short dates now use the selected locale's native order, separators, and year
  convention instead of a fixed day/month format.
- Custom date patterns show a live preview while typing. Empty patterns,
  unmatched quotes, and patterns without date tokens are rejected before
  persistence; old invalid values fall back safely in the widget.
- The schema now provides a structured, searchable editor for up to three
  secondary IANA zones while preserving the existing stored representation.
- Secondary zones are deduplicated, validated through OS timezone data, limited
  to three, and rendered as higher-contrast cards with larger labels and times.
- Multi-rule conditional disclosure was fixed at the shared ConfigField
  boundary, so the fixed UTC offset now hides for local and IANA modes and shows
  only when fixed-offset mode is active.
- Focused Clock QML suite: 15 passed; broad Clock behavior suite: 56 passed.
- Shared ConfigField suite: 68 passed; shared schema suite: 56 passed.
- Schema invariant suite: 6 passed; all-widget configuration suite: 3 passed.
- Timezone bridge QtTest suite: 1 passed; compositor-backed Time suite: 107 passed.
- The Release build completed, and every declared portrait and landscape size,
  plus the three-zone state, was visually reviewed.

## 10. Analog Clock

Status: Done

### User story

As a user who prefers an analog display, I want a legible, accessible clock face
whose timezone and visual choices behave predictably.

### Bugs and backlog

- ANALOG-01 P1: Fixed-offset and DST behavior needs stronger correctness.
- ANALOG-02 P3: Face, numeral, hand, motion, and label choices are missing.

### Widget-specific Definition of Done

- The face and accessible time description agree for local, IANA, and offset modes.
- Invalid timezone configuration remains visible and actionable.
- Hands remain legible at every size, orientation, scale, and theme.
- Motion respects reduced-motion settings and user-selected second-hand behavior.

### Completion evidence

- IANA zones now drive both the Canvas hands and the accessible time description
  from the same timezone bridge result, including daylight-saving transitions.
- Fixed offsets use a two-pass local-offset conversion so host daylight-saving
  boundaries do not shift the displayed wall time.
- Invalid IANA zones remain visible on the face and in detailed layouts. The
  widget names the fixed-offset fallback and explicitly states that it does not
  apply daylight-saving changes.
- Micro world clocks now retain a compact zone badge, including fractional
  offsets such as `UTC+5:30`, instead of looking indistinguishable from local time.
- Classic and minimal faces, numeral visibility, round and slender hands, second
  hand behavior, zone labels, and reduced-motion behavior are all wired to the
  rendered face and tested.
- Focused Analog Clock QML suite: 34 passed.
- Shared ConfigField suite: 68 passed; schema invariant suite: 6 passed;
  all-widget configuration suite: 3 passed.
- Timezone bridge QtTest suite: 1 passed.
- Compositor-backed Time suite: 111 passed, including pixel-difference checks
  for face and hand styles plus visual evidence for invalid and compact zones.
- The Release build completed, and every declared portrait and landscape size
  was visually reviewed.

## 11. Moon Phase

Status: Done

### User story

As a user interested in lunar context, I want a deterministic phase display with
clear accuracy and optional local rise and set context.

### Bugs and backlog

- MOON-01 P1: The primary visual depends on platform emoji.
- MOON-02 P1: Caveat text competes with useful information.
- MOON-03 P2: Location-aware rise and set information is absent.
- MOON-04 P3: Size progression has a large information gap.

### Widget-specific Definition of Done

- A bundled deterministic visual renders all phases consistently.
- Phase name, illumination, direction, and approximation status have clear hierarchy.
- Location permission is optional and rise/set absence has an explicit reason.
- Every supported size has distinct useful content and contained typography.

### Completion evidence

- The platform emoji was replaced by a bundled-code deterministic Canvas disc.
  Its lit geometry, outline, accent, hemisphere mirroring, and accessible
  description render consistently without depending on the system emoji font.
- Phase name and illumination remain primary. Direction and approximation are
  grouped into a quieter, readable disclosure, while next-phase dates and the
  lunar-cycle bar use larger labels in rich layouts.
- Local moonrise and moonset are opt-in. Users can search for a city or enter
  coordinates, and the widget performs an on-device 36-hour crossing estimate.
  It names the selected place, labels times as device-local, and explicitly
  reports when location is missing or no event occurs in the window.
- City search is an explicit action routed through NetHub. Opening the widget,
  Manager preview, or configuration never initiates a remote request.
- The catalog now offers 1x1.5. Both orientations add rich phase context, and
  the wide projection increases the disc size instead of leaving unused space.
- Focused Moon Phase QML suite: 64 passed.
- Dashboard suite: 61 passed; Manager suite: 63 passed; catalog suite: 18 passed.
- Schema invariant suite: 6 passed; all-widget configuration suite: 3 passed.
- Compositor-backed Time suite: 115 passed, including every supported size,
  both hemispheres, new and full phases, and configured and unconfigured local
  event states.
- The Release build completed, and all generated Moon Phase evidence was
  visually reviewed.

## 12. Focus Timer

**Status: Done**

### User story

As a person doing focused work, I want a readable and safe timer that continues
correctly across screens and notifies me when a phase completes.

### Bugs and backlog

- FOCUS-01 P1: Phase and supporting text need better contrast and size.
- FOCUS-02 P1: Custom duration fields remain visible for non-custom presets.
- FOCUS-03 P1: Skip is too easy to activate.
- FOCUS-04 P2: Hidden-page completion notification is absent.

### Widget-specific Definition of Done

- Remaining time and phase remain the strongest elements at every size.
- Preset-specific configuration uses conditional disclosure.
- Skip is separated or confirmed and cannot be triggered by an adjacent tap.
- State survives view changes and completion is optionally announced off-page.

### Completion evidence

- Remaining time remains the dominant element, while phase, session runway,
  daily progress, nudges, and secondary controls use legible display-scale
  typography and contrast.
- Custom duration fields appear only for the Custom preset.
- Skip now requires a second confirming tap within three seconds in both tile
  and expanded views.
- An opt-in desktop notification announces naturally completed focus or break
  phases only while the widget is off the visible Hub page.
- Dashboard foreground lifecycle is explicit: off-page timers keep advancing,
  while only the current tile or expanded view is considered foreground.
- Focused Focus Timer QML suite: 61 passed.
- Dashboard lifecycle suite: 61 passed; WidgetHost suite: 5 passed.
- Notification bridge QtTest suite: 5 passed.
- Compositor-backed Focus suite: 120 passed, including both orientations,
  every supported size, all presets, natural transitions, and the armed Skip
  state.
- The Release build completed, and the compact, tall, expanded, and
  confirmation evidence was visually reviewed.

## 13. Tasks

**Status: Done**

### User story

As a task-list user, I want to read and deliberately complete, edit, remove, and
undo tasks without accidental row activation.

### Bugs and backlog

- TASK-01 P1: Complete, edit, and remove actions need full accessibility.
- TASK-02 P1: Destructive or completion actions lack consistent undo.
- TASK-03 P1: Rows are too dense and text is too small.
- TASK-04 P2: Editing surfaces are duplicated.
- TASK-05 P2: Empty and overflow states are weak.

### Widget-specific Definition of Done

- Each task has distinct accessible complete, edit, and remove controls.
- Completion and removal offer one-shot undo with stable item identity.
- Visible row count follows size while preserving legible text and touch targets.
- Empty, completed, and hidden-overflow states are explicit.

### Completion evidence

- Every row has a dedicated checkbox with accessible checked state. The
  expanded editor gives edit, move, and remove controls task-specific names,
  keyboard activation, and full touch targets.
- Completing, reopening, removing, or bulk-clearing tasks creates a seven-second
  one-shot Undo action. Undo restores the original order and stable task IDs,
  and is invalidated by an intervening edit.
- Row text now uses the readable label floor at every size. Larger sizes earn
  more rows and progress context without shrinking controls.
- Checklist content is edited in the expanded live widget in both Hub and
  Manager. The settings form no longer duplicates a second task editor.
- Truly empty, all-completed-and-hidden, height-clipped, and First 3 overflow
  states are distinct and explicit.
- Focused Tasks QML suite: 51 passed.
- Shared ConfigField suite: 68 passed; Manager suite: 64 passed.
- Shared WidgetChrome suite: 19 passed; schema invariant suite: 6 passed.
- Compositor-backed Focus and Tasks suite: 121 passed, including every Tasks
  size in both orientations, input, completion, removal, Undo, bulk clear,
  hidden-completed, overflow, appearance, and empty states.
- The final compact, wide, expanded Undo, and hidden-completed evidence was
  visually reviewed.

## 14. Right Now

**Status: Done**

### User story

As a user tracking my current activity, I want the activity, context, and elapsed
time to remain readable and synchronized wherever I edit it.

### Bugs and backlog

- NOW-01 P1: Short text can render unnecessarily small.
- NOW-02 P1: Long text elides before using available wrapping.
- NOW-03 P1: Context and elapsed state are too small.
- NOW-04 P2: Hierarchy differs inconsistently by size.

### Widget-specific Definition of Done

- Short activity text uses available size without excessive shrinking.
- Long text wraps to a bounded line count before eliding.
- Context and elapsed time remain legible and visually subordinate.
- Hub and Manager edits use one lifecycle and produce identical state.

### Completion evidence

- Hero typography now adapts to content length and physical room. Short micro
  cues use a 36px-or-larger display treatment, while longer goals wrap across
  available lines and never shrink below the title-size legibility floor.
- Every non-micro tile reports elapsed focus time. Rich 1x1.5 layouts consolidate
  start time, elapsed flow, and finished-today context into one panel without
  duplicating those values below it.
- Eyebrow, placeholder, daily count, elapsed state, rich context headings, and
  expanded-editor guidance now use readable label or title typography with
  stronger contrast.
- Clear requires a second confirming tap. Done remains the primary completion
  action and the calm or celebration behavior remains configurable.
- Focused Right Now QML suite: 35 passed.
- Compositor-backed Focus, Right Now, and Tasks suite: 123 passed, including
  every supported Right Now size in both orientations, short and wrapped-long
  focus text, elapsed context, completion, protected Clear, configuration,
  empty states, appearance, and expanded editing.
- The micro, baseline, wrapped-long, rich 1x1.5, and armed-Clear evidence was
  visually reviewed.

## 15. Notes

**Status: Done**

### User story

As a note-taking user, I want comfortable reading and one understandable editing
workflow with reliable saving and undo.

### Bugs and backlog

- NOTES-01 P1: Reading text is too small.
- NOTES-02 P1: Footer information competes with content.
- NOTES-03 P2: Editing is duplicated across surfaces.
- NOTES-04 P2: Edit mode is not discoverable.

### Widget-specific Definition of Done

- Reading typography meets the legibility floor before secondary UI is shown.
- Footer status never displaces note content and appears only when useful.
- Tile, expanded view, and Manager use one documented edit and history model.
- Save, external edit, truncation, clear, and undo states remain explicit.

### Completion evidence

- Tile previews now use a title-size reading floor and scale gently up to 24px.
  The expanded editor uses the same floor and scales to 26px where room permits.
- Short roomy notes show a restrained word-count footer and a clear “Tap
  anywhere to edit” hint. Long notes hide that footer and reclaim the entire
  line for reading content.
- Hub and Manager now use the expanded live widget as the single note editor.
  The settings form no longer duplicates a second textarea.
- Expanded editing reserves its viewport above one consolidated footer
  containing Undo, protected Clear, count, and save state. The footer cannot
  cover note content or the caret.
- Existing debounced autosave, destruction flush, external-update
  reconciliation, ten-step history, length bound and disclosure, cursor follow,
  no-op write suppression, and confirmed clear behavior remain intact.
- Focused Quick Note QML suite: 61 passed.
- Manager suite: 65 passed; all-widget configuration suite: 3 passed.
- Compositor-backed Quick Note suite: 18 passed, covering all 14 supported
  size and orientation combinations plus the short-note edit hint and expanded
  editor footer.
- Micro, baseline, wide, short-note, and expanded-editor evidence was visually
  reviewed.

## 16. Habit

**Status: Done**

### User story

As a habit-building user, I want deliberate check-ins and a heatmap that is
understandable without color, plus useful progress at larger sizes.

### Bugs and backlog

- HABIT-01 P1: Heatmap meaning depends on color.
- HABIT-02 P1: Date and weekday context is insufficient.
- HABIT-03 P1: Weekday configuration uses free text.
- HABIT-04 P2: Feedback and large-size statistics can be richer.

### Widget-specific Definition of Done

- Check-in state has text or icon semantics and accessible announcement.
- Heatmap includes weekday/date context and an accessible summary.
- Schedule uses structured weekday controls and calendar-safe streak logic.
- Larger sizes add consistency, record, and next-goal information without overflow.

### Completion evidence

- Every heatmap day now has a visible check, open ring, or rest mark in addition
  to its color. Each cell exposes its full date and state, while the heatmap
  exposes an assistive 28-day completion summary.
- Every non-micro map shows a readable date range and a text legend. Today's
  full date and checked-in, ready, rest-day, or paused state remain visible near
  the primary action.
- Custom schedules now use seven explicit, touch-sized weekday controls in both
  Hub and Manager. The persisted CSV representation remains backward compatible,
  canonical, and hidden unless Custom is selected.
- Functional emoji were removed from status, check-in, milestone, and record
  feedback. Singular and plural language is deterministic, and re-checking a
  previously reached milestone does not falsely re-announce it.
- Roomy cards retain current streak, personal best, 28-day completion,
  consistency percentage, and distance to the next goal without overflow.
- Focused Habit QML suite: 70 passed. Shared schema and structured-control suite:
  57 passed. Manager suite: 65 passed; all-widget configuration suite: 3 passed.
- Compositor-backed Habit size suite: 12 passed across ten tile projections and
  state checks. The broader Focus and Habits compositor suite: 71 passed.
- Micro, baseline, tall half-screen, and wide half-screen evidence was visually
  reviewed after the contrast refinement.

## 17. Hydration

**Status: Done**

### User story

As a hydration user, I want quick, reversible logging with visible serving size
and consistent goal credit.

### Bugs and backlog

- WATER-01 P2: Serving volume lacks prominence.
- WATER-02 P2: Action emoji depend on platform rendering.

### Widget-specific Definition of Done

- Current amount, goal, serving volume, and progress remain readable.
- Add, remove, and one-step undo are deterministic across all hosts.
- Bundled icons replace functional emoji and carry accessible labels.
- Goal completion and streak credit occur exactly once per qualifying day.

### Completion evidence

- Every card now states the configured serving volume, including micro cards,
  and the primary action names the exact amount it will add. Baseline detail
  cards show today, serving, and remaining values with strengthened typography.
- Logged servings and add actions use the bundled hydration SVG. Empty servings
  retain a high-contrast open-circle state, and functional water, celebration,
  overfill, and streak emoji have been removed from the rendered widget.
- Tile glasses and overlay targets expose deterministic accessible descriptions.
  Add and remove actions name their volume, while Undo remains a true one-step
  restore and becomes unavailable after use.
- Goal animations are dismissed as soon as the count falls below the target, so
  stale completion feedback cannot survive a reset or state replacement.
- Existing daily reset, count and goal bounds, first-crossing celebration,
  Manager goal reconciliation, overfill, streak, unit conversion, and single
  daily goal-credit behavior remain intact.
- Focused Hydration QML suite: 56 passed. Shared control suite: 27 passed; shared
  touch-target suite: 5 passed.
- Compositor-backed Hydration suite: 35 passed across every supported tile
  projection, volume and unit configuration, add/undo/overlay actions, goal
  transitions, overfill, appearance, and micro celebration placement.
- Micro, narrow portrait, wide, baseline, goal detail, and overlay evidence was
  visually reviewed after the stale-feedback and contrast refinements.

## 18. Break Reminder

**Status: Done**

### User story

As a desk worker, I want break reminders only during my work schedule, with safe
controls and optional notifications when the widget is not visible.

### Bugs and backlog

- BREAK-01 P1: Weekday configuration uses CSV.
- BREAK-02 P1: Paused-state contrast is weak.
- BREAK-03 P2: Hidden-page due notifications are absent.

### Widget-specific Definition of Done

- Weekdays and work range use structured validated controls, including overnight ranges.
- Running, due, paused, snoozed, outside-hours, and disabled states are distinct.
- Every action remains contained and touch-sized in both orientations.
- Optional due notifications fire once and respect schedule and snooze state.

### Completion evidence

- Weekdays use a seven-chip structured control, work hours use bounded controls,
  and empty or malformed schedules cannot silently enable Sunday.
- Running, paused, snoozed, due, outside-hours, and schedule-disabled states use
  explicit text and non-color ring semantics. The detailed layout also exposes
  the active hour range and selected weekday group.
- Hidden-page notifications are opt-in, use the shared notification bridge, fire
  once per due transition, and remain suppressed while visible, snoozed, or
  outside the active schedule.
- Focused Break Reminder suite: 68 passed. Shared schema and catalog suites:
  57 and 18 passed. Manager suite: 65 passed. All-widget config suite: 3 passed.
- Compositor-backed Break Reminder suite: 16 passed across every supported size
  plus running, paused, snoozed, outside-hours, disabled, and due visual states.
- The size matrix and state montage were visually reviewed for legibility,
  contained actions, state distinction, and schedule context.

## 19. Medications

**Status: Done**

### User story

As a medication user, I want private, deliberate dose tracking with clear due,
taken, missed, and reminder behavior.

### Bugs and backlog

- MEDS-01 P1: State relies too much on color and small labels.
- MEDS-02 P1: Action naming needs stronger accessibility.
- MEDS-03 P1: Schedule configuration is free text.
- MEDS-04 P1: Privacy and diagnostic behavior are insufficiently documented.
- MEDS-05 P2: Reminders and safe post-window state rules are absent.

### Widget-specific Definition of Done

- Due, taken, later, and not-marked states have non-color semantics.
- Dose actions are explicit, guarded, accessible, and reversible where safe.
- Schedule uses structured time and recurrence controls.
- Medication content is redacted from diagnostics and local-storage sensitivity is disclosed.

### Completion evidence

- The Manager and Hub configuration surfaces now share a structured medication
  editor with validated 24-hour times, per-dose weekday recurrence, explicit add
  and remove controls, and touch-sized day selectors.
- Existing line-based schedules remain visible and migrate on the first
  structured edit. Taken identifiers survive migration, and clearing the new
  editor cannot resurrect the legacy schedule.
- Rows use a minimum 72 px touch height, 17 to 22 px primary typography, and
  explicit `!`, `✓`, `○`, and `-` state marks in addition to color and text.
- The post-window state remains the clinically honest and neutral "Not marked".
  The software does not claim a dose was missed because it cannot observe that.
- Hidden-screen reminders are optional, fire once per scheduled due dose, ignore
  inactive weekdays and already marked doses, and omit the medication name by
  default. Users must separately opt in before names reach desktop notification
  history.
- Medication values are disclosed as local plaintext and are excluded from both
  Rust and Manager diagnostic summaries by tested redaction paths.
- Focused Medications suite: 56 passed. Shared schema/control suite: 58 passed.
  Catalog suite: 18 passed. Manager suites: 65 and 6 passed. All-widget config
  suite: 3 passed. Rust and C++ diagnostic redaction gates passed.
- Compositor-backed health suite: 104 passed, including every supported
  Medications size, state, action, recurrence, rest-day, accent, and backdrop
  projection. The state and size evidence was visually reviewed.

## 20. Brain Dump

**Status: Done**

### User story

As a capture-first user, I want to add, edit, remove, and undo thoughts quickly
without silent loss or inconsistent state.

### Bugs and backlog

- BRAIN-01 P1: Edit and remove actions need explicit accessibility.
- BRAIN-02 P1: Undo state is not shared between all hosts.
- BRAIN-03 P2: Empty state is weak.
- BRAIN-04 P2: Timestamps dominate content.

### Widget-specific Definition of Done

- Add, edit, remove, clear, and undo have explicit controls and announcements.
- Stable entry identity and shared undo produce the same result from every host.
- Limits and eviction are disclosed before persistence.
- Content hierarchy prioritizes the captured thought over its timestamp.

### Completion evidence

- Every capture now receives an immutable ID. Legacy entries receive stable IDs
  on their first mutation, so edit and remove operations do not depend on text
  or a stale row index.
- Capture, edit, remove, and confirmed clear all write an atomic shared undo
  snapshot into the store. The same undo survives serialization and is available
  to a newly loaded Hub, overlay, or Manager host.
- Expanded edit and remove actions are separate 52 px keyboard and touch targets,
  use bundled icons, expose button roles, and name the affected row. Mutation
  feedback is exposed as visible accessible status text.
- Thought text is 17 to 20 px and visually leads the smaller 13 to 14 px
  timestamp. The empty state gives capture guidance, while hidden queue rows use
  an explicit `+N more` badge.
- The live `characters / 500` and `queue / 100` line discloses both limits before
  saving, and the oldest-entry replacement rule remains visible at every size.
- Focused Brain Dump suite: 40 passed. Manager suite: 65 passed. Catalog suite:
  18 passed. All-widget config suite: 3 passed.
- Compositor-backed health suite: 107 passed, covering every Brain Dump size,
  multiline capture, add, edit, remove, undo, confirmed clear, empty, ordering,
  overflow, timestamp visibility, accents, and backdrops. The size, state, and
  action evidence was visually reviewed.

## 21. Routine

**Status: Done**

### User story

As a routine user, I want structured schedules and stable checklist items that
remain readable and reorder safely.

### Bugs and backlog

- ROUTINE-01 P1: Weekday and reorder configuration uses text entry.
- ROUTINE-02 P1: Text is incorrectly used as item identity.
- ROUTINE-03 P1: Rows need greater legibility.
- ROUTINE-04 P1: Hidden overflow is not disclosed.

### Widget-specific Definition of Done

- Items use immutable IDs while labels remain freely editable.
- Weekdays use structured selection and order uses accessible direct manipulation.
- Completion has explicit controls and predictable daily reset.
- Each size discloses hidden items and preserves readable rows.

### Completion evidence

- Routine configuration now uses a structured list editor with explicit add,
  rename, remove, move-up, and move-down controls plus the shared seven-day
  weekday selector.
- Existing line-based routines migrate on the first structured edit. Migration
  preserves legacy completion keys, while clearing the structured editor cannot
  resurrect old lines.
- Each structured step has an immutable ID. Completion follows that ID through
  label edits and reordering instead of following mutable text or row position.
- Rows are at least 60 px high with 17 to 21 px labels. Completed text remains
  readable, the factual summary uses primary contrast, and constrained lists
  expose an accessible `+N more` badge.
- The explicit checkbox remains the only completion target, supports keyboard
  and touch input, resets by date on read, and stores no streak, history, or
  cross-day score.
- Focused Routine suite: 38 passed. Shared schema/control suite: 59 passed.
  Manager suite: 65 passed. Catalog suite: 18 passed. All-widget config suite:
  3 passed.
- Compositor-backed health suite: 109 passed, covering every Routine size,
  legacy and structured content, completion, reversal, empty, progress,
  all-done, rest, overflow, accent, and backdrop states. The evidence matrix was
  visually reviewed after the completed-row contrast refinement.

## 22. Media

Status: Done

### User story

As a media listener, I want accessible playback controls, trustworthy player
state, and useful progress information without unsafe artwork requests.

### Bugs and backlog

- MEDIA-01 P1: Transport and progress targets need better accessibility.
- MEDIA-02 P1: Elapsed time, total duration, and seeking are absent.
- MEDIA-03 P1: Loading, disconnected, no-player, and artwork-error states blur together.
- MEDIA-04 P2: Preferred-player selection is absent.

### Widget-specific Definition of Done

- Transport controls meet touch and accessibility requirements.
- Progress shows elapsed and total time; seeking is enabled only when supported.
- Player and artwork states are explicit and recover without stale content.
- Preferred player uses discovered MPRIS identity and remote art obeys network policy.

### Completion evidence

- Previous, play/pause, and next are named semantic buttons with keyboard and
  assistive-action support. Unsupported controls remain visible but disabled.
- The progress surface is 48 px or taller, exposes keyboard and assistive seek
  actions, and only invokes MPRIS Seek when the player reports `CanSeek`.
- Elapsed and total time are derived from real MPRIS Position and
  `mpris:length`; live or unknown-duration media is labeled explicitly.
- Session bus disconnected, discovery in progress, no player, and no loaded
  track are separate states. Artwork blocked by policy is disclosed.
- A per-widget preferred MPRIS identity is available, while blank or missing
  preferences retain active-player selection.
- Focused Media QML suites: 64 passed.
- Focused hermetic MPRIS QtTest: passed.
- Compositor-backed Media, HTTP/JSON, and KPI suite: 141 passed.
- Release Hub and Manager build: passed.

## 23. HTTP and JSON

Status: Done

### User story

As an integration user, I want to configure and test a bounded HTTP JSON source
with actionable errors and safe credentials.

### Bugs and backlog

- HTTP-01 P1: Test Connection is missing.
- HTTP-02 P1: Errors do not give enough corrective guidance.
- HTTP-03 P1: Configuration disclosure is incomplete.
- HTTP-04 P2: Refresh is not a fully accessible control.
- HTTP-05 P2: Threshold meaning depends too much on color.

### Widget-specific Definition of Done

- Test Connection validates URL, policy, authentication reference, status, size,
  parse path, and representative output without persisting a secret value.
- Error states identify transport, policy, status, size, parse, and path failures.
- Irrelevant fields hide conditionally and all limits match runtime enforcement.
- Refresh and threshold states have accessible, non-color semantics.

### Completion evidence

- Test Connection uses the same NetHub policy path as live polling and reports
  HTTP status, parse validity, JSON-path validity, and a bounded representative
  value without replacing the last live reading.
- Offline, policy, insecure credential, HTTP, timeout, size, parse, and path
  failures each provide a corrective next step.
- List-only settings hide number, unit, and threshold fields. Runtime polling,
  response-size, list, and numeric limits continue to match the schema.
- Refresh is a named keyboard and assistive-action button using the shared SVG
  icon system. Warning and critical values include visible text labels.
- Focused HTTP/JSON QML gate: 14 passed.
- Shared configuration action gate: 3 passed.
- Focused Manager configuration-dialog gate: 3 passed.
- Compositor-backed Media, HTTP/JSON, and KPI suite: 141 passed.
- Release Hub and Manager build: passed.

## 24. KPI

Status: Done

### User story

As a dashboard builder, I want to safely derive a KPI from a local or remote
source and preview thresholds before trusting the result.

### Bugs and backlog

- KPI-01 P0: Local-file access is not yet limited to approved bounded regular files.
- KPI-02 P1: Test Connection and live preview are missing.
- KPI-03 P1: Threshold relationships are not fully validated.
- KPI-04 P1: Initial setup state is unclear.

### Widget-specific Definition of Done

- Local mode accepts only approved, canonical, bounded regular files and rejects
  links, traversal, devices, pipes, directories, and oversized input.
- Remote mode satisfies the HTTP and JSON security contract.
- Test Connection previews parsed value, formatting, and threshold state.
- Thresholds validate ordering and all empty/error states explain the next action.

### Completion evidence

- Local reads leave QML and pass through a native allowlist that canonicalizes
  the path, rejects traversal and final symlinks, opens without following links,
  verifies a regular file with `fstat`, and caps reads at 1 MiB.
- Directories, FIFOs, missing files, oversized files, outside-root paths,
  traversal, and link escapes are covered by hermetic native tests.
- Test Source supports both network and local modes, shows a representative
  formatted value and threshold state, and does not replace the live reading.
- Invalid normal and Lower is worse threshold ordering is explained. Normal,
  Warning, and Critical are visible text, not color-only state.
- Local rejection, setup, policy, timeout, and network errors state a corrective
  next action. Refresh uses the shared semantic SVG control.
- Focused KPI QML suite: 32 passed.
- Focused ConfigBridge QtTest: passed.
- Compositor-backed Media, HTTP/JSON, and KPI suite: 141 passed.
- Release Hub and Manager build: passed.

## 25. Calendar

### User story

As a calendar user, I want private calendar feeds, shared provider state, and
readable events with honest freshness.

### Bugs and backlog

- CAL-01 P0: Capability URLs need stronger secret storage and diagnostic redaction.
- CAL-02 P1: Hosts duplicate provider fetches and state.
- CAL-03 P1: Loading, empty, stale, partial, and error states are weak.
- CAL-04 P2: Connection editing is duplicated.
- CAL-05 P2: Event rows need greater legibility.

### Widget-specific Definition of Done

- Capability URLs persist as secret references and never appear in diagnostics.
- One bounded provider state serves all hosts and avoids duplicate polling.
- Freshness and partial failures are visible without discarding last good data.
- Events remain readable, calendar-correct, and timezone-correct across DST.

### Completed implementation and evidence

- Environment, file, and future keyring URL references are resolved only inside
  the shared network request. The stored widget value remains the reference.
- Legacy literal URLs remain supported in the mode-0600 config file, while the
  configuration copy recommends references and diagnostics omit private values.
- The app-global network gate now owns a volatile provider lease and result
  cache. Calendar and Now/Next coalesce concurrent requests and reuse a result
  published moments earlier without writing events or URLs to disk.
- The expanded preview no longer duplicates the subscription editor beside the
  shared configuration panel. It provides a clear source summary and refresh.
- Loading, empty, stale, partial, policy, timeout, invalid-source, oversized-feed,
  and unavailable-secret states provide visible status and recovery guidance.
- Event rows use larger title and metadata type while preserving the tested
  per-size row cap and multi-column behavior.
- Focused NetHub suite: 35 passed.
- Focused Calendar network suite: 24 passed.
- Comprehensive Calendar widget suite: 75 passed.
- Focused compositor-backed Calendar interaction and timeout cases: 6 passed.

## 26. Now and Next

### User story

As a meeting user, I want the current and next event, safe joining, and readable
metadata in both orientations.

### Bugs and backlog

- NEXT-01 P1: External Join opens without confirmation.
- NEXT-02 P1: Calendar provider state is duplicated.
- NEXT-03 P1: Portrait layout wastes useful space.
- NEXT-04 P1: Join is missing at some useful sizes.
- NEXT-05 P2: Metadata is too small.

### Widget-specific Definition of Done

- Current and next event hierarchy is clear at every size.
- Join is available where it fits, names the destination, and confirms external opening.
- Shared Calendar provider state preserves freshness and privacy behavior.
- Portrait and landscape use available space without clipping or dead zones.

### Completed implementation and evidence

- HTTPS meeting links are cleaned of common calendar punctuation and the action
  names the destination host.
- The first Join action arms a five-second confirmation. Only a second action on
  the same destination opens the external application.
- Join is rendered as a full touch target in every supported physical shape when
  a meeting link exists, including narrow portrait and short landscape tiles.
- Titles and metadata scale from the real block geometry. Metadata now respects
  the shared label-size floor.
- The duplicate private URL editor was removed from the expanded preview. The
  adjacent shared configuration panel remains the one connection editor.
- The embedded agenda inherits Calendar's private-reference resolution, shared
  provider lease, freshness, recurrence, and DST behavior.
- Focused Now/Next suite: 34 passed.
- Focused compositor-backed expanded-preview case: 3 passed.

## 27. Weather

### User story

As a weather user, I want a consistent forecast with deterministic visuals,
clear location, units, freshness, and recovery.

### Bugs and backlog

- WEATHER-01 P1: Provider state is duplicated across hosts.
- WEATHER-02 P1: Condition visuals depend on platform emoji.
- WEATHER-03 P1: Error and place labels compete.
- WEATHER-04 P1: Forecast text is too small.
- WEATHER-05 P2: Unit options and stale/recovery states are incomplete.

### Widget-specific Definition of Done

- One provider state serves all hosts with bounded polling and last-good data.
- Bundled condition assets render consistently and include accessible descriptions.
- Place, condition, temperature, forecast, freshness, and error have clear hierarchy.
- Temperature, wind, and precipitation units are explicit and tested.

### Completed implementation and evidence

- NetHub's volatile provider lease coalesces simultaneous forecast requests and
  distributes one result to tile, overlay, and passive hosts without disk writes.
- A palette-aware Canvas component replaces platform emoji with deterministic
  clear, cloudy, fog, rain, snow, storm, and unknown condition artwork.
- Place, connectivity state, stale state, and recovery are separate lines.
  A failed refresh retains the last reading while clearly labeling its status.
- A successful refresh after failure reports Connection restored and a temporary
  Recovered badge.
- Forecast labels and values use the shared label-size floor. Current-condition
  supporting text and the rich detail strip were enlarged as well.
- Temperature, wind speed, and precipitation units are configurable. Provider
  URLs include Fahrenheit, mph, m/s, and inch options only when selected.
- Source changes abort and supersede old in-flight work before a differently
  configured reading can land under the new labels.
- Focused Weather network and provider-sharing suite: 29 passed.
- Comprehensive Weather size, schema, and rendering suite: 59 passed.
- Compositor-backed Calendar, Now/Next, and Weather suite: 105 passed.
- Release Hub and Manager build: passed.

## 28. Countdown

### User story

As an event planner, I want to configure a valid one-time or recurring countdown
and understand exactly which occurrence is being counted.

### Bugs and backlog

- COUNT-01 P1: Date and time configuration is unstructured.
- COUNT-02 P1: Leap-day recurrence needs explicit validation.
- COUNT-03 P1: Event identity and target date are too small.
- COUNT-04 P2: Recurrence explanation is incomplete.

### Widget-specific Definition of Done

- Structured controls validate local date, time, timezone, and recurrence.
- Leap-day behavior is explicit and tested for leap and non-leap years.
- Target event and next occurrence remain visible alongside the countdown.
- Before, at, and after-event states follow the configured policy exactly.

### Completed implementation and evidence

- Raw time text was replaced by bounded hour and quarter-hour controls while
  existing saved time strings remain compatible.
- February 29 recurrence now has explicit next-leap-year, February 28, and
  March 1 policies with deterministic tests for every branch.
- The event identity and exact target are larger and remain visible before,
  during, and after the event.
- Recurring countdowns explain the next yearly occurrence and the selected
  leap-day policy. One-time countdowns identify the device-local UTC offset.
- The duplicated expanded-preview editor was removed. Configuration remains in
  the shared panel beside the live preview.
- Focused Countdown logic, size, schema, and rendering suite: 55 passed.
- Focused compositor-backed configuration and event-moment cases: 6 passed.

## 29. End of Day

### User story

As a shift worker, I want an accurate end-of-day progress view that supports
overnight schedules and explains elapsed and remaining time.

### Bugs and backlog

- EOD-01 P1: Overnight ranges need stronger validation.
- EOD-02 P1: Elapsed versus remaining progress is unclear.
- EOD-03 P1: Weekday selection uses CSV.
- EOD-04 P1: Supporting text has weak contrast and legibility.

### Widget-specific Definition of Done

- Structured workday and weekday controls validate ordinary and overnight shifts.
- Before-shift, working, complete, off-day, and invalid states are explicit.
- Progress labels clearly distinguish elapsed and remaining time.
- The correct start weekday governs an overnight shift across midnight.

### Completed implementation and evidence

- The weekday CSV field now renders seven explicit, accessible, touch-sized day
  controls while retaining the canonical saved representation.
- Same-day and overnight validity includes quarter-hour precision. Disabled,
  zero-length, and over-12-hour overnight schedules show distinct actionable
  guidance instead of entering the progress calculation.
- Empty weekday selection, off day, before shift, working, complete, and invalid
  schedule states have explicit labels.
- Compact and wide captions distinguish percent elapsed from time remaining.
  Tall layouts add dedicated Start, End, Elapsed, Remaining, and Done rows.
- Supporting labels and captions use larger text and primary contrast. Visual
  compositor evidence was inspected at compact and tall physical projections.
- Overnight shifts remain assigned to the weekday on which they start, including
  after-midnight progress and daylight-saving calendar endpoints.
- Focused End of Day logic, schema, size, and rendering suite: 86 passed.
- Compositor-backed End of Day size, state, interaction, accent, and backdrop
  sweep: 44 passed.

## 30. Quote

### User story

As a user seeking a short prompt, I want readable, attributable quotes with
predictable custom-library and shuffle behavior.

### Bugs and backlog

- QUOTE-01 P1: The custom separator parser contains a duplicate branch.
- QUOTE-02 P1: Shuffle is not a proper accessible control.
- QUOTE-03 P1: Empty custom input silently falls back to bundled content.
- QUOTE-04 P2: Micro text is too small.
- QUOTE-05 P2: Bundled library and author-display options are limited.

### Widget-specific Definition of Done

- Supported custom formats parse deterministically with line-specific validation.
- Empty or invalid custom input is explicit and never silently changes source.
- Shuffle is touch-sized, accessible, shared across hosts, and never repeats when avoidable.
- Quote and attribution remain readable and rights provenance remains documented.

### Completed implementation and evidence

- Custom separators now use one deterministic precedence table and advance by
  the actual separator length. Empty quote or author fields report their exact
  one-based line number, while valid neighboring lines remain available.
- Empty custom mode stays custom. It renders clear setup guidance instead of
  silently substituting Focus content, and malformed libraries expose validation
  feedback in the expanded view.
- Both tile and expanded next-quote actions use the shared keyboard-accessible,
  touch-sized button component with a semantic accessible name and SVG icon.
- Every bundled category now contains eight original project-owned entries with
  source and rights metadata.
- Micro quote text was enlarged. Author lines now use primary contrast, and the
  author can be shown when provided, always shown, or hidden.
- Shared pinned identity still keeps Hub, overlay, and Manager on the same quote.
- Focused Quote parsing, source, rights, schema, size, action, and sharing suite:
  61 passed.
- Compositor-backed Quote size, category, custom input, separator, state, action,
  accent, and backdrop sweep: 39 passed. Updated micro, baseline, and empty-state
  evidence was visually inspected.

## Combined Definition of Done for all widgets

All widgets together reach Done only when:

1. Every individual widget Definition of Done is satisfied and its issue IDs are closed.
2. WidgetCatalog, Hub resources, Manager resources, tests, documentation, presets,
   and configuration schemas enumerate exactly the same widget set and sizes.
3. Every declared size of every widget renders through the actual Dashboard and
   Manager geometry in portrait and landscape, with containment, legibility,
   touch-target, accessible-name, and non-color-state assertions.
4. Every preset renders real widget previews matching the resulting Hub layout.
5. Hub and Manager remain WYSIWYG for pages, sizes, order, orientation, theme,
   accent, background, configuration, runtime state, and error state.
6. Network and local-data widgets pass policy, secret-redaction, path, response
   size, polling, offline, reconnect, stale-data, and recovery tests.
7. Destructive and consequential actions have confirmation or undo and cannot
   be triggered by an undifferentiated row tap.
8. The behavior matrix covers every widget-scoped configuration field and
   function without relying on a same-named field from another widget.
9. Rust tests, formatting, Clippy, all QML tests, C++ tests, runtime E2E,
   compositor tests, real Hub and Manager tests, resource parity, documentation,
   packaging checks, and the complete aggregate suite pass with zero failures,
   skips, blacklisted checks, fatal diagnostics, or unreviewed warnings.
10. A final real-display review confirms touch operation, orientation changes,
    reconnect, scaling, animation smoothness, Manager placement, Hub placement,
    and viewing-distance readability.
11. The final diff contains no unrelated cleanup, whitespace errors, secrets,
    generated build output, or em dashes.
12. The completed backlog, verification commands, exact totals, evidence paths,
    performance impact, security impact, known limitations, and remaining risks
    are recorded in the final delivery report.
