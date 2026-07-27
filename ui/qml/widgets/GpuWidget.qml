import QtQuick
import QtQuick.Layouts

// GPU telemetry from the Rust DRM catalog. Every metrics tick rescans cards so
// driver reloads, eGPU reconnects, and hot-plug changes recover without restart.
WidgetChrome {
    id: w
    property var metrics: ({})
    property bool expanded: false
    property bool active: true
    property var store: null
    property string instanceId: ""

    title: "GPU"; iconName: "gpu"; accentColor: theme.catGaming
    showHeader: !micro
    Accessible.role: Accessible.StaticText
    Accessible.name: w.accessibleSummary

    readonly property var cfg: {
        var _ = store ? store.revision : 0
        return (store && instanceId) ? JSON.parse(JSON.stringify(store.settingsFor(instanceId))) : ({})
    }
    readonly property string gpuDevice: cfg.gpuDevice !== undefined ? cfg.gpuDevice : "auto"
    readonly property bool showTemp: cfg.showTemp !== undefined ? cfg.showTemp : true
    readonly property bool showHistory: cfg.showHistory !== undefined ? cfg.showHistory : true
    readonly property string graphStyle: cfg.graphStyle !== undefined ? cfg.graphStyle : "smooth"
    readonly property bool showDetails: cfg.showDetails !== undefined ? cfg.showDetails : true
    readonly property real warnTemp: cfg.warnTemp !== undefined ? cfg.warnTemp : 90

    function _selectDevice(frame) {
        var devices = frame.gpu_devices
        if (devices !== undefined && devices !== null) {
            var target = w.gpuDevice === "auto" ? String(frame.gpu_primary_id || "") : w.gpuDevice
            for (var i = 0; i < devices.length; i++)
                if (String(devices[i].id) === target) return devices[i]
            if (w.gpuDevice === "auto" && devices.length) return devices[0]
            return { id: target, unavailable_reason: "Selected GPU is not connected" }
        }
        return {
            id: "legacy",
            name: "GPU",
            usage_percent: frame.gpu_usage_percent,
            temperature_celsius: frame.gpu_temp_celsius,
            unavailable_reason: String(frame.gpu_unavailable_reason || "")
        }
    }

    readonly property var selectedDevice: _selectDevice(metrics)
    property bool avail: selectedDevice.usage_percent !== undefined
                         && selectedDevice.usage_percent !== null
                         && selectedDevice.usage_percent >= 0
    property real v: avail ? Number(selectedDevice.usage_percent) : 0
    readonly property bool tempAvailable: selectedDevice.temperature_celsius !== undefined
                                          && selectedDevice.temperature_celsius !== null
    property real temp: tempAvailable ? Number(selectedDevice.temperature_celsius) : 0
    readonly property string unavailableReason: {
        var reason = String(selectedDevice.unavailable_reason || "")
        return reason.length ? reason : (w.avail ? "" : "Utilization is unavailable")
    }
    readonly property bool selectedOffline:
        w.gpuDevice !== "auto" && w.unavailableReason === "Selected GPU is not connected"
    readonly property string capabilityState:
        w.avail ? "supported" : (w.selectedOffline ? "disconnected" : "unsupported")
    readonly property string deviceName: String(selectedDevice.name || selectedDevice.id || "GPU")
    readonly property string selectedDeviceId: String(selectedDevice.id || "legacy")
    readonly property string vendorDriver: {
        var parts = []
        if (selectedDevice.vendor) parts.push(String(selectedDevice.vendor))
        if (selectedDevice.driver) parts.push(String(selectedDevice.driver))
        if (selectedDevice.device_type) parts.push(String(selectedDevice.device_type))
        return parts.join(" · ")
    }

    readonly property string alertLevel: {
        if (w.selectedOffline) return "disconnected"
        if (!w.avail) return "unsupported"
        if (w.tempAvailable && w.temp > w.warnTemp) return "critical"
        if (w.v > 92) return "critical"
        if (w.tempAvailable && w.temp > w.warnTemp - 17) return "warning"
        if (w.v > 75) return "warning"
        return "normal"
    }
    readonly property string alertText: {
        if (w.alertLevel === "disconnected") return "Selected GPU offline"
        if (w.alertLevel === "unsupported") return "Utilization unsupported"
        if (w.alertLevel === "critical")
            return w.tempAvailable && w.temp > w.warnTemp
                ? "Critical temperature" : "Critical load"
        if (w.alertLevel === "warning")
            return w.tempAvailable && w.temp > w.warnTemp - 17
                ? "High temperature" : "High load"
        return "Normal"
    }
    readonly property string accessibleSummary: {
        var parts = ["GPU", w.deviceName]
        parts.push(w.avail ? w.v.toFixed(0) + " percent utilization" : w.alertText)
        if (w.showTemp)
            parts.push(w.tempAvailable ? w.temp.toFixed(0) + " degrees Celsius"
                                       : "temperature unavailable")
        if (w.alertLevel !== "normal") parts.push(w.alertText)
        if (!w.avail && w.unavailableReason.length) parts.push(w.unavailableReason)
        return parts.join(", ")
    }
    status: {
        var temperature = (w.showTemp && w.tempAvailable) ? w.temp.toFixed(0) + "°C" : ""
        var state = w.alertLevel === "normal" ? "" : w.alertText
        // Narrow tall projections keep the exact temperature and severity but
        // avoid repeating a long thermal phrase in the constrained header.
        // accessibleSummary retains the full alert wording.
        if (w.width < 480 && state.length) {
            if (w.alertLevel === "unsupported") return "Unsupported"
            if (w.alertLevel === "disconnected") return "GPU offline"
            if (state === "Critical temperature")
                return temperature.length ? temperature + " critical" : "Temp critical"
            if (state === "High temperature")
                return temperature.length ? temperature + " high" : "High temp"
            return state === "Critical load" ? "Load critical" : state
        }
        return state.length ? (temperature.length ? temperature + " · " + state : state)
                            : temperature
    }
    statusColor: w.alertLevel === "critical" ? theme.error
                 : w.alertLevel === "warning" ? theme.warning
                 : theme.textSecondary
    function col(p) {
        if (w.tempAvailable) {
            if (w.temp > w.warnTemp) return theme.error
            if (w.temp > w.warnTemp - 17) return theme.warning
        }
        return p > 92 ? theme.error : p > 75 ? theme.warning : w.effAccent
    }

    function gb(bytes) { return (Number(bytes) / 1073741824).toFixed(1) }
    readonly property bool haveVram: Number(selectedDevice.vram_total_bytes || 0) > 0
    readonly property string vramText: {
        if (!w.haveVram) return ""
        var total = w.gb(selectedDevice.vram_total_bytes)
        var used = Number(selectedDevice.vram_used_bytes || 0)
        return used > 0 ? w.gb(used) + " / " + total + " GiB" : total + " GiB VRAM"
    }
    readonly property string powerText: selectedDevice.power_watts !== undefined
                                                && selectedDevice.power_watts !== null
                                         ? Number(selectedDevice.power_watts).toFixed(0) + " W" : ""
    readonly property string clockText: {
        var mhz = Number(selectedDevice.clock_mhz || 0)
        if (mhz <= 0) return ""
        return mhz >= 1000 ? (mhz / 1000).toFixed(2) + " GHz" : mhz.toFixed(0) + " MHz"
    }
    readonly property string fanText: selectedDevice.fan_rpm !== undefined
                                              && selectedDevice.fan_rpm !== null
                                       ? Number(selectedDevice.fan_rpm).toFixed(0) + " RPM" : ""
    readonly property var detailMetrics: {
        var result = []
        if (w.vramText.length)
            result.push({ label: "VRAM", value: w.vramText, source: "DRM memory info" })
        if (w.powerText.length)
            result.push({ label: "POWER", value: w.powerText,
                          source: String(selectedDevice.power_source || "DRM hwmon") })
        if (w.clockText.length)
            result.push({ label: "CLOCK", value: w.clockText, source: "DRM sysfs" })
        if (w.fanText.length)
            result.push({ label: "FAN", value: w.fanText,
                          source: String(selectedDevice.fan_source || "DRM hwmon") })
        return result
    }
    readonly property string missingTelemetryText: {
        if (w.selectedOffline) return "Reconnect this GPU or use Automatic selection."
        if (!w.avail) return w.unavailableReason
        var missing = []
        if (!w.haveVram) missing.push("VRAM")
        if (!w.powerText.length) missing.push("power")
        if (!w.clockText.length) missing.push("clock")
        if (!w.fanText.length) missing.push("fan")
        if (!missing.length) return "All reported telemetry is available."
        var provider = selectedDevice.driver ? String(selectedDevice.driver) : "the current driver"
        return "Not reported by " + provider + ": " + missing.join(", ")
    }
    readonly property bool roomyTile:
        !w.expanded && ((w.sizeClass === "tall" && w.height > 1000)
                        || (w.sizeClass === "wide" && w.width > 1000))
    readonly property var glanceDetails: w.micro || w.expanded ? [] : w.detailMetrics.slice(0, 4)
    readonly property string detailLine: {
        if (!w.avail && w.unavailableReason.length) return w.unavailableReason
        var parts = []
        if (w.vramText.length) parts.push(w.vramText)
        if (w.powerText.length) parts.push(w.powerText)
        if (w.clockText.length) parts.push(w.clockText)
        if (w.fanText.length) parts.push(w.fanText)
        return parts.join(" · ")
    }

    property var hist: []
    function _seedHist() {
        if (w.store && w.instanceId && (!w.hist || w.hist.length === 0)) {
            var s = w.store.settingsFor(w.instanceId)
            if (s.hist && s.hist.length
                    && (!s.histDevice || s.histDevice === w.selectedDeviceId))
                w.hist = s.hist.slice()
        }
    }
    onStoreChanged: _seedHist()
    onInstanceIdChanged: _seedHist()
    onGpuDeviceChanged: w.hist = []
    function _recordSample(device) {
        if (!w.active) return
        var usage = device.usage_percent
        if (usage === undefined || usage === null || usage < 0) return
        var deviceId = String(device.id || "legacy")
        var shared = w.store && w.instanceId ? w.store.settingsFor(w.instanceId) : ({})
        var h = shared.histDevice === deviceId && shared.hist
            ? shared.hist.slice() : []
        h.push(Math.max(0, Math.min(1, Number(usage) / 100)))
        if (h.length > 48) h.shift()
        w.hist = h
        if (w.store && w.instanceId)
            w.store.patchSettings(w.instanceId, { hist: h, histDevice: deviceId })
    }
    onMetricsChanged: _recordSample(w._selectDevice(metrics))
    function useAutomaticGpu() {
        if (w.store && w.instanceId)
            w.store.setSetting(w.instanceId, "gpuDevice", "auto")
    }

    readonly property bool historyMatchesDevice:
        !cfg.histDevice || cfg.histDevice === w.selectedDeviceId
    readonly property var visibleHistory: w.historyMatchesDevice ? w.hist : []
    readonly property string histStats: {
        if (!w.showHistory || !w.visibleHistory || w.visibleHistory.length < 2) return ""
        var sum = 0, peak = 0
        for (var i = 0; i < w.visibleHistory.length; i++) {
            sum += w.visibleHistory[i]
            if (w.visibleHistory[i] > peak) peak = w.visibleHistory[i]
        }
        return "avg " + Math.round(sum / w.visibleHistory.length * 100) + "% · peak "
               + Math.round(peak * 100) + "%"
    }

    MetricGauge {
        anchors.fill: parent
        anchors.bottomMargin: detailPanel.visible ? detailPanel.height + theme.spacingMd : 0
        ok: w.avail
        value: Math.max(0, Math.min(w.v / 100, 1))
        big: w.avail ? w.v.toFixed(0) + "%" : "N/A"
        sub: (w.expanded || w.sizeClass === "large") && w.showDetails
             ? (detailPanel.visible ? w.deviceName : w.detailLine)
             : (!w.expanded && w.avail ? w.histStats : "")
        color: w.col(w.v)
        history: w.showHistory && !w.micro ? w.visibleHistory : []
        chartStyle: w.graphStyle
        chartSampleIntervalSeconds: 2
        chartPrimaryLabel: "GPU"
        expanded: w.expanded
        showSpark: (w.showHistory || detailPanel.visible) && !w.micro
        horizontal: w.sizeClass === "wide"
        sparkFills: (w.sizeClass === "tall" || w.sizeClass === "large") && !w.expanded
        bigMax: w.micro ? 72 : 60
        detailItems: w.glanceDetails
        detailLabelPixelSize: theme.fontLabel
        detailValuePixelSize: theme.fontTitle
        detailLabelColor: theme.textPrimary
        historyCaptionColor: theme.textPrimary
        historyCaptionPixelSize: theme.fontLabel
        subTextColor: theme.textPrimary
        stackedRingMaxFraction: w.roomyTile ? 0.48 : 0.62
        historyCaption: w.showHistory && !w.micro ? "LIVE UTILIZATION" : ""
    }

    Rectangle {
        id: detailPanel
        objectName: "gpuDetailPanel"
        visible: (w.expanded || w.roomyTile) && w.showDetails
                 && (w.detailMetrics.length > 0 || w.vendorDriver.length > 0
                     || w.unavailableReason.length > 0)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 22
        height: w.selectedOffline ? 176 : (w.expanded ? 138 : 92)
        radius: theme.radiusMd
        color: Qt.rgba(theme.cardBackground.r, theme.cardBackground.g, theme.cardBackground.b, 0.92)
        border.width: 1
        border.color: theme.cardBorder

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 10
            spacing: 5
            RowLayout {
                Layout.fillWidth: true
                Text {
                    Layout.fillWidth: true
                    text: w.deviceName
                    elide: Text.ElideRight
                    font.pixelSize: theme.fontLabel
                    font.bold: true
                    color: theme.textPrimary
                }
                Text {
                    text: w.vendorDriver
                    font.pixelSize: theme.fontLabel
                    color: theme.textSecondary
                }
            }
            RowLayout {
                visible: w.expanded && w.detailMetrics.length > 0
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 8
                Repeater {
                    model: w.detailMetrics
                    delegate: ColumnLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: 1
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: modelData.label
                            font.pixelSize: theme.fontLabel
                            font.bold: true
                            font.letterSpacing: 1
                            color: theme.textPrimary
                        }
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            Layout.maximumWidth: 150
                            text: modelData.value
                            elide: Text.ElideRight
                            font.pixelSize: theme.fontTitle
                            font.family: theme.fontMono
                            color: w.effAccent
                        }
                        Text {
                            visible: w.expanded
                            Layout.alignment: Qt.AlignHCenter
                            text: modelData.source
                            font.pixelSize: theme.fontMinimum
                            color: theme.textSecondary
                        }
                    }
                }
            }
            Text {
                visible: w.missingTelemetryText.length > 0
                Layout.fillWidth: true
                text: w.missingTelemetryText
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
                font.pixelSize: theme.fontLabel
                color: theme.textSecondary
            }
            Rectangle {
                id: autoGpuButton
                objectName: "gpuUseAutomaticButton"
                visible: w.selectedOffline
                enabled: w.store !== null && w.instanceId.length > 0
                Layout.fillWidth: true
                Layout.preferredHeight: 48
                radius: theme.radiusMd
                color: autoGpuMouse.pressed ? Qt.darker(w.effAccent, 1.2) : w.effAccent
                activeFocusOnTab: visible && enabled
                Accessible.role: Accessible.Button
                Accessible.name: "Use automatic GPU selection"
                Accessible.onPressAction: w.useAutomaticGpu()
                Keys.onReturnPressed: w.useAutomaticGpu()
                Keys.onSpacePressed: w.useAutomaticGpu()
                Text {
                    anchors.centerIn: parent
                    text: "Use Automatic GPU"
                    color: theme.backgroundColor
                    font.pixelSize: theme.fontLabel
                    font.bold: true
                }
                MouseArea {
                    id: autoGpuMouse
                    anchors.fill: parent
                    enabled: autoGpuButton.enabled
                    onClicked: w.useAutomaticGpu()
                }
            }
        }
    }
}
