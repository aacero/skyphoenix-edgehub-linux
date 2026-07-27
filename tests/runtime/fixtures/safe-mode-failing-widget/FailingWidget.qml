import QtQuick

// Deliberately hostile Tier-0 fixture. A normal Hub session instantiates it,
// performs one observable loopback request, and then throws. Safe mode must not
// scan or instantiate it, so neither action can occur.
Item {
    property var store: null
    property string instanceId: ""
    property var request: null

    // WidgetHost injects store/instanceId in Loader.onLoaded, after this item's
    // Component.onCompleted. Defer the probe so it observes the real host
    // contract instead of racing it with an empty URL.
    Timer {
        interval: 100
        running: true
        repeat: false
        onTriggered: {
            var settings = store && store.settingsFor ? store.settingsFor(instanceId) : ({})
            request = new XMLHttpRequest()
            request.open("GET", String(settings.probeUrl || ""), true)
            request.send()
        }
    }

    Timer {
        interval: 350
        running: true
        repeat: false
        onTriggered: {
            throw new Error("INTENTIONALLY_FAILING_SAFE_MODE_RUNTIME_WIDGET")
        }
    }
}
