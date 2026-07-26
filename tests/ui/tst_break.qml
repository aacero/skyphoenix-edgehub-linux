import QtQuick
import QtTest

// BreakWidget - verifies persistent/shared timer state and the audited fix that
// the compact "Done" action (reset) is reachable and works, plus interval clamp.
Item {
    id: root
    width: 420; height: 820
    WidgetHarness { id: h; anchors.fill: parent; widgetFile: "BreakWidget.qml"; expanded: true }
    property int priorityAlertCount: 0
    property var lastPriorityAlert: null
    QtObject {
        id: prioritySink
        function showPriorityAlert(request) {
            root.priorityAlertCount++
            root.lastPriorityAlert = request
            return true
        }
    }

    TestCase {
        name: "BreakWidget"
        when: windowShown

        function init() {
            tryVerify(function () { return h.ready }, 3000)
            // These lifecycle cases test timer actions, not office-hours policy.
            // Pin an all-day, all-week schedule so wall-clock test execution does
            // not change whether reset/resume owns a live deadline.
            h.storeCtl.patchSettings("test-instance", {
                workStartHour: 0, workEndHour: 0, workDays: "0,1,2,3,4,5,6",
                scheduleSuspended: false, priorityAlertEnabled: true
            })
            h.item.priorityAlerts = prioritySink
            root.priorityAlertCount = 0
            root.lastPriorityAlert = null
        }
        function cfg() { return h.storeCtl.settingsFor("test-instance") }

        function test_reset_clears_due_and_restarts() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { due: true })
            compare(w.due, true)
            w.reset()
            compare(cfg().due, false, "reset clears due")
            verify(cfg().endEpoch > 0, "reset seeds a fresh end epoch")
            verify(cfg().running === true)
        }

        function test_toggle_persists() {
            var w = h.item
            w.reset()
            verify(w.running)
            w.toggleRun()  // pause
            compare(cfg().running, false)
            verify(cfg().pausedRemaining !== undefined)
            w.toggleRun()  // resume
            compare(cfg().running, true)
            verify(cfg().endEpoch > 0)
        }

        function test_setinterval_clamps() {
            var w = h.item
            w.setInterval(3)      // below min 5
            compare(cfg().intervalMin, 5)
            w.setInterval(999)    // above max 120
            compare(cfg().intervalMin, 120)
            w.setInterval(45)
            compare(cfg().intervalMin, 45)
        }

        function test_state_lives_in_store_not_widget() {
            // Timer state must be persisted in the store (so tile + expanded, which
            // are separate widget instances bound to the same id, share it and it
            // survives restart) - not in widget-local properties as before.
            var w = h.item
            w.reset()
            var ep = cfg().endEpoch
            verify(ep > 0)
            // Mutating the store is reflected in the widget's derived state.
            h.storeCtl.patchSettings("test-instance", { running: false, pausedRemaining: 123 })
            compare(w.running, false)
            w.pulse++
            compare(w.remaining, 123, "widget reads remaining from the store")
        }

        function test_due_event_requests_a_persistent_actionable_alert() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", {
                due: false, running: false, pausedRemaining: 0,
                priorityAlertEnabled: true
            })
            compare(w.remaining, 0)
            verify(w.markDue(), "zero countdown enters the due state")
            compare(root.priorityAlertCount, 1,
                    "one due transition requests exactly one priority alert")
            compare(root.lastPriorityAlert.key, "break:test-instance")
            compare(root.lastPriorityAlert.primaryLabel, "I took a break")
            compare(root.lastPriorityAlert.secondaryLabel, "Snooze 5 min")
            verify(typeof root.lastPriorityAlert.primaryCallback === "function")
            verify(typeof root.lastPriorityAlert.secondaryCallback === "function")

            root.lastPriorityAlert.primaryCallback()
            compare(cfg().due, false, "the primary alert action acknowledges the break")
            verify(cfg().endEpoch > 0, "acknowledgement starts a fresh interval")
        }

        function test_full_screen_alert_can_be_disabled_without_disabling_due_state() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", {
                due: false, running: false, pausedRemaining: 0,
                priorityAlertEnabled: false
            })
            verify(w.markDue())
            compare(cfg().due, true, "the underlying reminder still becomes due")
            compare(root.priorityAlertCount, 0,
                    "only the full-screen alert is disabled")
        }
    }
}
