# Xeneon Edge - Consolidated Fix Plan

> **Historical audit plan (2026-07-13), superseded.** The findings and severity
> labels below describe the tree at the time of that audit; they are not an open
> defect count for the current branch. Many items were subsequently fixed and
> regression-tested. Current release blockers are tracked in
> [MVP scope](product/mvp-scope.md) and [the beta/release gate](BETA_PLAN.md).

504 raw findings (345 audit + 159 test-confirmed). The test set overwhelmingly **corroborates** the audit rather than adding new defects - treat every `likelyRealBug:true` test as a regression gate for the matching audit item. After dedup, ~10 systemic patterns account for well over half the volume. **Fix the systemic patterns first**; most per-widget "lows" evaporate when the root cause is fixed once.

---

## A. Cross-cutting systemic issues (fix once, resolve many)

These are ordered by blast radius. Each consolidates many individual findings.

### S1 - `effAccent ⇄ accentColor` binding loop *(CRITICAL, but 1-line fix)*
`WidgetChrome.qml:32` falls back `effAccent → accentColor`; `MediaWidget.qml:15` sets `accentColor: w.effAccent` → cycle → Media renders black/invisible play glyph out of the box.
**Fix:** Change `MediaWidget.qml:15` to a concrete theme color (e.g. `theme.catEntertainment`), like every other widget. Optionally harden Chrome to detect self-reference. Resolves 2 findings.

### S2 - Declarative control bindings self-destruct after first touch *(breaks live Manager mirroring everywhere)*
Pattern `checked: X; onToggled: X = checked` (and `value:`/`text:` equivalents) severs the binding permanently on first interaction, so later external/store pushes never move the control.
Affected: `ConfigField.qml:87` (text/textarea/date), `SettingsPanel.qml:228/241/246/251`, `Manager.qml:503/518/523/528/677`, `Manager.qml:813` (autostart), `CalendarWidget.qml:245` (URL), `WeatherWidget`/`WidgetConfigDialog.qml:82` (place field), `Manager.qml:143` (page-name).
**Fix:** Adopt a single pattern - keep a `text:`/`checked:` binding and re-assert it in the mutator, or drive controls through a small helper that re-binds on `store.revision`. Resolves ~12 findings (several are high).

### S3 - `active` property declared but never honored *(wasted repaint/accumulation on fanless panel)*
`Dashboard.qml:378` binds `active` for the single-driver rule; widgets never read it.
Affected: Cpu, Gpu, Ram, Net, Disk, Sensors, Analog, Moon (`*.qml:9-10`).
**Fix:** Gate `onMetricsChanged`/`tick` handlers on `active` in each widget (or in a shared mixin). Resolves ~8 findings + several test cases.

