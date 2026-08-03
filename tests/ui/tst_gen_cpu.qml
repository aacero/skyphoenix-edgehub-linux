import QtQuick
import QtTest
import "../../ui/qml" as App
import "../../ui/qml/widgets" as Wg


// Comprehensive coverage for the CPU widget (ui/qml/widgets/CpuWidget.qml).
//
// Exercises: usage + temperature reading from the Rust metrics JSON, the
// temperature warning thresholds (header text vs. ring), config honouring +
// reactivity (showTemp / showHistory / warnTemp), the universal appearance keys
// (accent / title / backdrop) on the shared WidgetChrome, the history buffer
// (accumulation, cap, gating), the expanded core-count sub-line, and value
// clamping. Also directly instantiates the shared MetricGauge and the CPU
// config schema.
//
// The regression checks keep unavailable samples, thermal alerts, live history,
// selectable temperature sources, richer large-size data, and expanded per-core
// presentation aligned with the approved CPU widget behavior.
Item {
    id: root
    width: 520; height: 440

    // A file-root `theme` so directly-instantiated shared components (below)
    // resolve the `theme` global by name, the way the harness provides it to
    // widgets it loads.
    property alias theme: rootTheme
    App.Theme { id: rootTheme }

    WidgetHarness {
        id: h
        anchors.fill: parent
        widgetFile: "CpuWidget.qml"
        expanded: true
    }

    // Fixed-size hosts for the per-sizeClass structure tests (W1 wave 2a) -
    // real projected cell footprints (half-cell ≈ 344x416, full cell ≈ 696x840).
    Item { id: microWrap; width: 344; height: 416
        WidgetHarness { id: hMicro; anchors.fill: parent; widgetFile: "CpuWidget.qml"; expanded: false } }
    Item { id: baseWrap; width: 696; height: 840
        WidgetHarness { id: hBase; anchors.fill: parent; widgetFile: "CpuWidget.qml"; expanded: false } }
    Item { id: wideWrap; width: 696; height: 416
        WidgetHarness { id: hWide; anchors.fill: parent; widgetFile: "CpuWidget.qml"; expanded: false } }
    Item { id: tallWrap; width: 344; height: 840
        WidgetHarness { id: hTall; anchors.fill: parent; widgetFile: "CpuWidget.qml"; expanded: false } }

    // Directly-instantiated shared MetricGauge (resolves `theme` from root).
    Item {
        id: gaugeHost
        width: 200; height: 200
        Wg.MetricGauge { id: mg; anchors.fill: parent }
    }

    App.WidgetConfigSchema { id: schema }

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
    // MetricGauge: duck-typed by its distinctive property set.
    function findGauge(rootNode) {
        return findPred(rootNode, function (n) {
            return n.big !== undefined && n.history !== undefined && n.ok !== undefined
        })
    }
    // RingProgress: value + thickness + progressColor.
    function findRing(rootNode) {
        return findPred(rootNode, function (n) {
            return n.thickness !== undefined && n.progressColor !== undefined && n.trackColor !== undefined
        })
    }
    // BackdropLayer: style + running (Text has `style` but no `running`).
    function findBackdrop(rootNode) {
        return findPred(rootNode, function (n) {
            return n.style !== undefined && n.running !== undefined
        })
    }
    function findText(rootNode, prefix) {
        return findPred(rootNode, function (n) {
            return n.text !== undefined && typeof n.text === "string" && n.text.indexOf(prefix) === 0
        })
    }
    function findObjectName(rootNode, objectName) {
        return findPred(rootNode, function (n) {
            return n.objectName !== undefined && n.objectName === objectName
        })
    }
    // The glance rows are {label, value} objects, not items - this audit needed a
    // way to assert a row's PRESENCE without depending on its position.
    function labelled(rows, label) {
        for (var i = 0; i < (rows ? rows.length : 0); i++)
            if (rows[i].label === label) return rows[i]
        return null
    }
    function findField(sch, key) {
        for (var i = 0; i < sch.sections.length; i++) {
            var fs = sch.sections[i].fields || []
            for (var j = 0; j < fs.length; j++)
                if (fs[j].key === key) return fs[j]
        }
        return null
    }

    function feed(obj) { h.metricsJson = JSON.stringify(obj) }

    // ── Main widget behaviour (hosted like Dashboard) ────────────────────────
    TestCase {
        name: "Cpu"
        when: windowShown

        function init() {
            tryVerify(function () { return h.ready }, 3000)
            var s = h.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            h.storeCtl._touchSettings()
            h.metricsJson = "{}"
            h.expanded = true
            h.active = true
            h.item.hist = []
        }

        // Wire the universal per-instance appearance bindings exactly as
        // Dashboard.injectWidget does (the harness does not do this itself).
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

        // ── Metrics reading ──────────────────────────────────────────────────
        function test_reads_usage_from_metrics() {
            var w = h.item
            feed({ cpu_usage_percent: 42 })
            compare(w.v, 42, "usage read from cpu_usage_percent")
            var g = findGauge(w)
            verify(g !== null, "gauge is present")
            compare(g.big, "42%", "centre value renders the usage")
        }

        function test_reads_temp_from_metrics() {
            var w = h.item
            feed({ cpu_usage_percent: 30, cpu_temp_celsius: 58 })
            compare(w.temp, 58, "temp read from cpu_temp_celsius")
            compare(w.status, "58°C", "header shows the temperature")
        }

        function test_defaults_when_settings_empty() {
            var w = h.item
            compare(w.showTemp, true, "showTemp defaults true")
            compare(w.showHistory, true, "showHistory defaults true")
            compare(w.historyWindow, "2m", "history defaults to a named two-minute window")
            compare(w.showFrequency, true, "showFrequency defaults true")
            compare(w.showLoadAverage, true, "showLoadAverage defaults true")
            compare(w.showPerCore, true, "showPerCore defaults true")
            compare(w.showTopProcess, true, "showTopProcess defaults true")
            compare(w.tempSource, "auto", "temperature source defaults automatic")
            compare(w.warnTemp, 85, "warnTemp defaults to 85")
        }

        function test_explicit_warming_state_is_not_a_real_zero() {
            var w = h.item
            feed({ cpu_usage_percent: 0, cpu_usage_available: false,
                   cpu_sample_status: "warming" })
            compare(w.avail, false, "a warming delta is not available yet")
            compare(w.warming, true, "warming status is exposed to the widget")
            compare(findGauge(w).big, "...", "warming has a distinct placeholder")
            compare(w.status, "warming up", "the header explains the placeholder")
        }

        function test_explicit_unavailable_state_does_not_enter_history() {
            var w = h.item
            w.hist = []
            feed({ cpu_usage_percent: 0, cpu_usage_available: false,
                   cpu_sample_status: "unavailable" })
            compare(w.hist.length, 0, "an unavailable core sample is never recorded as 0%")
            compare(findGauge(w).big, "N/A", "an unavailable sample is labelled honestly")
        }

        // ── Availability (BUG: missing usage renders 0%, not N/A) ────────────
        function test_missing_usage_marks_gauge_unavailable() {
            var w = h.item
            feed({ cpu_temp_celsius: 50 })   // temperature present, but NO usage
            compare(w.v, 0, "missing usage collapses to v=0 (the |0 default)")
            var g = findGauge(w)
            verify(g !== null, "gauge present")
            // Intended: unavailable data dims the gauge (ok:false), as GpuWidget does.
            compare(g.ok, false,
                    "missing cpu_usage_percent should mark the gauge unavailable, not show a confident 0%")
        }

        // ── History accumulation (BUG: empty/malformed frames push a fake 0) ──
        function test_empty_frame_does_not_push_history_sample() {
            var w = h.item
            w.hist = []
            feed({ cpu_usage_percent: 50 })          // two real frames
            feed({ cpu_usage_percent: 60 })
            var before = w.hist.length
            verify(before >= 1, "real frames accumulate history (" + before + ")")
            h.metricsJson = "{}"                     // empty metrics tick
            // Intended: an empty frame carries no reading, so it must not record one.
            compare(w.hist.length, before,
                    "an empty {} frame must not push a fake history sample")
        }

        function test_malformed_frame_leaves_history_unchanged() {
            var w = h.item
            w.hist = []
            feed({ cpu_usage_percent: 40 })          // two real frames
            feed({ cpu_usage_percent: 45 })
            var before = w.hist.length
            h.metricsJson = "{not valid json"        // parse fails → {}
            compare(w.hist.length, before,
                    "a malformed metrics frame must not push a fake sample")
        }

        function test_history_caps_at_named_default_window_and_drops_oldest() {
            var w = h.item
            w.hist = []
            for (var i = 1; i <= 75; i++) feed({ cpu_usage_percent: i })
            compare(w.hist.length, 60, "two-minute history caps at 60 two-second samples")
            // Fed a strictly increasing series → the retained window is the most
            // recent 48 (oldest dropped): still in chronological order, and the
            // earliest low-value samples are gone.
            var increasing = true
            for (var j = 1; j < w.hist.length; j++)
                if (w.hist[j] <= w.hist[j - 1]) increasing = false
            verify(increasing, "retained samples stay in chronological order")
            verify(w.hist[0] > 0.05, "the oldest low-value samples were dropped (got " + w.hist[0] + ")")
            verify(w.hist[w.hist.length - 1] <= 1.0, "newest sample is a recent in-range reading")
        }

        // ── Display toggles: the schema promises "every option here is honoured
        // by the corresponding widget - nothing is decorative", and until this
        // audit (2026-08-03) these four were only ever checked for their FIELD
        // shape (type + default). A widget that ignored them entirely would have
        // shipped green. Each case drives the real setting and asserts the
        // surface it is documented to change.
        function test_show_frequency_toggle_gates_the_clock_reading() {
            var w = h.item
            feed({ cpu_usage_percent: 20, cpu_frequency_mhz: 3600 })
            compare(w.frequencyText, "3.60 GHz", "frequency is formatted from the metric")
            verify(w.expandedDetails.indexOf("3.60 GHz") >= 0,
                   "expanded details carry the clock while the toggle is on")
            h.storeCtl.setSetting("test-instance", "showFrequency", false)
            compare(w.showFrequency, false, "the setting reaches the widget")
            verify(w.expandedDetails.indexOf("3.60 GHz") < 0,
                   "expanded details drop the clock when the toggle is off")
            // ...and the compact tile's CLOCK row, which is a separate code path.
            h.expanded = false
            h.storeCtl.setSetting("test-instance", "showFrequency", true)
            verify(labelled(w.glanceDetails, "CLOCK") !== null,
                   "the tile shows a CLOCK row while the toggle is on")
            h.storeCtl.setSetting("test-instance", "showFrequency", false)
            compare(labelled(w.glanceDetails, "CLOCK"), null,
                    "the tile drops the CLOCK row when the toggle is off")
            h.expanded = true
        }

        function test_show_load_average_toggle_gates_the_load_reading() {
            var w = h.item
            feed({ cpu_usage_percent: 20, cpu_load_1: 1.5, cpu_load_5: 1.25, cpu_load_15: 1 })
            verify(w.expandedDetails.indexOf("load 1.50") >= 0,
                   "expanded details carry the load averages while the toggle is on")
            h.storeCtl.setSetting("test-instance", "showLoadAverage", false)
            verify(w.expandedDetails.indexOf("load ") < 0,
                   "expanded details drop the load averages when the toggle is off")
            h.expanded = false
            h.storeCtl.setSetting("test-instance", "showLoadAverage", true)
            verify(labelled(w.glanceDetails, "LOAD 1M") !== null,
                   "the tile shows a LOAD 1M row while the toggle is on")
            h.storeCtl.setSetting("test-instance", "showLoadAverage", false)
            compare(labelled(w.glanceDetails, "LOAD 1M"), null,
                    "the tile drops the LOAD 1M row when the toggle is off")
            h.expanded = true
        }

        // NOTE the tile half of this: the schema help calls showTopProcess an
        // "Expanded view" option, but glanceDetails is the COMPACT path. The
        // assertion documents where the option really applies.
        function test_show_top_process_toggle_gates_both_surfaces() {
            var w = h.item
            feed({ cpu_usage_percent: 20, cpu_top_process_name: "cargo",
                   cpu_top_process_percent: 42 })
            compare(w.topProcessText, "cargo 42%", "the busiest process is formatted")
            verify(w.expandedDetails.indexOf("cargo 42%") >= 0,
                   "expanded details name the busiest process while the toggle is on")
            h.storeCtl.setSetting("test-instance", "showTopProcess", false)
            verify(w.expandedDetails.indexOf("cargo") < 0,
                   "expanded details drop the busiest process when the toggle is off")
            h.expanded = false
            h.storeCtl.setSetting("test-instance", "showTopProcess", true)
            verify(labelled(w.glanceDetails, "BUSIEST") !== null,
                   "the TILE also shows a BUSIEST row - not only the expanded view")
            h.storeCtl.setSetting("test-instance", "showTopProcess", false)
            compare(labelled(w.glanceDetails, "BUSIEST"), null,
                    "the tile drops the BUSIEST row when the toggle is off")
            h.expanded = true
        }

        function test_show_per_core_toggle_gates_the_core_panel() {
            var w = h.item
            feed({ cpu_usage_percent: 20,
                   cpu_core_usage_percent: [10, 90, 45, 5, 60, 20, 80, 30, 70] })
            compare(w.busiestCores.length, 8, "the panel is capped at the eight busiest")
            compare(w.busiestCores[0].value, 90, "the busiest core sorts first")
            var panel = findObjectName(w, "cpuCorePanel")
            verify(panel !== null, "the core panel exists")
            verify(panel.visible, "the core panel shows while the toggle is on")
            h.storeCtl.setSetting("test-instance", "showPerCore", false)
            compare(panel.visible, false, "the core panel hides when the toggle is off")
            // Empty core data must hide it too, regardless of the toggle.
            h.storeCtl.setSetting("test-instance", "showPerCore", true)
            feed({ cpu_usage_percent: 20 })
            compare(panel.visible, false, "no per-core data means no panel")
        }

        function test_history_window_setting_changes_retention() {
            var w = h.item
            h.storeCtl.setSetting("test-instance", "historyWindow", "1m")
            compare(w.historyLimit, 30, "one minute retains 30 samples")
            w.hist = []
            for (var i = 0; i < 40; i++) feed({ cpu_usage_percent: i })
            compare(w.hist.length, 30, "one-minute selection is applied to live retention")
            h.storeCtl.setSetting("test-instance", "historyWindow", "5m")
            compare(w.historyLimit, 150, "five minutes retains 150 samples")
        }

        // FIXED, and this test pins it (audit). The defect was: history is a
        // plain instance property, not shared through the store, so the expanded
        // overlay (a separate instance) starts blank.
        function test_history_persisted_to_shared_store() {
            var w = h.item
            w.hist = []
            feed({ cpu_usage_percent: 20 })
            feed({ cpu_usage_percent: 30 })
            var s = h.storeCtl.settingsFor("test-instance")
            verify(s.hist !== undefined && s.hist.length >= 2,
                   "history should live in the shared store so tile + expanded overlay share it")
        }

        // FIXED, and this test pins it (audit). The defect was: `active` is
        // declared but never read; hidden instances churn.
        function test_inactive_instance_pauses_accumulation() {
            var w = h.item
            w.hist = []
            h.active = false
            feed({ cpu_usage_percent: 55 })
            feed({ cpu_usage_percent: 65 })
            compare(w.hist.length, 0,
                    "an inactive (covered/off-page) tile should not accumulate history")
        }

        // ── Temperature thresholds ───────────────────────────────────────────
        function test_ring_amber_above_warn_minus_12_red_above_warn() {
            var w = h.item
            // warnTemp default 85 → amber above 73, red above 85. Low load so the
            // load branch stays comfortable and only temp drives escalation.
            feed({ cpu_usage_percent: 10, cpu_temp_celsius: 90 })
            verify(Qt.colorEqual(w.col(w.v), h.theme.error), "90°C (>warnTemp) → red")
            feed({ cpu_usage_percent: 10, cpu_temp_celsius: 80 })
            verify(Qt.colorEqual(w.col(w.v), h.theme.warning), "80°C (>warnTemp-12) → amber")
            feed({ cpu_usage_percent: 10, cpu_temp_celsius: 70 })
            verify(Qt.colorEqual(w.col(w.v), w.effAccent), "70°C (<warnTemp-12) → comfortable accent")
        }

        function test_warnTemp_slider_moves_boundaries() {
            var w = h.item
            h.storeCtl.setSetting("test-instance", "warnTemp", 60)
            compare(w.warnTemp, 60, "warnTemp honours the slider")
            // At 55°C: with warnTemp 60 the amber boundary is 48 → amber now.
            feed({ cpu_usage_percent: 10, cpu_temp_celsius: 55 })
            verify(Qt.colorEqual(w.col(w.v), h.theme.warning),
                   "55°C is amber once warnTemp drops to 60 (boundary 48)")
        }

        // FIXED, and this test pins it (audit). The defect was: header text
        // turns amber at warnTemp-17 but the ring only at warnTemp-12 - a 5°C
        // band where the two temperature signals disagree.
        function test_header_and_ring_agree_at_same_threshold() {
            var w = h.item
            // warnTemp 85. 70°C is below the ring's amber threshold (73) but above
            // the header's (68) - the two should still agree.
            feed({ cpu_usage_percent: 10, cpu_temp_celsius: 70 })
            verify(Qt.colorEqual(w.statusColor, w.col(w.v)),
                   "header temperature colour and ring colour should switch to amber at the same threshold")
        }

        function test_showTemp_false_hides_label_but_keeps_thermal_warning() {
            var w = h.item
            h.storeCtl.setSetting("test-instance", "showTemp", false)
            compare(w.showTemp, false, "showTemp honoured")
            feed({ cpu_usage_percent: 10, cpu_temp_celsius: 95 })   // very hot
            compare(w.status, "Critical temperature",
                    "the numeric temperature is hidden but its critical meaning remains visible")
            verify(Qt.colorEqual(w.col(w.v), h.theme.error),
                   "hiding the label must not suppress a critical thermal warning")
        }

        function test_warning_meaning_is_visible_and_accessible_without_color() {
            var w = h.item
            feed({ cpu_usage_percent: 78, cpu_temp_celsius: 50 })
            compare(w.alertLevel, "warning")
            compare(w.alertText, "High load")
            verify(w.status.indexOf("High load") >= 0,
                   "a sighted color-blind user receives a text warning")
            verify(w.accessibleSummary.indexOf("High load") >= 0,
                   "assistive technology receives the same warning meaning")

            feed({ cpu_usage_percent: 20, cpu_temp_celsius: 92 })
            compare(w.alertLevel, "critical")
            compare(w.alertText, "Critical temperature")
            verify(w.status.indexOf("Critical temperature") >= 0)
            verify(w.accessibleSummary.indexOf("degrees Celsius") >= 0)
        }

        // FIXED, and this test pins it (audit). The defect was: a genuine 0°C
        // reading is treated as missing (temp>0 gate).
        function test_zero_celsius_is_displayed() {
            var w = h.item
            feed({ cpu_usage_percent: 20, cpu_temp_celsius: 0 })
            compare(w.temp, 0, "0°C is read as a real value, not the -1 sentinel")
            compare(w.status, "0°C",
                    "a genuine 0°C reading should be displayed, not swallowed as missing")
        }

        function test_subzero_celsius_is_displayed() {
            var w = h.item
            feed({ cpu_usage_percent: 20, cpu_temp_celsius: -1 })
            compare(w.tempAvailable, true, "sub-zero temperature remains available")
            compare(w.status, "-1°C", "a real -1°C reading is not used as a sentinel")
        }

        function test_temperature_source_selects_package_or_hottest_sensor() {
            var w = h.item
            var sensors = [
                { id: "coretemp:temp2", label: "Core 0", celsius: 72 },
                { id: "coretemp:temp1", label: "Package id 0", celsius: 65 }
            ]
            feed({ cpu_usage_percent: 20, cpu_temperature_sensors: sensors })
            compare(w.temp, 72, "automatic uses the core-provided preferred first sensor")
            h.storeCtl.setSetting("test-instance", "tempSource", "package")
            compare(w.temp, 65, "package selection finds the package-labelled sensor")
            h.storeCtl.setSetting("test-instance", "tempSource", "hottest")
            compare(w.temp, 72, "hottest selection chooses the maximum live sensor")
            compare(w.tempSourceLabel, "Core 0",
                    "the chosen source is exposed to the detailed UI")
        }

        function test_missing_requested_package_sensor_is_explained() {
            var w = h.item
            feed({ cpu_usage_percent: 20, cpu_temperature_sensors: [
                { id: "coretemp:temp2", label: "Core 0", celsius: 72 }
            ] })
            h.storeCtl.setSetting("test-instance", "tempSource", "package")
            compare(w.tempAvailable, false,
                    "package mode does not silently substitute a different sensor")
            verify(w.tempUnavailableReason.indexOf("package") >= 0,
                   "the unavailable reason names the missing requested source")
        }

        // ── History graph visibility ─────────────────────────────────────────
        function test_showHistory_false_empties_gauge_history() {
            var w = h.item
            w.hist = []
            feed({ cpu_usage_percent: 30 })
            feed({ cpu_usage_percent: 40 })
            h.storeCtl.setSetting("test-instance", "showHistory", false)
            compare(w.showHistory, false, "showHistory honoured")
            var g = findGauge(w)
            compare(g.history.length, 0, "the sparkline receives no samples when history is hidden")
            h.storeCtl.setSetting("test-instance", "showHistory", true)
            verify(findGauge(w).history.length >= 2, "and the graph returns when re-enabled")
        }

        // ── Config reactivity ────────────────────────────────────────────────
        function test_cfg_rereads_on_revision_bump() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance",
                { showTemp: false, tempSource: "hottest", showHistory: false,
                  historyWindow: "5m", showFrequency: false, showLoadAverage: false,
                  showPerCore: false, showTopProcess: false, warnTemp: 70 })
            compare(w.showTemp, false, "showTemp follows a revision bump")
            compare(w.tempSource, "hottest", "tempSource follows a revision bump")
            compare(w.showHistory, false, "showHistory follows a revision bump")
            compare(w.historyWindow, "5m", "historyWindow follows a revision bump")
            compare(w.showFrequency, false, "showFrequency follows a revision bump")
            compare(w.showLoadAverage, false, "showLoadAverage follows a revision bump")
            compare(w.showPerCore, false, "showPerCore follows a revision bump")
            compare(w.showTopProcess, false, "showTopProcess follows a revision bump")
            compare(w.warnTemp, 70, "warnTemp follows a revision bump")
        }

        // ── Universal appearance keys ────────────────────────────────────────
        function test_default_accent_is_system_category() {
            var w = h.item
            verify(Qt.colorEqual(w.effAccent, h.theme.catSystem),
                   "with no accent override, effAccent is the System category colour")
        }

        function test_accent_config_recolors_comfortable_state() {
            var w = h.item
            wireAppearance(w)
            h.storeCtl.setSetting("test-instance", "accent", "green")
            verify(Qt.colorEqual(w.effAccent, h.theme.accentPresets["green"].a),
                   "accent preset recolours effAccent")
            feed({ cpu_usage_percent: 50 })   // comfortable, no temp
            verify(Qt.colorEqual(w.col(w.v), h.theme.accentPresets["green"].a),
                   "the comfortable ring/number use the configured accent")
        }

        function test_custom_title_override_applied() {
            var w = h.item
            wireAppearance(w)
            h.storeCtl.setSetting("test-instance", "title", "Processor")
            compare(w.titleOverride, "Processor", "custom title flows from config")
            verify(findText(w, "Processor") !== null, "the header renders the custom title")
        }

        function test_cardBackdrop_config_renders() {
            var w = h.item
            wireAppearance(w)
            h.storeCtl.setSetting("test-instance", "cardBackdrop", "aurora")
            compare(w.cardBackdrop, "aurora", "card backdrop flows from config")
            var bd = findBackdrop(w)
            verify(bd !== null, "the in-card backdrop layer exists")
            compare(bd.style, "aurora", "the backdrop renders the selected style")
            verify(bd.visible, "the backdrop is visible (theme is decorative)")
        }

        // ── Expanded core-count sub-line ─────────────────────────────────────
        function test_core_count_shown_in_expanded() {
            var w = h.item
            h.expanded = true
            feed({ cpu_usage_percent: 25, cpu_core_count: 8 })
            var g = findGauge(w)
            verify(g.sub.indexOf("8 cores") >= 0,
                   "expanded sub-line shows the core count")
        }

        function test_core_count_hidden_when_collapsed() {
            var w = h.item
            h.expanded = false
            feed({ cpu_usage_percent: 25, cpu_core_count: 8 })
            var g = findGauge(w)
            compare(g.sub, "", "collapsed tile hides the core-count sub-line")
        }

        // FIXED, and this test pins it (audit testCase). The defect was:
        // 0/absent core count should hide, but renders "0 cores".
        function test_core_count_hidden_when_absent() {
            var w = h.item
            h.expanded = true
            feed({ cpu_usage_percent: 25 })   // no cpu_core_count
            var g = findGauge(w)
            verify(g.sub.indexOf("0 cores") < 0,
                    "an absent core count must not render '0 cores'")
            verify(g.sub.indexOf("temperature sensor") >= 0,
                   "the space is used for the real temperature unavailable reason")
        }

        function test_large_details_use_real_frequency_load_and_freshness() {
            var w = h.item
            h.expanded = true
            feed({ cpu_usage_percent: 25, cpu_usage_available: true,
                   cpu_sample_status: "ready", cpu_sample_unix_ms: Date.now(),
                   cpu_core_count: 8, cpu_frequency_mhz: 4200,
                   cpu_load_1: 0.5, cpu_load_5: 0.75, cpu_load_15: 1.0 })
            var detail = findGauge(w).sub
            verify(detail.indexOf("8 cores") >= 0, "details retain logical core count")
            verify(detail.indexOf("4.20 GHz") >= 0, "details add current average frequency")
            verify(detail.indexOf("load 0.50 / 0.75 / 1.00") >= 0,
                   "details add named 1, 5 and 15 minute load values")
            verify(detail.indexOf("updated now") >= 0, "details expose sample freshness")
        }

        function test_large_detail_toggles_remove_optional_rows() {
            var w = h.item
            h.expanded = true
            h.storeCtl.patchSettings("test-instance",
                { showFrequency: false, showLoadAverage: false })
            feed({ cpu_usage_percent: 25, cpu_core_count: 8,
                   cpu_frequency_mhz: 4200, cpu_load_1: 0.5 })
            var detail = findGauge(w).sub
            verify(detail.indexOf("8 cores") >= 0,
                   "large-detail toggles retain the core count")
            verify(detail.indexOf("GHz") < 0 && detail.indexOf("load ") < 0,
                   "large-detail toggles remove only their matching data")
        }

        function test_expanded_view_shows_busiest_process_and_cores() {
            var w = h.item
            h.expanded = true
            feed({ cpu_usage_percent: 25, cpu_core_count: 4,
                   cpu_top_process_name: "compiler", cpu_top_process_percent: 18.5,
                   cpu_core_usage_percent: [12, 90, 45, 3] })
            verify(findGauge(w).sub.indexOf("compiler 19%") >= 0,
                   "expanded detail names the busiest local process")
            verify(findText(w, "BUSIEST CORES") !== null,
                   "expanded view renders the per-core activity panel")
            verify(findText(w, "C2") !== null,
                   "the busiest logical CPU is represented by its kernel index")
        }

        // ── Value clamping ───────────────────────────────────────────────────
        function test_ring_clamps_out_of_range_usage() {
            var w = h.item
            feed({ cpu_usage_percent: 150 })
            var ring = findRing(w)
            verify(ring !== null, "ring present")
            verify(ring.value <= 1.0, "over-100% usage clamps the ring to full")
            feed({ cpu_usage_percent: -10 })
            verify(findRing(w).value >= 0.0, "negative usage clamps the ring to empty")
        }

        // FIXED, and this test pins it (audit testCase). The defect was: the
        // sparkline sample is w.v/100 unclamped.
        function test_history_sample_is_clamped() {
            var w = h.item
            w.hist = []
            feed({ cpu_usage_percent: 150 })   // out of range
            feed({ cpu_usage_percent: 10 })    // second frame flushes 150 into history
            var mx = 0
            for (var i = 0; i < w.hist.length; i++) mx = Math.max(mx, w.hist[i])
            verify(mx <= 1.0,
                   "an out-of-range usage should be clamped before entering the sparkline (max sample " + mx + ")")
        }
    }

    // ── Per-sizeClass structure (W1 wave 2a) ─────────────────────────────────
    // Dashboard injects sizeClass; the widget must key layout off it and must
    // not collapse the sizes back into one stretched layout.
    TestCase {
        name: "CpuSizes"
        when: windowShown

        function feedTo(host, obj) { host.metricsJson = JSON.stringify(obj) }

        // 0.5x0.5 - headerless bare ring: the one number, nothing else.
        function test_micro_is_bare_ring() {
            tryVerify(function () { return hMicro.ready }, 3000)
            var w = hMicro.item
            w.sizeClass = "compact"
            feedTo(hMicro, { cpu_usage_percent: 42, cpu_temp_celsius: 55 })
            compare(w.micro, true, "a 344x416 compact box is the micro tile")
            compare(w.showHeader, false, "micro hides the header - nothing competes with the number")
            var g = findGauge(w)
            verify(g !== null, "the gauge is there")
            compare(g.showSpark, false, "micro reserves no sparkline slot")
            compare(g.history.length, 0, "micro feeds the sparkline nothing")
            compare(g.sub, "", "micro shows only the one number")
            verify(g.bigMax > 60, "the headerless number is allowed to fill its box")
        }

        // 1x1 baseline - header + ring + the classic sparkline strip.
        function test_baseline_keeps_header_and_spark_strip() {
            tryVerify(function () { return hBase.ready }, 3000)
            var w = hBase.item
            w.sizeClass = "compact"
            w.hist = []
            feedTo(hBase, { cpu_usage_percent: 30, cpu_core_count: 8,
                            cpu_frequency_mhz: 4200, cpu_load_1: 0.7 })
            feedTo(hBase, { cpu_usage_percent: 40, cpu_core_count: 8,
                            cpu_frequency_mhz: 4200, cpu_load_1: 0.7 })
            compare(w.micro, false, "a 696x840 compact box is the baseline, not micro")
            compare(w.showHeader, true, "the baseline keeps the header")
            var g = findGauge(w)
            compare(g.showSpark, true, "the baseline keeps the sparkline")
            compare(g.horizontal, false, "stacked, not side-by-side")
            compare(g.sparkFills, false, "classic sparkline strip at the baseline")
            compare(g.sub, "", "no avg/peak line at the baseline (no room to earn it)")
            verify(g.detailItems.length >= 3,
                   "the baseline uses its history area for cores, clock, and load context")
            compare(g.detailLabelPixelSize, hBase.theme.fontLabel,
                    "CPU supporting labels use the readable label token")
            compare(g.detailValuePixelSize, hBase.theme.fontTitle,
                    "CPU detail values use the stronger title token")
            verify(Qt.colorEqual(g.detailLabelColor, hBase.theme.textPrimary),
                   "CPU detail labels use primary contrast, not tertiary contrast")
            compare(g.historyCaptionPixelSize, hBase.theme.fontLabel,
                    "the history window remains readable at display distance")
            verify(g.detailRowHeight >= g.detailLabelPixelSize + g.detailValuePixelSize + 19,
                   "the raised typography expands its row instead of clipping")
            verify(g.historySlotMinimumHeight > g.height * g.sparkFrac,
                   "detail rows and captions override the legacy fractional history slot")
            verify(g.historySlotMinimumHeight
                   >= g.detailRowHeight * g.effectiveDetailRows
                      + g.historyCaptionPixelSize + hBase.theme.fontMinimum,
                   "the history slot reserves height for every readable text section")
        }

        // wide - ring beside the sparkline in BOTH projections of the class
        // (1x0.5 portrait 696x416, 0.5x1 landscape 840x344).
        function test_wide_puts_spark_beside_ring_in_both_orientations() {
            tryVerify(function () { return hWide.ready }, 3000)
            var w = hWide.item
            w.sizeClass = "wide"
            w.hist = []
            feedTo(hWide, { cpu_usage_percent: 30 })
            feedTo(hWide, { cpu_usage_percent: 60 })
            var g = findGauge(w)
            compare(g.horizontal, true, "wide lays ring and sparkline side by side")
            compare(g.showSpark, true, "the sparkline is the point of going wide")
            verify(g.history.length >= 2, "and it gets the real history")
            // The other projection of the same class.
            wideWrap.width = 840; wideWrap.height = 344
            compare(g.horizontal, true, "the landscape projection stays side-by-side")
            wideWrap.width = 696; wideWrap.height = 416
        }

        function test_wide_supporting_values_do_not_truncate() {
            tryVerify(function () { return hWide.ready }, 3000)
            var w = hWide.item
            w.sizeClass = "wide"
            w.hist = [0.3, 0.6]
            feedTo(hWide, { cpu_usage_percent: 60, cpu_core_count: 16,
                            cpu_frequency_mhz: 4675, cpu_load_1: 1.34,
                            cpu_top_process_name: "rustc",
                            cpu_top_process_percent: 18 })
            var g = findGauge(w)
            compare(g.horizontalDetailColumns, 2,
                    "wide CPU uses a 2x2 detail grid instead of four narrow cards")
            compare(g.effectiveDetailRows, 2, "all four supporting facts remain visible")

            function verifyProjection(width, height, tag) {
                wideWrap.width = width
                wideWrap.height = height
                wait(50)
                var busiest = findText(w, "BUSIEST")
                var process = findText(w, "rustc 18%")
                verify(busiest !== null, tag + " keeps the busiest-process label")
                verify(process !== null, tag + " keeps the busiest-process value")
                verify(!busiest.truncated && busiest.contentWidth <= busiest.width + 1,
                       tag + " busiest label fits its supported footprint")
                verify(!process.truncated && process.contentWidth <= process.width + 1,
                       tag + " busiest value fits its supported footprint")
            }

            verifyProjection(696, 416, "portrait 1x0.5")
            verifyProjection(840, 344, "landscape 0.5x1")
            wideWrap.width = 696
            wideWrap.height = 416
        }

        function test_narrow_thermal_alert_and_sensor_label_fit_data() {
            return [
                { tag: "portrait-0.5x1", width: 348, height: 818 },
                { tag: "landscape-1x0.5-at-125-percent", width: 338, height: 490 }
            ]
        }

        // Regression for the two CPU rows caught by the systemic legibility
        // matrix. Exercise their actual projected geometry, font, text scale,
        // and saturated thermal content without relaxing the shared gate.
        function test_narrow_thermal_alert_and_sensor_label_fit(row) {
            tryVerify(function () { return hTall.ready }, 3000)
            tallWrap.width = row.width
            tallWrap.height = row.height
            hTall.theme.textScale = 1.3
            hTall.theme.fontChoice = "hyperlegible"

            var w = hTall.item
            w.sizeClass = "tall"
            w.hist = [0.72, 0.91, 1.0]
            feedTo(hTall, {
                cpu_usage_percent: 100,
                cpu_temp_celsius: 110,
                cpu_core_count: 128
            })
            wait(50)

            compare(w.status, "110°C critical",
                    row.tag + " keeps the reading and severity in the header")
            verify(w.accessibleSummary.indexOf("Critical temperature") >= 0,
                   row.tag + " retains the full thermal meaning for accessibility")
            var statusText = findText(w, "110°C critical")
            verify(statusText !== null && statusText.visible,
                   row.tag + " renders the compact thermal status")
            verify(!statusText.truncated
                   && statusText.contentWidth <= statusText.width + 1,
                   row.tag + " thermal status is not truncated")

            var gauge = findGauge(w)
            verify(gauge !== null, row.tag + " keeps the metric gauge")
            var sensorIndex = -1
            for (var i = 0; i < gauge.detailItems.length; i++)
                if (gauge.detailItems[i].label === "SENSOR") sensorIndex = i
            verify(sensorIndex >= 0,
                   row.tag + " exposes the temperature source with a compact label")
            var sensorLabel = findObjectName(w, "metricDetailLabel_" + sensorIndex)
            verify(sensorLabel !== null && sensorLabel.visible,
                   row.tag + " renders the sensor label")
            compare(sensorLabel.text, "SENSOR", row.tag + " uses the compact label")
            verify(!sensorLabel.truncated
                   && sensorLabel.contentWidth <= sensorLabel.width + 1,
                   row.tag + " sensor label is not truncated")
        }

        function cleanup() {
            tallWrap.width = 344
            tallWrap.height = 840
            hTall.theme.textScale = 1.15
            hTall.theme.fontChoice = "hyperlegible"
        }

        // tall - the sparkline earns real height and the ring captions itself
        // with avg/peak (genuinely more information).
        function test_tall_earns_spark_height_and_avg_peak() {
            tryVerify(function () { return hTall.ready }, 3000)
            var w = hTall.item
            w.sizeClass = "tall"
            w.hist = []
            feedTo(hTall, { cpu_usage_percent: 20 })
            feedTo(hTall, { cpu_usage_percent: 80 })
            var g = findGauge(w)
            compare(g.sparkFills, true, "tall hands the sparkline all the height below the ring")
            compare(g.stackedRingMaxFraction, 0.62,
                    "the narrow tall card keeps the ring sized by its width")
            compare(w.histStats, "avg 50% · peak 80%", "avg/peak derive from the retained history")
            compare(g.sub, "avg 50% · peak 80%", "and the ring captions itself with them")
            // One sample has no average story to tell.
            w.hist = []
            feedTo(hTall, { cpu_usage_percent: 20 })
            compare(w.histStats, "", "a single sample earns no avg/peak line")
        }

        function test_roomy_tall_rebalances_ring_for_context() {
            tryVerify(function () { return hTall.ready }, 3000)
            var w = hTall.item
            w.sizeClass = "tall"
            tallWrap.width = 696
            tallWrap.height = 1226
            wait(0)
            var g = findGauge(w)
            compare(w.roomyTile, true)
            compare(g.stackedRingMaxFraction, 0.48,
                    "the half-screen portrait card gives more height to context and history")
            tallWrap.width = 344
            tallWrap.height = 840
        }

        // showHistory=false must also silence the tall tile's avg/peak line -
        // the option means "no history anywhere", not "no graph".
        function test_tall_avg_peak_respects_showHistory() {
            tryVerify(function () { return hTall.ready }, 3000)
            var w = hTall.item
            w.sizeClass = "tall"
            w.hist = []
            feedTo(hTall, { cpu_usage_percent: 20 })
            feedTo(hTall, { cpu_usage_percent: 80 })
            hTall.storeCtl.setSetting("test-instance", "showHistory", false)
            compare(w.histStats, "", "showHistory=false silences avg/peak too")
            hTall.storeCtl.setSetting("test-instance", "showHistory", true)
        }

        // full (the overlay) - never micro; the expanded gauge keeps its
        // core-count sub-line (asserted in the Cpu case above).
        function test_full_is_never_micro() {
            tryVerify(function () { return h.ready }, 3000)
            var w = h.item
            w.sizeClass = "full"
            compare(w.micro, false, "full is never micro")
            compare(w.showHeader, true, "the overlay keeps the header")
            compare(findGauge(w).showSpark, true, "the overlay keeps the sparkline")
        }
    }

    // ── Shared MetricGauge (directly instantiated) ───────────────────────────
    TestCase {
        name: "GaugeShared"
        when: windowShown

        function test_ok_false_dims_the_ring() {
            mg.ok = false
            mg.value = 0.7
            var ring = findRing(gaugeHost)
            verify(ring !== null, "ring present")
            compare(ring.value, 0, "ok:false forces the ring empty (the N/A path CpuWidget never uses)")
            mg.ok = true
        }

        function test_value_is_clamped() {
            // The metric ring eases between samples (W3), so assert the landed
            // targets with tryCompare rather than sampling mid-glide.
            mg.ok = true
            mg.value = 1.5
            var ring = findRing(gaugeHost)
            tryCompare(ring, "value", 1, 2000, "value >1 clamps to full")
            mg.value = -0.5
            tryCompare(findRing(gaugeHost), "value", 0, 2000, "value <0 clamps to empty")
            mg.value = 0.5
            tryVerify(function () { return Math.abs(findRing(gaugeHost).value - 0.5) < 1e-9 },
                      2000, "in-range value passes through")
        }
    }

    // ── CPU config schema (directly instantiated) ────────────────────────────
    TestCase {
        name: "ConfigSchemaCpu"
        when: windowShown

        function test_cpu_display_fields_and_defaults() {
            var s = schema.schemaFor("cpu")
            verify(s && s.sections && s.sections.length > 0, "cpu has a schema")
            var showTemp = findField(s, "showTemp")
            var tempSource = findField(s, "tempSource")
            var showHistory = findField(s, "showHistory")
            var historyWindow = findField(s, "historyWindow")
            var showFrequency = findField(s, "showFrequency")
            var showLoadAverage = findField(s, "showLoadAverage")
            var showPerCore = findField(s, "showPerCore")
            var showTopProcess = findField(s, "showTopProcess")
            var warnTemp = findField(s, "warnTemp")
            verify(showTemp && showTemp.type === "toggle", "showTemp is a toggle")
            compare(showTemp.dflt, true, "showTemp defaults true (matches the widget)")
            verify(tempSource && tempSource.type === "segmented", "tempSource is segmented")
            compare(tempSource.dflt, "auto", "tempSource defaults automatic")
            verify(showHistory && showHistory.type === "toggle", "showHistory is a toggle")
            compare(showHistory.dflt, true, "showHistory defaults true")
            verify(historyWindow && historyWindow.type === "segmented", "historyWindow is segmented")
            compare(historyWindow.dflt, "2m", "historyWindow defaults to two minutes")
            compare(historyWindow.visibleWhen.key, "showHistory",
                    "history duration is disclosed only when history is enabled")
            compare(historyWindow.visibleWhen.equals, true)
            verify(showTemp.label.indexOf("label") >= 0,
                   "temperature toggle says it hides only the label")
            verify(showTemp.help.indexOf("remain active") >= 0,
                   "the config explains that thermal safety remains active")
            verify(showFrequency && showFrequency.type === "toggle", "showFrequency is a toggle")
            compare(showFrequency.dflt, true, "showFrequency defaults true")
            verify(showLoadAverage && showLoadAverage.type === "toggle", "showLoadAverage is a toggle")
            compare(showLoadAverage.dflt, true, "showLoadAverage defaults true")
            verify(showPerCore && showPerCore.type === "toggle", "showPerCore is a toggle")
            compare(showPerCore.dflt, true, "showPerCore defaults true")
            verify(showTopProcess && showTopProcess.type === "toggle", "showTopProcess is a toggle")
            compare(showTopProcess.dflt, true, "showTopProcess defaults true")
            verify(warnTemp && warnTemp.type === "slider", "warnTemp is a slider")
            compare(warnTemp.dflt, 85, "warnTemp default matches the widget (85)")
            compare(warnTemp.min, 60, "warnTemp min 60")
            compare(warnTemp.max, 100, "warnTemp max 100")
        }

        function test_cpu_has_custom_title_field() {
            var s = schema.schemaFor("cpu")
            verify(findField(s, "title") !== null, "cpu exposes a custom title field")
        }
    }
}
