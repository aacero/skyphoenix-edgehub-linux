# Full Product Audit

> Integrity correction: this audit ran on a dirty tree. Its results are
> observations only and are not attributable to a clean commit. The
> authoritative integrity report, code-derived corrections, remediation order,
> and two-tier Definition of Done are in
> [Audit Correction and Remediation Plan](audit-correction-and-remediation-2026-07-24.md).

Date: 2026-07-24
Candidate commit: `2526cf58401297f6c23c6293958c605564ff6628`
Describe: `v1.0.0-beta.1-11-g2526cf5-dirty`
Host: KDE Plasma Wayland, three displays, physical Edge panel on DP-3

## Executive verdict

The current candidate is functionally strong, but it does not yet satisfy the project's complete release Definition of Done.

- No P0 crash, layout-overlap, Hub-to-Manager synchronization, or display-lifecycle defect was observed by the named dirty-tree runs. Autosave crash and power-loss durability were not tested for, so no no-data-loss claim is made.
- The complete functional suite passed.
- The real Hub and Manager integration suite passed.
- All 30 widgets rendered on the physical panel and were visually distinct.
- All 19 preset screens rendered without overlap in the compositor-backed landscape suite.
- Real display restart, rotation, scaling, disable, reconnect, and missing-target behavior passed.
- C++ line coverage is 92.80%, below the required 95% gate.
- Physical touch actions were not certified because the safety probe could not map virtual touch coordinates to the panel reliably. The test correctly refused blind input.
- Some widget evidence shows density, low-contrast, or space-use concerns that should be measured and refined.
- The working tree is dirty. A release from this exact state would not be reproducible until the intended changes are reviewed and committed.

Release classification: **not ready under the repository's strict gates**. It is a viable beta candidate only if the coverage and physical-touch evidence gaps are explicitly accepted as release risks.

## Safety and preservation

- The user's live configuration was backed up before testing:
  `/home/simon/.config/xeneon-edge-hub/config.toml.before-full-audit-20260724-1140.bak`
- Original and backup SHA-256:
  `e9e2bad96426f6c1ec83e097ca555361a51545804626b25599a5e03da7e13e05`
- The physical display was restored after lifecycle testing:
  DP-3 at `5120,2880`, `720x2560`, scale `1`, right rotation, priority `3`.
- No soak test was run. This follows the product owner's explicit decision to stop spending time on soak testing.
- No GitHub Actions minutes were used.
- No product implementation was changed during this audit.

## Fresh test results

### Complete automated suite

Command: `./scripts/run_all_tests.sh`
Log: `../../artifacts/2526cf584012-dirty-20260724/logs/edgehub-full-audit-20260724-1105.log`
Result: PASS

| Area | Result |
|---|---:|
| Rust unit tests | 258 passed |
| QML UI tests | 3,155 passed |
| C++ QtTest suites | 24 of 24 passed |
| Enumerated QML requirements | 497 of 497 assertion-backed |
| Compositor-backed GUI tests | 1,479 passed |
| Runtime and contract scenarios | 9 passed |
| Rust formatting | Passed |
| Rust Clippy with warnings denied | Passed |

The source-tree QML harness emitted 10,488 allowlisted resource warnings from 53 files. These result primarily from running `qmltestrunner` without the compiled resource collection. Static resource parity passed and the compiled widgets rendered, so this is not evidence of 10,488 shipped missing icons. It is still an important test-quality problem because that volume of expected noise can hide a new warning.

The local namespace run proved containment but did not include `strace`, so it did not prove absence of raw-IP connection attempts. The combined supply-chain CI attestation includes namespace containment, sink attribution, syscall tracing, liveness, and negative controls. Local absence of `strace` is not a release blocker when that job passes on the exact clean release SHA.

### Real Manager and Hub integration

Command: `XENEON_HW_INPUT=1 XENEON_HW_INPUT_DESKTOP=1 ./scripts/run_manager_tests.sh`
Log: `../../artifacts/2526cf584012-dirty-20260724/logs/edgehub-full-audit-manager-20260724.log`
Result: PASS, 53 of 53

