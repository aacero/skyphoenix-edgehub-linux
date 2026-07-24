import QtQuick
import QtTest
import "../ui" as UI
import "GuiUtil.js" as G

// Visible GUI tests for the three system-metric Hub widgets: CPU, GPU, RAM.
// Each widget is hosted single via UI.WidgetHarness in a REAL KWin-composited
// window and driven with real store/metric mutations + real property drives that
// mirror exactly what Dashboard.injectWidget does (sizeClass / accentName /
// titleOverride / cardBackdrop are bindings the Dashboard sets from store - the
// harness has no Dashboard, so we set them directly, which is the same public
// API and produces the same visible pixels).
//
// Metric widgets are fed via wh.metricsJson (JSON.stringify of the metric blob).
// Keys read by the widgets (verified against source):
//   cpu: cpu_usage_percent, cpu_temp_celsius, cpu_core_count
//   gpu: gpu_usage_percent, gpu_temp_celsius
//   ram: ram_usage_percent, ram_used_bytes, ram_total_bytes
//
// Ring colour is asserted with grabImage pixels sampled across the top of the
// RingProgress arc (the sweep starts at 12 o'clock, so any non-zero value paints
// there). Availability / N/A / warn / crit / accent states are all covered.
Item {
    id: root
    width: 2560; height: 720

    UI.WidgetHarness {
        id: wh
        anchors.left: parent.left; anchors.top: parent.top
        width: 620; height: 560
        widgetFile: ""
    }

    TestCase {
        name: "GuiWSysA"
        when: windowShown
        visible: true

        // ---------- evidence ----------
        function snap(item, name) {
            var img = grabImage(item)
            img.save("gui-evidence/wsysa_" + name + ".png")
            return img
        }

        // ---------- scene-graph seams ----------
        function findRing() {
            return G.findPred(wh.item, function (n) {
                try { return n && n.progressColor !== undefined && n.thickness !== undefined
                             && n.animateValue !== undefined } catch (e) { return false }
            })
        }
        function findSpark() {
            return G.findPred(wh.item, function (n) {
                try { return n && n.values !== undefined && n.fill !== undefined
                             && n.color !== undefined } catch (e) { return false }
            })
        }
        function findBackdrop() {
            return G.findPred(wh.item, function (n) {
                try { return n && n.style !== undefined && n.accent !== undefined
                             && n.running !== undefined } catch (e) { return false }
            })
        }

        // Minimum RGB distance from `col` (a color object, .r/.g/.b in 0..1)
        // found by scanning the top of the progress arc.
        function ringDist(col) {
            var ring = findRing()
            verify(ring, "found RingProgress")
            var img = grabImage(ring)
            var w = img.width, h = img.height
            var cx = Math.floor(w / 2)
            var er = Math.round(col.r * 255), eg = Math.round(col.g * 255), eb = Math.round(col.b * 255)
            var best = 99999
            var yMax = Math.min(h - 1, Math.floor(h * 0.20) + 8)
            for (var y = 2; y <= yMax; y++) {
                for (var dx = -3; dx <= 3; dx++) {
                    var x = cx + dx
                    if (x < 0 || x >= w) continue
                    var dr = img.red(x, y) - er, dg = img.green(x, y) - eg, db = img.blue(x, y) - eb
                    var d = Math.sqrt(dr * dr + dg * dg + db * db)
                    if (d < best) best = d
                }
            }
            return best
        }
        function expectColor(kind) {
            if (kind === "error")   return wh.theme.error
            if (kind === "warning") return wh.theme.warning
            if (kind === "success") return wh.theme.success
            return wh.item.effAccent   // "accent"
        }

        // ---------- host configuration ----------
        // p: { file, w, h, sizeClass, settings, metrics, accent, title, backdrop }
        function prep(p) {
            wh.width = p.w
            wh.height = p.h
            if (wh.widgetFile !== p.file)
                wh.widgetFile = p.file
            tryVerify(function () { return wh.ready }, 5000)
            wh.item.sizeClass = p.sizeClass
            wh.item.accentName    = (p.accent   !== undefined) ? p.accent   : ""
            wh.item.titleOverride = (p.title    !== undefined) ? p.title    : ""
            wh.item.cardBackdrop  = (p.backdrop !== undefined) ? p.backdrop : "none"
            wh.item.hist = []
            var s = { showTemp: true, showHistory: true,
                      warnTemp: (p.file === "GpuWidget.qml" ? 90 : 85), unit: "percent" }
            if (p.settings) for (var k in p.settings) s[k] = p.settings[k]
            for (var kk in s) wh.storeCtl.setSetting(wh.instanceId, kk, s[kk])
            feed(p.metrics)
            if (p.history) wh.item.hist = p.history.slice()
            wait(120)
        }
        function feed(m) {
            wh.metricsJson = (m === undefined) ? "{}"
                           : (typeof m === "string" ? m : JSON.stringify(m))
        }
        function feedWait(m, ms) { feed(m); wait(ms === undefined ? 160 : ms) }

        // ===================================================================
        //  Shared size table for cpu/gpu/ram (each declared catalog size).
        // ===================================================================
        function sizeRows(file, metrics) {
            return [
                { tag: "0.5x0.5", file: file, w: 348, h: 409, sizeClass: "compact", metrics: metrics },
                { tag: "0.5x1",   file: file, w: 340, h: 620, sizeClass: "compact", metrics: metrics },
                { tag: "1x0.5",   file: file, w: 780, h: 360, sizeClass: "wide",    metrics: metrics },
                { tag: "1x1",     file: file, w: 620, h: 560, sizeClass: "compact", metrics: metrics },
                { tag: "1x1.5",   file: file, w: 460, h: 700, sizeClass: "tall",    metrics: metrics },
            ]
        }
        function checkSize(row, readout, pfx) {
            // Portrait half-screen tiles are taller than the suite's historical
            // 720px landscape window. Grow the composed window before grabbing,
            // otherwise Qt clips the bottom and a "size" screenshot silently
            // judges only the first 720px of a 1226px widget.
            root.height = Math.max(720, row.h)
            prep(row)
            wait(120)
            compare(wh.item.width, row.w, "cell width matches request")
            compare(wh.item.height, row.h, "cell height matches request")
            var img = snap(wh, pfx + "_" + row.tag)
            verify(G.looksRendered(img), "content rendered (not blank card) at " + row.tag)
            var big = G.byText(wh.item, readout)
            verify(big, "primary readout '" + readout + "' present at " + row.tag)
            verify(big.truncated === false || big.contentWidth <= big.width + 1,
                   "primary readout not clipped at " + row.tag)
        }

        // ===================================================================
        //  CPU
        // ===================================================================
        readonly property var cpuMetrics: ({
            cpu_usage_available: true, cpu_sample_status: "ready",
            cpu_usage_percent: 42, cpu_temp_celsius: 55, cpu_core_count: 8,
            cpu_frequency_mhz: 4675, cpu_load_1: 1.34, cpu_load_5: 1.12,
            cpu_load_15: 0.96, cpu_top_process_name: "rustc",
            cpu_top_process_percent: 18,
            cpu_core_usage_percent: [74, 66, 58, 52, 47, 39, 31, 22]
        })

        function test_cpu_00_sizes_data() {
            return [
                { tag: "portrait-0.5x0.5",  file: "CpuWidget.qml", w: 348,  h: 409,  sizeClass: "compact", metrics: cpuMetrics, history: [0.24, 0.31, 0.38, 0.42] },
                { tag: "landscape-0.5x0.5", file: "CpuWidget.qml", w: 423,  h: 306,  sizeClass: "compact", metrics: cpuMetrics, history: [0.24, 0.31, 0.38, 0.42] },
                { tag: "portrait-0.5x1",    file: "CpuWidget.qml", w: 348,  h: 818,  sizeClass: "tall",    metrics: cpuMetrics, history: [0.24, 0.31, 0.38, 0.42] },
                { tag: "landscape-0.5x1",   file: "CpuWidget.qml", w: 846,  h: 306,  sizeClass: "wide",    metrics: cpuMetrics, history: [0.24, 0.31, 0.38, 0.42] },
                { tag: "portrait-1x0.5",    file: "CpuWidget.qml", w: 696,  h: 409,  sizeClass: "wide",    metrics: cpuMetrics, history: [0.24, 0.31, 0.38, 0.42] },
                { tag: "landscape-1x0.5",   file: "CpuWidget.qml", w: 423,  h: 612,  sizeClass: "tall",    metrics: cpuMetrics, history: [0.24, 0.31, 0.38, 0.42] },
                { tag: "portrait-1x1",      file: "CpuWidget.qml", w: 696,  h: 818,  sizeClass: "compact", metrics: cpuMetrics, history: [0.24, 0.31, 0.38, 0.42] },
                { tag: "landscape-1x1",     file: "CpuWidget.qml", w: 846,  h: 612,  sizeClass: "compact", metrics: cpuMetrics, history: [0.24, 0.31, 0.38, 0.42] },
                { tag: "portrait-1x1.5",    file: "CpuWidget.qml", w: 696,  h: 1226, sizeClass: "tall",    metrics: cpuMetrics, history: [0.24, 0.31, 0.38, 0.42] },
                { tag: "landscape-1x1.5",   file: "CpuWidget.qml", w: 1268, h: 612,  sizeClass: "wide",    metrics: cpuMetrics, history: [0.24, 0.31, 0.38, 0.42] }
            ]
        }
        function test_cpu_00_sizes(row) {
            checkSize(row, "42%", "cpu")
            if (row.tag.indexOf("0.5x0.5") < 0)
                verify(wh.item.hist.length >= 2, "the visual gate contains real history")
            var strip = G.byObjName(wh.item, "metricDetailStrip")
            verify(strip !== null, "CPU detail strip exists")
            compare(strip.visible, row.tag.indexOf("0.5x0.5") < 0,
                    "only the true micro tile omits glanceable detail")
            var cores = G.byObjName(wh.item, "cpuCorePanel")
            verify(cores !== null, "CPU core panel exists")
            compare(cores.visible, row.tag.indexOf("1x1.5") >= 0,
                    "the half-screen tile earns per-core distribution")
        }

        function test_cpu_10_showTemp_data() {
            return [ { tag: "on", on: true }, { tag: "off", on: false } ]
        }
        function test_cpu_10_showTemp(row) {
            prep({ file: "CpuWidget.qml", w: 620, h: 560, sizeClass: "compact",
                   settings: { showTemp: row.on }, metrics: { cpu_usage_percent: 40, cpu_temp_celsius: 60 } })
            wait(150)
            snap(wh, "cpu_showTemp_" + row.tag)
            if (row.on) {
                compare(wh.item.status, "60°C", "status shows temperature when showTemp on")
                var t = G.byText(wh.item, "°C")
                verify(t && t.visible, "temperature status text visible in header")
            } else {
                compare(wh.item.status, "", "status empty when showTemp off")
            }
        }

        function test_cpu_11_showHistory_data() {
            return [ { tag: "on", on: true }, { tag: "off", on: false } ]
        }
        function test_cpu_11_showHistory(row) {
            prep({ file: "CpuWidget.qml", w: 620, h: 560, sizeClass: "compact",
                   settings: { showHistory: row.on }, metrics: { cpu_usage_percent: 30 } })
            feedWait({ cpu_usage_percent: 45 }, 180)
            feedWait({ cpu_usage_percent: 55 }, 180)
            var spark = findSpark()
            verify(spark, "sparkline item exists in tree")
            snap(wh, "cpu_showHistory_" + row.tag)
            compare(spark.parent.visible, row.on, "sparkline slot visibility follows showHistory")
            if (row.on) verify(spark.visible, "sparkline painted with >1 sample")
        }

        function test_cpu_12_warnTemp_data() {
            return [ { tag: "warn60_red",   warn: 60,  expect: "error"   },
                     { tag: "warn85_amber", warn: 85,  expect: "warning" },
                     { tag: "warn100_acc",  warn: 100, expect: "accent"  } ]
        }
        function test_cpu_12_warnTemp(row) {
            prep({ file: "CpuWidget.qml", w: 620, h: 560, sizeClass: "compact",
                   settings: { warnTemp: row.warn },
                   metrics: { cpu_usage_percent: 30, cpu_temp_celsius: 82 } })
            wait(520)
            snap(wh, "cpu_warnTemp_" + row.tag)
            var d = ringDist(expectColor(row.expect))
            verify(d < 75, "ring colour is " + row.expect + " for warnTemp " + row.warn + " (dist " + d.toFixed(0) + ")")
        }

        function test_cpu_13_title() {
            prep({ file: "CpuWidget.qml", w: 620, h: 560, sizeClass: "compact",
                   title: "Proc", metrics: cpuMetrics })
            wait(150)
            var t = G.byText(wh.item, "Proc")
            snap(wh, "cpu_title")
            verify(t && t.visible, "custom title rendered in header")
            compare(t.text, "Proc", "header title text is the override")
        }

        function test_cpu_20_state_na() {
            prep({ file: "CpuWidget.qml", w: 620, h: 560, sizeClass: "compact", metrics: {} })
            wait(150)
            var na = G.byText(wh.item, "N/A")
            snap(wh, "cpu_state_na")
            verify(na && na.visible, "centre reads N/A with no metrics")
            compare(wh.item.avail, false, "widget reports unavailable")
        }

        function test_cpu_21_state_ring() {
            prep({ file: "CpuWidget.qml", w: 620, h: 560, sizeClass: "compact",
                   metrics: { cpu_usage_percent: 42 } })
            wait(150)
            var v = G.byText(wh.item, "42%")
            snap(wh, "cpu_state_ring")
            verify(v && v.visible, "centre shows 42%")
            var ring = findRing()
            verify(ring && ring.value > 0.35 && ring.value < 0.5, "ring sweep ~0.42 (got " + ring.value.toFixed(2) + ")")
        }

        function test_cpu_22_state_warn() {
            prep({ file: "CpuWidget.qml", w: 620, h: 560, sizeClass: "compact",
                   settings: { warnTemp: 85 }, metrics: { cpu_usage_percent: 30, cpu_temp_celsius: 75 } })
            wait(520)
            snap(wh, "cpu_state_warn")
            var d = ringDist(wh.theme.warning)
            verify(d < 75, "ring amber for temp 75 warn 85 (dist " + d.toFixed(0) + ")")
        }

        function test_cpu_23_state_crit() {
            prep({ file: "CpuWidget.qml", w: 620, h: 560, sizeClass: "compact",
                   settings: { warnTemp: 85 }, metrics: { cpu_usage_percent: 30, cpu_temp_celsius: 90 } })
            wait(520)
            snap(wh, "cpu_state_crit")
            var d = ringDist(wh.theme.error)
            verify(d < 75, "ring red for temp 90 warn 85 (dist " + d.toFixed(0) + ")")
        }

        function test_cpu_24_state_sparkline() {
            prep({ file: "CpuWidget.qml", w: 620, h: 560, sizeClass: "compact",
                   metrics: { cpu_usage_percent: 20 } })
            feedWait({ cpu_usage_percent: 55 }, 200)
            feedWait({ cpu_usage_percent: 35 }, 200)
            var spark = findSpark()
            snap(wh, "cpu_state_sparkline")
            verify(spark && spark.visible, "sparkline visible after 3 samples")
            verify(spark.values.length >= 3, "history holds >=3 samples (" + spark.values.length + ")")
        }

        function test_cpu_25_state_micro() {
            prep({ file: "CpuWidget.qml", w: 348, h: 409, sizeClass: "compact",
                   metrics: { cpu_usage_percent: 42 } })
            wait(150)
            snap(wh, "cpu_state_micro")
            compare(wh.item.micro, true, "half-cell derives micro")
            compare(wh.item.showHeader, false, "micro hides header")
            var spark = findSpark()
            compare(spark.parent.visible, false, "micro reserves no sparkline slot")
            var v = G.byText(wh.item, "42%")
            verify(v && v.visible, "bare ring + number still rendered")
        }

        function test_cpu_26_state_tall_avgpeak() {
            prep({ file: "CpuWidget.qml", w: 460, h: 700, sizeClass: "tall",
                   metrics: { cpu_usage_percent: 20 } })
            feedWait({ cpu_usage_percent: 60 }, 200)
            feedWait({ cpu_usage_percent: 40 }, 200)
            var s = G.byText(wh.item, "avg")
            snap(wh, "cpu_state_tall_avgpeak")
            verify(s && s.visible, "tall tile shows an avg/peak sub-line")
            verify(("" + s.text).indexOf("peak") >= 0, "sub-line reports peak too ('" + s.text + "')")
        }

        function test_cpu_27_state_header_temp() {
            prep({ file: "CpuWidget.qml", w: 620, h: 560, sizeClass: "compact",
                   settings: { showTemp: true, warnTemp: 85 },
                   metrics: { cpu_usage_percent: 30, cpu_temp_celsius: 60 } })
            wait(200)
            snap(wh, "cpu_state_header_temp")
            compare(wh.item.status, "60°C", "header status is the temperature")
            // statusColor tracks the ring (col): comfortable temp+load -> accent.
            verify(G.colorDist("" + wh.item.statusColor, "" + wh.item.effAccent) < 40,
                   "status colour tracks the ring accent")
        }

        function test_cpu_30_chrome_accent() {
            prep({ file: "CpuWidget.qml", w: 620, h: 560, sizeClass: "compact",
                   accent: "purple", metrics: { cpu_usage_percent: 30 } })
            wait(520)
            snap(wh, "cpu_chrome_accent")
            var near = ringDist(wh.item.effAccent)
            var far  = ringDist(wh.theme.catSystem)
            verify(near < 75, "ring recolours to the accent preset (dist " + near.toFixed(0) + ")")
            verify(far > near, "ring is no longer the default catSystem blue")
        }

        function test_cpu_31_chrome_auto() {
            prep({ file: "CpuWidget.qml", w: 620, h: 560, sizeClass: "compact",
                   accent: "", metrics: { cpu_usage_percent: 30 } })
            wait(520)
            snap(wh, "cpu_chrome_auto")
            var d = ringDist(wh.theme.catSystem)
            verify(d < 75, "Auto accent falls back to catSystem (dist " + d.toFixed(0) + ")")
        }

        function test_cpu_32_backdrop_data() {
            return [ { tag: "none" }, { tag: "orbs" }, { tag: "mesh" }, { tag: "aurora" },
                     { tag: "waves" }, { tag: "stars" }, { tag: "bokeh" }, { tag: "grid" } ]
        }
        function test_cpu_32_backdrop(row) {
            prep({ file: "CpuWidget.qml", w: 620, h: 560, sizeClass: "compact",
                   backdrop: row.tag, metrics: { cpu_usage_percent: 42 } })
            wait(200)
            var bd = findBackdrop()
            verify(bd, "backdrop layer present")
            snap(wh, "cpu_backdrop_" + row.tag)
            compare(bd.visible, row.tag !== "none", "backdrop visibility for style " + row.tag)
            if (row.tag !== "none") compare("" + bd.style, row.tag, "backdrop style applied")
        }

        // ===================================================================
        //  GPU
        // ===================================================================
        readonly property var gpuMetrics: ({
            gpu_primary_id: "card1",
            gpu_devices: [ {
                id: "card1", name: "Radeon RX 7900 XTX", vendor: "AMD",
                driver: "amdgpu", device_type: "discrete", usage_percent: 42,
                temperature_celsius: 55, vram_used_bytes: 7516192768,
                vram_total_bytes: 25769803776, power_watts: 188,
                clock_mhz: 2487, fan_rpm: 1320
            } ]
        })

        function test_gpu_00_sizes_data() {
            return [
                { tag: "portrait-0.5x0.5",  file: "GpuWidget.qml", w: 348,  h: 409,  sizeClass: "compact", metrics: gpuMetrics, history: [0.28, 0.34, 0.39, 0.42] },
                { tag: "landscape-0.5x0.5", file: "GpuWidget.qml", w: 423,  h: 306,  sizeClass: "compact", metrics: gpuMetrics, history: [0.28, 0.34, 0.39, 0.42] },
                { tag: "portrait-0.5x1",    file: "GpuWidget.qml", w: 348,  h: 818,  sizeClass: "tall",    metrics: gpuMetrics, history: [0.28, 0.34, 0.39, 0.42] },
                { tag: "landscape-0.5x1",   file: "GpuWidget.qml", w: 846,  h: 306,  sizeClass: "wide",    metrics: gpuMetrics, history: [0.28, 0.34, 0.39, 0.42] },
                { tag: "portrait-1x0.5",    file: "GpuWidget.qml", w: 696,  h: 409,  sizeClass: "wide",    metrics: gpuMetrics, history: [0.28, 0.34, 0.39, 0.42] },
                { tag: "landscape-1x0.5",   file: "GpuWidget.qml", w: 423,  h: 612,  sizeClass: "tall",    metrics: gpuMetrics, history: [0.28, 0.34, 0.39, 0.42] },
                { tag: "portrait-1x1",      file: "GpuWidget.qml", w: 696,  h: 818,  sizeClass: "compact", metrics: gpuMetrics, history: [0.28, 0.34, 0.39, 0.42] },
                { tag: "landscape-1x1",     file: "GpuWidget.qml", w: 846,  h: 612,  sizeClass: "compact", metrics: gpuMetrics, history: [0.28, 0.34, 0.39, 0.42] },
                { tag: "portrait-1x1.5",    file: "GpuWidget.qml", w: 696,  h: 1226, sizeClass: "tall",    metrics: gpuMetrics, history: [0.28, 0.34, 0.39, 0.42] },
                { tag: "landscape-1x1.5",   file: "GpuWidget.qml", w: 1268, h: 612,  sizeClass: "wide",    metrics: gpuMetrics, history: [0.28, 0.34, 0.39, 0.42] }
            ]
        }
        function test_gpu_00_sizes(row) {
            checkSize(row, "42%", "gpu")
            var strip = G.byObjName(wh.item, "metricDetailStrip")
            verify(strip !== null, "GPU detail strip exists")
            compare(strip.visible, row.tag.indexOf("0.5x0.5") < 0,
                    "only the true micro tile omits GPU telemetry detail")
            var panel = G.byObjName(wh.item, "gpuDetailPanel")
            verify(panel !== null, "GPU identity panel exists")
            compare(panel.visible, row.tag.indexOf("1x1.5") >= 0,
                    "the half-screen tile earns full device identity")
        }

        function test_gpu_10_showTemp_data() {
            return [ { tag: "on", on: true }, { tag: "off", on: false } ]
        }
        function test_gpu_10_showTemp(row) {
            prep({ file: "GpuWidget.qml", w: 620, h: 560, sizeClass: "compact",
                   settings: { showTemp: row.on }, metrics: { gpu_usage_percent: 40, gpu_temp_celsius: 60 } })
            wait(150)
            snap(wh, "gpu_showTemp_" + row.tag)
            if (row.on) {
                compare(wh.item.status, "60°C", "status shows temperature when showTemp on")
                var t = G.byText(wh.item, "°C")
                verify(t && t.visible, "temperature status text visible in header")
            } else {
                compare(wh.item.status, "", "status empty when showTemp off")
            }
        }

        function test_gpu_11_showHistory_data() {
            return [ { tag: "on", on: true }, { tag: "off", on: false } ]
        }
        function test_gpu_11_showHistory(row) {
            prep({ file: "GpuWidget.qml", w: 620, h: 560, sizeClass: "compact",
                   settings: { showHistory: row.on }, metrics: { gpu_usage_percent: 30 } })
            feedWait({ gpu_usage_percent: 45 }, 180)
            feedWait({ gpu_usage_percent: 55 }, 180)
            var spark = findSpark()
            verify(spark, "sparkline item exists in tree")
            snap(wh, "gpu_showHistory_" + row.tag)
            compare(spark.parent.visible, row.on, "sparkline slot visibility follows showHistory")
            if (row.on) verify(spark.visible, "sparkline painted with >1 sample")
        }

        function test_gpu_12_warnTemp_data() {
            return [ { tag: "warn60_red",   warn: 60,  expect: "error"   },
                     { tag: "warn90_amber", warn: 90,  expect: "warning" },
                     { tag: "warn110_acc",  warn: 110, expect: "accent"  } ]
        }
        function test_gpu_12_warnTemp(row) {
            prep({ file: "GpuWidget.qml", w: 620, h: 560, sizeClass: "compact",
                   settings: { warnTemp: row.warn },
                   metrics: { gpu_usage_percent: 30, gpu_temp_celsius: 82 } })
            wait(520)
            snap(wh, "gpu_warnTemp_" + row.tag)
            var d = ringDist(expectColor(row.expect))
            verify(d < 75, "ring colour is " + row.expect + " for warnTemp " + row.warn + " (dist " + d.toFixed(0) + ")")
        }

        function test_gpu_13_title() {
            prep({ file: "GpuWidget.qml", w: 620, h: 560, sizeClass: "compact",
                   title: "Graphics", metrics: gpuMetrics })
            wait(150)
            var t = G.byText(wh.item, "Graphics")
            snap(wh, "gpu_title")
            verify(t && t.visible, "custom title rendered in header")
            compare(t.text, "Graphics", "header title text is the override")
        }

        function test_gpu_20_state_na() {
            prep({ file: "GpuWidget.qml", w: 620, h: 560, sizeClass: "compact", metrics: {} })
            wait(150)
            var na = G.byText(wh.item, "N/A")
            snap(wh, "gpu_state_na")
            verify(na && na.visible, "centre reads N/A when no GPU reading")
            compare(wh.item.avail, false, "widget reports unavailable")
        }

        function test_gpu_21_state_ring() {
            prep({ file: "GpuWidget.qml", w: 620, h: 560, sizeClass: "compact",
                   metrics: { gpu_usage_percent: 42 } })
            wait(150)
            var v = G.byText(wh.item, "42%")
            snap(wh, "gpu_state_ring")
            verify(v && v.visible, "centre shows 42%")
            var ring = findRing()
            verify(ring && ring.value > 0.35 && ring.value < 0.5, "ring sweep ~0.42 (got " + ring.value.toFixed(2) + ")")
        }

        function test_gpu_22_state_warn() {
            prep({ file: "GpuWidget.qml", w: 620, h: 560, sizeClass: "compact",
                   settings: { warnTemp: 90 }, metrics: { gpu_usage_percent: 30, gpu_temp_celsius: 80 } })
            wait(520)
            snap(wh, "gpu_state_warn")
            var d = ringDist(wh.theme.warning)
            verify(d < 75, "ring amber for temp 80 warn 90 (dist " + d.toFixed(0) + ")")
        }

        function test_gpu_23_state_crit() {
            prep({ file: "GpuWidget.qml", w: 620, h: 560, sizeClass: "compact",
                   settings: { warnTemp: 90 }, metrics: { gpu_usage_percent: 30, gpu_temp_celsius: 95 } })
            wait(520)
            snap(wh, "gpu_state_crit")
            var d = ringDist(wh.theme.error)
            verify(d < 75, "ring red for temp 95 warn 90 (dist " + d.toFixed(0) + ")")
        }

        function test_gpu_24_state_sparkline() {
            prep({ file: "GpuWidget.qml", w: 620, h: 560, sizeClass: "compact",
                   metrics: { gpu_usage_percent: 20 } })
            feedWait({ gpu_usage_percent: 55 }, 200)
            feedWait({ gpu_usage_percent: 35 }, 200)
            var spark = findSpark()
            snap(wh, "gpu_state_sparkline")
            verify(spark && spark.visible, "sparkline visible after 3 samples")
            verify(spark.values.length >= 3, "history holds >=3 samples (" + spark.values.length + ")")
        }

        function test_gpu_25_state_micro() {
            prep({ file: "GpuWidget.qml", w: 348, h: 409, sizeClass: "compact",
                   metrics: { gpu_usage_percent: 42 } })
            wait(150)
            snap(wh, "gpu_state_micro")
            compare(wh.item.micro, true, "half-cell derives micro")
            compare(wh.item.showHeader, false, "micro hides header")
            var spark = findSpark()
            compare(spark.parent.visible, false, "micro reserves no sparkline slot")
            var v = G.byText(wh.item, "42%")
            verify(v && v.visible, "bare ring + number still rendered")
        }

        function test_gpu_26_state_tall_avgpeak() {
            prep({ file: "GpuWidget.qml", w: 460, h: 700, sizeClass: "tall",
                   metrics: { gpu_usage_percent: 20 } })
            feedWait({ gpu_usage_percent: 60 }, 200)
            feedWait({ gpu_usage_percent: 40 }, 200)
            var s = G.byText(wh.item, "avg")
            snap(wh, "gpu_state_tall_avgpeak")
            verify(s && s.visible, "tall tile shows an avg/peak sub-line")
            verify(("" + s.text).indexOf("peak") >= 0, "sub-line reports peak too ('" + s.text + "')")
        }

        function test_gpu_27_state_header_status() {
            prep({ file: "GpuWidget.qml", w: 620, h: 560, sizeClass: "compact",
                   settings: { showTemp: true, warnTemp: 90 },
                   metrics: { gpu_usage_percent: 30, gpu_temp_celsius: 95 } })
            wait(200)
            snap(wh, "gpu_state_header_status")
            compare(wh.item.status, "95°C · Critical temperature",
                    "header reports the temperature and non-color critical state")
            verify(G.colorDist("" + wh.item.statusColor, "" + wh.theme.error) < 40,
                   "header status colour is error when temp exceeds warn")
        }

        function test_gpu_30_chrome_accent() {
            prep({ file: "GpuWidget.qml", w: 620, h: 560, sizeClass: "compact",
                   accent: "cyan", metrics: { gpu_usage_percent: 30 } })
            wait(520)
            snap(wh, "gpu_chrome_accent")
            var near = ringDist(wh.item.effAccent)
            var far  = ringDist(wh.theme.catGaming)
            verify(near < 75, "ring recolours to the accent preset (dist " + near.toFixed(0) + ")")
            verify(far > near, "ring is no longer the default catGaming orange")
        }

        function test_gpu_31_chrome_auto() {
            prep({ file: "GpuWidget.qml", w: 620, h: 560, sizeClass: "compact",
                   accent: "", metrics: { gpu_usage_percent: 30 } })
            wait(520)
            snap(wh, "gpu_chrome_auto")
            var d = ringDist(wh.theme.catGaming)
            verify(d < 75, "Auto accent falls back to catGaming (dist " + d.toFixed(0) + ")")
        }

        function test_gpu_32_backdrop_data() {
            return [ { tag: "none" }, { tag: "orbs" }, { tag: "mesh" }, { tag: "aurora" },
                     { tag: "waves" }, { tag: "stars" }, { tag: "bokeh" }, { tag: "grid" } ]
        }
        function test_gpu_32_backdrop(row) {
            prep({ file: "GpuWidget.qml", w: 620, h: 560, sizeClass: "compact",
                   backdrop: row.tag, metrics: { gpu_usage_percent: 42 } })
            wait(200)
            var bd = findBackdrop()
            verify(bd, "backdrop layer present")
            snap(wh, "gpu_backdrop_" + row.tag)
            compare(bd.visible, row.tag !== "none", "backdrop visibility for style " + row.tag)
            if (row.tag !== "none") compare("" + bd.style, row.tag, "backdrop style applied")
        }

        // ===================================================================
        //  RAM
        // ===================================================================
        readonly property real gib: 1073741824
        readonly property var ramMetrics: ({
            ram_metrics_available: true, ram_usage_percent: 55,
            ram_used_bytes: 8 * 1073741824,
            ram_total_bytes: 16 * 1073741824,
            ram_available_bytes: 7.2 * 1073741824,
            ram_cached_bytes: 3.4 * 1073741824,
            ram_buffers_bytes: 0.6 * 1073741824,
            swap_used_bytes: 1.1 * 1073741824,
            swap_total_bytes: 8 * 1073741824,
            ram_pressure_some_avg10: 0.72
        })

        function test_ram_00_sizes_data() {
            return [
                { tag: "portrait-0.5x0.5",  file: "RamWidget.qml", w: 348,  h: 409,  sizeClass: "compact", metrics: ramMetrics, history: [0.48, 0.51, 0.53, 0.55] },
                { tag: "landscape-0.5x0.5", file: "RamWidget.qml", w: 423,  h: 306,  sizeClass: "compact", metrics: ramMetrics, history: [0.48, 0.51, 0.53, 0.55] },
                { tag: "portrait-0.5x1",    file: "RamWidget.qml", w: 348,  h: 818,  sizeClass: "tall",    metrics: ramMetrics, history: [0.48, 0.51, 0.53, 0.55] },
                { tag: "landscape-0.5x1",   file: "RamWidget.qml", w: 846,  h: 306,  sizeClass: "wide",    metrics: ramMetrics, history: [0.48, 0.51, 0.53, 0.55] },
                { tag: "portrait-1x0.5",    file: "RamWidget.qml", w: 696,  h: 409,  sizeClass: "wide",    metrics: ramMetrics, history: [0.48, 0.51, 0.53, 0.55] },
                { tag: "landscape-1x0.5",   file: "RamWidget.qml", w: 423,  h: 612,  sizeClass: "tall",    metrics: ramMetrics, history: [0.48, 0.51, 0.53, 0.55] },
                { tag: "portrait-1x1",      file: "RamWidget.qml", w: 696,  h: 818,  sizeClass: "compact", metrics: ramMetrics, history: [0.48, 0.51, 0.53, 0.55] },
                { tag: "landscape-1x1",     file: "RamWidget.qml", w: 846,  h: 612,  sizeClass: "compact", metrics: ramMetrics, history: [0.48, 0.51, 0.53, 0.55] },
                { tag: "portrait-1x1.5",    file: "RamWidget.qml", w: 696,  h: 1226, sizeClass: "tall",    metrics: ramMetrics, history: [0.48, 0.51, 0.53, 0.55] },
                { tag: "landscape-1x1.5",   file: "RamWidget.qml", w: 1268, h: 612,  sizeClass: "wide",    metrics: ramMetrics, history: [0.48, 0.51, 0.53, 0.55] }
            ]
        }
        function test_ram_00_sizes(row) {
            checkSize(row, "55%", "ram")
            var micro = row.tag.indexOf("0.5x0.5") >= 0
            var complete = row.tag.indexOf("1x1.5") >= 0
            var glance = !micro && !complete
                         && (row.sizeClass === "wide" || row.sizeClass === "tall")
            var strip = G.byObjName(wh.item, "metricDetailStrip")
            verify(strip !== null, "RAM detail strip exists")
            compare(strip.visible, glance,
                    "only wide and tall intermediate sizes use the glance strip")
            var panel = G.byObjName(wh.item, "ramDetailPanel")
            verify(panel !== null, "RAM roomy detail panel exists")
            compare(panel.visible, complete,
                    "the largest declared tile earns the complete memory breakdown")
        }

        function test_ram_10_unit_data() {
            return [ { tag: "percent", unit: "percent", readout: "55%" },
                     { tag: "gb",      unit: "gb",      readout: "8.0 GiB" } ]
        }
        function test_ram_10_unit(row) {
            prep({ file: "RamWidget.qml", w: 620, h: 560, sizeClass: "compact",
                   settings: { unit: row.unit }, metrics: ramMetrics })
            wait(150)
            snap(wh, "ram_unit_" + row.tag)
            var v = G.byText(wh.item, row.readout)
            verify(v && v.visible, "centre reading '" + row.readout + "' for unit " + row.unit)
            if (row.unit === "gb") {
                var pct = G.byText(wh.item, "55%")
                verify(pct && pct.visible, "gb mode shows percent on the sub-line")
            }
        }

        function test_ram_11_showHistory_data() {
            return [ { tag: "on", on: true }, { tag: "off", on: false } ]
        }
        function test_ram_11_showHistory(row) {
            prep({ file: "RamWidget.qml", w: 620, h: 560, sizeClass: "compact",
                   settings: { showHistory: row.on }, metrics: { ram_usage_percent: 30 } })
            feedWait({ ram_usage_percent: 45 }, 180)
            feedWait({ ram_usage_percent: 55 }, 180)
            var spark = findSpark()
            verify(spark, "sparkline item exists in tree")
            snap(wh, "ram_showHistory_" + row.tag)
            compare(spark.parent.visible, row.on, "sparkline slot visibility follows showHistory")
            if (row.on) verify(spark.visible, "sparkline painted with >1 sample")
        }

        function test_ram_12_title() {
            prep({ file: "RamWidget.qml", w: 620, h: 560, sizeClass: "compact",
                   title: "Mem", metrics: ramMetrics })
            wait(150)
            var t = G.byText(wh.item, "Mem")
            snap(wh, "ram_title")
            verify(t && t.visible, "custom title rendered in header")
            compare(t.text, "Mem", "header title text is the override")
        }

        function test_ram_20_state_na() {
            prep({ file: "RamWidget.qml", w: 620, h: 560, sizeClass: "compact", metrics: {} })
            wait(150)
            var na = G.byText(wh.item, "N/A")
            snap(wh, "ram_state_na")
            verify(na && na.visible, "centre reads N/A with no metrics")
            compare(wh.item.avail, false, "widget reports unavailable")
        }

        function test_ram_21_state_percent() {
            prep({ file: "RamWidget.qml", w: 620, h: 560, sizeClass: "compact",
                   settings: { unit: "percent" }, metrics: ramMetrics })
            wait(150)
            var v = G.byText(wh.item, "55%")
            snap(wh, "ram_state_percent")
            verify(v && v.visible, "percent mode centre shows 55%")
            var ring = findRing()
            verify(ring && ring.value > 0.5 && ring.value < 0.6, "ring sweep ~0.55 (got " + ring.value.toFixed(2) + ")")
        }

        function test_ram_22_state_gb() {
            prep({ file: "RamWidget.qml", w: 620, h: 560, sizeClass: "compact",
                   settings: { unit: "gb" }, metrics: ramMetrics })
            wait(150)
            var v = G.byText(wh.item, "8.0 GiB")
            snap(wh, "ram_state_gb")
            verify(v && v.visible, "gb mode centre shows used GiB (8.0 GiB)")
        }

        function test_ram_23_state_usedtotal() {
            prep({ file: "RamWidget.qml", w: 620, h: 560, sizeClass: "compact",
                   settings: { unit: "percent" }, metrics: ramMetrics })
            wait(150)
            var sub = G.byText(wh.item, "used 8.0 · available 7.2 GiB")
            snap(wh, "ram_state_usedtotal")
            verify(sub && sub.visible, "sub-line distinguishes used and available GiB")
        }

        function test_ram_24_state_micro() {
            prep({ file: "RamWidget.qml", w: 348, h: 409, sizeClass: "compact",
                   metrics: ramMetrics })
            wait(150)
            snap(wh, "ram_state_micro")
            compare(wh.item.micro, true, "half-cell derives micro")
            compare(wh.item.showHeader, false, "micro hides header")
            // micro drops the sub-line entirely.
            var sub = G.byText(wh.item, " / ")
            verify(!sub || !sub.visible, "micro has no used/total sub-line")
            var v = G.byText(wh.item, "55%")
            verify(v && v.visible, "bare ring + number still rendered")
        }

        function test_ram_25_state_warncrit() {
            // warn band (>75) -> amber
            prep({ file: "RamWidget.qml", w: 620, h: 560, sizeClass: "compact",
                   metrics: { ram_usage_percent: 80, ram_used_bytes: 13 * gib, ram_total_bytes: 16 * gib } })
            wait(520)
            snap(wh, "ram_state_warn")
            var dw = ringDist(wh.theme.warning)
            verify(dw < 75, "ring amber at 80% (dist " + dw.toFixed(0) + ")")
            // crit band (>90) -> red
            feedWait({ ram_usage_percent: 95, ram_used_bytes: 15 * gib, ram_total_bytes: 16 * gib }, 520)
            snap(wh, "ram_state_crit")
            var dc = ringDist(wh.theme.error)
            verify(dc < 75, "ring red at 95% (dist " + dc.toFixed(0) + ")")
        }

        function test_ram_26_state_sparkline() {
            prep({ file: "RamWidget.qml", w: 620, h: 560, sizeClass: "compact",
                   metrics: { ram_usage_percent: 20 } })
            feedWait({ ram_usage_percent: 55 }, 200)
            feedWait({ ram_usage_percent: 35 }, 200)
            var spark = findSpark()
            snap(wh, "ram_state_sparkline")
            verify(spark && spark.visible, "sparkline visible after 3 samples")
            verify(spark.values.length >= 3, "history holds >=3 samples (" + spark.values.length + ")")
        }

        function test_ram_30_chrome_accent() {
            prep({ file: "RamWidget.qml", w: 620, h: 560, sizeClass: "compact",
                   accent: "teal", metrics: { ram_usage_percent: 40, ram_used_bytes: 6 * gib, ram_total_bytes: 16 * gib } })
            wait(520)
            snap(wh, "ram_chrome_accent")
            var near = ringDist(wh.item.effAccent)
            var far  = ringDist(wh.theme.catProductivity)
            verify(near < 75, "ring recolours to the accent preset (dist " + near.toFixed(0) + ")")
            verify(far > near, "ring is no longer the default catProductivity purple")
        }

        function test_ram_31_chrome_auto() {
            prep({ file: "RamWidget.qml", w: 620, h: 560, sizeClass: "compact",
                   accent: "", metrics: { ram_usage_percent: 40, ram_used_bytes: 6 * gib, ram_total_bytes: 16 * gib } })
            wait(520)
            snap(wh, "ram_chrome_auto")
            var d = ringDist(wh.theme.catProductivity)
            verify(d < 75, "Auto accent falls back to catProductivity (dist " + d.toFixed(0) + ")")
        }

        function test_ram_32_backdrop_data() {
            return [ { tag: "none" }, { tag: "orbs" }, { tag: "mesh" }, { tag: "aurora" },
                     { tag: "waves" }, { tag: "stars" }, { tag: "bokeh" }, { tag: "grid" } ]
        }
        function test_ram_32_backdrop(row) {
            prep({ file: "RamWidget.qml", w: 620, h: 560, sizeClass: "compact",
                   backdrop: row.tag, metrics: ramMetrics })
            wait(200)
            var bd = findBackdrop()
            verify(bd, "backdrop layer present")
            snap(wh, "ram_backdrop_" + row.tag)
            compare(bd.visible, row.tag !== "none", "backdrop visibility for style " + row.tag)
            if (row.tag !== "none") compare("" + bd.style, row.tag, "backdrop style applied")
        }
    }
}
