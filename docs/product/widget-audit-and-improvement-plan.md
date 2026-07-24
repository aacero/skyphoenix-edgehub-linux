# EdgeHub Widget Audit and Improvement Plan

**Status:** Implementation in progress; owner approved on 2026-07-22
**Audit date:** 2026-07-22
**Scope:** 30 first-party widgets, 19 preset screens, Hub and Manager configuration, Hub and Manager preview parity, and immersive Hub controls

## 1. Decision summary

The widget system has a strong technical foundation: a single catalog, semantic sizes that rotate correctly, shared chrome and configuration components, a private live-sync path between Manager and Hub, and substantial behavior tests. The next release should improve trust, setup, accessibility, and persona completion before adding a large number of new widgets.

The first implementation wave should address these P0 items:

1. Add Standard and Immersive Hub control modes, defaulting existing users to Standard.
2. Make the Manager preview use the same bottom-bar geometry as the Hub.
3. Introduce shared unconfigured, loading, fresh, stale, blocked, error, and unavailable states.
4. Remove the silent Berlin Weather default and add shared location onboarding.
5. Add conditional configuration fields, validation, secret handling, and Test Connection.
6. Fix accessibility metadata, keyboard focus, reduced-motion behavior, and catalog-wide touch verification.
7. Reconcile preset marketing copy with the actual layouts, then improve connected presets that currently open mostly empty.
8. Fix duplicate active widget drivers in Manager previews and establish one shared widget-host contract.

No product code is changed by this plan.

### Requirement map

| ID | Requirement group | Primary evidence and acceptance section |
|---|---|---|
| LOSS-001 | Confirm page deletion and separate config reset from personal-data erase | Sections 2, 3, 8 Phase 0A |
| HOST-001 | Shared WidgetHost and exactly one active state driver | Sections 2, 3, 8 Phase 0B |
| STATE-001 | Canonical provider state, freshness, stale/error recovery | Sections 2, 3, 8 Phase 0C |
| CFG-001 | Draft Apply/Cancel, conditions, validation, versioned migrations | Sections 2, 3, 8 Phase 0D |
| SEC-001 | CredentialStore, redaction, egress intersection, local-file limits | Sections 2, 3, 7, 8 Phase 0D |
| A11Y-001 | Semantics, keyboard/focus, 48-pixel targets, contrast, text scale, reduced motion | Sections 2, 3, 8 Phase 0E |
| TEST-001 | Catalog-derived render/state/config/touch/preset/parity evidence | Sections 2, 8 Phase 0F, 9 |
| IMM-001 | Standard and Immersive Hub controls | Section 6 and Phase 1 |
| PRESET-001 | Preset truth, onboarding, behavior defaults, and persona validation | Section 5 and Phase 3 |
| WIDGET-001 | Per-widget size, data, design, config, and safety improvements | Section 4 and Phase 2 |
| NEW-001 | Dependency-gated first-party widget backlog | Section 7 and Phase 4 |
| DOC-001 | Generated preset copy and qualified marketing/nonclaims | Sections 5 and 7 |

## 2. Audit method and definition of done

The review used 15 distinct roles:

1. Business analyst
2. Product owner
3. Solution architect
4. Senior Linux/system developer representing developer, homelab, and gamer needs
5. Productivity, wellness, neurodivergent, student, remote-work, and creator domain specialist
6. Finance, trader, data, calendar, and time domain specialist
7. Manual QA tester
8. Test automation engineer
9. Accessibility and touch-display specialist
10. UI/UX analyst
11. Product visual designer
12. Product marketing specialist
13. Adversarial rubber-duck reviewer
14. Security, privacy, and product legal reviewer
15. Cross-sector persona user researcher

Each role reviewed the repository independently, and this document reconciles their findings into one decision set. Static beauty and physical-touch conclusions remain subject to the specified real-display validation after implementation.

Each widget was assessed against the same contract:

- user job and intended outcome;
- source, permissions, refresh behavior, and data freshness;
- useful information at every declared size in portrait and landscape;
- visual hierarchy, density, empty space, and legibility;
- inline touch behavior and accidental activation risk;
- Hub and Manager configuration quality;
- unconfigured, loading, empty, stale, disconnected, blocked, error, and recovery states;
- reduced motion, contrast, accessibility metadata, keyboard and mouse fallback;
- Hub, Manager preview, persistence, and live-sync parity;
- preset and persona fit;
- automated and real-device evidence.

A widget is complete only when every declared size has meaningful content in both orientations, no clipping, no hover-only action, touch hit areas of at least 48 logical pixels, truthful freshness, accessible names and roles, reduced-motion behavior, config-to-render tests, and Hub versus Manager parity evidence.

### Decisions fixed by this plan

- A visible or enabled action has a hard minimum hit area of 48 by 48 logical pixels. There is no silent exception.
- First-party state vocabulary is `unconfigured`, `loading`, `fresh`, `stale`, `blocked`, `disconnected`, `error`, `empty`, and `unavailable`. Catalog metadata declares which states apply. Provider transitions are tested, and recovery returns through `loading` to `fresh`.
- First-party config dialogs use a draft. Changes update the local preview, but persistence and Manager-to-Hub push occur only on Apply. Cancel discards the draft. Closing with changes asks Apply, Discard, or Continue editing. Test Connection runs from the Hub when connected and uses the same NetHub, secret resolver, policy, and authority as production. It is unavailable with an explanation when that authority is offline.
- New bearer tokens and calendar capability URLs are stored through a CredentialStore backed by the desktop Secret Service when available. Config stores only a credential reference. Environment and file references remain supported and resolve only on the Hub. If secure storage is unavailable, the UI requires a reference instead of storing a new literal. Legacy literals remain readable, are masked everywhere, and receive an explicit non-destructive migration action.
- Conditional fields use a declarative conjunction of equality predicates against keys in the same widget schema. Cycles are rejected by tests. Hidden values remain stored but are excluded from validation and runtime output until their condition is true.
- Per-instance settings store a reserved integer `__version`. WidgetCatalog owns the current version and a stepwise migration function. Failed migration preserves the original bucket read-only and shows recovery; newer unknown versions are never rewritten by an older build.
- The running Hub is the only active driver for polling, countdown advancement, and persisted ephemeral results. Hub tile and expanded hosts elect exactly one active view. EdgeClone and Manager dialog are passive renderers. When Hub is absent, Manager previews remain passive and do not perform widget egress.
- Runtime user widgets are outside the first-party render/config/state guarantee until their manifest contract gains equivalent metadata. They remain covered by loader isolation, permission disclosure, and failure-boundary tests.
- New and migrated installs default to Standard controls. Entering Immersive requires confirmation and names Manager plus `/usr/bin/xeneon-edge-hub --standard-controls`, a command-only recovery path that atomically restores Standard and exits without opening the Hub. No hidden gesture and no auto-hide behavior are included.
- A managed policy may explicitly force `hubControlsMode`. If it does not, the preference remains user-editable even when a preset is policy-locked. A noninteractive `Managed` pill, 24 logical pixels high with 8-pixel inset, floats at top center above every dashboard/empty/expanded state and reserves no bottom-row height. Its accessibility label explains whether policy is active or in fail-closed error state.
- Standard mode uses a condensed current/total indicator when page dots do not fit. Edit mode prioritizes edit controls and current/total over the long page name and managed sentence. There is no arbitrary page-count limit.
- At 1.6 text scale, secondary metadata is removed first, then text reflows or elides. Lists may scroll within their existing list surface. Primary values and actions never clip or shrink below token minimums. A size that cannot meet this rule is removed from the widget's declared sizes.
- Hub page deletion requires confirmation with the page name and widget count. Widget reset changes presentation/config only. Erasing tasks, notes, check-ins, schedules, timer history, or other personal state is a separate destructive action with explicit scope and confirmation.
- Secrets, calendar query strings/events, medication data, and credential references are redacted from logs, diagnostics, screenshots, exports, crash reports, and support bundles. Sensitive local data is documented as plaintext unless it is in CredentialStore.
- Managed egress is the intersection of the application allowlist, managed allowlist, and request-specific restriction. A widget can narrow policy but never widen it. Canonical host, port, IDNA, redirects, DNS, IPv6, and response-size limits are tested.
- Local-file KPI access requires explicit opt-in to one canonical regular file or approved metrics directory, displays path and cadence, caps bytes, rejects unsupported schemes/special files, and warns that network-mounted files can cause OS-level traffic.
- The 298 render cases are the current derived count, not a permanent hard-coded product number. Tests derive the expected count from the catalog and may snapshot it only to require intentional review when the catalog changes.
- Persona interviews are discovery evidence, not an automated release gate. Research records tasks, completion rate, time, errors, and qualitative confidence; deterministic release gates remain in automated and real-device acceptance criteria.

