import QtQuick
import QtTest
import "../../ui/qml/widgets" as W

Item {
    id: root
    width: 420
    height: 320

    property int storeRevision: 0
    property var buckets: ({})
    property int taps: 0

    QtObject {
        id: fakeStore
        property int revision: root.storeRevision
        function ensureSettings(id, defaults) {
            if (root.buckets[id] === undefined) root.buckets[id] = defaults || ({})
        }
        function settingsFor(id) { return root.buckets[id] || ({}) }
    }
    QtObject {
        id: fakeCatalog
        function defaults(type) { return { title: type + " title", accent: "amber", cardBackdrop: "grid" } }
    }

    Component {
        id: probeComponent
        Item {
            property string instanceId: ""
            property var store: null
            property bool expanded: false
            property string sizeClass: ""
            property bool active: true
            property bool foreground: false
            property var metrics: ({})
            property var netHub: null
            property var timeZones: null
            property int tick: -1
            property bool chromeless: false
            property bool showHeader: true
            property string titleOverride: ""
            property string accentName: ""
            property string cardBackdrop: ""
            MouseArea { anchors.fill: parent; onClicked: root.taps++ }
        }
    }

    W.WidgetHost {
        id: host
        anchors.fill: parent
        widgetId: "probe-1"
        widgetType: "probe"
        widgetComponent: probeComponent
        store: fakeStore
        catalog: fakeCatalog
        metrics: ({ value: 7 })
        tick: 11
        sizeClass: "wide"
        driverActive: false
        foreground: false
        acceptsInput: false
    }

    W.WidgetHost {
        id: failedHost
        width: 360
        height: 220
        x: root.width + 20
        loadEnabled: false
        widgetId: "broken-1"
        widgetType: "broken-widget"
        widgetSource: "file:///definitely-missing/WidgetThatDoesNotExist.qml"
        acceptsInput: true
    }

    function findByObjectName(node, wanted) {
        if (!node) return null
        if (node.objectName === wanted) return node
        var children = node.children || []
        for (var i = 0; i < children.length; i++) {
            var found = findByObjectName(children[i], wanted)
            if (found) return found
        }
        return null
    }

    TestCase {
        name: "WidgetHost"
        when: windowShown

        function initTestCase() {
            tryVerify(function () { return host.status === Loader.Ready && host.item !== null }, 3000)
        }

        function init() {
            host.driverActive = false
            host.foreground = false
            host.expanded = false
            host.sizeClass = "wide"
            host.tick = 11
            host.metrics = ({ value: 7 })
            host.acceptsInput = false
        }

        function test_shared_injection_contract() {
            compare(host.item.instanceId, "probe-1")
            compare(host.item.store, fakeStore)
            compare(host.item.expanded, false)
            compare(host.item.sizeClass, "wide")
            compare(host.item.active, false)
            compare(host.item.foreground, false)
            compare(host.item.metrics.value, 7)
            compare(host.item.tick, 11)
            compare(host.item.titleOverride, "probe title")
            compare(host.item.accentName, "amber")
            compare(host.item.cardBackdrop, "grid")
        }

        function test_lifecycle_bindings_follow_host() {
            host.driverActive = true
            host.foreground = true
            host.expanded = true
            host.sizeClass = "full"
            host.tick = 12
            host.metrics = ({ value: 9 })
            compare(host.item.active, true)
            compare(host.item.foreground, true)
            compare(host.item.expanded, true)
            compare(host.item.sizeClass, "full")
            compare(host.item.tick, 12)
            compare(host.item.metrics.value, 9)
            host.driverActive = false
            host.foreground = false
            host.expanded = false
            host.sizeClass = "wide"
        }

        function test_passive_preview_blocks_widget_actions() {
            root.taps = 0
            host.acceptsInput = false
            mouseClick(host, host.width / 2, host.height / 2)
            compare(root.taps, 0, "passive preview consumed the action")

            host.acceptsInput = true
            mouseClick(host, host.width / 2, host.height / 2)
            compare(root.taps, 1, "interactive Hub host delivered the action")
            host.acceptsInput = false
        }

        function test_loader_error_isolated_to_visible_fallback() {
            ignoreWarning(/.*WidgetThatDoesNotExist.qml.*/)
            failedHost.loadEnabled = true
            tryCompare(failedHost, "status", Loader.Error, 3000)
            compare(failedHost.item, null, "failed widget created no unsafe partial item")
            compare(failedHost.loadFailed, true, "host exposes the Loader error state")
            var fallback = findByObjectName(failedHost, "widgetLoadError")
            verify(fallback !== null && fallback.visible,
                   "the failed widget is replaced by a visible local fallback")
            verify(fallback.Accessible.name.indexOf("broken-widget") >= 0,
                   "assistive output identifies the failed widget type")
            compare(host.status, Loader.Ready,
                    "a second healthy host remains ready after one widget fails")
            failedHost.loadEnabled = false
        }
    }
}
