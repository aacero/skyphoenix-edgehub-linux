import QtQuick
import QtTest
import "../../ui/qml" as App
import "../../ui/qml/widgets" as Wg


// Comprehensive coverage for the GPU widget (ui/qml/widgets/GpuWidget.qml).
//
// Exercises: availability (N/A) logic, percent reading + ring value + clamping,
// temperature header status, ring-colour escalation on both the load path and
// the thermal path, config defaults + live reactivity (showTemp / showHistory /
// warnTemp), history accumulation / cap / pause, the shared MetricGauge gauge,
// the "gpu" config schema, and the universal appearance keys (accent / title).
//
// The regression checks cover truthful capability states, multi-GPU selection,
// supported hardware details, hot-plug recovery, history, and thermal safety.
Item {
    id: root
    width: 520; height: 640

    // A theme in scope so the directly-instantiated MetricGauge resolves `theme`.
    property alias theme: _theme
    App.Theme { id: _theme }

    App.WidgetConfigSchema { id: sc }

    WidgetHarness {
        id: h
        anchors.fill: parent
        widgetFile: "GpuWidget.qml"
        expanded: true
    }

    // Directly-instantiated shared gauge for the store/gauge shared-area tests.
    Wg.MetricGauge { id: gauge; width: 200; height: 200; visible: false }
    Wg.ConfigField {
        id: gpuDeviceField
        x: root.width + 40
        width: 420
        field: ({
            key: "gpuDevice", label: "GPU device", type: "select", dflt: "auto",
            options: [
                { value: "auto", label: "Automatic: Radeon Test GPU" },
                { value: "card0", label: "Integrated Graphics (card0)" },
                { value: "card1", label: "Radeon Test GPU (card1)" }
            ]
        })
        st: h.storeCtl
        instanceId: "gpu-select-test"
        col: ({
            textPrimary: "#E6EDF3", textSecondary: "#8B949E", bg: "#0D1117",
            accent: "#58A6FF", border: "#30363D", panel: "#161B22",
            panelAlt: "#1C222B", ctlH: 58, fontBase: 17
        })
    }

    // ── Tree helpers ─────────────────────────────────────────────────────────
    function eachItem(node, fn) {
        if (!node) return
        fn(node)
        var kids = node.children
        if (kids)
            for (var i = 0; i < kids.length; i++) eachItem(kids[i], fn)
    }
    // The one MetricGauge inside the widget (unique: it carries history+ok+big).
    function findGauge() {
        var found = null
        eachItem(h.item, function (n) {
            if (found) return
            if (n.hasOwnProperty("history") && n.hasOwnProperty("ok") && n.hasOwnProperty("big"))
                found = n
        })
        return found
    }
    // Resolve an item by objectName, so an assertion can name the exact surface a
    // setting governs instead of a shape-alike (audit 2026-08-03).
    function findObjectName(rootNode, name) {
        var found = null
        eachItem(rootNode, function (n) {
            if (found) return
            if (n.objectName !== undefined && n.objectName === name) found = n
        })
        return found
    }
    function findRing(node) {
        var found = null
        eachItem(node, function (n) {
            if (found) return
            if (n.hasOwnProperty("thickness") && n.hasOwnProperty("progressColor"))
                found = n
        })
        return found
    }
    function findTextIn(rootNode, str) {
        var found = null
        eachItem(rootNode, function (n) {
            if (found) return
            if (n.text !== undefined && typeof n.text === "string" && n.text === str)
                found = n
        })
        return found
    }
    function findText(str) { return findTextIn(h.item, str) }
    // Feed the metrics JSON (omit an arg entirely to leave that key absent).
    // Derived properties (avail/v/temp/status/col) update synchronously on read.
    // The onMetricsChanged accumulator, however, lags exactly one feed: because
    // the harness wires item.metrics = Qt.binding(() => harness.metrics) (a binding
    // over a `var`), the sample for feed(X) is committed to `hist` on the FOLLOWING
    // feed. History tests therefore end with flush() to commit the last real sample.
    function feed(usage, temp) {
        var m = {}
        if (usage !== undefined) m.gpu_usage_percent = usage
        if (temp !== undefined) m.gpu_temp_celsius = temp
        h.metricsJson = JSON.stringify(m)
    }
    function feedObject(obj) { h.metricsJson = JSON.stringify(obj || {}) }
    // Commit the last real sample. An unavailable feed triggers the (lagged)
    // accumulator for the previous available tick but adds nothing of its own.
    function flush() { h.metricsJson = "{}" }
    function fieldsOf(type) {
        var s = sc.schemaFor(type); var out = {}
        for (var j = 0; j < s.sections.length; j++)
            for (var k = 0; k < (s.sections[j].fields || []).length; k++) {
                var f = s.sections[j].fields[k]
                if (f.key) out[f.key] = f
            }
        return out
    }
    function reset() {
        var s = h.storeCtl.settingsFor("test-instance")
        for (var k in s) delete s[k]
        h.storeCtl._touchSettings()
        h.metricsJson = "{}"
        h.expanded = true
        h.active = true
        h.item.hist = []
    }

    // ── Config schema (shared area) ──────────────────────────────────────────
    TestCase {
        name: "GpuSchema"
        when: windowShown

        function test_gpu_schema_display_fields() {
            var f = fieldsOf("gpu")
            verify(f.gpuDevice !== undefined, "gpu exposes device selection")
            compare(f.gpuDevice.type, "select")
            compare(f.gpuDevice.dflt, "auto")
            compare(f.gpuDevice.options.length, 1,
                    "without runtime telemetry only Automatic is offered")
            compare(f.gpuDevice.options[0].label, "Automatic")
            verify(f.showTemp !== undefined, "gpu exposes showTemp")
            compare(f.showTemp.type, "toggle")
            compare(f.showTemp.dflt, true, "showTemp defaults on")
            verify(f.showHistory !== undefined, "gpu exposes showHistory")
            compare(f.showHistory.dflt, true, "showHistory defaults on")
            verify(f.showDetails !== undefined, "gpu exposes hardware details")
            compare(f.showDetails.type, "toggle")
            compare(f.showDetails.dflt, true, "hardware details default on")
            verify(f.warnTemp !== undefined, "gpu exposes warnTemp")
            compare(f.warnTemp.type, "slider")
            compare(f.warnTemp.dflt, 90, "warnTemp default is 90")
            compare(f.warnTemp.min, 60)
            compare(f.warnTemp.max, 110, "GPU warn range goes to 110°C")
        }
        function test_gpu_schema_has_title_and_appearance() {
            var f = fieldsOf("gpu")
            verify(f.title !== undefined, "custom title field present")
            verify(f.accent !== undefined, "per-widget accent present")
            verify(f.cardBackdrop !== undefined, "per-widget backdrop present")
        }
        function test_gpu_schema_uses_discovered_identity_and_keeps_offline_selection() {
            var runtime = {
                gpu_primary_id: "card1",
                gpu_devices: [
                    { id: "card0", name: "Integrated Graphics", vendor: "AMD" },
                    { id: "card1", name: "Radeon Test GPU", vendor: "AMD" }
                ]
            }
            var definition = sc.schemaFor("gpu", runtime, "card9")
            var options = null
            for (var i = 0; i < definition.sections.length; i++) {
                var fields = definition.sections[i].fields || []
                for (var j = 0; j < fields.length; j++)
                    if (fields[j].key === "gpuDevice") options = fields[j].options
            }
            verify(options !== null)
            compare(options.length, 4)
            compare(options[0].label, "Automatic: Radeon Test GPU")
            compare(options[1].label, "Integrated Graphics (card0)")
            compare(options[2].label, "Radeon Test GPU (card1)")
            compare(options[3].label, "Offline selection (card9)")
        }
        function test_discovered_device_select_renders_and_persists_a_choice() {
            h.storeCtl.setSetting("gpu-select-test", "gpuDevice", "auto")
            var control = findChild(gpuDeviceField, "control")
            verify(control !== null, "the select renderer creates a real ComboBox")
            compare(control.count, 3)
            compare(control.displayText, "Automatic: Radeon Test GPU")
            compare(control.Accessible.name, "GPU device")
            control.popup.open()
            tryCompare(control.popup, "opened", true)
            control.currentIndex = 2
            control.activated(2)
            compare(h.storeCtl.settingsFor("gpu-select-test").gpuDevice, "card1")
            compare(control.displayText, "Radeon Test GPU (card1)")
            control.popup.close()
        }
    }

    // ── Shared MetricGauge (store/gauge shared area) ─────────────────────────
    TestCase {
        name: "GpuGaugeShared"
        when: windowShown

        function test_ring_clamps_value_to_unit_interval() {
            // Eased since W3 - assert the landed targets.
            gauge.ok = true
            gauge.value = 1.5
            var ring = findRing(gauge)
            verify(ring !== null, "found the RingProgress")
            tryCompare(ring, "value", 1, 2000, "ring clamps an over-100% value to 1.0")
            gauge.value = -0.4
            tryCompare(ring, "value", 0, 2000, "ring clamps a negative value to 0")
        }
        function test_not_ok_dims_ring_to_zero() {
            var ring = findRing(gauge)
            gauge.value = 0.8
            gauge.ok = false
            compare(ring.value, 0, "an unavailable gauge draws an empty (0) ring")
            gauge.ok = true
        }
    }

    // ── Availability / N/A ───────────────────────────────────────────────────
    TestCase {
        name: "GpuAvailability"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000); reset() }

        function test_na_when_key_absent() {
            var w = h.item
            feed()                              // no gpu keys at all
            compare(w.avail, false, "no usage key → unavailable")
            var g = findGauge()
            compare(g.ok, false, "gauge dimmed")
            compare(g.big, "N/A", "gauge reads N/A")
        }
        function test_na_when_null() {
            var w = h.item
            feed(null)
            compare(w.avail, false, "null usage → unavailable")
        }
        function test_na_when_negative() {
            var w = h.item
            feed(-1)
            compare(w.avail, false, "negative usage → unavailable")
            compare(findGauge().big, "N/A")
        }
        function test_available_shows_percent() {
            var w = h.item
            feed(42)
            compare(w.avail, true, "0..100 usage → available")
            compare(w.v, 42, "reads gpu_usage_percent")
            var g = findGauge()
            compare(g.ok, true, "gauge live")
            compare(g.big, "42%", "gauge shows the percent")
            compare(g.value, 0.42, "ring fills proportionally")
        }
        function test_zero_is_available() {
            var w = h.item
            feed(0)
            compare(w.avail, true, "0% is a valid reading, not N/A")
            compare(findGauge().big, "0%")
        }
        function test_ring_clamps_over_100() {
            var w = h.item
            feed(150)
            compare(w.avail, true)
            compare(findGauge().value, 1, "ring value clamps to 1.0 above 100%")
            compare(findGauge().big, "150%", "the number itself is not clamped")
        }
    }

    // ── Temperature header status ────────────────────────────────────────────
    TestCase {
        name: "GpuTemperatureStatus"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000); reset() }

        function test_status_shows_temp_when_enabled() {
            var w = h.item
            feed(30, 65)
            compare(w.showTemp, true, "showTemp defaults on")
            compare(w.status, "65°C", "header shows the temperature")
        }
        function test_status_hidden_when_showTemp_off() {
            var w = h.item
            h.storeCtl.setSetting("test-instance", "showTemp", false)
            feed(30, 65)
            compare(w.status, "", "showTemp off hides the header temperature")
        }
        function test_status_shows_zero_celsius() {
            var w = h.item
            feed(30, 0)
            compare(w.temp, 0, "0°C passes through as 0")
            compare(w.status, "0°C", "a real zero-degree reading is shown")
        }
        function test_status_shows_subzero_temperature() {
            var w = h.item
            feed(30, -5)
            compare(w.status, "-5°C", "a sub-zero reading is not an unavailable sentinel")
        }
        function test_status_hidden_when_temp_null() {
            var w = h.item
            feed(30, null)
            compare(w.tempAvailable, false)
            compare(w.status, "", "null temperature hidden")
        }
        function test_status_colour_thresholds() {
            var w = h.item
            h.storeCtl.setSetting("test-instance", "warnTemp", 90)
            feed(30, 95)
            compare(String(w.statusColor), String(root.theme.error), "above warnTemp → red")
            feed(30, 80)   // 80 > 90-17=73 → amber
            compare(String(w.statusColor), String(root.theme.warning), "above warnTemp-17 → amber")
            feed(30, 60)   // 60 < 73 → calm
            compare(String(w.statusColor), String(root.theme.textSecondary), "well below → calm")
        }
    }

    // ── Ring colour escalation ───────────────────────────────────────────────
    TestCase {
        name: "GpuRingColour"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000); reset() }

        // Load path (no/low temperature so the thermal branch is inert).
        function test_load_calm_below_75() {
            var w = h.item
            feed(50)                       // no temp key
            compare(String(w.col(w.v)), String(w.effAccent), "comfortable load → accent ring")
        }
        function test_load_amber_above_75() {
            var w = h.item
            feed(80)
            compare(String(w.col(w.v)), String(root.theme.warning), "load > 75% → amber ring")
        }
        function test_load_red_above_92() {
            var w = h.item
            feed(95)
            compare(String(w.col(w.v)), String(root.theme.error), "load > 92% → red ring")
        }

        // Thermal path (showTemp on) escalates the whole ring.
        function test_temp_red_above_warnTemp() {
            var w = h.item
            h.storeCtl.setSetting("test-instance", "warnTemp", 90)
            feed(20, 95)
            compare(String(w.col(w.v)), String(root.theme.error), "temp > warnTemp → red ring")
        }
        function test_temp_amber_above_warnTemp_minus_12() {
            var w = h.item
            h.storeCtl.setSetting("test-instance", "warnTemp", 90)
            feed(20, 79)                   // 79 > 90-12=78
            compare(String(w.col(w.v)), String(root.theme.warning), "temp > warnTemp-12 → amber ring")
        }
        function test_temp_calm_below_bands() {
            var w = h.item
            h.storeCtl.setSetting("test-instance", "warnTemp", 90)
            feed(20, 70)                   // 70 < 78 and load 20 < 75
            compare(String(w.col(w.v)), String(w.effAccent), "cool + light load → accent ring")
        }
        function test_gauge_colour_matches_col() {
            var w = h.item
            feed(95)
            // The gauge colour cross-fades to the threshold tone (W3) - wait for
            // it to land, then confirm it matches col(v) exactly.
            tryVerify(function () { return String(findGauge().color) === String(w.col(w.v)) },
                      2000, "gauge paints with col(v)")
        }
    }

    // ── Config defaults + reactivity ─────────────────────────────────────────
    TestCase {
        name: "GpuConfig"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000); reset() }

        function test_defaults_when_settings_empty() {
            var w = h.item
            compare(w.showTemp, true, "showTemp defaults true")
            compare(w.showHistory, true, "showHistory defaults true")
            compare(w.showDetails, true, "showDetails defaults true")
            compare(w.gpuDevice, "auto", "device selection defaults automatic")
            compare(w.warnTemp, 90, "warnTemp defaults 90")
        }
        function test_defaults_when_store_null() {
            var w = h.item
            var saved = w.store
            w.store = null
            compare(w.showTemp, true, "null store → showTemp default")
            compare(w.showHistory, true, "null store → showHistory default")
            compare(w.showDetails, true, "null store → showDetails default")
            compare(w.gpuDevice, "auto", "null store → automatic device")
            compare(w.warnTemp, 90, "null store → warnTemp default")
            w.store = saved                 // restore harness wiring
        }
        function test_showTemp_reactive() {
            var w = h.item
            feed(30, 65)
            verify(w.status.indexOf("65") >= 0, "temp shown when on")
            h.storeCtl.setSetting("test-instance", "showTemp", false)
            compare(w.status, "", "toggling showTemp off updates live")
            h.storeCtl.setSetting("test-instance", "showTemp", true)
            verify(w.status.indexOf("65") >= 0, "and back on live")
        }
        function test_warnTemp_reactive() {
            var w = h.item
            h.storeCtl.setSetting("test-instance", "warnTemp", 100)
            feed(20, 95)                    // 95 < 100 → not red
            verify(String(w.col(w.v)) !== String(root.theme.error), "below new threshold: not red")
            h.storeCtl.setSetting("test-instance", "warnTemp", 90)  // 95 > 90 → red, live
            compare(String(w.col(w.v)), String(root.theme.error), "revision bump re-reads warnTemp")
        }
        function test_showHistory_reactive() {
            var w = h.item
            compare(w.showHistory, true)
            h.storeCtl.patchSettings("test-instance", { showHistory: false })
            compare(w.showHistory, false, "patchSettings bump re-reads showHistory")
        }
        function test_device_and_details_reactive() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { gpuDevice: "card1", showDetails: false })
            compare(w.gpuDevice, "card1", "device selection updates live")
            compare(w.showDetails, false, "hardware detail visibility updates live")
        }
    }

    // ── History accumulation ─────────────────────────────────────────────────
    TestCase {
        name: "GpuHistory"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000); reset() }

        function test_history_accumulates() {
            var w = h.item
            feed(10); feed(20); feed(30); flush()
            compare(w.hist.length, 3, "one sample per available tick")
            compare(w.hist[0], 0.10, "samples stored as 0..1 fractions")
            compare(w.hist[2], 0.30)
        }
        function test_history_caps_at_48() {
            var w = h.item
            for (var i = 1; i <= 60; i++) feed(i)
            flush()
            compare(w.hist.length, 48, "history buffer caps at 48 samples")
            // 60 samples pushed; oldest 12 dropped; window is 13..60.
            compare(w.hist[0], 0.13, "oldest retained sample is the 13th push")
            compare(w.hist[w.hist.length - 1], 0.60, "newest is the last push")
        }
        function test_no_sample_when_unavailable() {
            var w = h.item
            feed(40); flush()
            compare(w.hist.length, 1, "one available tick → one sample")
            feed(null); flush()             // GPU drops out - no sample
            compare(w.hist.length, 1, "no history pushed on an unavailable tick")
            feed(); flush()                 // key absent - still nothing
            compare(w.hist.length, 1)
        }
        // showDetails had property-level coverage only - the setting was proven to
        // REACH w.showDetails, but nothing asserted the two surfaces it governs.
        // Audit 2026-08-03.
        function test_show_details_toggle_gates_both_surfaces() {
            var w = h.item
            h.expanded = true
            // Real device data: the sub-line is only meaningful when there IS a
            // hardware detail to show, which is the whole point of the toggle.
            feedObject({ gpu_usage_percent: 30, gpu_temp_celsius: 65,
                         gpu_devices: [ { id: "card0", name: "Radeon RX 7900",
                                          vendor: "AMD", driver: "amdgpu",
                                          usage_percent: 30, temp_celsius: 65,
                                          vram_used_mb: 2048, vram_total_mb: 16384 } ],
                         gpu_primary_id: "card0" })
            var gauge = findGauge()
            verify(gauge !== null, "the gauge exists")
            verify(String(gauge.sub).length > 0,
                   "the gauge sub-line carries the hardware detail while the toggle is on")
            var panel = findObjectName(w, "gpuDetailPanel")
            if (panel !== null)
                verify(panel.visible, "the detail panel shows while the toggle is on")
            h.storeCtl.setSetting("test-instance", "showDetails", false)
            compare(w.showDetails, false, "the setting reaches the widget")
            compare(String(gauge.sub), "",
                    "the gauge sub-line is emptied when the toggle is off")
            if (panel !== null)
                compare(panel.visible, false,
                        "the detail panel hides when the toggle is off")
        }

        function test_showHistory_off_still_accumulates() {
            var w = h.item
            h.storeCtl.setSetting("test-instance", "showHistory", false)
            feed(10); feed(20); flush()
            compare(w.hist.length, 2, "samples keep accumulating even when hidden")
            compare(findGauge().history.length, 0, "but the sparkline is fed an empty history")
        }

        // FIXED, and this test pins it (audit low). The defect was: `active` is
        // declared and bound by the host to pause sampling while expanded / off-
        // page, but onMetricsChanged never checks it. Intended: an inactive
        // instance stops accumulating.
        function test_inactive_instance_pauses_sampling() {
            var w = h.item
            h.active = false
            feed(33); feed(44); flush()
            compare(w.hist.length, 0,
                    "an inactive (expanded/off-page) instance should not sample history")
        }
    }

    // ── DRM device catalog, selection and capability truth ──────────────────
    TestCase {
        name: "GpuCatalog"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000); reset() }

        function catalogFrame() {
            return {
                gpu_primary_id: "card1",
                gpu_devices: [
                    { id: "card0", name: "Integrated Graphics", vendor: "AMD",
                      driver: "amdgpu", device_type: "integrated", usage_percent: 12,
                      unavailable_reason: "", temperature_celsius: 45,
                      vram_total_bytes: 2147483648, vram_used_bytes: 268435456 },
                    { id: "card1", name: "Radeon Test GPU", vendor: "AMD",
                      driver: "amdgpu", device_type: "discrete", usage_percent: 67,
                      unavailable_reason: "", temperature_celsius: 55,
                      vram_total_bytes: 17179869184, vram_used_bytes: 4294967296,
                      power_watts: 45, clock_mhz: 2400, fan_rpm: 900 }
                ]
            }
        }

        function test_auto_uses_primary_device_and_all_supported_details() {
            var w = h.item
            feedObject(catalogFrame())
            compare(w.selectedDevice.id, "card1", "automatic selection follows gpu_primary_id")
            compare(w.v, 67, "selected device drives utilization")
            compare(w.status, "55°C", "selected device drives temperature")
            compare(w.vramText, "4.0 / 16.0 GiB")
            compare(w.powerText, "45 W")
            compare(w.clockText, "2.40 GHz")
            compare(w.fanText, "900 RPM")
            verify(findText("Radeon Test GPU") !== null, "expanded panel names the device")
            verify(findText("AMD · amdgpu · discrete") !== null,
                   "expanded panel identifies vendor, driver and device class")
        }

        function test_numbered_device_selection_pins_another_gpu() {
            var w = h.item
            h.storeCtl.setSetting("test-instance", "gpuDevice", "card0")
            feedObject(catalogFrame())
            compare(w.selectedDevice.id, "card0")
            compare(w.deviceName, "Integrated Graphics")
            compare(w.v, 12, "pinned card drives the gauge instead of the automatic card")
        }

        function test_selected_device_disconnect_and_reconnect_recovers_live() {
            var w = h.item
            h.storeCtl.setSetting("test-instance", "gpuDevice", "card1")
            feedObject({ gpu_primary_id: "card0", gpu_devices: [catalogFrame().gpu_devices[0]] })
            compare(w.avail, false, "missing selected card is unavailable")
            compare(w.unavailableReason, "Selected GPU is not connected")
            compare(w.capabilityState, "disconnected")
            compare(w.alertText, "Selected GPU offline")
            verify(w.accessibleSummary.indexOf("Selected GPU offline") >= 0,
                   "disconnect is available without relying on colour")
            var button = findChild(w, "gpuUseAutomaticButton")
            verify(button !== null && button.visible, "disconnect exposes a recovery action")
            feedObject(catalogFrame())
            compare(w.avail, true, "reconnected selected card recovers without restarting")
            compare(w.v, 67)
            compare(button.visible, false, "reconnect removes the recovery action")
        }

        function test_disconnected_recovery_switches_to_automatic_selection() {
            var w = h.item
            h.storeCtl.setSetting("test-instance", "gpuDevice", "card1")
            feedObject({ gpu_primary_id: "card0", gpu_devices: [catalogFrame().gpu_devices[0]] })
            compare(w.selectedOffline, true)
            w.useAutomaticGpu()
            compare(h.storeCtl.settingsFor("test-instance").gpuDevice, "auto")
            compare(w.gpuDevice, "auto")
            compare(w.selectedDevice.id, "card0")
            compare(w.avail, true)
        }

        function test_history_resets_when_selected_device_changes() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", {
                gpuDevice: "card0", hist: [0.1, 0.2], histDevice: "card0"
            })
            w.hist = [0.1, 0.2]
            w._recordSample(catalogFrame().gpu_devices[0])
            compare(w.hist.length, 3, "same GPU extends its existing history")
            w._recordSample(catalogFrame().gpu_devices[1])
            compare(w.hist.length, 1,
                    "a different GPU begins a separate history")
            compare(h.storeCtl.settingsFor("test-instance").histDevice, "card1")
            compare(w.hist[0], 0.67, "new history starts with the new GPU sample")
        }

        function test_vendor_without_usage_explains_capability_gap() {
            var w = h.item
            feedObject({ gpu_primary_id: "card0", gpu_devices: [
                { id: "card0", name: "NVIDIA Test GPU", vendor: "NVIDIA",
                  driver: "nvidia", device_type: "discrete", usage_percent: null,
                  unavailable_reason: "The NVIDIA driver does not expose utilization through DRM sysfs",
                  vram_total_bytes: 12884901888 }
            ] })
            compare(w.avail, false)
            compare(findGauge().big, "N/A")
            compare(w.unavailableReason,
                    "The NVIDIA driver does not expose utilization through DRM sysfs")
            compare(w.capabilityState, "unsupported")
            compare(w.alertText, "Utilization unsupported")
            verify(findText(w.unavailableReason) !== null,
                   "expanded view tells the user why utilization is unavailable")
        }

        function test_catalog_temperature_preserves_zero_and_subzero_values() {
            var w = h.item
            feedObject({ gpu_primary_id: "card0", gpu_devices: [
                { id: "card0", usage_percent: 10, unavailable_reason: "",
                  temperature_celsius: 0 }
            ] })
            compare(w.status, "0°C")
            feedObject({ gpu_primary_id: "card0", gpu_devices: [
                { id: "card0", usage_percent: 10, unavailable_reason: "",
                  temperature_celsius: -2 }
            ] })
            compare(w.status, "-2°C")
        }
    }

    // ── Universal appearance keys ────────────────────────────────────────────
    TestCase {
        name: "GpuAppearance"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000); reset() }

        function test_default_accent_is_gaming_category() {
            var w = h.item
            verify(Qt.colorEqual(w.effAccent, root.theme.catGaming),
                   "with no override, effAccent is the Gaming category colour")
        }
        function test_default_header_is_gpu() {
            var w = h.item
            compare(w.titleOverride, "", "no override by default")
            verify(findText("GPU") !== null, "header renders the default GPU title")
        }
        function test_accent_recolours_effAccent_and_ring() {
            var w = h.item
            // Wire the per-instance accent exactly as Dashboard.injectWidget does.
            w.accentName = Qt.binding(function () {
                h.storeCtl.revision; var s = h.storeCtl.settingsFor("test-instance")
                return (s && s.accent) ? s.accent : ""
            })
            h.storeCtl.setSetting("test-instance", "accent", "red")
            verify(Qt.colorEqual(w.effAccent, root.theme.accentPresets["red"].a),
                   "accent preset recolours effAccent")
            feed(50)   // comfortable load → ring uses effAccent
            compare(String(w.col(w.v)), String(w.effAccent),
                    "comfortable-load ring follows the per-widget accent")
        }
        function test_title_override_honored_in_header() {
            var w = h.item
            w.titleOverride = Qt.binding(function () {
                h.storeCtl.revision; var s = h.storeCtl.settingsFor("test-instance")
                return (s && s.title) ? s.title : ""
            })
            h.storeCtl.setSetting("test-instance", "title", "RTX 4090")
            compare(w.titleOverride, "RTX 4090", "custom title flows from the 'title' key")
            verify(findText("RTX 4090") !== null, "header renders the custom title")
        }
    }

    // ── Per-sizeClass structure (W1 wave 2a) ────────────────────────────────
    // Fixed-size hosts at real projected cell footprints.
    Item { width: 344; height: 416
        WidgetHarness { id: hMicro; anchors.fill: parent; widgetFile: "GpuWidget.qml"; expanded: false } }
    Item { id: wideWrap; width: 696; height: 416
        WidgetHarness { id: hWide; anchors.fill: parent; widgetFile: "GpuWidget.qml"; expanded: false } }
    Item { id: tallWrap; width: 344; height: 840
        WidgetHarness { id: hTall; anchors.fill: parent; widgetFile: "GpuWidget.qml"; expanded: false } }

    TestCase {
        name: "GpuSizes"
        when: windowShown

        function feedTo(host, u, t) {
            host.metricsJson = JSON.stringify({ gpu_usage_percent: u, gpu_temp_celsius: t })
        }
        function gaugeIn(host) {
            var found = null
            eachItem(host.item, function (n) {
                if (!found && n.big !== undefined && n.history !== undefined && n.ok !== undefined)
                    found = n
            })
            return found
        }

        // 0.5x0.5 - headerless bare ring: the one number (or a dimmed N/A).
        function test_micro_is_bare_ring() {
            tryVerify(function () { return hMicro.ready }, 3000)
            var w = hMicro.item
            w.sizeClass = "compact"
            feedTo(hMicro, 42, 60)
            compare(w.micro, true, "a 344x416 compact box is the micro tile")
            compare(w.showHeader, false, "micro hides the header")
            var g = gaugeIn(hMicro)
            compare(g.showSpark, false, "micro reserves no sparkline slot")
            compare(g.sub, "", "micro shows only the one number")
            verify(g.bigMax > 60, "the headerless number may fill its box")
        }

        // wide - ring beside the sparkline in both projections.
        function test_wide_puts_spark_beside_ring() {
            tryVerify(function () { return hWide.ready }, 3000)
            var w = hWide.item
            w.sizeClass = "wide"
            w.hist = []
            feedTo(hWide, 30, 60); feedTo(hWide, 60, 60)
            var g = gaugeIn(hWide)
            compare(g.horizontal, true, "wide lays ring and sparkline side by side")
            compare(g.showSpark, true, "the sparkline is the point of going wide")
            wideWrap.width = 840; wideWrap.height = 344
            compare(g.horizontal, true, "the landscape projection stays side-by-side")
            wideWrap.width = 696; wideWrap.height = 416
        }

        function test_narrow_thermal_alert_fits_data() {
            return [
                { tag: "portrait-0.5x1", width: 348, height: 818 },
                { tag: "landscape-1x0.5-at-125-percent", width: 338, height: 490 }
            ]
        }

        // Regression for the two exact GPU projections caught by the systemic
        // legibility matrix. The gate still checks the rendered Text object.
        function test_narrow_thermal_alert_fits(row) {
            tryVerify(function () { return hTall.ready }, 3000)
            tallWrap.width = row.width
            tallWrap.height = row.height
            hTall.theme.textScale = 1.3
            hTall.theme.fontChoice = "lexend"

            var w = hTall.item
            w.sizeClass = "tall"
            w.hist = [0.72, 0.91, 1.0]
            feedTo(hTall, 100, 95)
            wait(50)

            compare(w.status, "95°C critical",
                    row.tag + " keeps the temperature and severity")
            verify(w.accessibleSummary.indexOf("Critical temperature") >= 0,
                   row.tag + " retains the complete accessible alert")
            var statusText = findTextIn(w, "95°C critical")
            verify(statusText !== null && statusText.visible,
                   row.tag + " renders the compact thermal status")
            verify(!statusText.truncated
                   && statusText.contentWidth <= statusText.width + 1,
                   row.tag + " thermal status is not truncated")
        }

        function cleanup() {
            tallWrap.width = 344
            tallWrap.height = 840
            hTall.theme.textScale = 1.15
            hTall.theme.fontChoice = "hyperlegible"
        }

        // tall - full-height sparkline + avg/peak caption inside the ring.
        function test_tall_earns_height_and_avg_peak() {
            tryVerify(function () { return hTall.ready }, 3000)
            var w = hTall.item
            w.sizeClass = "tall"
            feedTo(hTall, 40, 60)
            // Seed the retained history directly (accumulation itself is pinned
            // elsewhere; GPU's handler reads its lazy bindings one frame stale).
            w.hist = [0.2, 0.8]
            var g = gaugeIn(hTall)
            compare(g.sparkFills, true, "tall hands the sparkline all the height below the ring")
            compare(w.histStats, "avg 50% · peak 80%", "avg/peak derive from the retained history")
            compare(g.sub, "avg 50% · peak 80%", "and the ring captions itself with them")
            // No GPU → no invented stats: the gauge dims to N/A with no caption.
            hTall.metricsJson = "{}"
            compare(g.sub, "", "an unavailable GPU earns no avg/peak caption")
            w.sizeClass = "full"
            compare(w.micro, false, "full is never micro")
        }
    }

    // ── Deliberate bug pins (intended behaviour that current code violates) ──
    TestCase {
        name: "GpuBugs"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000); reset() }

        // FIXED, and this test pins it (audit low). The defect was: header amber
        // threshold is warnTemp-17 but the ring's is warnTemp-12 - a 5°C band
        // where the number is amber inside a calm ring.
        function test_header_and_ring_amber_thresholds_agree() {
            var w = h.item
            h.storeCtl.setSetting("test-instance", "warnTemp", 90)
            feed(20, 75)   // 75 > 73 (header amber) but 75 < 78 (ring still calm)
            compare(String(w.statusColor), String(root.theme.warning),
                    "header text is amber at 75°C")
            compare(String(w.col(w.v)), String(root.theme.warning),
                    "the ring must agree with the header's amber threshold")
        }

        // FIXED, and this test pins it (audit low). The defect was:
        // showTemp=false disables ALL thermal ring colouring, so an overheating
        // GPU renders a calm accent ring with no red anywhere.
        function test_thermal_warning_survives_showTemp_off() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { showTemp: false, warnTemp: 90 })
            feed(20, 110)  // dangerously hot, but light load
            compare(String(w.col(w.v)), String(root.theme.error),
                    "a 110°C GPU must still show a red ring even with the temp text hidden")
            compare(w.alertText, "Critical temperature")
            verify(w.status.indexOf("Critical temperature") >= 0,
                   "thermal danger is visible as text when the temperature number is hidden")
            verify(w.accessibleSummary.indexOf("Critical temperature") >= 0)
        }
    }
}