## 3. Shared findings

### P0 findings

- The Manager preview does not currently reserve the Hub bottom-bar footprint. Standard-mode preview geometry is therefore not fully WYSIWYG.
- The Manager can host the same widget instance in EdgeClone and WidgetConfigDialog with both marked active. Timers and network widgets can have two state drivers.
- Network widgets preserve useful values but do not expose a standard last-success or stale state. HTTP/JSON currently stores `httpAt: 0` rather than a useful timestamp.
- Several core metric read failures can collapse to valid-looking zeroes. Metrics need per-reading availability, sample timestamp, source, and failure reason so `0%` never means `unknown`.
- Weather starts with Berlin coordinates and can confidently display irrelevant information before setup.
- Calendar subscription URLs are bearer capabilities stored and displayed as ordinary text. HTTP tokens also use ordinary text fields.
- The common config schema has no conditional visibility, dependency rules, inline error summary, sensitive field type, draft validation, Test Connection, or undo.
- Reset to defaults can erase user content and runtime state, such as tasks, notes, timer progress, and check-ins, while the action is presented as a settings reset. Data reset and appearance/config reset need separate, explicit confirmation.
- Hub page deletion is an immediate single tap with no confirmation or undo, while Manager asks for confirmation. This is a high accidental-loss risk beside other edit controls.
- EdgeClone combines whole-tile drag, click-to-configure, and immediate remove in a small overlay. Separate selection from dragging, use an explicit handle or long press, and confirm or undo removal.
- None of the 30 selectable widget QML files declares Qt `Accessible` metadata. Many interactive surfaces are custom MouseAreas.
- Several celebration and alert animations continue to flash and scale under reduced motion. Changing easing to linear is not sufficient.
- Shared configuration controls allow 44 or 46 logical-pixel targets in several paths, while this touch product should standardize on at least 48. Slider visuals are smaller still, so their semantic hit areas must be verified separately.
- Meaningful timestamps, empty/help copy, completed items, and medication states sometimes use `textTertiary`, although that token is treated as decorative. Meaningful text needs a contrast-safe semantic token.
- Several on-accent foregrounds are hardcoded instead of using a contrast-derived semantic token. Dark/custom accents can therefore reduce control and checkmark contrast.
- Theme palettes can change both color and card geometry substantially, which weakens a stable product silhouette. Theme variation should emphasize palette while preserving core spacing and shape identity.
- Manager config preview always uses expanded mode at a fixed portrait-oriented logical width. It does not prove the selected tile size or orientation, and the dialog has no narrow stacked layout.
- Manager has a backend save-error signal but no visible error handling on the main surface. Offline and connected copy can therefore claim saved/live state without a user-visible acknowledgement.
- The shared date regex accepts impossible calendar dates such as 30 February; the widget rejects them later, after the form appeared to accept the value.
- Page count is not bounded, but the Standard bottom bar must fit page name, managed disclosure, indicators, and up to six edit controls. Many-page portrait behavior needs an overflow design.
- `tst_all_widget_configs.qml` covers only 22 widget types. The resize matrix verifies store acceptance, not visual fitness. The shared touch test does not cover every interactive widget and declared size.
- The catalog currently declares 149 widget-size combinations, or 298 render cases across both orientations. No single runtime test renders that full matrix.
- The QML behavior matrix can report full lexical coverage while catalog iteration only proves registry presence. Type-qualified config effects, semantic visible states, and render parity need runtime evidence.
- UI-state appearance and per-widget settings lack enforceable, versioned normalization. Crafted or legacy state is mostly defended inside each widget instead of at one boundary.

### P1 design-system improvements

- Add a shared WidgetHost used by Dashboard, EdgeClone, and WidgetConfigDialog.
- Add catalog metadata for provider type, refresh policy, stale threshold, permissions, config version, and per-size information contract.
- Add a shared StatusBadge pattern with compact and expanded explanations.
- Define shared visual contracts for numeric heroes, units, metadata, micro-card identity, overlay hierarchy, bounded header status, and state illustrations.
- Standardize configuration order: General, Data source, Content, Display, Behavior, Appearance, About.
- Add schema rules such as `visibleWhen`, `enabledWhen`, `requiredWhen`, `sensitive`, validator, and action result.
- Add a responsive Manager config dialog that stacks preview and form at narrow widths and can preview the tile's real size and orientation.
- Keep the last good reading when a refresh fails, but clearly mark it stale and show the last success time.
- Add a transient page indicator while swiping in Immersive mode without recreating a permanent control bar.
- Add actual screen-reader names, keyboard actions, focus rings, and switch/control semantics.
- Add focus containment and restoration for modal surfaces, Escape/Back behavior, arrow-key navigation for grouped controls, and live announcements for timer, media, task, habit, hydration, medication, validation, and connection-state changes.
- Test whole-widget reflow at a 1.6 text scale, all themes/accents/glass endpoints, and no color-only meaning.
- Replace functional emoji/text symbols with the SVG icon system where the glyph is an action or status. Keep emoji only where it is intentional content.

## 4. Widget-by-widget improvement strategy

### System and hardware

| Widget | Current value and source | Size assessment | Configuration and design strategy |
|---|---|---|---|
| CPU | Rust metrics from kernel sources provide utilization, temperature, core count, and a 48-sample history. | `0.5x0.5` to `1x1.5` is justified. Micro is a readout; wider and taller cards add history and summary. | P0: keep thermal warning semantics active even when temperature text is hidden. P1: per-core view, frequency, load average, selectable temperature source, named history window, freshness, and top-process detail. |
| GPU | Rust metrics currently emphasize AMD `amdgpu` utilization and temperature with history. | The five declared sizes adapt well, but unsupported hardware weakens presets. | P0: NVIDIA/Intel capability truth, multi-GPU selection, hot-plug rediscovery, explicit unavailable reason, and correct zero/subzero temperature handling. P1: VRAM, power, clock, fan, driver and device name. |
| Memory | Rust metrics provide used percentage, used and total bytes, and history. | Micro and baseline are strong. Larger cards need more than a bigger graph. | P1: available memory, cache, buffers, swap, pressure, min/average/peak, freshness, and correct GiB rather than GB labels for binary values. |
| Network | Aggregate receive and transmit rates, history, and session peaks come from Rust metrics. | Wide and tall layouts use space well through `1x1.5`. | P0: disclose current exclusion rules and add interface/inclusion selection for VPN, bridge, container, and virtual traffic. P1: identity, link state/speed, latency, packet loss, totals, scale mode, and resettable peaks. |
| Disk | Root filesystem usage, used, free, and total are derived through the core. | Micro and baseline are useful. A static ring under-fills `1x1.5`. | P0: use actual byte counters instead of reconstructing Used from rounded percent times total. P1: remove `1x1.5` now; restore it with mount selection, multiple volumes, I/O, filesystem name, and warnings. |
| Sensors | Combines CPU, GPU, memory, disk, and temperatures from the metrics payload. | Wide two-column layout is useful. Six micro rows can become illegibly small and larger cards mostly enlarge bars. | P0: remove micro support until a reduced micro subset stays readable. Distinguish disabled from unavailable/stale. P1: row order, source labels, per-row thresholds, fan RPM, and power. |
| Packages | DistroBridge reads `/etc/os-release`, pacman directories, or dpkg status without changing the system. | One number is appropriate at micro and compact sizes but under-fills `1x1.5`. | P1: cap at `1x1` now. Restore larger sizes only after available/security updates add useful content. Add RPM only through a safe library/API, not fragile command output. |
| System Age | DistroBridge derives an install-age estimate from package-manager history and shows the date/caveat. | Useful as a small system identity fact; larger cards waste space. | P2: cap at `1x1` now. Later merge kernel, uptime, distro, install estimate, and boot facts into System Identity. Distinguish confirmed date from log-age estimate. |

