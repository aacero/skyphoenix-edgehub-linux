import QtQuick
import QtTest
import "../../ui/qml" as App
import "../../ui/qml/widgets" as W

Item {
    id: root
    width: 1000
    height: 260

    property alias theme: themeImpl
    App.Theme { id: themeImpl }
    property var buckets: ({})
    QtObject {
        id: store
        property int revision: 0
        function ensureSettings(id, defaults) {
            if (root.buckets[id] === undefined) root.buckets[id] = defaults || ({})
        }
        function settingsFor(id) { return root.buckets[id] || ({}) }
        function patchSettings(id, patch) {
            ensureSettings(id, {})
            for (var key in patch) root.buckets[id][key] = patch[key]
            revision++
        }
    }
    property alias widgetStore: store
    W.NetHub { id: gate; offline: true }

    function source(name) { return Qt.resolvedUrl("../../ui/qml/widgets/" + name) }

    Row {
        anchors.fill: parent
        spacing: 10

        W.WidgetHost {
            id: httpHost; width: 240; height: 240
            widgetId: "http-passive"; widgetType: "httpjson"
            widgetSource: root.source("HttpJsonWidget.qml")
            store: root.widgetStore; ensureSettings: false; netHub: gate
            driverActive: false; acceptsInput: false
        }
        W.WidgetHost {
            id: kpiHost; width: 240; height: 240
            widgetId: "kpi-passive"; widgetType: "kpi"
            widgetSource: root.source("KpiWidget.qml")
            store: root.widgetStore; ensureSettings: false; netHub: gate
            driverActive: false; acceptsInput: false
        }
        W.WidgetHost {
            id: calendarHost; width: 240; height: 240
            widgetId: "calendar-passive"; widgetType: "calendar"
            widgetSource: root.source("CalendarWidget.qml")
            store: root.widgetStore; ensureSettings: false; netHub: gate
            driverActive: false; acceptsInput: false
        }
        W.WidgetHost {
            id: weatherHost; width: 240; height: 240
            widgetId: "weather-passive"; widgetType: "weather"
            widgetSource: root.source("WeatherWidget.qml")
            store: root.widgetStore; ensureSettings: false; netHub: gate
            driverActive: false; acceptsInput: false
        }
    }

    TestCase {
        name: "WidgetHostNetwork"
        when: windowShown

        function initTestCase() {
            tryVerify(function () {
                return httpHost.status === Loader.Ready && kpiHost.status === Loader.Ready
                       && calendarHost.status === Loader.Ready && weatherHost.status === Loader.Ready
            }, 5000)
            store.patchSettings("http-passive", { url: "https://status.example/value", mode: "value" })
            store.patchSettings("kpi-passive", { source: "http", url: "https://status.example/kpi" })
            store.patchSettings("calendar-passive", { url: "https://calendar.example/private.ics" })
            store.patchSettings("weather-passive", { lat: 48.2, lon: 16.37, place: "Vienna" })
            wait(20)
            compare(store.settingsFor("http-passive").url, "https://status.example/value")
            compare(httpHost.item.url, "https://status.example/value")
        }

        function init() {
            httpHost.driverActive = false
            kpiHost.driverActive = false
            calendarHost.driverActive = false
            weatherHost.driverActive = false
            gate.requests = 0
            gate.blocked = 0
            wait(10)
        }

        function cleanup() {
            httpHost.driverActive = false
            kpiHost.driverActive = false
            calendarHost.driverActive = false
            weatherHost.driverActive = false
        }

        function test_passive_hosts_never_attempt_a_refresh() {
            wait(500)
            compare(gate.requests, 0)
            compare(gate.blocked, 0, "inactive debounces ended without touching NetHub")
            compare(httpHost.item.active, false)
            compare(kpiHost.item.active, false)
            compare(calendarHost.item.active, false)
            compare(weatherHost.item.active, false)
        }

        function test_only_an_elected_host_attempts_refresh() {
            var before = gate.blocked
            httpHost.driverActive = true
            tryCompare(httpHost.item, "active", true)
            verify(httpHost.item.url.length > 0, "configured source reached the hosted widget")
            httpHost.item.refresh()
            compare(gate.blocked, before + 1,
                    "the elected host can reach the shared offline gate")
            httpHost.driverActive = false
            compare(kpiHost.item.active, false)
            compare(calendarHost.item.active, false)
            compare(weatherHost.item.active, false)
        }
    }
}
