# Widget-by-widget feature audit (opened 2026-08-03)

Running record for a full pass over all 30 catalog widgets: enumerate what each
one actually offers, prove every option is honoured, and file what is not.

## Why this exists

`ui/qml/WidgetConfigSchema.qml` opens with a promise:

> IMPORTANT: every option here is honoured by the corresponding widget - nothing
> is decorative.

Nothing verifies that promise. The enumerated-requirements matrix
(`scripts/qml_coverage.py`) requires every `schema:<widget>.<key>` to be
"assertion-backed", but its bar is that *some* assertion mentions the key's leaf
token — and a schema-shape test (`findField(s, "showPerCore")`, then asserting it
is a toggle whose default is `true`) satisfies that bar completely while proving
nothing about the widget. A regression that ignored the option entirely would
ship green.

So the matrix answers "is this option declared and shaped correctly?" This audit
answers the different question: **does the widget do what the option says?**

## Method, per widget

1. **Enumerate** the feature surface: every `schema:` key, the catalog `sizes`
   the widget claims, and the states it renders (nominal / zero / saturated /
   empty / error, compact vs roomy tile vs expanded, micro).
2. **Classify** each key by the strongest coverage that exists today:
   - `behaviour` — a test sets the key and asserts the widget's response
   - `shape-only` — a test asserts the schema field's type/default and nothing else
   - `absent` — no test names it at all
3. **Exercise** everything that is not `behaviour`. Read the widget source to
   find what the key is supposed to do, then assert it.
4. **Record** every mismatch below and file it in `BACKLOG.md`. A key the widget
   does not read is a broken promise; a help string that describes the wrong
   place is a user-facing defect even when the option works.
5. **Fix** them one at a time, each with a negative control proving the new
   assertion fails when the behaviour is removed.

Coverage added by this audit lives with the widget's existing tests
(`tests/ui/tst_gen_<widget>.qml` for logic, `tests/gui/` for rendered state), not
in a new parallel suite.

## Progress

| # | Widget | Audited | Findings | Fixed |
|---|---|---|---|---|
| 1 | cpu | 2026-08-03 | 2 | 2 |
| 2 | gpu | 2026-08-03 | 1 | 1 |
| 3 | ram | 2026-08-03 | 1 | 1 |
| 4 | net | 2026-08-03 | 1 | 1 |
| 5 | disk | 2026-08-03 | 1 | 1 |
| 6 | sensors | 2026-08-03 | 2 | 2 |
| 7 | packages | 2026-08-03 | 1 | 1 |
| 8 | sinceinstall | 2026-08-03 | 1 | 1 |
| 9 | clock | 2026-08-03 | 1 | 1 |
| 10 | analog | 2026-08-03 | 1 | 1 |
| 11 | moon | 2026-08-03 | 1 | 1 |
| 12 | focus | 2026-08-03 | 1 | 1 |
| 13 | tasks | 2026-08-03 | 1 | 1 |
| 14 | rightnow | 2026-08-03 | 1 | 1 |
| 15 | notes | 2026-08-03 | 1 | 1 |
| 16 | habit | 2026-08-03 | 1 | 1 |
| 17 | hydration | 2026-08-03 | 1 | 1 |
| 18 | break | 2026-08-03 | 0 | 0 |
| 19 | meds | 2026-08-03 | 1 | 1 |
| 20 | braindump | 2026-08-03 | 1 | 1 |
| 21 | routine | 2026-08-03 | 1 | 1 |
| 22 | media | 2026-08-03 | 5 | 3 |
| 23 | httpjson | 2026-08-03 | 1 | 1 |
| 24 | kpi | 2026-08-03 | 2 | 2 |
| 25 | calendar | 2026-08-03 | 2 | 2 |
| 26 | nownext | 2026-08-03 | 1 | 1 |
| 27 | weather | 2026-08-03 | 2 | 2 |
| 28 | countdown | 2026-08-03 | 1 | 1 |
| 29 | eod | 2026-08-03 | 1 | 1 |
| 30 | quote | 2026-08-03 | 0 | 0 |

Plus one cross-cutting seam, swept before the widgets that sit on it:

| Seam | Audited | Findings | Fixed |
|---|---|---|---|
| NetHub (calendar, weather, nownext, httpjson, kpi, update-checker) | 2026-08-03 | 5 | 4 |
| Open-defect gate (`check_no_open_bug_notes.sh`) | 2026-08-03 | 1 | 1 |

---

## 1. cpu

Schema keys: `showTemp`, `tempSource`, `showHistory`, `historyWindow`,
`graphStyle`, `showFrequency`, `showLoadAverage`, `showPerCore`,
`showTopProcess`, `warnTemp`, plus the universal `title` / `accent` /
`cardBackdrop`.

| key | coverage before this audit |
|---|---|
| `tempSource` | **behaviour** — all three modes, plus the missing-requested-sensor path |
| `historyWindow` | **behaviour** — retention limit and live pruning |
| `showTemp` | **behaviour** |
| `showHistory` | **behaviour** |
| `warnTemp` | **behaviour** |
| `showFrequency` | **shape-only** |
| `showLoadAverage` | **shape-only** |
| `showPerCore` | **shape-only** |
| `showTopProcess` | **shape-only** |

### Finding 1.1 — four display toggles have no behaviour coverage

`showFrequency`, `showLoadAverage`, `showPerCore` and `showTopProcess` appear in
the test suite only inside `test_config_schema_*`, which resolves the field and
checks its `type`/`dflt`. The widget does read all four
(`CpuWidget.qml:37-40`, gating `expandedDetails`, `glanceDetails` and the
per-core section), so they work today — but nothing would notice if they stopped.

### Finding 1.2 — two help strings name the wrong surface

Both of these tell the user the option only affects the expanded view. Both also
change the ordinary tile:

- `showPerCore` — help says *"Expanded view shows live activity for the eight
  busiest logical CPUs."* The section's condition is
  `(w.expanded || w.roomyTile)` (`CpuWidget.qml:324`), and `roomyTile` is
  explicitly `!w.expanded` (a tall tile over 1000px, or a wide one over 1000px).
  So it also drives a large tile.
- `showTopProcess` — help says *"Expanded view shows the local process using the
  most CPU in the latest sample."* It is also one of `glanceDetails`
  (`CpuWidget.qml:227`), which returns `[]` **only** when `micro || expanded` —
  i.e. it is the compact-tile path.

A user turning these off to declutter a *tile* would be told the setting does
not apply there.

### Both fixed 2026-08-03

- **1.1** — four behaviour tests added to `tests/ui/tst_gen_cpu.qml`, each driving
  the real setting through the store and asserting the surface it governs:
  `expandedDetails` for the expanded view and `glanceDetails` / the
  `cpuCorePanel` item for the tile. Negative control: making all four properties
  ignore `cfg` (`readonly property bool X: true`) fails all four tests; reverted,
  all four pass. The per-core case also pins the "eight busiest, sorted" contract
  and that empty core data hides the panel regardless of the toggle.
- **1.2** — both help strings now name every surface they govern:
  *"…in the expanded view and on a large tile"* and *"…on the tile and in the
  expanded view"*.

---

## 2. gpu

Schema keys: `gpuDevice`, `showTemp`, `showHistory`, `showDetails`, `warnTemp`,
plus the universal three.

Better shape than cpu: `showTemp` (header temperature disappears), `showHistory`
(sparkline is fed an empty history while sampling continues), `warnTemp`
(thermal state) and `gpuDevice` (selection, and the not-connected path) all have
real behaviour coverage.

### Finding 2.1 — `showDetails` had property-level coverage only

Tests proved the setting REACHED the widget (`compare(w.showDetails, false)`) but
never asserted either surface it governs: the `MetricGauge` `sub:` line
(`GpuWidget.qml:244`) and the `gpuDetailPanel` visibility (`:271`). A widget that
read the property and then ignored it would have passed.

**Fixed 2026-08-03.** `test_show_details_toggle_gates_both_surfaces` feeds a real
device (so there IS a hardware detail to show — the point of the toggle) and
asserts both surfaces on and off. Needed a `findObjectName` helper in that file,
so an assertion can name the exact item a setting governs instead of a
shape-alike. Negative control: making `showDetails` ignore `cfg` fails the test;
reverted, it passes.

### Note — this widget's own test file carries three unfiled bug notes

