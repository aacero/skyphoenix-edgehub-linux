import QtQuick
import QtQuick.Controls
import QtTest
import "../../ui/qml" as App
import "../../ui/qml/widgets" as Widgets

// Focus config panel - REAL GUI interaction on the shared WidgetConfigPanel (the
// same component the Manager dialog and the on-device config view use). Proves
// every control is clickable + wired, and that mouse-wheel scrolling moves a
// sensible amount. These are exactly what "Manager buttons don't click / scroll
// is far too slow" would fail on.
Item {
    id: root
    width: 760; height: 2200          // tall enough that the whole form is visible

    property var col: ({
        textPrimary: "#E6EDF3", textSecondary: "#8B949E", bg: "#0D1117",
        accent: "#58A6FF", border: "#30363D", panel: "#161B22", panelAlt: "#1C222B",
        radius: 10, ctlH: 46
    })

    App.Theme { id: theme }
    App.DashboardStore { id: store }
    App.WidgetConfigSchema { id: sc }

    // Tall panel for click tests (no scrolling needed → every control on screen).
    Widgets.WidgetConfigPanel {
        id: panel
        x: 0; y: 0; width: 400; height: root.height
        schema: sc.schemaFor("focus")
        st: store
        instanceId: "t"
        col: root.col
    }

    // Small panel beside it, purely to test scrolling (content overflows).
    Widgets.WidgetConfigPanel {
        id: scrollPanel
        x: 410; y: 0; width: 340; height: 240
        schema: sc.schemaFor("focus")
        st: store
        instanceId: "t2"
        col: root.col
    }

    TestCase {
        name: "FocusConfigPanel"
        when: windowShown

        function initTestCase() {
            store.load("blank")
            store.ensureSettings("t", {})
            store.ensureSettings("t2", {})
        }
        function init() { tryVerify(function () { return panel.width > 0 }, 2000) }

        function cfg() { return store.settingsFor("t") }

        function toggleOf(key) { return findChild(findChild(panel, "field-" + key), "control") }

        // The reported bug: config toggles can't be clicked.
        function test_toggle_is_clickable_and_wired() {
            var sw = toggleOf("celebrate")
            verify(sw, "the 'celebrate' toggle rendered")
            verify(sw.width > 0 && sw.height > 0, "control has a real clickable size")
            verify(sw.checked === true, "defaults on (celebrate dflt true)")
            mouseClick(sw)
            compare(cfg().celebrate, false, "clicking the toggle persisted celebrate=false")
            verify(sw.checked === false, "control reflects the new state")
            mouseClick(sw)
            compare(cfg().celebrate, true, "clicks toggle back on")
        }

        function test_all_toggles_click() {
            var keys = ["autoStartBreak", "rewardPoints", "showNudges", "breakSuggestions"]
            for (var i = 0; i < keys.length; i++) {
                var sw = toggleOf(keys[i])
                verify(sw, keys[i] + " toggle rendered")
                var before = sw.checked
                mouseClick(sw)
                verify(sw.checked !== before, keys[i] + " toggled on click")
                compare(cfg()[keys[i]], sw.checked, keys[i] + " persisted to the store")
            }
        }

        function test_number_stepper_plus_minus() {
            store.setSetting("t", "preset", "custom")
            var field = findChild(panel, "field-workMin")
            verify(field, "workMin field rendered")
            tryVerify(function () { return field.visible }, 1000,
                      "custom lengths become visible for the Custom preset")
            wait(50)
            var formScroll = findChild(panel, "cfgScroll")
            var fieldPos = field.mapToItem(formScroll.contentItem, 0, 0)
            formScroll.contentY = Math.max(0, Math.min(
                formScroll.contentHeight - formScroll.height,
                fieldPos.y - formScroll.height / 3))
            wait(0)
            var start = Number(field.cur())
            var plus = findChild(field, "numberIncrement")
            var minus = findChild(field, "numberDecrement")
            verify(plus && minus, "the number stepper exposes both touch targets")
            verify(plus.visible && plus.width >= 44 && plus.height >= 44,
                   "the increment target is visible and touch-sized")
            mouseClick(plus, plus.width / 2, plus.height / 2)
            wait(0)
            compare(Number(field.cur()), start + 1, "plus stepped the value up")
            mouseClick(minus, minus.width / 2, minus.height / 2)
            wait(0)
            compare(Number(field.cur()), start, "minus stepped it back")
        }

        // The reported bug: scrolling is extremely slow / barely moves.
        function test_wheel_scroll_moves_a_sensible_amount() {
            var f = findChild(scrollPanel, "cfgScroll")   // the Flickable itself
            verify(f, "scroll flickable exists")
            verify(f.contentHeight > f.height, "content overflows so scrolling is meaningful")
            f.contentY = 0
            mouseWheel(scrollPanel, scrollPanel.width / 2, scrollPanel.height / 2, 0, -120)
            tryVerify(function () { return f.contentY >= 100 }, 1000,
                      "one wheel notch scrolled a sensible distance (>=100px), got " + f.contentY)
        }
    }
}
