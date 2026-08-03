import QtQuick
import QtTest
import "../../ui/qml" as App
import "../../ui/qml/widgets" as Widgets


// ─────────────────────────────────────────────────────────────────────────
// Comprehensive tests for widget:eod - ui/qml/widgets/EndOfDayWidget.qml
// (the "End of Day" workday-progress widget) plus the shared config schema /
// ConfigField surface that drives its hour fields.
//
// Drives config through the shared DashboardStore (setSetting/patchSettings on
// "test-instance") exactly like the live dashboard, plus the Manager control
// socket path (store.applyExternal), and asserts on the widget's derived
// properties/functions (cfg, startHour, endHour, showPercent, progressStyle,
// validHours, frac, fmtDur(), remaining, setHours(), effAccent) and on the
// actual rendered Text/PillButton/RingProgress nodes.
//
// Several assertions encode the INTENDED behaviour and currently FAIL because
// of real bugs called out in the audit (out-of-range hours via the config
// stepper corrupt the window; ring-mode time text ignores effAccent; percent
// caption is not zero-padded like the editor; long remaining strings overflow
// the tile; the hour schema fields omit min/max; cross-midnight windows are
// silently rejected). Those failures are the point and are left in.
// ─────────────────────────────────────────────────────────────────────────
Item {
    id: root
    width: 520; height: 900

    // Expanded harness for the bulk of the logic + layout tests.
    //
    // `expanded` and sizeClass "full" are pinned TOGETHER (see clear()), because
    // that is the only pairing Dashboard ever produces: injectWidget sets
    // sizeClass "full" for the overlay and a span-derived class otherwise. Left
    // to WidgetChrome's geometric default this 760-tall host reported "tall"
    // WHILE expanded - a combination the product cannot reach - and the widget
    // carried a `&& !w.expanded` term whose only job was to paper over it. Pinning
    // the real pairing let that dead term go.
    WidgetHarness {
        id: hEod
        x: 0; y: 0; width: 480; height: 760
        widgetFile: "EndOfDayWidget.qml"; expanded: true
    }
    // A second, collapsed harness sized to a half-width portrait tile
    // (~344px on the 720px panel) for overflow/clipping checks.
    WidgetHarness {
        id: hCollapsed
        x: 0; y: 760; width: 344; height: 140
        widgetFile: "EndOfDayWidget.qml"; expanded: false
    }

    // Shared config-surface components, instantiated directly.
    App.WidgetConfigSchema { id: schema }

    // ConfigField needs a `theme` in scope to render its hour control; expose one.
    Item {
        id: cfEnv
        width: 1; height: 1
        property alias theme: cfTheme
        Component.onCompleted: cfStore.load("blank")   // seed a live `data` document
        App.Theme { id: cfTheme }
        App.DashboardStore { id: cfStore }
        Widgets.ConfigField {
            id: cfHour
            field: ({ key: "startHour", label: "Start hour", type: "hour", dflt: 9 })
            st: cfStore
            instanceId: "cf-inst"
            col: ({
                textPrimary: cfTheme.textPrimary,
                textSecondary: cfTheme.textSecondary,
                bg: cfTheme.cardBackground,
                accent: cfTheme.accent,
                border: cfTheme.cardBorder,
                panelAlt: cfTheme.cardBackgroundAlt
            })
        }
    }

    // ── Shared traversal helpers (root-level → visible to every TestCase) ────
    function collect(node, acc) {
        acc.push(node)
        var ch = node.children
        if (ch)
            for (var i = 0; i < ch.length; i++)
                if (ch[i]) collect(ch[i], acc)
        return acc
    }
    // Effective visibility: walk from node up to `top` (inclusive).
    function effVisible(node, top) {
        var n = node
        while (n) {
            if (n.visible === false) return false
            if (n === top) break
            n = n.parent
        }
        return true
    }
    // The single VISIBLE Text node whose text === `str`, or null.
    function visibleTextEq(top, str) {
        var all = collect(top, [])
        for (var i = 0; i < all.length; i++) {
            var o = all[i]
            if (o !== top && typeof o.text === "string" && o.text === str && effVisible(o, top))
                return o
        }
        return null
    }
    // The single VISIBLE Text node whose text CONTAINS `sub`, or null.
    function visibleTextContains(top, sub) {
        var all = collect(top, [])
        for (var i = 0; i < all.length; i++) {
            var o = all[i]
            if (o !== top && typeof o.text === "string" && o.text.indexOf(sub) >= 0 && effVisible(o, top))
                return o
        }
        return null
    }
    function objectNamed(top, name) {
        var all = collect(top, [])
        for (var i = 0; i < all.length; i++)
            if (all[i] !== top && all[i].objectName === name)
                return all[i]
        return null
    }
    function heroText(top) {
        var all = collect(top, [])
        for (var i = 0; i < all.length; i++) {
            var o = all[i]
            if (o !== top && o.objectName === "eodHeroTime" && effVisible(o, top))
                return o
        }
        return null
    }
    // All PillButton-like nodes (declare a string `label`).
    function pills(top) {
        var out = []
        var all = collect(top, [])
        for (var i = 0; i < all.length; i++) {
            var o = all[i]
            if (o !== top && typeof o.label === "string" && o.label !== ""
                    && o.hasOwnProperty("primary"))
                out.push(o)
        }
        return out
    }
    // The visible RingProgress node (has `value` + `progressColor`), or null.
    function visibleRing(top) {
        var all = collect(top, [])
        for (var i = 0; i < all.length; i++) {
            var o = all[i]
            if (o !== top && o.value !== undefined && o.progressColor !== undefined
                    && effVisible(o, top))
                return o
        }
        return null
    }

    function clear(h) {
        var s = h.storeCtl.settingsFor("test-instance")
        for (var k in s) delete s[k]
        h.storeCtl._touchSettings()
        // Restore the real pairing: an expanded host IS sizeClass "full".
        if (h.item && h.expanded) h.item.sizeClass = "full"
    }

    // ── frac / remaining time math (deterministic injected clock) ──────────────
    TestCase {
        name: "EodTimeMath"
        when: windowShown
        function init() {
            tryVerify(function () { return hEod.ready }, 3000)
            clear(hEod)
            hEod.item.nowOverride = null
        }
        function cleanup() { hEod.item.nowOverride = null }
        function patch(o) { hEod.storeCtl.patchSettings("test-instance", o) }
        function at(h, m) { return new Date(2026, 0, 15, h, m || 0, 0, 0) }

        function test_before_start_frac_zero_and_countdown() {
            var w = hEod.item
            patch({ startHour: 10, endHour: 18 })
            w.nowOverride = at(8, 30)
            compare(w.frac, 0, "before the workday, frac is 0")
            compare(w.remaining, "Starts in 1h 30m",
                    "08:30 before a 10:00 start shows the exact countdown")
        }

        function test_after_end_frac_one_and_done() {
            var w = hEod.item
            patch({ startHour: 9, endHour: 17 })
            w.nowOverride = at(18, 30)
            compare(w.frac, 1, "after the end, frac clamps to 1")
            compare(w.remaining, "Complete", "past the end shows the completion string")
            compare(w.phase, "complete")
        }

        function test_within_window_frac_and_live_remaining() {
            var w = hEod.item
            patch({ startHour: 9, endHour: 17 })
            w.nowOverride = at(13)
            fuzzyCompare(w.frac, 0.5, 0.001, "13:00 is halfway through 09:00–17:00")
            compare(w.remaining, "4h 0m", "within the window shows the exact live duration")
        }

        function test_quarter_hour_precision_and_scheduled_day() {
            var w = hEod.item
            patch({ startHour: 9, startMinute: 15, endHour: 17, endMinute: 45,
                    workDays: "1,2,3,4,5" })
            w.nowOverride = new Date(2026, 0, 15, 13, 30, 0, 0)
            compare(w.activeOn(w.nowOverride), true)
            fuzzyCompare(w.frac, 0.5, 0.001)
            compare(w.remaining, "4h 15m")
            w.nowOverride = new Date(2026, 0, 18, 13, 30, 0, 0)
            compare(w.activeOn(w.nowOverride), false)
            compare(w.remaining, "Off today")
            compare(w.frac, 0)
            w.nowOverride = null
        }

        function test_overnight_window_uses_its_start_weekday() {
            var w = hEod.item
            patch({
                startHour: 22, endHour: 6, allowOvernight: true,
                workDays: "1"
            })
            w.nowOverride = new Date(2026, 0, 5, 23, 0, 0, 0)
            verify(w.activeOn(w.windowBounds(w.nowOverride)[0]),
                   "Monday night is active")
            fuzzyCompare(w.frac, 1 / 8, 0.001)
            compare(w.remaining, "7h 0m")

            w.nowOverride = new Date(2026, 0, 6, 3, 0, 0, 0)
            verify(w.activeOn(w.windowBounds(w.nowOverride)[0]),
                   "Tuesday morning still belongs to Monday's shift")
            fuzzyCompare(w.frac, 5 / 8, 0.001)
            compare(w.remaining, "3h 0m")

            patch({ workDays: "2" })
            compare(w.frac, 0,
                    "enabling Tuesday alone does not retroactively enable Monday's shift")
            compare(w.remaining, "Off today")
        }

        function test_tick_recomputes_frac_and_remaining() {
            var w = hEod.item
            patch({ startHour: 9, endHour: 17 })
            // A plain JS clock object remains mutable when stored in a QML `var`
            // (a Date is converted to an immutable QVariant copy). Its fields have
            // no notify signal, making `tick` the only recomputation trigger.
            var clock = {
                hour: 13,
                getFullYear: function () { return 2026 },
                getMonth: function () { return 0 },
                getDate: function () { return 15 },
                valueOf: function () {
                    return new Date(2026, 0, 15, this.hour, 0, 0, 0).valueOf()
                }
            }
            w.nowOverride = clock
            fuzzyCompare(w.frac, 0.5, 0.001, "setup is halfway through the window")
            compare(w.remaining, "4h 0m")

            // Mutate the injected clock in place. That emits no property-change
            // signal, so only the widget's real timer seam (`tick`) can invalidate
            // and recompute these bindings.
            clock.hour = 14
            w.tick++
            fuzzyCompare(w.frac, 5 / 8, 0.001, "tick recomputes progress at 14:00")
            compare(w.remaining, "3h 0m", "tick recomputes the remaining duration")
        }

        function test_fmtDur_formats_hours_minutes() {
            var w = hEod.item
            compare(w.fmtDur(0), "0h 0m")
            compare(w.fmtDur(3600), "1h 0m")
            compare(w.fmtDur(3661), "1h 1m")
            compare(w.fmtDur(5400), "1h 30m")
            compare(w.fmtDur(45 * 60), "0h 45m")
        }
    }

    // ── Invalid / degenerate windows ────────────────────────────────────────
    TestCase {
        name: "EodInvalidWindow"
        when: windowShown
        function init() { tryVerify(function () { return hEod.ready }, 3000); clear(hEod) }
        function patch(o) { hEod.storeCtl.patchSettings("test-instance", o) }

        function test_end_before_start_is_set_hours() {
            var w = hEod.item
            patch({ startHour: 17, endHour: 9 })
            compare(w.frac, 0, "inverted window has frac 0")
            compare(w.remaining, "Enable overnight mode",
                    "inverted window explains how to enable a night shift")
            compare(w.phase, "invalid")
        }
        function test_equal_hours_is_set_hours() {
            var w = hEod.item
            patch({ startHour: 10, endHour: 10 })
            compare(w.frac, 0, "zero-length window has frac 0")
            compare(w.remaining, "Start and end must differ",
                    "zero-length window explains the invalid schedule")
        }
        function test_validHours_flag_tracks_comparison() {
            var w = hEod.item
            patch({ startHour: 9, endHour: 17 })
            compare(w.validHours, true, "9→17 is valid")
            patch({ startHour: 17, endHour: 9 })
            compare(w.validHours, false, "17→9 is invalid")
            patch({ startHour: 22, endHour: 6, allowOvernight: true })
            compare(w.validHours, true, "22→06 is a valid eight-hour overnight shift")
        }
        function test_minute_precision_participates_in_validation() {
            var w = hEod.item
            patch({ startHour: 9, startMinute: 0, endHour: 9, endMinute: 30 })
            compare(w.validHours, true, "09:00 to 09:30 is a valid same-day window")
            patch({ startMinute: 30, endMinute: 0, allowOvernight: true })
            compare(w.validHours, false, "a 23.5-hour wrap is rejected")
            compare(w.remaining, "Overnight window exceeds 12 hours")
        }
        // `stateLabel` is the header's whole vocabulary - six phases, one line
        // each. Two were asserted ("Schedule paused", "Invalid schedule"); the
        // four a user sees on an ordinary configured day were not. The clock is
        // driven through nowOverride so each phase is reached deterministically
        // rather than depending on when the suite happens to run.
        function test_state_label_names_every_phase_data() {
            // 2026-08-05 is a Wednesday (day 3); 2026-08-08 is a Saturday.
            return [
                { tag: "before",   days: "1,2,3,4,5", at: [2026, 7, 5, 7, 0],
                  phase: "before",   label: "Starts later" },
                { tag: "working",  days: "1,2,3,4,5", at: [2026, 7, 5, 12, 0],
                  phase: "working",  label: "Working" },
                { tag: "complete", days: "1,2,3,4,5", at: [2026, 7, 5, 19, 0],
                  phase: "complete", label: "Complete" },
                // A weekend with a weekdays-only schedule: not paused, not
                // invalid, simply not a day this schedule runs.
                { tag: "off-day",  days: "1,2,3,4,5", at: [2026, 7, 8, 12, 0],
                  phase: "off",      label: "Off day" }
            ]
        }
        function test_state_label_names_every_phase(data) {
            var w = hEod.item
            patch({ startHour: 9, endHour: 17, workDays: data.days })
            w.nowOverride = new Date(data.at[0], data.at[1], data.at[2],
                                     data.at[3], data.at[4], 0)
            compare(w.phase, data.phase, data.tag + " is phase " + data.phase)
            compare(w.stateLabel, data.label,
                    "and reads as '" + data.label + "'")
            w.nowOverride = null
        }

        // The six labels must be distinct: a header that says the same thing in
        // two different situations tells the user nothing.
        function test_no_two_phases_share_a_label() {
            var w = hEod.item
            var seen = {}
            var cases = [
                { days: "1,2,3,4,5", at: [2026, 7, 5, 7, 0] },    // before
                { days: "1,2,3,4,5", at: [2026, 7, 5, 12, 0] },   // working
                { days: "1,2,3,4,5", at: [2026, 7, 5, 19, 0] },   // complete
                { days: "1,2,3,4,5", at: [2026, 7, 8, 12, 0] }    // off day
            ]
            for (var i = 0; i < cases.length; i++) {
                patch({ startHour: 9, endHour: 17, workDays: cases[i].days })
                var a = cases[i].at
                w.nowOverride = new Date(a[0], a[1], a[2], a[3], a[4], 0)
                verify(seen[w.stateLabel] === undefined,
                       "'" + w.stateLabel + "' is claimed by phase " + w.phase
                       + " and already by " + seen[w.stateLabel])
                seen[w.stateLabel] = w.phase
                w.nowOverride = null
            }
            // Plus the two already covered elsewhere.
            patch({ startHour: 9, endHour: 17, workDays: "" })
            verify(seen[w.stateLabel] === undefined, "'Schedule paused' is its own label")
            seen[w.stateLabel] = "no-days"
            patch({ startHour: 9, endHour: 9, workDays: "1,2,3,4,5" })
            verify(seen[w.stateLabel] === undefined, "'Invalid schedule' is its own label")
        }

        function test_empty_weekday_selection_is_explicit() {
            var w = hEod.item
            patch({ startHour: 9, endHour: 17, workDays: "" })
            compare(w.hasActiveDays, false)
            compare(w.phase, "no-days")
            compare(w.remaining, "No active weekdays")
            compare(w.stateLabel, "Schedule paused")
        }
    }

    // ── setHours() clamping + 1-hour minimum span ───────────────────────────
    TestCase {
        name: "EodSetHours"
        when: windowShown
        function init() { tryVerify(function () { return hEod.ready }, 3000); clear(hEod) }
        function patch(o) { hEod.storeCtl.patchSettings("test-instance", o) }

        function test_cannot_invert_pushing_start_past_end() {
            var w = hEod.item
            patch({ startHour: 9, endHour: 17 })
            w.setHours(20, 17)   // move start beyond end
            verify(w.endHour > w.startHour, "end stays after start (start=" + w.startHour + " end=" + w.endHour + ")")
        }
        function test_cannot_invert_pulling_end_below_start() {
            var w = hEod.item
            patch({ startHour: 9, endHour: 17 })
            w.setHours(w.startHour, w.startHour - 2)
            verify(w.endHour > w.startHour, "end can't drop to/under start")
        }

        function test_explicit_overnight_mode_allows_direct_controls_to_wrap() {
            var w = hEod.item
            patch({ startHour: 9, endHour: 17, allowOvernight: true })
            w.setHours(22, 6)
            compare(w.startHour, 22)
            compare(w.endHour, 6)
        }
        function test_one_hour_min_span_start_yields() {
            var w = hEod.item
            patch({ startHour: 16, endHour: 17 })
            w.setHours(17, 17)   // press Start+ into end
            compare(w.startHour, 16, "Start+ at the 1h floor keeps start at 16")
            compare(w.endHour, 17, "end unchanged")
        }
        function test_one_hour_min_span_end_yields() {
            var w = hEod.item
            patch({ startHour: 16, endHour: 17 })
            w.setHours(16, 16)   // press End- into start
            compare(w.endHour, 17, "End- at the 1h floor keeps end at 17")
            compare(w.startHour, 16, "start unchanged")
        }
        function test_setHours_clamps_upper_bounds() {
            var w = hEod.item
            w.setHours(25, 30)   // both out of range high
            compare(w.startHour, 23, "start clamps to 23")
            compare(w.endHour, 24, "end clamps to 24")
        }
        function test_setHours_clamps_lower_bounds() {
            var w = hEod.item
            w.setHours(-3, 5)    // start below 0
            compare(w.startHour, 0, "start clamps to 0")
            compare(w.endHour, 5, "end unchanged")
        }
        function test_setHours_clamps_end_high() {
            var w = hEod.item
            w.setHours(5, 100)
            compare(w.startHour, 5)
            compare(w.endHour, 24, "end clamps to 24")
        }
    }

    // ── endHour = 24 → next-day 00:00, full-day window ──────────────────────
    TestCase {
        name: "EodFullDay"
        when: windowShown
        function init() {
            tryVerify(function () { return hEod.ready }, 3000)
            clear(hEod)
            hEod.item.nowOverride = new Date(2026, 0, 15, 12, 0, 0, 0)
        }
        function cleanup() { hEod.item.nowOverride = null }
        function patch(o) { hEod.storeCtl.patchSettings("test-instance", o) }

        function test_full_day_window_is_valid() {
            var w = hEod.item
            patch({ startHour: 0, endHour: 24 })
            verify(w.frac > 0 && w.frac < 1,
                   "a 00:00–24:00 window produces a mid-day frac in (0,1) (got " + w.frac + ")")
            verify(w.remaining !== "Start and end must differ" && w.remaining !== "Complete",
                   "full-day window shows a live remaining (got '" + w.remaining + "')")
        }
    }

    // ── BUG: out-of-range hours from the config stepper corrupt the window ──
    // The number stepper writes startHour/endHour straight into the store,
    // bypassing setHours()'s clamp; the widget must still refuse to break.
    TestCase {
        name: "EodConfigStepperRange"
        when: windowShown
        function init() { tryVerify(function () { return hEod.ready }, 3000); clear(hEod) }
        function patch(o) { hEod.storeCtl.patchSettings("test-instance", o) }

        function test_start_hour_25_is_clamped_not_stored_raw() {
            var w = hEod.item
            patch({ startHour: 25, endHour: 17 })   // as the stepper would write it
            verify(w.startHour >= 0 && w.startHour <= 23,
                   "a config-set startHour must be clamped to 0..23 (got " + w.startHour + ")")
        }
        function test_start_hour_25_does_not_silently_break_window() {
            var w = hEod.item
            patch({ startHour: 25, endHour: 17 })
            // setHours(25) normalises to tomorrow 01:00, dropping the window behind
            // the end and stranding the widget on 'Set hours' for plausible values.
            verify(w.remaining !== "Set hours",
                   "plausible-looking editor hours must not strand the widget (remaining='" + w.remaining + "')")
        }
        function test_negative_start_hour_is_clamped() {
            var w = hEod.item
            patch({ startHour: -1, endHour: 17 })
            verify(w.startHour >= 0,
                   "a config-set startHour must clamp at 0, not go negative (got " + w.startHour + ")")
        }
        function test_end_hour_100_is_clamped() {
            var w = hEod.item
            patch({ startHour: 9, endHour: 100 })
            verify(w.endHour <= 24,
                   "a config-set endHour must be clamped to <=24 (got " + w.endHour + ")")
        }
    }

    // ── Reactivity: schema keys + Manager control socket ────────────────────
    TestCase {
        name: "EodReactivity"
        when: windowShown
        function init() { tryVerify(function () { return hEod.ready }, 3000); clear(hEod) }
        function patch(o) { hEod.storeCtl.patchSettings("test-instance", o) }
        function set(k, v) { hEod.storeCtl.setSetting("test-instance", k, v) }

        function test_showPercent_honored() {
            var w = hEod.item
            set("showPercent", false); compare(w.showPercent, false, "showPercent off")
            set("showPercent", true);  compare(w.showPercent, true, "showPercent on")
        }
        function test_progressStyle_honored() {
            var w = hEod.item
            set("progressStyle", "ring"); compare(w.progressStyle, "ring")
            set("progressStyle", "bar");  compare(w.progressStyle, "bar")
        }
        function test_startEnd_hours_reactive_via_patch() {
            var w = hEod.item
            patch({ startHour: 8, endHour: 16 })
            compare(w.startHour, 8); compare(w.endHour, 16)
        }
        function test_control_socket_applyExternal_updates_cfg() {
            var w = hEod.item
            var doc = {
                version: 1,
                appearance: { themeMode: "oled", accent: "blue" },
                pages: [ { name: "Pushed", tiles: [ { id: "test-instance", type: "eod" } ] } ],
                settings: { "test-instance": { startHour: 7, endHour: 15, progressStyle: "ring", showPercent: false } }
            }
            var before = hEod.storeCtl.revision
            verify(hEod.storeCtl.applyExternal(JSON.stringify(doc)), "control-socket doc accepted")
            verify(hEod.storeCtl.revision > before, "revision bumped for reactivity")
            compare(w.startHour, 7, "pushed startHour picked up live")
            compare(w.endHour, 15, "pushed endHour picked up live")
            compare(w.progressStyle, "ring", "pushed progressStyle picked up live")
            compare(w.showPercent, false, "pushed showPercent picked up live")
        }
    }

    // ── Rendered display: percent caption, bar vs ring, accent recolour ─────
    TestCase {
        name: "EodDisplay"
        when: windowShown
        function init() {
            tryVerify(function () { return hEod.ready }, 3000)
            clear(hEod)
            hEod.item.accentName = ""
        }
        function patch(o) { hEod.storeCtl.patchSettings("test-instance", o) }

        function test_showPercent_toggles_caption_node() {
            var w = hEod.item
            patch({ startHour: 9, endHour: 17, progressStyle: "bar", showPercent: true })
            verify(visibleTextContains(w, "% elapsed") !== null,
                   "elapsed and remaining caption visible when showPercent on")
            patch({ showPercent: false })
            verify(visibleTextContains(w, "% elapsed") === null,
                   "elapsed and remaining caption hidden when showPercent off")
        }

        function test_progressStyle_switches_bar_and_ring() {
            var w = hEod.item
            patch({ startHour: 9, endHour: 17, progressStyle: "bar" })
            verify(visibleRing(w) === null, "no ring in bar mode")
            patch({ progressStyle: "ring" })
            verify(visibleRing(w) !== null, "ring shown in ring mode")
        }

        // The primary time text must honour a per-instance accent in BOTH modes.
        function test_time_text_uses_effAccent_in_bar_mode() {
            var w = hEod.item
            patch({ startHour: 9, endHour: 17, progressStyle: "bar" })
            w.accentName = "pink"
            var t = heroText(w)
            verify(t !== null, "found the visible remaining text (bar)")
            compare(t.text, w.remaining, "bar hero carries the remaining-time value")
            compare(String(t.color), String(w.effAccent),
                    "bar-mode time text is recoloured by effAccent")
        }
        // BUG (low): ring-mode centre time uses theme.textPrimary, not effAccent.
        function test_time_text_uses_effAccent_in_ring_mode() {
            var w = hEod.item
            patch({ startHour: 9, endHour: 17, progressStyle: "ring" })
            w.accentName = "pink"
            var t = heroText(w)
            verify(t !== null, "found the visible ring-centre remaining text")
            compare(t.text, w.remaining, "ring hero carries the remaining-time value")
            compare(String(t.color), String(w.effAccent),
                    "ring-mode time text should also honour effAccent")
        }

        // BUG (low): caption renders '9:00' / '24:00'; the editor renders '09:00'.
        function test_caption_hours_match_editor_zero_padding() {
            var w = hEod.item
            patch({ startHour: 9, endHour: 17, progressStyle: "bar", showPercent: true })
            var cap = visibleTextContains(w, "% elapsed")
            verify(cap !== null, "percent caption present")
            // What the on-device config editor renders for the same startHour:
            cfStore.setSetting("cf-inst", "startHour", 9)
            var editorStart = cfHour.numStr()          // "09:00"
            compare(editorStart, "09:00", "sanity: editor zero-pads the hour")
            verify(cap.text.indexOf(editorStart) >= 0,
                   "caption must format hours like the editor (caption='" + cap.text + "')")
        }
    }

    // ── BUG: long remaining strings overflow the collapsed tile ─────────────
    TestCase {
        name: "EodOverflow"
        when: windowShown
        function init() {
            tryVerify(function () { return hCollapsed.ready }, 3000)
            clear(hCollapsed)
            hCollapsed.item.nowOverride = null
        }
        function cleanup() { hCollapsed.item.nowOverride = null }
        function patch(o) { hCollapsed.storeCtl.patchSettings("test-instance", o) }

        function test_starts_in_string_fits_collapsed_tile() {
            var w = hCollapsed.item
            patch({ startHour: 23, endHour: 24 })
            w.nowOverride = new Date(2026, 0, 15, 0, 0, 0, 0)
            compare(w.remaining, "Starts in 23h 0m", "setup produces the longest same-day countdown")
            var t = visibleTextEq(w, w.remaining)
            verify(t !== null, "found the visible remaining text")
            verify(t.paintedWidth <= hCollapsed.width,
                   "remaining text must fit the " + hCollapsed.width + "px tile (painted "
                   + Math.round(t.paintedWidth) + "px for '" + w.remaining + "')")
        }
        function test_set_hours_string_fits_collapsed_tile() {
            var w = hCollapsed.item
            patch({ startHour: 17, endHour: 9 })
            compare(w.remaining, "Enable overnight mode")
            var t = visibleTextEq(w, "Enable overnight mode")
            verify(t !== null, "found the overnight guidance")
            verify(t.paintedWidth <= hCollapsed.width,
                   "overnight guidance must fit the " + hCollapsed.width + "px tile (painted "
                   + Math.round(t.paintedWidth) + "px)")
        }
    }

    // ── Touch targets: Start/End pills ≥44px and fit the expanded tile ──────
    TestCase {
        name: "EodTouchTargets"
        when: windowShown
        function init() { tryVerify(function () { return hEod.ready }, 3000); clear(hEod) }
        function patch(o) { hEod.storeCtl.patchSettings("test-instance", o) }

        function test_four_pills_present_and_tall_enough() {
            var w = hEod.item
            patch({ startHour: 9, endHour: 17 })   // valid window keeps the row meaningful
            var ps = pills(w)
            compare(ps.length, 4, "Start −/+ and End −/+ pills are present")
            for (var i = 0; i < ps.length; i++)
                verify(ps[i].height >= 44,
                       "pill '" + ps[i].label + "' meets the 44px min (got " + ps[i].height + ")")
        }
        function test_pills_fit_within_tile_width() {
            var w = hEod.item
            patch({ startHour: 9, endHour: 17 })
            var ps = pills(w)
            var minX = 1e9, maxX = -1e9
            for (var i = 0; i < ps.length; i++) {
                var p = ps[i].mapToItem(w, 0, 0)
                minX = Math.min(minX, p.x)
                maxX = Math.max(maxX, p.x + ps[i].width)
            }
            verify(maxX - minX <= w.width,
                   "the four pills span <= tile width (span " + Math.round(maxX - minX)
                   + "px vs " + w.width + "px)")
        }
    }

    // ── BUG/limitation: cross-midnight (night-shift) windows ────────────────
    TestCase {
        name: "EodCrossMidnight"
        when: windowShown
        function init() { tryVerify(function () { return hEod.ready }, 3000); clear(hEod) }
        function patch(o) { hEod.storeCtl.patchSettings("test-instance", o) }

        function test_overnight_window_is_representable_or_signposted() {
            var w = hEod.item
            patch({ startHour: 22, endHour: 6 })   // 22:00 → 06:00 overnight shift
            compare(w.frac, 0)
            compare(w.remaining, "Enable overnight mode",
                    "a disabled overnight window gives an actionable explanation")
            compare(w.stateLabel, "Invalid schedule")
        }
    }

    // ── Overnight window selection, driven by a deterministic injected "now" ─
    // A 22:00→06:00 night shift must resolve to the candidate window that
    // actually CONTAINS "now": [yesterday 22:00, today 06:00] after midnight and
    // [today 22:00, tomorrow 06:00] before. `nowOverride` is a test seam feeding
    // frac/remaining a fixed Date so this is checked without the wall clock.
    TestCase {
        name: "EodOvernightDeterministic"
        when: windowShown
        function init() {
            tryVerify(function () { return hEod.ready }, 3000)
            clear(hEod)
            hEod.item.nowOverride = null
        }
        function cleanup() { hEod.item.nowOverride = null }   // never leak the seam
        function patch(o) { hEod.storeCtl.patchSettings("test-instance", o) }
        function at(y, mo, d, h) { return new Date(y, mo, d, h, 0, 0, 0) }

        // Sanity: the seam actually drives the derived properties.
        function test_now_override_drives_frac() {
            var w = hEod.item
            patch({ startHour: 9, endHour: 17 })
            w.nowOverride = at(2026, 0, 15, 13)             // 13:00, 4h into a 9→17 day
            fuzzyCompare(w.frac, 0.5, 0.001)               // (13-9)/(17-9)
            compare(w.remaining, "4h 0m", "daytime window shows live remaining")
        }

        // Pre-midnight half of the overnight shift: in-window, ~7h left.
        function test_overnight_23h_is_in_window_seven_hours_left() {
            var w = hEod.item
            patch({ startHour: 22, endHour: 6, allowOvernight: true })
            w.nowOverride = at(2026, 0, 15, 23)            // 23:00 → [today22, tmrw06]
            fuzzyCompare(w.frac, 1 / 8, 0.001)             // 1h of an 8h window
            compare(w.remaining, "7h 0m", "23:00 → 7h until 06:00")
            verify(w.remaining.indexOf("Starts") !== 0, "must not be a 'Starts in' countdown")
        }

        // THE BUG: after midnight, mid-shift. Old code anchored start on today
        // (03:00 < today-22:00) → "Starts in 19h" + 0%. Correct: [yest22, today06].
        function test_overnight_03h_after_midnight_is_in_window() {
            var w = hEod.item
            patch({ startHour: 22, endHour: 6, allowOvernight: true })
            w.nowOverride = at(2026, 0, 15, 3)             // 03:00 → [yest22, today06]
            fuzzyCompare(w.frac, 5 / 8, 0.001)             // 5h of an 8h window ≈ 62%
            compare(w.remaining, "3h 0m", "03:00 → 3h until 06:00")
            verify(w.remaining.indexOf("Starts") !== 0,
                   "after-midnight mid-shift must NOT show 'Starts in' (got '" + w.remaining + "')")
        }

        // After the shift ends: next window is [today22, tmrw06] → "Starts in".
        function test_overnight_07h_after_shift_counts_down_to_next() {
            var w = hEod.item
            patch({ startHour: 22, endHour: 6, allowOvernight: true })
            w.nowOverride = at(2026, 0, 15, 7)             // 07:00, shift ended at 06:00
            compare(w.frac, 0, "outside the window frac is 0")
            compare(w.remaining, "Starts in 15h 0m", "07:00 → 15h until the next 22:00 start")
        }

        // Just before the shift: "Starts in ~1h".
        function test_overnight_21h_before_shift_counts_down() {
            var w = hEod.item
            patch({ startHour: 22, endHour: 6, allowOvernight: true })
            w.nowOverride = at(2026, 0, 15, 21)            // 21:00, 1h before start
            compare(w.frac, 0, "before the window frac is 0")
            compare(w.remaining, "Starts in 1h 0m", "21:00 → 1h until 22:00")
        }
    }

    // ── Calendar/DST semantics ─────────────────────────────────────
    TestCase {
        name: "EodDST"
        when: windowShown
        function init() {
            tryVerify(function () { return hEod.ready }, 3000)
            clear(hEod)
            hEod.item.nowOverride = null
        }
        function cleanup() { hEod.item.nowOverride = null }

        function test_full_day_uses_calendar_endpoints_across_offset_changes() {
            var w = hEod.item
            hEod.storeCtl.patchSettings("test-instance", { startHour: 0, endHour: 24 })

            // Discover a local UTC-offset transition instead of assuming a named
            // timezone. Europe/Vienna exercises the 23/25-hour path; UTC and zones
            // without DST exercise the same calendar-endpoint contract on 24 hours.
            var day = null
            for (var i = 0; i < 365; i++) {
                var candidate = new Date(2026, 0, 1 + i, 0, 0, 0, 0)
                var next = new Date(candidate.getFullYear(), candidate.getMonth(),
                                    candidate.getDate() + 1, 0, 0, 0, 0)
                if (candidate.getTimezoneOffset() !== next.getTimezoneOffset()) {
                    day = candidate
                    break
                }
            }
            if (day === null)
                day = new Date(2026, 0, 15, 0, 0, 0, 0)

            var noon = new Date(day.getFullYear(), day.getMonth(), day.getDate(), 12, 0, 0, 0)
            w.nowOverride = noon
            var bounds = w.windowBounds(noon)
            var start = bounds[0], end = bounds[1]
            var expectedStart = new Date(day.getFullYear(), day.getMonth(), day.getDate(),
                                         0, 0, 0, 0)
            var expectedEnd = new Date(day.getFullYear(), day.getMonth(), day.getDate(),
                                       24, 0, 0, 0)
            compare(start.valueOf(), expectedStart.valueOf(),
                    "start uses the configured local calendar endpoint")
            compare(end.valueOf(), expectedEnd.valueOf(),
                    "endHour=24 uses the following local calendar endpoint")

            // Calendar construction naturally yields 23/25 hours over DST and
            // also handles the rarer zones whose transition happens at midnight.
            var expectedHours = (expectedEnd - expectedStart) / 3600000
            verify(expectedHours >= 22 && expectedHours <= 26,
                   "a local calendar day remains within a sane transition range")
            compare((end - start) / 3600000, expectedHours,
                    "absolute duration accounts for any local UTC-offset change")
            fuzzyCompare(w.frac, (noon - start) / (end - start), 0.001,
                         "progress uses the real calendar-day duration")
        }
    }

    // ── Shared config schema surface (instantiated directly) ────────────────
    TestCase {
        name: "EodSchema"
        when: windowShown

        function hourFields() {
            var s = schema.schemaFor("eod")
            var out = []
            for (var j = 0; j < s.sections.length; j++)
                for (var k = 0; k < (s.sections[j].fields || []).length; k++)
                    if (s.sections[j].fields[k].type === "hour")
                        out.push(s.sections[j].fields[k])
            return out
        }

        function test_eod_schema_exposes_start_and_end_hour() {
            var hs = hourFields()
            var keys = hs.map(function (f) { return f.key })
            verify(keys.indexOf("startHour") >= 0, "schema exposes startHour")
            verify(keys.indexOf("endHour") >= 0, "schema exposes endHour")
        }
        function test_eod_schema_exposes_display_keys() {
            var s = schema.schemaFor("eod")
            var keys = []
            for (var j = 0; j < s.sections.length; j++)
                for (var k = 0; k < (s.sections[j].fields || []).length; k++)
                    keys.push(s.sections[j].fields[k].key)
            verify(keys.indexOf("progressStyle") >= 0, "schema exposes progressStyle")
            verify(keys.indexOf("showPercent") >= 0, "schema exposes showPercent")
            verify(keys.indexOf("startMinute") >= 0, "schema exposes startMinute")
            verify(keys.indexOf("endMinute") >= 0, "schema exposes endMinute")
            verify(keys.indexOf("allowOvernight") >= 0, "schema exposes allowOvernight")
            verify(keys.indexOf("workDays") >= 0, "schema exposes workDays")
            var workDays = null
            for (var n = 0; n < s.sections.length; n++)
                for (var m = 0; m < (s.sections[n].fields || []).length; m++)
                    if (s.sections[n].fields[m].key === "workDays")
                        workDays = s.sections[n].fields[m]
            verify(workDays !== null)
            compare(workDays.type, "weekdays",
                    "active weekdays use explicit touch controls instead of CSV")
        }
        // BUG (medium): the hour fields omit min/max, so the stepper can drive
        // startHour/endHour out of 0..24 and corrupt the window.
        function test_hour_fields_declare_min_and_max() {
            var hs = hourFields()
            verify(hs.length >= 2, "found both hour fields")
            for (var i = 0; i < hs.length; i++) {
                verify(hs[i].min !== undefined,
                       "hour field '" + hs[i].key + "' must declare a min to bound the stepper")
                verify(hs[i].max !== undefined,
                       "hour field '" + hs[i].key + "' must declare a max to bound the stepper")
            }
        }
    }

    // ── Per-sizeClass structure (W1 wave 2a) ────────────────────────────────
    // Fixed-size hosts at real projected cell footprints.
    Item { width: 344; height: 416
        WidgetHarness { id: hMicro; anchors.fill: parent; widgetFile: "EndOfDayWidget.qml"; expanded: false } }
    Item { id: wideWrap; width: 696; height: 416
        WidgetHarness { id: hWide; anchors.fill: parent; widgetFile: "EndOfDayWidget.qml"; expanded: false } }
    Item { width: 344; height: 840
        WidgetHarness { id: hTall; anchors.fill: parent; widgetFile: "EndOfDayWidget.qml"; expanded: false } }
    // The exact constrained portrait projection used by the legibility matrix
    // at 125% output scaling.
    Item { width: 278; height: 654
        WidgetHarness { id: hTightTall; anchors.fill: parent; widgetFile: "EndOfDayWidget.qml"; expanded: false } }
    Item { width: 696; height: 819
        WidgetHarness { id: hBase; anchors.fill: parent; widgetFile: "EndOfDayWidget.qml"; expanded: false } }
    // The OVERLAY, at the two boxes Dashboard actually gives it: the live-preview
    // pane beside the config form, ~941x456 landscape and ~656x980 portrait.
    // `expanded: true` AND sizeClass "full" - the real pairing - because a
    // mode-keyed literal can only be caught with the mode switched ON.
    Item { width: 941; height: 456
        WidgetHarness { id: hOvlL; anchors.fill: parent; widgetFile: "EndOfDayWidget.qml"; expanded: true } }
    Item { width: 656; height: 980
        WidgetHarness { id: hOvlP; anchors.fill: parent; widgetFile: "EndOfDayWidget.qml"; expanded: true } }

    TestCase {
        name: "EodSizes"
        when: windowShown

        function prep(h) {
            var s = h.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            h.storeCtl._touchSettings()
            h.storeCtl.patchSettings("test-instance",
                { startHour: 9, endHour: 17, progressStyle: "bar", showPercent: true })
        }

        // 0.5x0.5 - headerless: the remaining time + a slim bar, no caption.
        function test_micro_is_time_plus_bar() {
            tryVerify(function () { return hMicro.ready }, 3000)
            prep(hMicro)
            var w = hMicro.item
            w.sizeClass = "compact"
            compare(w.micro, true, "a 344x416 compact box is the micro tile")
            compare(w.showHeader, false, "micro hides the header")
            verify(visibleTextEq(w, w.remaining) !== null, "the remaining time is the tile")
            verify(visibleTextContains(w, "% elapsed") === null, "micro drops the caption")
            verify(visibleTextEq(w, "Start") === null, "micro has no detail column")
        }

        // wide - remaining/caption beside the progress; the ring style is
        // honoured outside the overlay.
        function test_wide_honours_ring_style() {
            tryVerify(function () { return hWide.ready }, 3000)
            prep(hWide)
            var w = hWide.item
            w.sizeClass = "wide"
            compare(w.horiz, true, "wide goes side-by-side")
            verify(visibleRing(w) === null, "bar style: no ring")
            verify(visibleTextContains(w, "% elapsed") !== null, "wide keeps the caption")
            hWide.storeCtl.setSetting("test-instance", "progressStyle", "ring")
            compare(w.useRing, true, "ring style is honoured on a wide TILE")
            verify(visibleRing(w) !== null, "the ring renders")
            verify(visibleTextEq(w, w.remaining) !== null,
                   "wide keeps the remaining time beside the ring (percent lives in the ring)")
            wideWrap.width = 840; wideWrap.height = 344
            compare(w.horiz, true, "the landscape projection stays side-by-side")
            wideWrap.width = 696; wideWrap.height = 416
        }

        // tall - the detail column spells the workday out and replaces the caption.
        function test_tall_earns_detail_column() {
            tryVerify(function () { return hTall.ready }, 3000)
            prep(hTall)
            var w = hTall.item
            w.sizeClass = "tall"
            compare(w.tallish, true, "tall is the roomy class")
            verify(visibleTextEq(w, "Start") !== null, "Start row rendered")
            verify(visibleTextEq(w, "End") !== null, "End row rendered")
            verify(visibleTextEq(w, "Elapsed") !== null, "Elapsed row rendered")
            verify(visibleTextEq(w, "Remaining") !== null, "Remaining row rendered")
            verify(visibleTextEq(w, "09:00") !== null, "start hour spelled out, editor-padded")
            verify(visibleTextContains(w, "% elapsed") === null, "the detail column replaces the caption")
            // Done row honours showPercent.
            var doneRow = objectNamed(w, "eodDetailRow-done")
            verify(doneRow !== null, "Done detail row exists")
            verify(effVisible(doneRow, w), "Done row rendered while showPercent on")
            hTall.storeCtl.setSetting("test-instance", "showPercent", false)
            verify(!effVisible(doneRow, w), "Done row honours showPercent=false")
            hTall.storeCtl.setSetting("test-instance", "showPercent", true)
            // Ring style on tall: the remaining time moves INTO the ring.
            hTall.storeCtl.setSetting("test-instance", "progressStyle", "ring")
            compare(w.timeInRing, true, "tall ring carries the time in its centre")
            verify(visibleRing(w) !== null, "the ring renders")
            w.sizeClass = "full"
            compare(w.micro, false, "full is never micro")
        }

        function test_constrained_tall_header_keeps_title_and_accessible_state() {
            tryVerify(function () { return hTightTall.ready }, 3000)
            prep(hTightTall)
            var w = hTightTall.item
            w.sizeClass = "tall"
            hTightTall.theme.textScale = 1.45
            wait(0)

            compare(w.narrowHeader, true)
            compare(w.headerStateLabel, w.conciseStateLabel)
            var title = visibleTextEq(w, "End of Day")
            verify(title !== null, "the complete title remains visible")
            verify(!title.truncated,
                   "the title is not elided at the largest supported type scale")
            verify(title.paintedWidth <= title.width + 0.5,
                   "the title fits inside its assigned header width")
            verify(w.Accessible.name.indexOf(w.stateLabel) >= 0,
                   "the full state remains in the widget's accessible summary")

            hTightTall.theme.textScale = 1.15
        }

        // ── size, not mode ──────────────────────────────────────────────────
        // rowSpacing, the bar's height, the ring, the hero time and the caption
        // were all keyed off `expanded`. Catching that class needs the mode held
        // FIXED while only the room moves: anything that changes is genuinely
        // sized by its box, anything that does not is still reading the mode.
        //
        // The two hosts are a 344x819 TALL tile and a 696x819 BASELINE - both
        // expanded:false, both non-micro. That pairing is deliberate: the old
        // literals had a micro-aware ELSE branch (`micro ? 64 : 52`,
        // `micro ? 8 : 10`), so a tall-vs-micro comparison passes even against
        // the buggy code - the two boxes differ only in the micro flag, which the
        // else branch reads too. tall-vs-baseline strips that out: with the mode
        // literal restored both collapse to the same non-micro else value (hero
        // 52, rowSpacing 6), so the assertions below go red exactly when the bug
        // is present. (Verified by restoring `w.expanded ? 80` and
        // `rowSpacing: w.expanded ? 14 : 6` - this test failed, the overlay test
        // stayed green; see the report.)
        function test_sizing_follows_the_room_while_the_mode_is_held_fixed() {
            tryVerify(function () { return hTall.ready && hBase.ready }, 3000)
            prep(hTall); prep(hBase)
            var tall = hTall.item; tall.sizeClass = "tall"
            var base = hBase.item; base.sizeClass = "compact"
            wait(16)
            compare(tall.expanded, false, "precondition: neither host is the overlay")
            compare(base.expanded, false, "…including the roomy one")
            compare(tall.roomy, true, "…and 'tall' is the roomy class")
            compare(base.roomy, false, "…while the baseline third is not")
            compare(base.micro, false, "…and the baseline is NOT micro (so the old "
                    + "literal's micro-aware else branch cannot rescue it)")

            // The RENDERED hero time, not the property that feeds it: a Text that
            // ignored the binding and re-froze a literal would sail through a
            // property-only check. Both boxes are non-micro, so the old
            // `micro ? 64 : 52` else branch gives BOTH 52 - only the box-derived
            // term separates them.
            var th = heroText(tall)
            var bh = heroText(base)
            verify(th && bh, "both hero times resolve")
            verify(th.font.pixelSize > bh.font.pixelSize,
                   "the hero time follows the room (" + th.font.pixelSize
                   + " on a tall tile vs " + bh.font.pixelSize + " on the baseline)")

            // The rendered GridLayout's own spacing (mode literal → 6 for both).
            var tg = root.collect(tall, []).filter(function (n) {
                return n.hasOwnProperty("rowSpacing") && n.hasOwnProperty("columnSpacing") })[0]
            var bg = root.collect(base, []).filter(function (n) {
                return n.hasOwnProperty("rowSpacing") && n.hasOwnProperty("columnSpacing") })[0]
            verify(tg.rowSpacing > bg.rowSpacing,
                   "a tall tile gets more air between its rows (" + tg.rowSpacing
                   + " vs " + bg.rowSpacing + ")")
        }

        // The overlay is a size class like any other, and its box is the one it is
        // actually given. This is the test that catches a mode-keyed literal, and
        // the ONLY shape that can: the sibling test above holds the mode fixed at
        // false, where a surviving `w.expanded ? 80 : <derived>` never fires its
        // literal at all and the derived branch keeps the assertion green.
        //
        // Both hosts are expanded AND "full"; only the BOX differs - the real
        // live-preview panes beside the config form (Dashboard: 38% of the width
        // in landscape, a stacked band in portrait), NOT a 2560x720 screen. A
        // literal returns one number for both, so asserting the two differ is
        // exactly the mode/size conflation, caught.
        function test_overlay_is_sized_by_its_pane_not_by_a_mode_literal() {
            tryVerify(function () { return hOvlL.ready && hOvlP.ready }, 3000)
            prep(hOvlL); prep(hOvlP)
            var land = hOvlL.item; land.sizeClass = "full"
            var port = hOvlP.item; port.sizeClass = "full"
            // A real event-loop turn, not wait(0): these hosts default to "tall"
            // (height > 240) and only become "full" on the lines above; wait(0)
            // returns BEFORE the layout re-polishes and a rendered read then
            // reports pre-change geometry. waitForRendering is not the tool -
            // offscreen never swaps a frame.
            wait(16)
            compare(land.expanded, true, "precondition: this IS the overlay")
            compare(port.expanded, true, "…and so is this one")
            compare(land.roomy, true, "…and 'full' is roomy")

            verify(land.remainingPx !== port.remainingPx,
                   "the overlay's hero time is sized by the pane it is given, not by "
                   + "one literal for 'the overlay' (941x456 -> "
                   + land.remainingPx.toFixed(1) + ", 656x980 -> "
                   + port.remainingPx.toFixed(1) + ")")
            verify(port.remainingPx > land.remainingPx,
                   "the 980-tall pane earns the bigger number ("
                   + port.remainingPx.toFixed(1) + " > " + land.remainingPx.toFixed(1) + ")")
            verify(port.ringPx > land.ringPx,
                   "…and the bigger ring (" + port.ringPx.toFixed(1) + " > "
                   + land.ringPx.toFixed(1) + ")")

            // RENDERED, not merely derived: the Text actually carries it.
            var t = heroText(land)
            verify(t !== null, "the landscape pane's remaining time resolves")
            compare(t.text, land.remaining, "the landscape hero carries the remaining-time value")
            compare(t.font.pixelSize, Math.round(land.remainingPx),
                    "the rendered hero is the derived size, not a re-frozen literal")

            // And the caption follows the hero it annotates rather than the mode.
            var capL = visibleTextContains(land, "% elapsed")
            var capP = visibleTextContains(port, "% elapsed")
            verify(capL && capP, "both panes render the caption")
            verify(capP.font.pixelSize > capL.font.pixelSize,
                   "the caption is sized by the pane too (" + capP.font.pixelSize
                   + " vs " + capL.font.pixelSize + ")")

            // The hero still FITS the pane it was sized for - the structural
            // guarantee, not glyph ink (headless font metrics are meaningless).
            verify(t.width <= land.width + 0.51,
                   "the hero stays inside the landscape pane (" + t.width.toFixed(0)
                   + " in " + land.width + ")")
        }

        // invalid hours - the detail column must not render a bogus workday.
        function test_tall_detail_hidden_when_invalid() {
            tryVerify(function () { return hTall.ready }, 3000)
            prep(hTall)
            var w = hTall.item
            w.sizeClass = "tall"
            hTall.storeCtl.patchSettings("test-instance", { startHour: 17, endHour: 9 })
            compare(w.remaining, "Enable overnight mode", "invalid window shows the hint")
            verify(visibleTextEq(w, "Start") === null, "no detail rows for an invalid window")
        }
    }

    // ── ConfigField hour rendering (shared component, instantiated directly) ─
    TestCase {
        name: "EodConfigField"
        when: windowShown

        function test_hour_numStr_zero_pads_single_digit() {
            cfStore.setSetting("cf-inst", "startHour", 9)
            compare(cfHour.numStr(), "09:00", "single-digit hour is zero-padded")
        }
        function test_hour_numStr_two_digit() {
            cfStore.setSetting("cf-inst", "startHour", 17)
            compare(cfHour.numStr(), "17:00", "two-digit hour is unpadded")
        }
    }
}