`tst_gen_gpu.qml` contains three `BUG (audit, low)` comments. They are part of a
larger seam: **36 such notes across the widget tests**, none of them in
`BACKLOG.md`. Several are already stale — the `active`-is-never-read note in
gpu, cpu and net is fixed in all three (`GpuWidget.qml:205`,
`CpuWidget.qml:256`, `NetWidget.qml:217` all check it now). Triaging all 36
against current code, discarding the stale ones and filing the live ones, is
tracked separately.

---

## Interlude: the 36 unfiled bug notes, triaged

Auditing gpu surfaced `BUG (audit ...)` comments in its test file, and a sweep
found **36 of them** across nine widget test files, none in `BACKLOG.md`. Five
ended with *"This assertion is expected to FAIL"*.

**Every single one is already fixed.** Each note sits above a test whose
assertions state the INTENDED behaviour, and the whole suite is green — so the
defects were repaired after the notes were written and the comments were left
behind. Spot-checked against the product rather than inferred from the tests
alone: `DiskWidget.human()` now labels `TiB`/`GiB` with a comment explaining
why, `DiskWidget.col()` rounds before banding so critical can no longer sit
below the warn line, and `active` is honoured in cpu, gpu, net and analog.

So the correct action was **not** to file 36 backlog items. Filing from the
comments would have imported 36 phantom defects into a backlog whose value is
that it is trusted.

The notes were rewritten as what they actually are — provenance for a regression
guard: *"FIXED, and this test pins it (audit high). The defect was: …"*. The
`tst_gen_break.qml` "AUDITED BUGS" block and the `tst_gen_habit.qml` file header
got the same treatment, both found by the new guard rather than by the original
grep.

### The real finding: a comment cannot go stale silently if it may not exist

`scripts/check_no_open_bug_notes.sh` fails on `BUG (audit`, `FIXME`, `XXX`,
`HACK` and "expected to fail" **in test comments**. A known defect belongs in
`BACKLOG.md`, where it is tracked and closed; a test states what it pins.
Past-tense provenance is explicitly allowed. It carries the same anti-vacuity
floor as its siblings — scanning zero files is a failure, not an OK — and it is
wired into both `run_all_tests.sh` and `ci.yml`.

It earned its place before it was even committed: the first run found two
annotations the original `BUG (audit` grep had missed, in `tst_gen_break.qml`
and `tst_gen_habit.qml`. Negative control: reinserting a marker fails the gate.

---

## 3. ram

Schema keys: `unit`, `showHistory`, `historyWindow`, `showDetails`,
`warnPercent`, plus the universal three.

The best-covered of the three metric widgets so far: `unit` (percent vs GiB in
the gauge centre), `showHistory` (gauge history emptied live), `historyWindow`
(limit, label and buffer cap) and `warnPercent` (the colour bands) all have real
behaviour coverage.

### Finding 3.1 — `showDetails` had property-level coverage only

Identical in shape to gpu's finding 2.1: `test_showDetails_reacts_live` set the
setting and asserted `w.showDetails === false`, and stopped there. A widget that
read the property and then ignored it would have passed.

**Fixed 2026-08-03.** The test now asserts the `ramDetailPanel` item's visibility
on and off. The gauge sub-line is the toggle's other surface, but every branch
that fills it needs live byte counts this case does not feed, so it is left to
the cases that have that data rather than pinned to `""` here. Negative control:
making `showDetails` ignore `cfg` fails the test; reverted, it passes.

### Pattern across the three metric widgets

Three audited, three found the same class of hole — a config key whose *plumbing*
is tested and whose *effect* is not:

| widget | key(s) | strongest coverage before |
|---|---|---|
| cpu | `showFrequency`, `showLoadAverage`, `showPerCore`, `showTopProcess` | schema shape only |
| gpu | `showDetails` | property only |
| ram | `showDetails` | property only |

Worth carrying into the remaining 27 as the first thing to check.

---

## 4. net

Schema keys: `unit`, `showHistory`, `historyWindow`, `showDetails`, `scaleMode`,
`fixedScaleMbps`, `interfaceName`, plus the universal three.

Strong on the hard parts: `scaleMode` + `fixedScaleMbps` are proven through
`graphScaleLabel` ("Fixed ceiling…"), `interfaceName` through the selected-vs-
aggregate counters, and `unit` / `showHistory` / `historyWindow` all have real
behaviour coverage.

### Finding 4.1 — `showDetails` was the weakest instance of the family yet

Not property-only like gpu and ram — **default-only**. The single assertion was
`compare(w.showDetails, true)` inside `test_defaults_when_settings_empty`, and no
test ever turned it off. Three `Text` rows are gated on it
(`NetWidget.qml:388/402/411`): the link/source line, the session totals, and the
drops/errors line. A widget that stopped honouring it entirely would have shipped
green.

**Fixed 2026-08-03.** `test_show_details_toggle_gates_the_detail_rows` feeds a
live rate (the rows need `rateAvailable`), asserts the totals and drops rows are
present and visible, turns the toggle off and asserts both hide, then turns it
back on. Negative control: making `showDetails` ignore `cfg` fails the test;
reverted, it passes.

### The pattern is now four for four

| widget | key(s) | strongest coverage before | grade |
|---|---|---|---|
| cpu | `showFrequency`, `showLoadAverage`, `showPerCore`, `showTopProcess` | schema shape | weakest |
| gpu | `showDetails` | property round-trip | |
| ram | `showDetails` | property round-trip | |
| net | `showDetails` | default value only | weakest |

Every metric widget shipped at least one display toggle whose *effect* nothing
asserted, and in three of the four it is the same key. Worth checking
`showDetails` first on `disk` and `sensors`.

---

## 5. disk

Schema keys: `mountPath`, `showActivity`, `warnPercent`, plus the universal three.

`warnPercent` is the best-covered key in the whole audit so far (eleven cases,
including the band-ordering and rounding-boundary regressions), and `mountPath`
covers selection and the offline-mount path.

### Finding 5.1 — `showActivity` was only ever set to `true`

The on-path was proven — `test_activity_has_non_color_direction_labels_and_real_rates`
sets it true and asserts the read/write rows render — and the off-path never was.
The whole `diskActivity` column is gated on it (`DiskWidget.qml:406`).

**Fixed 2026-08-03.** The new case asserts the column visible with the toggle on,
hidden with it off, and — the part worth having — that `ioAvailable` and
`readRate` are *unchanged* underneath: the toggle governs the display, not the
sampling. Negative control: making `showActivity` ignore `cfg` fails the test.

---

## 6. sensors

Schema keys: `gpuDevice`, `rowOrder`, `showCpu`, `showGpu`, `showRam`, `showDisk`,
`showTemps`, `showGpuPower`, `showGpuFan`, `warnCpu`, `warnGpu`, `warnRam`,
`warnDisk`, `warnCpuTemp`, `warnGpuTemp` — the largest surface of any widget so
far.

### Finding 6.1 — five of the six thresholds were never set by any test

`warnCpu`, `warnGpu`, `warnRam`, `warnDisk` and `warnGpuTemp` appeared only in a
schema key-list assertion. Only `warnCpuTemp` was ever driven. Each one feeds
`stateFor()` for its row (`SensorsWidget.qml:163-175`: warning at the value,
critical ten points above), so the widget could have ignored any of the five and
every existing case would still have passed.

**Fixed 2026-08-03** with one data-driven case over all five, asserting the full
band walk per row — Normal below the line, Warning at it, Critical ten above —
and then that the line is *genuinely the config value*: raising it to 90 returns
the same 71 reading to Normal. Negative control: pinning `warnRam` to a constant
fails the ram row.

### Finding 6.2 — the first attempt at that test silently did not run

Worth recording because the suite stayed green while it happened. The insertion
landed **inside** `test_temp_colour_thresholds`, nesting both new functions where
QtTest cannot see them — legal JavaScript, zero test functions added, suite green.
`check_live_tests.sh` did not catch it: that guard is for a `_data` provider with
no matching test, and here both halves existed, just out of reach.

The lesson is a procedural one for the rest of this audit: **after adding a test,
confirm it appears in the run log by name.** A green suite is not evidence that a
new test ran. Re-inserted at TestCase level; all five data rows now appear
individually, and the disk row failed first time on a missing availability
companion (`disk_metrics_available`), which is exactly the kind of honest failure
a test that actually runs produces.