| Scenario | Result |
|---|---:|
| Manager navigation and liveness | 11 of 11 |
| Manager-to-Hub 14-widget capacity | 20 of 20 |
| Page mirroring | 8 of 8 |
| Hub-to-Manager theme and orientation reflection | 8 of 8 |
| Drag reorder | 6 of 6 |

Observed placement was correct: Manager on the desktop monitor and Hub fullscreen on DP-3. The Manager did not start on the Edge panel. Live state pushes were accepted by the Hub, and current evidence did not reproduce the earlier color or orientation mismatch.

Two runtime warnings were observed:

1. The installed Qt Virtual Keyboard `PopupList.contentWidth` overrides a base member. This is outside repository QML and needs a supported Qt/package disposition.
2. Repository-owned `DashboardStore.data` overrode a base member. It has now been renamed to `DashboardStore.document`, but that corrective edit is not yet tested.

The first cannot honestly be renamed in this repository. The second was an immediate P1 fix.

The orientation sensor reported that the device did not answer the startup `GET_REPORT`. Code inspection found only one conditional delayed retry after 400 ms, and a restored persisted orientation suppresses that retry. This is a P1 product defect, not only an evidence gap.

### Physical widget render matrix

Command: the repository hardware widget matrix
Log: `../../artifacts/2526cf584012-dirty-20260724/logs/edgehub-full-audit-widget-matrix-20260724.log`
Result: PASS, 32 of 32 checks

All 30 first-party widgets loaded on the real panel, produced a non-blank render, and were visually distinct. Evidence directory: `../../artifacts/2526cf584012-dirty-20260724/evidence/tmp/widget-render-g2lfo8hg`.

### Physical feature buildup

Log: `../../artifacts/2526cf584012-dirty-20260724/logs/edgehub-full-audit-buildup-20260724.log`
Result: PASS, 64 of 64 checks

Covered:

- Add, rename, and remove screens
- Add, remove, resize, and arrange widgets
- Theme changes
- Accent changes
- Background and wallpaper changes
- Orientation state
- Manager and Hub visual coherence

Evidence directory: `../../artifacts/2526cf584012-dirty-20260724/evidence/tmp/edge-buildup-kx0wioef`.

### Display lifecycle

Log: `../../artifacts/2526cf584012-dirty-20260724/logs/edgehub-full-audit-display-lifecycle-20260724.log`
Result: PASS, 15 of 15 lifecycle checks and 3 of 3 missing-target checks

Covered:

- Hub restart
- Landscape target
- 125% scale
- Edge temporarily set as primary
- Disable and reconnect
- Missing target without hijacking the primary desktop display
- Restoration of the original display layout

Evidence directory: `../../artifacts/2526cf584012-dirty-20260724/evidence/tmp/edge-lifecycle-xtz14yre`.

The screenshot utility produced two Pillow decompression warnings when capturing a roughly 99-million-pixel mixed-DPI desktop. This is test-tool noise rather than a product defect. The lifecycle harness should crop the relevant outputs or set an intentional image-size policy.

### Physical touch

Log: `../../artifacts/2526cf584012-dirty-20260724/logs/edgehub-full-audit-edge-touch-20260724.log`
Result: INCOMPLETE

The Hub launched and remained alive, but the interaction suite was skipped. The VTouch landing probe failed in all tested transform assumptions and the pointer clamped outside the intended panel area. The safety harness correctly refused to inject unverified touches.

Not certified in this run:

- Focus Start and Pause
- Hydration decrement and increment
- Task completion toggle
- Hub page swipes

This is not proof that those product actions fail. It is proof that the current physical-touch automation is no longer a trustworthy test of them. It is a P1 release-evidence gap.

### Coverage

Command: `./scripts/coverage.sh` using `cmake-build-audit-coverage`
Log: `../../artifacts/2526cf584012-dirty-20260724/logs/edgehub-full-audit-coverage-confirm-20260724.log`
Result: FAIL

| Area | Coverage | Gate |
|---|---:|---:|
| Rust line coverage | 96.41% | Passed |
| C++ line coverage | 92.80% | Failed, requires 95% |
| Combined line coverage | 96.20% | Non-gating diagnostic |
| Enumerated QML requirements | 497 of 497 | Assertion-backed matrix passed |