### S4 - Metric widgets fabricate `0%` / poison history on empty/partial frames
`|| 0` coalescing + unconditional `hist.push` with no availability gate (contrast GpuWidget's `if(!w.avail) return`).
Affected: `CpuWidget.qml:25/41`, `RamWidget.qml:29`, `DiskWidget.qml:38`, `SensorsWidget.qml:39`. Also unclamped samples (`>100%` → 1.5) and 0°C-treated-as-missing (`CpuWidget.qml:26`).
**Fix:** Add an `avail` guard + `ok:` binding into MetricGauge (mirror GpuWidget), clamp samples to 0..1, skip history push when unavailable, use a real "missing" sentinel distinct from 0. Resolves ~10 findings + many tests.

### S5 - Per-instance state (history, peaks, session counts) not in shared store
Tile and expanded overlay are separate instances; `hist`/`peakRx`/`peakTx` are plain properties, so expanding shows an empty graph and Net peaks reset every open.
Affected: Cpu/Gpu/Ram/Net history, `NetWidget.qml:27-29` peaks.
**Fix:** Persist rolling history/peaks in `DashboardStore` keyed by instanceId (bounded ring). Resolves ~6 findings.

### S6 - DST-unsafe fixed-`86400000ms` day math + non-reactive `todayKey`
Two related date bugs. (a) Fixed-24h stepping drifts across DST: `HabitWidget.qml:37/122`, `CalendarWidget.qml:108/122`, `QuoteWidget.qml:85`, `EndOfDayWidget.qml:34`. (b) `todayKey`/daily counters never roll at midnight on a 24/7 device: `RightNowWidget.qml:23`, `BreakWidget.qml:32` (missing `property int tick`!), `HydrationWidget.qml:24`, `FocusWidget.qml:59`, `QuoteWidget.qml:91` (manual shuffle never clears).
**Fix:** Introduce a shared date helper that steps by calendar date (set to local midnight, add 1 day) instead of ms deltas; ensure every daily widget declares `tick` and derives `todayKey` reactively. Resolves ~12 findings.

### S7 - `effAccent` not applied to widget content (design-system gap)
Content stays category/theme color while chrome recolors.
Affected: Moon (`61-79`), Focus (`77`), RightNow (`73`), EndOfDay ring-mode (`77`), Dashboard expanded overlay (`Dashboard.qml:363`), all card backdrops (`BackdropLayer`/`*Background.qml`), config-panel highlights (`Dashboard.qml:146`).
**Fix:** Thread `effAccent` into content colors and into the expanded overlay (`expandedColor` should read `settingsFor(id).accent` and react to `store.revision`); add an `accent` prop to BackdropLayer. Resolves ~8 findings.

### S8 - `settingsFor()` is a mutating getter called inside bindings
`DashboardStore.qml:121` lazily creates `data.settings[id]={}` as a read side-effect; empty `instanceId` writes a phantom `settings['']`. Grows/persists the document and materializes ghost entries (compounds with orphan-settings never pruned, `DashboardStore.qml:77`).
**Fix:** Make `settingsFor` non-mutating (return a frozen default without assigning); prune orphaned settings on load/applyExternal; guard empty instanceId in ConfigField. Resolves ~4 findings.

### S9 - Screen inventory & orientation frozen at boot (no hotplug)
`main.cpp:488` builds `_screens` once; `screenAdded/Removed` only push a bare name string (`main.cpp:653/658`) into a **misnamed** property (`main.qml:34/50` - `screenAddedChanged` → notifier is `...ChangedChanged`, handler param always undefined). Diagnostics/Wizard/target-migration all stale. Orientation sensor (`orientation_sensor.cpp:74`) never queries initial state and (`:29`) may open the wrong hidraw node; no re-open after unplug.
**Fix:** Re-emit full `_screens` JSON on hotplug via a properly-named notifiable property; re-run `findTargetScreen()`/window migration on `screenAdded`; issue a HID GET_REPORT for initial orientation and add udev/retry re-open. Resolves ~10 findings.

### S10 - Config keys with no FFI getter/setter (write-only / dead)
`theme_accent` (write-only, never read back - accent lost on restart), `reconnect`, `notify_disconnect`, `fallback_behavior`, `reduced_motion`, post-wizard `autostart`.
**Fix:** Add FFI get/set + context properties for each; wire the hub handlers to consult them. Resolves ~6 findings (several high).

### S11 - Repeaters keyed on `store.revision` instead of `structureRevision`
Every keystroke rebuilds structural lists: `EdgeClone.qml:168` (all tile Loaders reload/flicker), `Manager.qml:282/355/…`, `TasksWidget.qml:105` (scroll resets).
**Fix:** Bind structural Repeaters to `structureRevision`. Resolves ~3 findings + tests.

### S12 - Text overflow with no elide/wrap/fontSizeMode on clipped tiles
`ClockWidget.qml:79`, `EndOfDayWidget.qml:83`, `CountdownWidget.qml:53`, `MoonWidget.qml:57`, `HabitWidget.qml:79/96`, `BreakWidget.qml:109`, `WeatherWidget.qml:160`, `SensorsWidget.qml:51` overflow, `MediaWidget` playerName.
**Fix:** Add `fontSizeMode: Text.Fit` + `Layout.maximumWidth`/`elide`/`wrap` where text is user- or data-driven; add scroll/placeholder for overflowing row lists. Resolves ~10 findings.

---

## B. Prioritized bugs by area

### Widgets - CRITICAL / HIGH (beyond systemic)

| Sev | File:line | Problem | Fix |
|---|---|---|---|
| CRIT | `NotesWidget.qml:29` | Save-on-close never runs - overlay is destroyed, `onExpandedChanged`/debounce never fire; entire last edit lost | Flush in `Component.onDestruction`; also re-sync open editor on external push (`:49`) and add equality guard |
| HIGH | `BreakWidget.qml:84` | Timer never seeds `endEpoch` (Component.onCompleted runs before store injected) → never counts down/fires | Seed `endEpoch` in `Loader.onLoaded`/first valid store write; add missing `property int tick` (S6) |
| HIGH | `DiskWidget.qml:27` | Hardcoded 97% red evaluated before `warnPercent` → red below user's warn line, amber unreachable | Clamp critical `≥ max(97, warnPercent)`; order checks warn→critical; clamp `warnPercent` input |
| HIGH | `FocusWidget.qml:128` | "Skip" counts as completed session, awards points + fake celebration (`natural` flag is dead) | Honor `natural`: only count/reward on timer-driven completion |
| HIGH | `CalendarWidget.qml:114` | MONTHLY/YEARLY events never appear (fall-through emits only past DTSTART, then pruned) | Implement monthly/yearly stepping; fix `emit()` "finished" guard to use `now` not midnight (`:72`) |
| HIGH | `CalendarWidget.qml:41` | `TZID=` ignored → timed events at wrong wall-clock time | Parse TZID param; also `webcal://`→`https://` (`:184`), accept 200/203/206/304 (`:178`) |
| HIGH | `QuoteWidget.qml:91` | Manual Shuffle pins quote forever (manualIdx never cleared at midnight) | Clear manualIdx on day rollover (S6) |
| HIGH | `HabitWidget.qml:37` | DST breaks streak count (S6) | Calendar-date stepping |

**Widgets - MEDIUM (representative, non-systemic):**
- `FocusWidget.qml:97/98` Reset/preset-switch wipe today's count & streak; `:87` `+5` while running w/o endEpoch → NaN; `:113` goal celebration only on exact `===`.
- `TasksWidget.qml:45` stale captured `idx` → toggle/remove wrong item or TypeError under concurrent edits; `:146` "No tasks" shown while completed tasks exist.
- `HydrationWidget.qml:49` lowering goal never credits streak; `:54` celebration re-fires on re-cross.
- `BreakWidget.qml:74` ±5m while paused silently resumes; `:69` pause-while-due corrupts pausedRemaining.
- `RamWidget.qml:38` "NN.N GB" overflows ring / printed twice.
- `SensorsWidget.qml:51` rows clipped in 120px tile (S12); `:46` all-off → blank (add placeholder).
- `WeatherWidget.qml:27` unit label flips before value converts; `:72` stale data shown as live on error; `:120` geocode never reports status to panel.
- `CountdownWidget.qml:46` `-999` sentinel collides with real dates ≥999 days past; `:34/42` impossible/Feb-29 dates roll over silently.
- `MediaWidget.qml:83` leading `·` when artist empty.

### Shared infra - HIGH
| Sev | File:line | Problem | Fix |
|---|---|---|---|
| HIGH | `ConfigField.qml:134` | Number field has only +/- steppers - lat/lon (step 0.01) effectively un-enterable | Add keyboard TextInput path for number/hour |
| HIGH | `ConfigField.qml:215` | Date field accepts impossible dates (`2026-19-45`), silently drops partial input | Add validator + range check; feedback on incomplete |
| HIGH | `DashboardStore.qml:67` | Structural edits only debounce-saved, not force-flushed → lost on power cut | `_commitStructure()` calls `flushNow()` |

**Shared infra - MEDIUM:**
- `DashboardStore.qml:217` `removePage(-1)` deletes last page; `:171/195` removeTile/moveTile no bounds check; `:98/104` load/applyExternal accept pages w/o `tiles` array, don't cancel pending save or re-clamp index. (Root: add bounds/normalization/index-clamp to all mutators - resolves ~6.)
- `WidgetConfigSchema.qml:210` eod hour fields lack min/max → stepper corrupts to `25:00`/`-1`; `:201` countdown date no validation. (Add bounds; resolves the eod cluster of ~5 tests.)
- `WidgetCatalog.qml:83` `defaults()` returns live reference → aliasing across instances (deep-clone in `ensureSettings`).
- `DashboardStore.qml:128` `ensureSettings` doesn't bump revision/schedule save; `:280` two id schemes + non-persisted `_idSeq` → collisions.
- `RingProgress.qml:36` 0% draws a colored dot (round-cap); `Sparkline.qml:22` NaN sample poisons whole polyline; `:50` in-place mutation never repaints; `MetricGauge.qml:60` ring shrinks when sparkline pops in.
- Backgrounds: `WavesBackground.qml:44`/`StarfieldBackground.qml`/`GridBackground.qml:60` don't repaint on theme change; portrait-fill issues (mostly low/cosmetic).

### Hub shell (main.qml / Dashboard.qml) - HIGH
- `main.qml:163` `--diagnostics` startup shows empty page (no bindings injected) - same as `Diagnostics.qml`. **Fix:** inject `Qt.binding` for metrics/config/screens on the initial item (and for Ctrl+D pushes `:212`, Dashboard `:569` use bindings not snapshots).
- `main.qml:174` keyboard-lift math wrong in landscape (mixes window vs rotated-item coords). **Fix:** compute lift in the rotated frame.
- `Dashboard.qml:363` expanded overlay ignores per-widget accent (S7); `:299` landscape column count ignores per-page/global `gridCols`; `:393` full-bleed interactive widgets can't be expanded by touch (add an explicit expand hit-target).
- Medium/low: `Dashboard.qml:192` live push while expanded → orphan settings; `:518` page-name `pages()[-1]` during rebuild; `:57` wallpaper path not URL-encoded.

### Hub C++ - HIGH
- `main.cpp:519` wizard theme accent write-only (S10). `:655` reconnect/notify_disconnect unhonored (S10). `:649` hub started before Edge never migrates window (S9).
- `control_server.cpp:108` `setUiState` always acks `ok` even on failure → silent Manager divergence. **Fix:** derive ack from `applyExternalUiState` result.
- `control_server.cpp:55` dangling `buf` reference into `m_buffers` across `handleLine()` reentrancy → possible UAF/heap corruption. **Fix:** re-lookup buffer each iteration / splice before dispatch.
- `mpris_bridge.cpp:152` GetAll reply from replaced player applied to current service (no identity guard); `:207` same for Position. **Fix:** capture the target service in each async lambda and drop stale replies. `:198` unconditional `changed()` every 3s restarts animations (add dirty-check).
- `orientation_sensor.cpp:74/29` initial orientation + wrong-hidraw (S9).

**Hub C++ - MEDIUM:** `control_server.cpp:95` no server-initiated push (on-device edits never reach Manager); `main.cpp:339` autostart only written during wizard; `:148` orientation force-defaults to "portrait"; `:157` weak EDID hash → target collisions; `:498` synchronous first metrics collect on GUI thread races the worker baseline.

### Manager - HIGH
- `manager/src/main.cpp:70` reconnect flushes buffered offline edit **before** pulling hub state → clobbers device-side edits. **Fix:** pull → reconcile/merge → then push (or drop the buffered push if hub is newer).
- `Manager.qml:528` / `:330` broken switch bindings + stale page-name (S2).
- `EdgeClone.qml:168` tile Repeater on `revision` (S11).
- `WidgetConfigDialog.qml:40` reopening for a different instance of the same type shows the previous tile's body (Loader doesn't reload; `instanceId` stays stale) → split-brain preview + unseeded defaults (`:38`).

