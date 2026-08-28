import QtQuick
import QtTest

// Smoke + boundary coverage for every widget: each must load, produce a
// non-zero-sized item (guards the nested-Loader "invisible widget" pitfall),
// and survive extreme/missing metrics without throwing - in BOTH compact and
// expanded modes.
Item {
    id: container
    width: 400
    height: 820

    // Every self-contained widget (excludes shared controls + SettingsPanel,
    // which is not a contract widget).
    readonly property var allWidgets: [
        "ClockWidget.qml", "AnalogClockWidget.qml", "MoonWidget.qml",
        "CpuWidget.qml", "GpuWidget.qml", "RamWidget.qml", "NetWidget.qml",
        "DiskWidget.qml", "SensorsWidget.qml", "FocusWidget.qml",
        "TasksWidget.qml", "RightNowWidget.qml", "NotesWidget.qml",
        "MediaWidget.qml", "CalendarWidget.qml", "WeatherWidget.qml",
        "QuoteWidget.qml", "HabitWidget.qml", "HydrationWidget.qml",
        "BreakWidget.qml", "CountdownWidget.qml", "EndOfDayWidget.qml",
        "SystemsWidget.qml"
    ]

    // Metrics fixtures: nominal, all-zero, saturated, and missing keys.
    readonly property var metricSets: ({
        "nominal": '{"cpu_usage_percent":42.5,"cpu_temp_celsius":55,"ram_usage_percent":63,"ram_total_bytes":34359738368,"ram_used_bytes":21646635008,"cpu_core_count":16,"gpu_usage_percent":30,"gpu_temp_celsius":48,"net_rx_bytes_per_sec":1048576,"net_tx_bytes_per_sec":524288,"disk_total_bytes":1099511627776,"disk_used_bytes":549755813888,"disk_usage_percent":50}',
        "zero": '{"cpu_usage_percent":0,"cpu_temp_celsius":0,"ram_usage_percent":0,"ram_total_bytes":0,"ram_used_bytes":0,"cpu_core_count":0,"gpu_usage_percent":0,"net_rx_bytes_per_sec":0,"net_tx_bytes_per_sec":0,"disk_total_bytes":0,"disk_used_bytes":0,"disk_usage_percent":0}',
        "saturated": '{"cpu_usage_percent":100,"cpu_temp_celsius":110,"ram_usage_percent":100,"ram_total_bytes":137438953472,"ram_used_bytes":137438953472,"cpu_core_count":128,"gpu_usage_percent":100,"gpu_temp_celsius":95,"net_rx_bytes_per_sec":1250000000,"net_tx_bytes_per_sec":1250000000,"disk_total_bytes":8796093022208,"disk_used_bytes":8796093022208,"disk_usage_percent":100}',
        "empty": '{}'
    })

    Component {
        id: harnessComp
        WidgetHarness { anchors.fill: parent }
    }

    TestCase {
        id: tc
        name: "WidgetSmoke"
        when: windowShown

        function _cases() {
            var rows = []
            var modes = [false, true]
            var metricKeys = ["nominal", "zero", "saturated", "empty"]
            for (var i = 0; i < container.allWidgets.length; i++)
                for (var m = 0; m < modes.length; m++)
                    for (var k = 0; k < metricKeys.length; k++)
                        rows.push({ tag: container.allWidgets[i] + (modes[m] ? ":expanded" : ":compact") + ":" + metricKeys[k],
                                    file: container.allWidgets[i], expanded: modes[m], metrics: metricKeys[k] })
            return rows
        }

        function test_widget_data() { return _cases() }

        function test_widget(row) {
            var h = createTemporaryObject(harnessComp, container, {
                widgetFile: row.file,
                expanded: row.expanded,
                metricsJson: container.metricSets[row.metrics]
            })
            verify(h !== null, "harness created for " + row.tag)
            tryVerify(function () { return h.ready }, 3000, "widget loaded: " + row.tag)
            verify(h.item !== null, "item exists: " + row.tag)
            // The invisible-widget guard: a live tile must have real extent.
            verify(h.item.width > 0 && h.item.height > 0,
                   "non-zero size: " + row.tag + " (" + h.item.width + "x" + h.item.height + ")")
            // Let timers/bindings settle one frame to surface runtime JS errors.
            wait(16)
        }
    }
}