---

## 7. packages

One schema key: `showDistro`. The smallest surface audited so far, and the first
widget whose key already had genuine **behaviour** coverage —
`test_showDistro_controls_the_header_status` asserts `w.status` becomes the
distro name and empties again.

### Finding 7.1 — one of three surfaces was covered

`showDistro` gates three things, not one:

| line | surface |
|---|---|
| `PackagesWidget.qml:123` | the chrome header `status` — **covered** |
| `:158` | the shaped tile's `packageDetailCard` — uncovered |
| `:287` | the expanded view's large distro name — uncovered |

A narrower miss than the earlier widgets, but the same shape: the toggle could
have stopped governing either of the other two without a test noticing.

**Fixed 2026-08-03.** The new case drives both — a shaped wide tile for the
detail card, then the expanded view for the distro name — on and off. It needed a
`findText` helper, because the expanded name has no `objectName`; resolving it by
its exact text keeps the assertion pointed at the real surface rather than a
shape-alike. Negative control: making `showDistro` ignore `cfg` fails on the
detail card.

### Method note

Per the lesson from sensors, the new test was confirmed present in
`tst_packages.log` **by name** before it was believed.

---

## 8. sinceinstall

Schema keys: `ageUnit`, `showDate`.

`ageUnit` is the **best-covered key in the audit so far** and needed nothing: the
automatic mode is walked across all four promotion bands (days → completed
calendar months → years, with the 60-day and 730-day boundaries pinned), and each
explicit unit is proven to stop the promotion — including the deliberate case
that 1461 days stays "1461 days" because that IS the flex for some people.

### Finding 8.1 — `showDate` gates four surfaces; one was covered

| line | surface | was covered |
|---|---|---|
| `SinceInstallWidget.qml:139` | chrome header `status` | yes |
| `:26` | the **accessible summary** | no |
| `:172` | the rich tile's `systemAgeDetailCard` | no |
| `:255` | the expanded exact-date line | no |

The accessible-summary one is the most interesting: `showDate` is presented as a
display option, but it also removes the date from `Accessible.name`. That is
arguably correct — a screen-reader user asked for less, not for a different
amount — but nothing asserted it either way, so it was free to drift.

**Fixed 2026-08-03.** The new case drives all three uncovered surfaces on and
off, and states the accessible-summary behaviour explicitly rather than leaving
it implied. Needed a `findObjectName` and a `findTextStarting` helper, since the
expanded line carries no `objectName`. Negative control: making `showDate` ignore
`cfg` fails on the detail card. Confirmed in `tst_sinceinstall.log` by name.

### The pattern, eight in

The metric widgets hid *whole keys*; the info widgets (packages, sinceinstall)
hide *surfaces of a covered key*. Same defect, smaller blast radius — and it
suggests the check for the remaining 22 is not only "is this key exercised?" but
"how many places does it reach, and does the test know about all of them?"

---

## 9. clock

Schema keys: `format24`, `showSeconds`, `showDate`, `dateStyle`, `datePattern`,
`localeName`, `customZone`, `zoneId`, `zoneLabel`, `utcOffset`, `secondaryZones`.

The most heavily tested widget in the audit — every key appears in both
`tst_clock.qml` and `tst_gen_clock.qml`, `utcOffset` alone 21 times. The
"unexercised key" check finds nothing here, which is why the reach-vs-coverage
question from sinceinstall mattered.

### Finding 9.1 — `localeName` never reached `formatAt`

It is read in **eight** places and set by exactly two tests, and both assert only
`dateFmt` — the date *pattern*, via `localeShortDatePattern()`. Its three
branches inside `formatAt()` had no coverage at all:

| branch | condition | covered |
|---|---|---|
| `at.toLocaleString(Qt.locale(name), fmt)` | no custom zone | no |
| `tz.formatLocale(zoneId, ms, fmt, name)` | custom zone, bridge can localise | no |
| `shifted.toLocaleString(...)` / `tz.format(...)` | fallbacks | partly |

`formatLocale` appeared **nowhere outside the widget**. The reason is neat: the
tests' `fakeTz` bridge does not implement it, and the widget only takes that path
when the bridge offers it (`ClockWidget.qml:127`) — so the branch was unreachable
by construction, not merely unvisited.

Concretely, "New York time, displayed in German" — a real configuration the
schema invites — had no test.

**Fixed 2026-08-03** with three cases and a `fakeTzWithLocale` variant of the
bridge:

- the chosen locale reaches the rendered *text*, not just the pattern —
  `dddd` on a known Monday renders differently under `en_US` and `de_DE`, and
  matches that locale's own rendering (Qt ships its own CLDR data, so this does
  not depend on host locales being installed);
- a zone **and** a locale go to `formatLocale`, carrying the locale;
- a bridge that cannot localise falls back to the plain zone formatter and still
  goes through the bridge, rather than dropping to a locally-shifted `Date`.

Negative control: collapsing the branch to `tz.format(...)` fails the second case.

### Note

`utcOffset`, `zoneId` and the DST-following offset lookup are genuinely well
covered — including a zone from a newer build that this box cannot resolve
falling back to the stored offset rather than rendering a confidently wrong time.
Nothing to add there.

---

## Interlude — the shared NetHub seam

The clock finding (`tz.formatLocale`) was a *branch keyed on a capability the
test double did not implement*. Before auditing the six bridge-backed widgets
one at a time, the whole family was swept for that shape at once: every place
the product tests a member's existence before calling it.

```
$ # guards of the form `&& obj.member`, `obj.member ?`, typeof === "function",
$ # where the same obj.member is called within the next few lines
ClockWidget.qml:127     tz.formatLocale              ← fixed above
FocusWidget.qml:220     priorityAlerts.showPriorityAlert
FocusWidget.qml:238     notificationBridge.sendPriority
MediaWidget.qml:121     media.setPreferredPlayer
NetHub.qml:169          r.resolveSecret
NetHub.qml:318          xhr.abort
NetHub.qml:359          xhr.setRequestHeader
… plus Dashboard/main.qml configBridge probes
```

Every one of those doubles **does** implement its method, so the clock's exact
shape does not repeat. But that inverts the question, and the inverted form
turned out to be worse: **which branch can no test reach because the double is
*too* capable, or because the product itself excludes tests from the branch?**

### Finding N.1 — the request watchdog was unreachable by construction

`NetHub.request()` created its timeout watchdog only when no test factory was
injected:

```qml
var mk = opts.xhrFactory ? opts.xhrFactory : (hub.xhrFactory ? hub.xhrFactory : null)
…
if (!mk && !settled) {                     // ← `!mk` = "no injected XHR factory"
    watchdog = hub._timeoutTimerFactory.createObject(hub, …)
    watchdog.triggered.connect(function () { fail("timeout", true) })
    watchdog.start()
}
```

`mk` is the injected factory. Every offline test injects one, so `!mk` was false
in every test and true only in production — the guard is a direct "tests must not
enter here". That made the entire mechanism unreachable: creation, firing,
the abort, and `clearWatchdog()`'s teardown.

This matters because the watchdog is not a duplicate of the transport timeout.
`NetHub.qml` says so itself: *"Qt's QML XMLHttpRequest accepts a `timeout`
property but does not emit `ontimeout` reliably on every supported runtime."*
The watchdog is the **only** defence against a connection that hangs without
`ontimeout` — and it is the only caller that passes `abortRequest=true`, so it is
also the only path that reaches `xhr.abort()` inside `fail()`. The existing
`test_timeout_surfaces` drives `ontimeout` by hand, which is precisely the case
the watchdog exists to cover for.

Measured, not argued — deleting the whole block:

| control | result |
|---|---|
| gut `clearWatchdog()`'s body | 213/213 still green |
| delete the watchdog creation block entirely | 213/213 still green |

across `tst_nethub`, `tst_calendar_net`, `tst_weather_net`, `tst_kpi_net`,
`tst_httpjson_net`, `tst_update_checker`.

`tst_nethub.qml:135` carried a comment standing in for the missing test — *"The
real-XHR watchdog follows the same fail() path and is destroyed by
clearWatchdog() during the first settlement."* Both halves are reasoning, not
coverage, and the first half is not quite true: the watchdog passes
`abortRequest=true` where `ontimeout` passes `false`, so the paths differ in
exactly the abort. The second half asserted `clearWatchdog` while `watchdog` was
always `null` — the function early-returned, so a `// COVERS: fn:NetHub.clearWatchdog`
claim was satisfied entirely by the no-op path.