Lowest C++ files:

| File | Line coverage | Main missing behavior |
|---|---:|---|
| `app/src/notification_bridge.h` | 32% | Notification construction, delivery, and fallback branches |
| `app/src/mpris_bridge.h` | 65% | Player action and unavailable-player branches |
| `app/src/control_socket_path.h` | 79% | Runtime path fallback and environment branches |
| `app/src/config_bridge.h` | 83% | Error, persistence, and state boundary branches |

This is a test deficiency, not evidence that 7.2% of the C++ product is visibly broken. It remains a hard project gate.

### Strict release preflight

Log: `../../artifacts/2526cf584012-dirty-20260724/logs/edgehub-full-audit-release-preflight-20260724.log`
Result: FAIL

Missing prerequisites:

- An owner-issued Pro key in the expected environment
- Local `strace`, which is an owner tooling choice when exact-SHA supply-chain CI provides the combined attestation

Other checked host prerequisites passed, including Wayland, uinput, the unprivileged network namespace, and display geometry. The strict script also expects a 48-hour soak. That step was deliberately excluded by current product-owner direction.

## Widget-by-widget audit

All widgets passed loading, schema, boundary, supported-size, and non-blank render checks. The findings below distinguish observed visual concerns from missing human-validation evidence. Supported sizes use short-axis by long-axis notation and must work in both physical orientations.