### Time and ambient

| Widget | Current value and source | Size assessment | Configuration and design strategy |
|---|---|---|---|
| Clock | System time plus OS tzdata through TimeZoneBridge; supports local/fixed/IANA time, date, seconds, ISO week/day. | One of the strongest density ladders from micro to half screen. | P1: searchable full IANA list, locale and date-pattern controls, optional multi-zone strip, sunrise/sunset companion data, and DST explanation for fixed offsets. |
| Analog Clock | Local system time rendered on Canvas with optional seconds and numerals; larger cards add date/digital time. | Aesthetic scaling is valid, and the card progressively reveals context. | P2: world-clock parity, face/numeral/hand styles, motion setting, and timezone label. Ensure second-hand motion is disabled under effective reduced motion. |
| Moon Phase | Local synodic calculation gives phase, illumination, age, and next new/full dates, with hemisphere choice. | Current range through `1x1` is honest. | P2: keep the current size range. Add shared location, moonrise/moonset, accuracy wording, and astronomical detail as a later bounded story; that story must separately justify any new size. |

### Focus, wellness, and personal state

| Widget | Current value and source | Size assessment | Configuration and design strategy |
|---|---|---|---|
| Focus Timer | Persistent Pomodoro phases, presets, daily goal, sessions, points, nudges, and break suggestions. | `1x1` and `1x1.5` correctly protect the ring and controls. | P0: Calm behavior profile with celebration, points, and nudges off. P1: long-break cadence, separate auto-start rules, gentle system notification, and optional history. Fully stop flash/scale under reduced motion. |
| Tasks | Local checklist with add, complete, remove, hide completed, clear, and celebration. | List content earns `0.5x1` through `1x3`; full-screen needs a graceful sparse state. | P1: stable task IDs, reorder/edit, Top 3 mode, sections, optional due time, import/export, and a non-celebratory preset. Separate content deletion from settings reset. |
| Right Now | One locally persisted focus statement, Done action, and daily completion count. | Compact sizes are strong; `1x1.5` is mostly hero scale. | P1: cap at `1x1` now. Restore the larger size only with started-at/elapsed context, replace/clear shortcut, task link, and calm completion. |
| Quick Note | Local scratchpad with debounced autosave, tile preview, and expanded editor. | More space earns more text, so all seven sizes can be justified. | P1: visible saved/saving/error state, undo/history, copy/export, search, clear confirmation, and optional lightweight Markdown. |
| Habit Streak | Local daily check-ins, current/best streak, and 28-day heatmap. | One of the best size-specific designs through `1x1.5`. | P1: selected weekdays or N-times-per-week cadence, pause/vacation days, optional no-streak mode, reminder, and duplicate-instance clarity. Never include it silently in a shame-free preset. |
| Hydration | Local daily count, goal, volume, streak, and one-tap adjustment. | Micro through `1x1` is the correct range. | P1: ml/oz, variable serving sizes, reminder schedule, clearer undo, optional history, and celebration/streak switches. |
| Break Reminder | Persistent interval, pause/reset, due state, suggestions, and daily count. | Micro through `1x1` is appropriate. | P0: work-hours schedule, snooze, notification while other pages are visible, and a reduced-motion-safe due state. P1: quiet hours and custom suggestions. |
| Meds | Parsed daily schedule with due, taken, and neutral states; local tap record and explicit safety copy. | `0.5x1` through `1x2` earns additional schedule rows. | P0 product-safety and privacy sign-off: structured validation, duplicate identity, timezone/DST/midnight/restart tests, export/backup, undo, and safety wording on onboarding and the active surface. Disclose sensitive local plaintext. Never claim adherence, reliability, dosage, emergency, or clinical outcomes. |
| Braindump | Timestamped local capture queue, newest first, bounded to 100 entries. | Wide split and taller list modes use `0.5x1` through `1x2` well. | P1: edit, copy/export, archive, send-to-task, keyboard focus clarity, and confirmation before Clear All. Promote it into Calm Focus. |
| Routine | Local daily checklist that deliberately has no history, score, or streak. | List sizes through `1x2` are appropriate and persona-aligned. | P0: stable step IDs because duplicate text currently shares identity and renamed text changes identity. P1: reorder and weekday-specific routines without streak pressure. Use it in Health. |

### Media, connected data, and information

| Widget | Current value and source | Size assessment | Configuration and design strategy |
|---|---|---|---|
| Now Playing | MPRIS metadata, album art, progress, and transport controls from the local machine. | Micro correctly retains one full-sized play action; richer sizes earn art and transport. | P1: capability-aware disabled controls, player selector, seek, volume, shuffle/repeat, output device, and clearer disconnected/paused states. Media currently has no functional config. |
| HTTP / JSON | NetHub-gated polling, JSON path extraction, value/gauge/list modes, thresholds, and bearer-token references. | List mode earns `1x2`; a value or gauge does not. | P0: make `1x2` available only in list mode. Add Test Connection, real last-success timestamp, stale state, conditional fields, masked secrets, host/cadence disclosure, and decimal formatting. P1: reusable profiles and structured list columns. |
| KPI | HTTP or local-file headline value with thresholds, trend, and large min/average/max treatment. | Full-screen billboard use is justified. | P0: Test Connection, stale age, validated source-specific fields, number/currency/precision formatting, prefix/suffix, target and delta. Require explicit local-file disclosure. |
| Calendar | NetHub-fetched ICS agenda with daily/weekly recurrence, EXDATE, and partial timezone handling. | `0.5x1` through `1x2` uses row capacity and columns well. | P0: shared protected calendar source, last refresh/stale state, recurrence correctness, timezone tests, credential references, and unsupported-rule feedback. P1: multiple calendars/colors and filters. |
| Now / Next | Derives current and next event through Calendar behavior and the same ICS setting. | Two-block wide/stacked layouts are useful; `1x1.5` mostly adds legibility. | P1: cap at `1x1` now. Restore the larger size with shared calendar cache/source, stale status, meeting Join, location, and buffer/travel context. |
| Weather | Open-Meteo current and daily forecast through NetHub plus geocoding. | Strong adaptation through `1x1.5`; daily items fill additional room. | P0: setup-required location instead of Berlin, shared location profile, last-updated/stale state. P1: precipitation, wind, humidity, sunrise/sunset. Hourly data is a separate egress/data feature. |
| Countdown | Local date countdown, yearly repeat, and progress. | Compact hero is strong; `1x1.5` lacks enough context. | P1: cap at `1x1` now. Restore the larger size after adding time of day, timezone, units, milestones, post-event action, and notification. |
| End of Day | Local work-window progress, remaining time, overnight calculation, bar/ring, and details. | Tall and wide variants add useful detail. | P0: resolve the contradiction where overnight math exists but validation and direct controls reject overnight schedules. P1: minute precision, weekdays, split shifts, breaks, holidays, and profiles. |
| Daily Quote | Bundled/category/custom local quote selection with daily rotation and Shuffle. | Aesthetic compact card; `1x1.5` adds little beyond larger type. | P0: cap at `1x1` and replace the bundled corpus with entries that have per-entry source, attribution, and cleared rights. Remove unverifiable entries. Custom-import UI states that users are responsible for content rights. |