**Manager - MEDIUM:** `main.cpp:296` `deleteImage` path traversal (sanitize to basename); `:379` `applyAutostart(false)` returns true even on failed remove; `:100` file watcher never armed if config absent at start; `:225` `isEdge` uses logical (scaled) size; `:120` wallpaper `file://` URLs not percent-encoded; `syncTheme` on every keystroke (`Manager.qml:153`).

### Rust core - HIGH / MEDIUM
- `metrics.rs:44` sensor/GPU paths cached in `OnceLock` forever → transient boot-time absence becomes permanent "unavailable". **Fix:** retry discovery (bounded) when currently `None`.
- `metrics.rs:38` global CPU/net delta baseline shared across GUI-thread and worker-thread callers → spurious spikes. **Fix:** per-caller baseline or single owner.
- `config.rs:179` corrupt config → full reset (re-triggers wizard, drops `ui_state`) and overwrites the single fixed `.bak`. **Fix:** timestamped backups, preserve `first_run_complete`/`ui_state` on parse failure where possible, don't overwrite good backup.
- Medium/low: `metrics.rs:449` VPN/tunnel ifaces double-counted; `:337/368` GPU AMD-only despite comment; `ffi.rs:538` `-1.0` sentinel collides with real sub-zero temps (use Option/NaN flag); `:159` first sample always 0%; `config.rs:196` schema migrations unimplemented; `display.rs:19` `parse_manufacturer` emits non-alpha garbage.

