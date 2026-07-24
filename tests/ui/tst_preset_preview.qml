import QtQuick
import QtTest
import "../../ui/qml" as App
import "../../ui/qml/widgets" as Wg

Item {
    id: root
    width: 1000
    height: 620

    property alias theme: previewTheme
    App.Theme { id: previewTheme }
    App.PresetCatalog { id: presets }
    App.WidgetCatalog { id: widgets }
    App.WidgetPacker { id: expectedPacker }

    Wg.PresetPreview {
        id: preview
        anchors.fill: parent
        preset: presets.def("gaming")
        widgetCatalog: widgets
        landscape: true
    }

    function eachItem(node, fn) {
        if (!node) return
        fn(node)
        var children = node.children || []
        for (var i = 0; i < children.length; i++) eachItem(children[i], fn)
    }

    function previewTiles() {
        var out = []
        eachItem(preview.canvasItem, function (node) {
            if (node.objectName !== undefined
                    && String(node.objectName).indexOf("presetPreviewTile-") === 0)
                out.push(node)
        })
        return out
    }

    function previewHosts() {
        var out = []
        eachItem(preview.canvasItem, function (node) {
            if (node.objectName !== undefined
                    && String(node.objectName).indexOf("presetPreviewHost-") === 0)
                out.push(node)
        })
        return out
    }

    function canvasRect(item) {
        var tl = item.mapToItem(preview.canvasItem, 0, 0)
        var br = item.mapToItem(preview.canvasItem, item.width, item.height)
        return { x: Math.min(tl.x, br.x), y: Math.min(tl.y, br.y),
                 width: Math.abs(br.x - tl.x), height: Math.abs(br.y - tl.y) }
    }

    function overlaps(a, b) {
        return a.x < b.x + b.width - 0.5 && a.x + a.width > b.x + 0.5
            && a.y < b.y + b.height - 0.5 && a.y + a.height > b.y + 0.5
    }

    TestCase {
        name: "PresetPreview"
        when: windowShown

        function init() {
            root.width = 1000
            root.height = 620
            preview.landscape = true
            preview.preset = presets.def("gaming")
            wait(30)
        }

        function test_explains_selected_screen_before_commit() {
            compare(preview.titleItem.text, "Gaming Cockpit")
            verify(preview.purposeItem.text.indexOf("graphics card") >= 0)
            verify(preview.setupItem.text.indexOf("Linux telemetry") >= 0)
            compare(preview.previewTileCount, 3)
            compare(previewTiles().length, 3)
        }

        function test_preview_is_explicitly_passive() {
            compare(preview.passive, true,
                    "a catalog preview never starts live widget drivers or egress")
            var hosts = previewHosts()
            compare(hosts.length, 3, "each preview tile is a real WidgetHost")
            for (var i = 0; i < hosts.length; i++) {
                compare(hosts[i].driverActive, false)
                compare(hosts[i].acceptsInput, false)
                compare(hosts[i].netHub.offline, true)
                tryCompare(hosts[i], "status", Loader.Ready, 3000)
                verify(hosts[i].item !== null, "the actual widget QML is rendered")
            }
        }

        function test_landscape_real_widgets_stay_inside_canvas_without_overlap() {
            var tiles = previewTiles()
            compare(tiles.length, 3)
            for (var i = 0; i < tiles.length; i++) {
                var box = canvasRect(tiles[i])
                verify(box.x >= -0.5 && box.y >= -0.5, tiles[i].objectName + " starts inside")
                verify(box.x + box.width <= preview.canvasItem.width + 0.5,
                       tiles[i].objectName + " fits horizontally")
                verify(box.y + box.height <= preview.canvasItem.height + 0.5,
                       tiles[i].objectName + " fits vertically")
                for (var j = i + 1; j < tiles.length; j++)
                    verify(!overlaps(box, canvasRect(tiles[j])),
                           tiles[i].objectName + " does not overlap " + tiles[j].objectName)
            }
        }

        function test_portrait_real_widgets_preserve_order_and_do_not_overlap() {
            root.width = 500
            root.height = 1000
            preview.landscape = false
            wait(30)
            var tiles = previewTiles()
            compare(tiles.length, 3)
            verify(String(tiles[0].objectName).indexOf("gpu") >= 0,
                   "the hero GPU remains first after projection")
            for (var i = 0; i < tiles.length; i++) {
                var box = canvasRect(tiles[i])
                verify(box.x >= -0.5 && box.y >= -0.5)
                verify(box.x + box.width <= preview.canvasItem.width + 0.5)
                verify(box.y + box.height <= preview.canvasItem.height + 0.5)
                for (var j = i + 1; j < tiles.length; j++)
                    verify(!overlaps(box, canvasRect(tiles[j])))
            }
        }

        function test_blank_screen_has_an_honest_empty_preview() {
            preview.preset = {
                title: "Blank dashboard",
                purpose: "Start empty.",
                setup: "Add widgets after setup.",
                pages: [ { tiles: [] } ]
            }
            wait(20)
            compare(preview.previewTileCount, 0)
            compare(preview.titleItem.text, "Blank dashboard")
            verify(preview.setupItem.text.indexOf("Add widgets") >= 0)
        }

        function test_every_preset_renders_real_widgets_and_matches_resulting_page() {
            verify(presets.items.length >= 19, "the full preset catalog is exercised")
            for (var presetIndex = 0; presetIndex < presets.items.length; presetIndex++) {
                var selected = presets.items[presetIndex]
                var document = presets.buildDoc(selected.id)
                verify(document && document.pages.length === 1,
                       selected.id + " builds one screen")
                var expected = expectedPacker.pack(document.pages[0].tiles)

                for (var orientationIndex = 0; orientationIndex < 2; orientationIndex++) {
                    preview.landscape = orientationIndex === 0
                    root.width = preview.landscape ? 1000 : 500
                    root.height = preview.landscape ? 620 : 1000
                    preview.preset = selected
                    preview.syncPreset()
                    wait(0)
                    tryCompare(preview, "previewTileCount", expected.length, 3000,
                               selected.id + " preview count")

                    var tiles = previewTiles()
                    var hosts = previewHosts()
                    compare(tiles.length, expected.length,
                            selected.id + " uses the resulting page tile count")
                    compare(hosts.length, expected.length,
                            selected.id + " renders every tile through WidgetHost")
                    for (var i = 0; i < expected.length; i++) {
                        compare(tiles[i].modelData.type, expected[i].type,
                                selected.id + " preserves widget order")
                        compare(tiles[i].modelData.size, expected[i].size,
                                selected.id + " preserves declared size")
                        tryCompare(hosts[i], "status", Loader.Ready, 3000,
                                   selected.id + " loads " + expected[i].type)
                        verify(hosts[i].item !== null,
                               selected.id + " uses real " + expected[i].type + " QML")
                        compare(hosts[i].driverActive, false)
                        compare(hosts[i].acceptsInput, false)

                        var box = canvasRect(tiles[i])
                        verify(box.x >= -0.5 && box.y >= -0.5,
                               selected.id + " starts inside the preview")
                        verify(box.x + box.width <= preview.canvasItem.width + 0.5,
                               selected.id + " fits preview width")
                        verify(box.y + box.height <= preview.canvasItem.height + 0.5,
                               selected.id + " fits preview height")
                        for (var j = i + 1; j < tiles.length; j++)
                            verify(!overlaps(box, canvasRect(tiles[j])),
                                   selected.id + " tiles do not overlap")
                    }
                }
            }
        }
    }
}