| Widget | What is done | Supported sizes | Remaining findings and improvement work |
|---|---|---|---|
| CPU | Live load, temperature when available, history, gauge, compact and detailed variants | 0.5x0.5, 0.5x1, 1x0.5, 1x1, 1x1.5 | **Supported-size defect:** the busiest-process/supporting line truncates in a wide half-height tile. Fix it or remove that size from the supported list. Confirm supporting labels at arm's-length viewing distance. |
| GPU | Driver-provided load, temperature, memory and history with honest unavailable states | 0.5x0.5, 0.5x1, 1x0.5, 1x1, 1x1.5 | No reproduced functional defect. Hardware capability differs by driver, so validate AMD, Intel, NVIDIA proprietary, and NVIDIA open-driver states. Supporting figures need the same arm's-length review as CPU. |
| Memory | Current memory usage, capacity context, gauge and history | 0.5x0.5, 0.5x1, 1x0.5, 1x1, 1x1.5 | No reproduced functional defect. Verify used, available, cache, and swap wording with non-technical users. Supporting figures are less prominent than the hero value. |
| Network | Upload/download throughput, interfaces, history, and empty state | 0.5x0.5, 0.5x1, 1x0.5, 1x1, 1x1.5 | Functional. Interface naming and units should be checked with VPN, bridge, Wi-Fi, Ethernet, and no-network states. Detailed half-size layouts are information-dense. |
| Disk | Root filesystem usage, capacity detail, gauge and history | 0.5x0.5, 0.5x1, 1x0.5, 1x1, 1x1.5 | Functional. The tall half tile packs several secondary facts into a small space. Add mount selection only if the product intends more than root-disk monitoring; otherwise state the root-only scope more visibly. |
| Sensors | CPU/GPU/memory/disk thermal, power, fan and source rows where available | 0.5x1, 1x0.5, 1x1, 1x1.5 | Functional and adaptive, but detailed rows, provenance, and units are dense. Test machines with many sensors, duplicate labels, no sensors, and extreme values. Improve prioritization so warnings remain readable from a distance. |
| Packages | Read-only installed package count, distro context, truthful not-checked update state | 0.5x0.5, 0.5x1, 1x0.5, 1x1 | Honest and functional. Security/update counts remain deliberately unimplemented because there is no trustworthy cross-distro source yet. Keep `Not checked`; do not imply zero updates. Test additional package-manager combinations. |
| System Age | Installer/package-history based age, date, confidence and provenance | 0.5x0.5, 0.5x1, 1x0.5, 1x1 | **Supported-size defect:** the exact date truncates in the micro layout. Fix it with a shorter locale-aware presentation, hide it deliberately, or remove that size from the supported list. Expand cross-distro evidence for weak/unknown history. |
| Clock | Locale-aware digital time, date, IANA/fixed time zones, world clocks | 0.5x0.5, 0.5x1, 1x0.5, 1x1, 1x1.5 | Functional. Validate longest locale strings, 12/24-hour preferences, DST transitions, and three-zone labels. Some screenshot evidence contains excess white harness canvas and should be regenerated cleanly. |
| Analog Clock | Scalable analog face and time | 0.5x0.5, 0.5x1, 1x0.5, 1x1, 1x1.5 | No observed widget defect. Add visual-regression crops for every size, high contrast, and reduced motion. Verify hand contrast on all themes. |
| Moon Phase | Deterministic phase, illumination, cycle, future phases, optional rise/set | 0.5x0.5, 0.5x1, 1x0.5, 1x1, 1x1.5 | Functional. Validate high-latitude no-rise/no-set cases and all themes. Current evidence has excess harness canvas, weakening visual review. |
| Focus Timer | Work/break cycles, presets, persistence, start/pause/skip, daily progress | 1x1, 1x1.5 | Functional automation passed. In 1x1.5, the secondary Now/Next/Cycle panel and controls look undersized relative to available space. Physical Start/Pause was not certified because touch calibration failed. |
| Tasks | Add, edit, complete, remove, undo, persisted checklist and capacity disclosure | 0.5x1, 1x0.5, 1x1, 1x1.5, 1x2, 1x3 | Functional. Tall layouts can show many small rows and become a wall of text. Introduce density tiers or stronger grouping for 1x2 and 1x3. Physical completion touch was not certified. |
| Right Now | One editable focus statement with saved state and supporting context | 0.5x0.5, 0.5x1, 1x0.5, 1x1, 1x1.5 | Functional. The 1x1.5 version has substantial unused space while its secondary statistics remain small. Enlarge the core statement or add useful optional context rather than leaving the area passive. |
| Quick Note | Autosaving scratchpad, multiple sizes, edit and persisted content | 0.5x0.5, 0.5x1, 1x0.5, 1x1, 1x1.5, 1x2, 1x3 | Functional. Long/tall layouts prioritize capacity over glanceability, producing dense small lines. Consider an explicit editing density versus display density, larger default line height, and an uncluttered read mode. |
| Habit Streak | Daily check-in, current/best streak, 28-day history and persistence | 0.5x0.5, 0.5x1, 1x0.5, 1x1, 1x1.5 | Functional. The portrait 1x1.5 layout leaves notable upper space while concentrating the insight map below. Rebalance hero, streak summary, and heatmap. Verify heatmap contrast without relying on color alone. |
| Hydration | Daily count, goal, decrement/increment and daily reset | 0.5x0.5, 0.5x1, 1x0.5, 1x1 | Strong hero presentation. Detailed labels in 1x1 are small. Physical minus/plus input was not certified. Add an optional volume unit only if it can remain simple and accessible. |
| Break Reminder | Schedule-aware countdown, snooze, weekdays and optional notifications | 0.5x0.5, 0.5x1, 1x0.5, 1x1 | Functional and visually clear. Notification bridge coverage is weak, so hidden-page and unavailable-notification paths need direct C++ tests and one real desktop notification check. |
| Meds | Weekday-aware schedule, due windows, taken state, optional private notifications | 0.5x1, 1x0.5, 1x1, 1x1.5, 1x2 | Functional. Tall variants can become visually dense and contain sensitive information. Validate privacy wording, large schedules, missed-dose neutrality, redaction, and arm's-length row size. Do not imply medical adherence or advice. |
| Braindump | Fast capture, edit, remove, clear, undo, bounded 100-item queue | 0.5x1, 1x0.5, 1x1, 1x1.5, 1x2 | Functional. The 1x2 landscape layout leaves a large unused central area because content width/distribution is constrained. Use a wider reading column or a deliberate two-pane/history composition. |
| Routine | Daily checklist, active weekdays, reorder, rename, daily reset | 0.5x1, 1x0.5, 1x1, 1x1.5, 1x2 | Functional. Large routines become dense at tall sizes. Improve section rhythm and completion hierarchy, and validate date-boundary reset under suspend and timezone changes. |
| Now Playing | MPRIS metadata, artwork, transport controls and unavailable state | 0.5x0.5, 0.5x1, 1x0.5, 1x1, 1x1.5 | Functional mocks passed, but MPRIS bridge coverage is only 65%. Test multiple players, disappearing players, missing art, long metadata, seek capability, and real transport actions. Existing screenshot evidence contains sibling hosts rather than isolated crops. |
| HTTP / JSON | Governed HTTP source, JSON path, value/gauge/list modes, thresholds, auth, polling | 0.5x0.5, 0.5x1, 1x0.5, 1x1, 1x1.5, 1x2 | Functional and security contracts pass. Validate malformed JSON, huge lists, slow endpoints, TLS errors, token redaction, allowlist denial, and retry feedback visually. Existing visual evidence is contaminated by sibling test hosts. |
| KPI | HTTP or local-file value, JSON path, thresholds, inverse status, units and polling | 0.5x0.5, 0.5x1, 1x0.5, 1x1, 1x1.5, 1x2, 1x3 | Functional and supports a true full-screen hero. Validate extreme digit counts, negative/scientific values, stale-data age, malformed files, and all threshold combinations. Existing visual evidence is not cleanly isolated. |
| Calendar | ICS agenda, event limits, all-day/time/location states and governed fetching | 0.5x1, 1x0.5, 1x1, 1x1.5, 1x2 | Functional. Tall event lists are dense and small. Test recurrence/timezone edge cases, malformed ICS, privacy of URLs/titles, long locations, no events, and stale-cache feedback. |
| Now / Next | Exactly two calendar event blocks with empty/loading/error states | 0.5x1, 1x0.5, 1x1 | Functional, but the Next event appears very low contrast in current evidence. Measure contrast across all themes and accents, then increase secondary hierarchy without competing with Now. |
| Weather | Current conditions, forecast, units, automatic/manual location and governed network | 0.5x0.5, 0.5x1, 1x0.5, 1x1, 1x1.5 | Functional. Forecast day and temperature labels appear low contrast, particularly in detailed layouts. Test long place names, seven days, offline/cache age, geocoding failure, extreme temperatures, and high contrast. |
| Countdown | Target date, label, yearly repeat and elapsed/upcoming states | 0.5x0.5, 0.5x1, 1x0.5, 1x1 | Functional. Supporting label/date is too faint in larger evidence and can be dominated by the hero number. Measure and raise contrast, then test long labels, today, past dates, leap day, and yearly rollover. |
| End of Day | Work-hour progress, remaining time, weekdays and multiple progress styles | 0.5x0.5, 0.5x1, 1x0.5, 1x1, 1x1.5 | Functional. Detailed labels are small. Test before-work, after-work, overnight ranges, weekends, DST days, invalid ranges, and suspend/resume. Increase supporting-text prominence in larger footprints. |
| Daily Quote | Curated/custom quote, categories, author/source and shuffle | 0.5x0.5, 0.5x1, 1x0.5, 1x1 | Functional and generally balanced. Author, provenance, and shuffle are visually subordinate and small. Test longest strings, custom content, attribution absence, and line clamping in every locale/font scale. |

