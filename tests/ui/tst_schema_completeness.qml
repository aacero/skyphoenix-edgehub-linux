import QtQuick
import QtTest
import "../../ui/qml" as App


Item {
    width: 100
    height: 100

    App.WidgetConfigSchema { id: schema }

    function field(type, key) {
        var sections = schema.schemaFor(type).sections
        for (var i = 0; i < sections.length; i++) {
            var fields = sections[i].fields || []
            for (var j = 0; j < fields.length; j++)
                if (fields[j].key === key) return fields[j]
        }
        return null
    }

    TestCase {
        name: "SchemaCompleteness"
        when: windowShown

        function test_less_common_fields_remain_configurable() {
            verify(field("clock", "datePattern") !== null, "datePattern")
            verify(field("clock", "localeName") !== null, "localeName")
            verify(field("clock", "secondaryZones") !== null, "secondaryZones")
            verify(field("moon", "showAccuracyNote") !== null, "showAccuracyNote")
            verify(field("net", "scaleMode") !== null, "scaleMode")
            verify(field("net", "interfaceName") !== null, "interfaceName")
            compare(field("net", "interfaceName").type, "select",
                    "network selection uses discovered identities")
            compare(field("disk", "mountPath").type, "select",
                    "disk selection uses discovered mounts")
            verify(field("disk", "showActivity") !== null, "showActivity")
            verify(field("sensors", "showGpuPower") !== null, "showGpuPower")
            verify(field("sensors", "showGpuFan") !== null, "showGpuFan")
            verify(field("sensors", "rowOrder") !== null, "rowOrder")
            compare(field("sensors", "rowOrder").type, "reorder",
                    "sensor order uses direct manipulation")
            compare(field("sensors", "gpuDevice").type, "select",
                    "sensor GPU selection uses discovered identities")
            verify(field("sensors", "warnCpu") !== null, "warnCpu")
            verify(field("sensors", "warnGpu") !== null, "warnGpu")
            verify(field("sensors", "warnRam") !== null, "warnRam")
            verify(field("sensors", "warnDisk") !== null, "warnDisk")
            verify(field("sensors", "warnCpuTemp") !== null, "warnCpuTemp")
            verify(field("sensors", "warnGpuTemp") !== null, "warnGpuTemp")
            verify(field("focus", "longBreakMin") !== null, "longBreakMin")
            verify(field("focus", "longBreakEvery") !== null, "longBreakEvery")
            verify(field("focus", "behaviorProfile") !== null, "behaviorProfile")
            verify(field("focus", "autoStartFocus") !== null, "autoStartFocus")
            verify(field("tasks", "displayMode") !== null, "displayMode")
            verify(field("break", "snoozeMin") !== null, "snoozeMin")
            verify(field("break", "workStartHour") !== null, "workStartHour")
            verify(field("break", "workEndHour") !== null, "workEndHour")
            verify(field("countdown", "afterEvent") !== null, "afterEvent")
            verify(field("habit", "cadence") !== null, "cadence")
            verify(field("habit", "activeDays") !== null, "activeDays")
            verify(field("habit", "paused") !== null, "paused")
            verify(field("nownext", "bufferMin") !== null, "bufferMin")
            verify(field("rightnow", "completionStyle") !== null, "completionStyle")
            verify(field("systems", "hosts") !== null, "hosts")
            verify(field("systems", "defaultPort") !== null, "defaultPort")
            verify(field("systems", "warnCpu") !== null, "warnCpu")
            verify(field("systems", "warnRam") !== null, "warnRam")
            verify(field("systems", "warnDisk") !== null, "warnDisk")
            verify(field("systems", "pollSec") !== null, "pollSec")
            verify(field("grafana", "url") !== null, "url")
            verify(field("grafana", "query") !== null, "query")
            verify(field("grafana", "rangeSec") !== null, "rangeSec")
            verify(field("grafana", "pollSec") !== null, "pollSec")
            verify(field("grafana", "chartType") !== null, "chartType")
            verify(field("grafana", "yMin") !== null, "yMin")
            verify(field("grafana", "yMax") !== null, "yMax")
        }
    }
}
