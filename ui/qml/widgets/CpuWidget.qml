import QtQuick
import QtQuick.Layouts

// CPU utilization + temperature - real data from the Rust core (metricsJson).
//
// Sizing (W1 wave 2a): layout keys off the injected `sizeClass`, never off
// `expanded`. The shared MetricGauge carries the ring; each size earns its box:
//   • 0.5x0.5 (micro) - headerless bare ring + the one number. No sparkline.
//   • 1x1 (baseline)  - header + ring + the classic sparkline strip.
//   • wide            - ring beside the sparkline, which finally gets real width.
//   • tall            - bigger sparkline share + an avg/peak line inside the
//                       ring: genuinely more information, not a stretched void.
//   • full (overlay)  - the expanded gauge (core count sub-line).
WidgetChrome {
    id: w
    property var metrics: ({})
    property bool expanded: false
    property bool active: true
    property var store: null
    property string instanceId: ""

    title: "CPU"; iconName: "cpu"; accentColor: theme.catSystem
    showHeader: !micro
    Accessible.role: Accessible.StaticText
    Accessible.name: w.accessibleSummary

    // Live per-instance config (see WidgetConfigSchema "cpu").
    readonly property var cfg: {
        var _ = store ? store.revision : 0
        return (store && instanceId) ? JSON.parse(JSON.stringify(store.settingsFor(instanceId))) : ({})
    }
    readonly property bool showTemp: cfg.showTemp !== undefined ? cfg.showTemp : true
    readonly property string tempSource: cfg.tempSource !== undefined ? cfg.tempSource : "auto"
    readonly property bool showHistory: cfg.showHistory !== undefined ? cfg.showHistory : true
    readonly property string historyWindow: cfg.historyWindow !== undefined ? cfg.historyWindow : "2m"
    readonly property string graphStyle: cfg.graphStyle !== undefined ? cfg.graphStyle : "smooth"
    readonly property bool showLoadAverage: cfg.showLoadAverage !== undefined ? cfg.showLoadAverage : true
    readonly property bool showFrequency: cfg.showFrequency !== undefined ? cfg.showFrequency : true
    readonly property bool showPerCore: cfg.showPerCore !== undefined ? cfg.showPerCore : true
    readonly property bool showTopProcess: cfg.showTopProcess !== undefined ? cfg.showTopProcess : true
    readonly property real warnTemp: cfg.warnTemp !== undefined ? cfg.warnTemp : 85

    // New core snapshots state availability explicitly. The fallback keeps the
    // widget compatible with older snapshots and source-tree test fixtures.
    readonly property bool hasExplicitState: metrics.cpu_usage_available !== undefined
                                             || metrics.cpu_sample_status !== undefined
    property bool avail: metrics.cpu_usage_available !== undefined
                         ? metrics.cpu_usage_available === true
                         : metrics.cpu_usage_percent !== undefined
                           && metrics.cpu_usage_percent !== null
                           && metrics.cpu_usage_percent >= 0
    readonly property string sampleStatus: metrics.cpu_sample_status !== undefined
                                           ? String(metrics.cpu_sample_status)
                                           : (w.avail ? "ready" : "unavailable")
    readonly property bool warming: sampleStatus === "warming"
    property real v: avail ? metrics.cpu_usage_percent : 0
    // Select a source locally so two CPU widget instances may use different
    // temperature policies without changing the shared metrics collector.
    readonly property var selectedTemperature: {
        var sensors = metrics.cpu_temperature_sensors || []
        var chosen = null
        if (w.tempSource === "hottest") {
            for (var i = 0; i < sensors.length; i++)
                if (!chosen || Number(sensors[i].celsius) > Number(chosen.celsius)) chosen = sensors[i]
        } else if (w.tempSource === "package") {
            for (var j = 0; j < sensors.length && !chosen; j++) {
                var label = String(sensors[j].label || "").toLowerCase()
                if (label.indexOf("package") >= 0 || label.indexOf("tctl") >= 0
                        || label.indexOf("tdie") >= 0) chosen = sensors[j]
            }
            if (!chosen)
                return { available: false, celsius: 0, label: "Package sensor",
                         reason: sensors.length
                                 ? "No package temperature sensor was reported"
                                 : "No CPU temperature sensors were reported" }
        }
        if (!chosen && sensors.length) chosen = sensors[0]
        if (chosen) return { available: true, celsius: Number(chosen.celsius),
                             label: String(chosen.label || "CPU"), reason: "" }
        if (metrics.cpu_temp_celsius !== undefined && metrics.cpu_temp_celsius !== null)
            return { available: true, celsius: Number(metrics.cpu_temp_celsius),
                     label: "CPU sensor", reason: "" }
        return { available: false, celsius: 0, label: "",
                 reason: String(metrics.cpu_temp_unavailable_reason
                                || "No CPU temperature sensor was reported") }
    }
    readonly property bool tempAvailable: selectedTemperature.available === true
    property real temp: tempAvailable ? selectedTemperature.celsius : 0
    readonly property string tempSourceLabel: selectedTemperature.label || ""
    readonly property string tempUnavailableReason: tempAvailable
        ? "" : String(selectedTemperature.reason || "Temperature unavailable")
    readonly property string freshness: {
        if (w.warming) return "warming up"
        if (!w.avail) return "unavailable"
        var stamp = Number(metrics.cpu_sample_unix_ms || 0)
        if (stamp <= 0) return "live"
        var age = Math.max(0, Math.floor((Date.now() - stamp) / 1000))
        return age < 2 ? "updated now" : "updated " + age + "s ago"
    }
    readonly property string alertLevel: {
        if (!w.avail) return "unavailable"
        if (w.tempAvailable && w.temp > w.warnTemp) return "critical"
        if (w.v > 90) return "critical"
        if (w.tempAvailable && w.temp > w.warnTemp - 12) return "warning"
        if (w.v > 70) return "warning"
        return w.warming ? "warming" : "normal"
    }
    readonly property string alertText: {
        if (w.alertLevel === "unavailable") return "CPU unavailable"
        if (w.alertLevel === "warming") return "Building CPU sample"
        if (w.alertLevel === "critical")
            return w.tempAvailable && w.temp > w.warnTemp
                ? "Critical temperature" : "Critical load"
        if (w.alertLevel === "warning")
            return w.tempAvailable && w.temp > w.warnTemp - 12
                ? "High temperature" : "High load"
        return "Normal"
    }
    readonly property string accessibleSummary: {
        var parts = ["CPU"]
        parts.push(w.avail ? w.v.toFixed(0) + " percent utilization" : w.alertText)
        if (w.showTemp)
            parts.push(w.tempAvailable
                       ? w.temp.toFixed(0) + " degrees Celsius from " + w.tempSourceLabel
                       : w.tempUnavailableReason)
        if (w.alertLevel !== "normal" && w.alertLevel !== "unavailable")
            parts.push(w.alertText)
        if (w.showHistory) parts.push(w.historyLabel + " history")
        return parts.join(", ")
    }
    status: {
        var temperature = (w.showTemp && w.tempAvailable) ? w.temp.toFixed(0) + "°C" : ""
        var state = w.alertLevel === "warning" || w.alertLevel === "critical"
                    ? w.alertText : ""
        if (w.width < 480 && state === "Critical temperature")
            state = "Temp critical"
        else if (w.width < 480 && state === "High temperature")
            state = "High temp"
        var base = !w.hasExplicitState
                   ? temperature
                   : (temperature.length ? temperature + " · " + w.freshness : w.freshness)
        return state.length ? (base.length ? base + " · " + state : state) : base
    }
    // Header temperature colour tracks the ring exactly, so both signals switch
    // at the same threshold (no 5 °C band where they disagree).
    statusColor: w.col(w.v)
    // Temperature is the real warning signal - escalate the WHOLE gauge (ring +
    // number) on it, not just the tiny header text. Otherwise reflect load, in the
    // widget's own accent while comfortable.
    function col(p) {
        if (w.tempAvailable) {
            if (w.temp > w.warnTemp) return theme.error
            if (w.temp > w.warnTemp - 12) return theme.warning
        }
        return p > 90 ? theme.error : p > 70 ? theme.warning : w.effAccent
    }

    readonly property string frequencyText: {
        var mhz = Number(metrics.cpu_frequency_mhz || 0)
        if (mhz <= 0) return ""
        return mhz >= 1000 ? (mhz / 1000).toFixed(2) + " GHz" : mhz.toFixed(0) + " MHz"
    }
    readonly property string loadText: {
        if (metrics.cpu_load_1 === undefined || metrics.cpu_load_1 === null) return ""
        var one = Number(metrics.cpu_load_1).toFixed(2)
        var five = (metrics.cpu_load_5 === undefined || metrics.cpu_load_5 === null)
                   ? "-" : Number(metrics.cpu_load_5).toFixed(2)
        var fifteen = (metrics.cpu_load_15 === undefined || metrics.cpu_load_15 === null)
                      ? "-" : Number(metrics.cpu_load_15).toFixed(2)
        return "load " + one + " / " + five + " / " + fifteen
    }
    readonly property string expandedDetails: {
        var parts = []
        if ((metrics.cpu_core_count || 0) > 0) parts.push(metrics.cpu_core_count + " cores")
        if (w.showFrequency && w.frequencyText.length) parts.push(w.frequencyText)
        if (w.showLoadAverage && w.loadText.length) parts.push(w.loadText)
        if (w.showTopProcess && w.topProcessText.length) parts.push(w.topProcessText)
        if (w.showTemp)
            parts.push(w.tempAvailable ? w.tempSourceLabel + " " + w.temp.toFixed(0) + "°C"
                                       : w.tempUnavailableReason)
        if (w.hasExplicitState) parts.push(w.freshness)
        return parts.join(" · ")
    }
    readonly property string topProcessText: {
        var name = metrics.cpu_top_process_name
        var percent = metrics.cpu_top_process_percent
        if (name === undefined || name === null || String(name).length === 0
                || percent === undefined || percent === null) return ""
        return String(name) + " " + Number(percent).toFixed(0) + "%"
    }
    readonly property int historyLimit: historyWindow === "1m" ? 30
                                        : historyWindow === "5m" ? 150 : 60
    readonly property string historyLabel: historyWindow === "1m" ? "1 minute"
                                           : historyWindow === "5m" ? "5 minutes" : "2 minutes"
    readonly property var busiestCores: {
        var source = metrics.cpu_core_usage_percent || []
        var result = []
        for (var i = 0; i < source.length; i++)
            result.push({ index: i + 1, value: Math.max(0, Math.min(100, Number(source[i]))) })
        result.sort(function (a, b) { return b.value - a.value })
        return result.slice(0, 8)
    }
    readonly property bool roomyTile:
        !w.expanded && ((w.sizeClass === "tall" && w.height > 1000)
                        || (w.sizeClass === "wide" && w.width > 1000))
    readonly property var glanceDetails: {
        if (w.micro || w.expanded) return []
        var out = []
        if ((metrics.cpu_core_count || 0) > 0)
            out.push({ label: "CORES", value: String(metrics.cpu_core_count) })
        if (w.showFrequency && w.frequencyText.length)
            out.push({ label: "CLOCK", value: w.frequencyText })
        if (w.showLoadAverage && metrics.cpu_load_1 !== undefined
                && metrics.cpu_load_1 !== null)
            out.push({ label: "LOAD 1M", value: Number(metrics.cpu_load_1).toFixed(2) })
        if (w.showTopProcess && w.topProcessText.length)
            out.push({ label: "BUSIEST", value: w.topProcessText })
        if (w.showTemp)
            out.push({ label: "TEMP SOURCE",
                       value: w.tempAvailable ? w.tempSourceLabel : "Unavailable" })
        return out.slice(0, 4)
    }

    // Rolling history. Mirrored into the shared store (keyed by instanceId) so a
    // tile and its expanded overlay - two separate instances - share one graph.
    property var hist: []
    function _seedHist() {
        if (w.store && w.instanceId && (!w.hist || w.hist.length === 0)) {
            var s = w.store.settingsFor(w.instanceId)
            if (s.hist && s.hist.length) w.hist = s.hist.slice()
        }
    }
    onStoreChanged: _seedHist()
    onInstanceIdChanged: _seedHist()
    onMetricsChanged: {
        // Honour `active` (hidden/off-page tiles must not churn) and only record
        // a sample when the frame actually carried a reading - never a fake 0%.
        // Availability/value are computed from `metrics` directly here: the bound
        // `avail`/`v` properties re-evaluate lazily and would read one frame stale
        // inside this handler.
        var u = metrics.cpu_usage_percent
        if (!w.active || metrics.cpu_usage_available === false
                || u === undefined || u === null || u < 0) return
        var h = w.hist.slice()
        h.push(Math.max(0, Math.min(1, u / 100)))   // clamp out-of-range usage
        while (h.length > w.historyLimit) h.shift()
        w.hist = h
        if (w.store && w.instanceId) w.store.setSetting(w.instanceId, "hist", h)
    }

    // avg/peak over the retained history - the extra line a tall tile earns.
    // Needs ≥2 samples (one reading has no "average" story to tell).
    readonly property string histStats: {
        if (!w.showHistory || !w.hist || w.hist.length < 2) return ""
        var sum = 0, peak = 0
        for (var i = 0; i < w.hist.length; i++) {
            sum += w.hist[i]
            if (w.hist[i] > peak) peak = w.hist[i]
        }
        return "avg " + Math.round(sum / w.hist.length * 100) + "% · peak "
               + Math.round(peak * 100) + "%"
    }

    MetricGauge {
        anchors.fill: parent
        anchors.bottomMargin: corePanel.visible ? corePanel.height + theme.spacingMd : 0
        ok: w.avail
        value: Math.min(w.v / 100, 1)
        big: w.avail ? w.v.toFixed(0) + "%" : (w.warming ? "..." : "N/A")
        // Temp lives in the header (top-right) - the sub-line only adds core count
        // in the overlay, so the reading isn't printed twice. Hide it when the
        // count is absent/0 rather than printing a misleading "0 cores". Tall
        // tiles (room, but not the overlay) use the line for avg/peak instead.
        sub: w.expanded || w.sizeClass === "large"
             ? w.expandedDetails
             : (w.avail && w.big ? w.histStats : "")
        color: w.col(w.v)
        history: w.showHistory && !w.micro ? w.hist : []
        chartStyle: w.graphStyle
        chartSampleIntervalSeconds: 2
        chartPrimaryLabel: "CPU"
        expanded: w.expanded
        // Per-size layout (sizeClass injected by Dashboard; micro derived by chrome).
        showSpark: (w.showHistory || corePanel.visible) && !w.micro
        horizontal: w.sizeClass === "wide"
        // Tall TILES hand the sparkline all the height below a squared ring;
        // the overlay keeps the classic expanded gauge.
        sparkFills: (w.sizeClass === "tall" || w.sizeClass === "large") && !w.expanded
        // A roomy portrait card uses the height for context and history rather
        // than turning the ring into a nearly full-width poster.
        stackedRingMaxFraction: w.roomyTile ? 0.48 : 0.62
        bigMax: w.micro ? 72 : 60
        detailItems: w.glanceDetails
        detailLabelPixelSize: theme.fontLabel
        detailValuePixelSize: theme.fontTitle
        detailLabelColor: theme.textPrimary
        historyCaptionColor: theme.textPrimary
        historyCaptionPixelSize: theme.fontLabel
        subTextColor: theme.textPrimary
        // Four single-row cards gave each supporting value less than 100 px in
        // the wide half-height footprint. A 2x2 strip keeps all four facts while
        // giving labels and values enough width at the minimum supported size.
        horizontalDetailColumns: w.sizeClass === "wide" ? 2 : 0
        historyCaption: w.showHistory && !w.micro ? w.historyLabel.toUpperCase() + " HISTORY" : ""
    }

    Rectangle {
        id: corePanel
        objectName: "cpuCorePanel"
        visible: (w.expanded || w.roomyTile) && w.showPerCore && w.busiestCores.length > 0
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 22
        height: w.expanded ? 82 : 112
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
                    text: "BUSIEST CORES"
                    font.pixelSize: theme.fontMinimum
                    font.bold: true
                    font.letterSpacing: 1
                    color: theme.textTertiary
                }
                Item { Layout.fillWidth: true }
                Text {
                    text: w.historyLabel + " history"
                    font.pixelSize: theme.fontMinimum
                    color: theme.textTertiary
                }
            }
            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 5
                Repeater {
                    model: w.busiestCores
                    delegate: ColumnLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        spacing: 2
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            radius: 3
                            color: theme.backgroundColor
                            Rectangle {
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.bottom: parent.bottom
                                height: parent.height * modelData.value / 100
                                radius: 3
                                color: w.col(modelData.value)
                            }
                        }
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: "C" + modelData.index
                            font.pixelSize: theme.fontMinimum
                            font.family: theme.fontMono
                            color: theme.textSecondary
                        }
                    }
                }
            }
        }
    }
}
