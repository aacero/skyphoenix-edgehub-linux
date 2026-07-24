# Widget Remediation Backlog

Audit date: 2026-07-23 to 2026-07-24
Scope: latest Hub and Manager sources, all 30 catalog widgets, every declared size, widget configuration, live synchronization, and real-display behavior

## Test baseline

All 30 widget remediation sequences are complete. Each widget was changed,
given focused behavior and size tests, and passed before work moved to the next
widget. The rebuilt Release binaries then passed the combined source,
integration, runtime, and compositor gates.

Verified on 2026-07-24:

- Release build: passed
- Rust: 258 passed, 0 failed
- QML source suite: 3,155 passed across 99 files, 0 failed, 0 skipped
- C++: 24 passed, 0 failed
- QML behavior matrix: 497 of 497 behaviors, 100.0 percent
- Runtime E2E: all nine scenarios passed
- Nested-compositor GUI: 1,479 passed, 0 failed, 0 skipped
- Rust formatting and Clippy with warnings denied: passed
- WidgetCatalog, Hub resource, and Manager resource parity: 30 of 30
- Preset previews: all 19 presets use real widgets in both orientations
- Repository U+2014 em-dash scan: passed

The aggregate log is `/tmp/edgehub-widget-final-20260724.log`. Every functional
phase passed. Its first behavior-matrix pass reported 496 of 497 because the new
and already-passing `main.applyExternalUiState` regression test lacked a
`COVERS` declaration. The declaration was added and the direct rerun passed 497
of 497.

The five opt-in physical Manager input suites remain fail-closed before input.
KWin reports the Hub as active, opaque, fullscreen, and correctly placed at
DP-3 geometry `5120,2880 720x2560`, while Spectacle returns the Plasma desktop
instead of that rotated fullscreen surface. IPC persistence and the live QML
apply path both passed, but the safety harness correctly refuses synthetic
clicks without an independent pixel proof. No physical Manager input result is
claimed from that blocked run.

## Priority definitions

- P0: data loss, security, dangerous action, inaccessible primary action, or incorrect core result
- P1: functional correctness, WYSIWYG, state continuity, serious layout, or legibility problem
- P2: information design, configuration quality, accessibility, or resilience improvement
- P3: useful feature and polish improvement

## Shared backlog

- [x] P0 Make real Manager automation locate controls from stable accessible identities and prove the target window is foreground before injecting input.
- [x] P0 Make network-capable widgets use the shared Hub policy path for every remote request, including media art.
- [x] P1 Key behavior coverage by widget and field instead of treating identical field keys as global coverage.
- [x] P1 Derive the complete Hub and Manager widget-resource parity test from WidgetCatalog.
- [x] P1 Render each declared size through the actual Dashboard and Manager host geometry, in both orientations.
- [x] P1 Add containment assertions for visible controls and text. A nonblank screenshot alone is not a layout test.
- [x] P1 Add actual-widget preset previews for every preset and compare preview geometry with the resulting Hub page.
- [x] P1 Raise meaningful supporting text on the Hub to an arm-length legibility floor, removing secondary content before shrinking essential text.
- [x] P1 Complete accessible names, roles, focus behavior, keyboard activation, and 48 by 48 touch targets for custom interactive surfaces.
- [x] P2 Add conditional configuration disclosure, inline validation, and source-specific help.
- [x] P2 Replace functional emoji with the shared SVG icon system where the glyph communicates status or an action.
- [x] P2 Add last-success, stale, unavailable, disconnected, and recovery states consistently.

## Per-widget backlog

### CPU

- [x] P1 Make temperature source selection report the actual sensor and unavailable reason.
- [x] P1 Increase detail-label legibility and rebalance the ring so values and context use the larger sizes.
- [x] P2 Add non-color warning semantics plus accessible status text.
- [x] P3 Add frequency, load average, per-core inspection, and a named history window.

### GPU

- [x] P1 Reset or separate history when the selected device changes.
- [x] P1 Replace generic device choices with discovered identity and recovery for disconnected devices.
- [x] P1 Label binary memory units as GiB and improve VRAM and power legibility.
- [x] P2 Add driver, clock, fan, and source details with explicit unsupported states.

### Memory

- [x] P1 Make larger cards prioritize used, available, swap, and pressure instead of enlarging the ring.
- [x] P1 Make warning thresholds configurable and explain PSI terminology.
- [x] P2 Name the history window and expose minimum, average, and peak.
- [x] P2 Use GiB for binary values.

### Network

- [x] P0 Restore per-instance runtime state when instanceId changes.
- [x] P1 Prevent double counting across aggregate and selected interfaces.
- [x] P1 Show interface identity, link state, graph scale, time window, and non-color direction labels.
- [x] P1 Correct binary versus decimal rate labels.
- [x] P2 Replace free-text interface configuration with discovery and explain virtual-interface inclusion.

### Disk

- [x] P1 Make the critical threshold reachable when warning is configured at 99 percent.
- [x] P1 Use actual byte counters instead of reconstructing used bytes from a rounded percentage.
- [x] P1 Reduce ring dominance and increase capacity legibility.
- [x] P2 Add mount selection, filesystem identity, I/O, and threshold preview, or remove the under-filled tall size.

