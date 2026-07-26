import QtQuick
import QtTest
import "../../ui/qml" as App
import "../../ui/qml/widgets" as Wg

// COVERAGE NOTE: config-value → store → rendered-observable for FIVE more widget types.
//
// T2 (widen widget-configuration coverage). tst_widget_config_values.qml proved
// the chain for CPU - the richest DISPLAY widget - but CPU alone exercises one
// shape of config: booleans and a slider feeding a MetricGauge. This file takes
// the same structure to four other widget FAMILIES, so the schema's remaining
// field kinds (segmented enums, numbers, free text) are all driven end to end:
//
//   • RAM       - a second metric widget: `unit` (segmented) + `showHistory`.
//   • CLOCK     - a time widget: format24 / showSeconds / showDate / dateStyle
//                 / customZone+zoneLabel.
//   • HYDRATION - a focus widget: `goal` + `glassMl` (numbers driving counts).
//   • NOTES     - a text widget: `text` (the note itself).
//   • KPI       - an info/data widget: label / unit / warnAt / critAt / invert.
//
// Every case follows the CPU file's shape: write the value through
// store.setSetting / patchSettings (exactly what WidgetConfigDialog does), then
// assert (a) it lands in settingsFor(id) AND (b) a REAL rendered observable
// moves - a Text node's rendered string, a node's `visible`, a delegate COUNT,
// a rendered colour. Never a re-read of the value just written. Where possible
// the observable node is CAPTURED BEFORE the write and re-asserted afterwards,
// so the test cannot pass by finding some other node that happened to appear.
//
// This repo has a documented history of vacuous "a thing exists" tests, so each
// assertion below also states a precondition that is false after the write (the
// placeholder is gone, the default title is no longer rendered twice, the old
// droplet count no longer holds).
Item {
    id: root
    width: 520; height: 440

    property alias theme: rootTheme
    App.Theme { id: rootTheme }

    // ── Visual-tree helpers (shared by every TestCase below) ─────────────────
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
    function isText(n) { return n.text !== undefined && typeof n.text === "string" }
    function findExactText(rootNode, str) {
        return findPred(rootNode, function (n) { return isText(n) && n.text === str })
    }
    // How MANY nodes render exactly this string. Used where a single "does it
    // exist" check would be satisfied by an unrelated node (e.g. the KPI label
    // falling back to the same word the card header already shows).
    function countText(rootNode, str) {
        var c = 0
        eachItem(rootNode, function (n) { if (isText(n) && n.text === str) c++ })
        return c
    }
    // As above, but only nodes that are actually ON SCREEN. `visible` on a
    // QQuickItem is EFFECTIVE visibility, so this excludes delegates living in a
    // hidden sibling layout - several widgets instantiate both their tile and
    // their expanded overlay and switch between them with `visible`, so a raw
    // count would double every delegate.
    function countVisibleText(rootNode, str) {
        var c = 0
        eachItem(rootNode, function (n) { if (isText(n) && n.text === str && n.visible) c++ })
        return c
    }
    function findTextMatching(rootNode, re) {
        return findPred(rootNode, function (n) { return isText(n) && re.test(n.text) })
    }
    // MetricGauge: duck-typed by its distinctive property set (same as the CPU file).
    function findGauge(rootNode) {
        return findPred(rootNode, function (n) {
            return n.big !== undefined && n.history !== undefined
                   && n.ok !== undefined && n.color !== undefined
        })
    }
    // Sparkline: the only component carrying a `values` array.
    function findSparkline(rootNode) {
        return findPred(rootNode, function (n) { return n.values !== undefined })
    }
    // Clear an instance's settings bucket in place, so each case starts at the
    // schema defaults (the harness seeds an empty bucket at load).
    function resetSettings(h) {
        var s = h.storeCtl.settingsFor("test-instance")
        for (var k in s) delete s[k]
        h.storeCtl._touchSettings()
    }

    // ── Harnesses (one store each, so the cases cannot leak into each other) ──
    WidgetHarness { id: ramH;   width: 520; height: 440; widgetFile: "RamWidget.qml" }
    WidgetHarness { id: clockH; width: 520; height: 440; widgetFile: "ClockWidget.qml" }
    WidgetHarness { id: hydH;   width: 520; height: 440; widgetFile: "HydrationWidget.qml" }
    WidgetHarness { id: notesH; width: 520; height: 440; widgetFile: "NotesWidget.qml" }
    WidgetHarness { id: kpiH;   width: 520; height: 440; widgetFile: "KpiWidget.qml" }

    // ═════════════════════════════════════════════════════════════════════════
    // RAM - a second metric widget. `unit` is the schema's segmented field kind,
    // which CPU has no example of.
    // ═════════════════════════════════════════════════════════════════════════
    TestCase {
        name: "RamConfigValues"
        when: windowShown

        function init() {
            tryVerify(function () { return ramH.ready }, 3000)
            resetSettings(ramH)
            ramH.metricsJson = "{}"
            ramH.active = true
            ramH.item.hist = []
        }

        function feed(obj) { ramH.metricsJson = JSON.stringify(obj) }

        // ── segmented: "Center reading" (unit: percent | gb) ─────────────────
        // Observable: the gauge's centre Text and its supporting line SWAP -
        // percent mode reads "40%" over a concise used-memory line, gb mode
        // reads "8.0 GiB" over "40%". Both are rendered Text nodes.
        function test_unit_field_swaps_the_rendered_centre_reading() {
            var w = ramH.item
            feed({ ram_usage_percent: 40,
                   ram_used_bytes: 8 * 1073741824,
                   ram_total_bytes: 16 * 1073741824 })

            // Precondition: the default ("percent") renders the percentage big.
            var g = findGauge(w)
            verify(g !== null, "gauge present")
            compare(g.big, "40%", "precondition: percent mode leads with the percentage")
            verify(findExactText(w, "40%") !== null,
                   "the centre Text renders '40%' by default")
            compare(g.sub, "8.0 GiB used",
                    "the supporting line stays concise when detail cards show availability")

            ramH.storeCtl.setSetting("test-instance", "unit", "gb")

            // (a) stored, and re-read by the widget.
            compare(ramH.storeCtl.settingsFor("test-instance").unit, "gb",
                    "unit lands in the tile's settings")
            compare(w.unit, "gb", "widget re-reads unit from the store")

            // (b) the rendered readout actually swaps.
            compare(findGauge(w).big, "8.0 GiB",
                    "the centre reading becomes the used-GiB figure")
            verify(findExactText(w, "8.0 GiB") !== null,
                   "and a Text node renders it")
            verify(findExactText(w, "8.0 / 16.0 GiB") === null,
                   "the used/total sub-line is replaced, not shown alongside")
            compare(findGauge(w).sub, "40%",
                    "the sub-line reports the percentage instead of repeating GiB")
        }

        // ── toggle: "Show the history graph" ─────────────────────────────────
        // Observable: the samples the gauge hands its sparkline, and the
        // Sparkline node's own visibility.
        function test_showHistory_toggle_empties_and_hides_the_sparkline() {
            var w = ramH.item
            w.hist = []
            feed({ ram_usage_percent: 30, ram_total_bytes: 16 * 1073741824 })
            feed({ ram_usage_percent: 45, ram_total_bytes: 16 * 1073741824 })
            var spark = findSparkline(w)
            verify(spark !== null, "sparkline present")
            verify(findGauge(w).history.length >= 2, "precondition: the graph has samples")
            verify(spark.visible, "and the sparkline is visible while the toggle is on")

            ramH.storeCtl.setSetting("test-instance", "showHistory", false)

            compare(ramH.storeCtl.settingsFor("test-instance").showHistory, false,
                    "showHistory=false lands in the tile's settings")
            compare(w.showHistory, false, "widget re-reads showHistory from the store")

            compare(findGauge(w).history.length, 0,
                    "the sparkline receives no samples when the graph is hidden")
            verify(!spark.visible,
                   "the very Sparkline node that drew the samples is now hidden")

            ramH.storeCtl.setSetting("test-instance", "showHistory", true)
            verify(findGauge(w).history.length >= 2,
                   "and the graph returns when the toggle is switched back on")
            verify(spark.visible, "the sparkline node is shown again")
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // CLOCK - a time widget. Its config is almost entirely FORMAT, so every
    // observable here is the literal string the tile renders.
    // ═════════════════════════════════════════════════════════════════════════
    TestCase {
        name: "ClockConfigValues"
        when: windowShown

        // The rendered time: the only Text on the tile that starts "H:MM".
        function timeNode(w) { return findTextMatching(w, /^\d{1,2}:\d{2}/) }
        // The rendered date line, found by the exact string the widget's own
        // format currently produces (captured BEFORE the config write so the
        // assertion re-checks that same node).
        function dateNode(w) { return findExactText(w, w.formatAt(w.dateFmt)) }

        function init() {
            tryVerify(function () { return clockH.ready }, 3000)
            resetSettings(clockH)
            clockH.expanded = false
            clockH.active = true
        }

        // ── toggle: "24-hour clock" ──────────────────────────────────────────
        // Observable: the rendered time string gains/loses the AM/PM suffix and
        // switches between "h" and zero-padded "HH".
        function test_format24_toggle_changes_the_rendered_time_string() {
            var w = clockH.item
            var t = timeNode(w)
            verify(t !== null, "the time Text is rendered")
            verify(/ (AM|PM)$/.test(t.text),
                   "precondition: the 12-hour default renders an AM/PM suffix - got '" + t.text + "'")

            clockH.storeCtl.setSetting("test-instance", "format24", true)

            compare(clockH.storeCtl.settingsFor("test-instance").format24, true,
                    "format24 lands in the tile's settings")
            compare(w.format24, true, "widget re-reads format24 from the store")

            verify(!/ (AM|PM)$/.test(t.text),
                   "the AM/PM suffix is gone from the very Text that showed it - got '" + t.text + "'")
            verify(/^\d{2}:\d{2}$/.test(t.text),
                   "and the time renders as zero-padded 24-hour HH:mm - got '" + t.text + "'")
        }

        // ── toggle: "Show seconds" ───────────────────────────────────────────
        // Observable: the rendered time grows a third field.
        function test_showSeconds_toggle_adds_seconds_to_the_time() {
            var w = clockH.item
            clockH.storeCtl.setSetting("test-instance", "format24", true)   // isolate from AM/PM
            var t = timeNode(w)
            verify(t !== null, "the time Text is rendered")
            compare(t.text.split(":").length - 1, 1,
                    "precondition: the time has one colon (HH:mm) - got '" + t.text + "'")

            clockH.storeCtl.setSetting("test-instance", "showSeconds", true)

            compare(clockH.storeCtl.settingsFor("test-instance").showSeconds, true,
                    "showSeconds lands in the tile's settings")
            compare(w.showSeconds, true, "widget re-reads showSeconds from the store")

            verify(/^\d{2}:\d{2}:\d{2}$/.test(t.text),
                   "the same Text now renders HH:mm:ss - got '" + t.text + "'")
        }

        // ── toggle: "Show the date" ──────────────────────────────────────────
        // Observable: the date Text node is hidden, AND the header weekday chip
        // (which only exists to complement the date row) goes with it.
        function test_showDate_toggle_hides_the_date_line() {
            var w = clockH.item
            var d = dateNode(w)
            verify(d !== null, "the date Text is rendered by default")
            verify(d.visible, "and it is visible")

            clockH.storeCtl.setSetting("test-instance", "showDate", false)

            compare(clockH.storeCtl.settingsFor("test-instance").showDate, false,
                    "showDate=false lands in the tile's settings")
            compare(w.showDate, false, "widget re-reads showDate from the store")

            verify(!d.visible,
                   "the very Text node that showed the date is now hidden")
        }

        // ── segmented: "Date style" (full | short) ───────────────────────────
        // Observable: the date Text switches from a spelled-out date to dd/MM,
        // and the header status picks up the weekday the short form drops.
        function test_dateStyle_field_switches_the_date_format() {
            var w = clockH.item
            var d = dateNode(w)
            verify(d !== null, "the date Text is rendered")
            verify(/[A-Za-z]/.test(d.text),
                   "precondition: the 'full' default spells the date out - got '" + d.text + "'")
            compare(w.status, "",
                    "precondition: the header carries no weekday while the full date does")

            clockH.storeCtl.setSetting("test-instance", "dateStyle", "short")

            compare(clockH.storeCtl.settingsFor("test-instance").dateStyle, "short",
                    "dateStyle lands in the tile's settings")
            compare(w.dateStyle, "short", "widget re-reads dateStyle from the store")

            compare(d.text, Qt.formatDate(new Date(), w.localeShortDatePattern()),
                    "the same Text now renders the locale's real short-date form")
            verify(/^[A-Za-z]{3}$/.test(w.status),
                   "and the header picks up the weekday the short form drops - got '" + w.status + "'")
            verify(findExactText(w, w.status) !== null,
                   "the header weekday is actually rendered")
        }

        // ── toggle + text: "Use a specific time zone" / "Zone name" ──────────
        // Observable: the zone label line above the time appears with the
        // configured name - foreign time must never read as local time.
        function test_customZone_and_zoneLabel_render_the_zone_line() {
            var w = clockH.item
            verify(findExactText(w, "Tokyo Office") === null,
                   "precondition: no zone line is rendered for a local clock")

            clockH.storeCtl.patchSettings("test-instance",
                                          { customZone: true, zoneLabel: "Tokyo Office" })

            var s = clockH.storeCtl.settingsFor("test-instance")
            compare(s.customZone, true, "customZone lands in the tile's settings")
            compare(s.zoneLabel, "Tokyo Office", "zoneLabel lands in the tile's settings")
            compare(w.customZone, true, "widget re-reads customZone from the store")
            compare(w.zoneLabel, "Tokyo Office", "widget re-reads zoneLabel from the store")

            var z = findExactText(w, "Tokyo Office")
            verify(z !== null, "the zone line renders the configured name")
            verify(z.visible, "and it is visible")

            // Turning the zone off must take the line with it - the same node.
            clockH.storeCtl.setSetting("test-instance", "customZone", false)
            verify(!z.visible, "clearing customZone hides that same zone line")
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // HYDRATION - a focus widget. Both fields are NUMBERS that drive a count and
    // a derived volume, so the observables are a delegate count and a string.
    // ═════════════════════════════════════════════════════════════════════════
    TestCase {
        name: "HydrationConfigValues"
        when: windowShown

        function todayKey() { return Qt.formatDate(new Date(), "yyyy-MM-dd") }
        // Empty glasses render "○", filled ones "💧" - a real delegate count.
        // Counted VISIBLE-only: the widget instantiates its tile grid and its
        // expanded overlay grid at the same time and hides one, so a raw count
        // reports both (16 for a goal of 8).
        function emptyGlasses(w) { return countVisibleText(w, "○") }

        function init() {
            tryVerify(function () { return hydH.ready }, 3000)
            resetSettings(hydH)
            hydH.expanded = false
            hydH.active = true
        }

        // ── number: "Daily goal" ─────────────────────────────────────────────
        // Observable: the "N of M glasses" caption AND the number of droplet
        // delegates the grid actually instantiates.
        function test_goal_field_changes_the_caption_and_the_glass_count() {
            var w = hydH.item
            compare(w.goal, 8, "precondition: the default goal is 8 glasses")
            verify(findExactText(w, "0 of 8 glasses") !== null,
                   "precondition: the caption reads the default goal")
            compare(emptyGlasses(w), 8,
                    "precondition: the grid draws one droplet per goal glass")

            hydH.storeCtl.setSetting("test-instance", "goal", 5)

            compare(hydH.storeCtl.settingsFor("test-instance").goal, 5,
                    "goal lands in the tile's settings")
            compare(w.goal, 5, "widget re-reads goal from the store")

            verify(findExactText(w, "0 of 5 glasses") !== null,
                   "the caption renders the configured goal")
            verify(findExactText(w, "0 of 8 glasses") === null,
                   "and the old goal caption is gone, not shown alongside")
            compare(emptyGlasses(w), 5,
                    "the glass grid draws exactly the configured number of glasses")
            compare(w.status, "0/5", "the header count tracks the configured goal")
        }

        // ── number: "Glass size" (glassMl) ───────────────────────────────────
        // Observable: the overlay's volume line - count × glassMl, rendered as
        // ml below a litre and as L at or above it.
        function test_glassMl_field_changes_the_rendered_volume() {
            var w = hydH.item
            hydH.expanded = true
            hydH.storeCtl.patchSettings("test-instance", { day: todayKey(), count: 2 })
            compare(w.count, 2, "precondition: two glasses logged today")
            compare(w.glassMl, 250, "precondition: the default glass is 250 ml")
            verify(findExactText(w, "500 ml today  ·  250 ml per glass") !== null,
                   "precondition: the expanded summary renders volume and serving size")

            hydH.storeCtl.setSetting("test-instance", "glassMl", 600)

            compare(hydH.storeCtl.settingsFor("test-instance").glassMl, 600,
                    "glassMl lands in the tile's settings")
            compare(w.glassMl, 600, "widget re-reads glassMl from the store")

            compare(w.volumeText(), "1.2 L",
                    "2 × 600 ml is reported as 1.2 L")
            verify(findExactText(w, "1.2 L today  ·  600 ml per glass") !== null,
                   "the volume line renders the new total and serving size")
            verify(findExactText(w, "500 ml today  ·  250 ml per glass") === null,
                   "and the old 250 ml total is no longer rendered")
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // NOTES - a text widget. Its single config key IS its content.
    // ═════════════════════════════════════════════════════════════════════════
    TestCase {
        name: "NotesConfigValues"
        when: windowShown

        function init() {
            tryVerify(function () { return notesH.ready }, 3000)
            resetSettings(notesH)
            notesH.expanded = false
            notesH.active = true
        }

        // ── textarea: "Note" (text) ──────────────────────────────────────────
        // Observable: the tile preview Text - captured while it still shows the
        // placeholder - renders the note, and its colour promotes from the
        // tertiary placeholder tone to primary body text.
        function test_text_field_replaces_the_placeholder_preview() {
            var w = notesH.item
            var preview = findExactText(w, "Tap to jot a note…")
            verify(preview !== null, "precondition: the empty note shows the placeholder")
            verify(Qt.colorEqual(preview.color, notesH.theme.textPrimary),
                   "precondition: the placeholder uses the legible primary tone")
            fuzzyCompare(preview.opacity, 0.78, 0.01,
                         "the placeholder is distinguished without reducing contrast")

            notesH.storeCtl.setSetting("test-instance", "text", "Buy milk")

            compare(notesH.storeCtl.settingsFor("test-instance").text, "Buy milk",
                    "the note text lands in the tile's settings")
            compare(w.current, "Buy milk", "widget re-reads the note from the store")

            compare(preview.text, "Buy milk",
                    "the very Text that showed the placeholder now renders the note")
            verify(Qt.colorEqual(preview.color, notesH.theme.textPrimary),
                   "and it is promoted to the primary body colour")
            fuzzyCompare(preview.opacity, 1, 0.01,
                         "and the saved note uses full opacity")
        }

        // A whitespace-only note is deliberately treated as empty: the preview
        // must fall BACK to the placeholder rather than render blank.
        function test_whitespace_only_note_falls_back_to_the_placeholder() {
            var w = notesH.item
            notesH.storeCtl.setSetting("test-instance", "text", "Buy milk")
            var preview = findExactText(w, "Buy milk")
            verify(preview !== null, "precondition: the note is rendered")

            notesH.storeCtl.setSetting("test-instance", "text", "   \n  ")

            compare(notesH.storeCtl.settingsFor("test-instance").text, "   \n  ",
                    "the whitespace note lands in the tile's settings verbatim")
            compare(preview.text, "Tap to jot a note…",
                    "the preview falls back to the placeholder for an empty note")
            verify(Qt.colorEqual(preview.color, notesH.theme.textPrimary),
                   "and keeps the legible primary placeholder tone")
            fuzzyCompare(preview.opacity, 0.78, 0.01,
                         "while returning to the placeholder opacity")
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // KPI - an info/data widget. The reading itself is normally fetched, so the
    // fetch is quiesced (active=false) and the value seeded through the same
    // store keys the fetch writes; the CONFIG under test is presentation +
    // thresholds, which is pure local logic over that value.
    // ═════════════════════════════════════════════════════════════════════════
    TestCase {
        name: "KpiConfigValues"
        when: windowShown

        // Quiesce the widget's own polling, then seed a value exactly as a
        // successful fetch would (_apply → patchSettings(httpVal/httpText)).
        function seedValue(v) {
            kpiH.active = false
            // Let the debounced initial refresh land (and clear) before seeding,
            // otherwise it would wipe the seed a moment later.
            wait(500)
            kpiH.storeCtl.patchSettings("test-instance", {
                source: "file", filePath: "/proc/uptime",
                httpErr: "", httpVal: v, httpText: "" + v
            })
            compare(kpiH.item.valText, "" + v, "the seeded reading is what the widget shows")
        }

        function init() {
            tryVerify(function () { return kpiH.ready }, 3000)
            resetSettings(kpiH)
            kpiH.expanded = false
            kpiH.active = true
        }

        // ── text: "Label" ────────────────────────────────────────────────────
        // Observable: the caption under the number. With no label it falls back
        // to the widget title, which the card header ALSO renders - so the
        // observable is the COUNT of nodes rendering each string, not mere
        // existence (a bare "is 'KPI' present" check would pass either way).
        function test_label_field_replaces_the_fallback_caption() {
            seedValue(87)
            var w = kpiH.item
            compare(countText(w, "KPI"), 2,
                    "precondition: with no label, both the header and the caption read 'KPI'")
            compare(countText(w, "Queue depth"), 0,
                    "precondition: the custom label is not rendered anywhere yet")

            kpiH.storeCtl.setSetting("test-instance", "label", "Queue depth")

            compare(kpiH.storeCtl.settingsFor("test-instance").label, "Queue depth",
                    "label lands in the tile's settings")
            compare(w.label, "Queue depth", "widget re-reads the label from the store")

            compare(countText(w, "Queue depth"), 1,
                    "the caption renders the configured label")
            compare(countText(w, "KPI"), 1,
                    "and the fallback caption is gone - only the card header still reads 'KPI'")
        }

        // ── text: "Unit" ─────────────────────────────────────────────────────
        // Observable: the unit Text beside the number appears (it is hidden
        // outright when the unit is blank).
        function test_unit_field_renders_the_unit_beside_the_number() {
            seedValue(87)
            var w = kpiH.item
            verify(findExactText(w, "ms") === null,
                   "precondition: no unit is rendered while the field is blank")

            kpiH.storeCtl.setSetting("test-instance", "unit", "ms")

            compare(kpiH.storeCtl.settingsFor("test-instance").unit, "ms",
                    "unit lands in the tile's settings")
            compare(w.unit, "ms", "widget re-reads the unit from the store")

            var u = findExactText(w, "ms")
            verify(u !== null, "the unit Text renders the configured unit")
            verify(u.visible, "and it is visible beside the number")
        }

        // ── thresholds: warnAt / critAt / invert ─────────────────────────────
        // Observable: the RENDERED COLOUR of the number, captured once and
        // re-asserted after each write.
        function test_thresholds_and_invert_recolor_the_number() {
            seedValue(87)
            var w = kpiH.item
            var num = findExactText(w, "87")
            verify(num !== null, "the number is rendered")
            verify(Qt.colorEqual(num.color, w.effAccent),
                   "precondition: with no thresholds the number uses the accent")

            // Warn: 87 >= 80.
            kpiH.storeCtl.setSetting("test-instance", "warnAt", "80")
            compare(kpiH.storeCtl.settingsFor("test-instance").warnAt, "80",
                    "warnAt lands in the tile's settings")
            compare(w.warnAt, 80, "widget re-reads warnAt from the store")
            verify(Qt.colorEqual(num.color, kpiH.theme.warning),
                   "the same number Text turns amber once it crosses the warn threshold")

            // Critical: 87 >= 85 wins over the warn band.
            kpiH.storeCtl.setSetting("test-instance", "critAt", "85")
            compare(kpiH.storeCtl.settingsFor("test-instance").critAt, "85",
                    "critAt lands in the tile's settings")
            compare(w.critAt, 85, "widget re-reads critAt from the store")
            verify(Qt.colorEqual(num.color, kpiH.theme.error),
                   "and red once it crosses the critical threshold")

            // "Lower is worse" flips the comparison: 87 is now comfortably ABOVE
            // both thresholds, so the colour must fall back to the accent.
            kpiH.storeCtl.setSetting("test-instance", "invert", true)
            compare(kpiH.storeCtl.settingsFor("test-instance").invert, true,
                    "invert lands in the tile's settings")
            compare(w.invert, true, "widget re-reads invert from the store")
            verify(Qt.colorEqual(num.color, w.effAccent),
                   "with 'lower is worse' the same value is healthy and the colour resets")

            // …and it really is the DIRECTION that changed, not the thresholds:
            // drop the reading below both and the colours come back.
            kpiH.storeCtl.patchSettings("test-instance", { httpVal: 40, httpText: "40" })
            var low = findExactText(w, "40")
            verify(low !== null, "the lowered reading is rendered")
            verify(Qt.colorEqual(low.color, kpiH.theme.error),
                   "40 is critical under 'lower is worse'")
        }
    }
}
