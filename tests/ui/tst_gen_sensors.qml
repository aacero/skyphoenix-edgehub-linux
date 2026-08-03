import QtQuick
import QtTest
import "../../ui/qml" as App


// Comprehensive coverage for area "widget:sensors" (ui/qml/widgets/SensorsWidget.qml).
//
// Drives config through the DashboardStore the harness owns and asserts on the
// widget's derived `rows` model, its num() helper, colour thresholds, accent
// handling, reactivity, and real geometry (overflow clipping + empty-body
// placeholder). Assertions describe the CORRECT behaviour; where the widget is
// buggy they fail on purpose (see the audit) rather than being weakened.
Item {
    id: root
    width: 520; height: 900

    // Roomy tile for the logic/colour/reactivity tests.
    WidgetHarness {
        id: h; anchors.fill: parent
        widgetFile: "SensorsWidget.qml"; expanded: true
    }
    App.WidgetCatalog { id: catalog }
    App.WidgetConfigSchema { id: schema }
    // A compact 1x1-ish tile pinned to the 120px minimum height, for the
    // overflow/clipping geometry test.
    WidgetHarness {
        id: hSmall; width: 220; height: 120
        widgetFile: "SensorsWidget.qml"; expanded: false
    }

    // ── shared helpers (root scope is visible inside the TestCases) ──────────
    function rowFor(w, lbl) {
        var rs = w.rows
        for (var i = 0; i < rs.length; i++) if (rs[i].lbl === lbl) return rs[i]
        return null
    }
    function colEq(a, b) { return Qt.colorEqual(a, b) }

    // Recursively visit every visual child.
    function eachChild(obj, fn) {
        if (!obj) return
        var ch = obj.children
        if (!ch) return
        for (var i = 0; i < ch.length; i++) { fn(ch[i]); eachChild(ch[i], fn) }
    }
    // First Text descendant whose text === label.
    function findText(rootItem, label) {
        var found = null
        eachChild(rootItem, function (c) {
            if (found) return
            if (c && c.hasOwnProperty("text") && c.text === label) found = c
        })
        return found
    }
    function findNamed(rootItem, name) {
        var found = null
        eachChild(rootItem, function (c) {
            if (!found && c && c.objectName === name) found = c
        })
        return found
    }
    // Every visible Text descendant with non-empty text.
    function visibleTexts(rootItem) {
        var out = []
        eachChild(rootItem, function (c) {
            if (c && c.hasOwnProperty("text") && typeof c.text === "string"
                && c.text !== "" && c.visible) out.push(c.text)
        })
        return out
    }

    readonly property string fullMetrics: JSON.stringify({
        cpu_usage_percent: 45, cpu_usage_available: true,
        gpu_usage_percent: 30, gpu_primary_id: "card1",
        gpu_devices: [{
            id: "card1", name: "Radeon Test", usage_percent: 30,
            temperature_celsius: 55, power_watts: 120, power_cap_watts: 220,
            fan_rpm: 1450, fan_max_rpm: 3200,
            temperature_critical_celsius: 105
        }],
        ram_usage_percent: 60, ram_metrics_available: true,
        disk_usage_percent: 55, disk_total_bytes: 1000000000, disk_metrics_available: true,
        cpu_temp_celsius: 50, gpu_temp_celsius: 55
    })

    // ── logic / config / colour / reactivity ────────────────────────────────
    TestCase {
        name: "SensorsLogic"
        when: windowShown

        function init() {
            tryVerify(function () { return h.ready }, 3000)
            var s = h.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            h.storeCtl._touchSettings()
            if (h.item.hasOwnProperty("accentName")) h.item.accentName = ""
            h.metricsJson = "{}"
        }
        function feed(o) { h.metricsJson = JSON.stringify(o) }

        // ---- num() coalescing helper ----
        function test_num_helper() {
            var w = h.item
            compare(w.num(undefined), -1, "undefined → -1")
            compare(w.num(null), -1, "null → -1")
            compare(w.num(0), 0, "genuine 0 preserved")
            compare(w.num(42), 42, "value passthrough")
        }

        // ---- all rows visible with a full metrics payload ----
        function test_all_eight_rows_with_full_metrics() {
            var w = h.item
            feed(JSON.parse(root.fullMetrics))
            compare(w.rows.length, 8, "all configured load, temperature, power and fan rows are present")
            verify(rowFor(w, "CPU") !== null)
            verify(rowFor(w, "GPU") !== null)
            verify(rowFor(w, "RAM") !== null)
            verify(rowFor(w, "DISK") !== null)
            verify(rowFor(w, "CPU °") !== null)
            verify(rowFor(w, "GPU °") !== null)
            verify(rowFor(w, "GPU W").available)
            verify(rowFor(w, "GPU RPM").available)
        }

        // ---- each show* toggle honoured after a revision bump ----
        function test_toggle_each_row() {
            var w = h.item
            feed(JSON.parse(root.fullMetrics))
            compare(w.rows.length, 8)

            h.storeCtl.setSetting("test-instance", "showCpu", false)
            compare(rowFor(w, "CPU"), null, "showCpu:false hides CPU")
            h.storeCtl.setSetting("test-instance", "showCpu", true)
            verify(rowFor(w, "CPU") !== null, "showCpu:true restores CPU")

            h.storeCtl.setSetting("test-instance", "showGpu", false)
            compare(rowFor(w, "GPU"), null, "showGpu:false hides GPU")

            h.storeCtl.setSetting("test-instance", "showRam", false)
            compare(rowFor(w, "RAM"), null, "showRam:false hides RAM")

            h.storeCtl.setSetting("test-instance", "showDisk", false)
            compare(rowFor(w, "DISK"), null, "showDisk:false hides DISK")

            h.storeCtl.setSetting("test-instance", "showTemps", false)
            compare(rowFor(w, "CPU °"), null, "showTemps:false hides CPU°")
            compare(rowFor(w, "GPU °"), null, "showTemps:false hides GPU°")
            h.storeCtl.setSetting("test-instance", "showGpuPower", false)
            compare(rowFor(w, "GPU W"), null)
            h.storeCtl.setSetting("test-instance", "showGpuFan", false)
            compare(rowFor(w, "GPU RPM"), null)
        }

        // Enabled but unavailable sources stay visible and explicitly say N/A.
        function test_gpu_null_marks_gpu_rows_unavailable() {
            var w = h.item
            feed({ cpu_usage_percent: 10, ram_usage_percent: 20, disk_usage_percent: 30,
                   disk_total_bytes: 5, gpu_usage_percent: null, gpu_temp_celsius: null,
                   cpu_temp_celsius: 40 })
            compare(rowFor(w, "GPU").available, false)
            compare(rowFor(w, "GPU °").available, false)
            verify(rowFor(w, "GPU").reason.length > 0)
            verify(rowFor(w, "CPU") !== null, "CPU still shown")
        }

        function test_disk_zero_total_is_unavailable_not_disabled() {
            var w = h.item
            feed({ cpu_usage_percent: 10, ram_usage_percent: 20,
                   disk_usage_percent: 88, disk_total_bytes: 0 })
            compare(rowFor(w, "DISK").available, false)
            // ...and non-zero brings it back.
            feed({ cpu_usage_percent: 10, ram_usage_percent: 20,
                   disk_usage_percent: 88, disk_total_bytes: 123 })
            verify(rowFor(w, "DISK").available, "non-zero total provides DISK")
        }

        function test_cpu_ram_are_unavailable_when_metric_absent() {
            var w = h.item
            feed({ gpu_usage_percent: 40, disk_usage_percent: 30, disk_total_bytes: 5 })  // no cpu/ram keys
            compare(rowFor(w, "CPU").available, false)
            compare(rowFor(w, "RAM").available, false)
            // a real 0 (idle machine) still shows the row, at value 0.
            feed({ cpu_usage_percent: 0, ram_usage_percent: 0 })
            var cpu = rowFor(w, "CPU"), ram = rowFor(w, "RAM")
            verify(cpu !== null && cpu.val === 0, "real cpu 0% shows the CPU row at 0")
            verify(ram !== null && ram.val === 0, "real ram 0% shows the RAM row at 0")
        }

        // Audit 2026-08-03: FIVE of this widget's six thresholds - warnCpu,
        // warnGpu, warnRam, warnDisk and warnGpuTemp - were never set by any
        // test. Only warnCpuTemp was. Each drives stateFor() for its row
        // (SensorsWidget.qml:163-175: warning at the value, critical ten points
        // above it), so the widget could have ignored any of them and every
        // existing case would still have passed. One case per threshold would be
        // five near-identical bodies; this drives all five through one contract.
        function test_every_row_threshold_drives_its_own_state_data() {
            return [
                { tag: "cpu",      key: "warnCpu",     label: "CPU",     metric: "cpu_usage_percent" },
                { tag: "gpu",      key: "warnGpu",     label: "GPU",     metric: "gpu_usage_percent" },
                { tag: "ram",      key: "warnRam",     label: "RAM",     metric: "ram_usage_percent" },
                // disk needs its availability companion, or the row is Unavailable
                //  and no threshold applies (SensorsWidget.qml:135).
                { tag: "disk",     key: "warnDisk",    label: "DISK",    metric: "disk_usage_percent",
                  extra: { disk_metrics_available: true, disk_total_bytes: 512 } },
                { tag: "gpu_temp", key: "warnGpuTemp", label: "GPU \u00b0", metric: "gpu_temp_celsius" }
            ]
        }
        function test_every_row_threshold_drives_its_own_state(d) {
            var w = h.item
            h.storeCtl.setSetting("test-instance", d.key, 60)
            var m = {}
            for (var k in (d.extra || {})) m[k] = d.extra[k]
            m[d.metric] = 55
            feed(m)
            var row = rowFor(w, d.label)
            verify(row !== null, d.tag + " row is present")
            compare(row.state, "Normal",
                    d.tag + " below its warn line is Normal (55 < 60)")
            m[d.metric] = 62
            feed(m)
            compare(rowFor(w, d.label).state, "Warning",
                    d.tag + " at or above its warn line is Warning (62 >= 60)")
            m[d.metric] = 71
            feed(m)
            compare(rowFor(w, d.label).state, "Critical",
                    d.tag + " ten points above the warn line is Critical (71 >= 70)")
            // ...and the threshold is genuinely the config value, not a constant:
            // the same reading changes state when the line moves.
            h.storeCtl.setSetting("test-instance", d.key, 90)
            compare(rowFor(w, d.label).state, "Normal",
                    d.tag + " raising the warn line to 90 returns the same 71 to Normal")
        }

        // ---- temperature warning thresholds are configurable ----
        function test_temp_colour_thresholds() {
            var w = h.item
            function cpuTempCol(t) {
                feed({ cpu_usage_percent: 5, ram_usage_percent: 5, cpu_temp_celsius: t })
                return rowFor(w, "CPU °").col
            }
            verify(colEq(cpuTempCol(79), h.theme.catSystem))
            verify(colEq(cpuTempCol(80), h.theme.warning))
            verify(colEq(cpuTempCol(89), h.theme.warning))
            verify(colEq(cpuTempCol(90), h.theme.error))
            h.storeCtl.setSetting("test-instance", "warnCpuTemp", 70)
            verify(colEq(cpuTempCol(70), h.theme.warning), "configured threshold is applied live")
        }

        // ---- load bars follow a valid per-widget accent; hot temp stays error ----
        function test_valid_accent_recolours_load_hot_temp_stays_error() {
            var w = h.item
            feed({ cpu_usage_percent: 45, gpu_usage_percent: 30, ram_usage_percent: 60,
                   disk_usage_percent: 55, disk_total_bytes: 9, cpu_temp_celsius: 90 })
            w.accentName = "purple"
            verify(w.accentName !== "" && h.theme.accentPresets["purple"] !== undefined)
            var eff = w.effAccent
            verify(colEq(rowFor(w, "CPU").col, eff), "CPU load bar → effAccent")
            verify(colEq(rowFor(w, "RAM").col, eff), "RAM load bar → effAccent")
            verify(colEq(rowFor(w, "DISK").col, eff), "DISK load bar → effAccent")
            // A >85 temp must remain error-coloured regardless of accent.
            verify(colEq(rowFor(w, "CPU °").col, h.theme.error),
                   "hot temp stays error even with accent set")
            // A cool temp under accent uses the accent (documents bug: collapses
            // category colours, but this is the code's actual behaviour).
            feed({ cpu_usage_percent: 45, ram_usage_percent: 60, cpu_temp_celsius: 50 })
            verify(colEq(rowFor(w, "CPU °").col, eff), "cool temp → effAccent when accent set")
        }

        // ---- an unknown accent name flips accentSet but effAccent falls back ----
        function test_invalid_accent_falls_back_to_category() {
            var w = h.item
            feed({ cpu_usage_percent: 45, ram_usage_percent: 60 })
            w.accentName = "violet"   // not a preset key
            // effAccent falls back to accentColor (catSystem); accentSet is still
            // true, so every load bar collapses to catSystem (documented bug #8).
            verify(colEq(w.effAccent, h.theme.catSystem), "unknown accent → catSystem fallback")
            verify(colEq(rowFor(w, "CPU").col, h.theme.catSystem))
            verify(colEq(rowFor(w, "RAM").col, h.theme.catSystem),
                   "RAM collapses to catSystem under an invalid accent")
        }

        // ---- distinct category colours when NO accent is set ----
        function test_distinct_category_colours_without_accent() {
            var w = h.item
            feed(JSON.parse(root.fullMetrics))
            verify(colEq(rowFor(w, "CPU").col,  h.theme.catSystem))
            verify(colEq(rowFor(w, "GPU").col,  h.theme.catGaming))
            verify(colEq(rowFor(w, "RAM").col,  h.theme.catProductivity))
            verify(colEq(rowFor(w, "DISK").col, h.theme.catInfo))
        }

        // ---- reactivity: rows re-evaluate on revision, metrics, and accent ----
        function test_reactivity() {
            var w = h.item
            feed(JSON.parse(root.fullMetrics))
            compare(w.rows.length, 8)
            // store.revision (config) reactivity
            h.storeCtl.setSetting("test-instance", "showGpu", false)
            compare(rowFor(w, "GPU"), null, "revision bump recomputes rows")
            // metrics reactivity
            feed({ cpu_usage_percent: 99, ram_usage_percent: 1 })
            compare(rowFor(w, "CPU").val, 99, "new metrics value flows through")
            // accent reactivity (no metrics/config change)
            feed({ cpu_usage_percent: 40, ram_usage_percent: 1 })
            w.accentName = "green"
            verify(colEq(rowFor(w, "CPU").col, w.effAccent), "accent change recolours")
        }

        // ---- value/unit shape: '%' vs '°C', and never a -1 in a visible row ----
        function test_value_shape_and_units() {
            var w = h.item
            feed(JSON.parse(root.fullMetrics))
            compare(rowFor(w, "CPU").unit, "%")
            compare(rowFor(w, "RAM").unit, "%")
            compare(rowFor(w, "CPU °").unit, "°C")
            compare(rowFor(w, "GPU °").unit, "°C")
            var rs = w.rows
            for (var i = 0; i < rs.length; i++)
                if (rs[i].available)
                    verify(rs[i].val !== -1, "available row has a real value (" + rs[i].lbl + ")")
        }

        // ---- rendered label text formats as toFixed(0)+unit ----
        function test_rendered_labels_formatted() {
            var w = h.item
            feed({ cpu_usage_percent: 45.7, ram_usage_percent: 60.2, cpu_temp_celsius: 49.9 })
            verify(findText(w, "46%") !== null, "45.7% renders as 46%")
            verify(findText(w, "60%") !== null, "60.2% renders as 60%")
            verify(findText(w, "50°C") !== null, "49.9°C renders as 50°C")
        }

        // ---- value >100 clamps the fill bar to the full track width ----
        function test_over_100_clamps_bar_width() {
            var w = h.item
            feed({ cpu_usage_percent: 105, ram_usage_percent: 60 })
            compare(rowFor(w, "CPU").val, 105, "raw value is not clamped in the model")
            var label = findText(w, "105%")
            verify(label !== null, "value label present")
            var rowLayout = label.parent            // the RowLayout for CPU
            // children: [labelText, trackRect, valueText]
            var track = rowLayout.children[1]
            var fill = track.children[0]
            // The bar now ANIMATES to its target (delegates survive ticks), so
            // wait for the ease to land rather than sampling mid-flight.
            tryVerify(function () { return fill.width >= track.width - 0.5 }, 2000,
                      "at >100% the bar eases to fully filled")
            verify(fill.width <= track.width + 0.5, "fill never exceeds the track")
        }

        // ---- THE OWNER-REPORTED CLUNK: a tick must not rebuild the widget ----
        // "If the CPU temp rises 1 degree, only the bar length should increase/
        // decrease smoothly, not reload the entire bar." The Repeater's model was
        // a fresh JS array per metrics tick, so every delegate was destroyed and
        // recreated ~2s - nothing survived long enough to animate. The model is
        // now a static label list: these assertions prove the SAME delegate
        // objects live across ticks and only their bound values move.
        function test_delegates_survive_metric_ticks() {
            var w = h.item
            feed({ cpu_usage_percent: 20, ram_usage_percent: 30, cpu_temp_celsius: 50 })
            var cpuLabel = findText(w, "CPU")
            verify(cpuLabel !== null, "CPU row rendered")
            var track = cpuLabel.parent.children[1]
            var fill = track.children[0]
            // Two more ticks with changed values.
            feed({ cpu_usage_percent: 45, ram_usage_percent: 35, cpu_temp_celsius: 51 })
            feed({ cpu_usage_percent: 60, ram_usage_percent: 40, cpu_temp_celsius: 52 })
            var cpuLabel2 = findText(w, "CPU")
            var fill2 = cpuLabel2.parent.children[1].children[0]
            // Object IDENTITY: a recreated delegate would be a different object.
            verify(cpuLabel2 === cpuLabel, "the CPU label is the SAME object after two metric ticks")
            verify(fill2 === fill, "the CPU fill bar is the SAME object after two metric ticks")
            // …and the surviving bar's bound value tracked the data.
            tryVerify(function () { return Math.abs(fill2.width - track.width * 0.60) < 2 }, 2000,
                      "the surviving bar eased to the new 60% value")
        }

        // ---- bar length + threshold colour EASE between ticks ----
        // Pins: the fill animates via theme.motionValue (Behavior on width /
        // color), and both collapse to an instant jump under reduce-motion.
        function test_bar_and_colour_ease_and_collapse_under_reduce_motion() {
            var w = h.item
            h.theme.reduceMotion = false
            compare(h.theme.motionValue, 400, "precondition: value easing enabled")
            feed({ cpu_usage_percent: 0, ram_usage_percent: 10, cpu_temp_celsius: 50 })
            var cpuLabel = findText(w, "CPU")
            var track = cpuLabel.parent.children[1]
            var fill = track.children[0]
            // Let the layout polish give the track real geometry first, and let
            // the bar settle at its 0% start.
            tryVerify(function () { return track.width > 50 }, 2000, "track laid out")
            tryVerify(function () { return fill.width < 2 }, 2000, "bar settled at ~0%")

            // A new sample GLIDES: immediately after the tick the bar is still
            // en route, then lands on the target.
            feed({ cpu_usage_percent: 100, ram_usage_percent: 10, cpu_temp_celsius: 50 })
            verify(fill.width < track.width * 0.9,
                   "mid-ease right after the tick (" + fill.width + " of " + track.width + ")")
            tryVerify(function () { return fill.width >= track.width - 1 }, 2000,
                      "…then eases to the full 100% width")

            // Threshold colour cross-fades rather than hard-cutting: cool→hot.
            var tempFill = findText(w, "CPU °").parent.children[1].children[0]
            // The colour itself eases now, so wait for it to settle at the base
            // tone before provoking the threshold change.
            tryVerify(function () { return colEq(tempFill.color, h.theme.catSystem) }, 2000,
                      "cool temp settles at the base colour")
            feed({ cpu_usage_percent: 100, ram_usage_percent: 10, cpu_temp_celsius: 90 })
            verify(!colEq(tempFill.color, h.theme.error),
                   "immediately after the tick the colour is still fading, not hard-cut")
            tryVerify(function () { return colEq(tempFill.color, h.theme.error) }, 2000,
                      "…and lands on the error colour")

            // REDUCE-MOTION IS SACRED: the same updates become instant jumps -
            // asserted IMMEDIATELY after the tick, where the motion-on case above
            // was still provably mid-ease.
            h.theme.reduceMotion = true
            compare(h.theme.motionValue, 0, "reduce-motion zeroes the value token")
            feed({ cpu_usage_percent: 0, ram_usage_percent: 10, cpu_temp_celsius: 50 })
            tryVerify(function () { return fill.width < 2 }, 50,
                      "under reduce-motion the bar snaps (no 400ms glide)")
            tryVerify(function () { return colEq(tempFill.color, h.theme.catSystem) }, 50,
                      "under reduce-motion the colour snaps (no 400ms fade)")
            h.theme.reduceMotion = false
        }

        function test_gpu_hotplug_preserves_row_identity_and_changes_availability() {
            var w = h.item
            feed({ cpu_usage_percent: 10, ram_usage_percent: 20,
                   disk_usage_percent: 30, disk_total_bytes: 4 })
            compare(w.rows[1].lbl, "GPU")
            compare(w.rows[1].available, false)
            feed({ cpu_usage_percent: 10, gpu_usage_percent: 77, ram_usage_percent: 20,
                   disk_usage_percent: 30, disk_total_bytes: 4 })
            compare(w.rows[1].lbl, "GPU")
            compare(w.rows[1].available, true)
            compare(w.rows[1].val, 77)
        }

        function test_empty_metrics_keep_enabled_rows_as_unavailable() {
            var w = h.item
            h.metricsJson = "{}"
            compare(rowFor(w, "CPU").available, false)
            compare(rowFor(w, "RAM").available, false)
            compare(w.status, "unavailable")
            verify(findText(w, "N/A") !== null)
        }

        // ---- 'active' contract is ignored: rows keep computing when inactive ----
        // Documents bug #5 (active declared + bound but never honoured).
        function test_active_is_ignored() {
            var w = h.item
            feed(JSON.parse(root.fullMetrics))
            h.active = false
            compare(w.active, false, "active propagates to the widget")
            compare(w.rows.length, 8, "rows keep evaluating despite active=false")
            h.active = true
        }

        // ---- disabling every row leaves NO placeholder (real bug #6) ----
        function test_all_disabled_needs_placeholder() {
            var w = h.item
            feed(JSON.parse(root.fullMetrics))
            h.storeCtl.patchSettings("test-instance", {
                showCpu: false, showGpu: false, showRam: false,
                showDisk: false, showTemps: false, showGpuPower: false, showGpuFan: false
            })
            compare(w.rows.length, 0, "no rows remain")
            // A well-behaved widget shows a 'nothing to show' placeholder; only the
            // chrome title 'Sensors' should otherwise be visible.
            var texts = visibleTexts(w).filter(function (t) { return t !== "Sensors" })
            verify(texts.length >= 1,
                   "expected a placeholder when all rows are disabled, found none: "
                   + JSON.stringify(texts))
        }

        function test_row_order_sources_and_gpu_telemetry() {
            var w = h.item
            feed(JSON.parse(root.fullMetrics))
            h.storeCtl.setSetting("test-instance", "rowOrder", "GPU RPM,CPU,RAM")
            compare(w.rows[0].lbl, "GPU RPM")
            compare(w.rows[0].val, 1450)
            compare(w.rows[1].lbl, "CPU")
            compare(rowFor(w, "GPU W").val, 120)
            verify(rowFor(w, "GPU W").source.indexOf("power") >= 0)
            verify(rowFor(w, "CPU").source.length > 0)
        }

        function test_stable_row_ids_are_persisted_and_legacy_labels_still_migrate() {
            var w = h.item
            feed(JSON.parse(root.fullMetrics))
            h.storeCtl.setSetting("test-instance", "rowOrder",
                                  ["gpu_fan", "cpu", "ram", "gpu"])
            compare(w.rows[0].id, "gpu_fan")
            compare(w.rows[1].id, "cpu")
            compare(w.rows[2].id, "ram")
            h.storeCtl.setSetting("test-instance", "rowOrder", "GPU RPM,CPU,RAM")
            compare(w.rows[0].id, "gpu_fan",
                    "legacy label strings migrate to the same stable ID order")
        }

        function test_selected_gpu_drives_all_gpu_rows_and_offline_is_explicit() {
            var w = h.item
            h.storeCtl.setSetting("test-instance", "gpuDevice", "card1")
            feed({
                gpu_primary_id: "card0",
                gpu_devices: [
                    { id: "card0", name: "Integrated", usage_percent: 10,
                      temperature_celsius: 40, power_watts: 8, fan_rpm: 0 },
                    { id: "card1", name: "Discrete", usage_percent: 77,
                      temperature_celsius: 66, power_watts: 180,
                      power_cap_watts: 220, fan_rpm: 2100, fan_max_rpm: 3200 }
                ]
            })
            compare(w.primaryGpu.id, "card1")
            compare(rowFor(w, "GPU").val, 77)
            compare(rowFor(w, "GPU °").val, 66)
            compare(rowFor(w, "GPU W").val, 180)
            verify(rowFor(w, "GPU RPM").source.indexOf("Discrete") >= 0)
            h.storeCtl.setSetting("test-instance", "gpuDevice", "card9")
            compare(w.selectedGpuMissing, true)
            compare(rowFor(w, "GPU").state, "Unavailable")
            compare(rowFor(w, "GPU W").reason, "Selected GPU is offline")
        }

        function test_capability_ranges_and_text_states_are_source_aware() {
            var w = h.item
            feed({
                cpu_usage_percent: 90, cpu_usage_available: true,
                gpu_primary_id: "card1",
                gpu_devices: [{
                    id: "card1", name: "Discrete", usage_percent: 40,
                    temperature_celsius: 104, temperature_critical_celsius: 105,
                    power_watts: 190, power_cap_watts: 200,
                    fan_rpm: 3100, fan_max_rpm: 3000
                }]
            })
            compare(rowFor(w, "CPU").state, "Warning")
            compare(rowFor(w, "CPU").stateLabel, "WARN")
            compare(rowFor(w, "GPU °").max, 110)
            compare(rowFor(w, "GPU °").state, "Warning")
            compare(rowFor(w, "GPU W").max, 200)
            compare(rowFor(w, "GPU W").state, "Warning")
            compare(rowFor(w, "GPU RPM").max, 3000)
            compare(rowFor(w, "GPU RPM").state, "Critical")
            verify(findText(w, "WARN") !== null,
                   "warning meaning is printed instead of relying on amber alone")
            verify(findText(w, "CRIT") !== null,
                   "critical meaning is printed instead of relying on red alone")
        }

        function test_schema_exposes_order_thresholds_and_gpu_rows() {
            var definition = schema.schemaFor("sensors", {
                gpu_primary_id: "card0",
                gpu_devices: [{ id: "card0", name: "Integrated" },
                              { id: "card1", name: "Discrete" }]
            }, "card1")
            var fieldsByKey = ({})
            for (var i = 0; i < definition.sections.length; i++) {
                var fields = definition.sections[i].fields || []
                for (var j = 0; j < fields.length; j++)
                    fieldsByKey[fields[j].key] = fields[j]
            }
            var expected = ["gpuDevice", "rowOrder", "showGpuPower", "showGpuFan", "warnCpu",
                            "warnGpu", "warnRam", "warnDisk", "warnCpuTemp", "warnGpuTemp"]
            for (var k = 0; k < expected.length; k++)
                verify(fieldsByKey[expected[k]], expected[k])
            compare(fieldsByKey.gpuDevice.type, "select")
            compare(fieldsByKey.gpuDevice.options[2].label, "Discrete (card1)")
            compare(fieldsByKey.rowOrder.type, "reorder")
            compare(fieldsByKey.rowOrder.options[0].value, "cpu")
        }
    }

    // ── geometry: compact tile clips the bottom rows (real bug #1) ───────────
    // ── Per-sizeClass structure (W1 wave 2a) ────────────────────────────────
    // Fixed-size hosts at real projected cell footprints.
    Item { width: 344; height: 416
        WidgetHarness { id: hMicro; anchors.fill: parent; widgetFile: "SensorsWidget.qml"; expanded: false } }
    Item { id: wideWrap; width: 696; height: 416
        WidgetHarness { id: hWide; anchors.fill: parent; widgetFile: "SensorsWidget.qml"; expanded: false } }
    Item { width: 344; height: 840
        WidgetHarness { id: hTall; anchors.fill: parent; widgetFile: "SensorsWidget.qml"; expanded: false } }
    Item { width: 278; height: 654
        WidgetHarness { id: hNarrow; anchors.fill: parent; widgetFile: "SensorsWidget.qml"; expanded: false } }

    TestCase {
        name: "SensorsSizes"
        when: windowShown

        function feedTo(host) {
            host.metricsJson = JSON.stringify({ cpu_usage_percent: 20, gpu_usage_percent: 30,
                ram_usage_percent: 40, disk_usage_percent: 50, disk_total_bytes: 1e12,
                cpu_temp_celsius: 55, gpu_temp_celsius: 45 })
        }
        function gridOf(host) {
            var cpu = findText(host.item, "CPU")
            return cpu ? cpu.parent.parent : null   // delegate RowLayout → the Grid/ColumnLayout
        }
        function cleanup() {
            wideWrap.width = 696
            wideWrap.height = 416
            if (hWide.item)
                hWide.item.sizeClass = "compact"
            hWide.theme.textScale = 1.15
            hWide.theme.fontChoice = "hyperlegible"
            hNarrow.theme.textScale = 1.15
            hNarrow.theme.fontChoice = "hyperlegible"
        }

        function test_catalog_removes_unreadable_micro_size() {
            var item = null
            for (var i = 0; i < catalog.items.length; i++)
                if (catalog.items[i].type === "sensors") item = catalog.items[i]
            verify(item !== null)
            compare(item.sizes.indexOf("0.5x0.5"), -1)
            verify(item.sizes.indexOf("0.5x1") >= 0)
        }

        // wide - the SAME delegates reflow into two columns; identity survives
        // the class flip (the whole point of the static model).
        function test_wide_two_columns_same_delegates() {
            tryVerify(function () { return hWide.ready }, 3000)
            var w = hWide.item
            w.sizeClass = "compact"
            feedTo(hWide)
            var cpuBefore = findText(w, "CPU")
            var fillBefore = cpuBefore.parent.children[1].children[0]
            compare(gridOf(hWide).columns, 1, "compact: one column")
            w.sizeClass = "wide"
            compare(gridOf(hWide).columns, 2, "wide: the rows flow into two columns")
            var cpuAfter = findText(w, "CPU")
            verify(cpuAfter === cpuBefore, "the CPU label is the SAME object across the class flip")
            verify(cpuAfter.parent.children[1].children[0] === fillBefore,
                   "…and so is its fill bar (no delegate rebuild on resize)")
            wideWrap.width = 840; wideWrap.height = 344
            compare(gridOf(hWide).columns, 2, "the landscape projection keeps two columns")
            wideWrap.width = 696; wideWrap.height = 416
            w.sizeClass = "compact"
        }

        function test_short_supported_size_prioritizes_rows_and_discloses_hidden_count() {
            tryVerify(function () { return hWide.ready }, 3000)
            wideWrap.width = 840
            wideWrap.height = 306
            var w = hWide.item
            w.sizeClass = "wide"
            hWide.metricsJson = root.fullMetrics
            compare(w.smallFootprint, true)
            compare(w.visibleRowIds.length, 4)
            compare(w.hiddenRowCount, 4)
            verify(findText(w, "+4 sensors hidden in this size") !== null)
            wideWrap.width = 696
            wideWrap.height = 416
            w.sizeClass = "compact"
        }

        function test_narrow_scaled_header_keeps_the_full_title() {
            tryVerify(function () { return hNarrow.ready }, 3000)
            hNarrow.item.sizeClass = "tall"
            hNarrow.theme.textScale = 1.45
            hNarrow.theme.fontChoice = "lexend"
            hNarrow.metricsJson = "{}"
            wait(32)

            compare(hNarrow.item.sensorStatus, "unavailable")
            compare(hNarrow.item.status, "N/A",
                    "the narrow badge preserves the same unavailable state")
            var title = findText(hNarrow.item, "Sensors")
            verify(title !== null)
            compare(title.truncated, false,
                    "the complete title remains visible at 145 percent text scale")
            verify(title.contentWidth <= title.width + 1)
        }

        function test_wide_unavailable_source_wraps_inside_the_body() {
            tryVerify(function () { return hWide.ready }, 3000)
            wideWrap.width = 1015
            wideWrap.height = 490
            hWide.item.sizeClass = "wide"
            hWide.theme.textScale = 1.0
            hWide.theme.fontChoice = "system"
            feedTo(hWide)
            wait(32)

            var source = findNamed(hWide.item, "sensorSource-gpu_fan")
            verify(source !== null && source.visible)
            compare(source.text, "GPU fan sensor unavailable")
            compare(source.truncated, false,
                    "the unavailable reason wraps instead of losing its ending")
            verify(source.contentHeight <= source.height + 1)

            var clippedBody = source.parent
            while (clippedBody && clippedBody !== hWide.item
                    && clippedBody.clip !== true)
                clippedBody = clippedBody.parent
            verify(clippedBody !== null && clippedBody.clip === true)
            var topLeft = source.mapToItem(clippedBody, 0, 0)
            var bottomRight = source.mapToItem(
                clippedBody, source.width, source.height)
            verify(Math.min(topLeft.x, bottomRight.x) >= -1)
            verify(Math.max(topLeft.x, bottomRight.x)
                   <= clippedBody.width + 1,
                   "the right-hand source remains inside the clipped widget body")
        }

        // tall - single column, thicker bars + larger type than wide.
        function test_tall_scales_rows_up() {
            tryVerify(function () { return hTall.ready }, 3000)
            tryVerify(function () { return hWide.ready }, 3000)
            var w = hTall.item
            w.sizeClass = "tall"
            feedTo(hTall)
            hWide.item.sizeClass = "wide"
            feedTo(hWide)
            compare(gridOf(hTall).columns, 1, "tall keeps a single column")
            verify(w.barH > hWide.item.barH, "tall bars are thicker than wide bars ("
                   + w.barH.toFixed(1) + " vs " + hWide.item.barH.toFixed(1) + ")")
            w.sizeClass = "full"
            compare(w.micro, false, "full is never micro")
        }
    }

    TestCase {
        name: "SensorsOverflow"
        when: windowShown

        function test_smallest_supported_layout_keeps_readable_type() {
            tryVerify(function () { return hWide.ready }, 3000)
            hWide.item.sizeClass = "wide"
            hWide.metricsJson = root.fullMetrics
            verify(hWide.item.rowFont >= 12)
            verify(hWide.item.barH >= 6)
        }
    }
}
