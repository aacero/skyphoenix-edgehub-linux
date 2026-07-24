import QtQuick
import QtTest
import "../../ui/qml" as App
import "../../ui/qml/widgets" as Widgets

// Comprehensive smoke: EVERY widget type's config schema renders in the shared
// WidgetConfigPanel without error, and every schema field with a `key` produces a
// rendered field control. Guards against a per-widget schema regression (bad field
// type, missing renderer, throw) that the shared-panel wiring test can't catch.
Item {
    id: root; width: 1000; height: 800
    property var m: ({ textPrimary:"#E6EDF3", textSecondary:"#8B949E", bg:"#0D1117",
        accent:"#F26D6D", border:"#30363D", panel:"#161B22", panelAlt:"#1C222B",
        textOnAccent:"#0D1117", radius:12 })
    App.Theme { id: theme }
    App.DashboardStore { id: store }
    App.WidgetConfigSchema { id: sc }
    App.WidgetCatalog { id: catalog }

    readonly property var types: catalog.items.map(function(item) { return item.type })

    property string curType: ""
    property bool ready: false
    Component.onCompleted: { store.load("blank"); ready = true }

    Loader {
        id: ld; active: root.ready && root.curType !== ""; anchors.fill: parent
        sourceComponent: Widgets.WidgetConfigPanel {
            schema: sc.schemaFor(root.curType)
            st: store
            instanceId: "inst-" + root.curType
            col: root.m
        }
    }

    function findAll(node, pred, acc) {
        acc = acc || []; if (!node) return acc
        if (pred(node)) acc.push(node)
        var kids = node.children
        for (var i=0; kids && i<kids.length; i++) findAll(kids[i], pred, acc)
        return acc
    }
    // schema field keys that render a control (exclude decorative info/about-only).
    function schemaFieldKeys(type) {
        var schema = sc.schemaFor(type); var keys = []
        if (!schema || !schema.sections) return keys
        for (var s=0; s<schema.sections.length; s++) {
            var f = schema.sections[s].fields || []
            for (var i=0; i<f.length; i++)
                if (f[i].key && f[i].type !== "info") keys.push(f[i].key)
        }
        return keys
    }

    TestCase {
        name: "AllWidgetConfigs"; when: windowShown

        function test_every_type_renders_its_schema() {
            compare(root.types.length, catalog.items.length,
                    "the config smoke follows every catalog widget")
            for (var i=0; i<root.types.length; i++) {
                var type = root.types[i]
                root.curType = ""; wait(0)
                root.curType = type
                tryVerify(function(){ return ld.item !== null }, 1000, type + " config panel loaded")
                wait(20)   // let the field Repeaters instantiate
                var expected = schemaFieldKeys(type)
                var wraps = findAll(ld.item, function(n){
                    return typeof n.objectName === "string" && n.objectName.indexOf("field-") === 0 })
                // every keyed field renders a wrapper (there can be more: About/title)
                verify(wraps.length >= expected.length,
                       type + ": rendered " + wraps.length + " fields, schema has " +
                       expected.length + " keyed fields (" + expected.join(",") + ")")
                // each keyed field has a matching wrapper by objectName
                for (var k=0; k<expected.length; k++) {
                    var want = "field-" + expected[k]
                    var found = wraps.some(function(w){ return w.objectName === want })
                    verify(found, type + ": missing rendered field '" + expected[k] + "'")
                }
            }
        }
    }
}
