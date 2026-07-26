import QtQuick
import QtTest
import "../../ui/qml" as App
import "../ui" as UI
import "GuiUtil.js" as G

// Systemic viewing-distance gate. Every first-party widget is loaded at every
// size it declares in WidgetCatalog, projected into both physical panel
// orientations. The scan inspects the rendered scene tree, so calculated font
// expressions are judged at their final pixel size rather than by source text.
Item {
    id: root
    width: 2700
    height: 2500

    App.WidgetCatalog { id: catalog }
    App.WidgetSizes { id: sizes }

    readonly property var metricSets: ({
        nominal: '{"cpu_usage_percent":42.5,"cpu_temp_celsius":55,'
               + '"ram_usage_percent":63,"ram_total_bytes":34359738368,'
               + '"ram_used_bytes":21646635008,"cpu_core_count":16,'
               + '"gpu_usage_percent":30,"gpu_temp_celsius":48,'
               + '"net_rx_bytes_per_sec":1048576,"net_tx_bytes_per_sec":524288,'
               + '"disk_total_bytes":1099511627776,"disk_used_bytes":549755813888,'
               + '"disk_usage_percent":50}',
        zero: '{"cpu_usage_percent":0,"cpu_temp_celsius":0,'
            + '"ram_usage_percent":0,"ram_total_bytes":0,"ram_used_bytes":0,'
            + '"cpu_core_count":0,"gpu_usage_percent":0,'
            + '"net_rx_bytes_per_sec":0,"net_tx_bytes_per_sec":0,'
            + '"disk_total_bytes":0,"disk_used_bytes":0,"disk_usage_percent":0}',
        saturated: '{"cpu_usage_percent":100,"cpu_temp_celsius":110,'
                 + '"ram_usage_percent":100,"ram_total_bytes":137438953472,'
                 + '"ram_used_bytes":137438953472,"cpu_core_count":128,'
                 + '"gpu_usage_percent":100,"gpu_temp_celsius":95,'
                 + '"net_rx_bytes_per_sec":1250000000,'
                 + '"net_tx_bytes_per_sec":1250000000,'
                 + '"disk_total_bytes":8796093022208,'
                 + '"disk_used_bytes":8796093022208,"disk_usage_percent":100}',
        empty: '{}'
    })
    readonly property var metricStates: ["nominal", "zero", "saturated", "empty"]

    UI.WidgetHarness {
        id: harness
        anchors.left: parent.left
        anchors.top: parent.top
        widgetFile: ""
        expanded: false
        active: false
    }

    function projected(size, landscape) {
        var def = sizes.table[size]
        if (!def) return ({ width: 0, height: 0 })
        return landscape
            ? ({ width: Math.round(846 * def.long),
                 height: Math.round(612 * def.short) })
            : ({ width: Math.round(696 * def.short),
                 height: Math.round(818 * def.long) })
    }

    function effectiveVisible(node) {
        var current = node
        while (current) {
            if (current.visible === false || current.opacity <= 0)
                return false
            current = current.parent
        }
        return true
    }

    function printable(text) {
        return ("" + text).replace(/\s/g, "")
    }

    function typeViolations(node, minimum) {
        var violations = []
        G.eachItem(node, function (candidate) {
            try {
                if (candidate.text === undefined || candidate.font === undefined
                        || !effectiveVisible(candidate)
                        || candidate.width <= 0 || candidate.height <= 0
                        || printable(candidate.text).length === 0)
                    return
                var pixelSize = Number(candidate.font.pixelSize)
                if (isFinite(pixelSize) && pixelSize > 0 && pixelSize < minimum) {
                    violations.push({
                        text: ("" + candidate.text).replace(/\n/g, " ").slice(0, 48),
                        pixelSize: pixelSize,
                        objectName: candidate.objectName || ""
                    })
                }
            } catch (error) {
                violations.push({
                    text: "scene-scan error: " + error,
                    pixelSize: -1,
                    objectName: ""
                })
            }
        })
        return violations
    }

    function clippingViolations(node) {
        var violations = []
        G.eachItem(node, function (candidate) {
            try {
                if (candidate.text === undefined || candidate.font === undefined
                        || candidate.truncated === undefined
                        || !effectiveVisible(candidate)
                        || candidate.width <= 0 || candidate.height <= 0
                        || printable(candidate.text).length === 0)
                    return

                var reasons = []
                if (candidate.truncated === true)
                    reasons.push("truncated")

                var contentWidth = Number(candidate.contentWidth)
                var contentHeight = Number(candidate.contentHeight)
                if (isFinite(contentWidth) && contentWidth > candidate.width + 1
                        && candidate.wrapMode === Text.NoWrap)
                    reasons.push("contentWidth " + Math.ceil(contentWidth)
                                 + " > width " + Math.floor(candidate.width))
                if (isFinite(contentHeight) && contentHeight > candidate.height + 1)
                    reasons.push("contentHeight " + Math.ceil(contentHeight)
                                 + " > height " + Math.floor(candidate.height))

                if (reasons.length > 0) {
                    violations.push({
                        text: ("" + candidate.text).replace(/\n/g, " ").slice(0, 64),
                        reasons: reasons.join("; "),
                        objectName: candidate.objectName || ""
                    })
                }
            } catch (error) {
                violations.push({
                    text: "scene-scan error: " + error,
                    reasons: "scan failed",
                    objectName: ""
                })
            }
        })
        return violations
    }

    TestCase {
        name: "WidgetLegibilityMatrix"
        when: windowShown
        visible: true

        property string loadedFile: ""

        function initTestCase() {
            var projections = 0
            for (var i = 0; i < catalog.items.length; i++)
                projections += catalog.items[i].sizes.length * 2
            verify(catalog.items.length === 30,
                   "matrix is tied to all 30 first-party widgets")
            compare(projections, 288,
                    "matrix contains every declared size in both orientations")
            compare(projections * root.metricStates.length, 1152,
                    "every projection carries all four metric boundary states")
        }

        function test_minimum_rendered_type_data() {
            var rows = []
            for (var i = 0; i < catalog.items.length; i++) {
                var item = catalog.items[i]
                var file = item.source.toString().split("/").pop()
                for (var s = 0; s < item.sizes.length; s++) {
                    var size = item.sizes[s]
                    for (var m = 0; m < root.metricStates.length; m++) {
                        var state = root.metricStates[m]
                        rows.push({
                            tag: item.type + "-portrait-" + size + "-" + state,
                            type: item.type,
                            file: file,
                            size: size,
                            landscape: false,
                            metrics: state
                        })
                        rows.push({
                            tag: item.type + "-landscape-" + size + "-" + state,
                            type: item.type,
                            file: file,
                            size: size,
                            landscape: true,
                            metrics: state
                        })
                    }
                }
            }
            return rows
        }

        function test_minimum_rendered_type(row) {
            if (loadedFile !== row.file) {
                harness.widgetFile = ""
                tryVerify(function () { return !harness.ready }, 3000,
                          "previous widget unloads")
                harness.widgetFile = row.file
                loadedFile = row.file
                tryVerify(function () { return harness.ready && harness.item !== null },
                          5000, row.type + " loads")
            }

            var box = projected(row.size, row.landscape)
            harness.width = box.width
            harness.height = box.height
            harness.expanded = false
            harness.active = false
            harness.metricsJson = root.metricSets[row.metrics]
            if (harness.item.hasOwnProperty("sizeClass"))
                harness.item.sizeClass = sizes.classFor(row.size, row.landscape)
            wait(100)

            compare(harness.item.width, box.width, row.tag + " projected width")
            compare(harness.item.height, box.height, row.tag + " projected height")
            var minimum = harness.theme.fontMinimum
            compare(minimum, 15, "default viewing-distance floor remains 15px")
            var failures = typeViolations(harness.item, minimum)
            var details = failures.map(function (failure) {
                return "'" + failure.text + "'=" + failure.pixelSize + "px"
                       + (failure.objectName ? " [" + failure.objectName + "]" : "")
            }).join(", ")
            compare(failures.length, 0,
                    row.tag + " has no visible text below " + minimum
                    + "px" + (details ? ": " + details : ""))

            var clipping = clippingViolations(harness.item)
            if (clipping.length > 0)
                grabImage(harness.item).save("gui-evidence/clipping-" + row.tag + ".png")
            var clippingDetails = clipping.map(function (failure) {
                return "'" + failure.text + "' (" + failure.reasons + ")"
                       + (failure.objectName ? " [" + failure.objectName + "]" : "")
            }).join(", ")
            compare(clipping.length, 0,
                    row.tag + " has no cut-off visible text"
                    + (clippingDetails ? ": " + clippingDetails : ""))
        }
    }
}
