import QtQuick
import QtTest
import "../../ui/qml" as App


// ─────────────────────────────────────────────────────────────────────────
// Comprehensive tests for widget:countdown - ui/qml/widgets/CountdownWidget.qml
//
// Drives config through the shared DashboardStore (setSetting / patchSettings on
// "test-instance") exactly the way the live dashboard does, and asserts on the
// widget's derived properties (cfg, label, dateStr, repeatYearly, days, valid)
// plus the rendered number/label Text.
//
// Several assertions encode the INTENDED behaviour and currently FAIL because of
// real bugs in the widget:
//   • the -999 "invalid" sentinel collides with genuine dates ≥999 days in the
//     past (they read as invalid instead of "passed"),
//   • impossible days-of-month (Feb-31, Apr-31) silently roll into the next
//     month instead of being rejected,
//   • a repeatYearly Feb-29 anniversary drifts to Mar-1 in non-leap years,
//   • a large day count overflows/clips the narrow collapsed tile.
// Those failures are the point - they are left in.
// ─────────────────────────────────────────────────────────────────────────
Item {
    id: root
    width: 520; height: 900

    // Expanded instance - header + settings visible, big number rendered.
    WidgetHarness {
        id: hCd; anchors.fill: parent
        widgetFile: "CountdownWidget.qml"; expanded: true
    }
    App.WidgetConfigSchema { id: schema }

    // A deliberately NARROW, COLLAPSED tile to exercise the big-number clip bug.
    Item {
        id: clipWrap; width: 70; height: 150
        WidgetHarness {
            id: hClip; anchors.fill: parent
            widgetFile: "CountdownWidget.qml"; expanded: false
        }
    }

    // ── Date helpers (mirror the widget's local "YYYY-MM-DD" convention) ──────
    function pad(n) { return (n < 10 ? "0" : "") + n }
    function ymd(d) { return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate()) }
    function offset(n) { var d = new Date(); d.setDate(d.getDate() + n); return d }
    function offsetStr(n) { return ymd(offset(n)) }
    function day0(d) { var x = new Date(d); x.setHours(0, 0, 0, 0); return x }

    // The next real Feb-29 on or after `from` (skips non-leap years, where
    // new Date(y,1,29) overflows to Mar-1).
    function nextFeb29(from) {
        var f0 = day0(from)
        for (var i = 0; i < 12; i++) {
            var cand = new Date(from.getFullYear() + i, 1, 29)
            if (cand.getMonth() === 1 && cand.getDate() === 29) {
                var c0 = day0(cand)
                if (c0 >= f0) return c0
            }
        }
        return null
    }

    // ── Recursive Text finder (widgets give their content Texts no ids) ──────
    function collectTexts(obj, out) {
        if (!obj) return out
        var kids = obj.children
        if (kids) {
            for (var i = 0; i < kids.length; i++) {
                var c = kids[i]
                if (c) {
                    if (typeof c.paintedWidth !== "undefined" && typeof c.text === "string")
                        out.push(c)
                    collectTexts(c, out)
                }
            }
        }
        return out
    }
    function findText(item, str) {
        var all = collectTexts(item, [])
        for (var i = 0; i < all.length; i++)
            if (all[i].text === str) return all[i]
        return null
    }
    function findTextContaining(item, str) {
        var all = collectTexts(item, [])
        for (var i = 0; i < all.length; i++)
            if (String(all[i].text).indexOf(str) >= 0) return all[i]
        return null
    }
    function findObject(item, name) {
        var all = collectTexts(item, [])
        for (var i = 0; i < all.length; i++)
            if (all[i].objectName === name) return all[i]
        return null
    }

    // ── Core config → days/valid mapping ─────────────────────────────────────
    TestCase {
        name: "CountdownConfig"
        when: windowShown
        function init() {
            tryVerify(function () { return hCd.ready }, 3000)
            hCd.item.nowMsOverride = -1
            var s = hCd.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            hCd.storeCtl._touchSettings()
        }
        function set(k, v) { hCd.storeCtl.setSetting("test-instance", k, v) }
        function patch(o) { hCd.storeCtl.patchSettings("test-instance", o) }

        function test_empty_date_is_invalid() {
            var w = hCd.item
            compare(w.valid, false, "no date → not valid")
            compare(w.days, -999, "empty date is the -999 sentinel")
            verify(findText(w, "-") !== null, "collapsed placeholder number is -")
            verify(findText(w, "Set a valid date and time in the configuration panel") !== null,
                   "expanded prompt directs the user to the structured controls")
        }

        // Parsing "YYYY-MM-DD" must use LOCAL midnight - no UTC off-by-one.
        function test_today_local_midnight_is_zero() {
            var w = hCd.item
            set("date", offsetStr(0))
            compare(w.valid, true)
            compare(w.days, 0, "today parses to 0 days (local, no off-by-one)")
        }

        function test_future_date_positive() {
            var w = hCd.item
            set("date", offsetStr(10))
            compare(w.days, 10, "a date 10 days out reads 10")
            compare(w.valid, true)
        }

        function test_time_validation_auto_precision_and_complete_state() {
            var w = hCd.item
            patch({ date: offsetStr(1), time: "25:00" })
            compare(w.valid, false, "impossible time is rejected")
            var now = new Date(2030, 0, 1, 10, 0, 0)
            var target = new Date(2030, 0, 1, 15, 0, 0)
            w.nowMsOverride = now.getTime()
            patch({ date: Qt.formatDate(target, "yyyy-MM-dd"),
                    time: Qt.formatTime(target, "HH:mm"), precision: "auto" })
            compare(w.valid, true)
            compare(w.timeStr, "15:00")
            compare(w.precision, "auto")
            compare(w.hoursRemaining, 5)
            verify(w.heroText.indexOf("h") > 0, "auto precision switches to hours")
            patch({ date: offsetStr(-1), time: "00:00", precision: "days", afterEvent: "complete" })
            compare(w.heroText, "✓")
            w.nowMsOverride = -1
        }

        function test_structured_time_is_bounded_and_formatted() {
            var w = hCd.item
            patch({ date: offsetStr(1), targetHour: 15, targetMinute: 30 })
            compare(w.timeStr, "15:30")
            compare(w.valid, true)
            patch({ targetHour: 25, targetMinute: 30 })
            compare(w.valid, false, "out-of-range structured hour is rejected")
            patch({ targetHour: 9, targetMinute: 60 })
            compare(w.valid, false, "out-of-range structured minute is rejected")
        }

        function test_past_date_negative_and_valid() {
            var w = hCd.item
            set("repeatYearly", false)
            set("date", offsetStr(-3))
            compare(w.days, -3, "a recent past date reads negative")
            compare(w.valid, true, "a recently-passed one-time event is still valid")
        }

        // Math.round absorbs the ±1h a DST transition adds to the ms delta, so a
        // far-future date still yields a clean integer day count.
        function test_dst_far_future_integer_days() {
            var w = hCd.item
            set("date", offsetStr(200))
            compare(w.days, 200, "200 days out reads exactly 200 across any DST edge")
        }

        function test_label_reflected_in_text() {
            var w = hCd.item
            patch({ label: "Trip", date: offsetStr(10) })
            compare(w.label, "Trip")
            verify(findText(w, "days until Trip") !== null, "label appears in the caption")
        }

        function test_days_zero_is_celebration_branch() {
            var w = hCd.item
            set("date", offsetStr(0))
            compare(w.days, 0)
            verify(findText(w, "NOW") !== null,
                   "days===0 shows a deterministic NOW hero, not a number")
            verify(findText(w, "Today!") !== null, "and the Today! caption")
        }

        function test_days_one_uses_singular() {
            var w = hCd.item
            set("date", offsetStr(1))
            compare(w.days, 1)
            verify(findText(w, "day until the day") !== null, "1 → singular 'day until'")
        }

        function test_days_two_uses_plural() {
            var w = hCd.item
            set("date", offsetStr(2))
            compare(w.days, 2)
            verify(findText(w, "days until the day") !== null, "2 → plural 'days until'")
        }
    }

    // ── repeatYearly behaviour ───────────────────────────────────────────────
    TestCase {
        name: "CountdownRepeatYearly"
        when: windowShown
        function init() {
            tryVerify(function () { return hCd.ready }, 3000)
            hCd.item.nowMsOverride = -1
            var s = hCd.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            hCd.storeCtl._touchSettings()
        }
        function set(k, v) { hCd.storeCtl.setSetting("test-instance", k, v) }

        // A passed anniversary rolls to next year and never reads "passed".
        function test_passed_anniversary_rolls_to_next_year() {
            var w = hCd.item
            set("repeatYearly", true)
            set("date", offsetStr(-3))   // 3 days ago
            verify(w.days > 300, "passed anniversary rolls forward (got " + w.days + ")")
        }

        // Toggling repeatYearly must reactively flip a passed one-time event
        // (negative) into a next-year countdown (positive).
        function test_toggle_is_reactive() {
            var w = hCd.item
            set("repeatYearly", false)
            set("date", offsetStr(-3))
            compare(w.days, -3, "one-time passed → negative")
            set("repeatYearly", true)
            verify(w.days > 300, "flipping repeatYearly on rolls to next year (got " + w.days + ")")
        }

        // A future within-this-year date counts down to THIS year's occurrence,
        // not next year's.
        function test_future_this_year_stays_this_year() {
            var w = hCd.item
            set("repeatYearly", true)
            var target = offset(20)
            set("date", ymd(target))
            if (target.getFullYear() === new Date().getFullYear())
                compare(w.days, 20, "a future date this year counts to this year (20)")
            else
                verify(w.days > 0 && w.days < 400, "future occurrence within a year")
        }

        // On the anniversary day, an occurrence later today remains this year's.
        function test_anniversary_later_today_is_not_next_year() {
            var w = hCd.item
            var now = new Date(2030, 6, 23, 10, 0, 0)
            w.nowMsOverride = now.getTime()
            set("repeatYearly", true)
            set("date", "2024-07-23")
            set("time", "15:00")
            compare(w.days, 0, "today's anniversary is 0, not ~365")
        }

        function test_anniversary_time_already_passed_rolls_to_next_year() {
            var w = hCd.item
            var now = new Date(2030, 6, 23, 16, 0, 0)
            w.nowMsOverride = now.getTime()
            set("repeatYearly", true)
            set("date", "2024-07-23")
            set("time", "15:00")
            var target = w.nextTarget()
            compare(target.getFullYear(), 2031,
                    "a passed occurrence on the same day advances one year")
            verify(w.days > 300, "the countdown no longer reports Today")
        }

        // BUG (medium): a Feb-29 anniversary rebuilt as new Date(year,1,29) drifts
        // to Mar-1 in non-leap years instead of landing on the next real Feb-29.
        function test_feb29_anniversary_lands_on_next_real_feb29() {
            var w = hCd.item
            set("repeatYearly", true)
            set("date", "2024-02-29")
            var today0 = day0(new Date())
            var target = nextFeb29(new Date())
            verify(target !== null, "a next Feb-29 exists")
            var expected = Math.round((target - today0) / 86400000)
            compare(w.days, expected,
                    "Feb-29 anniversary should count to the next real Feb-29 (" +
                    ymd(target) + "), not drift to Mar-1")
        }

        function test_feb29_policy_can_use_february_28() {
            var w = hCd.item
            w.nowMsOverride = new Date(2025, 0, 1, 12, 0, 0).getTime()
            hCd.storeCtl.patchSettings("test-instance", {
                repeatYearly: true, date: "2024-02-29",
                leapDayPolicy: "feb28", targetHour: 9, targetMinute: 0
            })
            var target = w.nextTarget()
            compare(target.getFullYear(), 2025)
            compare(target.getMonth(), 1)
            compare(target.getDate(), 28)
            verify(w.leapPolicyText.indexOf("February 28") >= 0)
        }

        // `nextLeap` is the DEFAULT policy and the only one no test drove. It is
        // also the one that decides whether a February 29 birthday counts down
        // to the next leap year or quietly to next February - the difference
        // between a correct four-year wait and a silently wrong one-year wait.
        function test_feb29_default_policy_waits_for_the_next_leap_year() {
            var w = hCd.item
            w.nowMsOverride = new Date(2025, 0, 1, 12, 0, 0).getTime()
            hCd.storeCtl.patchSettings("test-instance", {
                repeatYearly: true, date: "2024-02-29",
                targetHour: 9, targetMinute: 0
            })
            compare(w.leapDayPolicy, "nextLeap", "precondition: this is the default")
            var target = w.nextTarget()
            compare(target.getFullYear(), 2028, "2025, 2026 and 2027 have no February 29")
            compare(target.getMonth(), 1)
            compare(target.getDate(), 29, "and it really is the 29th, not a rolled-over March 1")
            compare(w.leapPolicyText, "Only occurs in leap years",
                    "the default says plainly that it will skip years")
        }

        // The century rule: 2100 is divisible by 4 but is NOT a leap year, and
        // `new Date(2100, 1, 29)` silently rolls to March 1. A policy that only
        // checked `year % 4` would land the countdown on the wrong day.
        function test_feb29_default_policy_skips_a_non_leap_century_year() {
            var w = hCd.item
            w.nowMsOverride = new Date(2097, 0, 1, 12, 0, 0).getTime()
            hCd.storeCtl.patchSettings("test-instance", {
                repeatYearly: true, date: "2024-02-29",
                targetHour: 9, targetMinute: 0
            })
            var target = w.nextTarget()
            compare(target.getFullYear(), 2104,
                    "2100 is divisible by 4 but is not a leap year, so 2104 is next")
            compare(target.getMonth(), 1)
            compare(target.getDate(), 29)
        }

        // The disclosure is only meaningful for a recurring February 29; showing
        // it for an ordinary date would be noise.
        function test_leap_policy_text_is_silent_for_dates_it_cannot_affect_data() {
            return [
                { tag: "not-recurring", repeat: false, date: "2024-02-29" },
                { tag: "ordinary-date", repeat: true, date: "2024-03-15" },
                { tag: "feb-28", repeat: true, date: "2024-02-28" }
            ]
        }
        function test_leap_policy_text_is_silent_for_dates_it_cannot_affect(data) {
            var w = hCd.item
            w.nowMsOverride = new Date(2025, 0, 1, 12, 0, 0).getTime()
            hCd.storeCtl.patchSettings("test-instance", {
                repeatYearly: data.repeat, date: data.date,
                targetHour: 9, targetMinute: 0
            })
            compare(w.leapPolicyText, "",
                    data.tag + " is unaffected by the leap-day policy, so it says nothing")
        }

        function test_feb29_policy_can_use_march_1() {
            var w = hCd.item
            w.nowMsOverride = new Date(2025, 0, 1, 12, 0, 0).getTime()
            hCd.storeCtl.patchSettings("test-instance", {
                repeatYearly: true, date: "2024-02-29",
                leapDayPolicy: "mar1", targetHour: 9, targetMinute: 0
            })
            var target = w.nextTarget()
            compare(target.getFullYear(), 2025)
            compare(target.getMonth(), 2)
            compare(target.getDate(), 1)
            verify(w.leapPolicyText.indexOf("March 1") >= 0)
        }
    }

    TestCase {
        name: "CountdownSchema"

        function field(key) {
            var sections = schema.schemaFor("countdown").sections
            for (var i = 0; i < sections.length; i++)
                for (var j = 0; j < (sections[i].fields || []).length; j++)
                    if (sections[i].fields[j].key === key) return sections[i].fields[j]
            return null
        }

        function test_time_uses_bounded_structured_controls() {
            compare(field("targetHour").type, "hour")
            compare(field("targetHour").min, 0)
            compare(field("targetHour").max, 23)
            compare(field("targetMinute").type, "segmented")
            compare(field("targetMinute").options.length, 4)
            compare(field("time"), null, "raw HH:MM input is no longer exposed")
        }

        function test_leap_day_policy_is_explicit() {
            var f = field("leapDayPolicy")
            compare(f.type, "segmented")
            compare(f.dflt, "nextLeap")
            compare(f.options.length, 3)
        }
    }

    // ── Reactivity + save semantics ──────────────────────────────────────────
    TestCase {
        name: "CountdownReactivity"
        when: windowShown
        function init() {
            tryVerify(function () { return hCd.ready }, 3000)
            var s = hCd.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            hCd.storeCtl._touchSettings()
        }
        function set(k, v) { hCd.storeCtl.setSetting("test-instance", k, v) }

        // Editing the date through the store (a store.revision bump) must update
        // the displayed day count WITHOUT any manual tick - the cfg binding tracks
        // store.revision. This is the Manager/companion-edit path.
        function test_store_edit_updates_without_tick() {
            var w = hCd.item
            set("date", offsetStr(10))
            compare(w.days, 10)
            set("date", offsetStr(20))
            tryCompare(w, "days", 20, 1000, "day count re-derives on a store edit")
        }

        // The Save button patches {label,date} atomically; the two per-field
        // onEditingFinished handlers set them one at a time. Both must yield the
        // same persisted config and same derived day count.
        function test_atomic_save_matches_per_field_saves() {
            var w = hCd.item
            var ds = offsetStr(10)
            // Save-button path (patchSettings).
            hCd.storeCtl.patchSettings("test-instance", { label: "Trip", date: ds })
            var pLabel = w.label, pDate = w.dateStr, pDays = w.days
            // Per-field path (two setSettings after a clear).
            var s = hCd.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            hCd.storeCtl._touchSettings()
            set("label", "Trip")
            set("date", ds)
            compare(w.label, pLabel, "same label both ways")
            compare(w.dateStr, pDate, "same date both ways")
            compare(w.days, pDays, "same day count both ways")
        }
    }

    // ── Malformed input never crashes and resolves to invalid ────────────────
    TestCase {
        name: "CountdownMalformed"
        when: windowShown
        function init() {
            tryVerify(function () { return hCd.ready }, 3000)
            var s = hCd.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            hCd.storeCtl._touchSettings()
        }
        function set(k, v) { hCd.storeCtl.setSetting("test-instance", k, v) }

        function test_various_garbage_is_invalid() {
            var w = hCd.item
            // Includes the mask-padded partial entry the inputMask can persist.
            var bad = ["", "2026", "2026-13-01", "2026-00-10", "2026-01-  ", "abc", "not-a-date"]
            for (var i = 0; i < bad.length; i++) {
                set("date", bad[i])
                compare(w.days, -999, "'" + bad[i] + "' → -999 sentinel")
                compare(w.valid, false, "'" + bad[i] + "' → not valid")
            }
        }
    }

    // ── Sentinel-collision + impossible-date bugs (assertions may FAIL) ───────
    TestCase {
        name: "CountdownBugs"
        when: windowShown
        function init() {
            tryVerify(function () { return hCd.ready }, 3000)
            var s = hCd.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            hCd.storeCtl._touchSettings()
        }
        function set(k, v) { hCd.storeCtl.setSetting("test-instance", k, v) }

        // BUG (high): a real date EXACTLY 999 days in the past produces days=-999,
        // which collides with the "invalid" sentinel, so valid becomes false and
        // the tile shows "Set a date below" instead of "999 days ... passed".
        function test_999_days_past_is_valid_and_passed() {
            var w = hCd.item
            set("repeatYearly", false)
            set("date", offsetStr(-999))
            compare(w.valid, true,
                    "a real event 999 days ago must be VALID (shows 'passed'), " +
                    "not mistaken for the -999 invalid sentinel")
        }

        // BUG (high): any date 1000+ days in the past is likewise misread as
        // invalid (days <= -999 → valid false).
        function test_1000_days_past_is_valid() {
            var w = hCd.item
            set("repeatYearly", false)
            set("date", offsetStr(-1000))
            compare(w.valid, true,
                    "an event 1000 days ago must still render a valid 'N days ... passed'")
        }

        // BUG (medium): Feb-31 passes the crude d<1||d>31 check and rolls over via
        // new Date(y,1,31) to early March - a plausible countdown to a date the
        // user never entered. It should be treated as invalid.
        function test_feb31_is_rejected_not_rolled() {
            var w = hCd.item
            set("date", "2099-02-31")
            compare(w.valid, false,
                    "Feb-31 is impossible → invalid, not silently rolled to Mar-3")
        }

        // BUG (medium): Apr-31 → new Date(y,3,31) overflows to May-1.
        function test_apr31_is_rejected_not_rolled() {
            var w = hCd.item
            set("date", "2099-04-31")
            compare(w.valid, false,
                    "Apr-31 is impossible → invalid, not silently rolled to May-1")
        }
    }

    // ── Collapsed-tile clip bug (large day count) ────────────────────────────
    TestCase {
        name: "CountdownClip"
        when: windowShown
        function init() {
            tryVerify(function () { return hClip.ready }, 3000)
            var s = hClip.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            hClip.storeCtl._touchSettings()
        }

        // BUG (low): the collapsed number Text has no fit/elide and the tile body
        // clips, so a 5-digit day count overflows a narrow tile. The rendered
        // number must fit inside the tile's content width.
        function test_large_day_count_fits_narrow_tile() {
            var w = hClip.item
            hClip.storeCtl.setSetting("test-instance", "date", offsetStr(40000))
            verify(w.days > 9999, "day count is 5 digits (got " + w.days + ")")
            var numStr = "" + w.days
            var num = null
            tryVerify(function () {
                num = findText(w, numStr)
                return num !== null && num.paintedWidth > 0
            }, 2000, "the big number Text is laid out")
            // Content width = tile width minus the collapsed content margins
            // (theme.spacingSm on each side).
            var avail = w.width - 2 * hClip.theme.spacingSm
            // Anti-clip is STRUCTURAL: the number box is bounded to the tile
            // content width and shrinks-to-fit (HorizontalFit) with elide. The
            // exact painted glyph width depends on the renderer's font fit, which
            // is not deterministic under the offscreen platform across Qt versions
            // (see docs/DEV_AND_TEST_PLAN.md "genuinely unmeasurable"). Assert the
            // box + fit config that guarantees no overflow, not the glyph ink.
            compare(num.fontSizeMode, Text.HorizontalFit,
                    "the day number shrinks to fit its width")
            verify(num.elide === Text.ElideRight,
                   "the day number elides rather than overflowing")
            verify(num.width <= avail + 1,
                   "the day number box (" + numStr + ") is bounded to the " +
                   Math.round(avail) + "px tile content width (got width=" +
                   Math.round(num.width) + ")")
        }
    }

    // ── Per-sizeClass structure (W1) ──────────────────────────────────────────
    // Fixed-size hosts at real projected cell footprints; the Dashboard injects
    // sizeClass, so the tests assign it the same way and pin what each size
    // shows - a future edit can't silently collapse the sizes back into one
    // stretched number-in-a-void.
    Item { id: cMicroWrap; width: 344; height: 416
        WidgetHarness { id: hCMicro; anchors.fill: parent; widgetFile: "CountdownWidget.qml"; expanded: false } }
    Item { id: cBaseWrap; width: 696; height: 840
        WidgetHarness { id: hCBase; anchors.fill: parent; widgetFile: "CountdownWidget.qml"; expanded: false } }
    Item { id: cWideWrap; width: 696; height: 416
        WidgetHarness { id: hCWide; anchors.fill: parent; widgetFile: "CountdownWidget.qml"; expanded: false } }
    Item { id: cTallWrap; width: 344; height: 840
        WidgetHarness { id: hCTall; anchors.fill: parent; widgetFile: "CountdownWidget.qml"; expanded: false } }

    TestCase {
        name: "CountdownSizes"
        when: windowShown

        // Seed a valid one-time countdown WITH a progress baseline, exactly what
        // the widget itself stamps when a date is stored: half the wait elapsed.
        function seed(hh, daysOut) {
            var ds = offsetStr(daysOut)
            hh.storeCtl.patchSettings("test-instance", {
                date: ds, label: "Trip", dateSetFor: ds,
                dateSetEpoch: Date.now() - daysOut * 86400000   // set as long ago as it is away
            })
            return ds
        }

        // 0.5x0.5 - the count + one caption line, nothing else.
        function test_micro_count_and_caption_only() {
            tryVerify(function () { return hCMicro.ready }, 3000)
            seed(hCMicro, 10)
            var w = hCMicro.item
            w.sizeClass = "compact"
            compare(w.micro, true, "a 344x416 compact box is the micro tile")
            compare(w.showDateRow, false, "micro drops the date row")
            compare(w.showProgress, false, "micro has no progress bar")
        }

        // 1x1 - count + caption + the target-date row; still no progress bar.
        function test_baseline_shows_date_row() {
            tryVerify(function () { return hCBase.ready }, 3000)
            seed(hCBase, 10)
            var w = hCBase.item
            w.sizeClass = "compact"
            compare(w.micro, false, "696x840 compact is the baseline, not micro")
            compare(w.showDateRow, true, "the 1x1 earns the target-date row")
            compare(w.showProgress, false, "compact keeps the progress bar for bigger sizes")
            var t = w.nextTarget()
            verify(t !== null, "a target exists")
            verify(findTextContaining(w, Qt.formatDate(t, "ddd, d MMM yyyy")) !== null,
                   "the formatted target date is rendered")
        }

        // wide - count beside caption/date/progress, in BOTH projections of the
        // class (1x0.5 portrait 696x416, 1x1.5 landscape 1264x696).
        function test_wide_shows_progress_both_orientations() {
            tryVerify(function () { return hCWide.ready }, 3000)
            seed(hCWide, 10)
            var w = hCWide.item
            w.sizeClass = "wide"
            compare(w.horiz, true, "wide lays the count beside the context column")
            compare(w.showDateRow, true, "wide shows the date row")
            compare(w.showProgress, true, "wide earns the progress bar")
            verify(w.progress > 0.35 && w.progress < 0.65,
                   "half the wait elapsed reads ≈50% (got " + w.progress + ")")
            cWideWrap.width = 1264; cWideWrap.height = 696   // 1x1.5 in landscape
            compare(w.showProgress, true, "the big landscape projection keeps the progress context")
            cWideWrap.width = 696; cWideWrap.height = 416
        }

        // tall - stacked, with date + progress (0.5x1 / 1x1.5 portrait).
        function test_tall_shows_date_and_progress() {
            tryVerify(function () { return hCTall.ready }, 3000)
            seed(hCTall, 10)
            var w = hCTall.item
            w.sizeClass = "tall"
            compare(w.horiz, false, "tall stacks vertically")
            compare(w.showDateRow, true, "tall shows the date row")
            compare(w.showProgress, true, "tall earns the progress bar")
        }

        function test_long_copy_reflows_in_constrained_micro_and_tall_tiles() {
            tryVerify(function () { return hCMicro.ready && hCTall.ready }, 3000)
            var longLabel = "Public production release and community launch"

            hCMicro.storeCtl.patchSettings("test-instance",
                { date: "2038-12-31", label: longLabel, precision: "seconds" })
            hCMicro.item.sizeClass = "compact"
            hCMicro.theme.textScale = 1.45
            wait(0)
            var microContext = findObject(hCMicro.item, "countdownContext")
            verify(microContext !== null)
            verify(!microContext.truncated,
                   "the micro event context wraps instead of silently eliding")
            verify(microContext.contentWidth <= microContext.width + 1)
            verify(microContext.contentHeight <= microContext.height + 1)

            cTallWrap.width = 278
            cTallWrap.height = 654
            hCTall.storeCtl.patchSettings("test-instance",
                { date: "2038-12-31", label: longLabel, precision: "seconds" })
            hCTall.item.sizeClass = "tall"
            hCTall.theme.textScale = 1.45
            wait(0)
            var eventText = findObject(hCTall.item, "countdownEvent")
            var targetText = findObject(hCTall.item, "countdownTarget")
            verify(eventText !== null && targetText !== null)
            verify(!eventText.truncated && eventText.contentHeight <= eventText.height + 1,
                   "the long event heading reflows inside the narrow tall tile")
            verify(!targetText.truncated && targetText.contentHeight <= targetText.height + 1,
                   "the concise target context reflows inside the narrow tall tile")
            verify(hCTall.item.Accessible.name.indexOf(longLabel) >= 0,
                   "the accessible summary retains the complete event name")
            verify(hCTall.item.Accessible.name.indexOf("Device local UTC") >= 0,
                   "the accessible summary retains the complete timezone context")

            hCMicro.theme.textScale = 1.15
            hCTall.theme.textScale = 1.15
            cTallWrap.width = 344
            cTallWrap.height = 840
        }

        // A repeatYearly countdown carries its own honest baseline (the year
        // cycle) - the progress bar works with no dateSetEpoch at all.
        function test_yearly_progress_needs_no_stamp() {
            tryVerify(function () { return hCTall.ready }, 3000)
            var s = hCTall.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            hCTall.storeCtl._touchSettings()
            hCTall.storeCtl.patchSettings("test-instance",
                { date: offsetStr(-100), repeatYearly: true })
            var w = hCTall.item
            w.sizeClass = "tall"
            verify(w.days > 200, "the anniversary rolled to next year")
            verify(w.progress >= 0 && w.progress <= 1,
                   "yearly progress derives from the year cycle (got " + w.progress + ")")
            verify(w.progress > 0.15, "~100 days into the cycle is visibly non-zero")
        }

        // The widget stamps its own baseline when a date is stored (the tile and
        // the overlay are two instances - only the active one writes).
        function test_widget_stamps_dateSet_baseline() {
            tryVerify(function () { return hCBase.ready }, 3000)
            var s = hCBase.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            hCBase.storeCtl._touchSettings()
            var ds = offsetStr(30)
            hCBase.storeCtl.setSetting("test-instance", "date", ds)
            tryVerify(function () {
                var c = hCBase.storeCtl.settingsFor("test-instance")
                return c.dateSetFor === ds && c.dateSetEpoch > 0
            }, 2000, "storing a date stamps dateSetFor/dateSetEpoch")
            // Re-storing the SAME date must not move the baseline.
            var epoch1 = hCBase.storeCtl.settingsFor("test-instance").dateSetEpoch
            hCBase.storeCtl.setSetting("test-instance", "label", "nudge")   // unrelated write
            wait(50)
            compare(hCBase.storeCtl.settingsFor("test-instance").dateSetEpoch, epoch1,
                    "an unrelated settings write does not move the baseline")
        }
    }

    // ── Custom title (titleOverride wiring, as Dashboard supplies it) ─────────
    TestCase {
        name: "CountdownTitle"
        when: windowShown
        function init() {
            tryVerify(function () { return hCd.ready }, 3000)
            var s = hCd.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            hCd.storeCtl._touchSettings()
            hCd.item.titleOverride = ""
        }

        function test_default_title_is_countdown() {
            var w = hCd.item
            verify(findText(w, "Countdown") !== null, "default header title is 'Countdown'")
        }

        // The dashboard wires cfg.title → titleOverride (Dashboard.qml:253-255);
        // replicate that binding and confirm the chrome header honours it and
        // reactively reverts when the custom title is cleared.
        function test_custom_title_reflected_in_header() {
            var w = hCd.item
            w.titleOverride = Qt.binding(function () {
                hCd.storeCtl.revision
                var s = hCd.storeCtl.settingsFor("test-instance")
                return (s && s.title) ? s.title : ""
            })
            hCd.storeCtl.setSetting("test-instance", "title", "Birthday Party")
            tryVerify(function () { return findText(w, "Birthday Party") !== null },
                      1000, "custom title overrides 'Countdown' in the header")
            hCd.storeCtl.setSetting("test-instance", "title", "")
            tryVerify(function () { return findText(w, "Countdown") !== null },
                      1000, "clearing the custom title falls back to 'Countdown'")
        }
    }
}