## 5. Preset-screen audit

All 19 presets are structurally valid, fit one screen, preserve the global theme, and use supported widget sizes. Product fit and onboarding are uneven.

| Preset | Current assessment | Planned improvement |
|---|---|---|
| Calm Focus | Strong core, but default points/celebration conflict with calm positioning and README promises Braindump. | Use `1x1` Focus, Right Now, and Braindump. Seed Focus with points, celebration, and nudges off. |
| Notes & Streak | Coherent for users who explicitly want streaks. | Keep, but state streak intent during selection. |
| Home | Clock and Weather are useful after setup; README also promises Media. | Keep the two-widget composition, add location onboarding, and correct README to Clock plus Weather. |
| Ambient | Media and Moon are coherent but often sparse; README promises clock/weather instead. | Add an Analog Clock in the remaining half-width slot and rewrite copy to Media, Moon, and Clock. |
| Minimalist | Intentional whitespace is valid. | Keep after removing the silent Weather location default. |
| Health & Routine | Contains Hydration, Break, and Habit, not Routine. It also layers multiple momentum signals. | Replace Habit with Routine and seed celebration/streak features off. Keep the current name. |
| Creator / Media | Media plus Focus is generic rather than creator-specific. | Use `1x1` Media, Focus, and Braindump now. Market it as a focus/media workspace until OBS, render, and audio features exist. |
| Student / Study | Focus plus unset Exam countdown makes half the screen require setup. | Use `1x1` Focus, Tasks, and Countdown with a clear exam setup action. |
| Productivity | Strong general-purpose baseline. | Keep and offer Calm and Momentum variants. |
| Remote Work | Tasks plus End of Day misses meetings and calendar promised in README. | Use `1x1` Tasks, End of Day, and Now/Next with shared calendar setup. |
| Gaming Cockpit | GPU, CPU, and RAM are hardware monitoring, not full gaming telemetry. | Use GPU `1x1.5`, CPU `1x0.5`, RAM `0.5x1`, and Network `0.5x1`. Market it as rig telemetry until FPS/frame-time support exists. |
| System Core | Clear and useful, but GPU may be unavailable. | Use Sensors, CPU, and RAM so unsupported GPU becomes one hidden row instead of a dead card. |
| System I/O | Network and Disk are useful, but Sensors duplicates several metrics. | Rename to System Details and use Network `1x1.5`, Disk `1x1`, Packages `0.5x0.5`, and System Age `0.5x0.5`. Replace the latter facts with Storage I/O and Updates when available. |
| Day Plan | Coherent after calendar setup, but starts mostly empty. | Add guided connection and reusable calendar source. |
| Developer | Two labelled but empty generic data slots; README promises machine health too. | Use `1x1` HTTP/JSON, KPI, and CPU. Add guided forge recipes now and a dedicated CI widget later. |
| Homelab Ops | Two empty HTTP lists do not yet deliver container/service monitoring. | Use `1x1` Uptime HTTP/JSON, Containers HTTP/JSON, and Sensors. Add local Systemd and Podman/Docker widgets later. |
| Trading Desk | Two clocks and one empty KPI do not form a trading desk. | Use two half-width clocks, `1x1` KPI, and `1x1` Now/Next. Label it a customizable desk until licensed market data exists. |
| Analyst / Data | Three empty data primitives and no chart/table. | Use `1x1` KPI, HTTP/JSON, and Clock so one local element always works. Add chart/table before marketing an analyst cockpit. |
| Team / Enterprise | End of Day plus one empty KPI is not sufficient enterprise value. | Use `1x1` Clock, End of Day, and approved KPI. Rename marketing to Team Baseline until managed calendar/admin workflows exist. |

Preset actions:

- Mark presets as `Ready now` or `Connect data first`.
- Add setup completion and clear connection calls to action.
- Add per-preset behavioral settings, not just appearance and sizes.
- Test each named preset with at least three representative users before calling it optimized.
- Extend persona documentation to finance/trading, homelab, analyst, student, creator, and enterprise roles.
- Reconcile README and release copy with PresetCatalog in the same implementation change.
- Generate the published preset table from PresetCatalog and test the generated output in documentation CI.
- Use `EdgeHub` as product copy and keep hardware compatibility language separate. Do not imply that the Team / Enterprise preset is itself locked or managed.
- Qualify display, keyboard-free setup, and automatic-targeting claims to the hardware and environments actually validated.
- Lead future demos with local-first proof: first-party request ledger before and after explicit connection, per-host diagnostics, offline kill switch, Manager live editing, rotation, reconnect, and persistence.
- Describe network proof narrowly as tested first-party gated requests in the published build/configuration. NetHub is not a host firewall, user-widget sandbox, or machine-wide traffic monitor.

Persona research priorities:

- Nontechnical first-run, reconnect, and failed-source recovery: at least 90% completion within 10 minutes, no critical loss or secret exposure, confidence at least 5/7.
- Developer and homelab connection/setup: at least 80% completion within 5 minutes; identify a failing build/service within 30 seconds after setup.
- Gamer and analyst glance tasks: at least 90% correctly understand the displayed scope/source/delay; identify an anomaly within 10 seconds.
- Student, remote-work, creator, and wellness workflows: at least 85% complete the primary task without assistance; calm preset users must not interpret missed activity as failure or shame.
- Recruit across portrait/landscape, X11/Wayland, AMD/NVIDIA/Intel, accessibility needs, and low/moderate/high technical proficiency. Record task completion, time, assistance, errors, accidental actions, freshness comprehension, and confidence.

## 6. Immersive Hub controls specification

### User story

As an EdgeHub owner, I can choose Standard or Immersive Hub controls from Manager so the physical display can devote all persistent space to widgets while widget-specific controls and configuration remain available on the Hub.

### Data model

Use a versionable appearance value:

```json
{ "hubControlsMode": "standard" }
```

Allowed values are `standard` and `immersive`. Missing or invalid values normalize to `standard`. Presets must never overwrite the setting.

### Behavior

- Standard preserves the current page name, page indicator, Edit, Add, Appearance, and Diagnostics bar.
- Immersive removes the entire bottom row from layout and reclaims its height in both orientations.
- Page swipe remains available. A noninteractive page-name and current/total overlay appears during a swipe and for 1.2 seconds after the page settles. Reduced motion removes its transition but not the information.
- The top-right per-widget expand/config target remains available.
- Expanded widget preview, widget-specific settings, back, and Done remain available.
- Hub edit, add/remove screen, global appearance, and diagnostics entry points are unavailable.
- Enabling Immersive exits Hub edit mode and closes global settings/pickers before the bar is removed. It does not close an open per-widget overlay.
- Empty-page text directs the user to Manager instead of saying `Tap Edit`.
- Managed-device disclosure remains visible in a minimal noninteractive location when policy requires it.
- Manager remains able to change the setting live or offline and shows the exact geometry in EdgeClone.
- Recovery is documented through Manager and supported reset tooling. No hidden gesture is added in the first version.

### Manager UX

- Place a two-option `Hub controls` setting in the Manager Device section with scope `Whole Edge`.
- Copy: `Immersive hides dashboard editing and global settings on the Hub. Widget controls and widget settings remain available. Use Manager to restore Standard controls.`
- Show the effect immediately in the preview.
- When connected, push live. When offline, persist and reconcile on reconnect.
- Display a save/push error if the Hub rejects the update instead of claiming success after queueing.

