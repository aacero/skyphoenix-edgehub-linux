import QtQuick
import QtQuick.Layouts

// Network throughput - real up/down byte-rates from the Rust core, with a
// live sparkline of recent activity (history kept in-widget).
//
// Sizing (W1 wave 2a): layout keys off the injected `sizeClass`.
//   • 0.5x0.5 (micro) - headerless; the two rates, big and centred. No graph.
//   • 1x1 (baseline)  - rates row above the sparkline (the classic tile).
//   • wide            - rates (+ session peaks) beside a full-width sparkline.
//   • tall            - rates + session peaks above a sparkline that earns the
//                       height (peaks are genuinely more information).
//   • full (overlay)  - rates left, peaks right, big sparkline below; SIZED by the
//                       pane it is actually given (see rateFont), not by literals.
//                       "full" is NOT a full screen: Dashboard hosts the overlay's
//                       live preview in a pane beside the config form - ~941x456 in
//                       landscape, ~656x980 stacked in portrait - so it is a class
//                       like any other and reads its own box.
WidgetChrome {
    id: w
    property var metrics: ({})
    property bool expanded: false
    property bool active: true
    property var store: null
    property string instanceId: ""

    title: "Network"; iconName: "net"; accentColor: theme.catServices
    showHeader: !micro
    Accessible.role: Accessible.StaticText
    Accessible.name: w.accessibleSummary

    // Live per-instance config (see WidgetConfigSchema "net").
    readonly property var cfg: {
        var _ = store ? store.revision : 0
        return (store && instanceId) ? JSON.parse(JSON.stringify(store.settingsFor(instanceId))) : ({})
    }
    readonly property bool showHistory: cfg.showHistory !== undefined ? cfg.showHistory : true
    readonly property string historyWindow: cfg.historyWindow !== undefined
                                            ? cfg.historyWindow : "2m"
    readonly property string unit: cfg.unit !== undefined ? cfg.unit : "bytes"
    readonly property bool showDetails: cfg.showDetails !== undefined ? cfg.showDetails : true
    readonly property string interfaceName: String(cfg.interfaceName || "").trim()
    readonly property string scaleMode: cfg.scaleMode !== undefined ? cfg.scaleMode : "auto"
    readonly property real fixedScaleMbps: Math.max(1, Number(cfg.fixedScaleMbps || 100))
    readonly property string selectionKey: interfaceName
    property bool componentReady: false
    Component.onCompleted: componentReady = true
    onSelectionKeyChanged: if (componentReady) {
        hist = []
        peakRx = 0
        peakTx = 0
        spark.requestPaint()
        Qt.callLater(_persist)
    }
    onScaleModeChanged: if (componentReady) spark.requestPaint()
    onFixedScaleMbpsChanged: if (componentReady) spark.requestPaint()
    onHistoryWindowChanged: if (componentReady) {
        if (hist.length > historyLimit) hist = hist.slice(hist.length - historyLimit)
        Qt.callLater(_persist)
        spark.requestPaint()
    }

    readonly property bool hasCatalog: metrics.net_interfaces !== undefined
    readonly property var interfaceCatalog: Array.isArray(metrics.net_interfaces)
                                                    ? metrics.net_interfaces : []
    function _included(netif) {
        if (w.interfaceName.length) return String(netif.name) === w.interfaceName
        return netif.category === "physical"
    }
    readonly property var selectedInterfaces: {
        var selected = []
        for (var i = 0; i < w.interfaceCatalog.length; i++)
            if (w._included(w.interfaceCatalog[i])) selected.push(w.interfaceCatalog[i])
        return selected
    }
    readonly property bool explicitAvailable: metrics.net_metrics_available !== undefined
    readonly property bool sourceAvailable: explicitAvailable
                                                    ? metrics.net_metrics_available === true
                                                    : metrics.net_rx_bytes_per_sec !== undefined
                                                      || metrics.net_tx_bytes_per_sec !== undefined
    readonly property bool rateAvailable: {
        if (!w.sourceAvailable) return false
        if (!w.hasCatalog) return true
        if (!w.selectedInterfaces.length) return false
        for (var i = 0; i < w.selectedInterfaces.length; i++)
            if (w.selectedInterfaces[i].rate_available === true) return true
        return false
    }
    function _sum(field, fallback) {
        if (!w.hasCatalog) return Number(metrics[fallback] || 0)
        var total = 0
        for (var i = 0; i < w.selectedInterfaces.length; i++)
            total += Number(w.selectedInterfaces[i][field] || 0)
        return total
    }
    property real rx: w._sum("rx_bytes_per_sec", "net_rx_bytes_per_sec")
    property real tx: w._sum("tx_bytes_per_sec", "net_tx_bytes_per_sec")
    readonly property real rxTotal: w._sum("rx_total_bytes", "net_rx_total_bytes")
    readonly property real txTotal: w._sum("tx_total_bytes", "net_tx_total_bytes")
    readonly property real dropped: w._sum("rx_dropped", "net_rx_dropped")
                                    + w._sum("tx_dropped", "net_tx_dropped")
    readonly property real errors: w._sum("rx_errors", "net_rx_errors")
                                   + w._sum("tx_errors", "net_tx_errors")
    function interfaceIdentity(netif) {
        var name = String(netif.name || "interface")
        var friendly = String(netif.friendly_name || "")
        return friendly.length ? friendly + " (" + name + ")" : name
    }
    readonly property string selectedLabel: {
        if (w.selectedInterfaces.length === 1)
            return w.interfaceIdentity(w.selectedInterfaces[0])
        if (w.interfaceName.length) return w.interfaceName
        if (!w.hasCatalog) return "physical links"
        return w.selectedInterfaces.length + " physical links"
    }
    readonly property string linkDetail: {
        if (w.selectedInterfaces.length !== 1) return ""
        var netif = w.selectedInterfaces[0]
        var parts = [String(netif.link_state || "unknown"),
                     String(netif.category || "interface")]
        if (netif.speed_mbps !== undefined && netif.speed_mbps !== null)
            parts.push(String(netif.speed_mbps) + " Mbps link")
        return parts.join(" · ")
    }
    readonly property string unavailableReason: {
        if (!w.sourceAvailable)
            return String(metrics.net_unavailable_reason || "Network metrics are unavailable")
        if (w.interfaceName.length && !w.selectedInterfaces.length)
            return "Interface " + w.interfaceName + " is not available"
        if (!w.selectedInterfaces.length)
            return String(metrics.net_unavailable_reason || "No matching network interfaces")
        return "Waiting for a second network sample"
    }
    readonly property string freshness: {
        if (!w.sourceAvailable) return "unavailable"
        if (String(metrics.net_sample_status || "") === "warming") return "sampling"
        if (w.hasCatalog && !w.selectedInterfaces.length) return "unavailable"
        if (w.hasCatalog && !w.rateAvailable) return "sampling"
        var stamp = Number(metrics.net_sample_unix_ms || 0)
        if (stamp <= 0) return "live"
        var age = Math.max(0, Math.floor((Date.now() - stamp) / 1000))
        return age < 2 ? "updated now" : "updated " + age + "s ago"
    }
    readonly property string sourceMode: w.interfaceName.length
                                         ? "Selected interface" : "Physical aggregate"
    readonly property string accessibleSummary: {
        var parts = ["Network", w.sourceMode, w.selectedLabel]
        if (w.rateAvailable) {
            parts.push("download " + w.fmt(w.rx))
            parts.push("upload " + w.fmt(w.tx))
            if (w.linkDetail.length) parts.push(w.linkDetail)
        } else {
            parts.push(w.unavailableReason)
        }
        if (w.showHistory)
            parts.push(w.historyLabel + " history, " + w.graphScaleLabel)
        return parts.join(", ")
    }
    status: w.explicitAvailable ? w.freshness : ""
    statusColor: w.rateAvailable ? theme.textSecondary : theme.warning

    property real peakRx: 0
    property real peakTx: 0
    property var hist: []
    function fmt(bps) {
        if (w.unit === "bits") {
            var mb = bps * 8 / 1e6
            // Step down to Kbps for small values so it doesn't read "0.0 Mbps".
            return mb < 1 ? (bps * 8 / 1e3).toFixed(0) + " Kbps" : mb.toFixed(1) + " Mbps"
        }
        // Round to whole bytes FIRST, then pick the unit - otherwise a value like
        // 1023.7 takes the B/s branch and rounds up to a nonsensical "1024 B/s".
        var b = Math.round(bps)
        if (b >= 1048576) return (b / 1048576).toFixed(1) + " MiB/s"
        if (b >= 1024) return (b / 1024).toFixed(0) + " KiB/s"
        return b + " B/s"
    }
    function fmtTotal(bytes) {
        var b = Math.max(0, Number(bytes || 0))
        if (b >= 1e12) return (b / 1e12).toFixed(1) + " TB"
        if (b >= 1e9) return (b / 1e9).toFixed(1) + " GB"
        if (b >= 1e6) return (b / 1e6).toFixed(1) + " MB"
        if (b >= 1e3) return (b / 1e3).toFixed(1) + " KB"
        return Math.round(b) + " B"
    }
    function resetSession() {
        w.hist = []
        w.peakRx = 0
        w.peakTx = 0
        w._persist()
        spark.requestPaint()
    }

    // Session peaks + sparkline history live in the shared store (keyed by
    // instanceId) so a tile and its expanded overlay - separate instances - share
    // the same accumulated state instead of resetting to 0/empty on every open (S5).
    function _persist() {
        if (!store || !instanceId) return
        store.patchSettings(instanceId, { hist: w.hist, peakRx: w.peakRx, peakTx: w.peakTx })
    }
    function _restoreState() {
        if (!store || !instanceId) return
        var s = store.settingsFor(instanceId)
        w.hist = Array.isArray(s.hist) ? JSON.parse(JSON.stringify(s.hist)) : []
        w.peakRx = s.peakRx !== undefined ? Number(s.peakRx) : 0
        w.peakTx = s.peakTx !== undefined ? Number(s.peakTx) : 0
        spark.requestPaint()
    }
    onStoreChanged: _restoreState()
    onInstanceIdChanged: _restoreState()

    onMetricsChanged: {
        // Honour `active`: an off-page/hidden instance must not keep accumulating
        // (S3). Read the freshly-changed `metrics` directly - the derived rx/tx
        // bindings lag one frame behind this handler.
        if (!w.active) return
        var m = w.metrics || ({})
        if (m.net_metrics_available === false || m.net_sample_status === "warming") return
        var r = 0, t = 0, found = false
        if (Array.isArray(m.net_interfaces)) {
            for (var i = 0; i < m.net_interfaces.length; i++) {
                var netif = m.net_interfaces[i]
                if (!w._included(netif) || netif.rate_available !== true) continue
                r += Number(netif.rx_bytes_per_sec || 0)
                t += Number(netif.tx_bytes_per_sec || 0)
                found = true
            }
        } else {
            found = m.net_rx_bytes_per_sec !== undefined || m.net_tx_bytes_per_sec !== undefined
            r = Number(m.net_rx_bytes_per_sec || 0)
            t = Number(m.net_tx_bytes_per_sec || 0)
        }
        if (!found) return
        var nextHistory = hist.slice()
        nextHistory.push({ r: r, t: t })
        while (nextHistory.length > w.historyLimit) nextHistory.shift()
        hist = nextHistory
        if (r > peakRx) peakRx = r
        if (t > peakTx) peakTx = t
        _persist()
        spark.requestPaint()
    }
    onEffAccentChanged: spark.requestPaint()

    // ── Per-size layout (sizeClass injected by Dashboard) ────────────────────
    readonly property bool horiz: sizeClass === "wide"

    // Does this instance have half-screen room? The same predicate HabitWidget
    // derives, for the same reason: Dashboard injects a sizeClass, never a size
    // NAME, so the question has to be answered from the room itself. Among the
    // sizes this widget declares, 1x1.5 is the only one that is BOTH off-square and
    // full-short-axis (696x1229 portrait / 1269x612 landscape, short side >= 612),
    // where 0.5x1 and 1x0.5 stop at 423 - so WidgetChrome's own 480 half-cell
    // threshold separates them here too, with no size-name special case. `large`
    // and `full` are roomier still; this widget declares no `large` tile, but it
    // must not read as cramped if it ever does.
    readonly property bool roomy: sizeClass === "large" || sizeClass === "full"
        || ((sizeClass === "tall" || sizeClass === "wide")
            && Math.min(width, height) >= 480)

    // Session peaks earn a place wherever there is room beyond the baseline:
    // the overlay (as before), and now also tall/wide tiles.
    // The `expanded ||` this used to lead with was already DEAD - the overlay is
    // injected as sizeClass "full", which `big` already covers - but it said the
    // decision was partly the overlay's, which is the habit being removed.
    readonly property bool showPeaks: !micro && (big || horiz)
    readonly property int historyLimit: w.historyWindow === "1m" ? 30
                                        : w.historyWindow === "5m" ? 150 : 60
    readonly property string historyLabel: w.historyWindow === "1m" ? "1 minute"
                                           : w.historyWindow === "5m" ? "5 minutes"
                                                                      : "2 minutes"
    readonly property real graphMaxBytesPerSecond: {
        if (w.scaleMode === "fixed") return w.fixedScaleMbps * 1000000 / 8
        var maximum = 0
        for (var i = 0; i < w.hist.length; i++)
            maximum = Math.max(maximum, Number(w.hist[i].r || 0),
                               Number(w.hist[i].t || 0))
        return maximum
    }
    readonly property string graphScaleLabel: w.scaleMode === "fixed"
                                              ? "Fixed ceiling " + w.fmt(w.graphMaxBytesPerSecond)
                                              : w.graphMaxBytesPerSecond > 0
                                                ? "Auto ceiling " + w.fmt(w.graphMaxBytesPerSecond)
                                                : "Auto scale"

    // Rate text scales with the box: the micro tile IS the two numbers.
    //
    // This used to open with `expanded ? 30`, a literal frozen twice over: it
    // ignored the box it was actually in, and it never noticed when W5 shrank the
    // overlay's live-preview pane to 38% of the width in landscape. Worse, 30 beat
    // the 26 a 1x1.5 tile got - a tile with FAR more room than that pane.
    //
    // The height term is new and binds nowhere on a shipped tile (the 26 cap
    // already did): it exists so the overlay's short 456px landscape pane cannot
    // let width alone overreach. Only `roomy` boxes are allowed past 26.
    readonly property real rateFont: micro
        ? Math.max(20, Math.min(width * 0.115, 38))
        : (big || horiz)
        ? Math.max(16, Math.min(width * 0.05, height * 0.09, w.roomy ? 40 : 26))
        : Math.max(15, Math.min(width * 0.032, 22))

    GridLayout {
        id: lay
        objectName: "netOuterLayout"
        anchors.fill: parent
        anchors.margins: theme.spacingSm
        columns: w.horiz ? 2 : 1
        // Air is room, not mode. 10 was "the overlay" and 4 "not the overlay";
        // what earns the wider gap is having the space for it, which is the same
        // `roomy` predicate rateFont's cap uses - so a 1x1.5 tile, whose rates are
        // now ~35px, gets the breathing room its own contents ask for instead of
        // the baseline third's tighter 4. Compact/micro tiles are unchanged.
        rowSpacing: w.roomy ? 10 : 4
        columnSpacing: theme.spacingLg

        // Rates block (+ peaks beside in the overlay, beneath on tall/wide).
        GridLayout {
            // DELIBERATELY still keyed off the mode, with `alignment` below - and
            // the second of the two legitimate cases in this file (see `status` on
            // WidgetChrome). This is COMPOSITION - which side the peaks sit on -
            // not a dimension. No box measurement makes one arrangement correct:
            // a 696-wide 1x1.5 tile and the 656-wide portrait overlay pane have
            // effectively the same width and genuinely want different compositions,
            // because one is a thing you glance at and the other is the thing you
            // opened. `expanded` is the honest question there. Sizes are not
            // allowed to ask it; what-goes-where is.
            columns: w.expanded ? 2 : 1
            rowSpacing: 2; columnSpacing: theme.spacingLg
            Layout.fillWidth: !w.horiz
            // micro (no graph): the rates are the tile - centre them in it.
            Layout.fillHeight: w.micro || !w.showHistory
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredWidth: w.horiz ? Math.round(lay.width * 0.36) : -1

            ColumnLayout {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                spacing: w.micro ? 2 : 0
                Text { text: "↓ " + (w.micro ? "" : "Download  ")
                              + (w.rateAvailable ? w.fmt(w.rx)
                                                 : w.freshness === "sampling" ? "Sampling" : "N/A")
                    color: w.rateAvailable ? theme.success : theme.textSecondary; font.bold: true
                    font.family: theme.fontMono; font.pixelSize: Math.round(w.rateFont)
                    fontSizeMode: Text.HorizontalFit; minimumPixelSize: theme.fontMinimum
                    Layout.fillWidth: true; elide: Text.ElideRight
                    horizontalAlignment: w.micro ? Text.AlignHCenter : Text.AlignLeft
                    Accessible.name: w.rateAvailable ? "Download " + w.fmt(w.rx)
                                                     : "Download " + w.unavailableReason }
                Text { text: "↑ " + (w.micro ? "" : "Upload  ")
                              + (w.rateAvailable ? w.fmt(w.tx)
                                                 : w.freshness === "sampling" ? "Sampling" : "N/A")
                    color: w.rateAvailable ? w.effAccent : theme.textSecondary; font.bold: true
                    font.family: theme.fontMono; font.pixelSize: Math.round(w.rateFont)
                    fontSizeMode: Text.HorizontalFit; minimumPixelSize: theme.fontMinimum
                    Layout.fillWidth: true; elide: Text.ElideRight
                    horizontalAlignment: w.micro ? Text.AlignHCenter : Text.AlignLeft
                    Accessible.name: w.rateAvailable ? "Upload " + w.fmt(w.tx)
                                                     : "Upload " + w.unavailableReason }
                Text {
                    visible: w.showDetails && !w.micro
                    text: w.rateAvailable
                          ? w.selectedLabel
                            + (w.linkDetail.length ? " · " + w.linkDetail : "")
                            + " · " + w.sourceMode
                          : w.unavailableReason
                    color: w.rateAvailable ? theme.textPrimary : theme.warning
                    font.pixelSize: theme.fontLabel
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
                Text {
                    visible: w.showDetails && (w.expanded || w.roomy) && w.rateAvailable
                    text: "total ↓ " + w.fmtTotal(w.rxTotal) + "  ↑ " + w.fmtTotal(w.txTotal)
                    color: theme.textPrimary
                    font.family: theme.fontMono
                    font.pixelSize: w.roomy ? theme.fontLabel : theme.fontMinimum
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
                Text {
                    visible: w.showDetails && (w.expanded || w.roomy) && w.rateAvailable
                    text: "drops " + w.dropped + "  errors " + w.errors
                    color: (w.dropped + w.errors) > 0 ? theme.warning : theme.textSecondary
                    font.family: theme.fontMono
                    font.pixelSize: w.roomy ? theme.fontLabel : theme.fontMinimum
                    Layout.fillWidth: true
                }
            }
            // Session peaks - "best so far". Right-aligned beside the rates in
            // the overlay; a quiet line under them on tall/wide tiles.
            // The peaks are a SECONDARY readout of the rates, so they are sized
            // from the rates rather than re-deriving the box: `expanded ? 14`
            // cost nothing to drop on its own (both overlay panes drive the old
            // width term straight into its own 14 cap), but it left the peaks
            // pinned at 14 next to a rate number that had grown to 40. Tied to
            // rateFont they stay legible against it at every box. The `alignment`
            // ternaries below are composition, not size - see `columns` above.
            ColumnLayout {
                visible: w.showPeaks; spacing: 0
                Layout.alignment: w.expanded ? (Qt.AlignRight | Qt.AlignVCenter) : Qt.AlignLeft
                Text { text: "peak ↓ " + w.fmt(w.peakRx); color: theme.textPrimary
                    font.family: theme.fontMono
                    font.pixelSize: Math.round(Math.max(theme.fontMinimum,
                                                       Math.min(w.rateFont * 0.52, theme.fontTitle)))
                    horizontalAlignment: w.expanded ? Text.AlignRight : Text.AlignLeft
                    Layout.alignment: w.expanded ? Qt.AlignRight : Qt.AlignLeft }
                Text { text: "peak ↑ " + w.fmt(w.peakTx); color: theme.textPrimary
                    font.family: theme.fontMono
                    font.pixelSize: Math.round(Math.max(theme.fontMinimum,
                                                       Math.min(w.rateFont * 0.52, theme.fontTitle)))
                    horizontalAlignment: w.expanded ? Text.AlignRight : Text.AlignLeft
                    Layout.alignment: w.expanded ? Qt.AlignRight : Qt.AlignLeft }
                Rectangle {
                    objectName: "resetNetworkSession"
                    visible: w.expanded
                    Layout.alignment: Qt.AlignRight
                    Layout.topMargin: 6
                    Layout.minimumWidth: 128
                    Layout.minimumHeight: 48
                    implicitWidth: 128
                    implicitHeight: 48
                    activeFocusOnTab: true
                    radius: theme.radiusMd
                    color: resetTap.pressed ? theme.cardBorder : theme.cardBackground
                    border.width: activeFocus ? 2 : 1
                    border.color: activeFocus ? w.effAccent : theme.cardBorder
                    Accessible.role: Accessible.Button
                    Accessible.name: "Reset network session"
                    Keys.onSpacePressed: w.resetSession()
                    Keys.onReturnPressed: w.resetSession()
                    Text {
                        anchors.centerIn: parent
                        text: "Reset session"
                        color: theme.textPrimary
                        font.pixelSize: theme.fontMinimum
                        font.bold: true
                    }
                    TapHandler {
                        id: resetTap
                        onTapped: w.resetSession()
                    }
                }
            }
        }

        ColumnLayout {
            visible: w.showHistory && !w.micro
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: theme.spacingXs

            GridLayout {
                Layout.fillWidth: true
                columns: width >= 520 ? 2 : 1
                Text {
                    text: w.historyLabel.toUpperCase() + " THROUGHPUT"
                    color: theme.textPrimary
                    font.pixelSize: theme.fontLabel
                    font.bold: true
                    font.letterSpacing: 0.8
                    Layout.fillWidth: true
                }
                Text {
                    text: w.graphScaleLabel
                    color: theme.textPrimary
                    font.pixelSize: theme.fontLabel
                    font.family: theme.fontMono
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                    horizontalAlignment: parent.columns === 2 ? Text.AlignRight : Text.AlignLeft
                }
            }
            Canvas {
                id: spark
                visible: w.showHistory && !w.micro
                Layout.fillWidth: true
                Layout.fillHeight: true
                onPaint: {
                    var ctx = getContext('2d'); ctx.clearRect(0, 0, width, height)
                    if (w.hist.length < 2 || width <= 0 || height <= 0) return
                    var max = Math.max(1, w.graphMaxBytesPerSecond)
                    function line(key, color) {
                        ctx.beginPath()
                        for (var j = 0; j < w.hist.length; j++) {
                            var x = j * width / (w.hist.length - 1)
                            var y = height - (w.hist[j][key] / max) * height * 0.92 - 2
                            j === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y)
                        }
                        ctx.strokeStyle = color; ctx.lineWidth = 2; ctx.stroke()
                    }
                    line("r", theme.success)
                    line("t", w.effAccent)
                }
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()
            }
        }
    }
}
