import QtQuick
import QtTest
import "../../ui/qml" as App


// Comprehensive coverage for the Network widget (ui/qml/widgets/NetWidget.qml).
//
// Exercises: rate reading from the Rust metrics JSON, byte/bit formatting and
// unit boundaries, config reactivity (unit / showHistory), defaults, session
// peaks + history accumulation, the history cap, the (dead) `active` gate, the
// universal appearance keys (accent / title / backdrop) on the shared
// WidgetChrome, and robustness against empty/missing metrics.
//
// Assertions that encode the *intended* behaviour but fail against the current
// code are deliberate - they pin real bugs called out in the audit:
//   • fmt(1023.7) rounds up to "1024 B/s" instead of rolling into KB/s.
//   • peaks + history live on the widget instance, not the shared store, so a
//     tile and its expanded overlay do NOT share them.
//   • `active` is declared but never honoured (hidden instances keep churning).
Item {
    id: root
    width: 520; height: 420

    WidgetHarness {
        id: h
        anchors.fill: parent
        widgetFile: "NetWidget.qml"
        expanded: true
    }
    App.WidgetConfigSchema { id: schema }

    // Recurse the widget's visual tree so we can inspect the rendered Text nodes
    // (colours + formatted strings) that the widget builds internally.
    function eachItem(node, fn) {
        if (!node) return
        fn(node)
        var kids = node.children
        if (kids)
            for (var i = 0; i < kids.length; i++) eachItem(kids[i], fn)
    }
    function findText(prefix) {
        var found = null
        eachItem(h.item, function (n) {
            if (found) return
            if (n.text !== undefined && typeof n.text === "string" && n.text.indexOf(prefix) === 0)
                found = n
        })
        return found
    }
    function findIn(rootNode, pred) {
        var found = []
        eachItem(rootNode, function (n) {
            if (pred(n)) found.push(n)
        })
        return found
    }
    function findObjectIn(rootNode, name) {
        var matches = findIn(rootNode, function (n) {
            return n.objectName === name
        })
        return matches.length ? matches[0] : null
    }
    function findObject(name) {
        var found = null
        eachItem(h.item, function (n) {
            if (!found && n.objectName === name) found = n
        })
        return found
    }
    function feed(rx, tx) {
        h.metricsJson = JSON.stringify({ net_rx_bytes_per_sec: rx, net_tx_bytes_per_sec: tx })
    }
    function feedCatalog(status) {
        h.metricsJson = JSON.stringify({
            net_metrics_available: true,
            net_sample_status: status || "ready",
            net_sample_unix_ms: Date.now(),
            net_unavailable_reason: "",
            net_rx_bytes_per_sec: 999000,
            net_tx_bytes_per_sec: 888000,
            net_interfaces: [
                { name: "enp1s0", friendly_name: "Desk Ethernet",
                  category: "physical", included_by_default: true,
                  link_state: "up", speed_mbps: 2500, rate_available: status !== "warming",
                  rx_bytes_per_sec: 1000, tx_bytes_per_sec: 2000,
                  rx_total_bytes: 1000000000, tx_total_bytes: 2000000000,
                  rx_errors: 1, tx_errors: 2, rx_dropped: 3, tx_dropped: 4 },
                { name: "wg0", category: "vpn", included_by_default: false,
                  link_state: "unknown", speed_mbps: null, rate_available: status !== "warming",
                  rx_bytes_per_sec: 3000, tx_bytes_per_sec: 4000,
                  rx_total_bytes: 3000000000, tx_total_bytes: 4000000000,
                  rx_errors: 0, tx_errors: 0, rx_dropped: 0, tx_dropped: 0 }
            ]
        })
    }

    TestCase {
        name: "Net"
        when: windowShown

        function init() {
            tryVerify(function () { return h.ready }, 3000)
            // Clear per-instance settings and reset the metrics feed + in-widget
            // accumulators so each test starts from a known state.
            var s = h.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            h.storeCtl._touchSettings()
            h.metricsJson = "{}"
            h.expanded = true
            h.active = true
            var w = h.item
            w.hist = []
            w.peakRx = 0
            w.peakTx = 0
        }

        // ── Metrics reading ──────────────────────────────────────────────────
        function test_reads_rx_tx_from_metrics() {
            var w = h.item
            feed(2048, 512)
            compare(w.rx, 2048, "rx read from net_rx_bytes_per_sec")
            compare(w.tx, 512, "tx read from net_tx_bytes_per_sec")
        }

        function test_down_uses_success_up_uses_accent() {
            var w = h.item
            feed(1000, 2000)
            var down = findText("↓")
            var up = findText("↑")
            verify(down !== null && up !== null, "found the down/up readouts")
            verify(Qt.colorEqual(down.color, h.theme.success), "download line uses theme.success")
            verify(Qt.colorEqual(up.color, w.effAccent), "upload line uses effAccent")
            // The two must be distinguishable so direction is readable.
            verify(!Qt.colorEqual(h.theme.success, w.effAccent), "down/up colours differ")
        }

        function test_missing_metrics_default_to_zero() {
            var w = h.item
            h.metricsJson = "{}"                       // no net keys at all
            compare(w.rx, 0, "rx defaults to 0")
            compare(w.tx, 0, "tx defaults to 0")
            compare(w.fmt(w.rx), "0 B/s", "zero renders as 0 B/s, no crash")
            h.metricsJson = '{"cpu_load": 12}'        // present but no net keys
            compare(w.rx, 0, "still 0 with unrelated metrics")
        }

        // ── Byte formatting ──────────────────────────────────────────────────
        function test_fmt_bytes_units() {
            var w = h.item
            h.storeCtl.setSetting("test-instance", "unit", "bytes")
            compare(w.unit, "bytes")
            compare(w.fmt(1048576), "1.0 MiB/s", "binary MiB uses an honest label")
            compare(w.fmt(1024), "1 KiB/s", "binary KiB uses an honest label")
            compare(w.fmt(500), "500 B/s", "sub-KiB → B/s")
            compare(w.fmt(0), "0 B/s", "zero")
        }

        // FIXED, and this test pins it (audit). The defect was: the < 1024 test
        // happens before Math.round, so 1023.7 takes the B/s branch and rounds
        // up to "1024 B/s" instead of rolling into KB/s.
        function test_fmt_byte_boundary_does_not_show_1024() {
            var w = h.item
            h.storeCtl.setSetting("test-instance", "unit", "bytes")
            verify(w.fmt(1023.7) !== "1024 B/s",
                   "1023.7 B/s must roll up, not render '1024 B/s' (got '" + w.fmt(1023.7) + "')")
        }

        // ── Bit formatting ───────────────────────────────────────────────────
        function test_fmt_bits_units() {
            var w = h.item
            h.storeCtl.setSetting("test-instance", "unit", "bits")
            compare(w.unit, "bits")
            // 1 MB/s * 8 = 8 Mbps.
            compare(w.fmt(1000000), "8.0 Mbps", "≥1 Mbps shows Mbps")
            // 100 KB/s * 8 = 800 Kbps (< 1 Mbps → Kbps).
            compare(w.fmt(100000), "800 Kbps", "<1 Mbps steps down to Kbps")
        }

        function test_unit_switch_rerenders_readouts() {
            var w = h.item
            feed(2000000, 3000000)
            h.storeCtl.setSetting("test-instance", "unit", "bytes")
            var downBytes = findText("↓")
            verify(downBytes.text.indexOf("MiB/s") >= 0, "bytes mode shows MiB/s (got '" + downBytes.text + "')")
            h.storeCtl.setSetting("test-instance", "unit", "bits")
            var downBits = findText("↓")
            verify(downBits.text.indexOf("Mbps") >= 0, "switching to bits re-renders as Mbps (got '" + downBits.text + "')")
        }

        // ── Config defaults + reactivity ─────────────────────────────────────
        function test_defaults_when_settings_empty() {
            var w = h.item
            // init() cleared settings - nothing set.
            compare(w.showHistory, true, "showHistory defaults true")
            compare(w.historyWindow, "2m", "history defaults to two minutes")
            compare(w.unit, "bytes", "unit defaults to bytes")
            compare(w.showDetails, true)
            compare(w.scaleMode, "auto")
        }

        // Audit 2026-08-03. showDetails was the weakest of the family: only its
        // DEFAULT was asserted (test_defaults_when_settings_empty), and no test
        // ever turned it off. Three Text rows are gated on it - the link/source
        // line, the session totals and the drops/errors line - so a widget that
        // stopped honouring it entirely would have shipped green.
        function test_show_details_toggle_gates_the_detail_rows() {
            var w = h.item
            h.expanded = true
            feedCatalog("ready")
            compare(w.showDetails, true, "showDetails defaults on")
            verify(w.rateAvailable, "precondition: the rows need a live rate")
            var totals = findText("total ↓")
            var drops = findText("drops ")
            verify(totals !== null, "the session totals row is present while the toggle is on")
            verify(drops !== null, "the drops/errors row is present while the toggle is on")
            verify(totals.visible && drops.visible, "and both are visible")

            h.storeCtl.setSetting("test-instance", "showDetails", false)
            compare(w.showDetails, false, "the setting reaches the widget")
            compare(totals.visible, false,
                    "the session totals row hides when the toggle is off")
            compare(drops.visible, false,
                    "the drops/errors row hides when the toggle is off")
            h.storeCtl.setSetting("test-instance", "showDetails", true)
            verify(totals.visible && drops.visible, "and both come back")
        }

        function test_showHistory_toggle_is_reactive() {
            var w = h.item
            compare(w.showHistory, true)
            h.storeCtl.setSetting("test-instance", "showHistory", false)
            compare(w.showHistory, false, "config edit hides the graph live")
            h.storeCtl.setSetting("test-instance", "showHistory", true)
            compare(w.showHistory, true, "and shows it again live")
        }

        function test_cfg_rereads_on_revision_bump() {
            var w = h.item
            compare(w.unit, "bytes")
            // patchSettings bumps store.revision → cfg re-reads.
            h.storeCtl.patchSettings("test-instance", { unit: "bits", showHistory: false })
            compare(w.unit, "bits", "unit follows a revision bump")
            compare(w.showHistory, false, "showHistory follows a revision bump")
        }

        // ── Session peaks + history accumulation ─────────────────────────────
        function test_peaks_track_session_maximum() {
            var w = h.item
            feed(1000, 500)
            feed(5000, 200)      // new rx peak
            feed(800, 9000)      // new tx peak
            feed(100, 100)       // smaller - peaks must hold
            compare(w.peakRx, 5000, "peakRx holds the session max down-rate")
            compare(w.peakTx, 9000, "peakTx holds the session max up-rate")
        }

        function test_history_accumulates_and_caps_at_60() {
            var w = h.item
            w.hist = []
            // Feed a long contiguous ramp; only the last 60 samples must survive.
            // (The handler records the previous tick's rate, so we assert on the
            // shape of the window - contiguous, length 60 - not absolute values.)
            for (var i = 1; i <= 80; i++) feed(i, i * 2)
            compare(w.hist.length, 60, "history buffer caps at 60 samples (push/shift)")
            var n = w.hist.length
            compare(w.hist[n - 1].r - w.hist[0].r, 59,
                    "the retained window spans exactly 60 consecutive samples (oldest dropped)")
            for (var j = 1; j < n; j++)
                compare(w.hist[j].r - w.hist[j - 1].r, 1, "samples stay in FIFO order")
            compare(w.hist[n - 1].t, w.hist[n - 1].r * 2, "tx recorded alongside rx")
        }

        function test_history_window_changes_the_retained_duration_and_label() {
            var w = h.item
            h.storeCtl.setSetting("test-instance", "historyWindow", "1m")
            compare(w.historyLimit, 30)
            compare(w.historyLabel, "1 minute")
            for (var i = 1; i <= 40; i++) feed(i, i * 2)
            compare(w.hist.length, 30)
            h.storeCtl.setSetting("test-instance", "historyWindow", "5m")
            compare(w.historyLimit, 150)
            compare(w.historyLabel, "5 minutes")
        }

        // FIXED, and this test pins it (audit medium). The defect was: peaks +
        // history are plain instance properties, not stored in the shared
        // DashboardStore. A tile and its expanded overlay are SEPARATE
        // instances, so the overlay resets peaks to 0 / an empty graph on every
        // open - contradicting the store's documented shared-state design. The
        // intended behaviour: session state lives in the store so both share it.
        function test_peaks_persisted_to_shared_store() {
            var w = h.item
            feed(4000, 7000)
            var s = h.storeCtl.settingsFor("test-instance")
            verify(s.peakRx !== undefined && s.peakTx !== undefined,
                   "peaks should live in the shared store so tile+overlay share them")
        }

        function test_history_persisted_to_shared_store() {
            var w = h.item
            feed(1000, 2000)
            feed(1500, 2500)
            var s = h.storeCtl.settingsFor("test-instance")
            verify(s.hist !== undefined && s.hist.length >= 2,
                   "sparkline history should live in the shared store, not per-instance")
        }

        function test_instance_change_restores_that_instances_runtime_state() {
            var w = h.item
            h.storeCtl.ensureSettings("net-a", {})
            h.storeCtl.ensureSettings("net-b", {})
            h.storeCtl.patchSettings("net-a", {
                hist: [{ r: 10, t: 20 }], peakRx: 10, peakTx: 20
            })
            h.storeCtl.patchSettings("net-b", {
                hist: [{ r: 30, t: 40 }, { r: 50, t: 60 }],
                peakRx: 50, peakTx: 60
            })
            w.instanceId = "net-a"
            compare(w.hist.length, 1)
            compare(w.peakRx, 10)
            w.instanceId = "net-b"
            compare(w.hist.length, 2,
                    "changing host identity restores the new instance history")
            compare(w.peakRx, 50)
            compare(w.peakTx, 60)
            w.instanceId = "net-empty"
            compare(w.hist.length, 0,
                    "an instance without state does not inherit the prior graph")
            compare(w.peakRx, 0)
            compare(w.peakTx, 0)
            w.instanceId = "test-instance"
        }

        // ── The dead `active` gate ───────────────────────────────────────────
        // FIXED, and this test pins it (audit low). The defect was: `active` is
        // declared but never read; hidden/off-page instances keep pushing
        // history + updating peaks every tick. Intended: an inactive instance
        // pauses accumulation.
        function test_inactive_instance_pauses_accumulation() {
            var w = h.item
            w.hist = []
            h.active = false
            feed(1234, 5678)
            feed(2345, 6789)
            compare(w.hist.length, 0,
                    "an inactive (off-page) instance should not accumulate history")
        }

        function test_aggregate_and_selected_interface_counters_are_mutually_exclusive() {
            var w = h.item
            h.metricsJson = "{}"
            feedCatalog("ready")
            compare(w.selectedInterfaces.length, 1)
            compare(w.selectedInterfaces[0].name, "enp1s0")
            compare(w.rx, 1000, "catalog aggregate does not add the top-level aggregate again")
            compare(w.tx, 2000, "physical aggregate uses only physical catalog counters")
            h.storeCtl.setSetting("test-instance", "interfaceName", "wg0")
            compare(w.selectedInterfaces.length, 1)
            compare(w.selectedLabel, "wg0")
            compare(w.rx, 3000, "selected VPN is not added to physical aggregate")
            compare(w.tx, 4000, "selected mode uses exactly one interface")
        }

        function test_warming_and_unavailable_are_not_fake_zero_rates() {
            var w = h.item
            feedCatalog("warming")
            compare(w.rateAvailable, false)
            compare(w.freshness, "sampling")
            compare(w.hist.length, 0, "warming frame is not added to history")
            compare(findText("↓").text, "↓ Download  Sampling")

            h.metricsJson = JSON.stringify({
                net_metrics_available: false,
                net_sample_status: "unavailable",
                net_unavailable_reason: "The kernel network counters could not be read",
                net_interfaces: []
            })
            compare(w.rateAvailable, false)
            compare(w.unavailableReason, "The kernel network counters could not be read")
            compare(findText("↓").text, "↓ Download  N/A")
        }

        function test_details_show_identity_link_totals_and_precise_counters() {
            var w = h.item
            feedCatalog("ready")
            compare(w.selectedLabel, "Desk Ethernet (enp1s0)")
            verify(w.linkDetail.indexOf("up · physical · 2500 Mbps link") >= 0)
            compare(w.rxTotal, 1000000000)
            compare(w.txTotal, 2000000000)
            compare(w.dropped, 7)
            compare(w.errors, 3)
            var totalLine = findText("total ↓")
            verify(totalLine !== null)
            verify(Qt.colorEqual(totalLine.color, h.theme.textPrimary))
            verify(findText("drops 7  errors 3") !== null)
            verify(w.accessibleSummary.indexOf("Desk Ethernet (enp1s0)") >= 0)
            verify(w.accessibleSummary.indexOf("download") >= 0)
            verify(w.accessibleSummary.indexOf("upload") >= 0)
        }

        function test_fixed_scale_and_reset_session_are_touch_safe() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", {
                scaleMode: "fixed", fixedScaleMbps: 2500
            })
            compare(w.scaleMode, "fixed")
            compare(w.fixedScaleMbps, 2500)
            feedCatalog("ready")
            verify(w.hist.length > 0)
            verify(w.peakRx > 0)
            var reset = findObject("resetNetworkSession")
            verify(reset !== null && reset.visible)
            verify(reset.width >= 48 && reset.height >= 48,
                   "reset control has a touch target of at least 48 logical pixels")
            mouseClick(reset, reset.width / 2, reset.height / 2)
            compare(w.hist.length, 0)
            compare(w.peakRx, 0)
            compare(w.peakTx, 0)
            var saved = h.storeCtl.settingsFor("test-instance")
            compare(saved.hist.length, 0)
            compare(saved.peakRx, 0)
            h.metricsJson = "{}"
            feedCatalog("ready")
            verify(w.hist.length > 0)
            reset.forceActiveFocus()
            keyClick(Qt.Key_Space)
            compare(w.hist.length, 0, "keyboard fallback resets the session")
        }

        function test_schema_exposes_discovered_selection_scale_and_details() {
            var definition = schema.schemaFor("net")
            verify(definition && definition.sections)
            var sections = definition.sections
            var keys = []
            for (var i = 0; i < sections.length; i++) {
                var fields = sections[i].fields || []
                for (var j = 0; j < fields.length; j++) keys.push(fields[j].key)
            }
            var expected = ["showHistory", "historyWindow", "showDetails", "unit",
                            "scaleMode", "fixedScaleMbps", "interfaceName"]
            for (var n = 0; n < expected.length; n++)
                verify(keys.indexOf(expected[n]) >= 0,
                       "missing Network config field " + expected[n])
            var interfaceField = null
            for (var s = 0; s < sections.length; s++) {
                var sectionFields = sections[s].fields || []
                for (var f = 0; f < sectionFields.length; f++)
                    if (sectionFields[f].key === "interfaceName")
                        interfaceField = sectionFields[f]
            }
            verify(interfaceField !== null)
            compare(interfaceField.type, "select")
            compare(interfaceField.options.length, 1)
            compare(interfaceField.options[0].label, "Aggregate physical links")
        }

        function test_schema_lists_discovered_identity_and_retains_offline_selection() {
            var definition = schema.schemaFor("net", {
                net_interfaces: [
                    { name: "enp1s0", friendly_name: "Desk Ethernet",
                      category: "physical", link_state: "up", speed_mbps: 2500 },
                    { name: "wg0", friendly_name: "", category: "vpn",
                      link_state: "unknown", speed_mbps: null }
                ]
            }, "old0")
            var field = null
            for (var i = 0; i < definition.sections.length; i++) {
                var fields = definition.sections[i].fields || []
                for (var j = 0; j < fields.length; j++)
                    if (fields[j].key === "interfaceName") field = fields[j]
            }
            verify(field !== null)
            compare(field.options.length, 4)
            compare(field.options[1].label,
                    "Desk Ethernet (enp1s0) · physical · up · 2500 Mbps")
            compare(field.options[2].label, "wg0 · vpn · unknown")
            compare(field.options[3].label, "Offline interface (old0)")
        }

        function test_history_header_names_duration_scale_and_directions() {
            var w = h.item
            feed(1000000, 250000)
            feed(2000000, 500000)
            compare(w.historyLabel, "2 minutes")
            verify(w.graphScaleLabel.indexOf("Auto ceiling") === 0)
            compare(w.historyCaption, "2 MIN HISTORY",
                    "a compact chart uses the responsive duration caption")
            verify(findText(w.historyCaption) !== null)
            verify(findText("↓ Download") !== null)
            verify(w.accessibleSummary.indexOf("2 minutes history") >= 0,
                   "the complete duration meaning remains accessible")
            h.storeCtl.patchSettings("test-instance", {
                scaleMode: "fixed", fixedScaleMbps: 1000
            })
            verify(w.graphScaleLabel.indexOf("Fixed ceiling") === 0)
        }

        // ── Universal appearance keys on WidgetChrome ────────────────────────
        function test_default_accent_is_category_colour() {
            var w = h.item
            verify(Qt.colorEqual(w.effAccent, h.theme.catServices),
                   "with no accent override, effAccent is the Services category colour")
        }

        function test_universal_appearance_keys_apply() {
            var w = h.item
            // Wire the universal per-instance bindings exactly as Dashboard.injectWidget does.
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

            h.storeCtl.patchSettings("test-instance",
                { title: "Uplink", accent: "red", cardBackdrop: "mesh" })

            compare(w.titleOverride, "Uplink", "custom title flows from config")
            compare(w.cardBackdrop, "mesh", "card backdrop flows from config")
            verify(Qt.colorEqual(w.effAccent, h.theme.accentPresets["red"].a),
                   "accent preset recolours effAccent")
        }
    }

    // ── Per-sizeClass structure (W1 wave 2a) ────────────────────────────────
    // Fixed-size hosts at real projected cell footprints.
    Item { width: 344; height: 416
        WidgetHarness { id: hMicro; anchors.fill: parent; widgetFile: "NetWidget.qml"; expanded: false } }
    Item { id: wideWrap; width: 696; height: 416
        WidgetHarness { id: hWide; anchors.fill: parent; widgetFile: "NetWidget.qml"; expanded: false } }
    Item { width: 344; height: 840
        WidgetHarness { id: hTall; anchors.fill: parent; widgetFile: "NetWidget.qml"; expanded: false } }
    Item { width: 696; height: 840
        WidgetHarness { id: hBase; anchors.fill: parent; widgetFile: "NetWidget.qml"; expanded: false } }
    // 1x1.5 portrait - the same "tall" class as hTall (344x840), but with genuine
    // half-screen room. The pair exists to move the BOX while holding the class.
    Item { width: 696; height: 1229
        WidgetHarness { id: hRoomy; anchors.fill: parent; widgetFile: "NetWidget.qml"; expanded: false } }

    // The OVERLAY, at the two boxes Dashboard actually gives it. `expanded: true`
    // AND sizeClass "full" - the real pairing - because a mode-keyed literal can
    // only be caught with the mode switched ON. These are the live-preview pane
    // beside the config form (Dashboard: 38% of the width in landscape, a <=46%-
    // tall band stacked in portrait), NOT a 2560x720 screen.
    Item { width: 941; height: 456
        WidgetHarness { id: hOvlL; anchors.fill: parent; widgetFile: "NetWidget.qml"; expanded: true } }
    Item { width: 656; height: 980
        WidgetHarness { id: hOvlP; anchors.fill: parent; widgetFile: "NetWidget.qml"; expanded: true } }
    // A dedicated host for the mode-independence probe below, so a failure there
    // cannot leak `expanded: true` into another test's host.
    Item { width: 696; height: 840
        WidgetHarness { id: hProbe; anchors.fill: parent; widgetFile: "NetWidget.qml"; expanded: false } }
    // Isolated host for the eight exact systemic-legibility projections.
    Item { id: responsiveWrap; width: 348; height: 818
        WidgetHarness {
            id: hResponsive
            anchors.fill: parent
            widgetFile: "NetWidget.qml"
            expanded: false
            active: false
        }
    }

    TestCase {
        name: "NetSizes"
        when: windowShown

        function findCanvas(host) {
            var found = null
            eachItem(host.item, function (n) {
                if (!found && n.canvasSize !== undefined && n.requestPaint !== undefined)
                    found = n
            })
            return found
        }
        function feedTo(host, r, t) {
            host.metricsJson = JSON.stringify({ net_rx_bytes_per_sec: r, net_tx_bytes_per_sec: t })
        }

        function test_supported_projection_legibility_data() {
            return [
                { tag: "portrait-0.5x1-zero-system-text1.15-output1.25",
                  width: 278, height: 654, sizeClass: "tall",
                  font: "system", scale: 1.15, metrics: "zero" },
                { tag: "portrait-0.5x1-empty-lexend-text1.45-output1.25",
                  width: 278, height: 654, sizeClass: "tall",
                  font: "lexend", scale: 1.45, metrics: "empty" },
                { tag: "landscape-0.5x1-saturated-lexend-text1.3-output1.25",
                  width: 677, height: 245, sizeClass: "wide",
                  font: "lexend", scale: 1.3, metrics: "saturated" },
                { tag: "portrait-1x0.5-zero-lexend-text1.15-output1.25",
                  width: 557, height: 327, sizeClass: "wide",
                  font: "lexend", scale: 1.15, metrics: "zero" },
                { tag: "portrait-1x0.5-saturated-system-text1.3-output1",
                  width: 696, height: 409, sizeClass: "wide",
                  font: "system", scale: 1.3, metrics: "saturated" },
                { tag: "portrait-1x0.5-empty-hyperlegible-text1.45-output1.25",
                  width: 557, height: 327, sizeClass: "wide",
                  font: "hyperlegible", scale: 1.45, metrics: "empty" },
                { tag: "landscape-1x0.5-empty-lexend-text1.45-output1",
                  width: 423, height: 612, sizeClass: "tall",
                  font: "lexend", scale: 1.45, metrics: "empty" },
                { tag: "portrait-1x1-empty-system-text1.45-output1.25",
                  width: 557, height: 654, sizeClass: "compact",
                  font: "system", scale: 1.45, metrics: "empty" }
            ]
        }

        function test_supported_projection_legibility(row) {
            tryVerify(function () { return hResponsive.ready }, 3000)
            responsiveWrap.width = row.width
            responsiveWrap.height = row.height
            hResponsive.theme.textScale = row.scale
            hResponsive.theme.fontChoice = row.font
            hResponsive.item.sizeClass = row.sizeClass
            hResponsive.item.hist = []
            if (row.metrics === "saturated")
                feedTo(hResponsive, 1250000000, 1250000000)
            else if (row.metrics === "zero")
                feedTo(hResponsive, 0, 0)
            else
                hResponsive.metricsJson = "{}"
            wait(50)

            var minimum = hResponsive.theme.fontMinimum
            var rateNames = ["netDownloadRate", "netUploadRate"]
            for (var i = 0; i < rateNames.length; i++) {
                var rate = findObjectIn(hResponsive.item, rateNames[i])
                verify(rate !== null && rate.visible,
                       row.tag + " renders " + rateNames[i])
                verify(rate.font.pixelSize >= minimum,
                       row.tag + " keeps " + rateNames[i] + " at the type floor")
                verify(!rate.truncated && rate.contentWidth <= rate.width + 1,
                       row.tag + " fits " + rateNames[i])
            }

            var caption = findObjectIn(hResponsive.item, "netHistoryCaption")
            if (caption && caption.visible)
                verify(!caption.truncated && caption.contentWidth <= caption.width + 1,
                       row.tag + " fits the responsive history caption")

            var statistics = findIn(hResponsive.item, function (candidate) {
                return candidate.text !== undefined
                    && typeof candidate.text === "string"
                    && candidate.text.indexOf("avg ") >= 0
                    && candidate.text.indexOf("peak ") >= 0
                    && candidate.visible
            })
            for (var s = 0; s < statistics.length; s++) {
                verify(statistics[s].font.pixelSize >= minimum,
                       row.tag + " keeps chart statistics at the type floor")
                verify(!statistics[s].truncated
                       && statistics[s].contentWidth <= statistics[s].width + 1,
                       row.tag + " fits chart statistics '" + statistics[s].text + "'")
            }
        }

        function cleanup() {
            responsiveWrap.width = 348
            responsiveWrap.height = 818
            hResponsive.theme.textScale = 1.15
            hResponsive.theme.fontChoice = "hyperlegible"
            if (hResponsive.ready) hResponsive.item.sizeClass = "tall"
        }

        // 0.5x0.5 - headerless; the two rates, big and centred; no graph, no peaks.
        function test_micro_is_the_two_rates() {
            tryVerify(function () { return hMicro.ready }, 3000)
            var w = hMicro.item
            w.sizeClass = "compact"
            feedTo(hMicro, 2048, 1024)
            compare(w.micro, true, "a 344x416 compact box is the micro tile")
            compare(w.showHeader, false, "micro hides the header")
            compare(w.showPeaks, false, "no peaks readout at micro")
            var cv = findCanvas(hMicro)
            verify(cv !== null, "the sparkline canvas exists")
            compare(cv.visible, false, "but micro does not draw it")
            verify(w.rateFont > 19, "the two rates are the tile - they scale up")
        }

        // wide - rates + peaks beside a full-width sparkline, in both projections.
        function test_wide_puts_graph_beside_rates() {
            tryVerify(function () { return hWide.ready }, 3000)
            var w = hWide.item
            w.sizeClass = "wide"
            feedTo(hWide, 2048, 1024)
            compare(w.horiz, true, "wide goes side-by-side")
            compare(w.showPeaks, true, "wide earns the session-peaks readout")
            compare(findCanvas(hWide).visible, true, "the sparkline is drawn")
            wideWrap.width = 840; wideWrap.height = 344
            compare(w.horiz, true, "the landscape projection stays side-by-side")
            wideWrap.width = 696; wideWrap.height = 416
        }

        // tall - rates + peaks above a sparkline that takes the height.
        function test_tall_earns_peaks_and_graph_height() {
            tryVerify(function () { return hTall.ready }, 3000)
            var w = hTall.item
            w.sizeClass = "tall"
            feedTo(hTall, 2048, 1024)
            compare(w.horiz, false, "tall stacks vertically")
            compare(w.showPeaks, true, "tall earns the session-peaks readout")
            compare(findCanvas(hTall).visible, true, "the sparkline is drawn")
            // showHistory=false must drop the graph, not leave a void.
            hTall.storeCtl.setSetting("test-instance", "showHistory", false)
            compare(findCanvas(hTall).visible, false, "showHistory=false drops the graph")
            hTall.storeCtl.setSetting("test-instance", "showHistory", true)
        }

        // baseline 1x1 keeps the classic quiet tile: no peaks readout.
        function test_baseline_has_no_peaks() {
            tryVerify(function () { return hBase.ready }, 3000)
            var w = hBase.item
            w.sizeClass = "compact"
            feedTo(hBase, 2048, 1024)
            compare(w.micro, false, "a 696x840 compact box is the baseline, not micro")
            compare(w.showHeader, true, "the baseline keeps the header")
            compare(w.showPeaks, false, "the 1x1 baseline stays quiet (no peaks)")
            compare(findCanvas(hBase).visible, true, "the classic sparkline strip stays")
            // The overlay keeps its peaks readout.
            w.sizeClass = "full"
            hBase.expanded = true
            compare(w.showPeaks, true, "the overlay keeps its peaks readout")
            hBase.expanded = false
            w.sizeClass = "compact"
        }

        // ── size, not mode ──────────────────────────────────────────────────
        function findIn(host, pred) {
            var acc = []
            root.eachItem(host.item, function (n) { if (pred(n)) acc.push(n) })
            return acc
        }
        function textStarting(host, prefix) {
            return findIn(host, function (n) {
                return n.text !== undefined && typeof n.text === "string"
                       && n.text.indexOf(prefix) === 0 })[0] || null
        }
        function rateTextOf(host) { return textStarting(host, "↓ ") }
        function peakTextOf(host) { return textStarting(host, "peak ↓") }
        // The outer GridLayout: the sparkline Canvas is its direct child.
        function outerLayOf(host) {
            return findIn(host, function (o) { return o.objectName === "netOuterLayout" })[0] || null
        }

        // The overlay is a size class like any other, and its box is the one it is
        // actually given. This is the ONLY shape that catches a mode-keyed literal:
        // the sibling test below holds the mode fixed at FALSE, where a surviving
        // `w.expanded ? 30 : <derived>` never fires its literal at all and the
        // derived branch keeps the assertion green.
        //
        // Both hosts are expanded AND "full"; only the BOX differs. A literal
        // returns one number for both, so asserting the two differ IS the
        // mode/size conflation, caught.
        function test_overlay_is_sized_by_its_pane_not_by_a_mode_literal() {
            tryVerify(function () { return hOvlL.ready && hOvlP.ready }, 3000)
            var land = hOvlL.item; land.sizeClass = "full"
            var port = hOvlP.item; port.sizeClass = "full"
            feedTo(hOvlL, 2048000, 1024000); feedTo(hOvlP, 2048000, 1024000)
            // A real event-loop turn, not wait(0). These hosts default to
            // sizeClass "tall" (height > 240) and only become "full" on the lines
            // above; wait(0) returns BEFORE the layout re-polishes, so a rendered
            // read then reports PRE-change geometry - a flake that says nothing
            // about the widget. waitForRendering is not the tool either: offscreen
            // never swaps a frame, so it just burns its timeout.
            wait(16)
            compare(land.expanded, true, "precondition: this IS the overlay")
            compare(port.expanded, true, "…and so is this one")
            compare(land.roomy, true, "…and 'full' is roomy")

            verify(land.rateFont !== port.rateFont,
                   "the overlay's rate text is sized by the pane it is given, not by "
                   + "one literal for 'the overlay' (941x456 -> "
                   + land.rateFont.toFixed(1) + ", 656x980 -> "
                   + port.rateFont.toFixed(1) + ")")
            verify(land.rateFont > port.rateFont,
                   "the 941-wide pane earns the bigger number ("
                   + land.rateFont.toFixed(1) + " > " + port.rateFont.toFixed(1) + ")")

            // The RENDERED Text's own font.pixelSize, not the property that feeds
            // it: a Text that ignored rateFont and re-froze a literal would sail
            // through a property-only check.
            var lt = rateTextOf(hOvlL), pt = rateTextOf(hOvlP)
            verify(lt !== null && pt !== null, "both rate readouts resolve")
            compare(lt.font.pixelSize, Math.round(land.rateFont),
                    "the landscape pane's rate Text actually uses the derived size")
            compare(pt.font.pixelSize, Math.round(port.rateFont),
                    "…and the portrait pane's does too")
            verify(lt.font.pixelSize > pt.font.pixelSize,
                   "…and the two rendered sizes genuinely differ ("
                   + lt.font.pixelSize + " vs " + pt.font.pixelSize + ")")

            // The peaks are derived FROM the rates, so they move with the pane too
            // - `expanded ? 14` used to pin them at 14 beside a 30px rate number.
            var lp = peakTextOf(hOvlL), pp = peakTextOf(hOvlP)
            verify(lp !== null && pp !== null, "both peak readouts resolve")
            verify(lp.font.pixelSize > pp.font.pixelSize,
                   "the peaks follow the rates, so the pane moves them as well ("
                   + lp.font.pixelSize + " vs " + pp.font.pixelSize + ")")

            // The rates still FIT the pane they were sized for - the structural
            // guarantee, not glyph ink (paintedWidth is meaningless headless).
            verify(lt.width <= land.width + 0.51,
                   "the landscape rate line stays inside its pane ("
                   + lt.width.toFixed(0) + " in " + land.width + ")")
            verify(pt.width <= port.width + 0.51,
                   "…and the portrait one inside its own ("
                   + pt.width.toFixed(0) + " in " + port.width + ")")
        }

        // The mirror image: hold the MODE fixed and move the room. Both hosts are
        // expanded:false AND the same sizeClass, so only the box differs -
        // anything that changes is genuinely sized by its box.
        function test_sizing_follows_the_room_while_the_mode_is_held_fixed() {
            tryVerify(function () { return hTall.ready && hRoomy.ready }, 3000)
            var small = hTall.item;  small.sizeClass = "tall"    // 344x840
            var roomy = hRoomy.item; roomy.sizeClass = "tall"    // 696x1229
            feedTo(hTall, 2048000, 1024000); feedTo(hRoomy, 2048000, 1024000)
            wait(16)
            compare(small.expanded, false, "precondition: neither host is the overlay")
            compare(roomy.expanded, false, "…including the roomy one")
            compare(small.sizeClass, roomy.sizeClass,
                    "…and both are the SAME class: only the box differs")
            verify(roomy.roomy && !small.roomy,
                   "696x1229 has half-screen room; 344x840 does not")

            verify(roomy.rateFont > small.rateFont,
                   "the rate text follows the room (" + roomy.rateFont.toFixed(1)
                   + " on a half screen vs " + small.rateFont.toFixed(1)
                   + " on a half cell)")
            var rt = rateTextOf(hRoomy), st = rateTextOf(hTall)
            verify(rt !== null && st !== null, "both rate readouts resolve")
            verify(rt.font.pixelSize > st.font.pixelSize,
                   "…and the RENDERED Text carries it (" + rt.font.pixelSize
                   + " vs " + st.font.pixelSize + ")")

            // The spacing, read off the LIVE layout item rather than the property
            // that feeds it: a GridLayout that ignored the binding and kept a
            // literal would sail through a property-only check.
            var lr = outerLayOf(hRoomy), ls = outerLayOf(hTall)
            verify(lr !== null && ls !== null, "both outer grids resolve")
            verify(lr.rowSpacing > ls.rowSpacing,
                   "the rendered grid gives a half-screen box more air between the "
                   + "rates and the graph (" + lr.rowSpacing + " vs " + ls.rowSpacing + ")")
        }

        // `showPeaks` opened with `w.expanded ||`, which was already dead (the
        // overlay is injected as "full", which `big` covers). Dead is not the same
        // as gone: this pins that the peaks are decided by the ROOM alone. The
        // combination below is synthetic - Dashboard always injects "full" with
        // the overlay - and that is precisely the point: the mode must not be able
        // to answer this question even when it is switched on.
        function test_peaks_are_decided_by_the_room_alone_not_the_mode() {
            tryVerify(function () { return hProbe.ready }, 3000)
            var w = hProbe.item
            w.sizeClass = "compact"
            hProbe.expanded = true
            wait(16)
            compare(w.expanded, true, "precondition: the mode is ON")
            compare(w.micro, false, "precondition: 696x840 is the baseline, not micro")
            compare(w.showPeaks, false,
                    "a 696x840 baseline box has no peaks REGARDLESS of the mode - "
                    + "the `expanded ||` term is gone, not merely shadowed by `big`")
        }
    }
}