### Acceptance tests

1. Existing config and invalid values render Standard.
2. Manager switch, offline save, live IPC push, reconnect, restart, and single-writer reconciliation preserve the value.
3. Immersive produces zero bottom-bar opacity, zero hit regions, and zero layout reservation.
4. Widgets reclaim space without semantic reorder or clipping in portrait and landscape.
5. Swipe works with one and multiple pages.
6. Every widget can still open and close its Hub configuration.
7. Inline widget actions remain functional.
8. Entering Immersive from edit mode exits edit mode safely.
9. Empty page, managed policy, reduced motion, fractional scaling, text scaling, touch, keyboard, and screen reader paths are covered.
10. EdgeClone and Hub have matching standard and immersive geometry.

## 7. New-widget backlog

### P0: make named personas truthful

| Widget or integration | Primary users | Key scope or dependency |
|---|---|---|
| FPS and Frame Time | Gamers | External telemetry path that does not inject into games; anti-cheat-safe positioning. |
| Latency and Packet Loss | Gamers, remote workers, homelab | Interface/target selection and bounded probing. |
| Systemd Service Health | Homelab, developers | Local zero-config service state and failure details. |
| Container Health | Homelab, developers | Podman first, Docker second; socket permissions and clear trust boundary. |
| CI/CD Status | Developers | GitHub/GitLab/forge profiles, secure credentials, pipeline/job model. |
| Git Forge Work | Developers | Pull requests, issues, reviews, and notifications with rate-limit state. |
| Time-Series Chart | Analysts, finance, homelab | HTTP/JSON, Prometheus, or file profiles; axes, units, stale state. |
| Data Table | Analysts, homelab, enterprise | Column mapping, sorting, status formatting, row limits. |
| Market Watch and Session | Traders | Data provider, licensing, delayed-data disclosure, market hours, financial disclaimer. |
| Shared Calendar Source | Remote workers, students, enterprise | Secret references, cache, timezone, recurrence, multi-calendar selection. |
| Shared Location | Home and Weather users | Consent, manual setup, reusable coordinates, no silent default. |

### P1: workflow depth

- Process Top with CPU and memory consumers.
- Storage I/O, mounts, and SMART health.
- System updates and security status.
- Battery, UPS, and power profile.
- OBS/recording/stream status with dropped frames.
- Audio meter, mixer, mute, and output device.
- Meeting countdown and Join action.
- Student timetable and assignment planner.
- Stopwatch and configurable interval timer.
- Home Assistant state and safe controls with confirmation for destructive actions.

### P2: ecosystem and convenience

- Multi-time-zone strip.
- RSS/feed reader.
- Clipboard/snippet card with privacy controls.
- Notification summary with strict privacy and source controls.
- Application launcher only after command-execution security design.
- Community widget gallery only after sandboxing, permissions, compatibility versioning, and failure isolation.

Finance work does not enter implementation until a provider contract confirms display/redistribution rights, attribution, caching, geography, and real-time or delayed entitlements. Every value shows provider, timestamp, delay/stale state, currency/exchange, and market-hours context. The product is informational only and does not execute trades or provide personalized advice, recommendations, guarantees, or professional-market-data claims.

Meds, managed mode, network/offline, and local-storage copy use explicit boundaries: a medication tap means `marked by the user`, managed mode is application policy rather than monitoring/compliance/tamper resistance, NetHub is not a host firewall, and local does not mean encrypted or excluded from OS access and backups.

## 8. Implementation sequence

### Phase 0A: loss safety and product truth

- Use the frozen requirement IDs above in commits, tests, and review reports.
- Fix README versus preset drift, page-delete confirmation, and separate config reset from personal-data erase.

### Phase 0B: widget host and lifecycle

- Add WidgetHost and one-active-driver election without changing widget features.
- Add lifecycle and Hub/Manager parity tests.

### Phase 0C: provider state contract

- Add the canonical state envelope, timestamps, stale transitions, cancellation, and shared state presentation.

### Phase 0D: transactional and secure configuration

- Add draft Apply/Cancel, conditions, validation, type-qualified schema tests, `__version` migration, CredentialStore, redaction, and same-authority Test Connection.

### Phase 0E: accessibility foundation

- Add semantics, keyboard/focus, hard 48-pixel targets, actual reduced-motion behavior, live announcements, text-scale behavior, and contrast/state tests.

### Phase 0F: catalog-driven render evidence

- Replace hardcoded 22-widget inventories and add derived size/orientation, state, config-effect, touch, preset, and Hub/Manager render matrices.

### Phase 1: Immersive controls

- Implement the data model, Hub behavior, Manager control, EdgeClone parity, managed disclosure, recovery copy, migration, and focused tests.

### Phase 2: existing-widget P0 fixes

- Weather onboarding, End of Day overnight behavior, network freshness, Calendar secrets/recurrence, calm Focus defaults, Routine identity, GPU vendor capability, and Break notifications.

### Phase 3: preset completion

- Improve Health, Remote Work, Gaming, Developer, Homelab, Trading, Analyst, Enterprise, Creator, and Study using existing widgets first.
- Mark connection requirements and validate persona tasks.

### Phase 4: high-value new widgets

- Local service/container health, gaming quality, developer forge status, chart/table, calendar/location sources, and finance widgets after provider/legal decisions.

## 9. Verification plan

- Generate a catalog-driven matrix for all 149 `(widget, declared size)` combinations and both orientations, with an exact 298-case anti-vacuity assertion before adding state variants.
- Render and inspect unconfigured, loading, fresh, stale, blocked, error, empty, extreme, and long-text data.
- Assert no clipping, useful density change, stable semantic order, and touch hit areas of at least 48 logical pixels.
- Test touch-only use with no hover dependency, keyboard navigation, focus visibility, accessible roles/names/actions, and screen-reader announcements.
- Verify effective reduced motion, not only the persisted preference, disables nonessential scale, flashing, wobble, and background motion.
- Compare Hub and EdgeClone structure and geometry from the same state.
- Use deterministic fake clock, metrics, distro, MPRIS, and XHR providers.
- Assert request cadence, cancellation, stale transitions, history caps, config write count, and one active driver.
- Test every config field changes the corresponding rendered behavior, including conditional and invalid states.
- Test every preset as a persona task, not only as valid JSON and grid capacity.
- Run focused real-display validation in portrait and landscape after automated gates pass.

## 10. Approval gate

Implementation must not begin until the owner approves this plan. Approval authorizes the phased backlog, but each phase is delivered and reviewed independently. The recommended first slice is Phase 0A only: requirement IDs, README/preset truth, Hub page-delete confirmation, and separation of configuration reset from personal-data erase. Phase 0B follows after that review; Immersive controls do not begin until Phases 0B through 0F supply the lifecycle, state, config, accessibility, and evidence contracts it depends on.

## 11. Sequential implementation record

Owner approval was received on 2026-07-22 with the additional rule that only one widget may be changed at a time. A widget is complete only after its focused test passes. This rule supersedes the earlier recommendation to begin with Phase 0A.

