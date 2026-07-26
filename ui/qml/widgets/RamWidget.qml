import QtQuick
import QtQuick.Layouts

// Physical memory, swap and Linux pressure data from the Rust metrics snapshot.
WidgetChrome {
    id: w
    property var metrics: ({})
    property bool expanded: false
    property bool active: true
    property var store: null
    property string instanceId: ""

    title: "Memory"; iconName: "ram"; accentColor: theme.catProductivity
    showHeader: !micro
    Accessible.role: Accessible.StaticText
    Accessible.name: w.accessibleSummary

    readonly property var cfg: {
        var _ = store ? store.revision : 0
        return (store && instanceId) ? JSON.parse(JSON.stringify(store.settingsFor(instanceId))) : ({})
    }
    readonly property string unit: cfg.unit !== undefined ? cfg.unit : "percent"
    readonly property bool showHistory: cfg.showHistory !== undefined ? cfg.showHistory : true
    readonly property string historyWindow: cfg.historyWindow !== undefined
                                            ? cfg.historyWindow : "2m"
    readonly property bool showDetails: cfg.showDetails !== undefined ? cfg.showDetails : true
    readonly property real warnPercent: Math.max(50, Math.min(95,
        Number(cfg.warnPercent !== undefined ? cfg.warnPercent : 75)))
    readonly property real criticalPercent: Math.min(100, Math.max(90, w.warnPercent + 10))
    readonly property bool roomyTile: (w.sizeClass === "tall" && w.height > 1000)
                                      || (w.sizeClass === "wide" && w.width > 1000)

    readonly property bool hasExplicitState: metrics.ram_metrics_available !== undefined
    property bool avail: metrics.ram_metrics_available !== undefined
                         ? metrics.ram_metrics_available === true
                         : metrics.ram_usage_percent !== undefined
                           && metrics.ram_usage_percent !== null
                           && metrics.ram_usage_percent >= 0
    property real v: avail ? Number(metrics.ram_usage_percent) : 0
    property real usedBytes: Number(metrics.ram_used_bytes || 0)
    property real totalBytes: Number(metrics.ram_total_bytes || 0)
    property real availableBytes: Number(metrics.ram_available_bytes || 0)
    readonly property bool availableBytesKnown:
        metrics.ram_available_bytes !== undefined && metrics.ram_available_bytes !== null
    readonly property real displayAvailableBytes: w.availableBytesKnown
                                                  ? w.availableBytes
                                                  : Math.max(0, w.totalBytes - w.usedBytes)
    property real cachedBytes: Number(metrics.ram_cached_bytes || 0)
    property real buffersBytes: Number(metrics.ram_buffers_bytes || 0)
    property real swapTotalBytes: Number(metrics.swap_total_bytes || 0)
    property real swapUsedBytes: Number(metrics.swap_used_bytes || 0)
    property bool haveBytes: totalBytes > 0
    readonly property string unavailableReason: String(metrics.ram_unavailable_reason
                                                        || "Memory metrics are unavailable")
    readonly property string freshness: {
        if (!w.avail) return "unavailable"
        var stamp = Number(metrics.ram_sample_unix_ms || 0)
        if (stamp <= 0) return "live"
        var age = Math.max(0, Math.floor((Date.now() - stamp) / 1000))
        return age < 2 ? "updated now" : "updated " + age + "s ago"
    }
    function col(p) {
        return p >= w.criticalPercent ? theme.error
             : p >= w.warnPercent ? theme.warning : w.effAccent
    }
    function gib(bytes) { return (Number(bytes) / 1073741824).toFixed(1) }
    // Backward-compatible helper name used by existing tests and saved gb mode.
    function gb(bytes) { return w.gib(bytes) }

    readonly property string swapText: swapTotalBytes > 0
                                              ? w.gib(swapUsedBytes) + " / " + w.gib(swapTotalBytes) + " GiB"
                                              : "None"
    readonly property string pressureText: metrics.ram_pressure_some_avg10 !== undefined
                                                   && metrics.ram_pressure_some_avg10 !== null
                                            ? Number(metrics.ram_pressure_some_avg10).toFixed(2) + "%" : ""
    readonly property string pressureSummary: w.pressureText.length
                                               ? w.pressureText + " tasks stalled, 10s" : ""
    readonly property string alertLevel: {
        if (!w.avail) return "unavailable"
        if (w.v >= w.criticalPercent) return "critical"
        if (w.v >= w.warnPercent) return "warning"
        return "normal"
    }
    readonly property string alertText: w.alertLevel === "critical"
                                        ? "Critical memory use"
                                        : w.alertLevel === "warning"
                                          ? "High memory use"
                                          : w.alertLevel === "unavailable"
                                            ? "Memory unavailable" : "Normal"
    readonly property string accessibleSummary: {
        var parts = ["Memory"]
        parts.push(w.avail ? w.v.toFixed(0) + " percent used" : w.alertText)
        if (w.haveBytes) {
            parts.push(w.gib(w.usedBytes) + " GiB used")
            if (w.haveBytes)
                parts.push(w.gib(w.displayAvailableBytes) + " GiB available")
        }
        if (w.swapTotalBytes > 0) parts.push("swap " + w.swapText)
        if (w.pressureSummary.length) parts.push(w.pressureSummary)
        if (w.alertLevel !== "normal" && w.alertLevel !== "unavailable")
            parts.push(w.alertText)
        return parts.join(", ")
    }
    status: {
        var base = w.hasExplicitState ? w.freshness : ""
        var state = w.alertLevel === "warning" || w.alertLevel === "critical"
                    ? w.alertText : ""
        return state.length ? (base.length ? base + " · " + state : state) : base
    }
    statusColor: w.alertLevel === "critical" ? theme.error
                 : w.alertLevel === "warning" || w.alertLevel === "unavailable"
                   ? theme.warning : theme.textSecondary
    readonly property var detailMetrics: {
        var result = []
        if (w.haveBytes)
            result.push({ label: "AVAILABLE", value: w.gib(w.displayAvailableBytes) + " GiB" })
        result.push({ label: "SWAP", value: w.swapText })
        if (w.pressureText.length)
            result.push({ label: "STALLS, 10S", value: w.pressureText })
        if (w.cachedBytes > 0)
            result.push({ label: "CACHE", value: w.gib(w.cachedBytes) + " GiB" })
        if (w.buffersBytes > 0)
            result.push({ label: "BUFFERS", value: w.gib(w.buffersBytes) + " GiB" })
        return result
    }
    readonly property var glanceDetails: {
        if (w.micro || w.expanded || w.roomyTile || !w.showDetails
                || (w.sizeClass !== "wide" && w.sizeClass !== "tall"))
            return []
        var result = []
        if (w.haveBytes)
            result.push({ label: "AVAILABLE, GiB", value: w.gib(w.displayAvailableBytes) })
        result.push({ label: "SWAP, GiB",
                      value: w.swapTotalBytes > 0
                             ? w.gib(w.swapUsedBytes) + " / " + w.gib(w.swapTotalBytes)
                             : "None" })
        if (w.pressureText.length)
            result.push({ label: "STALLS, 10S", value: w.pressureText })
        if (w.cachedBytes > 0)
            result.push({ label: "CACHE, GiB", value: w.gib(w.cachedBytes) })
        return result
    }
    readonly property string detailLine: {
        if (!w.avail) return w.unavailableReason
        var parts = []
        if (w.haveBytes) parts.push("avail " + w.gib(w.displayAvailableBytes) + " GiB")
        if (w.swapTotalBytes > 0) parts.push("swap " + w.swapText)
        if (w.pressureSummary.length) parts.push(w.pressureSummary)
        return parts.join(" · ")
    }

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
        if (!w.active || metrics.ram_metrics_available === false) return
        var percent = metrics.ram_usage_percent
        if (percent === undefined || percent === null || percent < 0) return
        var h = w.hist.slice()
        h.push(Math.max(0, Math.min(1, Number(percent) / 100)))
        while (h.length > w.historyLimit) h.shift()
        w.hist = h
        if (w.store && w.instanceId) w.store.setSetting(w.instanceId, "hist", h)
    }

    readonly property string histStats: {
        if (!w.showHistory || !w.hist || w.hist.length < 2) return ""
        var sum = 0, minimum = 1, peak = 0
        for (var i = 0; i < w.hist.length; i++) {
            sum += w.hist[i]
            minimum = Math.min(minimum, w.hist[i])
            peak = Math.max(peak, w.hist[i])
        }
        return "min " + Math.round(minimum * 100) + "% · avg "
               + Math.round(sum / w.hist.length * 100) + "% · peak "
               + Math.round(peak * 100) + "%"
    }
    readonly property int historyLimit: w.historyWindow === "1m" ? 30
                                        : w.historyWindow === "5m" ? 150 : 60
    readonly property string historyLabel: w.historyWindow === "1m" ? "1 minute"
                                           : w.historyWindow === "5m" ? "5 minutes"
                                                                      : "2 minutes"

    MetricGauge {
        anchors.fill: parent
        anchors.bottomMargin: detailPanel.visible
                              ? detailPanel.height + theme.spacingMd : 0
        ok: w.avail
        value: Math.max(0, Math.min(w.v / 100, 1))
        big: !w.avail ? "N/A"
           : w.unit === "gb" ? (w.haveBytes ? w.gib(w.usedBytes) + " GiB" : "N/A")
                             : w.v.toFixed(0) + "%"
        sub: w.micro ? ""
           : (w.expanded || w.sizeClass === "large") && w.showDetails
             ? (detailPanel.visible ? w.histStats : w.detailLine)
           : !w.haveBytes ? "-"
           : w.unit === "gb" ? w.v.toFixed(0) + "%"
                              : w.glanceDetails.length > 0
                                ? w.gib(w.usedBytes) + " GiB used"
                                : "used " + w.gib(w.usedBytes) + " · available "
                                  + w.gib(w.displayAvailableBytes) + " GiB"
        color: w.col(w.v)
        history: w.showHistory && !w.micro ? w.hist : []
        detailItems: w.glanceDetails
        detailLabelPixelSize: theme.fontLabel
        detailValuePixelSize: theme.fontTitle
        detailLabelColor: theme.textPrimary
        historyCaptionColor: theme.textPrimary
        historyCaptionPixelSize: theme.fontLabel
        subTextColor: theme.textPrimary
        historyCaption: w.showHistory && !w.micro
                        ? w.historyLabel.toUpperCase() + " UTILIZATION" : ""
        expanded: w.expanded
        showSpark: w.showHistory && !w.micro
        horizontal: w.sizeClass === "wide"
        sparkFills: (w.sizeClass === "tall" || w.sizeClass === "large") && !w.expanded
        stackedRingMaxFraction: w.roomyTile ? 0.46 : (w.big ? 0.52 : 0.62)
        bigMax: w.micro ? 72 : 60
    }

    Rectangle {
        id: detailPanel
        objectName: "ramDetailPanel"
        visible: (w.expanded || w.roomyTile) && w.showDetails
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 22
        height: w.expanded ? 116 : 172
        radius: theme.radiusMd
        color: Qt.rgba(theme.cardBackground.r, theme.cardBackground.g, theme.cardBackground.b, 0.92)
        border.width: 1
        border.color: theme.cardBorder

        GridLayout {
            visible: w.avail
            anchors.fill: parent
            anchors.margins: 10
            columns: w.expanded ? Math.min(5, w.detailMetrics.length) : 3
            columnSpacing: 8
            rowSpacing: 8
            Repeater {
                model: w.detailMetrics
                delegate: ColumnLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 2
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
                        Layout.maximumWidth: w.expanded ? 260 : 190
                        text: modelData.value
                        elide: Text.ElideRight
                        font.pixelSize: theme.fontTitle
                        font.family: theme.fontMono
                        color: w.effAccent
                    }
                }
            }
        }
        Text {
            visible: !w.avail
            anchors.fill: parent
            anchors.margins: 12
            text: w.unavailableReason
            wrapMode: Text.Wrap
            verticalAlignment: Text.AlignVCenter
            horizontalAlignment: Text.AlignHCenter
            font.pixelSize: theme.fontLabel
            color: theme.textSecondary
        }
    }
}