**Fixed** by dropping `!mk` from the creation guard. This is production-neutral
by construction: in production `mk` is null, so `!mk` was already true and
nothing about shipped behaviour changes. It only widens what a test can reach.

### Finding N.2 — asserting on callbacks does not recover that coverage

The first repair attempt asserted the *observable* consequence of a surviving
watchdog: settle a request, wait past the deadline, assert no late timeout. It
passed — and it still passed with `stop()`+`destroy()` gutted.

The reason is that `fail()` and `succeed()` both open with `if (settled) return`,
and `settled = true` is set *before* `clearWatchdog()`. A watchdog that outlives
its request is therefore behaviourally silent. Its only consequence is a leaked
QML `Timer`, one per request, parented to the hub for the hub's lifetime — and
`NetHub` is a `QtObject`, which exposes no `children`/`data` to count from QML.

Recovered by injecting a fake timer through NetHub's **existing**
`_timeoutTimerFactory` seam (no test-only product API added) that records
`start`/`stop`/`Component.onDestruction`. That also makes the timeout
deterministic instead of wall-clock dependent.

### Finding N.3 — the response-cap header was excluded from tests the same way

```qml
if (!mk && !local && xhr.setRequestHeader)
    xhr.setRequestHeader("X-Xeneon-Max-Response-Bytes", String(maxResponseBytes))
```

Same `!mk`, same effect. This header is how a widget's own — tighter — cap
reaches the enforcing layer: `XeneonNetworkAccessManager::responseByteLimit()`
(`app/src/network_access_policy.h:170`) widens an **absent** header back to the
2 MiB maximum. So a regression dropping this line does not fail closed; it
silently restores the loosest cap for every widget.

Nothing on either side of the seam covered it. `tests/cpp/tst_network_access_policy.cpp`
hand-builds requests and asserts the limit *given* a header; no test asserted
that anything ever sends one. Fixed the same way, with the same
production-neutrality.

### Finding N.4 — the shared fake XHR silently swallowed every header

`tests/ui/fixtures.js:makeFakeXHR()` implemented `open`, `send` and `abort` but
**not** `setRequestHeader`. Because NetHub guards each header write with
`xhr.setRequestHeader` before calling it, the missing method did not raise —
it made the guard false. Header writes were skipped, silently, for every suite
built on that fixture: calendar, weather, nownext, moon, and the cal+weather GUI
test.

No live defect today (those widgets pass no auth headers; calendar's credential
travels as `urlIsSecretRef`), but it is a trap primed to fire: adding an auth
header to the calendar feed would have looked tested and would not have been.
The fixture now records headers, like the per-suite fakes already did.

### Tests added (`tst_nethub.qml`, 37 → 41)

| test | proves |
|---|---|
| `test_watchdog_settles_a_request_the_transport_never_finishes` | a hang with no `ontimeout` still settles, reports `timeout`, never reports success, and **aborts** the request |
| `test_watchdog_is_torn_down_when_the_request_settles_first` | settling stops **and destroys** the timer |
| `test_response_cap_is_advertised_to_the_transport` | the widget's own cap is what the transport is told to enforce |
| `test_local_reads_carry_no_transport_header` | a `file://` read has no HTTP header layer |

`test_timeout_surfaces` also gained an assertion that the transport's own timeout
does **not** abort — that request has already finished, and it is what
distinguishes the two paths.

Negative controls, each run individually:

| control | expected failure | result |
|---|---|---|
| remove `watchdog.start()` | hung request never settles | FAIL ✓ |
| remove `watchdog.destroy()` | timer leaks | FAIL ✓ |
| remove `watchdog.stop()` | timer left armed | FAIL ✓ |
| remove the cap header write | cap never advertised | FAIL ✓ |

### Finding N.5 — a dead notification fallback in three widgets (not fixed)

`FocusWidget.qml:237`, `BreakWidget.qml:187` and `MedsWidget.qml:293` each
carry the same shape:

```qml
if (notificationBridge && notificationBridge.send) {
    if (notificationBridge.sendPriority) sent = notificationBridge.sendPriority(…)
    else                                 sent = notificationBridge.send(…)   // ← dead
}
```

There is exactly one real bridge (`app/src/notification_bridge.h`) and it
implements `sendPriority`; nothing outside tests assigns the property. Both test
doubles implement `sendPriority` too. So the `else` is reachable neither in
production nor in tests, in all three copies.

Unlike a version-skew fallback this cannot come back: the QML and the C++ bridge
ship in one binary from one `qrc`, so there is no "older host" to degrade to.
Filed as a candidate rather than fixed — deleting product code is not this
audit's remit, and the three copies want one decision, not three.

---

## 10. media

One own schema key — `preferredPlayer` — and it is genuinely `behaviour`-covered
(the trimmed value reaches the bridge, and clearing it reaches the bridge too).
So the schema surface was not the interesting part here. The widget's `about()`
text makes four further promises, and those are what the audit graded:

| promise | strongest coverage before |
|---|---|
| "reports discovery, connection and empty-track states separately" | behaviour — 4 of 5 rungs |
| "shows elapsed and total time" | behaviour |
| "only enables transport or seeking when the player supports them" | **property-only** |
| "Remote artwork remains blocked until it can use the shared network policy" | **absent** |

### Finding 10.1 — the transport test asserted properties, not controls

`test_player_capabilities_disable_unsupported_actions` sets the bridge
capabilities false and then asserts only that the widget's *own* mirror
properties went false:

```qml
h.mediaCtl.canPlayPause = false
compare(h.item.canPlayPause, false)      // ← the widget's property, not a button
```

No control is touched. A regression binding `enabled: true` on every transport
button passes it — the test's own name is the thing it does not check.
`canGoPrevious` was additionally never set false by any test; it was set to
`true` inside the very test that exists to check disabling.

**Fixed** with a data-driven case per control (previous / play-pause / next) that
looks the button up by `objectName` in both the tile and expanded transports and
asserts `enabled` follows the bridge in both directions.

Negative control: binding `enabled: true` in place of `enabled: w.canGoPrevious`
fails the `previous` case.

### Finding 10.2 — the artwork policy had no QML coverage at all

`MediaWidget.localArtworkSource()` decides whether artwork the media player
advertised may be loaded:

```qml
if (/^(file|qrc):/i.test(u)) return u
if (/^data:image\/(png|jpeg|jpg|webp|gif);base64,/i.test(u)) return u
if (!/^[a-z][a-z0-9+.-]*:/i.test(u) && u.indexOf("//") !== 0) return u
return ""
```

This is defence in depth behind `MprisState`, which already suppresses remote
`artUrl`s in C++ — and that C++ layer *is* tested
(`tests/cpp/tst_mpris_state.cpp:238 artUrlRemoteIsSuppressed`). But that suite
proves the **bridge** suppresses them. Nothing proved the **widget** does, so the
two layers could regress independently, and the widget is the layer that decides
what an `Image.source` actually points at. `remoteArtworkBlocked` was named once
in the whole suite; `artworkNotice` and both of its strings, never.

`MockMedia` can hand the widget a remote `artUrl` the real bridge would never
emit — which is precisely what makes the second layer testable at all.

**Fixed** with ten cases: `file:`, `qrc:`, `data:image/png`, `data:image/jpeg`
and a bare relative path are kept; `http:`, `https:`, the protocol-relative
`//host/x.png`, `data:text/html` and `data:image/svg+xml` are blocked, set
`remoteArtworkBlocked`, and produce the user-facing reason.

Negative control: making the filter return every URL unchanged fails all five
blocked cases.

### Finding 10.3 — the notice renders on two surfaces; a text sweep covers one

The first version of the render test swept the item tree for the notice string.
It passed, and it still passed with the tile notice's `visible` forced false —
the harness runs expanded, so the sweep kept finding the *expanded* copy. Same
shape as findings 7.1 and 8.1: N surfaces, one covered, and the test cannot tell
you which.

**Fixed** by giving the two `Text` elements the `objectName`s the rest of the
widget already uses (`mediaArtworkNotice`, `mediaArtworkNoticeExpanded`) and
asserting each by name in the mode that shows it.

