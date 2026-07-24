import QtQuick
import QtTest
import "../ui" as UI
import "GuiUtil.js" as G

// ─────────────────────────────────────────────────────────────────────────
// Visible GUI tests for the "system, group B" Hub widgets: Network, Disk,
// Sensors. Each widget is hosted in a real KWin-composited window via
// UI.WidgetHarness, sized to a concrete cell, fed real metrics through
// wh.metricsJson (the exact keys each widget reads), and asserted with
// objective, GUI-observable outcomes: item geometry, item.visible, on-screen
// Text.text, and grabImage() pixel colour.
//
// Case map (85 total):
//   Network (26): 5 sizes + 5 config + 6 states + 10 chrome
//   Disk    (26): 5 sizes + 4 config + 7 states + 10 chrome
//   Sensors (33): 5 sizes + 11 config + 7 states + 10 chrome
//
// Metric keys (verified against source):
//   net_rx_bytes_per_sec, net_tx_bytes_per_sec
//   disk_total_bytes, disk_usage_percent
//   cpu_usage_percent, gpu_usage_percent, ram_usage_percent,
//   disk_usage_percent, cpu_temp_celsius, gpu_temp_celsius
// ─────────────────────────────────────────────────────────────────────────
Item {
    id: root
    width: 1400; height: 1360

    UI.WidgetHarness {
        id: wh
        x: 0; y: 0
        width: 700; height: 700
    }

    TestCase {
        id: tc
        name: "GuiWSysB"
        when: windowShown
        visible: true

        // ── evidence + helpers ────────────────────────────────────────────
        function snap(item, name) {
            var img = grabImage(item)
            img.save("gui-evidence/wsysb_" + name + ".png")
            return img
        }

        // Find a Text whose text is EXACTLY s (regardless of visibility).
        function exactText(node, s) {
            return G.findPred(node, function (n) {
                try { return n && n.text !== undefined && ("" + n.text) === s } catch (e) { return false }
            })
        }
        // Find the single Canvas (sparkline) under node.
        function canvasOf(node) {
            return G.findPred(node, function (n) {
                try { return n && typeof n.requestPaint === "function" } catch (e) { return false }
            })
        }
        // Find the BackdropLayer root (has both `style` string and `accent` colour).
        function backdropOf(node) {
            return G.findPred(node, function (n) {
                try { return n && n.style !== undefined && n.accent !== undefined
                             && typeof n.style === "string" } catch (e) { return false }
            })
        }
        // Two colours within tol (per-channel Euclidean over 0..255).
        function colorNear(c1, c2, tol) {
            var dr = c1.r * 255 - c2.r * 255
            var dg = c1.g * 255 - c2.g * 255
            var db = c1.b * 255 - c2.b * 255
            return Math.sqrt(dr * dr + dg * dg + db * db) <= tol
        }
        // Does ANY sampled pixel of img land within tol of colour `c`?
        function pixNear(img, c, tol) {
            var tr = Math.round(c.r * 255), tg = Math.round(c.g * 255), tb = Math.round(c.b * 255)
            var W = img.width, H = img.height
            for (var yi = 1; yi < 64; yi++) {
                for (var xi = 1; xi < 64; xi++) {
                    var px = Math.floor(W * xi / 64), py = Math.floor(H * yi / 64)
                    var dr = img.red(px, py) - tr
                    var dg = img.green(px, py) - tg
                    var db = img.blue(px, py) - tb
                    if (Math.sqrt(dr * dr + dg * dg + db * db) <= tol) return true
                }
            }
            return false
        }

        function feed(obj) { wh.metricsJson = JSON.stringify(obj) }
        function netFeed(rx, tx) {
            return {
                net_metrics_available: true, net_sample_status: "ready",
                net_rx_bytes_per_sec: rx === undefined ? 2000000 : rx,
                net_tx_bytes_per_sec: tx === undefined ? 500000 : tx,
                net_interfaces: [{
                    name: "enp7s0", category: "physical", link_state: "up",
                    speed_mbps: 2500, rate_available: true,
                    rx_bytes_per_sec: rx === undefined ? 2000000 : rx,
                    tx_bytes_per_sec: tx === undefined ? 500000 : tx,
                    rx_total_bytes: 384000000000, tx_total_bytes: 72000000000,
                    rx_dropped: 2, tx_dropped: 0, rx_errors: 0, tx_errors: 0
                }]
            }
        }
        function diskFeed(pct) {
            var root = {
                path: "/", source: "/dev/nvme0n1p2", fs_type: "ext4",
                device: "nvme0n1p2", metrics_available: true,
                total_bytes: 1000 * 1073741824,
                used_bytes: 420 * 1073741824,
                available_bytes: 540 * 1073741824,
                reserved_bytes: 40 * 1073741824,
                usage_percent: pct,
                io_rate_available: true,
                read_bytes_per_sec: 18 * 1048576,
                write_bytes_per_sec: 6 * 1048576
            }
            return {
                disk_metrics_available: true,
                disk_total_bytes: 1000 * 1073741824,
                disk_used_bytes: 420 * 1073741824,
                disk_available_bytes: 540 * 1073741824,
                disk_reserved_bytes: 40 * 1073741824,
                disk_usage_percent: pct,
                disk_mounts: [root]
            }
        }
        function snsFeed(cpuT, gpuT) {
            return { cpu_usage_available: true, ram_metrics_available: true,
                     disk_metrics_available: true,
                     cpu_usage_percent: 42, gpu_usage_percent: 30, ram_usage_percent: 55,
                     disk_usage_percent: 60, disk_total_bytes: 500107862016,
                     cpu_temp_celsius: cpuT, gpu_temp_celsius: gpuT,
                     gpu_primary_id: "card1",
                     gpu_devices: [{
                         id: "card1", name: "Radeon Test", usage_percent: 30,
                         temperature_celsius: gpuT,
                         power_watts: 188, power_cap_watts: 250,
                         fan_rpm: 1320, fan_max_rpm: 3200,
                         temperature_critical_celsius: 105
                     }] }
        }

        // Load `file`, wait ready, pin size, clear appearance overrides.
        function setup(file, cls, w, h) {
            wh.widgetFile = file
            tryVerify(function () { return wh.ready && wh.item !== null }, 6000, "loaded " + file)
            wh.width = w; wh.height = h
            wh.item.sizeClass = cls
            wh.item.accentName = ""
            wh.item.cardBackdrop = "none"
            wh.item.titleOverride = ""
            wait(150)
        }
        function resetNetCfg() {
            wh.storeCtl.setSetting(wh.instanceId, "showHistory", true)
            wh.storeCtl.setSetting(wh.instanceId, "unit", "bytes")
            wh.storeCtl.setSetting(wh.instanceId, "showDetails", true)
        }
        function resetDiskCfg() {
            wh.storeCtl.setSetting(wh.instanceId, "warnPercent", 90)
        }
        function resetSensorsCfg() {
            var ks = ["showCpu", "showGpu", "showRam", "showDisk", "showTemps",
                      "showGpuPower", "showGpuFan"]
            for (var i = 0; i < ks.length; i++) wh.storeCtl.setSetting(wh.instanceId, ks[i], true)
            wh.storeCtl.setSetting(wh.instanceId, "gpuDevice", "auto")
            wh.storeCtl.setSetting(wh.instanceId, "rowOrder", [])
        }

        // Uniform size-render assertion.
        function assertRendered(w, h, primarySub, prefix, caseName) {
            var img = snap(wh, prefix + "_" + caseName)
            verify(G.looksRendered(img), caseName + ": rendered non-blank pixels")
            compare(wh.item.width, w, caseName + ": width matches cell")
            compare(wh.item.height, h, caseName + ": height matches cell")
            var t = G.byText(wh.item, primarySub)
            verify(t !== null && t.visible, caseName + ": primary readout '" + primarySub + "' visible")
            verify(!t.truncated, caseName + ": primary readout not clipped")
        }

        // ═══════════════════════════ SIZE TABLES ═══════════════════════════
        // sizeClass derived from (short×long) projection: 0.5x0.5→compact(micro),
        // 0.5x1→tall(portrait), 1x0.5→wide(portrait), 1x1→compact, 1x1.5→tall.
        function sizeRows() {
            return [
                { tag: "0.5x0.5", cls: "compact", w: 348, h: 409 },
                { tag: "0.5x1",   cls: "tall",    w: 348, h: 819 },
                { tag: "1x0.5",   cls: "wide",    w: 696, h: 409 },
                { tag: "1x1",     cls: "compact", w: 696, h: 819 },
                { tag: "1x1.5",   cls: "tall",    w: 696, h: 1229 }
            ]
        }

        // ────────────────────────────── DISK ──────────────────────────────
        function test_disk_a_size_data() {
            return [
                { tag: "portrait-0.5x0.5",  cls: "compact", w: 348,  h: 409 },
                { tag: "landscape-0.5x0.5", cls: "compact", w: 423,  h: 306 },
                { tag: "portrait-0.5x1",    cls: "tall",    w: 348,  h: 818 },
                { tag: "landscape-0.5x1",   cls: "wide",    w: 846,  h: 306 },
                { tag: "portrait-1x0.5",    cls: "wide",    w: 696,  h: 409 },
                { tag: "landscape-1x0.5",   cls: "tall",    w: 423,  h: 612 },
                { tag: "portrait-1x1",      cls: "compact", w: 696,  h: 818 },
                { tag: "landscape-1x1",     cls: "compact", w: 846,  h: 612 },
                { tag: "portrait-1x1.5",    cls: "tall",    w: 696,  h: 1226 },
                { tag: "landscape-1x1.5",   cls: "wide",    w: 1268, h: 612 }
            ]
        }
        function test_disk_a_size(row) {
            setup("DiskWidget.qml", row.cls, row.w, row.h)
            resetDiskCfg(); feed(diskFeed(42)); wait(200)
            assertRendered(row.w, row.h, "%", "dsk", "DSK-SZ_" + row.tag)
            var composition = G.byObjName(wh.item, "diskCapacityComposition")
            verify(composition !== null, "capacity composition exists")
            compare(composition.visible, row.cls === "wide" || row.cls === "tall",
                    "shape with spare space earns the complete capacity composition")
        }

        function test_disk_b_config_data() {
            return [
                { id: "warn50" }, { id: "warn90" }, { id: "warn99" }, { id: "title" }
            ]
        }
        function test_disk_b_config(row) {
            setup("DiskWidget.qml", "compact", 696, 819)
            resetDiskCfg()
            if (row.id === "title") {
                feed(diskFeed(42)); wait(150)
                wh.item.titleOverride = "Root"
                wait(150)
                var t = exactText(wh.item, "Root")
                verify(t !== null && t.visible, "DSK-CF2: custom title 'Root' shown")
                snap(wh, "dsk_CF_title")
                return
            }
            // warnPercent slider: feed usage 92 and cross the amber threshold.
            var warn = row.id === "warn50" ? 50 : row.id === "warn90" ? 90 : 99
            wh.storeCtl.setSetting(wh.instanceId, "warnPercent", warn)
            feed(diskFeed(92)); wait(300)
            var img = snap(wh, "dsk_CF_" + row.id)
            var num = G.byText(wh.item, "92%")
            verify(num !== null && num.visible, "DSK-CF1 " + row.id + ": ring value 92% shown")
            if (warn === 99) {
                // 92 < warn 99 → below the amber band → accent (catInfo), NOT amber.
                verify(!pixNear(img, wh.theme.warning, 55), "DSK-CF1 warn99: ring NOT amber at 92% (below warn)")
            } else {
                // 92 > warn (50/90), < crit 97 → amber.
                verify(pixNear(img, wh.theme.warning, 55), "DSK-CF1 " + row.id + ": ring amber at 92%")
                verify(!pixNear(img, wh.theme.error, 55), "DSK-CF1 " + row.id + ": not yet crit-red")
            }
        }

        function test_disk_c_state_data() {
            return [
                { id: "ST1_na" }, { id: "ST2_value" }, { id: "ST3_warn" }, { id: "ST4_crit" },
                { id: "ST5_details" }, { id: "ST6_inline" }, { id: "ST7_micro" }
            ]
        }
        function test_disk_c_state(row) {
            var img
            switch (row.id) {
            case "ST1_na":
                setup("DiskWidget.qml", "compact", 696, 819); resetDiskCfg()
                feed({}); wait(200)                                   // no disk_total → unavailable
                verify(!wh.item.avail, "DSK-ST1: widget reports unavailable")
                var na = exactText(wh.item, "N/A")
                verify(na !== null && na.visible, "DSK-ST1: 'N/A' shown for no metrics")
                snap(wh, "dsk_ST1_na")
                break
            case "ST2_value":
                setup("DiskWidget.qml", "compact", 696, 819); resetDiskCfg()
                feed(diskFeed(42)); wait(250)
                var v = G.byText(wh.item, "42%")
                verify(v !== null && v.visible, "DSK-ST2: '42%' ring value shown")
                snap(wh, "dsk_ST2_value")
                break
            case "ST3_warn":
                setup("DiskWidget.qml", "compact", 696, 819); resetDiskCfg()
                wh.storeCtl.setSetting(wh.instanceId, "warnPercent", 90)
                feed(diskFeed(93)); wait(300)                          // 93>90, <97 → amber
                img = snap(wh, "dsk_ST3_warn")
                verify(pixNear(img, wh.theme.warning, 55), "DSK-ST3: ring/number amber above warn")
                break
            case "ST4_crit":
                setup("DiskWidget.qml", "compact", 696, 819); resetDiskCfg()
                wh.storeCtl.setSetting(wh.instanceId, "warnPercent", 90)
                feed(diskFeed(99)); wait(300)                          // 99>crit 97 → red
                img = snap(wh, "dsk_ST4_crit")
                verify(pixNear(img, wh.theme.error, 55), "DSK-ST4: ring/number red above crit")
                break
            case "ST5_details":
                setup("DiskWidget.qml", "wide", 846, 612); resetDiskCfg()
                feed(diskFeed(42)); wait(250)
                var u = exactText(wh.item, "Used"), f = exactText(wh.item, "Available"), tt = exactText(wh.item, "Total")
                verify(u && u.visible, "DSK-ST5: 'Used' detail row visible on wide")
                verify(f && f.visible, "DSK-ST5: 'Available' detail row visible on wide")
                verify(tt && tt.visible, "DSK-ST5: 'Total' detail row visible on wide")
                snap(wh, "dsk_ST5_details")
                break
            case "ST6_inline":
                setup("DiskWidget.qml", "compact", 696, 819); resetDiskCfg()
                feed(diskFeed(42)); wait(250)
                verify(wh.item.showInlineSub, "DSK-ST6: inline sub enabled on baseline")
                var sub = G.byText(wh.item, "GiB")
                verify(sub !== null && sub.visible, "DSK-ST6: inline used/total (GiB) shown")
                snap(wh, "dsk_ST6_inline")
                break
            case "ST7_micro":
                setup("DiskWidget.qml", "compact", 348, 409); resetDiskCfg()
                feed(diskFeed(42)); wait(250)
                verify(wh.item.micro, "DSK-ST7: micro derived on half-cell")
                var hdr = exactText(wh.item, "Disk")
                verify(hdr !== null && !hdr.visible, "DSK-ST7: header hidden at micro")
                var mv = G.byText(wh.item, "42%")
                verify(mv !== null && mv.visible, "DSK-ST7: bare ring value shown")
                snap(wh, "dsk_ST7_micro")
                break
            }
        }

        function test_disk_d_chrome_data() { return chromeRows() }
        function test_disk_d_chrome(row) {
            chromeCase("DiskWidget.qml", row, wh.theme.catInfo, function () {
                feed(diskFeed(42))       // comfortable load → ring/number == effAccent
            }, "dsk")
        }

        // ────────────────────────────── NET ───────────────────────────────
        function test_net_a_size_data() {
            return [
                { tag: "portrait-0.5x0.5",  cls: "compact", w: 348,  h: 409 },
                { tag: "landscape-0.5x0.5", cls: "compact", w: 423,  h: 306 },
                { tag: "portrait-0.5x1",    cls: "tall",    w: 348,  h: 818 },
                { tag: "landscape-0.5x1",   cls: "wide",    w: 846,  h: 306 },
                { tag: "portrait-1x0.5",    cls: "wide",    w: 696,  h: 409 },
                { tag: "landscape-1x0.5",   cls: "tall",    w: 423,  h: 612 },
                { tag: "portrait-1x1",      cls: "compact", w: 696,  h: 818 },
                { tag: "landscape-1x1",     cls: "compact", w: 846,  h: 612 },
                { tag: "portrait-1x1.5",    cls: "tall",    w: 696,  h: 1226 },
                { tag: "landscape-1x1.5",   cls: "wide",    w: 1268, h: 612 }
            ]
        }
        function test_net_a_size(row) {
            setup("NetWidget.qml", row.cls, row.w, row.h)
            resetNetCfg()
            feed(netFeed(1400000, 320000)); wait(40)
            feed(netFeed(2400000, 610000)); wait(40)
            feed(netFeed(2000000, 500000)); wait(200)
            assertRendered(row.w, row.h, "↓", "net", "NET-SZ_" + row.tag)
            var micro = row.tag.indexOf("0.5x0.5") >= 0
            var spark = canvasOf(wh.item)
            verify(spark !== null, "network history canvas exists")
            compare(spark.visible, !micro, "only the true micro tile omits history")
            compare(wh.item.hist.length >= 3, true, "the visual gate contains live throughput history")
            compare(wh.item.roomy, row.tag.indexOf("1x1.5") >= 0,
                    "only the largest declared tile shows interface and transfer details")
        }

        function test_net_b_config_data() {
            return [
                { id: "hist_on" }, { id: "hist_off" }, { id: "unit_bytes" },
                { id: "unit_bits" }, { id: "title" }
            ]
        }
        function test_net_b_config(row) {
            setup("NetWidget.qml", "compact", 696, 819); resetNetCfg(); feed(netFeed()); wait(150)
            var spark = canvasOf(wh.item)
            switch (row.id) {
            case "hist_on":
                wh.storeCtl.setSetting(wh.instanceId, "showHistory", true); wait(200)
                verify(spark !== null && spark.visible, "NET-CF1 on: sparkline canvas visible")
                snap(wh, "net_CF_hist_on")
                break
            case "hist_off":
                wh.storeCtl.setSetting(wh.instanceId, "showHistory", false); wait(200)
                verify(spark !== null && !spark.visible, "NET-CF1 off: sparkline canvas hidden")
                snap(wh, "net_CF_hist_off")
                break
            case "unit_bytes":
                wh.storeCtl.setSetting(wh.instanceId, "unit", "bytes"); wait(200)
                var mb = G.byText(wh.item, "MiB/s")
                verify(mb !== null && mb.visible, "NET-CF2 bytes: rate reads MiB/s")
                snap(wh, "net_CF_unit_bytes")
                break
            case "unit_bits":
                wh.storeCtl.setSetting(wh.instanceId, "unit", "bits"); wait(200)
                var mbps = G.byText(wh.item, "Mbps")
                verify(mbps !== null && mbps.visible, "NET-CF2 bits: rate reads Mbps")
                snap(wh, "net_CF_unit_bits")
                break
            case "title":
                wh.item.titleOverride = "LAN"; wait(150)
                var t = exactText(wh.item, "LAN")
                verify(t !== null && t.visible, "NET-CF3: custom title 'LAN' shown")
                snap(wh, "net_CF_title")
                break
            }
        }

        function test_net_c_state_data() {
            return [
                { id: "ST1_rates" }, { id: "ST2_peaks" }, { id: "ST3_spark" },
                { id: "ST4_micro" }, { id: "ST5_kbps" }, { id: "ST6_hold" }
            ]
        }
        function test_net_c_state(row) {
            var img, spark
            switch (row.id) {
            case "ST1_rates":
                setup("NetWidget.qml", "compact", 696, 819); resetNetCfg()
                feed(netFeed()); wait(250)
                var dn = G.byText(wh.item, "↓"), up = G.byText(wh.item, "↑")
                verify(dn && dn.visible, "NET-ST1: download rate row visible")
                verify(up && up.visible, "NET-ST1: upload rate row visible")
                img = snap(wh, "net_ST1_rates")
                verify(pixNear(img, wh.theme.success, 70), "NET-ST1: ↓ rate rendered in success colour")
                break
            case "ST2_peaks":
                setup("NetWidget.qml", "wide", 846, 612); resetNetCfg()
                feed({ net_rx_bytes_per_sec: 3000000, net_tx_bytes_per_sec: 900000 }); wait(200)
                feed({ net_rx_bytes_per_sec: 1000000, net_tx_bytes_per_sec: 400000 }); wait(200)
                verify(wh.item.showPeaks, "NET-ST2: peaks enabled on wide")
                var pk = G.byText(wh.item, "peak")
                verify(pk !== null && pk.visible, "NET-ST2: session peak line visible")
                snap(wh, "net_ST2_peaks")
                break
            case "ST3_spark":
                setup("NetWidget.qml", "compact", 696, 819); resetNetCfg()
                feed({ net_rx_bytes_per_sec: 1000000, net_tx_bytes_per_sec: 200000 }); wait(150)
                feed({ net_rx_bytes_per_sec: 2500000, net_tx_bytes_per_sec: 600000 }); wait(150)
                feed({ net_rx_bytes_per_sec: 1500000, net_tx_bytes_per_sec: 800000 }); wait(250)
                spark = canvasOf(wh.item)
                verify(spark !== null && spark.visible, "NET-ST3: sparkline visible after samples")
                verify(wh.item.hist.length >= 3, "NET-ST3: history accumulated (" + wh.item.hist.length + ")")
                img = snap(wh, "net_ST3_spark")
                verify(pixNear(img, wh.theme.success, 70), "NET-ST3: rx line drawn in success colour")
                break
            case "ST4_micro":
                setup("NetWidget.qml", "compact", 348, 409); resetNetCfg()
                feed(netFeed()); wait(250)
                verify(wh.item.micro, "NET-ST4: micro derived on half-cell")
                spark = canvasOf(wh.item)
                verify(spark !== null && !spark.visible, "NET-ST4: no sparkline at micro")
                var m = G.byText(wh.item, "↓")
                verify(m !== null && m.visible, "NET-ST4: centred rate number shown")
                snap(wh, "net_ST4_micro")
                break
            case "ST5_kbps":
                setup("NetWidget.qml", "compact", 696, 819); resetNetCfg()
                wh.storeCtl.setSetting(wh.instanceId, "unit", "bits")
                feed({ net_rx_bytes_per_sec: 500, net_tx_bytes_per_sec: 200 }); wait(250)
                var kb = G.byText(wh.item, "Kbps")
                verify(kb !== null && kb.visible, "NET-ST5: small value steps down to Kbps")
                snap(wh, "net_ST5_kbps")
                break
            case "ST6_hold":
                setup("NetWidget.qml", "compact", 696, 819); resetNetCfg()
                feed({ net_rx_bytes_per_sec: 1000000, net_tx_bytes_per_sec: 200000 }); wait(150)
                feed({ net_rx_bytes_per_sec: 2000000, net_tx_bytes_per_sec: 400000 }); wait(150)
                feed({ net_rx_bytes_per_sec: 1200000, net_tx_bytes_per_sec: 350000 }); wait(200)
                var before = wh.item.hist.length
                feed({}); wait(250)                                   // empty frame → skipped
                compare(wh.item.hist.length, before, "NET-ST6: empty metric frame did not poison history")
                snap(wh, "net_ST6_hold")
                break
            }
        }

        function test_net_d_chrome_data() { return chromeRows() }
        function test_net_d_chrome(row) {
            chromeCase("NetWidget.qml", row, wh.theme.catServices, function () {
                feed(netFeed())          // ↑ line drawn in effAccent
            }, "net")
        }

        // ──────────────────────────── SENSORS ─────────────────────────────
        function test_sensors_a_size_data() {
            return [
                { tag: "portrait-0.5x1",    cls: "tall",    w: 348,  h: 818 },
                { tag: "landscape-0.5x1",   cls: "wide",    w: 846,  h: 306 },
                { tag: "portrait-1x0.5",    cls: "wide",    w: 696,  h: 409 },
                { tag: "landscape-1x0.5",   cls: "tall",    w: 423,  h: 612 },
                { tag: "portrait-1x1",      cls: "compact", w: 696,  h: 818 },
                { tag: "landscape-1x1",     cls: "compact", w: 846,  h: 612 },
                { tag: "portrait-1x1.5",    cls: "tall",    w: 696,  h: 1226 },
                { tag: "landscape-1x1.5",   cls: "wide",    w: 1268, h: 612 }
            ]
        }
        function test_sensors_a_size(row) {
            setup("SensorsWidget.qml", row.cls, row.w, row.h)
            resetSensorsCfg(); feed(snsFeed(55, 50)); wait(200)
            assertRendered(row.w, row.h, "42%", "sns", "SNS-SZ_" + row.tag)
            compare(wh.item.availableRowCount, 8, "all configured sensor sources are represented")
            var source = exactText(wh.item, "kernel CPU delta")
            verify(source !== null, "CPU source label exists")
            compare(source.visible, wh.item.showSources,
                    "source context follows the widget's readable source layout")
            if (wh.item.smallFootprint) {
                compare(wh.item.hiddenRowCount, 4,
                        "the shortest supported layout prioritizes four rows")
                var hidden = exactText(wh.item, "+4 sensors hidden in this size")
                verify(hidden !== null && hidden.visible,
                       "the short layout discloses its hidden sensor count")
            } else {
                compare(wh.item.hiddenRowCount, 0)
            }
        }

        function test_sensors_b_config_data() {
            return [
                { id: "cpu_off", key: "showCpu", lbl: "CPU" }, { id: "cpu_on", key: "showCpu", lbl: "CPU" },
                { id: "gpu_off", key: "showGpu", lbl: "GPU" }, { id: "gpu_on", key: "showGpu", lbl: "GPU" },
                { id: "ram_off", key: "showRam", lbl: "RAM" }, { id: "ram_on", key: "showRam", lbl: "RAM" },
                { id: "disk_off", key: "showDisk", lbl: "DISK" }, { id: "disk_on", key: "showDisk", lbl: "DISK" },
                { id: "temps_off", key: "showTemps", lbl: "CPU °" }, { id: "temps_on", key: "showTemps", lbl: "CPU °" },
                { id: "title", key: "", lbl: "" }
            ]
        }
        function test_sensors_b_config(row) {
            setup("SensorsWidget.qml", "compact", 696, 819); resetSensorsCfg(); feed(snsFeed(55, 50)); wait(150)
            if (row.id === "title") {
                wh.item.titleOverride = "Vitals"; wait(150)
                var t = exactText(wh.item, "Vitals")
                verify(t !== null && t.visible, "SNS-CF6: custom title 'Vitals' shown")
                snap(wh, "sns_CF_title")
                return
            }
            var on = row.id.indexOf("_on") >= 0
            wh.storeCtl.setSetting(wh.instanceId, row.key, on); wait(200)
            var lbl = exactText(wh.item, row.lbl)
            verify(lbl !== null, "SNS-CF " + row.id + ": row label '" + row.lbl + "' exists")
            compare(lbl.visible, on, "SNS-CF " + row.id + ": '" + row.lbl + "' row visibility == " + on)
            snap(wh, "sns_CF_" + row.id)
        }

        function test_sensors_c_state_data() {
            return [
                { id: "ST1_rows" }, { id: "ST2_wide" }, { id: "ST3_cool" }, { id: "ST4_warn" },
                { id: "ST5_hot" }, { id: "ST6_empty" }
            ]
        }
        function test_sensors_c_state(row) {
            var img
            switch (row.id) {
            case "ST1_rows":
                setup("SensorsWidget.qml", "compact", 696, 819); resetSensorsCfg()
                feed(snsFeed(55, 50)); wait(250)
                var cpu = exactText(wh.item, "CPU"), val = G.byText(wh.item, "42%")
                verify(cpu && cpu.visible, "SNS-ST1: CPU row visible")
                verify(val && val.visible, "SNS-ST1: CPU load value 42% shown")
                snap(wh, "sns_ST1_rows")
                break
            case "ST2_wide":
                setup("SensorsWidget.qml", "wide", 846, 612); resetSensorsCfg()
                feed(snsFeed(55, 50)); wait(300)
                var lc = exactText(wh.item, "CPU"), lg = exactText(wh.item, "GPU")
                verify(lc && lc.visible && lg && lg.visible, "SNS-ST2: CPU & GPU rows visible")
                var pc = lc.mapToItem(wh.item, 0, 0), pg = lg.mapToItem(wh.item, 0, 0)
                // Wide reflows the six delegates into two columns → GPU (item 1)
                // sits in the right column, to the RIGHT of CPU (item 0), not below.
                verify(pg.x > pc.x + 20, "SNS-ST2: GPU reflowed into 2nd column (gpu.x " + Math.round(pg.x) + " > cpu.x " + Math.round(pc.x) + ")")
                snap(wh, "sns_ST2_wide")
                break
            case "ST3_cool":
                setup("SensorsWidget.qml", "compact", 696, 819); resetSensorsCfg()
                feed(snsFeed(50, 48)); wait(650)                       // both temps <70 → no warn/hot
                img = snap(wh, "sns_ST3_cool")
                var coolRows = wh.item.rows
                var coolCpu = null, coolGpu = null
                for (var c = 0; c < coolRows.length; c++) {
                    if (coolRows[c].lbl === "CPU °") coolCpu = coolRows[c]
                    if (coolRows[c].lbl === "GPU °") coolGpu = coolRows[c]
                }
                verify(coolCpu && coolGpu, "SNS-ST3: both temperature rows exist")
                verify(G.colorDist("" + coolCpu.col, "" + wh.theme.warning) > 40
                       && G.colorDist("" + coolGpu.col, "" + wh.theme.warning) > 40,
                       "SNS-ST3: cool temperature bars are not amber")
                verify(G.colorDist("" + coolCpu.col, "" + wh.theme.error) > 40
                       && G.colorDist("" + coolGpu.col, "" + wh.theme.error) > 40,
                       "SNS-ST3: cool temperature bars are not red")
                break
            case "ST4_warn":
                setup("SensorsWidget.qml", "compact", 696, 819); resetSensorsCfg()
                feed(snsFeed(84, 82)); wait(650)                       // default 80..89 → amber
                img = snap(wh, "sns_ST4_warn")
                verify(pixNear(img, wh.theme.warning, 40), "SNS-ST4: amber temp bar in warn band")
                verify(!pixNear(img, wh.theme.error, 40), "SNS-ST4: not yet red in warn band")
                break
            case "ST5_hot":
                setup("SensorsWidget.qml", "compact", 696, 819); resetSensorsCfg()
                feed(snsFeed(92, 90)); wait(650)                       // >85 → red
                img = snap(wh, "sns_ST5_hot")
                verify(pixNear(img, wh.theme.error, 40), "SNS-ST5: red temp bar when hot")
                break
            case "ST6_empty":
                setup("SensorsWidget.qml", "compact", 696, 819); resetSensorsCfg()
                feed(snsFeed(55, 50))
                var ks = ["showCpu", "showGpu", "showRam", "showDisk", "showTemps",
                          "showGpuPower", "showGpuFan"]
                for (var i = 0; i < ks.length; i++) wh.storeCtl.setSetting(wh.instanceId, ks[i], false)
                wait(250)
                var ph = exactText(wh.item, "No sensors enabled")
                verify(ph !== null && ph.visible, "SNS-ST6: 'No sensors enabled' placeholder shown")
                snap(wh, "sns_ST6_empty")
                break
            }
        }

        function test_sensors_d_chrome_data() { return chromeRows() }
        function test_sensors_d_chrome(row) {
            chromeCase("SensorsWidget.qml", row, wh.theme.catSystem, function () {
                feed(snsFeed(55, 50)) // accentSet → load+temp bars recolour to effAccent
            }, "sns")
        }

        // ═══════════════════════ SHARED CHROME (CHx) ═══════════════════════
        // CH1 accent override, CH2 accent Auto, CH3 cardBackdrop ×8.
        function chromeRows() {
            return [
                { kind: "accent" }, { kind: "auto" },
                { kind: "backdrop", style: "none" }, { kind: "backdrop", style: "orbs" },
                { kind: "backdrop", style: "mesh" }, { kind: "backdrop", style: "aurora" },
                { kind: "backdrop", style: "waves" }, { kind: "backdrop", style: "stars" },
                { kind: "backdrop", style: "bokeh" }, { kind: "backdrop", style: "grid" }
            ]
        }
        function chromeCase(file, row, autoColor, feeder, prefix) {
            setup(file, "compact", 696, 819)
            if (prefix === "net") resetNetCfg()
            else if (prefix === "dsk") resetDiskCfg()
            else resetSensorsCfg()
            feeder(); wait(200)
            var red = Qt.color(wh.theme.accentPresets["red"].a)
            if (row.kind === "accent") {
                wh.item.accentName = "red"; wait(300)
                verify(colorNear(wh.item.effAccent, red, 8), "CH1 " + prefix + ": effAccent resolves to preset red")
                var img = snap(wh, prefix + "_CH1_accent")
                verify(pixNear(img, red, 80), "CH1 " + prefix + ": accent-tinted element rendered red")
            } else if (row.kind === "auto") {
                wh.item.accentName = ""; wait(300)
                verify(colorNear(wh.item.effAccent, autoColor, 10), "CH2 " + prefix + ": Auto falls back to category colour")
                snap(wh, prefix + "_CH2_auto")
            } else {
                wh.item.cardBackdrop = row.style; wait(250)
                var bl = backdropOf(wh.item)
                verify(bl !== null, "CH3 " + prefix + ": BackdropLayer present")
                compare(bl.visible, row.style !== "none",
                        "CH3 " + prefix + " " + row.style + ": backdrop visible == " + (row.style !== "none"))
                snap(wh, prefix + "_CH3_" + row.style)
            }
        }
    }
}
