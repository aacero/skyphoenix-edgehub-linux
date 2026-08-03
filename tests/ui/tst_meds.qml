import QtQuick
import QtQuick.Controls
import QtTest


// ─────────────────────────────────────────────────────────────────────────
// tst_meds - ui/qml/widgets/MedsWidget.qml.
//
// The two things that must be true, in order:
//   1. A dose goes due → taken and the mark SURVIVES a store round-trip. This is
//      a medication record; losing it on restart is the whole failure.
//   2. The widget never escalates. A dose whose time has passed un-marked must not
//      render as an error/warning colour and must not be called "missed". That is a
//      product requirement (an un-tapped dose is not evidence of a missed dose, and
//      the plausible user correction is double-dosing), so it is asserted, not
//      left to a code review.
//
// Time: the state matrix runs at a FIXED clock, passed to stateOf()/focusDoseAt().
// Building fixtures as "now ± n minutes" made the suite a different scenario
// depending on the hour it ran - "now + 2 h" does not exist at 23:00 - and it
// flaked exactly that way. One test still uses the wall clock, to prove the
// default path reads it; it schedules a dose for the current minute, which is
// due at any hour.
// ─────────────────────────────────────────────────────────────────────────
Item {
    id: root
    width: 1000; height: 720
    property int notificationCalls: 0
    property string notificationSummary: ""
    property string notificationBody: ""
    property bool notificationWasPriority: false
    property int priorityAlertCalls: 0
    property var lastPriorityAlert: null

    QtObject {
        id: fakeNotifications
        function send(summary, body) {
            root.notificationCalls++
            root.notificationSummary = summary
            root.notificationBody = body
            return true
        }
        function sendPriority(summary, body) {
            root.notificationWasPriority = true
            return send(summary, body)
        }
    }
    QtObject {
        id: prioritySink
        function showPriorityAlert(request) {
            root.priorityAlertCalls++
            root.lastPriorityAlert = request
            return true
        }
    }

    // Side by side rather than stacked: `hc` is clicked for real, and an
    // overlapping sibling would swallow the press.
    WidgetHarness {
        id: h; x: 0; y: 0; width: 620; height: parent.height
        widgetFile: "MedsWidget.qml"; expanded: true
    }
    WidgetHarness {
        id: hc; x: 640; y: 0; width: 340; height: 380; z: 100
        widgetFile: "MedsWidget.qml"; expanded: false
    }

    function clearSettings(harness) {
        var s = harness.storeCtl.settingsFor("test-instance")
        for (var k in s) delete s[k]
        harness.storeCtl._touchSettings()
    }
    // "HH:MM" for a time `deltaMin` from now, so a fixture can put a dose reliably
    // in the past or the future. Wraps within the day; the callers stay well away
    // from midnight-crossing deltas.
    function hhmm(deltaMin) {
        var d = new Date(Date.now() + deltaMin * 60000)
        return Qt.formatTime(d, "HH:mm")
    }
    function todayKey() { return Qt.formatDate(new Date(), "yyyy-MM-dd") }
    // A round-trip must go through a doc that OWNS the settings bucket: the store
    // prunes settings whose id no tile claims (an orphan bucket is a leak), so a
    // harness instance with no tile is dropped on reload - correctly. Give the
    // document the tile a real config.toml would have, then reload it.
    function reloadWith(harness, doc, type) {
        doc.pages = [ { name: "Test", tiles: [ { id: "test-instance", type: type, size: "1x1" } ] } ]
        return harness.storeCtl.applyExternal(JSON.stringify(doc))
    }

    // ── Parsing ──────────────────────────────────────────────────────────
    TestCase {
        name: "MedsSchedule"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000); clearSettings(h) }

        function test_schedule_parses_time_and_name() {
            h.storeCtl.patchSettings("test-instance", { schedule: "08:00 Vitamin D\n20:30 Magnesium" })
            compare(h.item.schedule, "08:00 Vitamin D\n20:30 Magnesium",
                    "the schedule setting is read back off the store")
            var d = h.item.doses
            compare(d.length, 2, "two doses parsed")
            compare(d[0].name, "Vitamin D")
            compare(d[0].hour, 8); compare(d[0].minute, 0); compare(d[0].mins, 480)
            compare(d[1].name, "Magnesium"); compare(d[1].mins, 20 * 60 + 30)
        }

        function test_schedule_is_sorted_by_clock_time() {
            h.storeCtl.patchSettings("test-instance", { schedule: "20:30 Night\n08:00 Morning\n13:00 Noon" })
            var d = h.item.doses
            compare(d.length, 3)
            compare(d[0].name, "Morning"); compare(d[1].name, "Noon"); compare(d[2].name, "Night")
        }

        function test_schedule_tolerates_sloppy_input() {
            h.storeCtl.patchSettings("test-instance",
                { schedule: "  8:00   Ritalin 10mg  \n\n\n09:05\n" })
            var d = h.item.doses
            compare(d.length, 2, "blank lines dropped, real lines kept")
            compare(d[0].name, "Ritalin 10mg", "single-digit hour + padding parses")
            compare(d[0].mins, 480)
            compare(d[1].name, "Dose", "a bare time gets a placeholder name")
        }

        // Dropping an unreadable medication line is the worst failure mode here, so
        // it degrades to an untimed dose instead.
        function test_unparseable_line_is_kept_as_untimed() {
            h.storeCtl.patchSettings("test-instance", { schedule: "Inhaler as needed\n08:00 Vitamin D" })
            var d = h.item.doses
            compare(d.length, 2, "the un-timed line is NOT discarded")
            compare(d[0].name, "Vitamin D", "timed doses come first")
            compare(d[1].name, "Inhaler as needed")
            compare(d[1].mins, -1, "no time")
            compare(h.item.timeOf(d[1]), "-", "and it renders as having no time")
        }

        // 25:00 / 08:99 are not times. They must not become hour 25.
        function test_impossible_times_are_not_treated_as_times() {
            h.storeCtl.patchSettings("test-instance", { schedule: "25:00 Nope\n08:99 Also nope" })
            var d = h.item.doses
            compare(d.length, 2)
            compare(d[0].mins, -1, "hour 25 is not a time")
            compare(d[1].mins, -1, "minute 99 is not a time")
            compare(h.item.scheduleIssues.length, 2, "both lines are surfaced for review")
        }

        function test_duplicate_lines_have_independent_identity() {
            h.storeCtl.patchSettings("test-instance",
                { schedule: "08:00 Vitamin D\n08:00 Vitamin D" })
            var w = h.item
            compare(w.doses.length, 2)
            verify(w.doses[0].key !== w.doses[1].key, "identical lines have distinct keys")
            compare(w.scheduleIssues.length, 1, "the repeated line is surfaced for review")
            w.toggleTaken(w.doses[0].key)
            compare(w.isTaken(w.doses[0].key), true)
            compare(w.isTaken(w.doses[1].key), false, "marking one duplicate leaves the other open")
        }

        function test_due_window_is_clamped_to_the_supported_range() {
            h.storeCtl.patchSettings("test-instance", { dueWindowMin: -5 })
            compare(h.item.dueWindowMin, 15)
            h.storeCtl.patchSettings("test-instance", { dueWindowMin: 999 })
            compare(h.item.dueWindowMin, 240)
        }

        function test_empty_schedule_yields_no_doses() {
            h.storeCtl.patchSettings("test-instance", { schedule: "" })
            compare(h.item.doses.length, 0)
            compare(h.item.focusDose, null, "and no dose to focus on")
        }

        function test_structured_schedule_filters_each_dose_by_weekday() {
            h.item.todayWeekdayOverride = 1
            h.storeCtl.patchSettings("test-instance", {
                scheduleItems: [
                    { id: "daily-a", time: "08:00", name: "Monday dose", days: "1,3" },
                    { id: "daily-b", time: "09:00", name: "Tuesday dose", days: "2" }
                ]
            })
            compare(h.item.allDoses.length, 2)
            compare(h.item.doses.length, 1)
            compare(h.item.doses[0].name, "Monday dose")
            compare(h.item.doses[0].key, "daily-a")
            h.item.todayWeekdayOverride = 2
            compare(h.item.doses.length, 1)
            compare(h.item.doses[0].name, "Tuesday dose")
        }

        function test_empty_recurrence_never_schedules_the_dose() {
            h.item.todayWeekdayOverride = 4
            h.storeCtl.patchSettings("test-instance", {
                scheduleItems: [
                    { id: "disabled", time: "08:00", name: "Paused dose", days: "" }
                ]
            })
            compare(h.item.allDoses.length, 1)
            compare(h.item.doses.length, 0)
        }

        function test_cleared_structured_schedule_does_not_fall_back_to_legacy_text() {
            h.storeCtl.patchSettings("test-instance", {
                schedule: "08:00 Old dose",
                scheduleItems: [],
                scheduleFormat: "structured"
            })
            compare(h.item.allDoses.length, 0)
            compare(h.item.doses.length, 0)
        }
    }

    TestCase {
        name: "MedsNotifications"
        when: windowShown
        function init() {
            tryVerify(function () { return h.ready }, 3000)
            clearSettings(h)
            root.notificationCalls = 0
            root.notificationSummary = ""
            root.notificationBody = ""
            root.notificationWasPriority = false
            root.priorityAlertCalls = 0
            root.lastPriorityAlert = null
            h.item.notificationBridge = fakeNotifications
            h.item.priorityAlerts = prioritySink
            h.item.foreground = false
            h.item.active = true
            h.item.todayWeekdayOverride = 1
            h.item.nowMinsOverride = 8 * 60 + 10
        }

        function seed(extra) {
            var settings = {
                scheduleItems: [
                    { id: "morning", time: "08:00", name: "Private name", days: "1" }
                ],
                dueWindowMin: 60,
                notifyWhenHidden: true,
                notificationDetails: false,
                notifiedDay: "",
                notified: []
            }
            for (var key in extra) settings[key] = extra[key]
            h.storeCtl.patchSettings("test-instance", settings)
        }

        function test_hidden_due_notification_is_private_and_fires_once() {
            seed({})
            compare(h.item.checkNotifications(), true)
            compare(root.notificationCalls, 1)
            compare(root.notificationSummary, "Medication reminder")
            compare(root.notificationBody, "A scheduled dose is due now.")
            compare(root.notificationWasPriority, true)
            compare(root.priorityAlertCalls, 1)
            compare(root.lastPriorityAlert.primaryAction, "openWidget")
            compare(root.lastPriorityAlert.body, "A scheduled dose is due now.")
            verify(root.lastPriorityAlert.body.indexOf("Private name") < 0)
            verify(root.lastPriorityAlert.detail.indexOf("cannot confirm") >= 0)
            verify(root.notificationBody.indexOf("Private name") < 0)
            compare(h.item.checkNotifications(), false)
            compare(root.notificationCalls, 1, "the same dose is not announced twice")
            compare(root.priorityAlertCalls, 1,
                    "the same dose does not enqueue a second Hub alert")
        }

        function test_dose_name_is_only_included_after_explicit_opt_in() {
            seed({ notificationDetails: true })
            compare(h.item.checkNotifications(), true)
            compare(root.notificationBody, "Private name is due now.")
        }

        function test_visible_or_opted_out_widget_does_not_notify() {
            seed({})
            h.item.foreground = true
            compare(h.item.checkNotifications(), false)
            compare(root.notificationCalls, 0)
            h.item.foreground = false
            h.storeCtl.patchSettings("test-instance", { notifyWhenHidden: false })
            compare(h.item.checkNotifications(), false)
            compare(root.notificationCalls, 0)
        }

        function test_inactive_weekday_and_taken_dose_do_not_notify() {
            seed({})
            h.item.todayWeekdayOverride = 2
            compare(h.item.checkNotifications(), false)
            h.item.todayWeekdayOverride = 1
            h.item.toggleTaken("morning")
            compare(h.item.checkNotifications(), false)
            compare(root.notificationCalls, 0)
        }
    }

    // ── States ───────────────────────────────────────────────────────────
    TestCase {
        name: "MedsStates"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000); clearSettings(h) }

        // The full state matrix, evaluated at a FIXED clock (13:00). Building the
        // fixture as "now ± n minutes" instead would make this a different scenario
        // depending on when the suite ran - "now + 2 h" simply does not exist at
        // 23:00, and the test flaked exactly that way before stateOf took a clock.
        readonly property int oneOClock: 13 * 60

        function test_due_taken_later_and_open() {
            h.storeCtl.patchSettings("test-instance", {
                schedule: "12:50 JustDue\n09:40 LongPast\n15:00 Upcoming",
                dueWindowMin: 60
            })
            var w = h.item
            var by = {}
            for (var i = 0; i < w.doses.length; i++) by[w.doses[i].name] = w.doses[i]
            compare(w.stateOf(by["JustDue"], oneOClock), "due",
                    "10 min after its time, inside a 60 min window")
            compare(w.stateOf(by["LongPast"], oneOClock), "open",
                    "200 min after its time, outside the window")
            compare(w.stateOf(by["Upcoming"], oneOClock), "later", "still ahead")
        }

        // The boundary itself, to the minute.
        function test_the_due_window_boundary_is_exact() {
            h.storeCtl.patchSettings("test-instance",
                { schedule: "13:00 Dose", dueWindowMin: 60 })
            var d = h.item.doses[0]
            compare(h.item.stateOf(d, 12 * 60 + 59), "later", "one minute before its time")
            compare(h.item.stateOf(d, 13 * 60), "due", "on the minute it is due")
            compare(h.item.stateOf(d, 13 * 60 + 59), "due", "the last minute of the window")
            compare(h.item.stateOf(d, 14 * 60), "open", "the window closes exactly on time")
        }

        // The knob has to actually move the boundary, or it is decorative.
        function test_dueWindowMin_widens_the_due_state() {
            h.storeCtl.patchSettings("test-instance",
                { schedule: "11:30 Dose", dueWindowMin: 60 })
            compare(h.item.dueWindowMin, 60)
            compare(h.item.stateOf(h.item.doses[0], oneOClock), "open",
                    "90 min ago is outside a 60 min window")
            h.storeCtl.patchSettings("test-instance", { dueWindowMin: 120 })
            compare(h.item.dueWindowMin, 120)
            compare(h.item.stateOf(h.item.doses[0], oneOClock), "due",
                    "…and inside a 120 min one")
        }

        function test_taken_wins_over_every_other_state() {
            h.storeCtl.patchSettings("test-instance", { schedule: "12:50 Dose" })
            var w = h.item
            compare(w.stateOf(w.doses[0], oneOClock), "due")
            w.toggleTaken(w.doses[0].key)
            compare(w.stateOf(w.doses[0], oneOClock), "taken", "a taken dose is never also due")
        }

        function test_untimed_dose_is_open_never_due() {
            h.storeCtl.patchSettings("test-instance", { schedule: "Inhaler as needed" })
            compare(h.item.stateOf(h.item.doses[0], oneOClock), "open",
                    "a dose with no time can never become due")
            compare(h.item.stateOf(h.item.doses[0], 0), "open", "…at any hour")
        }

        // The default path must genuinely read the wall clock - otherwise every
        // fixed-clock test above could pass against a stateOf() that ignores time.
        // A dose scheduled for this very minute is due whatever time it is, so this
        // is the one clock assertion that is safe at any hour.
        // (That the explicit clock really overrides is proved by the boundary test:
        // four different answers for one dose cannot all come from the wall clock.)
        function test_the_default_clock_is_the_real_one() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance",
                { schedule: root.hhmm(0) + " RightNow", dueWindowMin: 60 })
            compare(w.doses[0].mins, w.nowMins(), "the fixture really is scheduled for now")
            compare(w.stateOf(w.doses[0]), "due",
                    "with no clock passed, stateOf reads the actual time")
        }

        // The tile leads with the dose that needs attention.
        function test_focusDose_prefers_due_then_later() {
            h.storeCtl.patchSettings("test-instance", {
                schedule: "12:50 DueOne\n14:30 LaterOne", dueWindowMin: 60
            })
            compare(h.item.focusDoseAt(oneOClock).name, "DueOne", "a due dose leads")
            h.item.toggleTaken("12:50 DueOne")
            compare(h.item.focusDoseAt(oneOClock).name, "LaterOne",
                    "once taken, the next upcoming one leads")
        }

        function test_focusDose_falls_through_to_an_unmarked_dose() {
            h.storeCtl.patchSettings("test-instance", {
                schedule: "08:00 Morning\n09:00 Later", dueWindowMin: 60
            })
            // At 13:00 both are long past - the tile still offers the first.
            compare(h.item.focusDoseAt(oneOClock).name, "Morning",
                    "with nothing due or upcoming, the first un-marked dose leads")
        }
    }

    // ── Tone: the no-shaming requirement, asserted ───────────────────────
    TestCase {
        name: "MedsTone"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000); clearSettings(h) }

        // The core requirement: a passed, un-marked dose is quiet. If someone ever
        // "improves" this into an alert, this test is what stops it.
        function test_a_passed_dose_is_never_red_and_never_missed() {
            // Absolute dose + absolute clock: `stateOf(dose, nowM)` is a pure
            // function by design, so this needs no wall clock at all. It used
            // `hhmm(-300)`, which five hours before 00:07 is "19:07" - read as
            // a dose due LATER today, i.e. "later", not the "open" asserted.
            h.storeCtl.patchSettings("test-instance",
                { schedule: "08:00 Forgotten", dueWindowMin: 60 })
            var w = h.item
            var st = w.stateOf(w.doses[0], 13 * 60)   // 13:00 - five hours past
            compare(st, "open", "a long-passed dose settles into 'open'")
            compare(String(w.colorOf(st)), String(h.theme.textTertiary),
                    "it is muted, not an alarm")
            verify(String(w.colorOf(st)) !== String(h.theme.error),
                   "never the error colour")
            verify(String(w.colorOf(st)) !== String(h.theme.warning),
                   "never the warning colour either - this is not a problem to fix")
            var label = w.labelOf(st)
            compare(label, "Not marked")
            verify(label.toLowerCase().indexOf("miss") < 0, "the word 'missed' is never shown")
            verify(label.toLowerCase().indexOf("overdue") < 0, "nor 'overdue'")
            verify(label.toLowerCase().indexOf("late") < 0, "nor 'late'")
        }

        // No state at all may use error/warning - the widget has no failure states.
        function test_no_state_uses_an_alarm_colour() {
            var w = h.item
            var states = ["taken", "due", "later", "open"]
            for (var i = 0; i < states.length; i++) {
                var c = String(w.colorOf(states[i]))
                verify(c !== String(h.theme.error), states[i] + " is not the error colour")
                verify(c !== String(h.theme.warning), states[i] + " is not the warning colour")
            }
        }

        function test_taken_and_due_are_distinguishable() {
            var w = h.item
            verify(String(w.colorOf("taken")) !== String(w.colorOf("due")),
                   "taken and due do not look the same")
            verify(String(w.colorOf("due")) !== String(w.colorOf("open")),
                   "due stands out from a quiet dose")
        }

        function test_active_surface_explains_record_and_plaintext_limits() {
            var copy = (h.item.recordMeaningText + " " + h.item.privacyText).toLowerCase()
            verify(copy.indexOf("tap") >= 0)
            verify(copy.indexOf("cannot confirm") >= 0)
            verify(copy.indexOf("plaintext") >= 0)
            verify(copy.indexOf("medical advice") < 0, "the copy does not imply clinical guidance")
        }

        // The test above pins the WORDS. Nothing pinned that the user ever sees
        // them: the notice is one Text bound to `visible: w.expanded`, and a
        // broken binding would remove a medication safety disclaimer silently
        // while every keyword assertion above still passed. Same shape as the
        // media artwork notice (finding 10.3) - on a much less forgiving string.
        function findNamed(host, name) {
            var hits = root.findAll(host.item, function (n) {
                return n.objectName === name
            }, [])
            return hits.length ? hits[0] : null
        }

        function test_the_limits_notice_is_actually_on_screen() {
            // The notice lives on the ACTIVE surface, which is hidden until
            // there is a schedule to be active about - so a widget with no doses
            // legitimately shows no caveat. Seed one: the invariant that matters
            // is "if you are tracking medication, you see the limits".
            h.storeCtl.patchSettings("test-instance",
                                     { schedule: "08:00 Vitamin D\n20:30 Magnesium" })
            var notice = findNamed(h, "medsLimitsNotice")
            verify(notice !== null, "the expanded view has a limits notice at all")
            verify(notice.visible, "and it is visible, not merely constructed")
            verify(notice.width > 0 && notice.height > 0,
                   "with real geometry rather than a collapsed box")

            // It must be the widget's own strings - a hardcoded duplicate here
            // would keep passing after the real copy changed.
            var shown = String(notice.text)
            verify(shown.indexOf(h.item.recordMeaningText) >= 0,
                   "the rendered notice contains the record-meaning line verbatim")
            verify(shown.indexOf(h.item.privacyText) >= 0,
                   "and the plaintext-storage line verbatim")
        }

        // Both halves must survive together: dropping either one leaves a
        // disclaimer that is still plausible but no longer complete.
        function test_the_limits_notice_states_both_limits_data() {
            return [
                { tag: "record-meaning", needle: "cannot confirm a dose was taken" },
                { tag: "plaintext", needle: "stored locally in plaintext" }
            ]
        }
        function test_the_limits_notice_states_both_limits(data) {
            h.storeCtl.patchSettings("test-instance", { schedule: "08:00 Vitamin D" })
            var notice = findNamed(h, "medsLimitsNotice")
            verify(String(notice.text).indexOf(data.needle) >= 0,
                   "the on-screen notice still says '" + data.needle + "'")
        }
    }

    // ── Persistence - the point of the widget ────────────────────────────
    TestCase {
        name: "MedsPersistence"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000); clearSettings(h) }

        function test_marking_taken_persists_the_day_and_the_dose() {
            h.storeCtl.patchSettings("test-instance", { schedule: "08:00 Vitamin D\n20:30 Magnesium" })
            var w = h.item
            w.toggleTaken(w.doses[0].key)
            var saved = h.storeCtl.settingsFor("test-instance")
            compare(saved.takenDay, root.todayKey(), "the day is stamped")
            compare(saved.taken.length, 1)
            compare(saved.taken[0], "08:00 Vitamin D", "the dose's line is the stored key")
            compare(w.isTaken(w.doses[0].key), true)
            compare(w.isTaken(w.doses[1].key), false, "marking one does not mark the other")
            compare(w.takenCount, 1)
        }

        // A mis-tap must be undoable: a false "taken" is worse than no record.
        function test_marking_taken_is_reversible() {
            h.storeCtl.patchSettings("test-instance", { schedule: "08:00 Vitamin D" })
            var w = h.item
            w.toggleTaken(w.doses[0].key)
            compare(w.isTaken(w.doses[0].key), true)
            w.toggleTaken(w.doses[0].key)
            compare(w.isTaken(w.doses[0].key), false, "tapping again un-marks it")
            compare(h.storeCtl.settingsFor("test-instance").taken.length, 0, "and that persists too")
        }

        // The mark must come back after a restart - this is the whole feature.
        function test_taken_survives_a_store_round_trip() {
            h.storeCtl.patchSettings("test-instance", { schedule: "08:00 Vitamin D" })
            h.item.toggleTaken(h.item.doses[0].key)
            // Exactly what reaches disk: the persistable projection of the document.
            var onDisk = JSON.parse(JSON.stringify(h.storeCtl._persistableData()))
            verify(onDisk.settings["test-instance"] !== undefined, "the instance reaches disk")
            compare(onDisk.settings["test-instance"].taken[0], "08:00 Vitamin D",
                    "the taken mark is persistable, not ephemeral")
            compare(onDisk.settings["test-instance"].takenDay, root.todayKey())
            // Reload the store from those very bytes and re-read through the widget.
            // applyExternal() is the real reload path - the same one the hub and the
            // Manager push a document through - and it forces the doc back through
            // JSON, so this exercises the serialization config.toml actually uses.
            compare(root.reloadWith(h, onDisk, "meds"), true, "the document reloads")
            compare(h.item.isTaken("08:00 Vitamin D"), true,
                    "after a reload the dose is still marked taken")
            compare(h.item.takenCount, 1)
        }

        // Inserting a line above must not move existing marks onto other doses -
        // the reason the key is the line text and not the index.
        function test_marks_survive_a_schedule_reorder() {
            h.storeCtl.patchSettings("test-instance", { schedule: "20:30 Magnesium" })
            h.item.toggleTaken("20:30 Magnesium")
            h.storeCtl.patchSettings("test-instance", { schedule: "08:00 Vitamin D\n20:30 Magnesium" })
            var w = h.item
            compare(w.doses[0].name, "Vitamin D")
            compare(w.isTaken(w.doses[0].key), false, "the new earlier dose is NOT marked")
            compare(w.isTaken(w.doses[1].key), true, "the originally-marked dose still is")
        }

        // Yesterday's marks must not read as today's. The rollover is a read-time
        // decision, so it needs no timer and cannot half-apply.
        function test_a_previous_days_marks_do_not_count_today() {
            h.storeCtl.patchSettings("test-instance", {
                schedule: "08:00 Vitamin D", takenDay: "2020-01-01", taken: ["08:00 Vitamin D"]
            })
            var w = h.item
            compare(w.takenToday.length, 0, "a stale day reads as nothing taken")
            compare(w.isTaken("08:00 Vitamin D"), false)
            compare(w.takenCount, 0)
            // PINNED to 09:00, not the wall clock: an 08:00 dose is only "open" once
            // 08:00 has PASSED. Read before then it is legitimately "later", so this
            // asserted the rollover but silently also asserted "the suite runs after
            // 08:00" - and it failed the first time it ran just after midnight.
            compare(w.stateOf(w.doses[0], 9 * 60), "open", "…and the dose is open again, not taken")
        }

        // Marking after a rollover must re-stamp the day rather than append to
        // yesterday's list.
        function test_marking_after_rollover_restamps_the_day() {
            h.storeCtl.patchSettings("test-instance", {
                schedule: "08:00 Vitamin D", takenDay: "2020-01-01", taken: ["08:00 Vitamin D"]
            })
            h.item.toggleTaken("08:00 Vitamin D")
            var saved = h.storeCtl.settingsFor("test-instance")
            compare(saved.takenDay, root.todayKey(), "the day is re-stamped to today")
            compare(saved.taken.length, 1, "yesterday's entry is replaced, not appended to")
            compare(h.item.isTaken("08:00 Vitamin D"), true)
        }
    }

    // ── Real input on the compact tile ───────────────────────────────────
    TestCase {
        name: "MedsTileInput"
        when: windowShown
        function init() { tryVerify(function () { return hc.ready }, 3000); clearSettings(hc) }

        // Logging a dose must cost one tap on the tile - not an expand-then-tap.
        function test_tile_button_marks_the_focus_dose_taken() {
            // Pin the clock BEFORE seeding, so `focusDose` resolves against it.
            // `hhmm(-10)` formats a bare "HH:mm": ten minutes before 00:07 is
            // "23:57", which the widget correctly reads as a dose due LATER
            // TODAY - so this asserted "due" on a dose 23h50m away and failed
            // every night between 00:00 and 00:10.
            var w = hc.item
            w.sizeClass = "wide"
            w.nowMinsOverride = 13 * 60 + 10          // 13:10, ten past the dose
            hc.storeCtl.patchSettings("test-instance",
                { schedule: "13:00 Ritalin", dueWindowMin: 60 })
            compare(w.stateOf(w.focusDose), "due")
            // Find the PillButton by its label rather than by tree position.
            var pills = root.findAll(w, function (n) {
                return n.hasOwnProperty("label") && n.hasOwnProperty("primary")
            }, [])
            var mark = null
            for (var i = 0; i < pills.length; i++)
                if (pills[i].label === "Mark taken") mark = pills[i]
            verify(mark !== null, "the tile offers a 'Mark taken' button")
            verify(mark.height >= 44, "and it is a real touch target (" + mark.height + ")")
            mouseClick(mark)
            compare(w.isTaken(w.focusDose.key), true, "one tap on the tile logs the dose")
            compare(hc.storeCtl.settingsFor("test-instance").taken.length, 1, "and it persisted")
        }
    }

    TestCase {
        name: "MedsExplicitDoseAction"
        when: windowShown
        function init() {
            tryVerify(function () { return h.ready }, 3000)
            clearSettings(h)
            h.storeCtl.patchSettings("test-instance", { schedule: "08:00 Vitamin D" })
            wait(16)
        }

        function test_schedule_row_has_a_separate_named_action() {
            var rows = root.findAll(h.item, function (n) {
                return String(n.objectName).indexOf("medsDoseRow-") === 0
            }, [])
            var actions = root.findAll(h.item, function (n) {
                return String(n.objectName).indexOf("medsDoseAction-") === 0
            }, [])
            compare(rows.length, 1, "the dose row renders")
            compare(actions.length, 1, "the row exposes one explicit taken action")
            verify(actions[0].width >= h.theme.touchTertiary
                   && actions[0].height >= h.theme.touchTertiary,
                   "the explicit action is a full touch target")
            compare(actions[0].Accessible.role, Accessible.CheckBox)
            verify(String(actions[0].Accessible.name).indexOf("Vitamin D") >= 0,
                   "the action names the affected dose")
            compare(rows[0].children.length, 1,
                    "the row itself has layout content only, not a whole-row pointer handler")
        }
    }

    function findAll(node, pred, acc) {
        acc = acc || []
        if (!node) return acc
        if (pred(node)) acc.push(node)
        var kids = node.children
        for (var i = 0; kids && i < kids.length; i++) findAll(kids[i], pred, acc)
        return acc
    }

    // ── Per-sizeClass structure (W1 wave 2b) ────────────────────────────────
    // Fixed-size hosts at the real projected cell footprints. meds declares no
    // 0.5x0.5, so there is no micro case.
    Item { id: mTallWrap; width: 348; height: 819
        WidgetHarness { id: mTall; anchors.fill: parent; widgetFile: "MedsWidget.qml"; expanded: false } }
    Item { id: mWideWrap; width: 696; height: 409
        WidgetHarness { id: mWide; anchors.fill: parent; widgetFile: "MedsWidget.qml"; expanded: false } }
    Item { width: 696; height: 1639
        WidgetHarness { id: mLarge; anchors.fill: parent; widgetFile: "MedsWidget.qml"; expanded: false } }

    TestCase {
        name: "MedsSizes"
        when: windowShown

        function seed(host) {
            host.storeCtl.patchSettings(host.instanceId,
                { schedule: "08:00 Vitamin D\n12:30 Ritalin\n18:00 Magnesium\n22:00 Melatonin",
                  dueWindowMin: 60, taken: [], takenDay: "" })
        }
        function doseRows(host) {
            return root.findAll(host.item, function (n) {
                return n.hasOwnProperty("st") && n.hasOwnProperty("modelData") }, [])
        }
        function listOf(host) {
            return root.findAll(host.item, function (n) {
                return n.objectName === "medsDoseList" }, [])[0]
        }
        function named(host, name) {
            return root.findAll(host.item, function (n) {
                return n.objectName === name
            }, [])[0]
        }
        function prefixed(host, prefix) {
            return root.findAll(host.item, function (n) {
                return String(n.objectName).indexOf(prefix) === 0
            }, [])
        }
        function structuredDoses(count, longNames) {
            var result = []
            for (var i = 0; i < count; i++) {
                result.push({
                    id: "scaled-dose-" + i,
                    time: (i < 10 ? "0" : "") + (i % 24) + ":30",
                    name: longNames
                          ? "Prescribed morning medicine " + (i + 1)
                          : "Medicine " + (i + 1),
                    days: "0,1,2,3,4,5,6"
                })
            }
            return result
        }

        // A tall tile shows the SCHEDULE - it used to be overlay-only.
        function test_a_tall_tile_earns_the_whole_schedule() {
            tryVerify(function () { return mTall.ready }, 3000)
            var m = mTall.item
            m.sizeClass = "tall"
            seed(mTall)
            wait(32)
            compare(m.showSchedule, true,
                    "a 348x819 tile shows the day's schedule without expanding")
            compare(m.showFocus, false, "…and does not spend it on a single dose")
            compare(doseRows(mTall).length, 4, "all four doses render")
        }

        // 1x2 - the size that most obviously used to waste its box.
        function test_a_large_tile_shows_every_dose() {
            tryVerify(function () { return mLarge.ready }, 3000)
            var m = mLarge.item
            m.sizeClass = "large"
            seed(mLarge)
            wait(32)
            compare(m.showSchedule, true, "a 696x1639 tile shows the schedule")
            compare(doseRows(mLarge).length, 4, "every dose is on the tile")
        }

        // wide - the focus block sits BESIDE the schedule.
        function test_wide_puts_the_focus_dose_beside_the_schedule() {
            tryVerify(function () { return mWide.ready }, 3000)
            var m = mWide.item
            m.sizeClass = "tall"
            seed(mWide)
            wait(32)
            var outer = listOf(mWide).parent.parent.parent
            compare(outer.columns, 1, "a tall box is a single column")
            m.sizeClass = "wide"
            wait(32)
            compare(m.showFocus, true, "wide leads with the focused dose")
            compare(m.showSchedule, true, "…and still shows the schedule beside it")
            compare(outer.columns, 2, "…as two columns")
        }

        // Every dose row is a real touch target at every size - logging a dose is
        // the whole interaction, so it is never thinned for density.
        function test_dose_rows_are_touch_targets_at_every_size() {
            tryVerify(function () { return mTall.ready }, 3000)
            tryVerify(function () { return mLarge.ready }, 3000)
            var hosts = [mTall, mLarge]
            var classes = ["tall", "large"]
            for (var i = 0; i < hosts.length; i++) {
                hosts[i].item.sizeClass = classes[i]
                seed(hosts[i])
                wait(32)
                var rows = doseRows(hosts[i])
                verify(rows.length > 0, classes[i] + ": rows render")
                for (var j = 0; j < rows.length; j++)
                    verify(rows[j].height >= hosts[i].theme.touchTertiary,
                           classes[i] + " dose row " + j + " is >= touchTertiary ("
                           + rows[j].height + ")")
            }
            compare(mLarge.item.rowH, mTall.item.rowH,
                    "the row height does not grow with the box - room buys rows")
        }

        // The tone rule survives the new sizes: an un-marked past dose is quiet.
        function test_an_unmarked_past_dose_is_never_an_alarm_on_a_tile() {
            tryVerify(function () { return mLarge.ready }, 3000)
            var m = mLarge.item
            m.sizeClass = "large"
            seed(mLarge)
            wait(32)
            // 08:00 with the clock at 23:00 is long past and un-marked → "open".
            var open = m.stateOf(m.doses[0], 23 * 60)
            compare(open, "open", "a long-past un-marked dose is 'open', not 'missed'")
            compare(String(m.colorOf(open)), String(mLarge.theme.textTertiary),
                    "…and renders quiet, never error/warning coloured")
            verify(String(m.colorOf(open)) !== String(mLarge.theme.error), "never red")
            compare(m.labelOf(open), "Not marked", "…and says 'Not marked'")
        }

        function test_scaled_long_schedule_wraps_and_remains_reachable() {
            tryVerify(function () { return mTall.ready }, 3000)
            var oldScale = mTall.theme.textScale
            var oldFont = mTall.theme.fontChoice
            try {
                mTallWrap.z = 100
                mTallWrap.width = 278
                mTallWrap.height = 654
                mTall.item.sizeClass = "tall"
                mTall.theme.textScale = 1.45
                mTall.theme.fontChoice = "lexend"
                mTall.storeCtl.resetSettings(mTall.instanceId, {
                    scheduleFormat: "structured",
                    scheduleItems: structuredDoses(24, true),
                    dueWindowMin: 240,
                    taken: [],
                    takenDay: ""
                })
                wait(64)

                var floor = mTall.theme.fontMinimum
                var summary = named(mTall, "medsScheduleSummary")
                var list = listOf(mTall)
                var scrollBar = named(mTall, "medsDoseScrollBar")
                verify(summary && list && scrollBar)
                verify(summary.font.pixelSize >= floor)
                compare(summary.elide, Text.ElideNone)
                compare(summary.truncated, false)
                verify(summary.contentHeight <= summary.height + 1)
                compare(list.orientation, ListView.Vertical)
                compare(list.flickableDirection, Flickable.VerticalFlick,
                        "dose reading does not take the horizontal page gesture")
                compare(list.interactive, true,
                        "a long tile schedule can be read without opening the widget")
                compare(scrollBar.policy, ScrollBar.AlwaysOn,
                        "overflow is disclosed before the first swipe")
                compare(scrollBar.interactive, false)

                var names = prefixed(mTall, "medsDoseName-")
                var times = prefixed(mTall, "medsDoseTime-")
                var states = prefixed(mTall, "medsDoseState-")
                var actions = prefixed(mTall, "medsDoseAction-")
                verify(names.length > 0 && times.length > 0 && states.length > 0)
                for (var i = 0; i < names.length; i++) {
                    verify(names[i].font.pixelSize >= floor)
                    compare(names[i].elide, Text.ElideNone)
                    compare(names[i].truncated, false)
                    verify(names[i].contentHeight <= names[i].height + 1,
                           "medication name " + i + " receives every wrapped line")
                }
                for (var j = 0; j < times.length; j++)
                    verify(times[j].font.pixelSize >= floor)
                for (var k = 0; k < states.length; k++) {
                    verify(states[k].font.pixelSize >= floor)
                    compare(states[k].truncated, false)
                    verify(states[k].contentHeight <= states[k].height + 1)
                }
                for (var a = 0; a < actions.length; a++) {
                    verify(actions[a].width >= mTall.theme.touchTertiary)
                    verify(actions[a].height >= mTall.theme.touchTertiary)
                }
                var rows = doseRows(mTall)
                verify(rows.length > 0)
                list.contentY = rows[0].height / 2
                wait(16)
                var clippedAction = named(mTall, "medsDoseAction-0")
                verify(clippedAction !== undefined)
                compare(clippedAction.enabled, false,
                        "a partially clipped row cannot accept an accidental mark")
                compare(clippedAction.opacity, 0)

                list.positionViewAtBeginning()
                wait(16)
                mouseDrag(list, list.width / 2,
                          list.height - mTall.theme.spacingLg,
                          0, -Math.min(160, list.height / 2),
                          Qt.LeftButton)
                tryVerify(function () { return list.contentY > 0 }, 1000,
                          "a vertical drag reveals later doses")
                list.positionViewAtEnd()
                tryVerify(function () {
                    return named(mTall, "medsDoseName-23") !== undefined
                }, 1000, "the final supported dose is reachable")

                mTall.storeCtl.resetSettings(mTall.instanceId, {
                    scheduleFormat: "structured",
                    scheduleItems: structuredDoses(2, false),
                    taken: [],
                    takenDay: ""
                })
                tryVerify(function () { return !list.interactive }, 1000)
                compare(list.contentY, 0,
                        "a short schedule returns to its beginning")
                compare(scrollBar.policy, ScrollBar.AlwaysOff)
            } finally {
                mTall.theme.textScale = oldScale
                mTall.theme.fontChoice = oldFont
                mTallWrap.width = 348
                mTallWrap.height = 819
                mTallWrap.z = 0
            }
        }

        function test_scaled_focus_view_keeps_name_status_and_action() {
            tryVerify(function () { return mWide.ready }, 3000)
            var oldScale = mWide.theme.textScale
            var oldFont = mWide.theme.fontChoice
            try {
                mWideWrap.z = 100
                mWideWrap.width = 557
                mWideWrap.height = 327
                mWide.item.sizeClass = "wide"
                mWide.item.nowMinsOverride = 45
                mWide.theme.textScale = 1.45
                mWide.theme.fontChoice = "hyperlegible"
                mWide.storeCtl.resetSettings(mWide.instanceId, {
                    scheduleFormat: "structured",
                    scheduleItems: [{
                        id: "focus-dose",
                        time: "00:30",
                        name: "Prescribed morning medicine with extended instructions",
                        days: "0,1,2,3,4,5,6"
                    }],
                    taken: [],
                    takenDay: ""
                })
                wait(64)

                compare(mWide.item.showFocus, true)
                compare(mWide.item.showSchedule, false)
                var name = named(mWide, "medsFocusName")
                var state = named(mWide, "medsFocusState")
                verify(name && state)
                verify(name.font.pixelSize >= mWide.theme.fontMinimum)
                verify(state.font.pixelSize >= mWide.theme.fontMinimum)
                compare(name.elide, Text.ElideNone)
                compare(name.truncated, false)
                verify(name.contentHeight <= name.height + 1)
                compare(state.truncated, false)
                verify(state.contentHeight <= state.height + 1)

                var buttons = root.findAll(mWide.item, function (n) {
                    return n.hasOwnProperty("label")
                           && (n.label === "Mark taken" || n.label === "Undo taken")
                }, [])
                compare(buttons.length, 1)
                verify(buttons[0].width >= mWide.theme.touchTertiary)
                verify(buttons[0].height >= mWide.theme.touchTertiary)
            } finally {
                mWide.theme.textScale = oldScale
                mWide.theme.fontChoice = oldFont
                mWide.item.nowMinsOverride = -1
                mWideWrap.width = 696
                mWideWrap.height = 409
                mWideWrap.z = 0
            }
        }
    }
}