Negative controls: hiding either notice alone now fails exactly its own case.

### Finding 10.4 — `"Artwork unavailable"` is unreachable, by algebra (not fixed)

```qml
readonly property bool remoteArtworkBlocked: w.avail && !!media.artUrl
                                              && !w.artworkSource.length
readonly property string artworkNotice: !w.avail || !media.artUrl ? ""
    : w.remoteArtworkBlocked ? "Artwork blocked by network policy"
    : !w.artworkSource.length ? "Artwork unavailable" : ""
```

Reaching the third rung requires `avail && artUrl && !artworkSource.length` while
`remoteArtworkBlocked` is false — but those three conjuncts *are* the definition
of `remoteArtworkBlocked`. The string can never render. That is why it had zero
mentions anywhere: not an oversight, an impossibility.

The gap it was presumably meant to fill is real and is currently unhandled: a
`file://` artwork that passes the policy but fails to *load* (deleted, unreadable,
corrupt) produces `artworkSource` non-empty, no notice, and a silently blank art
box. Wiring the rung to `Image.status === Image.Error` would make it reachable
and correct. Product change beyond this audit's remit — filed as a candidate.

### Finding 10.5 — the "no bridge at all" rung is unreachable in both hosts

`emptyStateLabel`'s first rung, `"Media service unavailable"`, needs
`typeof media === "undefined" || !media`. `media` is not a widget property — the
widget reads it 43 times off the scope chain. The hub sets it as a context
property that is never null (`app/src/main.cpp:636`), the Manager satisfies it
with `MockMedia { id: media }` (`manager/qml/Manager.qml:493`), and the test
harness does the same. So no host can produce it and no test can reach it.

Noted rather than fixed. Unlike 10.4 this one is cheap insurance against a future
host that forgets the bridge, and MediaWidget is the only bridge-backed widget
without the injectable-property seam its siblings have (`CalendarWidget._hub()`,
`ClockWidget._tz()`); giving it one would make the rung reachable but touches 43
call sites, which is its own change.

---

## 27. weather

Schema keys: `locationMode`, `place`, `lat`, `lon`, `units`, `windUnits`,
`precipitationUnits`, `forecastDays`, plus the universal three.

`place`, `lat`, `lon`, `units` and `forecastDays` are the best-covered settings
of any widget audited so far — driven through the store in a dozen tests each,
across the geocode flow, the forecast URL, the shared-provider cache key and the
rendered headline. The two that were not:

| key | coverage before |
|---|---|
| `windUnits` | reaches the provider URL and re-keys the cache — **never reaches the screen** |
| `precipitationUnits` | same |

### Finding 27.1 — the forecast fixture omitted five fields the widget asks for

`WeatherWidget.refresh()` requests these (`WeatherWidget.qml:287-288`):

```
&current=temperature_2m,apparent_temperature,weather_code,
         relative_humidity_2m,wind_speed_10m,precipitation
&daily=weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset
```

`fixtures.js:FORECAST_VALID` supplied the first three and the first three, and
nothing else — no `relative_humidity_2m`, no `wind_speed_10m`, no
`precipitation`, no `sunrise`, no `sunset`. Five of the eleven requested fields.

So `parseForecast` ran against `undefined` for all five in **every** test
(`WeatherWidget.qml:246-250`):

```qml
w.humidity      = Number(d.current.relative_humidity_2m)   // NaN, always
w.windSpeed     = Number(d.current.wind_speed_10m)         // NaN, always
w.precipitation = Number(d.current.precipitation)          // NaN, always
w.sunrise = d.daily.sunrise && d.daily.sunrise.length ? String(d.daily.sunrise[0]).slice(11, 16) : ""
w.sunset  = d.daily.sunset  && d.daily.sunset.length  ? String(d.daily.sunset[0]).slice(11, 16)  : ""
```

Every consumer of those five therefore rendered its placeholder: the entire
`weatherConditionSummary` row is `isFinite(x) ? … : "-"`, so HUMIDITY / WIND /
RAIN were three dashes in every test that has ever run, and the composed detail
line dropped all five clauses. The `.slice(11, 16)` that turns Open-Meteo's
`"2026-07-13T05:12"` into `"05:12"` had never executed.

The one place those properties appear in the suite is
`tst_gui_widget_legibility.qml:564-566`, which assigns them **directly on the
item** — bypassing the parse entirely. That is a legibility test doing exactly
its job; it just cannot say anything about where the numbers come from.

This is the mirror of the clock finding: not a double missing an API, but a
payload missing the fields the product asks the provider for. Same consequence —
a branch no test can reach.

**Fixed** by completing the fixture, plus three tests: the three current-condition
values parse from the payload; sunrise/sunset slice to `HH:MM`; and a provider
that omits them yields `""` rather than the string `"undefined"`.

### Finding 27.2 — the unit settings reached the provider but not the screen

Open-Meteo converts server-side: the widget sends `&wind_speed_unit=mph` and
receives numbers already in mph. The widget's only remaining job is to **label**
them, via `windSym` (three-way) and `precipitationSym` (two-way).

That labelling had no coverage at all. `windSym` and `precipitationSym` were
named in zero tests, and the strings `"km/h"`, `"m/s"` and `"in"` appeared
nowhere in `tests/`. What existed asserted only that the setting reached the
URL and changed the shared-provider cache key.

The failure this admits is the nastiest kind: the number is right and the label
is wrong. A user who picks m/s sees a correct m/s figure labelled `km/h` — a
4× misread with nothing anywhere to catch it.

**Fixed** with four cases (`kmh` → km/h, `mph` → mph, `ms` → m/s, `inch` → in)
asserting both the symbol properties and the string the user actually reads.

Negative controls: pinning `windSym` to `"km/h"` fails the mph and ms cases;
pinning `precipitationSym` to `"mm"` fails the inch case; changing the sunrise
slice to `[11,15]` fails the sun-times case; reading humidity from
`d.current.humidity` fails the parse case.

### Method note — a negative control that does not bite may be lying to you

All four controls above passed on the first attempt, which would have "proved"
the new tests were vacuous. They were not: the widget harness loads widgets from
`qrc:/qml/`, so editing `ui/qml/widgets/WeatherWidget.qml` changes nothing until
`xeneon-qmltestrunner` is rebuilt and re-embeds the resource. `run_ui_tests.sh`
always rebuilds first, which is exactly why it does.

The same stale runner briefly made the clock test committed in `0c5c2dc` look
red on re-run. **A negative control is only evidence after a rebuild.** Both
failure modes are silent and both point the wrong way — one hides a vacuous test,
the other invents a regression.

---

## 26. nownext

Two schema keys: `url` and `bufferMin`.

`url` is well covered — it reaches the nested agenda, a missing one asks for a
URL rather than inventing events, and the egress gate governs the fetch.

### Finding 26.1 — `bufferMin` was the least-covered setting in the audit

Its **only** appearance anywhere under `tests/`:

```qml
tests/ui/tst_schema_completeness.qml:63
    verify(field("nownext", "bufferMin") !== null, "bufferMin")
```

An existence check. Not a type, not a default, not a behaviour — weaker than the
`shape-only` grade this audit defined, which at least asserts type and default.

`test_buffer_window_and_meeting_link_are_useful` does produce the "starts soon"
copy, which is what makes this easy to miss: it builds an event 5 minutes out and
relies on the **default** buffer of 10. So the string was covered and the setting
was not. A widget that hardcoded `10` in place of `cfg.bufferMin` passed the
entire suite.

What it governs (`NowNextWidget.qml:59-60`, `:163`):

```qml
readonly property int bufferMin: Math.max(0, Math.min(120,
    Number(cfg.bufferMin !== undefined ? cfg.bufferMin : 10)))
…
+ (mins > 0 && mins <= w.bufferMin ? "starts soon" : w.humanDelta(mins))
```

**Fixed** with nine cases:

- four buffers (5 / 10 / 30 / 120), each asserting the boundary in both
  directions — exactly `bufferMin` minutes out **is** "starts soon", one minute
  further out is not and still reports the delta;
- four clamp cases (500 → 120, −5 → 0, and both endpoints held);
- a zero buffer disables the copy entirely, including for an event starting this
  very minute — the `mins > 0` half of the guard, which `0 <= 0` would otherwise
  let back in.