| Order | Widget | Status | Delivered | Completion gate |
|---:|---|---|---|---|
| 1 | CPU | Complete | Truthful warming/unavailable/fresh states; thermal warnings independent of label visibility; zero and sub-zero temperature support; automatic, package, and hottest sensor selection; 1/5/15-minute load averages; average frequency; named 1/2/5-minute history; busiest process; eight busiest logical cores; matching Hub and Manager configuration. | `tst_gen_cpu.qml`: 51 passed, 0 failed in 651 ms; release build passed. |
| 2 | GPU | Complete | Live DRM catalog for AMD, Intel, NVIDIA and unknown vendors; automatic or numbered multi-GPU selection; per-tick rediscovery for hot-plug and driver reload recovery; explicit utilization capability reasons; zero and sub-zero temperature support; device name, vendor, driver, device class, VRAM, power, clock and fan details when exposed; matching Hub and Manager configuration. | `tst_gen_gpu.qml`: 70 passed, 0 failed in 972 ms; focused Rust catalog and real-collector tests passed; release build passed. |
| 3 | Memory | Complete | Truthful available, unavailable and freshness states; available memory, effective cache, buffers, swap usage and Linux PSI pressure; binary values labelled as GiB; min, average and peak history; responsive expanded details; matching Hub and Manager configuration. | `tst_gen_ram.qml`: 49 passed, 0 failed in 135 ms; focused Rust meminfo, pressure and JSON-contract tests passed; formatting and strict Clippy passed; release build passed. |
| 4 | Network | Complete | Truthful warming, ready, unavailable and freshness states; live per-interface catalog with physical, VPN, bridge, container, virtual and local classification; aggregate or named-interface selection; explicit virtual-link inclusion controls; link state and speed; transfer totals, drop and error counters; automatic or fixed graph scale; resettable shared session history and peaks; 48-pixel touch target and keyboard reset; matching Hub and Manager configuration. Active latency probes and claimed packet-loss percentages remain excluded until they have an explicit target, outbound-network and privacy contract. | `tst_gen_net.qml`: 34 passed, 0 failed in 72 ms; focused Rust catalog, hot-plug, JSON-contract and real-collector tests passed; formatting and strict Clippy passed; release build passed. |
| 5 | Disk | Complete | Real statvfs Used, Available, Total and root-reserved byte counters; df-compatible percentage kept distinct from raw capacity accounting; explicit availability, failure reason and freshness; binary unit labels; warning thresholds; responsive retained layouts; under-filled `1x1.5` size removed until multi-volume or storage-I/O content exists. | `tst_gen_disk.qml`: 31 passed, 0 failed in 14 ms; focused Rust statvfs, JSON-contract and real-root collector tests passed; formatting and strict Clippy passed; release build passed. |
| 6 | Sensors | Complete | Enabled rows remain visible with explicit N/A and source-specific reasons; live, partial, unavailable and disabled states; configurable row order and per-row warning thresholds; capability-aware GPU power and fan rows; expanded source labels; stable delegates across metric and hot-plug updates; reduced-motion-safe transitions; unreadable micro size removed while wide, tall and large layouts remain responsive. | `tst_gen_sensors.qml`: 32 passed, 0 failed in 1624 ms; formatting and strict Clippy passed; release build passed. |
| 7 | Packages | Complete | Truthful loading, counted-zero and unsupported-family states; distro identity toggle; grouped count; expanded pacman, dpkg or unsupported RPM source disclosure; read-only behavior retained; under-filled `1x1.5` size removed. Safe RPM support remains dependent on a library/API and never shells out. | `tst_packages.qml`: 12 passed, 0 failed in 4 ms; formatting and strict Clippy passed; release build passed. |
| 8 | System Age | Complete | Installer-record versus package-log-estimate provenance from the Rust probe; estimate wording on the active surface; expanded source and rotated-log caveat; loading, unknown, future-clock and exact date states preserved; automatic/days units; under-filled `1x1.5` size removed. | `tst_sinceinstall.qml`: 15 passed, 0 failed in 6 ms; focused Rust Arch, Debian and JSON provenance tests passed; formatting and strict Clippy passed; release build passed. |
| 9 | Clock | Complete | Full OS tzdata IANA selector; DST-correct named zones; explicit fixed-offset DST warning; system or requested locale; short, full, ISO and custom date patterns; up to three additional zones in tall and expanded layouts; existing responsive density, date visibility and legacy offset compatibility preserved. Sunrise and sunset remain owned by shared-location work so Clock does not independently request location data. | `tst_gen_clock.qml`: 56 passed, 0 failed in 482 ms; `timezone_bridge`: 19 passed, 0 failed in 2 ms; formatting and strict Clippy passed; release build passed. |
| 10 | Analog Clock | Complete | Named IANA and legacy fixed-offset world-clock parity; clear zone label; classic and minimal faces; rounded and slender hands; responsive date and digital context preserved; inactive repaint discipline retained; the second hand is suppressed by effective Reduce Motion. | `tst_gen_analog.qml`: 31 passed, 0 failed in 2072 ms; formatting and strict Clippy passed; release build passed. |
| 11 | Moon Phase | Complete | Approximate geocentric calculation and waxing/waning direction disclosed in roomy views; optional calculation note; invalid hemisphere data safely normalizes to north; local UTC-based phase, illumination, age and next-date calculations preserved; size range remains capped at `1x1`. Observer-specific moonrise/moonset remains assigned to the future shared-location service. | `tst_gen_moon.qml`: 52 passed, 0 failed in 56 ms; formatting and strict Clippy passed; release build passed. |
| 12 | Focus Timer | Complete | Calm, Momentum and Custom behavior profiles; Calm suppresses points, nudges and celebration; separate custom short and long breaks plus cadence; independent auto-start rules for breaks and focus; existing custom presets retain their former shared break length until changed; effective Reduce Motion removes color flash and scale motion. | Focus slice: 8 selected checks passed, 0 failed in 11 ms, including the previously crashing preset-switch case in isolation; formatting and strict Clippy passed; release build passed. The oversized legacy file hit a Qt 6.11 JavaScript-engine crash after the relevant assertions, so it was not rerun as a bulk gate. |
| 13 | Tasks | Complete | Stable IDs on new tasks; external IDs preserved; expanded inline editing and touch reordering; All and Top 3 views; Calm, Celebrate and Custom completion styles; two-step confirmation for clearing completed tasks; malformed item fields normalized for safe rendering; effective Reduce Motion applied to completion effects. | Tasks slice: 8 selected checks passed, 0 failed in 19 ms with zero runtime diagnostics; formatting and strict Clippy passed; release build passed. |
| 14 | Right Now | Complete | New and replaced focus statements record a start time; larger tiles earn live elapsed-focus context; explicit Clear does not count completion; Calm completion counts without celebration; celebration remains available and is effective-Reduce-Motion safe; daily count and shared Hub/Manager editing preserved. The existing `1x1.5` size is now justified by elapsed context. | Right Now slice: 12 passed, 0 failed in 15 ms with zero runtime diagnostics; formatting and strict Clippy passed; release build passed. |
| 15 | Quick Note | Complete | Visible Saving, Saved and Save failed states; debounced and destruction-time flush retained; ten-step local text recovery with Undo; confirmation before clearing; no-op edits still avoid config churn; existing responsive preview and large editor density preserved. | Quick Note slice: 11 passed, 0 failed in 473 ms with zero runtime diagnostics; formatting and strict Clippy passed; release build passed. |
| 16 | Habit Streak | Complete | Daily, weekday, weekend and explicit weekday schedules; schedule-aware consecutive streak math; unscheduled rest days do not break or accept check-ins; pause without deleting history; optional streak-free presentation; optional celebration; effective Reduce Motion for feedback; existing 28-day bounded heatmap and `1x1.5` density preserved. | Habit slice: 8 passed, 0 failed in 22 ms with zero runtime diagnostics; formatting and strict Clippy passed; release build passed. |
| 17 | Hydration | Complete | Configurable serving size retained; ml/L or fluid-ounce totals; explicit one-step Undo using the persisted previous count; optional goal streak and celebration; effective Reduce Motion for goal feedback; daily reset, goal-credit and bounded count behavior preserved; active copy clarifies this is not medical advice. | Hydration slice: 12 passed, 0 failed in 33 ms with zero runtime diagnostics; formatting and strict Clippy passed; release build passed. |
| 18 | Break Reminder | Complete | Configurable active weekdays and hours; daytime and overnight schedules; snooze without counting a completed break; persistent pause, reset and daily acknowledgment semantics retained; reduced-motion due feedback no longer flashes; due actions remain touch accessible. System notifications remain assigned to future shared lifecycle infrastructure rather than an unsafe per-widget background driver. | Break Reminder slice: 10 passed, 0 failed in 19 ms with zero runtime diagnostics; formatting and strict Clippy passed; release build passed. |
| 19 | Meds | Complete | Invalid or untimed lines stay visible and are counted for review; repeated identical lines have independent persisted identity; due-window values are bounded; marks remain explicitly reversible; the active surface explains that a mark records only a tap and cannot confirm intake; settings disclose sensitive local plaintext and backup exposure; neutral non-clinical wording remains enforced. | Meds slice: 12 passed, 0 failed in 60 ms with zero runtime diagnostics; formatting and strict Clippy passed; release build passed. |
| 20 | Braindump | Complete | Captures receive stable IDs and bounded text; expanded mode supports inline editing and per-entry removal; edits and removals retain timestamps; destructive Clear All requires a second confirmation within five seconds; the latest edit, removal or clear can be undone; existing newest-first order, 100-entry bound, persistence and responsive capture path remain intact. | Braindump slice: 12 passed, 0 failed in 20 ms with zero runtime diagnostics; formatting and strict Clippy passed; release build passed. |
| 21 | Routine | Complete | Repeated step labels now receive independent daily identity; weekday schedules define calm rest days without adding history or pressure; inactive days cannot accidentally record completion; existing daily rollover, reversible ticks, neutral copy, responsive summary and touch-sized rows remain intact. | Routine slice: 18 passed, 0 failed across focused behavior and real-input gates in 162 ms with zero runtime diagnostics; formatting and strict Clippy passed; release build passed. |
| 22 | Now Playing | Complete | Session bus, discovery, no-player and no-track states are distinct; transport is semantic, keyboard accessible and capability aware; real elapsed and duration data drive a large seek surface; preferred MPRIS identity is configurable; remote artwork remains blocked and the policy is disclosed; title and supporting text have stronger legibility across responsive compositions. | Media slice: 64 focused QML checks passed; focused hermetic `mpris_state` QtTest passed; compositor-backed Media/HTTP/KPI suite passed 141 checks; release Hub and Manager build passed. |
| 23 | HTTP / JSON | Complete | Test Connection follows the shared policy path and previews a bounded parsed value without replacing live data; failures include corrective guidance; list mode hides irrelevant numeric configuration; refresh is semantic and keyboard accessible; thresholds have text semantics as well as color; freshness, responsive modes, bounded parsing, secret handling and shared ephemeral results remain intact. | HTTP/JSON focused gate: 14 passed; shared configuration action gate: 3 passed; Manager dialog gate: 3 passed; compositor-backed Media/HTTP/KPI suite: 141 passed; release Hub and Manager build passed. |
| 24 | KPI | Complete | Local files pass a native canonical-root, no-final-symlink, regular-file and 1 MiB boundary; Test Source previews parsed formatting and threshold state in local and remote modes; invalid threshold ordering is explained; state uses text plus color; rejection and setup copy is actionable; responsive billboard, freshness, shared history, secret handling and target context remain intact. | KPI QML suite: 32 passed; hermetic ConfigBridge QtTest passed including local-file attack cases; compositor-backed Media/HTTP/KPI suite: 141 passed; release Hub and Manager build passed. |
| 25 | Calendar | Complete | The subscription URL is masked in both shared configuration and the active expanded editor with explicit plaintext-storage disclosure; Save & Test gives a direct validation path; last-success age, stale, loading, error and partial states are distinct; failed refreshes retain the last agenda; destination host and cadence are disclosed; unsupported timezones, recurrence parts and frequencies are surfaced instead of silently treated as complete support. Existing recurrence, EXDATE, egress and responsive agenda behavior remain intact. | Calendar slice: 12 passed, 0 failed in 13 ms with zero runtime diagnostics; formatting and strict Clippy passed; release build passed. |
| 26 | Now / Next | Complete | Oversized `1x1.5` is removed; the private subscription editor is masked and Save & Test is explicit; Calendar freshness, stale, error and partial-parser states are surfaced; a configurable meeting buffer adds calm Starts soon context; HTTPS meeting links from ICS URL or location data expose a Join action; deterministic clock seams and existing gated recurrence-aware derivation remain intact. A shared agenda cache remains cross-widget infrastructure rather than duplicated inside this slice. | Now / Next slice: 14 passed, 0 failed in 15 ms with zero runtime diagnostics; formatting and strict Clippy passed; release build passed. |
| 27 | Weather | Complete | Berlin is no longer silently queried or shown; location setup is required before egress; invalid or absent coordinates do not open a request; last-success age and stale/error state are explicit while failed refreshes preserve the last useful reading; expanded detail adds humidity, wind, precipitation, sunrise and sunset when supplied; Open-Meteo destination and 30-minute cadence are disclosed; existing unit safety, geocoding, responsive forecast and egress controls remain intact. A shared location profile remains cross-widget infrastructure. | Weather slice: 23 focused checks passed, 0 failed across network, setup, stale-state and request-shape gates in 65 ms with zero runtime diagnostics; formatting and strict Clippy passed; release build passed. |
| 28 | Countdown | Complete | Oversized `1x1.5` is removed; impossible dates and times are rejected; a device-local time can be configured; Auto precision switches to hours inside 48 hours; one-month, one-week and tomorrow milestones add useful context; completed one-time events can use neutral Complete rather than Passed; yearly recurrence and honest progress baselines remain intact. System notifications and named timezone conversion remain shared lifecycle/time infrastructure. | Countdown slice: 9 passed, 0 failed in 17 ms with zero runtime diagnostics; formatting and strict Clippy passed; release build passed. |
| 29 | End of Day | Complete | Quarter-hour start and end precision is supported; active weekdays can produce an explicit Off today state; an explicit Allow overnight option lets direct controls create supported cross-midnight windows up to 12 hours; existing deterministic overnight selection, DST-safe calendar endpoints, percent visibility, bar/ring modes and responsive detail remain intact. Split shifts, breaks, holidays and shared notification lifecycle remain future profile infrastructure. | End of Day slice: 15 passed, 0 failed across behavior and schema gates in 197 ms with zero runtime diagnostics; formatting and strict Clippy passed; release build passed. |
| 30 | Daily Quote | Complete | The oversized `1x1.5` option is removed; every bundled entry is project-authored copy with explicit source, attribution and rights status; unverifiable third-party and unknown-attribution entries are removed; expanded mode displays provenance; custom entries are marked as user supplied and both the active widget and settings state the user's content-rights responsibility; local daily rotation, stable shuffle identity and responsive layouts remain intact. | Daily Quote slice: 52 passed, 0 failed in 93 ms with zero fatal runtime diagnostics; formatting and strict Clippy passed; release build passed. |

