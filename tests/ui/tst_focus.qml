import QtQuick
import QtTest

// FocusWidget - verifies the timer logic and the audited fixes:
//  * reset()/applyPreset() clear the REAL persisted key (doneToday), not the
//    derived read-only completedWork.
//  * "+5" never drives the ring fill negative.
//  * start/pause/skip persist correctly and phases advance.
Item {
    id: root
    width: 420; height: 820
    WidgetHarness { id: h; anchors.fill: parent; widgetFile: "FocusWidget.qml"; expanded: true }
    property int priorityAlertCalls: 0
    property var lastPriorityAlert: null
    property int desktopPriorityCalls: 0
    QtObject {
        id: prioritySink
        function showPriorityAlert(request) {
            root.priorityAlertCalls++
            root.lastPriorityAlert = request
            return true
        }
    }
    QtObject {
        id: notificationSink
        function send(summary, body) { return true }
        function sendPriority(summary, body) {
            root.desktopPriorityCalls++
            return true
        }
    }

    TestCase {
        name: "FocusWidget"
        when: windowShown

        function init() {
            tryVerify(function () { return h.ready }, 3000)
            // Clean slate per test - settings would otherwise leak between tests
            // (they run in alphabetical order and share one instance).
            var s = h.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            h.storeCtl._touchSettings()
            h.item.priorityAlerts = prioritySink
            h.item.notificationBridge = notificationSink
            h.item.foreground = true
            root.priorityAlertCalls = 0
            root.lastPriorityAlert = null
            root.desktopPriorityCalls = 0
        }

        function cfg() { return h.storeCtl.settingsFor("test-instance") }

        function test_reset_preserves_done_today() {
            var w = h.item
            // Simulate sessions completed today.
            h.storeCtl.patchSettings("test-instance", { doneToday: 3, day: w.today() })
            compare(w.completedWork, 3)
            w.reset()
            // Reset restarts the TIMER; it must NOT wipe the day's earned count.
            compare(cfg().doneToday, 3, "reset keeps today's earned session count")
            compare(w.phase, "work", "reset returns to the work phase")
            verify(!w.running, "reset stops the timer")
            verify(cfg().completedWork === undefined, "no stray completedWork key written")
        }

        function test_applypreset_switches_preserving_count() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { doneToday: 2, day: w.today() })
            w.applyPreset("deep")
            compare(cfg().preset, "deep")
            compare(w.presetName, "deep")
            compare(cfg().doneToday, 2, "switching preset keeps the day's count")
            compare(w.phase, "work", "preset switch returns to work phase")
        }

        function test_start_pause_persist() {
            var w = h.item
            w.reset()
            verify(!w.running)
            w.toggle()  // start
            verify(cfg().running === true)
            verify(cfg().endEpoch > 0, "start sets an absolute end epoch")
            w.toggle()  // pause
            verify(cfg().running === false)
            verify(cfg().pausedRemaining !== undefined, "pause captures remaining")
        }

        function test_plus5_ring_never_negative() {
            var w = h.item
            w.reset()
            w.toggle() // running
            for (var i = 0; i < 20; i++) w.addFive()  // push remaining far past phaseTotal
            verify(w.ringValue >= 0, "ring fill fraction stays >= 0 (was underflowing)")
            verify(w.ringValue <= 1, "ring fill fraction stays <= 1")
        }

        function test_skip_advances_without_counting() {
            var w = h.item
            w.reset()  // phase = work, doneToday = 0
            w.skip()
            // A MANUAL skip advances the phase but must not count/reward - you
            // didn't actually finish the focus session.
            compare(cfg().doneToday || 0, 0, "a manual skip does NOT count as a completed session")
            verify(w.phase === "short" || w.phase === "long", "skip still advances to a break phase")
        }

        function test_natural_completion_counts() {
            var w = h.item
            w.reset()
            w.advance(true)  // timer-driven (natural) completion of the work phase
            compare(cfg().doneToday, 1, "a timer-driven completion counts a session")
            verify(w.phase === "short" || w.phase === "long", "advanced to a break phase")
        }

        function test_remaining_never_negative() {
            var w = h.item
            w.reset()
            w.toggle()
            // Force an end epoch in the past; remaining must clamp to 0.
            h.storeCtl.patchSettings("test-instance", { running: true, endEpoch: 1 })
            w.pulse++  // re-evaluate
            verify(w.remaining >= 0)
        }

        // The reported bug: choose a preset, then the timer won't start / the ring
        // doesn't reflect the new duration.
        function test_preset_then_start() {
            var w = h.item
            w.applyPreset("deep")
            compare(w.presetName, "deep")
            compare(w.p.work, 50)
            tryVerify(function () { return w.remaining === 3000 }, 1000,
                      "idle clock shows Deep's 50:00 (3000s)")
            compare(w.ringValue, 0, "ring empty (full time) on a fresh preset")
            verify(!w.running)
            w.toggle()   // START
            verify(w.running, "timer starts after choosing a preset")
            verify(cfg().running === true)
            verify(cfg().endEpoch > 0, "start sets an end epoch after a preset change")
        }

        // Changing the custom length (as the config panel does) resets the idle clock.
        function test_custom_length_change_resets_idle_clock() {
            var w = h.item
            w.applyPreset("custom")
            tryVerify(function () { return w.remaining === w.workMin * 60 }, 1000)
            h.storeCtl.patchSettings("test-instance", { workMin: 40 })
            tryVerify(function () { return w.remaining === 2400 }, 1000,
                      "idle clock follows a custom-length change (40:00)")
        }

        // ADHD momentum: points accrue per session with a bonus on hitting the goal.
        function test_reward_points_and_goal_bonus() {
            var w = h.item
            w.reset()
            h.storeCtl.patchSettings("test-instance", { points: 0, dailyGoal: 2 })
            w.advance(true)              // work #1 → +10, done=1, → break
            compare(cfg().doneToday, 1)
            compare(cfg().points, 10, "10 points per completed session")
            w.advance(true)              // break → work (no points)
            compare(cfg().doneToday, 1)
            w.advance(true)              // work #2 hits the goal → +10 +50
            compare(cfg().doneToday, 2)
            compare(cfg().points, 70, "goal bonus (+50) awarded on hitting the daily goal")
        }

        function test_celebrate_message_on_session() {
            var w = h.item
            w.reset()
            w.celebrateMsg = ""
            w.advance(true)              // a natural (timer-driven) completion celebrates
            verify(w.celebrateMsg.length > 0, "a celebration message pops on a completed session")
        }

        // Per-widget appearance (WidgetChrome, so it applies to every widget).
        function test_accent_override() {
            var w = h.item
            compare(String(w.effAccent), String(w.accentColor), "no override → widget's own accent")
            w.accentName = "green"
            compare(String(w.effAccent), String(Qt.color(h.theme.accentPresets["green"].a)),
                    "accent name overrides the effective accent")
            w.accentName = ""
            compare(String(w.effAccent), String(w.accentColor), "cleared override falls back")
        }

        function test_card_backdrop_property() {
            var w = h.item
            compare(w.cardBackdrop, "none")
            w.cardBackdrop = "orbs"
            compare(w.cardBackdrop, "orbs", "per-widget backdrop is settable")
            w.cardBackdrop = "none"
        }

        function test_points_off_when_disabled() {
            var w = h.item
            w.reset()
            h.storeCtl.patchSettings("test-instance", { points: 0, rewardPoints: false })
            w.advance(true)
            compare(cfg().points, 0, "no points accrue when rewards are disabled")
        }

        function test_hidden_completion_uses_persistent_hub_and_desktop_alerts() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { notifyWhenHidden: true })
            w.foreground = false
            verify(w.notifyCompletion("work", "short"))
            compare(root.priorityAlertCalls, 1)
            compare(root.desktopPriorityCalls, 1)
            compare(root.lastPriorityAlert.title, "Focus session complete")
            compare(root.lastPriorityAlert.primaryAction, "openWidget")
            compare(root.lastPriorityAlert.sourceId, "test-instance")
        }

        // notifyCompletion() is a 2x3 matrix - which phase ENDED decides the
        // eyebrow, summary and accent; which phase is NEXT decides the body.
        // Exactly one cell was covered ("work" -> "short"), and it asserted the
        // title only. A break ending could have announced "FOCUS COMPLETE" and
        // nothing would have noticed; neither `eyebrow` nor `body` appeared in
        // any assertion.
        function test_the_alert_says_which_phase_ended_data() {
            return [
                { tag: "work-ended", ended: "work",
                  eyebrow: "FOCUS COMPLETE", title: "Focus session complete" },
                { tag: "break-ended", ended: "break",
                  eyebrow: "BREAK COMPLETE", title: "Break complete" }
            ]
        }
        function test_the_alert_says_which_phase_ended(data) {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { notifyWhenHidden: true })
            w.foreground = false
            verify(w.notifyCompletion(data.ended, "short"))
            compare(root.lastPriorityAlert.eyebrow, data.eyebrow,
                    data.ended + " ending is announced as " + data.eyebrow)
            compare(root.lastPriorityAlert.title, data.title)
        }

        // ...and which phase is coming, which is the part the user acts on.
        function test_the_alert_says_what_comes_next_data() {
            return [
                { tag: "next-work",  next: "work",
                  body: "Ready for another focus session." },
                { tag: "next-long",  next: "long",
                  body: "Your long break is ready." },
                { tag: "next-short", next: "short",
                  body: "Your short break is ready." }
            ]
        }
        function test_the_alert_says_what_comes_next(data) {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { notifyWhenHidden: true })
            w.foreground = false
            verify(w.notifyCompletion("work", data.next))
            compare(root.lastPriorityAlert.body, data.body,
                    "a " + data.next + " phase next reads as: " + data.body)
            // A long break and a short break are different rewards; saying the
            // wrong one is worse than saying nothing.
            verify(String(root.lastPriorityAlert.body).length > 0)
        }

        // The alert must remain actionable however it was reached.
        function test_every_completion_alert_can_open_the_timer() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { notifyWhenHidden: true })
            w.foreground = false
            w.notifyCompletion("break", "work")
            compare(root.lastPriorityAlert.primaryAction, "openWidget")
            compare(root.lastPriorityAlert.primaryLabel, "Open timer")
            compare(root.lastPriorityAlert.detail,
                    "The next phase is ready in your Focus Timer.")
            compare(root.lastPriorityAlert.widgetType, "focus",
                    "and it is attributable to the widget that raised it")
        }

        function test_visible_completion_keeps_the_existing_in_widget_feedback() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { notifyWhenHidden: true })
            w.foreground = true
            compare(w.notifyCompletion("work", "short"), false)
            compare(root.priorityAlertCalls, 0)
            compare(root.desktopPriorityCalls, 0)
        }
    }
}
