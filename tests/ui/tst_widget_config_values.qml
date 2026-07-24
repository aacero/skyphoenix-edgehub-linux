import QtQuick
import QtTest
import "../../ui/qml" as App
import "../../ui/qml/widgets" as Wg

// COVERAGE NOTE: config-value → store → rendered-observable for the CPU widget.
//
// O4 (widget configuration coverage). WidgetConfigDialog.qml ships ~16 KB of
// per-tile config UI, but no test drove a config VALUE through the store and
// asserted it (a) lands in the tile's settings bucket AND (b) actually changes
// what the widget renders. This file closes that gap for CPU, the richest
// display widget: it owns every config field kind the schema exposes - a text
// field (custom title), two toggles (showTemp / showHistory), a slider
// (warnTemp), and the two universal appearance keys (accent / cardBackdrop).
//
// The dialog itself only wires store.setSetting(id, key, val) + the appearance
// bindings (titleOverride / accentName / cardBackdrop) onto the live widget -
// see WidgetHost. This test reproduces exactly that binding path (the
// store write plus the same three Qt.bindings) against a harness-hosted CPU
// widget and asserts the OBSERVABLE the field is supposed to drive.
//
// Every assertion here is written so it FAILS if the widget ignores the config:
// the observable is the rendered header text / the header status Text's
// visibility / the gauge's history array / the gauge's ring colour - never a
// re-read of the value that was just written. (The store re-read is asserted
// too, but only as the first link in the chain: store → widget.cfg → render.)
Item {
    id: root
    width: 520; height: 440

    // A file-root `theme` so directly-instantiated shared components resolve the
    // `theme` global by name, the way the harness provides it to loaded widgets.
    property alias theme: rootTheme
    App.Theme { id: rootTheme }

    WidgetHarness {
        id: h
        anchors.fill: parent
        widgetFile: "CpuWidget.qml"
        expanded: true
    }

    // ── Visual-tree helpers ──────────────────────────────────────────────────
    function eachItem(node, fn) {
        if (!node) return
        fn(node)
        var kids = node.children
        if (kids)
            for (var i = 0; i < kids.length; i++) eachItem(kids[i], fn)
    }
    function findPred(rootNode, pred) {
        var f = null
        eachItem(rootNode, function (n) { if (!f && pred(n)) f = n })
        return f
    }
    // MetricGauge: duck-typed by its distinctive property set. `color` is the
    // input the ring's progressColor binds to (MetricGauge.qml) - the rendered
    // colour observable the accent/warnTemp fields must move.
    function findGauge(rootNode) {
        return findPred(rootNode, function (n) {
            return n.big !== undefined && n.history !== undefined
                   && n.ok !== undefined && n.color !== undefined
        })
    }
    // The header status Text (top-right): mono font, visible-bound to status.
    // Duck-typed by an exact text match so we capture the very node showTemp
    // toggles, then re-assert that same node after the write.
    function findExactText(rootNode, str) {
        return findPred(rootNode, function (n) {
            return n.text !== undefined && typeof n.text === "string" && n.text === str
        })
    }
    function findHeaderTitle(rootNode, str) { return findExactText(rootNode, str) }

    function feed(obj) { h.metricsJson = JSON.stringify(obj) }

    TestCase {
        name: "CpuConfigValues"
        when: windowShown

        // Wire the per-instance appearance bindings exactly as
        // WidgetHost does in WidgetConfigDialog and Dashboard (the harness
        // does not). Without this the title/accent config has nothing to flow
        // through and the "custom title" / "accent" assertions could never move.
        function wireAppearance(w) {
            w.titleOverride = Qt.binding(function () {
                h.storeCtl.revision; var s = h.storeCtl.settingsFor("test-instance")
                return (s && s.title) ? s.title : ""
            })
            w.accentName = Qt.binding(function () {
                h.storeCtl.revision; var s = h.storeCtl.settingsFor("test-instance")
                return (s && s.accent) ? s.accent : ""
            })
            w.cardBackdrop = Qt.binding(function () {
                h.storeCtl.revision; var s = h.storeCtl.settingsFor("test-instance")
                return (s && s.cardBackdrop) ? s.cardBackdrop : "none"
            })
        }

        function init() {
            tryVerify(function () { return h.ready }, 3000)
            // Clear the instance settings bucket so each case starts at defaults.
            var s = h.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            h.storeCtl._touchSettings()
            h.metricsJson = "{}"
            h.expanded = true
            h.active = true
            h.item.hist = []
            wireAppearance(h.item)
        }

        // ── text field: "Custom title" ───────────────────────────────────────
        // Observable: the header title Text renders titleOverride when set,
        // otherwise the widget's own title ("CPU").
        function test_title_field_changes_header_text() {
            var w = h.item
            // Precondition: with no override the header shows the default "CPU".
            verify(findHeaderTitle(w, "CPU") !== null, "header shows the default 'CPU' title")

            // Drive the config value through the store, as the dialog does.
            h.storeCtl.setSetting("test-instance", "title", "Processor")

            // (a) stored in the tile's settings bucket, and re-read by the widget.
            compare(h.storeCtl.settingsFor("test-instance").title, "Processor",
                    "custom title lands in the tile's settings")
            compare(w.titleOverride, "Processor", "widget re-reads the title from the store")

            // (b) the rendered header actually changes: the custom title appears
            // and the default no longer does.
            verify(findHeaderTitle(w, "Processor") !== null,
                   "the header Text renders the custom title")
            verify(findHeaderTitle(w, "CPU") === null,
                   "the default 'CPU' header text is replaced, not shown alongside")
        }

        // ── toggle: "Show temperature" ───────────────────────────────────────
        // Observable: the header status Text (top-right). showTemp=false must
        // empty w.status AND hide that Text node; it also disables temp-based
        // ring escalation.
        function test_showTemp_toggle_hides_header_status() {
            var w = h.item
            feed({ cpu_usage_percent: 20, cpu_temp_celsius: 58 })
            compare(w.status, "58°C", "precondition: temperature shows in the header")
            var statusText = findExactText(w, "58°C")
            verify(statusText !== null, "the header status Text renders the temperature")
            verify(statusText.visible, "and it is visible while showTemp is on")

            h.storeCtl.setSetting("test-instance", "showTemp", false)

            compare(h.storeCtl.settingsFor("test-instance").showTemp, false,
                    "showTemp=false lands in the tile's settings")
            compare(w.showTemp, false, "widget re-reads showTemp from the store")

            compare(w.status, "", "the header status is emptied when temperature is hidden")
            verify(!statusText.visible,
                   "the very Text node that showed 58°C is now hidden")
            // The hot reading must no longer escalate the ring once temp is off.
            verify(Qt.colorEqual(w.col(w.v), w.effAccent),
                   "with showTemp off a hot CPU no longer reddens the ring")
        }

        // ── toggle: "Show the history graph" ─────────────────────────────────
        // Observable: the samples handed to the gauge's sparkline.
        function test_showHistory_toggle_empties_gauge_history() {
            var w = h.item
            w.hist = []
            feed({ cpu_usage_percent: 30 })
            feed({ cpu_usage_percent: 40 })
            var g = findGauge(w)
            verify(g !== null, "gauge present")
            verify(g.history.length >= 2, "precondition: the sparkline has samples")

            h.storeCtl.setSetting("test-instance", "showHistory", false)

            compare(h.storeCtl.settingsFor("test-instance").showHistory, false,
                    "showHistory=false lands in the tile's settings")
            compare(w.showHistory, false, "widget re-reads showHistory from the store")

            compare(findGauge(w).history.length, 0,
                    "the sparkline receives no samples when the graph is hidden")

            h.storeCtl.setSetting("test-instance", "showHistory", true)
            verify(findGauge(w).history.length >= 2,
                   "and the graph returns when the toggle is switched back on")
        }

        // ── slider: "Warn above" (warnTemp) ──────────────────────────────────
        // Observable: the temperature at which the gauge/ring colour escalates.
        // A fixed 55°C reading is comfortable at the default warnTemp (85) but
        // amber once the slider drops to 60 (amber boundary = warnTemp-12 = 48).
        function test_warnTemp_slider_moves_escalation_boundary() {
            var w = h.item
            feed({ cpu_usage_percent: 10, cpu_temp_celsius: 55 })   // low load, mild temp
            verify(Qt.colorEqual(w.col(w.v), w.effAccent),
                   "precondition: 55°C is comfortable at the default warnTemp (85)")
            var g = findGauge(w)
            // The gauge colour eases (Behavior on color); let it settle.
            tryVerify(function () { return Qt.colorEqual(findGauge(w).color, w.effAccent) },
                      2000, "the ring renders the comfortable accent at warnTemp 85")

            h.storeCtl.setSetting("test-instance", "warnTemp", 60)

            compare(h.storeCtl.settingsFor("test-instance").warnTemp, 60,
                    "warnTemp lands in the tile's settings")
            compare(w.warnTemp, 60, "widget re-reads warnTemp from the store")

            // Same 55°C reading is now above the (60-12)=48 amber boundary.
            verify(Qt.colorEqual(w.col(w.v), h.theme.warning),
                   "55°C turns amber once warnTemp drops to 60")
            tryVerify(function () { return Qt.colorEqual(findGauge(w).color, h.theme.warning) },
                      2000, "and the rendered ring colour follows to amber")
        }

        // ── universal: "Accent colour" ───────────────────────────────────────
        // Observable: the widget's effective accent and the comfortable-state
        // ring colour, which resolve to the chosen preset.
        function test_accent_field_recolors_ring() {
            var w = h.item
            // Default accent is the System category colour.
            verify(Qt.colorEqual(w.effAccent, h.theme.catSystem),
                   "precondition: default effAccent is the System category colour")

            h.storeCtl.setSetting("test-instance", "accent", "green")

            compare(h.storeCtl.settingsFor("test-instance").accent, "green",
                    "accent lands in the tile's settings")
            compare(w.accentName, "green", "widget re-reads the accent from the store")

            var preset = h.theme.accentPresets["green"].a
            verify(Qt.colorEqual(w.effAccent, preset),
                   "effAccent resolves to the chosen preset")
            feed({ cpu_usage_percent: 50 })   // comfortable: no temp, moderate load
            verify(Qt.colorEqual(w.col(w.v), preset),
                   "the comfortable ring/number use the configured accent")
            tryVerify(function () { return Qt.colorEqual(findGauge(w).color, preset) },
                      2000, "and the rendered gauge colour follows to the preset")
        }

        // ── universal: "Card backdrop" ───────────────────────────────────────
        // Observable: the in-card BackdropLayer's style + visibility.
        function test_cardBackdrop_field_renders_selected_style() {
            var w = h.item
            h.storeCtl.setSetting("test-instance", "cardBackdrop", "aurora")

            compare(h.storeCtl.settingsFor("test-instance").cardBackdrop, "aurora",
                    "cardBackdrop lands in the tile's settings")
            compare(w.cardBackdrop, "aurora", "widget re-reads the backdrop from the store")

            // BackdropLayer: has `style` + `running` (a Text has `style` but no `running`).
            var bd = findPred(w, function (n) {
                return n.style !== undefined && n.running !== undefined
            })
            verify(bd !== null, "the in-card backdrop layer exists")
            compare(bd.style, "aurora", "the backdrop renders the selected style")
            verify(bd.visible, "the backdrop is visible (default theme is decorative)")
        }
    }
}