No GPU work began before the CPU completion gate passed. No Memory or later-widget work began before the GPU completion gate passed. No Network or later-widget work began before the Memory completion gate passed. No Disk or later-widget work began before the Network completion gate passed. No Sensors or later-widget work began before the Disk completion gate passed. No Packages or later-widget work began before the Sensors completion gate passed. No System Age or later-widget work began before the Packages completion gate passed. No Clock or later-widget work began before the System Age completion gate passed. No Analog Clock or later-widget work began before the Clock completion gate passed. No Moon Phase or later-widget work began before the Analog Clock completion gate passed. No Focus Timer or later-widget work began before the Moon Phase completion gate passed. No Tasks or later-widget work began before the Focus Timer completion gate passed. No Right Now or later-widget work began before the Tasks completion gate passed. No Quick Note or later-widget work began before the Right Now completion gate passed. No Habit Streak or later-widget work began before the Quick Note completion gate passed. No Hydration or later-widget work began before the Habit Streak completion gate passed. No Break Reminder or later-widget work began before the Hydration completion gate passed. No Meds or later-widget work began before the Break Reminder completion gate passed. No Braindump or later-widget work began before the Meds completion gate passed. No Routine or later-widget work began before the Braindump completion gate passed. No Media or later-widget work began before the Routine completion gate passed. No HTTP/JSON or later-widget work began before the Media completion gate passed. No KPI or later-widget work began before the HTTP/JSON completion gate passed. No Calendar or later-widget work began before the KPI completion gate passed. No Now / Next or later-widget work began before the Calendar completion gate passed. No Weather or later-widget work began before the Now / Next completion gate passed. No Countdown or later-widget work began before the Weather completion gate passed. No End of Day or later-widget work began before the Countdown completion gate passed. No Daily Quote work began before the End of Day completion gate passed. All 30 listed widgets completed their focused gate in order.