Negative controls: hardcoding `bufferMin: 10` fails six cases; dropping the clamp
fails both out-of-range cases; dropping `mins > 0` fails the zero-buffer case.

---

## Interlude — the open-defect gate was case-sensitive

Found while classifying nownext, not while looking for it.

`scripts/check_no_open_bug_notes.sh` exists to stop a test comment from carrying
a known defect that `BACKLOG.md` should carry instead. Its pattern spelled the
case variants out by hand:

```sh
PATTERN='BUG \(audit|…|expected to FAIL|expected to fail'
```

Two files said **`EXPECTED to fail`**, which is neither variant, and `grep -E`
without `-i` is case-sensitive. Both slipped the gate from the day it landed:

| file | claim |
|---|---|
| `tests/ui/tst_gen_break.qml:13` | "Some assertions … are EXPECTED to fail until the code under test is fixed" |
| `tests/ui/tst_gen_shared_WidgetConfigSchema.qml:20` | "several assertions here are EXPECTED to fail … Those failures are the point; do not 'fix' the test to make them green" |

Both claims were **false at the time they were read**. Both suites are green
(72/72 and 60/60), so nothing in either file fails. Verified per claim rather
than in bulk: all four defects the second header names (eod hour fields with no
min/max clamp, countdown accepting `2026-02-30`, `catalog.defaults()` aliasing
its own internals, stale weather/sensors blurbs) have assertions that state the
**correct** behaviour — `test_impossible_day_is_rejected`,
`test_eod_hours_declare_0_to_23`, `test_defaults_returns_fresh_deep_copy`,
`test_weather_desc_not_hardcoded_to_4_days` — and all of them pass. The bugs were
fixed; the headers were never updated.

That is the precise failure this gate was built for, and it is worse than a
missing test: a header telling the next reader "these failures are the point; do
not fix the test to make them green" invites them to ignore a real regression in
that file.

**Fixed** by matching case-insensitively (`grep -EIi`) instead of enumerating
capitalisations — a gate that has to guess how a human shifted a word will always
lose that race. Proof the hole was real: with `-i` added and nothing else
changed, the gate fails and names exactly those two files.

The 8 stale `// BUG:` comments in `tst_gen_shared_WidgetConfigSchema.qml` and the
4 `"REAL BUG: …"` assertion messages in `tst_gen_break.qml` were rewritten as the
past-tense provenance the gate's own error message prescribes. Same treatment as
the 38 `BUG (audit)` notes triaged earlier in this audit, and the same root
cause: a note about a defect outlives the defect, because nothing re-reads it
when the fix lands.

Note that the four `REAL BUG` markers live in **assertion messages**, which this
gate does not scan (it reads comment lines only, so a test may legitimately
assert on a string containing "fixme"). Widening it to cover message strings is
not obviously right and is not done here.

---

## 24. kpi (partial — the file-source seam)

Full schema pass still pending; this records the one finding from the
bridge-backed sweep. `source`, `url`, `filePath`, `jsonPath`, `label`, `prefix`,
`target`, `invert`, `unit`, `decimals`, `warnAt`, `critAt` and `pollSec` all have
behaviour coverage — `prefix` and `target` in
`test_number_format_prefix_target_and_freshness`, which asserts the composed
`deltaText`, not just the property.

### Finding 24.1 — the "no native reader" branch was unreachable

`KpiWidget._fileReader()` picks a reader by **capability**, in three steps:

```qml
if (w.fileReader && w.fileReader.readMetricFile) return w.fileReader
if (typeof configBridge !== "undefined" && configBridge
        && configBridge.readMetricFile) return configBridge
return null
```

`tst_kpi_net.qml`'s `init()` injects a working `fileReader` into **every** test,
so the third step never returned `null` and the branch it feeds
(`KpiWidget.qml:225-229`) never ran. The double was too capable — the same shape
as MockMedia defaulting every transport capability to `true`.

That branch is not hypothetical. Its own help text says *"Start this widget in
the Hub to read a local metric file"*, which names exactly where it fires: a
file-source KPI previewed in the **Manager**, which has no `MetricFileReader`.
The string `"Local reader unavailable"` appeared nowhere under `tests/`.

**Fixed** with two cases: clearing the reader produces that message plus help
that points at the Hub rather than blaming the file, and reads nothing; and an
object *without* `readMetricFile` is not mistaken for a reader.

Negative controls: relaxing the guard to `if (w.fileReader)` fails the second
case; removing the `if (!reader)` guard fails the first — with
`Cannot read property 'readMetricFile' of null`, which is what that branch is
actually preventing.

---

## 25. calendar

Two schema keys. `url` is well covered (the egress gate governs it, webcal is
normalised, a secret ref resolves) and `maxEvents` is driven through the store in
seven tests with a documented "it is a MAXIMUM, not a target" decision.

So the interesting surface is the `about()` promise:

> The active widget reports freshness and any unsupported timezone or recurrence
> rules **instead of silently claiming complete coverage**.

### Finding 25.1 — one assertion covered three warnings and could not tell them apart

The widget emits three distinct warnings, all sharing an `"Unsupported"` prefix:

| line | warning |
|---|---|
| `CalendarWidget.qml:172` | `"Unsupported timezone: " + tz` |
| `:296` | `"Unsupported recurrence rule: " + partName` |
| `:343` | `"Unsupported recurrence frequency: " + freq` |

One test covered them, with:

```qml
verify(h.item.parseWarnings.join(" ").indexOf("Unsupported") >= 0)
```

Its payload — `RRULE:FREQ=HOURLY;BYMINUTE=30` — fires **two** of the three at
once (`BYMINUTE` is not a supported part, `HOURLY` is not a supported
frequency), and the assertion matches their shared prefix. So either emit site
could be deleted and the test still passed. The **timezone** warning was never
triggered by anything: it needs a `TZID=` the offset table cannot resolve, and no
fixture supplied one — half the widget's headline promise was unproven.

**Fixed** with a case per warning, each asserting the specific string including
what it names, because a bare "Unsupported" leaves a user guessing which rule was
dropped:

- `RRULE:FREQ=DAILY;BYSETPOS=2` → `"Unsupported recurrence rule: BYSETPOS"`
- `RRULE:FREQ=HOURLY` → `"Unsupported recurrence frequency: HOURLY"`
- `DTSTART;TZID=Mars/Olympus:…` → `"Unsupported timezone: Mars/Olympus"`

Negative controls: deleting any one emit site fails exactly its own case.

### Finding 25.2 — nothing asserted which frequencies are actually supported

Writing 25.1 surfaced this. `FREQ=MONTHLY` was the obvious "unsupported
frequency" test payload — and it produced no warning, because MONTHLY and YEARLY
**are** supported (`CalendarWidget.qml:304` steps by calendar month/year, for
birthdays and monthly bills). The `supportedParts` list two lines above does not
mention them, so the source reads as though they are not.

Nothing asserted the supported set. A regression routing MONTHLY or YEARLY into
the `stepDays === 0` branch would silently degrade every recurring birthday and
monthly bill to a **single instance** while still rendering something entirely
plausible — the failure would look like a calendar that simply had one event.

**Fixed** with a case per supported frequency (DAILY, WEEKLY, MONTHLY, YEARLY)
asserting no warning and at least one expanded occurrence, plus a case that a
fully-understood calendar warns about nothing and does not show "Partial".

Negative control: removing `MONTHLY` from the supported branch fails the monthly
case with `MONTHLY is expanded, not dropped: Unsupported recurrence frequency:
MONTHLY`.

---

## 23. httpjson · 24. kpi (completed)

Both widgets' settings are well driven — including the security-relevant join
the NetHub audit worried about: `test_bearer_token_becomes_auth_header` sets
`authToken` through the store and asserts the `Authorization` header on the fake,
so "the widget supplies what the gate consumes" is genuinely proven here.

The gap was elsewhere, and a repo-wide scan found it: **user-facing strings that
appear in no test at all**. Scanning every remaining widget for quoted sentences
absent from `tests/` ranked httpjson and kpi near the top (20/24 and 25/28
unasserted), and the strings turned out to be their *failure* vocabulary.

### Finding 23.1 — `errorDetails()` maps nine reasons and none of its help was asserted

