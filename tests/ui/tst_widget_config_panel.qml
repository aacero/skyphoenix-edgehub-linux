import QtQuick
import QtTest
import "../../ui/qml" as App
import "../../ui/qml/widgets" as Wg

// WidgetConfigPanel (ui/qml/widgets/WidgetConfigPanel.qml) + ConfigField - the
// schema-driven config form shared by the hub and the Manager. Assert: sections
// render (minus the "About" section), fields read their store/default value,
// edits push through setSetting/patchSettings, reset restores defaults, and the
// action field emits actionRequested.
Item {
    id: root
    width: 560; height: 900

    property alias theme: _theme
    App.Theme { id: _theme }
    App.DashboardStore { id: store }

    // Colour + sizing tokens (superset of what ConfigField + the panel need).
    readonly property var col: ({
        textPrimary: "#E6EDF3", textSecondary: "#8B949E", bg: "#0D1117",
        accent: "#58A6FF", border: "#30363D", panel: "#161B22", panelAlt: "#1C222B",
        radius: 12, ctlH: 44, fontBase: 15
    })

    readonly property var schema: ({ sections: [
        { title: "General", cols: 1, fields: [
            { key: "title", label: "Custom title", type: "text", placeholder: "CPU" },
            { key: "showTemp", label: "Show temp", type: "toggle", dflt: true },
            { key: "warn", label: "Warn", type: "slider", min: 0, max: 100, step: 1, dflt: 50 } ] },
        { title: "Extra", cols: 1, fields: [
            { key: "mode", label: "Mode", type: "segmented", dflt: "a",
              options: [ { value: "a", label: "A" }, { value: "b", label: "B" } ] },
            { key: "doThing", type: "action", action: "geocode", actionLabel: "Run" } ] },
        { title: "About this widget", cols: 1, fields: [ { type: "info", text: "Some info." } ] }
    ] })

    Component.onCompleted: store.load("blank")

    Wg.WidgetConfigPanel {
        id: cfg
        anchors.fill: parent
        schema: root.schema
        st: store
        instanceId: "inst"
        col: root.col
    }

    // ── tree helpers ─────────────────────────────────────────────────────────
    function eachItem(node, fn) {
        if (!node) return
        fn(node)
        var kids = node.children
        if (kids) for (var i = 0; i < kids.length; i++) eachItem(kids[i], fn)
    }
    function findPred(node, pred) {
        var f = null
        eachItem(node, function (n) { if (!f && pred(n)) f = n })
        return f
    }
    function findAll(node, pred) {
        var out = []
        eachItem(node, function (n) { if (pred(n)) out.push(n) })
        return out
    }
    function findText(node, str) {
        return findPred(node, function (n) {
            return n.text !== undefined && typeof n.text === "string" && n.text === str
        })
    }
    function fieldItem(key) {
        return findPred(cfg, function (n) { return n.objectName === "field-" + key })
    }
    function configFields() {
        return findAll(cfg, function (n) {
            return typeof n.objectName === "string"
                   && n.objectName.indexOf("field-") === 0
                   && n.objectName !== "field-preview"
        })
    }

    TestCase {
        name: "WidgetConfigPanel"
        when: windowShown

        function init() {
            var s = store.settingsFor("inst")
            for (var k in s) delete s[k]
            store._touchSettings()
        }

        // ── Section grouping ─────────────────────────────────────────────────
        function test_sections_render_excluding_about() {
            verify(findText(cfg, "General") !== null, "General section rendered")
            verify(findText(cfg, "Extra") !== null, "Extra section rendered")
            verify(findText(cfg, "About this widget") === null,
                   "the About section is not rendered in the form (it duplicates the header)")
        }

        function test_all_non_about_fields_render() {
            // 3 (General) + 2 (Extra) = 5 fields; About's info field is excluded.
            compare(configFields().length, 5, "one ConfigField per non-About field")
        }

        // ── Field reads default / store value ────────────────────────────────
        function test_toggle_reads_default() {
            var f = fieldItem("showTemp")
            verify(f !== null, "toggle field present")
            var sw = findPred(f, function (n) { return n.objectName === "control" })
            verify(sw !== null, "toggle control present")
            compare(sw.checked, true, "toggle reflects its schema default (true)")
        }

        function test_slider_reads_default() {
            var f = fieldItem("warn")
            var sl = findPred(f, function (n) {
                return n.from !== undefined && n.to !== undefined && n.stepSize !== undefined && n.value !== undefined
            })
            verify(sl !== null, "slider present")
            fuzzyCompare(sl.value, 50, 0.001, "slider reflects its schema default (50)")
        }

        function test_segmented_default_selected() {
            var f = fieldItem("mode")
            var segs = findAll(f, function (n) { return n.sel !== undefined && n.modelData !== undefined })
            compare(segs.length, 2, "two segments")
            var sel = segs.filter(function (s) { return s.sel })
            compare(sel.length, 1, "exactly one selected")
            compare(sel[0].modelData.value, "a", "the default value is selected")
        }

        // ── Edits push through the store ─────────────────────────────────────
        function test_toggle_click_writes_setSetting() {
            var f = fieldItem("showTemp")
            var sw = findPred(f, function (n) { return n.objectName === "control" })
            mouseClick(sw)
            compare(store.settingsFor("inst").showTemp, false, "tapping the toggle writes through setSetting")
        }

        function test_segment_click_writes_setSetting() {
            var f = fieldItem("mode")
            var segB = findPred(f, function (n) {
                return n.sel !== undefined && n.modelData !== undefined && n.modelData.value === "b"
            })
            verify(segB !== null, "segment B present")
            mouseClick(segB)
            compare(store.settingsFor("inst").mode, "b", "tapping a segment writes through setSetting")
        }

        // ── External store push (patchSettings) re-reads into the control ────
        function test_patchSettings_reflected_in_slider() {
            store.patchSettings("inst", { warn: 77 })
            var f = fieldItem("warn")
            var sl = findPred(f, function (n) { return n.from !== undefined && n.stepSize !== undefined })
            fuzzyCompare(sl.value, 77, 0.001, "an external patchSettings is re-read into the slider")
        }

        // ── Reset restores defaults ──────────────────────────────────────────
        function test_reset_restores_default_in_control() {
            store.setSetting("inst", "showTemp", false)
            var f = fieldItem("showTemp")
            var sw = findPred(f, function (n) { return n.objectName === "control" })
            compare(sw.checked, false, "precondition: edited to false")
            store.resetSettings("inst", { showTemp: true })   // the "Reset to defaults" action
            compare(sw.checked, true, "reset restores the default and the control re-reads it")
        }

        // ── Action field emits actionRequested ───────────────────────────────
        function test_action_field_emits_actionRequested() {
            var spy = actionSpy.createObject(root, { target: cfg, signalName: "actionRequested" })
            var f = fieldItem("doThing")
            var runBtn = findText(f, "Run")
            verify(runBtn !== null, "action button rendered")
            mouseClick(runBtn.parent)     // the action Rectangle wraps a MouseArea
            compare(spy.count, 1, "actionRequested fired once")
            compare(spy.signalArguments[0][0], "geocode", "…with the field's action id")
            spy.destroy()
        }
    }

    Component { id: actionSpy; SignalSpy {} }
}
