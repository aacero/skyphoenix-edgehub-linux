import QtQuick
import "../../ui/qml" as App

// WidgetHarness - hosts a single widget from the compiled shipping resource
// collection exactly the way Dashboard.qml hosts it: a Loader whose loaded item
// inherits this component's context, so the widget resolves the `theme`, `store`
// and `media` globals via the scope chain. The official runner links ui/qml.qrc;
// a missing alias is therefore a real test failure. Load a widget by file name
// and the harness injects the standard contract props (store, instanceId,
// metrics, expanded, active, tick).
Item {
    id: harness

    // The widget file under ui/qml/widgets, e.g. "FocusWidget.qml".
    property string widgetFile: ""
    property string instanceId: "test-instance"
    property bool expanded: false
    property bool active: true

    // Metrics feed (widgets read the injected `metrics` var; a couple also read
    // the `metricsJson` global directly).
    property string metricsJson: "{}"
    property var metrics: {
        try { return JSON.parse(metricsJson || "{}") } catch (e) { return ({}) }
    }

    // Globals the widgets resolve by name.
    property alias theme: _theme
    App.Theme { id: _theme }
    App.DashboardStore { id: store }
    MockMedia { id: media }

    // Test-facing handles.
    property alias item: ld.item
    property alias storeCtl: store
    property alias mediaCtl: media
    readonly property bool ready: ld.status === Loader.Ready && ld.item !== null

    // Seed the store (as the app does via store.load()) BEFORE the widget loads,
    // so its `data` document is a live, mutable JS object. Gating the Loader on
    // this flag defers widget construction until seeding is done.
    property bool _seeded: false
    Component.onCompleted: { store.load("blank"); _seeded = true }

    Loader {
        id: ld
        anchors.fill: parent
        active: harness._seeded
        source: harness.widgetFile ? "qrc:/qml/" + harness.widgetFile : ""
        onLoaded: {
            if (!item) return
            store.ensureSettings(harness.instanceId, {})
            item.instanceId = harness.instanceId
            item.store = store
            item.expanded = Qt.binding(function () { return harness.expanded })
            item.metrics = Qt.binding(function () { return harness.metrics })
            if (item.hasOwnProperty("active"))
                item.active = Qt.binding(function () { return harness.active })
            if (item.hasOwnProperty("tick"))
                item.tick = 0
        }
    }
}