```qml
function errorDetails(reason) {
    if (reason === "offline")            return { label: "Offline",  help: "Turn off Offline mode, then retry." }
    if (reason === "blocked")            return { label: "Blocked",  help: "This host is not allowed by the network policy." }
    if (reason === "insecure-auth")      return { label: "Blocked",  help: "Bearer credentials require an HTTPS URL." }
    …
}
```

This is the widget's entire "what went wrong, and what do I do about it"
surface. Tests asserted a few **labels** and not one **help** line.

Worse, two different reasons share the label `"Blocked"`. A label-only assertion
cannot tell *"this host is not allowed by the network policy"* from *"Bearer
credentials require an HTTPS URL"* — refusals with opposite fixes (change the
policy vs change the URL). The help line is the only thing distinguishing them,
and it was untested.

**Fixed** with a case per reason asserting label **and** help, a case pinning
that the two `"Blocked"` reasons do not read identically, and one end-to-end case
proving a real refusal carries the same help rather than composing its own.

Negative controls: falling every reason through to the catch-all fails 15 cases;
giving `insecure-auth` the policy help fails 3.

### Finding 24.1 — Test Connection's failure messages were entirely uncovered

`KpiWidget.testConnection()` is the button a user presses **when something is
already wrong**, so its messages are the whole feature. Only the two success
paths were covered (`HTTP 200`, `Local file ready`). Every refusal branch —
offline, blocked, insecure-auth, timeout, and the pass-through for an unmapped
reason — was untested, and none of those strings appeared under `tests/`.

Also uncovered: pressing Test on a file-source KPI pointed outside the approved
directories. That path must refuse *without reaching the native reader*, and
say which directories are acceptable.

**Fixed** with a parameterised fake gate (`reasonHub`) that fires a chosen
refusal, a case per branch asserting the exact message and that the spinner
stops, and a case proving the unapproved-path refusal never calls the reader.

Negative control: collapsing every refusal into `"Connection failed: " + reason`
fails four cases.

### Method note — the string scan is the cheapest finder in this audit

Three of the last four findings came from the same question: *which sentences
does this widget show a user that no test has ever named?* It is a one-pass grep
and it points straight at error vocabulary, disclosures and empty states — the
surfaces that only appear when something has gone wrong, which is exactly when
nobody is looking at a test. Ranked across the 17 remaining widgets it also
flags, for later passes: `MedsWidget`'s *"A mark records your tap only. It
cannot confirm a dose was taken."* (a safety disclaimer on a medication widget),
`AnalogClockWidget`'s two daylight-saving disclosures, and `CountdownWidget`'s
leap-day copy.

---

## 19. meds · 10. analog

Both found by the string scan described above, and both are the same defect
class: a **disclosure whose words are pinned but whose presence on screen is
not**.

### Finding 19.1 — the medication limits notice could vanish silently

`MedsWidget` shows one line combining two disclaimers:

```qml
readonly property string recordMeaningText: "A mark records your tap only. It cannot confirm a dose was taken."
readonly property string privacyText: "Medication names and marks are stored locally in plaintext. …"
```

`test_active_surface_explains_record_and_plaintext_limits` asserted the
**properties**: that the concatenated copy contains "tap", "cannot confirm" and
"plaintext", and does not imply clinical guidance. All good, and all satisfied
without the string ever reaching a pixel. The notice is a single `Text` bound to
`visible: w.expanded`; a broken binding removes a medication safety disclaimer
while every keyword assertion still passes.

**Fixed** by naming the element (`medsLimitsNotice`) and asserting it is visible,
has real geometry, and contains **both** source strings verbatim — a hardcoded
duplicate in the test would keep passing after the real copy changed.

Note on scope: the notice lives on the *active* surface, hidden until a schedule
exists. That is correct — no doses, nothing to caveat — so the test seeds a
schedule first. The invariant is "if you are tracking medication, you see the
limits."

Negative controls: `visible: false` fails the render case; dropping the privacy
half fails two cases.

### Finding 10.1 — two daylight-saving disclosures, neither asserted

`AnalogClockWidget` can render a face that is **an hour wrong for half the
year**, and these two lines are the only thing that says so:

| condition | line |
|---|---|
| `invalidZone` | "Unknown IANA zone. Using the fixed offset without daylight saving." |
| unresolvable, not invalid | "Fixed offset. Daylight-saving changes are not applied." |

Tests asserted the *properties* (`invalidZone`, `zoneResolvable()`) and the
header status. Neither sentence appeared anywhere under `tests/`, and the
`visible` gate was untested.

They are also not interchangeable: one says *you typed a zone I do not know*, the
other says *you chose a fixed offset, which is working as configured*. Different
causes, different user responses.

**Fixed** with three cases: each state shows its own exact sentence, and a
fully-resolvable zone shows **no** notice at all (claiming inaccuracy when the
clock is accurate would be its own defect).

Writing them clarified something the source does not make obvious:
`invalidZone` is *defined* as `customZone && zoneId.length && !zoneResolvable()`,
so the second message is reachable only with an **empty** `zoneId` — a pure
UTC-offset zone. That is the single state that is unresolvable without being
invalid, and it is now pinned as such.

Negative controls: hiding the notice fails both disclosure cases; giving the
invalid state the fixed-offset wording fails the case that says they must not be
interchangeable.

---

## 28. countdown

Well covered overall: impossible dates rejected, month out of range rejected,
DST-safe local parsing, `feb28` and `mar1` leap policies each asserting both the
substituted date and the disclosure.

### Finding 28.1 — the DEFAULT leap policy was the one nobody drove

`leapDayPolicy` offers three values and `nextLeap` is the default
(`WidgetConfigSchema.qml:565`). Tests drove `feb28` and `mar1`. Nothing drove
`nextLeap`, so nothing asserted the behaviour a user gets **without touching the
setting**: a February 29 recurring date must wait for the next real leap year.

The failure it admits is quiet and plausible — a Feb 29 birthday counting down to
next February instead of four years out. Nothing on screen would look broken.

**Fixed** with:

- the default resolves 2024-02-29 to **2028**-02-29 from 2025, and says
  "Only occurs in leap years";
- the **century rule**: from 2097 it resolves to 2104, not 2100. 2100 is
  divisible by 4 and is not a leap year;
- three cases proving the disclosure stays silent where the policy cannot apply
  (not recurring, an ordinary date, February 28) — showing it there would be
  noise.

### Note — the century case is defended twice, and the first control proved it

Replacing the rollover detection (`new Date(year, 1, 29).getMonth() !== 1`) with
a naive `year % 4` check did **not** fail anything. That is not a weak test: a
second, independent guard at `CountdownWidget.qml:103`
(`!substituted && c.getDate() !== d → continue`) catches the same rollover. The
product is genuinely doubly defended. Breaking **both** fails the century case,
which is what proves the test is not vacuous.

Worth recording because it is the inverse of the usual audit finding: here a
control that did not bite meant the code was *more* careful than expected, not
that the test was empty. The distinction is only visible if you follow up.

### Method note — the string scan produces false positives, and they are cheap

The scan flagged "In non-leap years: February 28" and "In non-leap years:
March 1" as unasserted. They are not: the tests assert
`indexOf("February 28")`, a substring. Exact-match scanning cannot see that.
Both false positives cost one grep each to dismiss, and the same pass found the
genuinely-untested default beside them — the scan is a *prioritiser*, not a
verdict.

---

## 11. moon · 12. focus · 13. tasks

### Finding 11.1 — the eight phase names were never asserted

`MoonWidget` has good numeric coverage: `_cyclePos` in `[0,1)`, `idx` in range,
`idx` matching its own formula, `illum` matching its own formula. None of that
says which **name** a point in the cycle produces, and not one of the eight names
appeared anywhere under `tests/`.

So a rotated or reordered `names` array passed every existing test — while
labelling a full moon "New Moon". That is the single defect this widget exists
to avoid.

**Fixed** by pinning the cycle deterministically (`_cyclePos` is an ordinary
property, so assigning it severs the live-clock binding) and asserting:

- each of the eight eighths yields its own name **and** its illumination
  (new = 0%, quarters = 50%, full = 100%);
- the buckets round to the **nearest** eighth, including the wrap where the last
  eighth rounds forward into New Moon rather than out of the array — an
  off-by-one here names every phase one step early for most of the month, always
  plausible and never right;
