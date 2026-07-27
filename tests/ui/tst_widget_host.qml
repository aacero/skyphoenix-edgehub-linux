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
    property int safeModeInstantiationAttempts: 0
    property int safeModeEnsureCalls: 0

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
    QtObject {
        id: fakePriorityAlerts
        function showPriorityAlert(request) { return request !== null }
    }
    QtObject {
        id: safeModeStore
        property int revision: 0
        function ensureSettings(id, defaults) {
            root.safeModeEnsureCalls++
        }
        function settingsFor(id) { return ({}) }
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
            property var priorityAlerts: null
            property int tick: -1
            property bool chromeless: false
            property bool showHeader: true
            property string titleOverride: ""
            property string accentName: ""
            property string cardBackdrop: ""
            property int flushCalls: 0
            property bool pendingChanges: false
            function hasPendingChanges() { return pendingChanges }
            function flush() {
                flushCalls++
                pendingChanges = false
                return true
            }
            MouseArea { anchors.fill: parent; onClicked: root.taps++ }
        }
    }

    Component {
        id: runtimeFaultComponent
        Item {
            property int successfulActions: 0
            signal faultRequested()
            onFaultRequested: {
                throw new Error("INJECTED_WIDGET_RUNTIME_FAULT")
            }
            function healthyAction() {
                successfulActions++
            }
        }
    }
    Component {
        id: pendingWithoutFlushComponent
        Item {
            property bool pendingChanges: true
            function hasPendingChanges() { return pendingChanges }
        }
    }
    Component {
        id: startupFaultComponent
        Item {
            Component.onCompleted: {
                root.safeModeInstantiationAttempts++
                throw new Error("INTENTIONALLY_FAILING_SAFE_MODE_WIDGET")
            }
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
        priorityAlerts: fakePriorityAlerts
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

    W.WidgetHost {
        id: runtimeFaultHost
        width: 360
        height: 220
        x: root.width + 400
        widgetId: "runtime-fault-1"
        widgetType: "runtime-fault-probe"
        widgetComponent: runtimeFaultComponent
        acceptsInput: true
    }

    W.WidgetHost {
        id: pendingWithoutFlushHost
        width: 360
        height: 220
        x: root.width + 780
        widgetId: "missing-flush-1"
        widgetType: "missing-flush-probe"
        widgetComponent: pendingWithoutFlushComponent
        acceptsInput: true
    }

    W.WidgetHost {
        id: safeModeHost
        width: 360
        height: 220
        x: root.width + 1160
        sessionEnabled: false
        widgetId: "safe-mode-fault-1"
        widgetType: "deliberately-failing"
        widgetComponent: startupFaultComponent
        store: safeModeStore
        catalog: fakeCatalog
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
            compare(host.item.priorityAlerts, fakePriorityAlerts)
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

        function test_clean_shutdown_flushes_a_widget_local_buffer() {
            compare(host.item.flushCalls, 0)
            compare(host.hasPendingState(), false,
                    "a clean widget does not report a local buffer")
            host.item.pendingChanges = true
            compare(host.hasPendingState(), true,
                    "WidgetHost exposes a loaded widget's pending buffer")
            verify(host.flushPendingState(), "a widget with flush() reports that it was flushed")
            compare(host.item.flushCalls, 1, "WidgetHost invoked the loaded widget's flush() exactly once")
            compare(host.hasPendingState(), false,
                    "a successful flush clears the pending contract")
            verify(failedHost.flushPendingState(),
                   "an unloaded widget is a successful no-op during shutdown")
            compare(failedHost.hasPendingState(), false,
                    "an unloaded widget cannot claim a pending local buffer")
            compare(pendingWithoutFlushHost.hasPendingState(), true,
                    "a widget can expose a pending buffer without a flush hook")
            verify(!pendingWithoutFlushHost.flushPendingState(),
                   "a real pending buffer without a flush hook fails closed")
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

        function test_runtime_exception_aborts_only_the_throwing_handler() {
            tryVerify(function () {
                return runtimeFaultHost.status === Loader.Ready
                        && runtimeFaultHost.item !== null
            }, 3000)
            ignoreWarning(/.*INJECTED_WIDGET_RUNTIME_FAULT.*/)
            runtimeFaultHost.item.faultRequested()

            compare(runtimeFaultHost.status, Loader.Ready,
                    "a handler exception does not unload the throwing widget")
            compare(runtimeFaultHost.loadFailed, false,
                    "a runtime exception is not misclassified as a Loader failure")
            runtimeFaultHost.item.healthyAction()
            compare(runtimeFaultHost.item.successfulActions, 1,
                    "the throwing widget remains usable after the failed handler")
            compare(host.status, Loader.Ready,
                    "a sibling widget remains ready after the runtime exception")
            verify(root.visible,
                   "the containing page remains alive after the runtime exception")
        }

        function test_safe_mode_never_instantiates_deliberately_failing_widget() {
            root.safeModeInstantiationAttempts = 0
            root.safeModeEnsureCalls = 0
            safeModeHost.sessionEnabled = false
            wait(100)

            compare(safeModeHost.status, Loader.Null,
                    "safe mode leaves the widget Loader unopened")
            compare(safeModeHost.item, null,
                    "safe mode creates no widget item")
            compare(root.safeModeInstantiationAttempts, 0,
                    "the deliberately failing component never executes")
            compare(root.safeModeEnsureCalls, 0,
                    "safe mode does not seed or persist widget settings")
            var paused = findByObjectName(safeModeHost, "safeModeWidgetPlaceholder")
            verify(paused !== null && paused.visible,
                   "the saved tile is represented by a visible session-only pause surface")

            // Non-vacuity control: the same component executes and throws as
            // soon as the session gate is opened.
            ignoreWarning(/.*INTENTIONALLY_FAILING_SAFE_MODE_WIDGET.*/)
            safeModeHost.sessionEnabled = true
            tryCompare(root, "safeModeInstantiationAttempts", 1, 3000)
            compare(safeModeHost.status, Loader.Ready,
                    "outside safe mode the same widget is instantiated")
            verify(root.safeModeEnsureCalls > 0,
                   "normal mode seeds settings through the existing host contract")

            safeModeHost.sessionEnabled = false
            tryCompare(safeModeHost, "status", Loader.Null, 3000)
        }
    }
}