No widget is certified as having zero possible issues. CPU, Memory, Analog Clock, Moon Phase, Break Reminder, and Daily Quote had no reproduced functional defect, but each still has either hardware/theme/human-validation work or test-evidence quality work.

## Preset-screen audit

All 19 presets satisfy the one-screen capacity contract and passed actual Dashboard landscape rendering without overlap. Preset selection includes a purpose and setup explanation, and automated tests verify that the preview uses real widget components in both orientations. The missing evidence is a curated actual-Dashboard portrait screenshot for every preset.

| Preset | Composition and audience fit | Current assessment |
|---|---|---|
| Calm Focus | Focus 1x1.5 and Right Now 1x1.5 | Purposeful and immediately usable. Inherits the Focus secondary-scale and Right Now empty-space concerns. |
| Notes & Streak | Notes 1x1.5 and Habit 1x1.5 | Coherent. Empty initial Notes creates a quiet but visually sparse first impression; Habit balance needs refinement. |
| Home | Clock 1x1.5 and Weather 1x1.5 | Good desk-companion concept. Requires one-time weather setup and inherits forecast contrast concerns. |
| Ambient | Media 1x1.5 and Moon 1x1 | Coherent ambient use. Media is bland until an MPRIS player is active. Add a polished disconnected illustration or clearer CTA without pretending content exists. |
| Minimalist | Clock 1x1.5, Weather 0.5x1, Moon 0.5x1 | Strong information hierarchy. Validate portrait balance and weather setup state. |
| Health & Routine | Hydration, Break, Habit at 1x1 | One of the strongest seeded layouts. Physical touch still needs certification. |
| Creator / Media | Media 1x1.5 and Focus 1x1.5 | Strong concept. Real-player and transport coverage remains weaker than timer coverage. |
| Student / Study | Focus, Tasks, Countdown at 1x1 | Appropriate composition. Countdown requires a date and the empty Tasks state occupies a large slot. Provide a setup checklist in the preset preview. |
| Productivity | Focus 1x1.5 and Tasks 1x1.5 | Strong and immediately usable. Density grows quickly with long task lists. |
| Remote Work | Tasks 1x1.5 and End of Day 1x1.5 | Appropriate. Empty Tasks can make half the screen look unfinished, and EOD assumes 09:00 to 17:00 until configured. |
| Gaming Cockpit | GPU 1x1.5, CPU and Memory 0.5x1 | Good hierarchy. On unsupported GPU telemetry it becomes visually bland. Test representative GPU drivers and explain driver limitations inline. |
| System Core | CPU, GPU, Memory at 1x1 | Balanced local metrics screen. Validate N/A and partial-sensor states on actual hardware, not only mocks. |
| System I/O | Network, Disk, Sensors at 1x1 | One of the strongest local-data layouts. Dense Sensors content needs viewing-distance validation. |
| Day Plan | Clock 1x1 and Calendar 1x2 | Good agenda hierarchy after setup. The large unconfigured Calendar panel weakens the first impression. |
| Developer | HTTP list and KPI at 1x1.5 | Correctly refuses to guess endpoints. Before configuration both large cards are mostly setup prompts, so the preset does not visually demonstrate its value. Preview it with clearly labelled sample-only data or a richer connection guide. |
| Homelab Ops | Two HTTP lists at 1x1.5 | Correct audience and data model. Both slots are empty until configured, creating the weakest out-of-box screen. Add safe sample-preview mode or endpoint templates without making network assumptions. |
| Trading Desk | Local and New York clocks at 0.5x1 plus KPI 1x1.5 | Time context works immediately. P&L is empty until configured and financial wording must avoid implying trading advice or accuracy guarantees. |
| Analyst / Data | HTTP KPI 1x1.5 plus file KPI and HTTP feed 0.5x1 | Flexible and honest. Initial state is almost entirely setup UI. Improve source setup guidance and sample-preview clarity. |
| Team / Enterprise | End of Day and KPI at 1x1.5 | Restrained managed baseline. Team KPI needs configuration and governance explanation. Validate policy-lock and managed-deployment presentation. |

