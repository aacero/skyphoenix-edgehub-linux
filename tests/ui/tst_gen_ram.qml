import QtQuick
import QtTest
import "../../ui/qml" as App


// Comprehensive coverage for the Memory (RAM) metric widget
// (ui/qml/widgets/RamWidget.qml) plus its shared config schema.
//
// Drives config through the DashboardStore the widget is wired to, and asserts
// on the widget's own derived state (v/unit/showHistory/hist/col()/gb()/effAccent)
// as well as the rendered MetricGauge (centre "big" text, "sub" line, ring).
//
// Regression checks cover truthful availability, binary unit labels, detailed
// memory categories, pressure, freshness, retained statistics and layout.
Item {
    id: root
    width: 460; height: 640

    // Main harness - expanded tile; metrics are driven directly per-test.
    WidgetHarness { id: hRam;   width: 420; height: 520; widgetFile: "RamWidget.qml"; expanded: true }
    // Compact half-width portrait tile (non-expanded) for the gb-mode overflow test.
    WidgetHarness { id: hSmall; width: 340; height: 560; widgetFile: "RamWidget.qml"; expanded: false }
    // A harness that is NEVER fed metrics → the pre-first-tick state.
    WidgetHarness { id: hFresh; width: 340; height: 560; widgetFile: "RamWidget.qml"; expanded: false }

    // Shared config schema (instantiated directly like the store/schema tests).
    App.WidgetConfigSchema { id: schema }

    // ── generic object-tree helpers ────────────────────────────────────────
    function walk(node, pred, acc) {
        if (!node) return acc
        var kids = node.children
        if (kids) {
            for (var i = 0; i < kids.length; i++) {
                var c = kids[i]
                if (c && pred(c)) acc.push(c)
                walk(c, pred, acc)
            }
        }
        return acc
    }
    function findAll(rootObj, pred) { return walk(rootObj, pred, []) }
    function findOne(rootObj, pred) { var a = walk(rootObj, pred, []); return a.length ? a[0] : null }

    function isGauge(o) {
        return typeof o.big === "string" && typeof o.sub === "string" && typeof o.history === "object"
    }
    function isRing(o) {
        return typeof o.thickness === "number" && typeof o.value === "number"
               && o.progressColor !== undefined && o.trackColor !== undefined
    }
    function isText(o) { return typeof o.text === "string" && o.font !== undefined }
    function isMouseArea(o) {
        return typeof o.pressed === "boolean" && typeof o.acceptedButtons !== "undefined"
               && typeof o.hoverEnabled === "boolean"
    }

    function gaugeOf(w) { return findOne(w, isGauge) }
    function hasText(rootObj, text) {
        return findOne(rootObj, function (o) { return isText(o) && o.text === text }) !== null
    }

    function clearCfg(h) {
        var s = h.storeCtl.settingsFor("test-instance")
        for (var k in s) delete s[k]
        h.storeCtl._touchSettings()
    }

    // ── Config: schema shape ───────────────────────────────────────────────
    TestCase {
        name: "RamConfigSchema"
        when: windowShown

        function test_ram_schema_exposes_expected_fields() {
            var s = schema.schemaFor("ram")
            verify(s && s.sections && s.sections.length > 0, "ram has a schema")
            var keys = {}
            var types = {}
            for (var j = 0; j < s.sections.length; j++)
                for (var k = 0; k < (s.sections[j].fields || []).length; k++) {
                    var f = s.sections[j].fields[k]
                    keys[f.key] = true; types[f.key] = f.type
                }
            verify(keys["unit"], "exposes 'unit'")
            verify(keys["showHistory"], "exposes 'showHistory'")
            verify(keys["historyWindow"], "exposes 'historyWindow'")
            verify(keys["showDetails"], "exposes 'showDetails'")
            verify(keys["warnPercent"], "exposes 'warnPercent'")
            verify(keys["title"], "exposes custom title")
            verify(keys["accent"], "exposes per-widget accent")
            verify(keys["cardBackdrop"], "exposes per-widget backdrop")
            compare(types["unit"], "segmented", "unit is a segmented control")
            compare(types["showHistory"], "toggle", "showHistory is a toggle")
            compare(types["historyWindow"], "segmented", "historyWindow is segmented")
            compare(types["showDetails"], "toggle", "showDetails is a toggle")
            compare(types["warnPercent"], "slider", "warnPercent is a slider")
        }

        function test_history_window_is_conditional_and_names_each_duration() {
            var s = schema.schemaFor("ram")
            var historyWindow = null
            for (var j = 0; j < s.sections.length; j++)
                for (var k = 0; k < (s.sections[j].fields || []).length; k++)
                    if (s.sections[j].fields[k].key === "historyWindow")
                        historyWindow = s.sections[j].fields[k]
            verify(historyWindow !== null)
            compare(historyWindow.dflt, "2m")
            compare(historyWindow.visibleWhen.key, "showHistory")
            compare(historyWindow.visibleWhen.equals, true)
            compare(historyWindow.options.map(function(o) { return o.value }).join(","),
                    "1m,2m,5m")
        }

        function test_unit_options_are_percent_and_gb() {
            var s = schema.schemaFor("ram")
            var unitField = null
            for (var j = 0; j < s.sections.length; j++)
                for (var k = 0; k < (s.sections[j].fields || []).length; k++)
                    if (s.sections[j].fields[k].key === "unit") unitField = s.sections[j].fields[k]
            verify(unitField, "found unit field")
            compare(unitField.dflt, "percent", "defaults to percent")
            var vals = unitField.options.map(function (o) { return o.value })
            compare(vals.sort(), ["gb", "percent"], "offers percent + gb")
        }
    }

    // ── Derived logic: col()/gb()/v/defaults ───────────────────────────────
    TestCase {
        name: "RamDerivedLogic"
        when: windowShown
        function init() { tryVerify(function () { return hRam.ready }, 3000); clearCfg(hRam) }

        function test_config_defaults() {
            var w = hRam.item
            compare(w.unit, "percent", "unit defaults to percent")
            compare(w.showHistory, true, "showHistory defaults to true")
            compare(w.historyWindow, "2m", "history defaults to two minutes")
            compare(w.showDetails, true, "showDetails defaults to true")
            compare(w.warnPercent, 75, "warning threshold defaults to 75%")
        }

        function test_v_reads_ram_usage_percent() {
            var w = hRam.item
            w.metrics = { ram_usage_percent: 63 }
            compare(w.v, 63, "v mirrors ram_usage_percent")
            w.metrics = {}
            compare(w.v, 0, "missing percent → 0")
        }

        function test_col_thresholds() {
            var w = hRam.item
            var th = hRam.theme
            compare(String(w.col(50)), String(w.effAccent), "50% → accent")
            compare(String(w.col(74.9)), String(w.effAccent), "below 75% → accent")
            compare(String(w.col(75)), String(th.warning), "75% boundary → warning")
            compare(String(w.col(89.9)), String(th.warning), "below critical → warning")
            compare(String(w.col(90)), String(th.error), "90% boundary → error")
            compare(String(w.col(99)), String(th.error), "99% → error")
        }

        function test_warning_threshold_is_configurable_and_clamped() {
            var w = hRam.item
            hRam.storeCtl.setSetting("test-instance", "warnPercent", 85)
            compare(w.warnPercent, 85)
            compare(String(w.col(80)), String(w.effAccent))
            compare(String(w.col(85)), String(hRam.theme.warning))
            hRam.storeCtl.setSetting("test-instance", "warnPercent", 200)
            compare(w.warnPercent, 95)
        }

        function test_effAccent_recolours_ring_and_number() {
            var w = hRam.item
            var th = hRam.theme
            w.accentName = "green"
            verify(Qt.colorEqual(w.effAccent, th.accentPresets["green"].a),
                   "effAccent resolves the preset colour")
            compare(String(w.col(50)), String(w.effAccent),
                    "col() below thresholds returns effAccent (recolours ring/number)")
            w.accentName = ""
        }

        function test_gb_uses_gibibyte_divisor() {
            var w = hRam.item
            // 1 GiB exactly → "1.0"
            compare(w.gb(1073741824), "1.0", "1 GiB → 1.0")
        }

        function test_gib_label_matches_binary_hardware_size() {
            // Memory is measured in binary units. A 32 GiB value is exactly
            // 34359738368 bytes, so the 2^30 divisor is correct. The old
            // 32e9-byte (decimal) premise contradicted test_gb_uses_gibibyte_divisor.
            var w = hRam.item
            compare(w.gb(34359738368), "32.0",
                    "a 32 GiB value should read 32.0 GiB")
        }
    }

    // ── MetricGauge rendering: centre reading honours unit, reacts live ─────
    TestCase {
        name: "RamGaugeReading"
        when: windowShown
        function init() { tryVerify(function () { return hRam.ready }, 3000); clearCfg(hRam) }

        function feed(w) {
            w.metrics = { ram_usage_percent: 63,
                          ram_used_bytes: 23200000000,
                          ram_total_bytes: 34359738368 }
        }

        function test_percent_mode_centre_is_percent() {
            var w = hRam.item; feed(w)
            var g = gaugeOf(w)
            verify(g, "found the gauge")
            hRam.storeCtl.setSetting("test-instance", "unit", "percent")
            compare(g.big, "63%", "percent mode shows NN% in the centre")
        }

        function test_gb_mode_centre_is_used_gb() {
            var w = hRam.item; feed(w)
            var g = gaugeOf(w)
            hRam.storeCtl.setSetting("test-instance", "unit", "gb")
            compare(g.big, w.gb(23200000000) + " GiB", "binary mode shows used GiB in the centre")
        }

        function test_unit_toggles_live_on_revision_bump() {
            var w = hRam.item; feed(w)
            var g = gaugeOf(w)
            hRam.storeCtl.setSetting("test-instance", "unit", "percent")
            compare(g.big, "63%", "starts as percent")
            hRam.storeCtl.setSetting("test-instance", "unit", "gb")
            verify(g.big.indexOf("GiB") >= 0, "flips to GiB live (store.revision bump)")
            hRam.storeCtl.setSetting("test-instance", "unit", "percent")
            compare(g.big, "63%", "flips back to percent live")
        }

        function test_ring_value_clamps_above_100() {
            // AUDIT testCase: ram_usage_percent > 100 clamps the ring to full.
            var w = hRam.item
            w.metrics = { ram_usage_percent: 150 }
            var g = gaugeOf(w)
            compare(g.value, 1, "gauge ring value clamps to 1.0 (no overflow)")
            var ring = findOne(g, isRing)
            verify(ring, "found ring")
            verify(ring.value <= 1.0, "ring stays clamped to full")
        }

        function test_gb_mode_does_not_print_used_twice() {
            // AUDIT (low): in gb mode the used figure shows in BOTH the centre
            // ("21.6 GB") and the sub-line ("21.6 / 32.0 GB").
            var w = hRam.item; feed(w)
            var g = gaugeOf(w)
            hRam.storeCtl.setSetting("test-instance", "unit", "gb")
            var usedStr = w.gb(23200000000)               // e.g. "21.6"
            verify(g.big.indexOf(usedStr) >= 0, "centre prints the used figure")
            verify(g.sub.indexOf(usedStr) < 0,
                   "sub-line should NOT repeat the used figure already shown in the centre")
        }
    }

    // ── showHistory config toggles the sparkline data live ──────────────────
    TestCase {
        name: "RamHistoryToggle"
        when: windowShown
        function init() { tryVerify(function () { return hRam.ready }, 3000); clearCfg(hRam) }

        function test_showHistory_gates_the_sparkline() {
            var w = hRam.item
            w.hist = []
            // Seed a few real samples so the sparkline has data.
            for (var i = 1; i <= 4; i++) w.metrics = { ram_usage_percent: 40 + i }
            var g = gaugeOf(w)
            verify(w.hist.length > 1, "history accumulated (" + w.hist.length + ")")

            hRam.storeCtl.setSetting("test-instance", "showHistory", true)
            compare(g.history.length, w.hist.length, "showHistory=true → gauge gets the samples")

            hRam.storeCtl.setSetting("test-instance", "showHistory", false)
            compare(g.history.length, 0, "showHistory=false → gauge history emptied live")

            hRam.storeCtl.setSetting("test-instance", "showHistory", true)
            compare(g.history.length, w.hist.length, "back on live")
        }
    }

    // ── History buffer behaviour (append / FIFO cap / guards) ───────────────
    TestCase {
        name: "RamHistoryBuffer"
        when: windowShown
        function init() { tryVerify(function () { return hRam.ready }, 3000); clearCfg(hRam) }

        // NOTE: onMetricsChanged reads w.v (a binding on metrics) which settles one
        // tick after the handler fires, so history lags the feed by exactly one
        // sample. These tests feed a value twice (or assert order-only) to stay
        // robust to that ordering rather than depending on it.
        function test_appends_a_sample_per_tick() {
            var w = hRam.item
            w.hist = []
            w.metrics = { ram_usage_percent: 63 }   // records the settling of the prior v
            w.metrics = { ram_usage_percent: 63 }   // v has settled to 63 → records 0.63
            compare(w.hist.length, 2, "one sample appended per metrics tick")
            fuzzyCompare(w.hist[w.hist.length - 1], 0.63, 1e-9, "sample is percent/100")
        }

        function test_history_cap_follows_the_named_window() {
            var w = hRam.item
            w.hist = []
            hRam.storeCtl.setSetting("test-instance", "historyWindow", "1m")
            for (var i = 1; i <= 40; i++) w.metrics = { ram_usage_percent: i }
            compare(w.historyLimit, 30)
            compare(w.historyLabel, "1 minute")
            compare(w.hist.length, 30, "one-minute buffer is capped at 30 samples")
            verify(w.hist[0] < w.hist[29], "oldest samples were dropped, newest retained")
            for (var j = 0; j < w.hist.length; j++)
                verify(w.hist[j] >= 0 && w.hist[j] <= 1, "every sample is normalised 0..1")
            hRam.storeCtl.setSetting("test-instance", "historyWindow", "5m")
            compare(w.historyLimit, 150)
            compare(w.historyLabel, "5 minutes")
        }

        function test_partial_frame_should_not_seed_a_false_zero() {
            // AUDIT (low): onMetricsChanged has no availability guard, so a metrics
            // frame lacking ram_usage_percent pushes (undefined||0)/100 = 0 and the
            // sparkline dips to the floor for a dip that never happened.
            var w = hRam.item
            w.hist = []
            w.metrics = { ram_usage_percent: 63, ram_used_bytes: 2e10, ram_total_bytes: 3e10 }
            w.metrics = { ram_usage_percent: 63, ram_used_bytes: 2e10, ram_total_bytes: 3e10 }
            fuzzyCompare(w.hist[w.hist.length - 1], 0.63, 1e-9, "real samples recorded")
            // Two partial frames (total present, usage_percent missing): a widget that
            // guarded on availability (as GpuWidget does) would append nothing.
            w.metrics = { ram_total_bytes: 3e10 }
            w.metrics = { ram_total_bytes: 3e10 }
            verify(w.hist[w.hist.length - 1] !== 0,
                   "a frame with no ram_usage_percent must not append a spurious 0")
        }
    }

    // ── Detailed memory categories, freshness and truthful state ────────────
    TestCase {
        name: "RamDetails"
        when: windowShown
        function init() {
            tryVerify(function () { return hRam.ready }, 3000)
            clearCfg(hRam)
            hRam.item.hist = []
        }

        function detailFrame() {
            return {
                ram_metrics_available: true,
                ram_sample_unix_ms: Date.now(),
                ram_unavailable_reason: "",
                ram_usage_percent: 50,
                ram_total_bytes: 17179869184,
                ram_used_bytes: 8589934592,
                ram_available_bytes: 8589934592,
                ram_cached_bytes: 4294967296,
                ram_buffers_bytes: 536870912,
                swap_total_bytes: 8589934592,
                swap_used_bytes: 2147483648,
                ram_pressure_some_avg10: 0.25
            }
        }

        function test_expanded_details_fill_supported_memory_categories() {
            var w = hRam.item
            w.metrics = detailFrame()
            compare(w.freshness, "updated now")
            compare(w.status, "updated now", "freshness appears in the header")
            compare(w.swapText, "2.0 / 8.0 GiB")
            compare(w.pressureText, "0.25%")
            compare(w.pressureSummary, "0.25% tasks stalled, 10s")
            verify(hasText(w, "8.0 GiB"), "available memory is shown")
            verify(hasText(w, "4.0 GiB"), "cache is shown")
            verify(hasText(w, "0.5 GiB"), "buffers are shown")
            verify(hasText(w, "2.0 / 8.0 GiB"), "swap use and capacity are shown")
            verify(hasText(w, "0.25%"), "Linux memory pressure is shown")
            verify(hasText(w, "STALLS, 10S"),
                   "pressure is labelled as task stalls rather than utilization")
        }

        function test_explicit_read_failure_is_not_a_real_zero() {
            var w = hRam.item
            w.metrics = { ram_metrics_available: false, ram_usage_percent: 0,
                          ram_unavailable_reason: "The kernel memory summary could not be read" }
            compare(w.avail, false)
            compare(gaugeOf(w).big, "N/A", "read failure is not rendered as 0%")
            compare(w.status, "unavailable")
            compare(w.unavailableReason, "The kernel memory summary could not be read")
            compare(w.hist.length, 0, "unavailable samples do not enter history")
        }

        function test_warning_and_critical_states_do_not_depend_on_colour() {
            var w = hRam.item
            w.metrics = { ram_metrics_available: true, ram_usage_percent: 80,
                          ram_total_bytes: 17179869184, ram_used_bytes: 13743895347,
                          ram_available_bytes: 3435973837 }
            compare(w.alertLevel, "warning")
            compare(w.alertText, "High memory use")
            verify(w.status.indexOf("High memory use") >= 0)
            verify(w.accessibleSummary.indexOf("High memory use") >= 0)
            w.metrics = { ram_metrics_available: true, ram_usage_percent: 95,
                          ram_total_bytes: 17179869184, ram_used_bytes: 16320875725,
                          ram_available_bytes: 858993459 }
            compare(w.alertLevel, "critical")
            compare(w.alertText, "Critical memory use")
            verify(w.status.indexOf("Critical memory use") >= 0)
            verify(w.accessibleSummary.indexOf("Critical memory use") >= 0)
        }

        function test_pressure_is_context_not_memory_utilization() {
            var w = hRam.item
            w.metrics = { ram_metrics_available: true, ram_usage_percent: 40,
                          ram_total_bytes: 17179869184, ram_used_bytes: 6871947674,
                          ram_available_bytes: 10307921510,
                          ram_pressure_some_avg10: 12.5 }
            compare(w.v, 40, "PSI never replaces the utilization reading")
            compare(w.alertLevel, "normal", "utilization warning remains independent")
            compare(w.pressureSummary, "12.50% tasks stalled, 10s")
        }

        function test_history_reports_min_average_and_peak() {
            var w = hRam.item
            w.hist = [0.2, 0.5, 0.8]
            compare(w.histStats, "min 20% · avg 50% · peak 80%")
            compare(w.historyLabel, "2 minutes")
            compare(gaugeOf(w).historyCaption, "2 MINUTES UTILIZATION")
            compare(gaugeOf(w).sub, "min 20% · avg 50% · peak 80%",
                    "expanded gauge uses the retained statistics")
        }

        // Audit 2026-08-03: this proved the setting REACHED the widget and
        // stopped there, so a widget that read the property and then ignored it
        // would have passed. Assert the surfaces it actually governs - the same
        // gap gpu's showDetails had.
        function test_showDetails_reacts_live() {
            var w = hRam.item
            compare(w.showDetails, true)
            var panel = findOne(w, function (n) {
                return n && n.objectName === "ramDetailPanel" })
            verify(panel !== null, "the detail panel exists")
            verify(panel.visible, "the detail panel shows while the toggle is on")
            hRam.storeCtl.setSetting("test-instance", "showDetails", false)
            compare(w.showDetails, false, "detail visibility follows the shared configuration")
            compare(panel.visible, false,
                    "the detail panel hides when the toggle is off")
            // The gauge sub-line is the toggle's other surface, but every branch
            // that fills it needs live byte counts this case does not feed, so it
            // is asserted where the data exists rather than pinned to "" here.
        }
    }

    // ── No-data / pre-first-tick state ──────────────────────────────────────
    TestCase {
        name: "RamNoData"
        when: windowShown
        function init() { tryVerify(function () { return hFresh.ready }, 3000) }

        function test_pre_first_tick_shows_neutral_placeholder_not_zero() {
            // AUDIT (low): before the first real metrics frame (metrics == {}), the
            // tile confidently prints "0.0 / 0.0 GB" / "0%" instead of a placeholder.
            var w = hFresh.item
            var g = gaugeOf(w)
            verify(g, "found gauge")
            verify(g.sub !== "0.0 / 0.0 GB",
                   "with no metrics yet the sub-line should be a neutral placeholder, not 0.0 / 0.0 GB")
        }

        function test_zero_total_is_graceful() {
            // AUDIT (low): ram_total_bytes==0 (read failure) still renders "0.0 / 0.0 GB".
            var w = hFresh.item
            w.metrics = { ram_used_bytes: 0, ram_total_bytes: 0, ram_usage_percent: 0 }
            var g = gaugeOf(w)
            verify(g.sub !== "0.0 / 0.0 GB",
                   "a 0-byte total should read as no-data, not a real 0-byte machine")
        }
    }

    // ── gb-mode centre text must fit inside the ring on a compact tile ──────
    TestCase {
        name: "RamGbOverflow"
        when: windowShown
        function init() { tryVerify(function () { return hSmall.ready }, 3000); clearCfg(hSmall) }

        function test_gb_centre_text_fits_ring_interior() {
            // AUDIT (medium): the long "NN.N GB" centre string has no width/elide
            // constraint, so on a half-width portrait tile it overruns the ring.
            var w = hSmall.item
            hSmall.storeCtl.setSetting("test-instance", "unit", "gb")
            w.metrics = { ram_usage_percent: 68,
                          ram_used_bytes: 23200000000,   // → "21.6 GB"
                          ram_total_bytes: 34359738368 }
            var g = gaugeOf(w)
            var ring = findOne(g, isRing)
            verify(ring && ring.width > 0, "ring laid out (w=" + (ring ? ring.width : -1) + ")")
            tryVerify(function () { return ring.width > 0 }, 2000)

            var bigText = findOne(g, function (o) { return isText(o) && o.text === g.big })
            verify(bigText, "found the centre text \"" + g.big + "\"")

            var interior = ring.width - 2 * ring.thickness
            verify(bigText.width <= interior,
                   "centre text (" + bigText.width.toFixed(0) + "px) must fit inside the ring interior ("
                   + interior.toFixed(0) + "px)")
        }

        // The value's box spans the ring's inner width (so it can shrink-to-fit),
        // and the box is itself centred in the ring. So a SHORT value ("4%") only
        // looks centred if the TEXT is centre-aligned WITHIN that box - otherwise
        // it left-aligns and sits visibly off-centre. That exact regression (the
        // overflow fix's wide box + a missing horizontalAlignment) is what the
        // marketing screenshots caught. The offset lives in the text's content
        // position, which can only be read via ink metrics (unreliable headless),
        // so pin the alignment PROPERTY - it is the fix, and Text renders directly
        // from it - plus prove the box really is wider than the value, so the
        // alignment is load-bearing rather than moot.
        function test_gauge_value_is_centred_in_the_ring() {
            var w = hSmall.item
            hSmall.storeCtl.setSetting("test-instance", "unit", "percent")
            w.metrics = { ram_usage_percent: 4, ram_used_bytes: 2000000000,
                          ram_total_bytes: 34359738368 }   // → a short "4%"
            var g = gaugeOf(w)
            var ring = findOne(g, isRing)
            tryVerify(function () { return ring && ring.width > 0 }, 2000)
            var bigText = findOne(g, function (o) { return isText(o) && o.text === g.big })
            verify(bigText, "found the centre text \"" + g.big + "\"")
            compare(bigText.horizontalAlignment, Text.AlignHCenter,
                    "the value must be centre-aligned in its box, not left")
            verify(bigText.width > bigText.contentWidth + 2,
                   "the box is wider than the value (" + bigText.width.toFixed(0) + " > "
                   + bigText.contentWidth.toFixed(0) + "), so the alignment is what centres it")
        }
    }

    // ── Per-sizeClass structure (W1 wave 2a) ────────────────────────────────
    // Fixed-size hosts at real projected cell footprints.
    Item { width: 344; height: 416
        WidgetHarness { id: hMicro; anchors.fill: parent; widgetFile: "RamWidget.qml"; expanded: false } }
    Item { id: wideWrap; width: 696; height: 416
        WidgetHarness { id: hWide; anchors.fill: parent; widgetFile: "RamWidget.qml"; expanded: false } }
    Item { width: 344; height: 840
        WidgetHarness { id: hTall; anchors.fill: parent; widgetFile: "RamWidget.qml"; expanded: false } }
    Item { width: 696; height: 1227
        WidgetHarness { id: hRoomyTall; anchors.fill: parent; widgetFile: "RamWidget.qml"; expanded: false } }
    Item { width: 1015; height: 490
        WidgetHarness { id: hRoomyWide; anchors.fill: parent; widgetFile: "RamWidget.qml"; expanded: false } }

    TestCase {
        name: "RamSizes"
        when: windowShown
        readonly property var m: ({ ram_usage_percent: 68,
                                    ram_used_bytes: 23218000000,
                                    ram_total_bytes: 34359738368,
                                    ram_cached_bytes: 173946175488,
                                    swap_total_bytes: 274877906944,
                                    swap_used_bytes: 13636521164,
                                    ram_pressure_some_avg10: 100 })

        // 0.5x0.5 - headerless bare ring: only the one number.
        function test_micro_is_bare_ring() {
            tryVerify(function () { return hMicro.ready }, 3000)
            var w = hMicro.item
            w.sizeClass = "compact"
            hMicro.metricsJson = JSON.stringify(m)
            compare(w.micro, true, "a 344x416 compact box is the micro tile")
            compare(w.showHeader, false, "micro hides the header")
            var g = gaugeOf(w)
            compare(g.showSpark, false, "micro reserves no sparkline slot")
            compare(g.sub, "", "micro drops the used/total line - the number IS the tile")
            verify(g.bigMax > 60, "the headerless number may fill its box")
        }

        // baseline 1x1 keeps the used/total sub-line and the sparkline strip
        // (asserted throughout the cases above); wide goes side-by-side.
        function test_wide_puts_spark_beside_ring_in_both_orientations() {
            tryVerify(function () { return hWide.ready }, 3000)
            var w = hWide.item
            w.sizeClass = "wide"
            hWide.metricsJson = JSON.stringify(m)
            var g = gaugeOf(w)
            compare(g.horizontal, true, "wide lays ring and sparkline side by side")
            compare(g.showSpark, true, "the sparkline is the point of going wide")
            compare(g.detailColumns, 2,
                    "wide memory details use two readable columns")
            compare(g.detailItems.length, 2,
                    "compact details prioritise available and swap")
            verify(g.sub.length > 0, "wide keeps the used/total context inside the ring")
            compare(g.detailLabelPixelSize, hWide.theme.fontLabel,
                    "supporting labels meet the arm-length legibility floor")
            wideWrap.width = 840; wideWrap.height = 344
            compare(g.horizontal, true, "the landscape projection stays side-by-side")
            wideWrap.width = 696; wideWrap.height = 416
        }

        // tall - sparkline earns the height below a squared ring.
        function test_tall_hands_spark_the_height() {
            tryVerify(function () { return hTall.ready }, 3000)
            var w = hTall.item
            w.sizeClass = "tall"
            hTall.metricsJson = JSON.stringify(m)
            var g = gaugeOf(w)
            compare(g.sparkFills, true, "tall hands the sparkline all the height below the ring")
            compare(g.detailColumns, 1,
                    "a narrow tall memory tile stacks long values in one column")
            compare(g.detailItems.length, 2,
                    "narrow details do not crowd in cache and pressure")
            verify(g.sub.length > 0, "tall keeps the used/total context")
            compare(g.stackedRingMaxFraction, 0.52,
                    "the taller card gives context more room instead of inflating the ring")
            w.sizeClass = "full"
            compare(g.sparkFills, false, "the overlay keeps the classic expanded gauge")
            compare(w.micro, false, "full is never micro")
        }

        function test_roomy_portrait_keeps_a_large_swap_value_complete() {
            tryVerify(function () { return hRoomyTall.ready }, 3000)
            var w = hRoomyTall.item
            w.sizeClass = "tall"
            hRoomyTall.metricsJson = JSON.stringify({
                ram_metrics_available: true,
                ram_usage_percent: 29,
                ram_total_bytes: 274877906944,
                ram_used_bytes: 78490567434,
                ram_available_bytes: 189321322496,
                ram_cached_bytes: 173946175488,
                ram_buffers_bytes: 0,
                swap_total_bytes: 267683125248,
                swap_used_bytes: 11059540787,
                ram_pressure_some_avg10: 0
            })
            tryCompare(w, "detailColumnCount", 2, 2000,
                       "portrait details use readable two-column rows")
            var expected = "10.3 / 249.3 GiB"
            var swapValue = findOne(w, function (o) {
                return isText(o) && o.text === expected
            })
            verify(swapValue, "the full real-world swap value is rendered")
            compare(swapValue.truncated, false,
                    "the full swap value is not elided")
            verify(swapValue.contentWidth <= swapValue.width + 1,
                   "the full swap value fits its allocated column")
        }

        function test_narrow_alert_and_history_caption_remain_complete_at_maximum_type() {
            tryVerify(function () { return hTall.ready }, 3000)
            var w = hTall.item
            hTall.theme.textScale = 1.45
            w.sizeClass = "tall"
            hTall.metricsJson = JSON.stringify({
                ram_metrics_available: true,
                ram_usage_percent: 100,
                ram_total_bytes: 137438953472,
                ram_used_bytes: 137438953472
            })
            tryCompare(w, "status", "100% critical", 2000)
            var statusText = findOne(w, function (o) {
                return isText(o) && o.text === "100% critical"
            })
            verify(statusText, "the concise severity is rendered")
            compare(statusText.truncated, false,
                    "the narrow severity is complete at the maximum type scale")

            hTall.metricsJson = "{}"
            tryCompare(gaugeOf(w), "historyCaption", "2 MINUTES HISTORY", 2000)
            var caption = findOne(w, function (o) {
                return isText(o) && o.text === "2 MINUTES HISTORY"
            })
            verify(caption, "the narrow history caption is rendered")
            compare(caption.truncated, false,
                    "the narrow history caption is complete at the maximum type scale")
            hTall.theme.textScale = 1.15
        }

        function test_roomy_detail_panels_reflow_without_clipping() {
            tryVerify(function () { return hRoomyTall.ready && hRoomyWide.ready }, 3000)
            var saturated = {
                ram_metrics_available: true,
                ram_usage_percent: 100,
                ram_total_bytes: 137438953472,
                ram_used_bytes: 137438953472,
                ram_available_bytes: 274877906944,
                ram_cached_bytes: 173946175488,
                ram_buffers_bytes: 10737418240,
                swap_total_bytes: 274877906944,
                swap_used_bytes: 13636521164,
                ram_pressure_some_avg10: 100
            }

            var tall = hRoomyTall.item
            hRoomyTall.theme.textScale = 1.45
            tall.sizeClass = "tall"
            hRoomyTall.metricsJson = JSON.stringify(saturated)
            tryCompare(tall, "detailColumnCount", 2, 2000)
            var tallPanel = findOne(tall, function (o) {
                return o.objectName === "ramDetailPanel"
            })
            var buffersValue = findOne(tall, function (o) {
                return isText(o) && o.text === "10.0 GiB"
            })
            verify(tallPanel && buffersValue, "the complete buffers value is rendered")
            var buffersTop = buffersValue.mapToItem(tallPanel, 0, 0)
            verify(buffersTop.y >= -1
                   && buffersTop.y + buffersValue.height <= tallPanel.height + 1,
                   "the third detail row remains inside the portrait panel")
            hRoomyTall.theme.textScale = 1.15

            var wide = hRoomyWide.item
            hRoomyWide.theme.textScale = 1.3
            wide.sizeClass = "wide"
            hRoomyWide.metricsJson = JSON.stringify(saturated)
            tryCompare(wide, "detailColumnCount", 3, 2000,
                       "roomy landscape uses three columns and only two rows")
            compare(gaugeOf(wide).sub, "128.0 GiB used",
                    "the ring does not repeat the available value shown below")
            var widePanel = findOne(wide, function (o) {
                return o.objectName === "ramDetailPanel"
            })
            var wideBuffers = findOne(wide, function (o) {
                return isText(o) && o.text === "10.0 GiB"
            })
            verify(widePanel && wideBuffers, "the landscape buffers value is rendered")
            var wideTop = wideBuffers.mapToItem(widePanel, 0, 0)
            verify(wideTop.y >= -1
                   && wideTop.y + wideBuffers.height <= widePanel.height + 1,
                   "the landscape detail rows remain inside their panel")
            hRoomyWide.theme.textScale = 1.15
        }
    }

    // ── The gauge must not swallow taps meant to expand the tile ────────────
    TestCase {
        name: "RamTapPassthrough"
        when: windowShown
        function init() { tryVerify(function () { return hRam.ready }, 3000) }

        function test_gauge_has_no_tap_swallowing_mousearea() {
            // AUDIT testCase: tapping anywhere on the tile should expand it; the
            // MetricGauge must not contain a MouseArea that eats the chrome tap.
            var g = gaugeOf(hRam.item)
            var eaters = findAll(g, function (o) {
                return isMouseArea(o) && (o.acceptedButtons & Qt.LeftButton) && o.enabled
            })
            compare(eaters.length, 0, "no left-button MouseArea inside the gauge")
        }
    }
}