---

## C. Notable non-bugs / dead code (verify, then delete - don't "fix" behavior)
- `WidgetChrome.qml:176` hover ring - dead on a touchscreen (no hover); remove or gate.
- `RingProgress.qml:11` `glow` property + repaint handler - no visual effect; remove.
- `Dashboard.qml:25/65` `isLandscape`/`fmtBytes`/`fmtRate` - unused.
- `EndOfDayWidget.qml:27` `validHours` - computed, never read.
- `RightNowWidget.qml:105` pluralization ternary - both branches identical (real UX bug: implement plural, don't just delete).
- `main.cpp:666` `XENEON_GRAB`/`XENEON_EXPAND` - QA hooks active in production; **do** build-guard these (latent footgun).
- Several "accuracy" lows are inherent tradeoffs (moon mean-synodic model ±1 day, clock fixed-UTC-offset DST) - document as known limitations rather than chase.

---

## D. Recommended execution order (phases)

**Phase 0 - Ship-blockers (data loss / setup / unusable):** S1 (Media loop), Notes save-on-close (`NotesWidget.qml:29`), FirstRunWizard Step-1 0px + Step-2/3 overlap (`FirstRunWizard.qml:76/183`), BreakWidget never counts down, `--diagnostics` empty page, DashboardStore force-flush (`:67`). Build-guard the `XENEON_GRAB` hooks.

**Phase 1 - Systemic foundations (unblocks the long tail):** S2 (binding pattern), S4 (metric availability guard), S6 (date/midnight helper), S8 (settingsFor + orphan pruning), S9 (hotplug/orientation), S10 (FFI config keys), S11 (structureRevision). Land with the corroborating test files as gates.

**Phase 2 - Correctness & state integrity:** DashboardStore bounds/normalization cluster, Manager reconnect ordering + control_server ack/UAF + MPRIS service-identity guards, DiskWidget thresholds, Calendar recurrence/TZID, Focus/Habit/Hydration counters, Rust sensor-cache + delta-baseline + corrupt-config backup.

**Phase 3 - Design-system & layout:** S3 (`active`), S5 (shared history/peaks), S7 (effAccent content/overlay/backdrop), S12 (text overflow), touch-target sizing (<44px items), config-field number/date entry.

**Phase 4 - Polish / cleanup:** dead-code removal (Section C), unit-label accuracy (GiB/GB), cosmetic background/portrait-fill, Diagnostics footer labels, minor Manager desktop UX.

---

## E. Rough severity counts (deduplicated)

| Severity | Audit (A) | After dedup | Notes |
|---|---|---|---|
| Critical | 2 | 2 | Notes save-loss; Wizard Step-1 0px |
| High | ~35 | ~30 | ~2 exact dups (Media loop ×2, Diagnostics-empty ×2); several collapse into S9/S10 |
| Medium | ~90 | ~80 | large fraction fold into S2/S6/S8/S11 |
| Low | ~218 | ~150+ | bulk are S3/S7/S12 instances + cosmetic; ~15 are pure dead-code cleanups |
| **Total** | **345** | **~460 unique** | |

The 159 test-confirmed bugs are almost entirely a **verification layer** over the audit (matching file:line), not new defects - they map cleanly onto S2/S4/S6/S7 and the high-severity widget bugs, so they double as the regression suite for each phase. Net practical takeaway: **~12 systemic fixes (S1–S12) plus ~30 discrete high-severity bugs** eliminate the vast majority of the 504 findings.
