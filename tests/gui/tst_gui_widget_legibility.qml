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

    TestCase {
        name: "WidgetLegibilityMatrix"
        when: windowShown
        visible: true

        property string loadedFile: ""

        function initTestCase() {
            var combinations = 0
            for (var i = 0; i < catalog.items.length; i++)
                combinations += catalog.items[i].sizes.length * 2
            verify(catalog.items.length === 30,
                   "matrix is tied to all 30 first-party widgets")
            verify(combinations >= 298,
                   "matrix contains every declared size in both orientations")
        }

        function test_minimum_rendered_type_data() {
            var rows = []
            for (var i = 0; i < catalog.items.length; i++) {
                var item = catalog.items[i]
                var file = item.source.toString().split("/").pop()
                for (var s = 0; s < item.sizes.length; s++) {
                    var size = item.sizes[s]
                    rows.push({
                        tag: item.type + "-portrait-" + size,
                        type: item.type,
                        file: file,
                        size: size,
                        landscape: false
                    })
                    rows.push({
                        tag: item.type + "-landscape-" + size,
                        type: item.type,
                        file: file,
                        size: size,
                        landscape: true
                    })
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
            if (harness.item.hasOwnProperty("sizeClass"))
                harness.item.sizeClass = sizes.classFor(row.size, row.landscape)
            wait(20)

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
        }
    }
}
