import QtQuick
import QtTest
import "../ui" as UI
import "GuiUtil.js" as G

// ─────────────────────────────────────────────────────────────────────────
// Visible GUI test suite for the five extended catalog widgets:
// Systems, Quick Actions, Grafana / Metrics, The Sky Tonight, and Humble Books.
// Exercises real layout, deterministic content seeding, and full-frame grabs
// at the standard portrait 1x1 tile size (696x818) to provide verified
// visual baselines for tests/visual/cases.json.
// ─────────────────────────────────────────────────────────────────────────
Item {
    id: root
    width: 1200; height: 1000

    Rectangle {
        anchors.fill: parent
        color: "#0D1117"
        z: -10
    }

    UI.WidgetHarness {
        id: wh
        anchors.left: parent.left
        anchors.top: parent.top
        width: 696; height: 818
        widgetFile: ""
    }

    TestCase {
        name: "GuiWCatalogExt"
        when: windowShown
        visible: true

        function snap(item, name) {
            var img = grabImage(item)
            img.save("gui-evidence/wext_" + name + ".png")
            return img
        }

        function prep(file, w, h, cls, settings) {
            wh.width = w
            wh.height = h
            wh.expanded = false
            if (wh.widgetFile !== file) {
                wh.widgetFile = file
                tryVerify(function () { return wh.ready }, 6000, "widget " + file + " loaded")
            }
            verify(wh.ready, "harness ready")
            wh.storeCtl.resetSettings(wh.instanceId, settings || {})
            wh.item.instanceId = wh.instanceId
            wh.item.sizeClass = cls
            wh.item.accentName = ""
            wh.item.cardBackdrop = "none"
            wh.item.active = false
            if (wh.item.hasOwnProperty("nowMsOverride"))
                wh.item.nowMsOverride = 1790632800000 // 2026-09-28T22:00:00Z
            wait(50)
            return wh.item
        }

        function test_systems_portrait_1x1() {
            var it = prep("SystemsWidget.qml", 696, 818, "compact", {
                hosts: "alpha | 10.0.0.10:9100\nbeta | 10.0.0.11:9100",
                defaultPort: 9100, pollSec: 3600, warnCpu: 85, warnRam: 85, warnDisk: 90
            })
            it.localNodes = [
                {
                    label: "alpha",
                    url: "http://10.0.0.10:9100/metrics", status: "online", error: "",
                    cpuPercent: 32.5, ramPercent: 54.2, diskPercent: 68.0,
                    netRxRate: 1048576, netTxRate: 524288,
                    uptimeSec: 1234567, uptimeStr: "14d 6h"
                },
                {
                    label: "beta",
                    url: "http://10.0.0.11:9100/metrics", status: "online", error: "",
                    cpuPercent: 45.0, ramPercent: 62.0, diskPercent: 40.0,
                    netRxRate: 2097152, netTxRate: 1048576,
                    uptimeSec: 3600000, uptimeStr: "42d 1h"
                }
            ]
            wait(80)
            verify(it.visible, "systems widget visible")
            var img = snap(wh.item, "systems_portrait-1x1")
            compare(img.width, 696)
            compare(img.height, 818)
        }

        function test_quickactions_portrait_1x1() {
            var it = prep("QuickActionsWidget.qml", 696, 818, "compact", {
                hostsText: "alpha | 10.0.0.10 | user\nbeta | 10.0.0.11 | user",
                showStatusBanner: true
            })
            wait(80)
            verify(it.visible, "quickactions widget visible")
            var img = snap(wh.item, "quickactions_portrait-1x1")
            compare(img.width, 696)
            compare(img.height, 818)
        }

        function test_grafana_portrait_1x1() {
            var it = prep("GrafanaWidget.qml", 696, 818, "compact", {
                url: "http://localhost:9090", query: "node_load1", rangeSec: 3600,
                pollSec: 3600, chartType: "area", unit: "%", unitScale: "auto",
                showMinMax: true, fillGlow: true
            })
            it.loading = false
            it.latestVal = 42.5
            it.minVal = 12.0
            it.maxVal = 85.0
            it.avgVal = 48.2
            it.deltaVal = 3.5
            it.seriesName = "cluster_load"
            it.dataPoints = [
                { t: 1000, v: 20 }, { t: 2000, v: 40 }, { t: 3000, v: 42.5 }
            ]
            wait(80)
            verify(it.visible, "grafana widget visible")
            var img = snap(wh.item, "grafana_portrait-1x1")
            compare(img.width, 696)
            compare(img.height, 818)
        }

        function test_skytonight_portrait_1x1() {
            var it = prep("SkyTonightWidget.qml", 696, 818, "compact", {
                locationMode: "manual", lat: 48.2082, lon: 16.3738, place: "Vienna",
                showTwilights: true, showClouds: true, showHourlyBar: true,
                showMoon: true, showPlanets: true
            })
            it.loading = false
            it.cloudLoaded = true
            it.avgCloud = 15
            it.bestWindow = { hr: 23, label: "11 PM", cloud: 5 }
            it.hourlyWindow = [
                { hr: 20, label: "8 PM", cloud: 10 },
                { hr: 21, label: "9 PM", cloud: 15 },
                { hr: 22, label: "10 PM", cloud: 12 },
                { hr: 23, label: "11 PM", cloud: 5 },
                { hr: 0, label: "12 AM", cloud: 8 },
                { hr: 1, label: "1 AM", cloud: 14 }
            ]
            wait(80)
            verify(it.visible, "skytonight widget visible")
            var img = snap(wh.item, "skytonight_portrait-1x1")
            compare(img.width, 696)
            compare(img.height, 818)
        }

        function test_humblebooks_portrait_1x1() {
            var it = prep("HumbleBooksWidget.qml", 696, 818, "compact", {
                category: "all", pollHours: 2
            })
            it.loading = false
            it.bundles = [
                {
                    id: "bundle-1", machineName: "techbooks",
                    title: "Linux Systems", fullName: "Comprehensive Linux Architecture Bundle", category: "Tech",
                    url: "https://example.test/bundle1", imageUrl: "", endDate: "2026-12-31T00:00:00Z",
                    timeRemainingText: "14d left", itemCountText: "12 items",
                    valueText: "$320", tierPriceText: "$25 for all",
                    blurb: "Master Linux internals."
                },
                {
                    id: "bundle-2", machineName: "sfbooks",
                    title: "Sci-Fi Classics", fullName: "Sci-Fi Classics Bundle", category: "SF",
                    url: "https://example.test/bundle2", imageUrl: "", endDate: "2026-12-31T00:00:00Z",
                    timeRemainingText: "3d left", itemCountText: "10 items",
                    valueText: "$180", tierPriceText: "$18 for all",
                    blurb: "Classic science fiction masterpieces."
                }
            ]
            wait(80)
            verify(it.visible, "humblebooks widget visible")
            var img = snap(wh.item, "humblebooks_portrait-1x1")
            compare(img.width, 696)
            compare(img.height, 818)
        }
    }
}