## Feature, design, and usability audit

| Area | Done and verified | Remaining risk or improvement |
|---|---|---|
| Hub startup and targeting | Finds the Edge model, places before fullscreen, does not hijack primary when target is missing | Cold-start physical sensor report was unavailable. Test real turn events, same/different port reconnect, suspend/resume, and power-cycle. |
| Manager startup and targeting | Manager stayed on the PC monitor while Hub stayed on DP-3 | Add a persistent automated assertion that no Manager window ever intersects the Edge output across all navigation suites. |
| Hub and Manager WYSIWYG | Theme and orientation reflection, page mirroring, live push, real widget preview and coherence passed | Add a long sequence test for theme, accent, wallpaper, per-screen override, page add/remove, restart, and reconnect in one session. |
| Screen management | Add, rename, remove, reorder, 1/2 columns and capacity behavior passed | Add explicit undo for destructive screen removal if product scope allows it. Confirm long screen names and many pages. |
| Preset selection | Review-first picker, purpose/setup copy, actual widgets, orientation-aware preview | Capture all 19 actual Dashboard presets in portrait. Make unconfigured connected-data screens more compelling and self-guiding. |
| Widget management | Add, remove, resize, reorder, configure and 14-widget boundary passed | Physical drag/touch was not certified in this audit. Add screen-reader order and keyboard reorder review. |
| Immersive Hub mode | Bottom Hub controls can be hidden while widget-specific configuration remains available | Run a real-device recovery test proving a user can re-enable standard mode from Manager after restart and reconnect. |
| Themes and accents | Theme, accent, background, wallpaper, high contrast and reduced-motion behavior are implemented and exercised | There is no exhaustive numeric contrast gate for every widget state across all theme, accent, and background combinations. Add one. |
| Rotation | Automated animation/state tests and forced real landscape/portrait lifecycle passed | Physical sensor turn from cold start was not proven. Human-review animation smoothness at native refresh rate and during Manager display should be recorded. |
| Readability | Comfortable text scale, Hyperlegible font, shared minimums and 48px control assertions exist | Several supporting labels still look small or faint. Minimum pixel size alone does not guarantee arm's-length legibility. Run a physical viewing-distance protocol at compact through extra-large settings. |
| Touch and accidental input | Automated QML controls pass target-size tests; safety harness prevents blind injection | Coordinate calibration failed, so real panel input actions and swipes are not currently certified. |
| Configuration dialogs | Every widget has a schema; value boundaries, reset configuration, and separate personal-data erase are tested | There is no complete screenshot matrix of every widget configuration dialog at minimum Manager size, long translations, error states, and keyboard focus. |
| Network and secrets | No raw widget XHR, governed network hub, allowlist/policy, token redaction and runtime contracts pass | Require the combined no-egress supply-chain job on the exact clean SHA. Test certificate failures, captive portal, proxy auth, IPv6, slow responses, and secret migration. |
| Offline behavior | Local widgets work without network; connected widgets do not poll before configuration | Improve stale/cache-age language and create visually useful disconnected states for data-heavy presets. |
| Notifications | Product paths exist and behavior tests cover QML intent | C++ notification delivery and fallback coverage is 32%. Real desktop notification behavior needs direct validation. |
| Media | MPRIS state and QML behavior are implemented | Bridge coverage is 65%; real multi-player and disappearing-player cases remain. |
| Accessibility | Hyperlegible font, scale controls, high contrast, reduced motion, touch targets and accessible descriptions exist | No complete assistive-technology run, color-blind review, focus-order audit, or all-combination contrast gate was completed. |
| First-run and recovery | Wizard, reset, restart, config persistence and missing-target safeguards are tested | Perform a clean-user installation walkthrough and an upgrade walkthrough from the last public beta package. |
| Packaging | Package/AppImage contracts passed in the aggregate suite | No fresh install/upgrade package was built and installed as part of this read-only audit. Dirty source state prevents a reproducible release artifact. |
| Branding and copy | Current source contains zero U+2014 em dash characters | Four occurrences remain only in an old generated CPack staging tree. Regenerated artifacts should be checked before publishing. |