### Phase 0A implementation record

- LOSS-001: deleting a Hub screen now requires a named confirmation that shows
  its widget count, refuses stale confirmations after the layout changes, and
  continues to protect the final screen.
- LOSS-001: Reset configuration and Erase personal data are separate Hub and
  Manager actions. Reset preserves catalog-classified personal content. Erase
  names its exact scope and preserves configuration and appearance.
- DOC-001: the README now describes the exact 19 preset compositions and the
  current cross-vendor DRM GPU capability. A focused preset contract pins every
  preset's ordered widget and size signature.
- Phase 0A focused gates: Dashboard page deletion 6 passed; Dashboard widget
  data actions 5 passed; DashboardStore data separation 5 passed; WidgetCatalog
  classification 3 passed; Manager separation 3 passed; existing Hub reset path
  3 passed; preset catalog 16 passed. All reported 0 failures and 0 fatal QML
  diagnostics. Rust formatting and strict Clippy passed, followed by the Release
  build.

### Visible-card refinement and QoL record

- Screen selection is now review-first in Hub Settings, Manager, and the first-run
  wizard. A shared passive preview shows the exact first-screen placement, intended
  job, included widgets, and setup requirements without loading live widget drivers
  or making network requests. Adding or choosing remains a separate explicit action.
- Focus Timer `1x1.5` adds a Now, Next, and Cycle runway with the planned finish.
- Tasks `1x1.5` adds a designed empty state, three starting prompts, and open,
  completed, and percentage progress when populated.
- Right Now `1x1.5` adds start time, live flow duration, and today's completion count.
- Quick Note roomy cards add word and character context, an edit affordance, and a
  purpose-built capture state when empty.
- Habit Streak roomy cards add 28-day scheduled completion, consistency, and the
  distance to the next milestone.
- Hydration `1x1` adds consumed and remaining volume.
- Break Reminder `1x1` adds interval rhythm, active schedule, and today's breaks.
- Hub controls use the approved versionable appearance contract,
  `hubControlsMode: standard | immersive`. Missing or invalid values normalize to
  Standard. Immersive removes the bottom navigation row, changes empty-screen help
  to direct users to Manager, and preserves the per-widget configuration corner.
  If Manager switches modes during an active Hub edit, the bar remains only until
  Done is tapped so the Hub cannot be trapped in edit mode.
- The mode can be changed from both Hub Appearance and Manager Look. All three
  focused mode gates passed 3/3. Each visible-card refinement passed its own 3/3
  focused gate. Screen preview gates passed for Hub, Manager, wizard, catalog, and
  passive-preview behavior.
- Manager EdgeClone now draws the Standard-mode Hub controls and removes their
  exact footprint in Immersive mode. Its widget grid uses the same remaining panel
  geometry in portrait and landscape, so the preview no longer promises space that
  the running Hub does not have. The focused geometry gate passed 3/3.
- The integrated Release build passed on 2026-07-22.

### Phase 0B implementation record

- HOST-001: Hub tiles, the Hub expanded view, Manager EdgeClone tiles, and the
  Manager widget-config preview now use one shared `WidgetHost` lifecycle and
  appearance-binding contract.
- The visible Hub tile is active only outside edit and expanded modes. Opening
  an expanded widget immediately transfers the driver role to that view; closing
  it deactivates the fading overlay before the tile resumes.
- Manager previews remain visually live from shared state but are passive:
  `active` is always false, widget pointer actions are shielded, and a dedicated
  offline NetHub is injected. HTTP / JSON, KPI, Calendar, and Weather debounce
  callbacks recheck activity before refreshing.
- Focused gates: WidgetHost 5 passed; passive connected hosts 4 passed;
  EdgeClone 17 passed; Dashboard 61 passed; Manager 60 passed; policy loading
  10 passed. All reported zero assertion failures. The Release build passed.

### Phase 0C implementation record, slice 1

- STATE-001 now has a shared `ProviderState` envelope with deterministic
  precedence for unconfigured, loading, fresh, stale, blocked, disconnected,
  error, empty, and unavailable states.
- The envelope centralizes concise badges, provider reasons, and last-success
  age text without owning transport or widget-specific presentation.
- HTTP / JSON, KPI, Calendar, and Weather now use the shared contract. They keep the last
  successful value after refresh failures while their headers distinguish
  Setup, Loading, Stale, Blocked, Offline, Error, and Empty states. HTTP / JSON
  retains its value, gauge, and list layouts; KPI retains HTTP and local-file
  providers plus its readout, trend, and billboard layouts. Calendar keeps its
  recurrence and Partial-parser disclosure, and a successful empty agenda is no
  longer misreported as an error. Weather keeps its retained forecast and now
  distinguishes Offline and Blocked from generic data errors.
- Focused gates: ProviderState 15 passed, HTTP / JSON 40 passed, and KPI 25
  passed. Calendar passed 23 provider/network checks plus 74 parser, boundary,
  and size checks. These cover declared sizes, source modes, network policy,
  freshness, failure recovery, and touch sizing. All reported zero assertion
  failures. Weather passed 25 provider/network checks plus 58 layout, boundary,
  unit, interaction, and size checks. The passive-host network gate passed 4
  checks and Dashboard passed 61 checks after all four migrations. Manager
  passed 60 checks and EdgeClone passed 17 checks using the Manager resource
  bundle and passive preview lifecycle.

### Readability and WYSIWYG refinement record

- The Hub now defaults to Comfortable text at 1.15 scale. A shared minimum text
  token is applied across all 30 widgets, the first-run wizard, Diagnostics,
  Dashboard controls, settings, and screen selection. Larger values still scale
  by widget size while secondary information no longer falls below the shared
  legibility floor.
- Manager chrome now uses one readable typography scale, 52-pixel primary
  controls, larger scope pills, legible thumbnails, and larger clone edit actions.
  Text size and typeface remain separate Hub appearance settings and are rendered
  in the live preview.
- Shared pill and segmented controls now expose keyboard focus, activation, and
  accessibility roles with visible focus rings. Configuration steppers, task-row
  actions, segments, sliders, and image actions meet the 48-pixel interaction
  minimum in both Hub and Manager token sets.
- Hub and Manager previews now include the same final accent wash. Successive
  changes to theme, accent, background style, wallpaper, text scale, and typeface
  retain the complete stored appearance instead of partially reverting it.
- Preset selection renders passive instances of the actual widgets using
  WidgetPacker and the Hub's logical 2560 by 720 or 720 by 2560 geometry. The
  preview no longer uses placeholder blocks and tests assert bounded,
  non-overlapping placement in both orientations.
- Focused gates passed for all modified widget families, shared controls, theme,
  Manager, EdgeClone, preset previews, wizard, Diagnostics, Dashboard, and touch
  targets. Rust formatting and strict Clippy passed, the integrated Release build
  completed, and both built-binary smoke tests passed on 2026-07-22.