### Sensors

- [x] P1 Keep enabled but unavailable sources visible with an explicit unavailable reason.
- [x] P1 Remove unsupported micro expectations and use a reduced readable subset at small sizes.
- [x] P1 Replace color-only warnings with text or icon state.
- [x] P2 Replace CSV row ordering with a reorder control.
- [x] P2 Make fan and power ranges source-aware and add GPU selection.

### Packages

- [x] P1 Show the detected package database and an explicit unavailable state.
- [x] P1 Explain count scope and show unavailable instead of a valid-looking empty value.
- [x] P2 Add safe RPM-family detection and a manual read-only refresh action.
- [x] P2 Fill detailed sizes with explicit update and security status plus provenance.
- [ ] P3 Add trustworthy available-update and security-update counts if a
  non-mutating, fresh-data provider becomes available. Current package caches
  can be stale, so the released behavior says `Not checked` rather than faking
  a zero.

### System Age

- [x] P1 Show the exact date, source, and confirmed or estimated status in the detailed card.
- [x] P1 Show the exact derived date, source, and estimate status in every size that claims detail.
- [x] P1 Handle rotated or incomplete package logs without presenting false precision.
- [x] P2 Add calendar-aware unit choices and fill rich sizes with evidence context.
- [x] P3 Keep this as a focused System Age widget rather than merging it into
  System Identity; the packages companion already supplies distribution and
  inventory context without making either widget harder to scan.

### Clock

- [x] P0 Fix day-of-year calculation across DST boundaries.
- [x] P1 Use locale-aware short dates instead of hardcoded day/month order.
- [x] P1 Hide fixed-offset fields when an IANA zone is selected and add a live custom-pattern preview.
- [x] P2 Replace secondary-zone CSV entry with a structured searchable zone editor.
- [x] P2 Increase secondary text legibility at larger viewing distance.

### Analog Clock

- [x] P1 Report invalid timezone configuration instead of silently falling back.
- [x] P1 Improve fixed-offset and DST behavior.
- [x] P2 Add an accessible time description for the Canvas face.
- [x] P3 Add face, numeral, hand, motion, and timezone-label choices.

### Moon Phase

- [x] P1 Disclose phase direction and that the local calculation is an approximate geocentric model.
- [x] P1 Replace the platform-dependent emoji as the primary visual with a deterministic asset.
- [x] P1 Increase rich-information legibility and reduce caveat dominance.
- [x] P2 Add optional location-aware rise, set, and illumination context.
- [x] P3 Evaluate a useful intermediate size between baseline and tall.

### Focus Timer

- [x] P1 Fix the portrait GUI harness so controls are tested inside the captured work area.
- [x] P1 Improve phase and supporting-text contrast and arm-length legibility.
- [x] P1 Show custom duration fields only for the custom preset.
- [x] P1 Add confirmation or safer separation for Skip.
- [x] P2 Add an optional completion notification when the page is hidden.

### Tasks

- [x] P0 Stop whole-row taps from completing a task accidentally.
- [x] P1 Add explicit accessible complete, edit, and remove actions with undo.
- [x] P1 Increase row text size and reduce excessive density.
- [x] P1 Explain or rename Top 3 because it currently means the first three items.
- [x] P2 Remove duplicate editing surfaces and add a clear empty state.

### Right Now

- [x] P1 Route config-side text changes through the same lifecycle as inline setText and Start.
- [x] P1 Prevent short text from rendering too small and let long text wrap before eliding.
- [x] P1 Increase context and elapsed-state legibility.
- [x] P2 Make current activity, context, and timer hierarchy clearer at every size.

### Notes

- [x] P1 Route config edits through note history so Hub and Manager changes remain undoable.
- [x] P1 Bound persisted note size and report truncation instead of silently losing text.
- [x] P1 Increase reading size and reduce dense competition with the footer.
- [x] P2 Consolidate duplicate editors and make edit mode discoverable.

### Habit

- [x] P0 Preserve a long streak when unchecking today even when older daily history has been pruned.
- [x] P1 Keep the 1x1.5 landscape insight panel and check-in action fully inside the card.
- [x] P1 Add non-color heatmap meaning and date or weekday context.
- [x] P1 Replace free-text weekday configuration with structured controls.
- [x] P2 Improve check-in feedback and large-size statistics.

### Hydration

- [x] P1 Move the micro celebration so it never covers the primary count.
- [x] P1 Route Manager goal changes through setGoal so streak credit is consistent.
- [x] P1 Make Undo a real one-step undo instead of toggling repeatedly between two counts.
- [x] P2 Strengthen serving-volume visibility and replace action emoji with deterministic icons.

### Break Reminder

- [x] P0 Stop the timer from continuing outside the configured work schedule.
- [x] P1 Fix portrait evidence capture and assert every button is within the widget body.
- [x] P1 Replace weekday CSV entry with structured controls and improve paused-state contrast.
- [x] P2 Add optional due notifications when the page is hidden.