## Visual evidence limitations

The automated visual evidence is useful but not yet a professional golden-image system.

1. Some widget size captures include a large white harness canvas instead of a tight widget crop.
2. HTTP, KPI, and Media captures contain sibling test hosts, so a reviewer cannot judge each widget in isolation.
3. The preset evidence is an actual Dashboard in landscape, but there is no equivalent curated set for all 19 presets in portrait.
4. Configuration dialogs do not have a complete per-widget visual matrix.
5. There is no baseline image comparison with an intentional tolerance and review process.
6. There is no numeric contrast scan for all 30 widgets across every theme, accent, background, loading, empty, error, warning, and disabled state.
7. There is no recorded arm's-length readability study on the physical panel.

## Platform coverage

Verified on this host:

- KDE Plasma Wayland
- Physical DP-3 Edge target
- Forced landscape and portrait
- 100% and 125% scaling
- Temporary primary-display role
- Disable and reconnect
- Target missing without desktop hijack
- Manager on a separate desktop monitor

Not verified in this audit:

- KDE X11
- GNOME Wayland
- GNOME X11
- Other compositors
- 150%, 175%, and 200% scaling
- Physical sensor turn from cold start
- Suspend and resume
- Display power-cycle
- Same-port and different-port cable reconnect
- Multi-touch
- Real physical touch actions and swipe
- Screen reader operation
- Keyboard-only completion of every Manager workflow
- Long translated strings
- Multiple representative AMD, Intel, and NVIDIA systems

