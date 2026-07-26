import QtQuick
import QtQuick.Layouts

// Sensor cluster with explicit sources, availability, and semantic states.
// All values are real metrics from the Rust core.
//
// Sizing (W1 wave 2a): the Repeater's STATIC label model and its long-lived
// delegates are load-bearing (identity-pinned: values ease, delegates never
// rebuild). Per-size layout therefore only RESHAPES the same rows:
//   • Small supported - a prioritized subset plus a disclosed hidden-row count.
//   • 1x1 (baseline)  - header + readable rows with state and source context.
//   • wide            - the SAME delegates flow into two columns (GridLayout
//                       `columns` flips; no delegate is recreated).
//   • tall            - single column, thicker bars + larger type.
//   • full (overlay)  - unchanged.
WidgetChrome {
    id: w
    property var metrics: ({})
    property bool expanded: false
    property bool active: true
    property var store: null
    property string instanceId: ""

    title: "Sensors"; iconName: "sensors"; accentColor: theme.catSystem
    showHeader: true

    // Live per-instance config (see WidgetConfigSchema "sensors").
    readonly property var cfg: {
        var _ = store ? store.revision : 0
        return (store && instanceId) ? JSON.parse(JSON.stringify(store.settingsFor(instanceId))) : ({})
    }
    readonly property bool showCpu: cfg.showCpu !== undefined ? cfg.showCpu : true
    readonly property bool showGpu: cfg.showGpu !== undefined ? cfg.showGpu : true
    readonly property bool showRam: cfg.showRam !== undefined ? cfg.showRam : true
    readonly property bool showDisk: cfg.showDisk !== undefined ? cfg.showDisk : true
    readonly property bool showTemps: cfg.showTemps !== undefined ? cfg.showTemps : true
    readonly property bool showGpuPower: cfg.showGpuPower !== undefined ? cfg.showGpuPower : true
    readonly property bool showGpuFan: cfg.showGpuFan !== undefined ? cfg.showGpuFan : true
    readonly property real warnCpu: Number(cfg.warnCpu !== undefined ? cfg.warnCpu : 85)
    readonly property real warnGpu: Number(cfg.warnGpu !== undefined ? cfg.warnGpu : 85)
    readonly property real warnRam: Number(cfg.warnRam !== undefined ? cfg.warnRam : 85)
    readonly property real warnDisk: Number(cfg.warnDisk !== undefined ? cfg.warnDisk : 90)
    readonly property real warnCpuTemp: Number(cfg.warnCpuTemp !== undefined ? cfg.warnCpuTemp : 80)
    readonly property real warnGpuTemp: Number(cfg.warnGpuTemp !== undefined ? cfg.warnGpuTemp : 80)
    readonly property string gpuDevice: String(cfg.gpuDevice || "auto")

    readonly property var defaultOrder: [
        "cpu", "gpu", "ram", "disk", "cpu_temp", "gpu_temp", "gpu_power", "gpu_fan"
    ]
    readonly property var rowLabels: ({
        cpu: "CPU", gpu: "GPU", ram: "RAM", disk: "DISK",
        cpu_temp: "CPU °", gpu_temp: "GPU °", gpu_power: "GPU W", gpu_fan: "GPU RPM"
    })
    readonly property var orderedIds: {
        var raw = cfg.rowOrder
        var requested = Array.isArray(raw) ? raw : String(raw || "").split(",")
        var result = []
        function canonical(value) {
            var cleaned = String(value || "").trim()
            if (w.defaultOrder.indexOf(cleaned) >= 0) return cleaned
            var upper = cleaned.toUpperCase()
            for (var key in w.rowLabels)
                if (String(w.rowLabels[key]).toUpperCase() === upper) return key
            return ""
        }
        function add(value) {
            var id = canonical(value)
            if (id.length && result.indexOf(id) < 0) result.push(id)
        }
        for (var i = 0; i < requested.length; i++) add(requested[i])
        for (var j = 0; j < w.defaultOrder.length; j++) add(w.defaultOrder[j])
        return result
    }

    readonly property var primaryGpu: {
        var devices = Array.isArray(metrics.gpu_devices) ? metrics.gpu_devices : []
        var wanted = w.gpuDevice === "auto" ? String(metrics.gpu_primary_id || "")
                                            : w.gpuDevice
        for (var i = 0; i < devices.length; i++)
            if (String(devices[i].id || "") === wanted) return devices[i]
        if (w.gpuDevice !== "auto") return null
        return devices.length ? devices[0] : null
    }
    readonly property bool selectedGpuMissing: gpuDevice !== "auto" && primaryGpu === null
    readonly property string gpuIdentity: primaryGpu
                                          ? String(primaryGpu.name || primaryGpu.vendor
                                                   || primaryGpu.id || "GPU")
                                            + " (" + String(primaryGpu.id || "?") + ")"
                                          : gpuDevice === "auto" ? "DRM GPU"
                                                                 : gpuDevice

    function num(x) { return (x === undefined || x === null) ? -1 : x }
    function stateFor(value, available, warning, critical) {
        if (!available) return "Unavailable"
        if (value >= critical) return "Critical"
        if (value >= warning) return "Warning"
        return "Normal"
    }
    function stateShort(state) {
        if (state === "Critical") return "CRIT"
        if (state === "Warning") return "WARN"
        if (state === "Unavailable") return "N/A"
        return "OK"
    }
    function stateColor(state, base) {
        if (state === "Critical") return theme.error
        if (state === "Warning") return theme.warning
        if (state === "Unavailable") return theme.textTertiary
        return w.accentName !== "" ? w.effAccent : base
    }
    property var rows: {
        var ct = num(metrics.cpu_temp_celsius)
        var gpuUsage = w.primaryGpu && w.primaryGpu.usage_percent !== undefined
                       ? num(w.primaryGpu.usage_percent) : num(metrics.gpu_usage_percent)
        var gt = w.primaryGpu && w.primaryGpu.temperature_celsius !== undefined
                 ? num(w.primaryGpu.temperature_celsius) : num(metrics.gpu_temp_celsius)
        var gpuPower = w.primaryGpu && w.primaryGpu.power_watts !== undefined
                       && w.primaryGpu.power_watts !== null ? Number(w.primaryGpu.power_watts) : -1
        var gpuFan = w.primaryGpu && w.primaryGpu.fan_rpm !== undefined
                     && w.primaryGpu.fan_rpm !== null ? Number(w.primaryGpu.fan_rpm) : -1
        var powerMax = w.primaryGpu && Number(w.primaryGpu.power_cap_watts || 0) > 0
                       ? Number(w.primaryGpu.power_cap_watts)
                       : Math.max(100, gpuPower > 0 ? gpuPower * 1.25 : 100)
        var fanMax = w.primaryGpu && Number(w.primaryGpu.fan_max_rpm || 0) > 0
                     ? Number(w.primaryGpu.fan_max_rpm)
                     : Math.max(3000, gpuFan > 0 ? gpuFan * 1.25 : 3000)
        var gpuTempCritical = w.primaryGpu
                              && Number(w.primaryGpu.temperature_critical_celsius || 0) > 0
                              ? Number(w.primaryGpu.temperature_critical_celsius)
                              : w.warnGpuTemp + 10
        var cpuReady = metrics.cpu_usage_available !== undefined
                       ? metrics.cpu_usage_available === true : num(metrics.cpu_usage_percent) >= 0
        var ramReady = metrics.ram_metrics_available !== undefined
                       ? metrics.ram_metrics_available === true : num(metrics.ram_usage_percent) >= 0
        var diskReady = metrics.disk_metrics_available !== undefined
                        ? metrics.disk_metrics_available === true : (metrics.disk_total_bytes || 0) > 0
        var gpuReady = !w.selectedGpuMissing && gpuUsage >= 0
        function make(id, value, max, unit, base, enabled, available, source,
                      reason, warning, critical) {
            var state = w.stateFor(value, available, warning, critical)
            return {
                id: id, lbl: w.rowLabels[id], val: value, max: max, unit: unit,
                col: w.stateColor(state, base), enabled: enabled,
                available: available, source: source, reason: reason,
                state: state, stateLabel: w.stateShort(state)
            }
        }
        var cpuTempSource = Array.isArray(metrics.cpu_temperature_sensors)
                            && metrics.cpu_temperature_sensors.length
                            ? String(metrics.cpu_temperature_sensors[0].label
                                     || "CPU temperature")
                            : "CPU temperature"
        var powerSource = "GPU power · " + w.gpuIdentity + (w.primaryGpu
                          && Number(w.primaryGpu.power_cap_watts || 0) > 0
                          ? " · cap " + powerMax.toFixed(0) + " W" : "")
        var fanSource = "GPU fan · " + w.gpuIdentity + (w.primaryGpu
                        && Number(w.primaryGpu.fan_max_rpm || 0) > 0
                        ? " · max " + fanMax.toFixed(0) + " rpm" : "")
        var definitions = ({
            cpu: make("cpu", num(metrics.cpu_usage_percent), 100, "%", theme.catSystem,
                      w.showCpu, cpuReady, "kernel CPU delta",
                      String(metrics.cpu_sample_status || "CPU sample unavailable"),
                      w.warnCpu, Math.min(100, w.warnCpu + 10)),
            gpu: make("gpu", gpuUsage, 100, "%", theme.catGaming, w.showGpu, gpuReady,
                      w.gpuIdentity, w.selectedGpuMissing ? "Selected GPU is offline"
                      : String(metrics.gpu_unavailable_reason || "GPU utilization unavailable"),
                      w.warnGpu, Math.min(100, w.warnGpu + 10)),
            ram: make("ram", num(metrics.ram_usage_percent), 100, "%", theme.catProductivity,
                      w.showRam, ramReady, "/proc/meminfo",
                      String(metrics.ram_unavailable_reason || "Memory sample unavailable"),
                      w.warnRam, Math.min(100, w.warnRam + 10)),
            disk: make("disk", num(metrics.disk_usage_percent), 100, "%", theme.catInfo,
                       w.showDisk, diskReady, "root filesystem",
                       String(metrics.disk_unavailable_reason || "Disk sample unavailable"),
                       w.warnDisk, Math.min(100, w.warnDisk + 10)),
            cpu_temp: make("cpu_temp", ct, 110, "°C", theme.catSystem, w.showTemps,
                           ct >= 0, cpuTempSource, "CPU temperature sensor unavailable",
                           w.warnCpuTemp, w.warnCpuTemp + 10),
            gpu_temp: make("gpu_temp", gt, Math.max(110, gpuTempCritical), "°C",
                           theme.catGaming, w.showTemps, !w.selectedGpuMissing && gt >= 0,
                           w.gpuIdentity, w.selectedGpuMissing ? "Selected GPU is offline"
                           : "GPU temperature sensor unavailable",
                           Math.min(w.warnGpuTemp, gpuTempCritical - 1), gpuTempCritical),
            gpu_power: make("gpu_power", gpuPower, powerMax, " W", theme.catGaming,
                            w.showGpuPower, !w.selectedGpuMissing && gpuPower >= 0,
                            powerSource, w.selectedGpuMissing ? "Selected GPU is offline"
                            : "GPU power sensor unavailable", powerMax * 0.9, powerMax),
            gpu_fan: make("gpu_fan", gpuFan, fanMax, " rpm", theme.catGaming,
                          w.showGpuFan, !w.selectedGpuMissing && gpuFan >= 0,
                          fanSource, w.selectedGpuMissing ? "Selected GPU is offline"
                          : "GPU fan sensor unavailable", fanMax * 0.9, fanMax)
        })
        var out = []
        for (var i = 0; i < w.orderedIds.length; i++) {
            var row = definitions[w.orderedIds[i]]
            if (row && row.enabled) out.push(row)
        }
        return out
    }

    readonly property int availableRowCount: {
        var count = 0
        for (var i = 0; i < rows.length; i++) if (rows[i].available) count++
        return count
    }
    status: rows.length === 0 ? "disabled"
            : availableRowCount === 0 ? "unavailable"
            : availableRowCount < rows.length ? "partial" : "live"
    statusColor: availableRowCount === rows.length && rows.length > 0
                 ? theme.textSecondary : theme.warning

    // ── Per-size metrics (the rows scale; their structure never changes) ────
    readonly property bool horiz: sizeClass === "wide"
    readonly property bool smallFootprint: !expanded
                                           && (height < 340
                                               || (width < 380 && height < 500))
    readonly property bool roomy: (sizeClass === "tall" || sizeClass === "wide")
                                  && Math.min(width, height) >= 480
    readonly property bool showSources: expanded || roomy || Math.min(width, height) >= 600
    readonly property int visibleRowLimit: smallFootprint ? 4 : rows.length
    readonly property var visibleRowIds: {
        var result = []
        for (var i = 0; i < rows.length && result.length < visibleRowLimit; i++)
            result.push(rows[i].id)
        return result
    }
    readonly property int hiddenRowCount: Math.max(0, rows.length - visibleRowIds.length)
    // Column width the row type is sized against (wide splits the box in two).
    readonly property real colW: horiz ? width / 2 : width
    readonly property real rowFont: expanded ? theme.fontLabel
        : Math.max(theme.fontMinimum, Math.min(colW * 0.045, height * 0.035, 22))
    readonly property real barH: expanded ? 12
        : Math.max(6, Math.min(height * 0.022, 14))
    readonly property real labelW: expanded ? 62
        : Math.max(92, Math.min(colW * 0.22, 112))
    readonly property real valueW: expanded ? 64
        : Math.max(74, Math.min(colW * 0.19, 112))

    GridLayout {
        anchors.fill: parent
        anchors.bottomMargin: w.hiddenRowCount > 0 ? theme.fontLabel + theme.spacingSm : 0
        // Wide reflows the SAME six delegates into two columns; flipping
        // `columns` only re-lays-out - it does not recreate delegates, so the
        // eased bars and colour cross-fades survive a resize too.
        columns: w.horiz ? 2 : 1
        rowSpacing: w.expanded ? 12 : 5
        columnSpacing: theme.spacingLg
        Repeater {
            // STABLE DELEGATES (owner-reported clunk). The model is a literal list
            // of row labels, so it is evaluated ONCE and the six delegates live for
            // the widget's whole life. Binding the Repeater to `w.rows` instead -
            // a fresh JS array every metrics tick - destroyed and recreated every
            // delegate ~2s, so nothing survived long enough to animate and the
            // whole widget flickered through reconstruction. Now a tick only moves
            // the bound VALUES below; the bar glides and the colour cross-fades.
            model: w.orderedIds
            delegate: RowLayout {
                id: sensorRow
                required property string modelData
                // Live lookup into the derived rows (re-evaluates on every metrics/
                // config/accent change); null while this row is hidden.
                readonly property var row: {
                    var rs = w.rows
                    for (var i = 0; i < rs.length; i++)
                        if (rs[i].id === sensorRow.modelData) return rs[i]
                    return null
                }
                visible: row !== null && w.visibleRowIds.indexOf(sensorRow.modelData) >= 0
                Accessible.name: row ? row.lbl + ", "
                                           + (row.available
                                              ? row.val.toFixed(0) + row.unit : row.reason)
                                           + ", " + row.state + ", source " + row.source : ""
                // Compact tiles are height-starved (a 120px tile leaves ~64px of
                // body): let every row share that height so all six stay fully
                // visible instead of overflowing the clipped body (S12). Expanded
                // tiles keep their natural, top-aligned rows.
                Layout.fillWidth: true; Layout.fillHeight: !w.expanded
                spacing: theme.spacingSm
                Text { text: w.rowLabels[sensorRow.modelData] || ""; font.family: theme.fontMono; color: theme.textPrimary
                    font.pixelSize: w.rowFont; Layout.preferredWidth: Math.round(w.labelW)
                    Layout.fillHeight: !w.expanded; verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight; fontSizeMode: Text.VerticalFit; minimumPixelSize: theme.fontMinimum }
                Rectangle {
                    Layout.fillWidth: true; Layout.preferredHeight: Math.round(w.barH)
                    radius: height / 2; color: theme.cardBorder
                    Rectangle {
                        height: parent.height; radius: height / 2
                        color: sensorRow.row && sensorRow.row.available ? sensorRow.row.col : "transparent"
                        width: sensorRow.row && sensorRow.row.available
                               ? parent.width * Math.min(sensorRow.row.val / sensorRow.row.max, 1) : 0
                        // A 1° temperature rise moves ONLY this bar, smoothly - the
                        // token collapses both eases to an instant jump under
                        // reduce-motion. Threshold colour (cool→warn→hot) cross-fades
                        // instead of hard-cutting for the same reason.
                        Behavior on width { NumberAnimation { duration: theme.motionValue; easing.type: Easing.OutCubic } }
                        Behavior on color { ColorAnimation { duration: theme.motionValue } }
                    }
                }
                Text { text: sensorRow.row
                              ? sensorRow.row.available
                                ? sensorRow.row.val.toFixed(0) + sensorRow.row.unit : "N/A" : ""
                    font.family: theme.fontMono
                    color: sensorRow.row && sensorRow.row.available
                           ? sensorRow.row.col : theme.textTertiary; font.pixelSize: w.rowFont
                    horizontalAlignment: Text.AlignRight; Layout.preferredWidth: Math.round(w.valueW)
                    Layout.fillHeight: !w.expanded; verticalAlignment: Text.AlignVCenter
                    fontSizeMode: Text.VerticalFit; minimumPixelSize: theme.fontMinimum }
                Text {
                    visible: sensorRow.row !== null
                    text: sensorRow.row ? sensorRow.row.stateLabel : ""
                    color: sensorRow.row ? sensorRow.row.col : theme.textSecondary
                    font.pixelSize: w.rowFont
                    font.bold: sensorRow.row && sensorRow.row.state !== "Normal"
                    horizontalAlignment: Text.AlignHCenter
                    Layout.preferredWidth: Math.max(48, w.rowFont * 3.1)
                }
                Text {
                    visible: w.showSources && sensorRow.row !== null
                    text: sensorRow.row
                          ? sensorRow.row.available ? sensorRow.row.source : sensorRow.row.reason : ""
                    color: sensorRow.row && sensorRow.row.available
                           ? theme.textPrimary : theme.warning
                    font.pixelSize: w.roomy ? theme.fontLabel : theme.fontMinimum
                    Layout.preferredWidth: w.roomy
                        ? Math.min(280, Math.max(210, w.colW * 0.36))
                        : Math.min(250, Math.max(190, w.colW * 0.30))
                    Layout.fillHeight: !w.expanded
                    verticalAlignment: Text.AlignVCenter
                    wrapMode: Text.WordWrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                }
            }
        }
    }

    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        visible: w.hiddenRowCount > 0
        text: "+" + w.hiddenRowCount + " sensor"
              + (w.hiddenRowCount === 1 ? "" : "s") + " hidden in this size"
        color: theme.warning
        font.pixelSize: theme.fontLabel
        font.bold: true
        Accessible.name: text
    }

    // Every row disabled → an explicit placeholder instead of a blank card.
    Text {
        anchors.centerIn: parent
        visible: w.rows.length === 0
        width: parent.width - 2 * theme.spacingSm
        text: "No sensors enabled"
        color: theme.textSecondary
        font.family: theme.fontDisplay
        font.pixelSize: w.expanded ? theme.fontLabel : theme.fontMinimum
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        elide: Text.ElideRight
    }
}