### Medications

- [x] P0 Replace whole-row “taken” activation with an explicit guarded action.
- [x] P1 Add non-color state, larger status text, and accessible action naming.
- [x] P1 Replace free-text schedule configuration with structured time and recurrence controls.
- [x] P1 Document local plaintext sensitivity and prevent medication data from diagnostics.
- [x] P2 Add optional reminders and safe post-window not-marked behavior.

### Brain Dump

- [x] P0 Replace the one-line editor with a multiline field suitable for the 500-character limit.
- [x] P1 Report truncation and oldest-entry eviction before data is lost.
- [x] P1 Make edit and remove explicit, accessible actions.
- [x] P1 Share undo state between tile, overlay, and Manager.
- [x] P2 Improve the empty state and reduce timestamp dominance.

### Routine

- [x] P0 Replace whole-row toggles with explicit accessible completion controls.
- [x] P1 Replace weekday CSV and textarea reordering with structured controls.
- [x] P1 Use stable item identity instead of text as identity.
- [x] P1 Increase row legibility and expose overflow when more items exist.

### Media

- [x] P0 Prevent remote album-art URLs from bypassing NetHub and the egress allowlist.
- [x] P1 Add accessible transport controls and a larger semantic hit surface for progress.
- [x] P1 Show elapsed and total time, and add seeking where supported.
- [x] P1 Distinguish loading, disconnected, no-player, and artwork-failure states.
- [x] P2 Add preferred-player selection.

### HTTP and JSON

- [x] P0 Never send bearer credentials over plain HTTP without an explicit safe policy.
- [x] P0 Bound response size and parsing work.
- [x] P1 Respect listMax in expanded mode.
- [x] P1 Enforce the schema minimum polling interval at runtime.
- [x] P1 Add Test Connection, actionable errors, and conditional configuration fields.
- [x] P2 Replace raw refresh interaction and color-only thresholds with accessible controls and semantics.

### KPI

- [x] P0 Restrict local-file access to approved bounded regular files.
- [x] P0 Never send bearer credentials over plain HTTP without an explicit safe policy.
- [x] P0 Bound response size and parsing work.
- [x] P1 Share raw history so tile and overlay cannot overwrite each other with different normalized series.
- [x] P1 Enforce the schema minimum polling interval at runtime.
- [x] P1 Add Test Connection, a live preview, threshold validation, and clearer setup state.

### Calendar

- [x] P0 Protect private calendar capability URLs and redact them from diagnostics.
- [x] P1 Share provider state so multiple hosts do not refetch independently.
- [x] P1 Fix tomorrow classification across DST transitions.
- [x] P1 Improve loading, empty, stale, partial, and error states.
- [x] P2 Consolidate duplicate connection editors and increase event-row legibility.

### Now and Next

- [x] P0 Compute all-day boundaries with calendar arithmetic, not fixed 24-hour milliseconds.
- [x] P1 Ask for confirmation before opening an external Join URL.
- [x] P1 Share the Calendar connection and provider state instead of duplicating it.
- [x] P1 Reduce portrait dead space and make Join available at useful tile sizes.
- [x] P2 Increase metadata legibility.

### Weather

- [x] P1 Share provider state between tile, overlay, and Manager.
- [x] P1 Replace platform-dependent condition emoji with deterministic weather assets.
- [x] P1 Separate error and place labels and increase forecast legibility.
- [x] P1 Show manual coordinates only when manual location mode is active.
- [x] P2 Complete unit options and add truthful stale and recovery states.

### Countdown

- [x] P0 Fix yearly recurrence when the configured time has already passed today.
- [x] P1 Use a structured time input and validate leap-day recurrence.
- [x] P1 Increase event identity, date, and label legibility.
- [x] P2 Add a clear next-occurrence explanation for recurring events.

### End of Day

- [x] P0 Attribute an overnight shift to its start day so weekday scheduling is correct.
- [x] P1 Validate overnight ranges and explain elapsed versus remaining progress.
- [x] P1 Replace weekday CSV with structured controls.
- [x] P1 Increase supporting-text contrast and legibility.

### Quote

- [x] P0 Share shuffle state so Hub tile, overlay, and Manager remain WYSIWYG.
- [x] P1 Fix the duplicate custom-quote separator parser branch.
- [x] P1 Replace the raw Shuffle hit surface with an accessible control.
- [x] P1 Report an empty custom library instead of silently using the built-in list.
- [x] P2 Increase micro text size, expand the built-in library, and add author-display options.

## Completion rule and result

A widget is marked complete only after its selected backlog item is implemented, its focused unit or compositor test passes, the changed size is inspected, and the widget has no new warnings. The full suite is rerun after the per-widget sequence, followed by the exact Hub and Manager real-display paths that failed in the baseline.

Result: all 30 catalog widgets meet this completion rule. The Packages P3 item
is a conditional future capability, not a correctness gap: the product reports
`Not checked` because no cross-distribution provider can currently guarantee a
fresh, non-mutating update and security count. It must not be implemented by
presenting stale cache data as a trustworthy zero.
