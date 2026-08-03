import QtQuick
import QtTest


// ─────────────────────────────────────────────────────────────────────────
// Comprehensive coverage for widget:break - ui/qml/widgets/BreakWidget.qml.
//
// Drives the SAME persistent store contract the Dashboard uses (via the
// WidgetHarness). Verifies every config option, the remaining/countdown math,
// the ±5m / reset / take-break / pause-resume actions, interval reseeding,
// accent theming, and the daily-momentum counter.
//
// Some assertions target audited bugs and are EXPECTED to fail until the code
// under test is fixed - those are called out in comments as "REAL BUG".
// ─────────────────────────────────────────────────────────────────────────
Item {
    id: root
    width: 720; height: 900
    property int notificationCalls: 0
    property string notificationSummary: ""
    property string notificationBody: ""
    QtObject {
        id: fakeNotifications
        function send(summary, body) {
            root.notificationCalls++
            root.notificationSummary = summary
            root.notificationBody = body
            return true
        }
    }

    // Expanded instance (buttons + full controls exercised through functions).
    WidgetHarness { id: h; anchors.fill: parent; widgetFile: "BreakWidget.qml"; expanded: true }

    // Fixed-size hosts for the per-sizeClass structure tests (W1) - real
    // projected cell footprints (half-cell ≈ 344x416, full cell ≈ 696x840).
    Item { id: bMicroWrap; width: 344; height: 416
        WidgetHarness { id: hBMicro; anchors.fill: parent; widgetFile: "BreakWidget.qml"; expanded: false } }
    Item { id: bBaseWrap; width: 696; height: 840
        WidgetHarness { id: hBBase; anchors.fill: parent; widgetFile: "BreakWidget.qml"; expanded: false } }
    Item { id: bWideWrap; width: 696; height: 416
        WidgetHarness { id: hBWide; anchors.fill: parent; widgetFile: "BreakWidget.qml"; expanded: false } }
    Item { id: bTallWrap; width: 344; height: 840
        WidgetHarness { id: hBTall; anchors.fill: parent; widgetFile: "BreakWidget.qml"; expanded: false } }

    // Recursively find the first descendant whose `prop` equals `val`.
    function findByProp(node, prop, val) {
        if (!node || !node.children) return null
        for (var i = 0; i < node.children.length; i++) {
            var c = node.children[i]
            if (c[prop] !== undefined && c[prop] === val) return c
            var r = findByProp(c, prop, val)
            if (r) return r
        }
        return null
    }
    // The RingProgress is uniquely identifiable: value + thickness +
    // progressColor + trackColor together.
    function findRing(host) {
        var found = null
        function scan(n) {
            if (!n || found) return
            if (typeof n.value === "number" && typeof n.thickness === "number"
                    && n.progressColor !== undefined && n.trackColor !== undefined)
                { found = n; return }
            for (var i = 0; n.children && i < n.children.length; i++) scan(n.children[i])
        }
        scan(host.item)
        return found
    }

    function clear(hh) {
        var s = hh.storeCtl.settingsFor("test-instance")
        for (var k in s) delete s[k]
        // Timer behavior must not depend on the wall clock of the machine
        // running the suite. Equal start/end means all day in BreakWidget.
        s.workStartHour = 0
        s.workEndHour = 0
        s.workDays = "0,1,2,3,4,5,6"
        hh.storeCtl._touchSettings()
    }
    function cfg() { return h.storeCtl.settingsFor("test-instance") }

    // ── Config options honored ───────────────────────────────────────────
    TestCase {
        name: "BreakConfig"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000); root.clear(h) }

        function test_defaults_from_empty_cfg() {
            var w = h.item
            compare(w.intervalMin, 30, "empty cfg → default 30-min interval")
            compare(w.running, true, "auto-running by default")
            compare(w.due, false, "not due by default")
            compare(w.message, "", "no custom message by default")
            compare(w.showSuggestion, true, "suggestions on by default")
        }
        function test_intervalMin_honored() {
            var w = h.item
            h.storeCtl.setSetting("test-instance", "intervalMin", 60)
            compare(w.intervalMin, 60)
        }
        function test_running_honored() {
            var w = h.item
            h.storeCtl.setSetting("test-instance", "running", false)
            compare(w.running, false)
        }
        function test_due_honored() {
            var w = h.item
            h.storeCtl.setSetting("test-instance", "due", true)
            compare(w.due, true)
        }
        function test_message_honored_and_fallback() {
            var w = h.item
            h.storeCtl.setSetting("test-instance", "message", "Stretch your legs")
            compare(w.message, "Stretch your legs")
            h.storeCtl.setSetting("test-instance", "message", "")
            compare(w.message, "", "empty message falls back to default wording downstream")
        }
        function test_showSuggestion_honored() {
            var w = h.item
            h.storeCtl.setSetting("test-instance", "showSuggestion", false)
            compare(w.showSuggestion, false)
        }
        function test_work_schedule_supports_daytime_and_overnight() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { workStartHour: 9, workEndHour: 17, workDays: "1,2,3,4,5" })
            verify(w.withinScheduleAt(10, 1)); verify(!w.withinScheduleAt(18, 1)); verify(!w.withinScheduleAt(10, 0))
            h.storeCtl.patchSettings("test-instance", { workStartHour: 22, workEndHour: 6, workDays: "1" })
            verify(w.withinScheduleAt(23, 1), "Monday evening starts Monday's shift")
            verify(w.withinScheduleAt(2, 2), "Tuesday morning belongs to Monday's overnight shift")
            verify(!w.withinScheduleAt(2, 1), "Monday morning belongs to Sunday's shift")
            verify(!w.withinScheduleAt(12, 1))
        }
        function test_schedule_schema_uses_structured_weekdays_and_notification_opt_in() {
            var schema = Qt.createQmlObject(
                'import QtQuick; import "../../ui/qml"; WidgetConfigSchema {}', root)
            var sections = schema.schemaFor("break").sections
            var workDays = null
            var notify = null
            for (var i = 0; i < sections.length; i++) {
                var fields = sections[i].fields || []
                for (var j = 0; j < fields.length; j++) {
                    if (fields[j].key === "workDays") workDays = fields[j]
                    if (fields[j].key === "notifyWhenHidden") notify = fields[j]
                }
            }
            verify(workDays !== null)
            compare(workDays.type, "weekdays")
            verify(notify !== null)
            compare(notify.type, "toggle")
            compare(notify.dflt, false, "desktop notifications are explicitly opt-in")
            schema.destroy()
        }
        function test_timer_suspends_outside_schedule_and_resumes_without_losing_time() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", {
                running: true, due: false, intervalMin: 30,
                pausedRemaining: 900, endEpoch: Date.now() + 900000,
                scheduleSuspended: false
            })
            w.applyScheduleState(false)
            compare(root.cfg().scheduleSuspended, true,
                    "leaving the work window suspends the interval")
            compare(root.cfg().endEpoch, 0,
                    "a suspended interval has no wall-clock deadline")
            verify(root.cfg().pausedRemaining >= 898,
                   "the remaining interval is preserved")
            var saved = root.cfg().pausedRemaining
            w.applyScheduleState(true)
            compare(root.cfg().scheduleSuspended, false,
                    "re-entering the work window resumes the interval")
            verify(root.cfg().endEpoch >= Date.now() + (saved - 1) * 1000,
                   "the resumed deadline is based on preserved active time")
        }
    }

    // ── remaining / countdown math ───────────────────────────────────────
    TestCase {
        name: "BreakRemaining"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000); root.clear(h) }

        function test_remaining_from_pausedRemaining_when_paused() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { running: false, due: false, pausedRemaining: 123 })
            w.pulse++
            compare(w.remaining, 123, "paused → reads pausedRemaining")
        }
        function test_remaining_from_endEpoch_when_running() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance",
                { running: true, due: false, endEpoch: Date.now() + 600 * 1000 })
            w.pulse++
            verify(w.remaining >= 598 && w.remaining <= 600, "≈600s from a 10-min endEpoch (got " + w.remaining + ")")
        }
        function test_remaining_zero_when_due() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance",
                { running: true, due: true, endEpoch: Date.now() + 600 * 1000 })
            w.pulse++
            compare(w.remaining, 0, "due forces remaining to 0")
        }
        function test_remaining_clamps_at_zero_after_sleep() {
            // Simulated sleep/resume: wall clock jumped PAST endEpoch.
            var w = h.item
            h.storeCtl.patchSettings("test-instance",
                { running: true, due: false, endEpoch: Date.now() - 5000 })
            w.pulse++
            compare(w.remaining, 0, "past endEpoch never goes negative")
        }
        function test_remaining_fallback_to_interval() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance",
                { running: true, due: false, endEpoch: 0, intervalMin: 30 })
            w.pulse++
            compare(w.remaining, 1800, "running with no endEpoch/pausedRemaining → intervalMin*60")
        }
    }

    // ── fmt() mm:ss formatting ───────────────────────────────────────────
    TestCase {
        name: "BreakFmt"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000) }
        function test_fmt() {
            var w = h.item
            compare(w.fmt(0), "00:00")
            compare(w.fmt(5), "00:05")
            compare(w.fmt(65), "01:05")
            compare(w.fmt(600), "10:00")
            compare(w.fmt(1800), "30:00")
        }
    }

    // ── reset / takeBreak / toggleRun actions ────────────────────────────
    TestCase {
        name: "BreakActions"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000); root.clear(h) }

        function test_reset_seeds_and_clears_due() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { due: true, intervalMin: 20 })
            w.reset()
            compare(root.cfg().due, false, "reset clears due")
            compare(root.cfg().running, true, "reset resumes")
            compare(root.cfg().pausedRemaining, 20 * 60, "reset seeds pausedRemaining to full interval")
            verify(root.cfg().endEpoch > Date.now() + 19 * 60 * 1000, "reset seeds a fresh endEpoch")
        }

        function test_takeBreak_increments_and_stamps_today() {
            var w = h.item
            // Baseline: 2 acknowledged breaks already today.
            h.storeCtl.patchSettings("test-instance",
                { due: true, day: w.todayKey, breaksToday: 2, intervalMin: 30 })
            compare(w.breaksToday, 2, "baseline momentum reads from cfg for today")
            w.takeBreak()
            compare(root.cfg().due, false, "acknowledging clears due")
            compare(root.cfg().breaksToday, 3, "acknowledging increments the daily count")
            compare(root.cfg().day, w.todayKey, "the count is stamped with the CURRENT day")
            verify(root.cfg().endEpoch > Date.now(), "the timer restarts after acknowledging")
        }
        function test_snooze_clears_due_without_counting_break() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { due: true, snoozeMin: 7, day: w.todayKey, breaksToday: 2 })
            w.snooze()
            compare(root.cfg().due, false); compare(root.cfg().breaksToday, 2)
            compare(root.cfg().pausedRemaining, 420)
            compare(root.cfg().snoozed, true, "snooze is a distinct persisted state")
            verify(root.cfg().endEpoch > Date.now() + 6 * 60000)
        }

        function test_pause_preserves_remaining_across_toggle() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance",
                { running: true, due: false, endEpoch: Date.now() + 600 * 1000 })
            w.pulse++
            var before = w.remaining
            verify(before >= 598 && before <= 600, "started ≈600s")
            w.toggleRun()   // pause
            compare(root.cfg().running, false, "paused")
            compare(root.cfg().pausedRemaining, before, "pause snapshots the exact remaining")
            w.toggleRun()   // resume
            compare(root.cfg().running, true, "resumed")
            w.pulse++
            verify(Math.abs(w.remaining - before) <= 2, "remaining survives pause→resume (got " + w.remaining + ")")
        }
    }

    TestCase {
        name: "BreakNotifications"
        when: windowShown
        function init() {
            tryVerify(function () { return h.ready }, 3000)
            root.clear(h)
            h.item.notificationBridge = fakeNotifications
            h.item.foreground = true
            root.notificationCalls = 0
            root.notificationSummary = ""
            root.notificationBody = ""
        }
        function cleanup() { h.item.foreground = true }
        function expire(patch) {
            h.storeCtl.patchSettings("test-instance", Object.assign({
                running: true, due: false, snoozed: false,
                notifyWhenHidden: true,
                endEpoch: Date.now() - 2000
            }, patch || {}))
            h.item.pulse++
        }

        function test_hidden_due_transition_notifies_once() {
            expire()
            h.item.foreground = false
            compare(h.item.markDue(), true)
            compare(root.notificationCalls, 1)
            compare(root.notificationSummary, "Break reminder")
            compare(root.notificationBody,
                    "Time to stand up, reset, and take a short break.")
            compare(h.item.markDue(), false, "an already-due cycle cannot notify twice")
            compare(root.notificationCalls, 1)
        }
        function test_custom_message_is_the_notification_body() {
            expire({ message: "Look away from the screen" })
            h.item.foreground = false
            h.item.markDue()
            compare(root.notificationBody, "Look away from the screen")
        }
        function test_visible_or_opted_out_reminder_does_not_notify() {
            expire()
            h.item.foreground = true
            h.item.markDue()
            compare(root.notificationCalls, 0, "visible due feedback is not duplicated")

            root.clear(h)
            expire({ notifyWhenHidden: false })
            h.item.foreground = false
            h.item.markDue()
            compare(root.notificationCalls, 0, "off-page notification remains opt-in")
        }
        function test_snooze_and_outside_schedule_suppress_due_notification() {
            expire({ snoozed: true, endEpoch: Date.now() + 300000 })
            h.item.foreground = false
            compare(h.item.markDue(), false, "an active snooze is not due")
            compare(root.notificationCalls, 0)

            var excluded = (new Date().getDay() + 1) % 7
            expire({ workDays: String(excluded), endEpoch: Date.now() - 2000 })
            compare(h.item.markDue(), false, "outside-hours expiry is suspended")
            compare(root.notificationCalls, 0)
        }
    }

    // ── setInterval clamping + seeding ───────────────────────────────────
    TestCase {
        name: "BreakSetInterval"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000); root.clear(h) }

        function test_clamp_low() {
            var w = h.item
            h.storeCtl.setSetting("test-instance", "intervalMin", 5)
            w.setInterval(w.intervalMin - 5)   // −5m at the floor
            compare(root.cfg().intervalMin, 5, "−5m at 5 stays 5")
        }
        function test_clamp_high() {
            var w = h.item
            h.storeCtl.setSetting("test-instance", "intervalMin", 120)
            w.setInterval(w.intervalMin + 5)   // +5m at the ceiling
            compare(root.cfg().intervalMin, 120, "+5m at 120 stays 120")
        }
        function test_setInterval_seeds_countdown() {
            var w = h.item
            w.setInterval(45)
            compare(root.cfg().intervalMin, 45)
            compare(root.cfg().pausedRemaining, 45 * 60, "seeds pausedRemaining to the new length")
            verify(root.cfg().endEpoch > Date.now(), "seeds a running endEpoch")
        }
    }

    // ── config-side interval change reseeds via onIntervalMinChanged ─────
    TestCase {
        name: "BreakApplyInterval"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000); root.clear(h) }

        function test_running_interval_reseeds_preserving_running() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { intervalMin: 30, running: true, due: false })
            h.storeCtl.setSetting("test-instance", "intervalMin", 45)
            tryVerify(function () { return root.cfg().pausedRemaining === 45 * 60 }, 2000,
                      "running interval change reseeds to the new length")
            compare(root.cfg().running, true, "still running after a config interval change")
            verify(root.cfg().endEpoch > Date.now(), "endEpoch re-seeded for the running timer")
        }

        function test_paused_interval_reseeds_but_stays_paused() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance",
                { intervalMin: 30, running: false, pausedRemaining: 1800, endEpoch: 12345 })
            h.storeCtl.setSetting("test-instance", "intervalMin", 60)
            tryVerify(function () { return root.cfg().pausedRemaining === 60 * 60 }, 2000,
                      "paused interval change reseeds pausedRemaining")
            compare(root.cfg().running, false, "stays paused")
            compare(root.cfg().endEpoch, 0, "endEpoch cleared while paused")
        }
    }

    // ── Daily momentum counter ───────────────────────────────────────────
    TestCase {
        name: "BreakMomentum"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000); root.clear(h) }

        function test_breaksToday_zero_on_day_mismatch() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { day: "2000-01-01", breaksToday: 5 })
            compare(w.breaksToday, 0, "a stale day resets today's count to 0")
        }
        function test_breaksToday_reads_current_day() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { day: w.todayKey, breaksToday: 4 })
            compare(w.breaksToday, 4, "today's count is honored")
        }
        function test_breakIdeas_present_for_cycling() {
            var w = h.item
            verify(w.breakIdeas.length >= 6, "there are break-activity ideas to cycle through")
            // The suggestion shown is breakIdeas[breaksToday % len]; verify the index math.
            h.storeCtl.patchSettings("test-instance", { day: w.todayKey, breaksToday: 7 })
            compare(w.breaksToday % w.breakIdeas.length, 1, "index wraps around the idea list")
        }
    }

    // ── Accent theming (effAccent) ───────────────────────────────────────
    TestCase {
        name: "BreakAccent"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000) }

        function test_default_accent_is_success() {
            var w = h.item
            w.accentName = ""
            var exp = h.theme.success
            fuzzyCompare(w.effAccent.r, exp.r, 0.02)
            fuzzyCompare(w.effAccent.g, exp.g, 0.02)
            fuzzyCompare(w.effAccent.b, exp.b, 0.02)
        }
        function test_accent_preset_recolours() {
            var w = h.item
            w.accentName = "red"
            var exp = Qt.color(h.theme.accentPresets["red"].a)
            fuzzyCompare(w.effAccent.r, exp.r, 0.02)
            fuzzyCompare(w.effAccent.g, exp.g, 0.02)
            fuzzyCompare(w.effAccent.b, exp.b, 0.02)
            w.accentName = ""   // restore
        }
    }

    // ── ONCE-BROKEN BEHAVIOUR, now pinned ────────────────────────────────
    //    Every case below described a real defect when it was written. All four
    //    were fixed; verified 2026-08-03, when the whole block was green. They
    //    stay as regression guards, and each states the defect it prevents. 
    TestCase {
        name: "BreakBugs"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000); root.clear(h) }

        // WAS BROKEN (high), now pinned. The defect was: a freshly-added, auto-running reminder never seeds endEpoch
        // (Component.onCompleted runs before the store is injected), so the
        // countdown is frozen at intervalMin*60 and never fires.
        function test_fresh_instance_seeds_endEpoch() {
            var w = h.item
            compare(w.running, true, "fresh reminder is auto-running")
            compare(w.due, false, "fresh reminder is not due")
            verify(root.cfg().endEpoch > 0,
                   "REAL BUG: a running, non-due reminder must have a live endEpoch to count down")
        }

        // WAS BROKEN (medium), now pinned. The defect was: BreakWidget never declares `property int tick`, so the
        // per-second tick binding is never injected and todayKey/breaksToday
        // never roll over at midnight.
        function test_declares_tick_property() {
            var w = h.item
            compare(w.hasOwnProperty("tick"), true,
                    "REAL BUG: BreakWidget must declare `property int tick` for midnight rollover")
        }

        // WAS BROKEN (medium), now pinned. The defect was: setInterval() unconditionally writes running:true, so
        // tapping −5m / +5m while paused silently resumes the countdown.
        function test_setInterval_while_paused_keeps_paused() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance",
                { running: false, due: false, pausedRemaining: 600, intervalMin: 30 })
            compare(w.running, false, "precondition: paused")
            w.setInterval(w.intervalMin - 5)   // tap −5m
            compare(root.cfg().running, false,
                    "REAL BUG: −5m/+5m while paused must NOT resume the timer")
        }

        // WAS BROKEN (low), now pinned. The defect was: pausing while a break is due snapshots pausedRemaining from
        // `remaining`, which is forced to 0 when due - corrupting the state.
        function test_pause_while_due_does_not_zero_paused() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance",
                { running: true, due: true, endEpoch: Date.now() + 600 * 1000, pausedRemaining: 600 })
            compare(w.due, true, "precondition: due")
            compare(w.remaining, 0, "remaining is forced to 0 while due")
            w.toggleRun()   // pause while due
            verify(root.cfg().pausedRemaining > 0,
                   "REAL BUG: pausing while due must not persist pausedRemaining:0")
        }
    }

    // ── Per-sizeClass structure (W1) ─────────────────────────────────────────
    // The Dashboard injects sizeClass; the tests assign it the same way and pin
    // what each size shows - a future edit can't silently collapse the sizes
    // back into one stretched countdown.
    TestCase {
        name: "BreakSizes"
        when: windowShown

        function prep(hh, patch) {
            root.clear(hh)
            hh.storeCtl.patchSettings("test-instance", patch || { running: false, due: false, pausedRemaining: 600 })
        }
        function cleanup() {
            hBMicro.theme.textScale = 1.15
            hBMicro.theme.fontChoice = "hyperlegible"
            bMicroWrap.width = 344
            bMicroWrap.height = 416
            hBWide.theme.textScale = 1.15
            hBWide.theme.fontChoice = "hyperlegible"
            bWideWrap.width = 696
            bWideWrap.height = 416
            hBTall.theme.textScale = 1.15
            hBTall.theme.fontChoice = "hyperlegible"
            bTallWrap.width = 344
            bTallWrap.height = 840
        }
        function verifyInside(item, label) {
            verify(item !== null, label + " exists")
            verify(item.x >= -1, label + " stays inside the left edge")
            verify(item.y >= -1, label + " stays inside the top edge")
            verify(item.x + item.width <= item.parent.width + 1,
                   label + " stays inside the right edge")
            verify(item.y + item.height <= item.parent.height + 1,
                   label + " stays inside the bottom edge")
        }

        // 0.5x0.5 - a bare headerless ring: no caption, no controls.
        function test_micro_is_a_bare_ring() {
            tryVerify(function () { return hBMicro.ready }, 3000)
            prep(hBMicro)
            var w = hBMicro.item
            w.sizeClass = "compact"
            compare(w.micro, true, "a 344x416 compact box is the micro tile")
            compare(w.showHeader, false, "micro hides the header - nothing competes with the ring")
            compare(w.showTileControls, false, "micro carries no pause/reset controls")
            verify(root.findRing(hBMicro) !== null, "the interval ring is there")
            var pause = root.findByProp(w, "label", "Pause")
            verify(pause === null || !pause.visible, "no visible Pause control at micro")
        }

        // …but a due break must ALWAYS be acknowledgeable, even at micro.
        function test_micro_due_still_has_done() {
            tryVerify(function () { return hBMicro.ready }, 3000)
            prep(hBMicro, { due: true, running: true })
            var w = hBMicro.item
            w.sizeClass = "compact"
            var done = root.findByProp(w, "label", "Done")
            verify(done !== null && done.visible, "the Done pill is reachable at micro")
            verify(done.height >= 44, "and it is touch sized (got " + done.height + ")")
        }

        // 1x1 - header + ring + caption + touch-token pause/reset + momentum.
        function test_baseline_ring_caption_controls() {
            tryVerify(function () { return hBBase.ready }, 3000)
            prep(hBBase, { running: false, due: false, pausedRemaining: 600,
                           day: Qt.formatDate(new Date(), "yyyy-MM-dd"), breaksToday: 3 })
            var w = hBBase.item
            w.sizeClass = "compact"
            compare(w.micro, false, "696x840 compact is the baseline, not micro")
            compare(w.showHeader, true, "the baseline keeps the header")
            compare(w.showTileControls, true, "the baseline carries the tile controls")
            var resume = root.findByProp(w, "label", "Resume")
            verify(resume !== null && resume.visible, "the pause/resume pill is rendered")
            verify(resume.implicitHeight >= 44,
                   "tile controls are touch sized (got " + resume.implicitHeight + ")")
            var caption = root.findByProp(w, "text", "Timer paused")
            verify(caption !== null && caption.visible, "the paused state is explicit")
            verify(caption.font.pixelSize >= 18, "paused state remains readable")
            var ringState = root.findByProp(w, "objectName", "breakRingState")
            verify(ringState !== null && ringState.visible)
            compare(ringState.text, "paused")
            verify(ringState.font.pixelSize >= 18, "ring state remains readable")
            var momentum = root.findByProp(w, "text", "✓ 3 breaks today")
            verify(momentum !== null && momentum.visible, "the momentum line earns its place")
        }

        function test_baseline_adds_rhythm_schedule_and_daily_context() {
            tryVerify(function () { return hBBase.ready }, 3000)
            prep(hBBase, { running: false, due: false, pausedRemaining: 600,
                           intervalMin: 30, workStartHour: 9, workEndHour: 17,
                           workDays: "1,2,3,4,5",
                           day: Qt.formatDate(new Date(), "yyyy-MM-dd"), breaksToday: 3 })
            var w = hBBase.item
            w.sizeClass = "compact"
            wait(32)
            compare(w.showDetails, true, "the 1x1 card earns reminder context")
            var details = root.findByProp(w, "objectName", "breakDetails")
            verify(details !== null && details.visible, "the reminder detail panel is rendered")
            verify(root.findByProp(details, "text", "Every 30 min") !== null)
            verify(root.findByProp(details, "text", "09:00 to 17:00") !== null)
            verify(root.findByProp(details, "text", "Weekdays") !== null)
            verify(root.findByProp(details, "text", "3 breaks") !== null)

            prep(hBMicro)
            var micro = hBMicro.item; micro.sizeClass = "compact"
            compare(micro.showDetails, false, "the micro timer stays a pure countdown")
        }

        function test_running_paused_snoozed_outside_disabled_and_due_are_distinct() {
            tryVerify(function () { return hBBase.ready }, 3000)
            var w = hBBase.item
            w.sizeClass = "compact"

            prep(hBBase, { running: true, due: false, snoozed: false,
                           scheduleSuspended: false, pausedRemaining: 600 })
            compare(w.stateLabel, "Running")
            compare(w.stateDescription, "until next break")

            prep(hBBase, { running: false, due: false, pausedRemaining: 600 })
            compare(w.stateLabel, "Paused")
            compare(w.stateDescription, "Timer paused")

            prep(hBBase, { running: true, due: false, snoozed: true,
                           scheduleSuspended: false, pausedRemaining: 300 })
            compare(w.stateLabel, "Snoozed")
            compare(w.stateDescription, "Snoozed until the next reminder")

            prep(hBBase, { running: true, due: false, snoozed: false,
                           scheduleSuspended: true, pausedRemaining: 600 })
            compare(w.stateLabel, "Outside active hours")
            compare(w.stateDescription, "Waiting for active hours")

            prep(hBBase, { running: true, due: false, workDays: "",
                           scheduleSuspended: true, pausedRemaining: 600 })
            compare(w.stateLabel, "Schedule disabled")
            compare(w.stateDescription, "No active weekdays selected")

            prep(hBBase, { running: true, due: true, pausedRemaining: 600 })
            compare(w.stateLabel, "Break due")
        }

        // The ring reads the interval: half the interval left ⇒ a half ring.
        function test_ring_tracks_interval_fraction() {
            tryVerify(function () { return hBBase.ready }, 3000)
            prep(hBBase, { running: false, due: false, pausedRemaining: 900, intervalMin: 30 })
            var w = hBBase.item
            w.pulse++
            verify(Math.abs(w.ringFrac - 0.5) < 0.01,
                   "15 of 30 minutes left reads 0.5 (got " + w.ringFrac + ")")
        }

        // wide - ring beside the control column, in BOTH projections of the
        // class (1x0.5 portrait 696x416, 0.5x1 landscape 840x344).
        function test_wide_ring_beside_controls_both_orientations() {
            tryVerify(function () { return hBWide.ready }, 3000)
            prep(hBWide)
            var w = hBWide.item
            w.sizeClass = "wide"
            compare(w.horiz, true, "wide lays ring and controls side by side")
            compare(w.showTileControls, true, "wide carries the controls")
            verify(w.ringDia <= hBWide.item.height, "the ring fits the short axis")
            bWideWrap.width = 840; bWideWrap.height = 344
            compare(w.showTileControls, true, "the landscape projection keeps the controls")
            verify(w.ringDia <= 344, "the ring fits the landscape short axis")
            bWideWrap.width = 696; bWideWrap.height = 416
        }

        // tall - stacked ring over controls (0.5x1 portrait, 1x0.5 landscape).
        function test_tall_stacks_ring_over_controls() {
            tryVerify(function () { return hBTall.ready }, 3000)
            prep(hBTall)
            var w = hBTall.item
            w.sizeClass = "tall"
            compare(w.horiz, false, "tall stacks vertically")
            compare(w.showTileControls, true, "tall carries the controls")
            verify(w.ringDia <= 344 * 0.8, "the ring is width-bound in the narrow tall box")
        }

        function test_scaled_micro_state_uses_the_active_type_floor() {
            tryVerify(function () { return hBMicro.ready }, 3000)
            hBMicro.theme.textScale = 1.45
            hBMicro.theme.fontChoice = "system"
            bMicroWrap.width = 278
            bMicroWrap.height = 327
            prep(hBMicro, {
                running: false, due: false, pausedRemaining: 900
            })
            var w = hBMicro.item
            w.sizeClass = "compact"
            wait(32)

            var state = root.findByProp(w, "objectName", "breakRingState")
            verify(state !== null && state.visible)
            verify(state.font.pixelSize >= hBMicro.theme.fontMinimum,
                   "micro state follows the active type floor")
            verify(!state.truncated, "micro state remains complete")
        }

        function test_scaled_state_description_uses_the_active_type_floor() {
            tryVerify(function () { return hBWide.ready }, 3000)
            hBWide.theme.textScale = 1.45
            hBWide.theme.fontChoice = "hyperlegible"
            bWideWrap.width = 557
            bWideWrap.height = 327
            prep(hBWide, {
                intervalMin: 240, running: false, due: false,
                pausedRemaining: 86399
            })
            var w = hBWide.item
            w.sizeClass = "wide"
            wait(32)

            var ringState = root.findByProp(w, "objectName", "breakRingState")
            var description = root.findByProp(
                w, "objectName", "breakStateDescription")
            verify(ringState !== null && ringState.visible)
            verify(description !== null && description.visible)
            verify(ringState.font.pixelSize >= hBWide.theme.fontMinimum,
                   "ring state follows the active type floor")
            verify(description.font.pixelSize >= hBWide.theme.fontMinimum,
                   "state description follows the active type floor")
            verify(!ringState.truncated && !description.truncated,
                   "both paused labels remain complete")
        }

        function test_output_scaled_narrow_header_preserves_the_title() {
            tryVerify(function () { return hBTall.ready }, 3000)
            hBTall.theme.textScale = 1.45
            hBTall.theme.fontChoice = "lexend"
            bTallWrap.width = 278
            bTallWrap.height = 654
            prep(hBTall, {
                running: false, due: false, pausedRemaining: 86399
            })
            var w = hBTall.item
            w.sizeClass = "tall"
            wait(32)

            compare(w.compactHeaderStatus, true)
            compare(w.status, "",
                    "the duplicate status yields to the widget title")
            var title = root.findByProp(w, "text", "Break Reminder")
            verify(title !== null && title.visible)
            verify(!title.truncated,
                   "the narrow header keeps the complete widget title")
        }

        function test_output_scaled_short_due_reflows_touch_actions() {
            tryVerify(function () { return hBWide.ready }, 3000)
            hBWide.theme.textScale = 1.3
            hBWide.theme.fontChoice = "lexend"
            bWideWrap.width = 677
            bWideWrap.height = 245
            prep(hBWide, {
                running: false, due: true, message: "Time to move",
                showSuggestion: true, snoozeMin: 5
            })
            var w = hBWide.item
            w.sizeClass = "wide"
            wait(32)

            compare(w.compactDueLayout, true)
            var layout = root.findByProp(w, "objectName", "breakDueLayout")
            var message = root.findByProp(w, "objectName", "breakDueMessage")
            var controls = root.findByProp(w, "objectName", "breakDueControls")
            var done = root.findByProp(w, "objectName", "breakDueDone")
            var snooze = root.findByProp(w, "objectName", "breakDueSnooze")
            verify(message !== null && message.visible && !message.truncated,
                   "the due message remains complete")
            compare(controls.columns, 2,
                    "short-wide actions reflow into two columns")
            verify(done.height >= hBWide.theme.touchSecondary)
            verify(snooze.height >= hBWide.theme.touchSecondary)
            verifyInside(layout, "short-wide due layout")
        }

        // The overlay (full) keeps the complete control set - ±5m lives there.
        function test_full_overlay_has_interval_controls() {
            tryVerify(function () { return h.ready }, 3000)
            root.clear(h)
            var w = h.item
            var minus = root.findByProp(w, "label", "−5m")
            verify(minus !== null && minus.visible, "−5m is an overlay control")
            var tile = root.findByProp(hBBase.item, "label", "−5m")
            verify(tile === null || !tile.visible, "…and never a tile control")
        }
    }
}
