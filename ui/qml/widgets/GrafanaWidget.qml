import QtQuick
import QtQuick.Layouts

// Grafana / Metrics Widget - Native time-series chart and metric renderer.
// Queries Prometheus endpoints (/api/v1/query_range) or Grafana datasource proxy
// over HTTP using the safe NetHub egress gate.
// Renders hardware-accelerated vector area/line sparklines, histogram bars, and
// gauge telemetry with interactive touch scrubbing and automatic unit scaling.
WidgetChrome {
    id: w
    property var metrics: ({})
    property bool expanded: false
    property bool active: true
    property var store: null
    property string instanceId: ""
    property int tick: 0
    property double nowMsOverride: -1

    // Egress gate
    property var netHub: null
    NetHub { id: _fallbackHub }
    function _hub() { return netHub ? netHub : _fallbackHub }
    property var xhrFactory: null

    title: w.customTitle.length ? w.customTitle : (w.query.length ? w.query : "Grafana / Metrics")
    iconName: "grafana"
    accentColor: w.statusColor
    showHeader: !micro
    Accessible.name: title
    Accessible.description: w.errText.length ? w.errText : (w.formattedLatest + " " + w.effectiveUnit)

    // Configuration
    readonly property var cfg: {
        var _ = store ? store.revision : 0
        return (store && instanceId) ? JSON.parse(JSON.stringify(store.settingsFor(instanceId))) : ({})
    }

    readonly property string customTitle: String(cfg.title || "")
    readonly property string serverUrl: String(cfg.url || "http://localhost:9090").trim()
    readonly property string query: String(cfg.query || "node_load1").trim()
    readonly property string authToken: String(cfg.authToken || "").trim()
    readonly property int rangeSec: Number(cfg.rangeSec || 3600)
    readonly property int pollSec: Math.max(5, Number(cfg.pollSec || 15))
    readonly property string chartType: String(cfg.chartType || "area")
    readonly property string customUnit: String(cfg.unit || "")
    readonly property string unitScale: String(cfg.unitScale || "auto")
    readonly property bool fillGlow: cfg.fillGlow !== undefined ? Boolean(cfg.fillGlow) : true
    readonly property bool showMinMax: cfg.showMinMax !== undefined ? Boolean(cfg.showMinMax) : true
    readonly property string warnAtStr: String(cfg.warnAt || "").trim()
    readonly property string critAtStr: String(cfg.critAt || "").trim()
    readonly property string yMinConfig: cfg.yMin !== undefined ? String(cfg.yMin).trim() : "0"
    readonly property string yMaxConfig: cfg.yMax !== undefined ? String(cfg.yMax).trim() : ""

    readonly property double effectiveMinVal: {
        if (yMinConfig === "auto") return minVal
        var parsed = parseFloat(yMinConfig)
        if (!isNaN(parsed)) return Math.min(parsed, minVal)
        return Math.min(0, minVal)
    }

    readonly property double effectiveMaxVal: {
        if (unitScale === "percent" && (!yMaxConfig.length || yMaxConfig === "auto")) {
            return Math.max(100, maxVal)
        }
        var parsed = parseFloat(yMaxConfig)
        if (!isNaN(parsed)) return Math.max(parsed, maxVal)
        return maxVal > effectiveMinVal ? maxVal : (effectiveMinVal + 1.0)
    }

    // Ephemeral state
    property var dataPoints: []
    property double latestVal: 0
    property double minVal: 0
    property double maxVal: 0
    property double avgVal: 0
    property double deltaVal: 0
    property double deltaPercent: 0
    property string errText: ""
    property bool loading: false
    property double lastFetchEpochMs: 0
    property string seriesName: ""

    // Touch / Mouse scrubber state
    property real scrubNormalizedX: -1 // 0.0 .. 1.0, or -1 when idle
    property var scrubPoint: null

    // Threshold evaluation
    readonly property double warnThreshold: warnAtStr.length ? parseFloat(warnAtStr) : NaN
    readonly property double critThreshold: critAtStr.length ? parseFloat(critAtStr) : NaN

    readonly property color statusColor: {
        if (errText.length) return theme.error
        if (!isNaN(critThreshold) && latestVal >= critThreshold) return theme.error
        if (!isNaN(warnThreshold) && latestVal >= warnThreshold) return theme.warning
        return theme.accent
    }

    readonly property string effectiveUnit: {
        if (customUnit.length) return customUnit
        if (unitScale === "percent") return "%"
        return ""
    }

    // Value formatter
    function formatValue(v) {
        if (isNaN(v) || v === null || v === undefined) return "—"
        if (unitScale === "percent") {
            return Math.round(v) + "%"
        }
        if (unitScale === "fixed2") {
            return Number(v).toFixed(2)
        }
        if (unitScale === "auto") {
            // Check if values resemble bytes (> 100000)
            if (Math.abs(maxVal) > 1000000000) {
                return (v / 1073741824).toFixed(1) + " GB"
            }
            if (Math.abs(maxVal) > 1000000) {
                return (v / 1048576).toFixed(1) + " MB"
            }
            if (Math.abs(maxVal) > 1000) {
                return (v / 1024).toFixed(1) + " KB"
            }
            if (Math.abs(v) >= 100) return String(Math.round(v))
            if (Math.abs(v) >= 10) return Number(v).toFixed(1)
            return Number(v).toFixed(2)
        }
        return Number(v).toFixed(2)
    }

    readonly property string formattedLatest: formatValue(latestVal)
    readonly property string formattedMin: formatValue(minVal)
    readonly property string formattedMax: formatValue(maxVal)
    readonly property string formattedAvg: formatValue(avgVal)

    // Time window label
    readonly property string rangeLabel: {
        if (rangeSec <= 300) return "5 min"
        if (rangeSec <= 900) return "15 min"
        if (rangeSec <= 1800) return "30 min"
        if (rangeSec <= 3600) return "1 hr"
        if (rangeSec <= 21600) return "6 hr"
        if (rangeSec <= 86400) return "24 hr"
        return Math.round(rangeSec / 3600) + " hr"
    }

    // Geometry layout helpers
    readonly property bool wideTile: width > 500
    readonly property bool tallTile: height > 280

    // Construct Prometheus range query URL
    function buildRequestUrl() {
        var base = serverUrl
        if (!base.startsWith("http://") && !base.startsWith("https://")) {
            base = "http://" + base
        }
        base = base.replace(/\/+$/, "")

        var endpoint = base + "/api/v1/query_range"
        var nowSec = Math.floor((nowMsOverride > 0 ? nowMsOverride : Date.now()) / 1000)
        var startSec = nowSec - rangeSec
        var stepSec = Math.max(2, Math.floor(rangeSec / 60))

        var params = "query=" + encodeURIComponent(query)
                   + "&start=" + startSec
                   + "&end=" + nowSec
                   + "&step=" + stepSec

        return endpoint + "?" + params
    }

    function parsePrometheusMatrix(jsonStr) {
        try {
            var res = JSON.parse(jsonStr)
            if (res.status !== "success") {
                w.errText = res.error || "Query error"
                return false
            }
            var data = res.data
            if (!data || !data.result || data.result.length === 0) {
                w.errText = "No data returned for query"
                w.dataPoints = []
                return true
            }

            var firstResult = data.result[0]
            var metricObj = firstResult.metric || ({})
            var labels = []
            for (var k in metricObj) {
                if (k !== "__name__") labels.push(k + '="' + metricObj[k] + '"')
            }
            w.seriesName = metricObj.__name__ || (labels.length ? labels.join(", ") : w.query)

            var rawVals = firstResult.values || []
            if (rawVals.length === 0) {
                if (firstResult.value) rawVals = [firstResult.value]
            }

            var pts = []
            var minV = Infinity
            var maxV = -Infinity
            var sum = 0

            for (var i = 0; i < rawVals.length; i++) {
                var p = rawVals[i]
                var t = Number(p[0]) * 1000
                var v = parseFloat(p[1])
                if (!isNaN(v)) {
                    pts.push({ t: t, v: v })
                    if (v < minV) minV = v
                    if (v > maxV) maxV = v
                    sum += v
                }
            }

            if (pts.length > 0) {
                w.dataPoints = pts
                w.minVal = minV
                w.maxVal = maxV
                w.avgVal = sum / pts.length
                w.latestVal = pts[pts.length - 1].v
                w.deltaVal = pts[pts.length - 1].v - pts[0].v
                w.deltaPercent = pts[0].v !== 0 ? (w.deltaVal / Math.abs(pts[0].v)) * 100 : 0
                w.errText = ""
            } else {
                w.errText = "Empty series"
            }
            return true
        } catch (e) {
            w.errText = "Parse error: " + e.message
            return false
        }
    }

    function fetchMetrics() {
        if (!w.query.length || !w.active) return
        w.loading = true
        var url = buildRequestUrl()

        var opts = {
            url: url,
            method: "GET",
            authToken: w.authToken,
            timeout: 8000,
            xhrFactory: w.xhrFactory,
            onDone: function (status, responseText) {
                w.loading = false
                w.lastFetchEpochMs = Date.now()
                if (status >= 200 && status < 300) {
                    parsePrometheusMatrix(responseText)
                } else {
                    w.errText = "HTTP " + status
                }
                if (chartCanvas) chartCanvas.requestPaint()
            },
            onError: function (reason) {
                w.loading = false
                w.lastFetchEpochMs = Date.now()
                w.errText = String(reason || "Connection failed")
                if (chartCanvas) chartCanvas.requestPaint()
            }
        }

        _hub().request(opts)
    }

    // Poll timer
    Timer {
        id: pollTimer
        interval: w.pollSec * 1000
        repeat: true
        running: w.active && !w.expanded
        onTriggered: w.fetchMetrics()
    }

    // Fast poll when expanded
    Timer {
        id: fastPollTimer
        interval: 5000
        repeat: true
        running: w.active && w.expanded
        onTriggered: w.fetchMetrics()
    }

    Component.onCompleted: fetchMetrics()
    onQueryChanged: fetchMetrics()
    onServerUrlChanged: fetchMetrics()
    onRangeSecChanged: fetchMetrics()

    // ── MAIN CONTENT ───────────────────────────────────────────────────────
    Item {
        anchors.fill: parent
        anchors.margins: w.expanded ? 16 : (w.micro ? 4 : 8)

        // Error State
        ColumnLayout {
            anchors.centerIn: parent
            visible: w.errText.length > 0 && w.dataPoints.length === 0
            spacing: 6
            Text {
                Layout.alignment: Qt.AlignCenter
                text: "METRICS UNAVAILABLE"
                color: theme.error
                font.pixelSize: 14
                font.family: theme.fontDisplay
                font.weight: Font.Bold
            }
            Text {
                Layout.alignment: Qt.AlignCenter
                text: w.errText
                color: theme.textSecondary
                font.pixelSize: 12
                font.family: theme.fontMono
                elide: Text.ElideRight
                Layout.maximumWidth: parent.width - 20
            }
        }

        // Active Content Layout
        ColumnLayout {
            anchors.fill: parent
            spacing: w.expanded ? 10 : 4
            visible: w.dataPoints.length > 0 || (w.errText.length === 0)

            // Top Telemetry Header (Compact Tile)
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                visible: !w.micro && !w.expanded

                // Big Latest Number
                Text {
                    text: w.formattedLatest
                    color: w.statusColor
                    font.pixelSize: w.wideTile ? 32 : (w.tallTile ? 28 : 22)
                    font.family: theme.fontDisplay
                    font.weight: Font.Bold
                }

                // Unit & Trend
                ColumnLayout {
                    spacing: 0
                    Text {
                        text: w.effectiveUnit
                        color: theme.textSecondary
                        font.pixelSize: 13
                        font.family: theme.fontMono
                        font.weight: Font.Bold
                        visible: w.effectiveUnit.length > 0
                    }
                    Text {
                        text: (w.deltaVal >= 0 ? "+" : "") + w.formatValue(w.deltaVal) + " (" + (w.deltaPercent >= 0 ? "+" : "") + w.deltaPercent.toFixed(1) + "%)"
                        color: w.deltaVal >= 0 ? theme.catSystem : theme.catServices
                        font.pixelSize: 11
                        font.family: theme.fontMono
                        font.weight: Font.Medium
                        visible: w.wideTile || w.tallTile
                    }
                }

                Item { Layout.fillWidth: true }

                // Min / Avg / Max Badges
                RowLayout {
                    spacing: 6
                    visible: w.showMinMax && w.wideTile

                    Rectangle {
                        color: Qt.rgba(1, 1, 1, 0.06); radius: 4
                        implicitWidth: minLbl.implicitWidth + 8; implicitHeight: 20
                        Text { id: minLbl; anchors.centerIn: parent; text: "MIN " + w.formattedMin; color: theme.textSecondary; font.pixelSize: 11; font.family: theme.fontMono; font.bold: true }
                    }
                    Rectangle {
                        color: Qt.rgba(1, 1, 1, 0.06); radius: 4
                        implicitWidth: avgLbl.implicitWidth + 8; implicitHeight: 20
                        Text { id: avgLbl; anchors.centerIn: parent; text: "AVG " + w.formattedAvg; color: theme.textPrimary; font.pixelSize: 11; font.family: theme.fontMono; font.bold: true }
                    }
                    Rectangle {
                        color: Qt.rgba(1, 1, 1, 0.06); radius: 4
                        implicitWidth: maxLbl.implicitWidth + 8; implicitHeight: 20
                        Text { id: maxLbl; anchors.centerIn: parent; text: "MAX " + w.formattedMax; color: theme.textSecondary; font.pixelSize: 11; font.family: theme.fontMono; font.bold: true }
                    }
                }

                // Range Tag
                Rectangle {
                    color: theme.cardBorder
                    radius: 4
                    implicitWidth: rangeTxt.implicitWidth + 8
                    implicitHeight: 20
                    Text {
                        id: rangeTxt
                        anchors.centerIn: parent
                        text: w.rangeLabel
                        color: theme.textTertiary
                        font.pixelSize: 11
                        font.family: theme.fontMono
                        font.bold: true
                    }
                }
            }

            // Expanded Summary Row (when expanded is true)
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                visible: w.expanded

                Rectangle {
                    Layout.fillWidth: true; Layout.preferredHeight: 52; radius: theme.radiusSm; color: theme.cardBackgroundAlt
                    ColumnLayout { anchors.centerIn: parent; spacing: 2
                        Text { text: "CURRENT"; color: theme.textSecondary; font.pixelSize: 11; font.family: theme.fontMono; font.bold: true; Layout.alignment: Qt.AlignCenter }
                        Text { text: w.formattedLatest + " " + w.effectiveUnit; color: w.statusColor; font.pixelSize: 16; font.family: theme.fontDisplay; font.bold: true; Layout.alignment: Qt.AlignCenter }
                    }
                }
                Rectangle {
                    Layout.fillWidth: true; Layout.preferredHeight: 52; radius: theme.radiusSm; color: theme.cardBackgroundAlt
                    ColumnLayout { anchors.centerIn: parent; spacing: 2
                        Text { text: "MINIMUM"; color: theme.textSecondary; font.pixelSize: 11; font.family: theme.fontMono; font.bold: true; Layout.alignment: Qt.AlignCenter }
                        Text { text: w.formattedMin + " " + w.effectiveUnit; color: theme.textPrimary; font.pixelSize: 16; font.family: theme.fontDisplay; font.bold: true; Layout.alignment: Qt.AlignCenter }
                    }
                }
                Rectangle {
                    Layout.fillWidth: true; Layout.preferredHeight: 52; radius: theme.radiusSm; color: theme.cardBackgroundAlt
                    ColumnLayout { anchors.centerIn: parent; spacing: 2
                        Text { text: "AVERAGE"; color: theme.textSecondary; font.pixelSize: 11; font.family: theme.fontMono; font.bold: true; Layout.alignment: Qt.AlignCenter }
                        Text { text: w.formattedAvg + " " + w.effectiveUnit; color: theme.textPrimary; font.pixelSize: 16; font.family: theme.fontDisplay; font.bold: true; Layout.alignment: Qt.AlignCenter }
                    }
                }
                Rectangle {
                    Layout.fillWidth: true; Layout.preferredHeight: 52; radius: theme.radiusSm; color: theme.cardBackgroundAlt
                    ColumnLayout { anchors.centerIn: parent; spacing: 2
                        Text { text: "MAXIMUM"; color: theme.textSecondary; font.pixelSize: 11; font.family: theme.fontMono; font.bold: true; Layout.alignment: Qt.AlignCenter }
                        Text { text: w.formattedMax + " " + w.effectiveUnit; color: theme.textPrimary; font.pixelSize: 16; font.family: theme.fontDisplay; font.bold: true; Layout.alignment: Qt.AlignCenter }
                    }
                }
                Rectangle {
                    Layout.fillWidth: true; Layout.preferredHeight: 52; radius: theme.radiusSm; color: theme.cardBackgroundAlt
                    ColumnLayout { anchors.centerIn: parent; spacing: 2
                        Text { text: "NET DELTA"; color: theme.textSecondary; font.pixelSize: 11; font.family: theme.fontMono; font.bold: true; Layout.alignment: Qt.AlignCenter }
                        Text { text: (w.deltaVal >= 0 ? "+" : "") + w.formatValue(w.deltaVal); color: w.deltaVal >= 0 ? theme.catSystem : theme.catServices; font.pixelSize: 16; font.family: theme.fontMono; font.bold: true; Layout.alignment: Qt.AlignCenter }
                    }
                }
            }

            // Canvas Vector Chart (Both compact and expanded)
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                Canvas {
                    id: chartCanvas
                    anchors.fill: parent
                    renderTarget: Canvas.FramebufferObject

                    onPaint: {
                        var ctx = getContext("2d")
                        ctx.reset()
                        var cw = width, ch = height
                        if (cw <= 0 || ch <= 0 || w.dataPoints.length < 2) return

                        var pts = w.dataPoints
                        var minV = w.effectiveMinVal
                        var maxV = w.effectiveMaxVal
                        var span = maxV - minV
                        if (span <= 0.0001) span = 1.0

                        var padTop = w.expanded ? 14 : 8
                        var padBot = w.expanded ? 14 : 8
                        var drawH = ch - padTop - padBot

                        // Horizontal baseline guides
                        ctx.strokeStyle = w.expanded ? "rgba(255, 255, 255, 0.12)" : "rgba(255, 255, 255, 0.08)"
                        ctx.lineWidth = 1
                        ctx.beginPath()
                        ctx.moveTo(0, padTop)
                        ctx.lineTo(cw, padTop)
                        ctx.moveTo(0, padTop + drawH / 2)
                        ctx.lineTo(cw, padTop + drawH / 2)
                        ctx.moveTo(0, padTop + drawH)
                        ctx.lineTo(cw, padTop + drawH)
                        ctx.stroke()

                        // Y-axis guide labels
                        ctx.font = (w.expanded ? "10px " : "9px ") + theme.fontMono
                        ctx.fillStyle = "rgba(255, 255, 255, 0.35)"
                        ctx.textAlign = "left"
                        ctx.textBaseline = "bottom"
                        ctx.fillText(w.formatValue(maxV), 4, padTop - 1)
                        ctx.textBaseline = "middle"
                        ctx.fillText(w.formatValue(minV + span / 2), 4, padTop + drawH / 2)
                        ctx.textBaseline = "top"
                        ctx.fillText(w.formatValue(minV), 4, padTop + drawH + 1)

                        // Calculate points on canvas
                        var coords = []
                        for (var i = 0; i < pts.length; i++) {
                            var px = (i / (pts.length - 1)) * cw
                            var norm = (pts[i].v - minV) / span
                            var clampedNorm = Math.max(0, Math.min(1.0, norm))
                            var py = padTop + drawH - (clampedNorm * drawH)
                            coords.push({ x: px, y: py, v: pts[i].v, t: pts[i].t })
                        }

                        // Draw filled area gradient
                        if (w.chartType === "area" && w.fillGlow) {
                            var grad = ctx.createLinearGradient(0, padTop, 0, ch)
                            var baseCol = w.statusColor
                            grad.addColorStop(0, Qt.rgba(baseCol.r, baseCol.g, baseCol.b, w.expanded ? 0.40 : 0.35))
                            grad.addColorStop(1, Qt.rgba(baseCol.r, baseCol.g, baseCol.b, 0.0))

                            ctx.fillStyle = grad
                            ctx.beginPath()
                            ctx.moveTo(coords[0].x, ch)
                            ctx.lineTo(coords[0].x, coords[0].y)
                            for (var j = 1; j < coords.length; j++) {
                                ctx.lineTo(coords[j].x, coords[j].y)
                            }
                            ctx.lineTo(coords[coords.length - 1].x, ch)
                            ctx.closePath()
                            ctx.fill()
                        }

                        // Draw path line
                        ctx.strokeStyle = w.statusColor
                        ctx.lineWidth = w.expanded ? 3.0 : 2.5
                        ctx.lineJoin = "round"
                        ctx.lineCap = "round"
                        ctx.beginPath()
                        ctx.moveTo(coords[0].x, coords[0].y)
                        for (var k = 1; k < coords.length; k++) {
                            ctx.lineTo(coords[k].x, coords[k].y)
                        }
                        ctx.stroke()

                        // Scrubber hairline
                        if (w.scrubNormalizedX >= 0 && coords.length > 0) {
                            var scrubIdx = Math.max(0, Math.min(coords.length - 1, Math.round(w.scrubNormalizedX * (coords.length - 1))))
                            var sp = coords[scrubIdx]
                            w.scrubPoint = sp

                            ctx.strokeStyle = "rgba(255, 255, 255, 0.5)"
                            ctx.lineWidth = 1
                            ctx.beginPath()
                            ctx.moveTo(sp.x, 0)
                            ctx.lineTo(sp.x, ch)
                            ctx.stroke()

                            // Highlight dot
                            ctx.fillStyle = w.statusColor
                            ctx.beginPath()
                            ctx.arc(sp.x, sp.y, w.expanded ? 5 : 4, 0, 2 * Math.PI)
                            ctx.fill()
                        }
                    }
                }

                // Interactive touch / hover scrubber
                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    onPositionChanged: function (mouse) {
                        w.scrubNormalizedX = Math.max(0, Math.min(1.0, mouse.x / width))
                        chartCanvas.requestPaint()
                    }
                    onExited: {
                        w.scrubNormalizedX = -1
                        w.scrubPoint = null
                        chartCanvas.requestPaint()
                    }
                }

                // Scrubber Tooltip Bubble
                Rectangle {
                    visible: w.scrubPoint !== null && w.scrubNormalizedX >= 0
                    x: w.scrubPoint ? Math.max(4, Math.min(parent.width - width - 4, w.scrubPoint.x - width / 2)) : 0
                    y: 4
                    width: scrubTxt.implicitWidth + 12
                    height: 22
                    radius: 4
                    color: Qt.rgba(0, 0, 0, 0.85)
                    border.color: theme.cardBorder
                    border.width: 1

                    Text {
                        id: scrubTxt
                        anchors.centerIn: parent
                        text: w.scrubPoint ? (w.formatValue(w.scrubPoint.v) + " " + w.effectiveUnit) : ""
                        color: theme.textPrimary
                        font.pixelSize: 12
                        font.family: theme.fontMono
                        font.bold: true
                    }
                }
            }
        }
    }
}