- `phaseDirection` agrees with the name, so "Waxing Gibbous" can never be
  reported while the widget calls the direction "Waning".

Negative controls: rotating the array by one fails **18** cases; replacing
round-to-nearest with `floor` fails 3; inverting waxing/waning fails 4.

Note: the boundary is exactly `0.4375` (`pos*8 + 0.5 === 4`). The first draft
asserted `0.438` was still Waxing Gibbous and failed — the test was wrong, not
the widget.

### Finding 12.1 — one cell of a 2×3 notification matrix was covered

`FocusWidget.notifyCompletion(completedPhase, nextPhase)` composes an alert from
two axes: which phase **ended** decides the eyebrow, summary and accent; which
phase is **next** decides the body. Exactly one cell was tested
(`"work"` → `"short"`), asserting the title only.

Neither `eyebrow` nor `body` appeared in any assertion, so a break ending could
have announced **"FOCUS COMPLETE"** and nothing would have caught it, and a long
break could have been announced as a short one.

**Fixed** with a case per phase-ended (eyebrow + title), a case per phase-next
(body), and one asserting every alert stays actionable — `openWidget`, "Open
timer", the detail line, and `widgetType: "focus"` so the alert is attributable.

Negative controls: hardcoding the eyebrow fails 1; making long and short breaks
read identically fails 1.

### Finding 13.1 — the destructive-clear confirm never expired under test

The two-tap confirm on "Clear completed" was covered. Its **expiry** was not.
`clearArmTimer` (4 s) disarms it; nothing asserted that it does. An arm that
never expires turns a stray second tap minutes later into a silent bulk delete —
the confirm still "works", it just stops meaning anything.

Also untested: the button **label** changing once armed, which is the only signal
the user gets that the next tap is destructive.

**Fixed** with a case that finds the timer (a resource, so it needs a `data`
walk, not a `children` walk), asserts the window is a deliberate few seconds
rather than a flicker or a minute, shortens the interval to drive expiry
deterministically instead of waiting out the real one, and asserts expiring
deletes **nothing**; plus a case that the label changes and still names the
action while asking for a second deliberate tap.

Negative controls: removing the timer's `onTriggered` fails 2 cases; freezing the
label fails 1.

**Zero product changes across all three widgets** — these are test-only.

---

## 14. rightnow · 16. habit · 21. routine · 29. eod

Four widgets, one finding each, all the same shape: **the single line the card
shows about its own current state was never asserted.** These are the lines a
user reads at a glance, and each is a small ladder where the branches are easy
to reorder and impossible to notice.

| widget | line | branches | covered before |
|---|---|---|---|
| habit | `todayFeedbackShort` | 4 | **0 mentions anywhere** |
| rightnow | `elapsedLabel()` / `startedLabel()` | 4 + 2 | 1 mention / **0** |
| routine | `routineSummaryText` | 3 | located only to check its font size |
| eod | `stateLabel` | 6 | 2 of 6 |

### 16.1 — habit

`todayFeedbackShort` is a priority ladder: paused beats everything, then a rest
day, then whether the check-in has happened. Nothing referenced it. A paused
habit still nagging "Today: Ready", or a rest day reported as a missed check-in,
would have shipped green. Now a case per state, including that **paused wins even
when the habit is already done**, plus one asserting a rest day says neither
"Ready" nor "Checked in" — the point of a cadence is that some days are meant to
be empty.

### 14.1 — rightnow

`elapsedLabel()` has four branches and `startedLabel()` two. Driving `startedAt`
directly pins each without waiting out real minutes: under a minute, exactly one
minute, under an hour, exactly an hour, hours-and-minutes, and whole hours —
which must read "Focused for 3h", not "3h 0m". `startedLabel()` must say "Not
started" rather than formatting epoch 0 into a confident `01:00`.

### 21.1 — routine

The suite located `routineSummaryText` only to check its font size against the
type floor. Its content was never read, so a rest day could have shown
"0 of 3 done" — a nag on a day nothing was scheduled — with nothing to catch it.
Now a case per branch plus one asserting a rest day reports no progress against
steps that were never due.

### 29.1 — eod

`stateLabel` is the header's whole vocabulary: six phases, one line each. Two
were asserted ("Schedule paused", "Invalid schedule"); the four a user sees on an
ordinary configured day were not. The clock is driven through `nowOverride` so
each phase is reached deterministically rather than depending on when the suite
runs. A second case asserts **no two phases share a label** — a header that says
the same thing in two different situations tells the user nothing.

Negative controls, each failing its own cases: removing habit's paused branch
(2); rendering whole hours as "3h 0m" (2); formatting epoch 0 as a start time
(1); making a rest day report progress (2); dropping eod's "Off day" so it falls
through to "Working" (2); giving "before" the "Complete" label (2).

**Zero product changes across all four.**

---

## 15. notes · 17. hydration · 20. braindump — and 18. break · 30. quote

### 15.1 — the same destructive-confirm gap as tasks

`NotesWidget`'s two-tap clear was covered; its **expiry** was not, exactly as in
finding 13.1. Here the stakes are higher: notes holds one note, so the clear
destroys it outright rather than removing completed rows. An arm that never
expires turns a stray second tap minutes later into a silent wipe.

Fixed the same way — find the timer through a `data` walk, assert the window is
a deliberate few seconds, shorten it to drive expiry deterministically, and
assert expiring leaves the note **intact** because the user never confirmed —
plus the "Clear" → "Confirm clear" label change, the only signal that the next
tap destroys something.

Two widgets with the identical gap is the useful part: it is a pattern in how
destructive confirms get written here, not a one-off.

### 17.1 — the goal line had no branch coverage

`HydrationWidget`'s summary is a three-way ladder around the goal and none of its
branches were asserted. Exactly-at-goal matters most: it is the moment the widget
exists for, and it is the easiest to lose to an off-by-one (`>` for `>=`), which
would leave someone who just hit their goal reading "glasses of water today" as
if nothing had happened.

Three cases (under / at / over) plus one asserting that reaching the goal is not
reported as exceeding it. Negative control: changing `>` to `>=` fails 2.

### 20.1 — the save-failure path was entirely uncovered

`BraindumpWidget.reportSaveFailure()` and its message had zero coverage. This is
the widget's **data-loss** path: the capture did not persist, and the notice is
the only thing telling the user to keep the widget open rather than navigate away
and lose the thought. Every persist route funnels through `persistMutation()`, so
a store that refuses a write exercises all of them.

Two cases: a store that returns `false`, and a store that throws — both must
report the same thing, and neither may also claim the entry was truncated or
evicted. Negative control: swallowing the refused write fails **12** cases; that
guard is load-bearing.

Not added: a `store = null` case. Assigning null did not take effect (the capture
still succeeded) and left the widget in a state that broke four later tests, so
it was dropped rather than left as a flaky or misleading assertion. The two
failure modes above cover `reportSaveFailure` on their own.

### 18 break · 30 quote — audited, no finding

The string scan ranks these highest by raw count (32 unasserted strings in
quote), and both are **deliberate non-findings**. What is unasserted is editorial
*content* — individual break ideas and quote texts. Their **selection logic** is
covered: break pins the `breakIdeas[breaksToday % length]` index math and its
wrap; quote pins category selection, the unknown-category fallback, custom
libraries (empty, whitespace, valid), that every bundled quote carries provenance
and rights, and that each category is large enough to avoid repetition.

Asserting the copy itself would pin editorial text, which produces churn on every
wording change and catches nothing. Recorded explicitly so the next reader does
not "fix" it.

---

## All 30 widgets audited

Closing note on what the audit actually found. Almost nothing was a broken
feature — the widgets do what their settings say. What was missing, repeatedly,
was coverage of what a widget says when something is **wrong, absent, refused, or
merely unusual**:

- refusal vocabulary (httpjson, kpi)
- safety and accuracy disclosures (meds, analog)
- state ladders (habit, rightnow, routine, eod, hydration, moon, focus)
- defaults nobody drives (countdown's `nextLeap`, nownext's `bufferMin`)
- destructive-confirm expiry (tasks, notes — the same gap twice)
- data-loss paths (braindump)
- branches unreachable because a test double was too capable, or because the
  product excluded tests from them (the NetHub seam, media, kpi, clock)

Those surfaces share one property: they only appear when something has gone
wrong, which is exactly when nobody is looking at a test.