## Prioritized remediation plan

### P0

No P0 product defect was observed by the named dirty-tree runs. This is not a
clean-SHA certification.

### P1: required before strict release

1. Raise C++ line coverage from 92.80% to at least 95%.
   - Add focused tests for notification delivery/fallback.
   - Add focused MPRIS action and unavailable-player tests.
   - Cover control socket path environment fallbacks.
   - Cover ConfigBridge error and persistence boundaries.
   - Re-run the complete coverage gate.
2. Record the fast manual physical-touch pass first.
   - Record Focus, Hydration, Tasks, page swipe, widget corner settings, and edit-mode gestures on the panel.
   - File signed, timestamped evidence under the clean commit key.
   - Then discover the current output transform and input device matrix.
   - Prove a safe landing target on DP-3.
   - Run Focus, Hydration, Tasks, page swipe, widget corner settings, and edit-mode gestures.
   - Preserve the refuse-on-uncertainty safety behavior.
3. Fix the physical orientation startup retry defect.
   - Retry hardware acquisition over a bounded multi-second window independently from persisted visual fallback.
   - Verify the first real turn after an unanswered startup report.
   - Verify persisted orientation, rapid turns, reconnect, and Hub/Manager reflection.
4. Measure potential accessibility defects.
   - Now / Next secondary event
   - Weather forecast labels
   - Countdown label/date
   - End of Day detail labels
   - Dense Tasks, Notes, Meds, Routine, Calendar, and Sensors layouts
5. Replace the source-tree QML warning allowlist with a compiled-resource
   harness and fail on every unexpected warning.
6. Fix the CPU wide half-height and System Age micro supported-size defects, or
   remove those sizes from the supported list.
7. Verify the repository-owned `DashboardStore.document` rename and record a
   supported Qt/package disposition for the external Virtual Keyboard warning.

### P2: visual and usability refinement

1. Regenerate isolated, tightly cropped evidence for every widget and supported size.
2. Add actual Dashboard portrait evidence for all 19 presets.
3. Add visual evidence for all 30 widget configuration dialogs.
4. Add an automated contrast matrix across themes, accents, backgrounds, and states.
5. Rebalance Focus 1x1.5, Right Now 1x1.5, Habit 1x1.5, and Braindump 1x2.
6. Add density tiers or improved hierarchy to long list widgets.
7. Improve unconfigured data-preset states with setup checklists or explicitly labelled sample previews.
9. Crop lifecycle screenshots to avoid image-size warnings.

### P3: future capability

1. Add trustworthy update/security counts to Packages only when cross-distro sources and semantics are reliable.
2. Consider more explicit disk mount selection.
3. Consider optional hydration volume without complicating the primary interaction.
4. Expand managed-policy presentation for enterprise deployments.
5. Build a broader real-hardware and desktop-environment compatibility matrix.

## Release Definition of Done

The former single list is superseded because it mixed beta and final-release
requirements. Every former line is assigned to either the v1.0.0-beta.2 gates,
the v1.0.0 release gates, or the owner-blocked prerequisites in
[Audit Correction and Remediation Plan](audit-correction-and-remediation-2026-07-24.md#8-two-tier-definition-of-done).

## Final status

The candidate has broad, credible functional coverage and passed the most important real Hub/Manager integration and display-lifecycle scenarios. The earlier WYSIWYG mismatch was not reproduced. The remaining work is narrower than the historical backlog, but it is not zero: the strict coverage gate fails, real touch is uncertified, cold-start physical rotation still needs proof, and several widget layouts need measured readability and contrast refinement.
