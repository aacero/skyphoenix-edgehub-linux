import QtQuick
import QtQuick.Layouts

// HTTP / JSON - the generic data-connected primitive. Polls a URL, pulls a value
// out of the JSON response by a dot/bracket path, and shows it as a number, a
// gauge, or a short list. All egress goes through NetHub (never a raw XHR), so
// "no telemetry / local-only" stays provable and a global offline switch / host
// allowlist governs it centrally.
//
// Live results (value/text/error/history) are mirrored into the SHARED per-instance
// store settings and registered as EPHEMERAL keys, so: (a) the compact tile and its
// expanded overlay show the same reading without polling twice, and (b) a poll every
// N seconds never rewrites config.toml (the flash-wear win already used by metrics).
//
// Sizing (W1 wave 3): 3 modes x 6 declared sizes, so layout keys off `sizeClass`
// per MODE rather than once for the widget:
//   • value - micro is the number alone (no trend, no path); the baseline adds
//     the trend; wide puts the trend BESIDE the number; tall/large hand it the
//     height. The number scales with the box (it was a flat 32px everywhere).
//   • gauge - delegates to the shared MetricGauge and drives its wave-2a knobs
//     (showSpark / horizontal / sparkFills / bigMax), exactly as CpuWidget does.
//   • list  - rows scale with the box, and the row count follows the same rule
//     calendar applies to maxEvents (see `listShown`).
//
// The UNCONFIGURED state ("Add a URL in settings") is what ships in the presets,
// so it is sized from the box and asserted legible at every size x mode.
WidgetChrome {
    id: w
    property var metrics: ({})
    property bool expanded: false
    property bool active: true
    property var store: null
    property string instanceId: ""
    property int tick: 0
    property double nowMsOverride: -1
    // The egress gate. Injected by Dashboard (one app-global instance); a local
    // fallback keeps the widget self-contained in tests / standalone use.
    property var netHub: null
    NetHub { id: _fallbackHub }
    function _hub() { return netHub ? netHub : _fallbackHub }
    // Test seam (mirrors Weather): a per-request XHR factory passed through the gate.
    property var xhrFactory: null

    title: "HTTP / JSON"; iconName: "net"; accentColor: theme.catInfo
    showHeader: !micro

    // ── Per-size layout (sizeClass injected by Dashboard) ────────────────────
    // A large allocation can be either a tall portrait column or a wide
    // landscape strip. Read the physical shape for large tiles so 1x2 does not
    // keep the portrait composition after the display turns.
    readonly property bool horiz: sizeClass === "wide"
                                  || (sizeClass === "large" && width > height * 1.4)
    readonly property bool tallish: sizeClass === "tall"
                                    || (sizeClass === "large" && !horiz)
    // Anything beyond the bare reading needs more than a half-cell.
    readonly property bool rich: !micro

    // The reading's type, sized from the box (it was a flat 32px on every tile,
    // so a 696x1637 box printed a 32px number).
    readonly property real valuePx: w.expanded ? 72
        : w.micro ? Math.max(20, Math.min(w.width * 0.26, w.height * 0.30, 76))
        : w.horiz ? Math.max(20, Math.min(w.width * 0.13, w.height * 0.34, 84))
        : Math.max(20, Math.min(w.width * 0.20, w.height * 0.16, 84))
    readonly property real unitPx: Math.max(theme.fontMinimum, Math.round(w.valuePx * 0.28))
    readonly property real hintPx: Math.max(theme.fontMinimum,
                                            Math.min(w.width * 0.038, w.height * 0.05,
                                                         w.expanded ? 16 : 15))

    // ── list mode: how many rows, and the same rule calendar uses ────────────
    // `listMax` is a MAXIMUM the user asks for (schema: 1..12); the SIZE decides
    // how many of those actually fit. Never more than asked for, never more than
    // we have, never an overflowing box.
    readonly property real listRowH: Math.max(36, Math.min(height * 0.06, 48))
    readonly property int listRowsFit: {
        var avail = w.height - w.headerHeight - 2 * theme.spacingSm
                    - (w.micro ? 0 : theme.touchTertiary)
        return Math.max(1, Math.floor(avail / (w.listRowH + 2)))
    }
    // listMax remains the user's maximum in every host, including the overlay.
    readonly property int listWant: w.listMax
    readonly property int listShown: w.expanded
        ? Math.min(w.listWant, w.listItems.length)
        : Math.max(0, Math.min(w.listWant, w.listItems.length, w.listRowsFit))

    readonly property var cfg: {
        var _ = store ? store.revision : 0
        return (store && instanceId) ? JSON.parse(JSON.stringify(store.settingsFor(instanceId))) : ({})
    }
    readonly property string url: cfg.url || ""
    readonly property string jsonPath: cfg.jsonPath || ""
    readonly property int pollSec: cfg.pollSec !== undefined ? Math.max(5, cfg.pollSec) : 60
    readonly property string mode: cfg.mode || "value"          // value | gauge | list
    readonly property string unit: cfg.unit || ""
    readonly property real gaugeMax: cfg.gaugeMax !== undefined ? cfg.gaugeMax : 100
    readonly property int listMax: cfg.listMax !== undefined
        ? Math.max(1, Math.min(12, cfg.listMax)) : 5
    readonly property string authToken: cfg.authToken || ""
    readonly property int decimals: Math.max(0, Math.min(6,
        Number(cfg.decimals !== undefined ? cfg.decimals : 1)))
    // Thresholds: value ≥ warnAt → amber, ≥ critAt → red. Blank/NaN disables.
    readonly property real warnAt: cfg.warnAt !== undefined && cfg.warnAt !== "" ? Number(cfg.warnAt) : NaN
    readonly property real critAt: cfg.critAt !== undefined && cfg.critAt !== "" ? Number(cfg.critAt) : NaN

    // ── Live (ephemeral, store-shared) state ────────────────────────────────
    readonly property string valText: cfg.httpText !== undefined ? cfg.httpText : ""
    readonly property var valNum: cfg.httpVal   // number or undefined
    readonly property string errText: cfg.httpErr || ""
    readonly property string errorHelp: cfg.httpHelp || ""
    readonly property var listItems: cfg.httpList || []
    readonly property double lastSuccessAt: Number(cfg.httpAt || 0)
    readonly property int staleAfterSec: Math.max(30, w.pollSec * 3)
    function currentMs() { return w.nowMsOverride >= 0 ? w.nowMsOverride : Date.now() }
    ProviderState {
        id: provider
        configured: w.url.length > 0
        loading: w._xhr !== null
        hasData: w.mode === "list"
            ? w.listItems.length > 0
            : (typeof w.valNum === "number" || (w.valText.length > 0 && w.valText !== "-"))
        errorText: w.errText
        lastSuccessAt: w.lastSuccessAt
        nowMs: (w.tick, w.currentMs())
        staleAfterSec: w.staleAfterSec
    }
    readonly property string providerState: provider.state
    readonly property int ageSec: provider.ageSec
    readonly property bool stale: provider.isStale
    readonly property string freshnessText: provider.freshnessText
    property var hist: []
    property string connectionStatus: ""
    property bool testingConnection: false
    property var _testXhr: null

    function _seedHist() {
        if (w.store && w.instanceId && (!w.hist || w.hist.length === 0)) {
            var s = w.store.settingsFor(w.instanceId)
            if (s.hist && s.hist.length) w.hist = s.hist.slice()
        }
    }
    onStoreChanged: _seedHist()
    onInstanceIdChanged: _seedHist()

    // ── JSON path resolver (dot + [index], e.g. "data.items[0].value") ──────
    function resolvePath(obj, path) {
        if (!path || !path.length) return obj
        var parts = ("" + path).replace(/\[(\w+)\]/g, ".$1").replace(/^\./, "").split(".")
        var cur = obj
        for (var i = 0; i < parts.length; i++) {
            if (cur === null || cur === undefined) return undefined
            cur = cur[parts[i]]
        }
        return cur
    }

    function formatNumber(v) {
        if (!isFinite(v)) return "-"
        if (w.decimals === 0) return "" + Math.round(v)
        return Number(v).toFixed(w.decimals).replace(/\.?0+$/, "")
    }
    function sourceHost() {
        var m = /^[a-z][a-z0-9+.-]*:\/\/([^\/:?#]+)/i.exec(w.url)
        return m ? m[1] : "configured source"
    }

    function threshColor(v) {
        if (typeof v === "number") {
            if (!isNaN(w.critAt) && v >= w.critAt) return theme.error
            if (!isNaN(w.warnAt) && v >= w.warnAt) return theme.warning
        }
        return w.effAccent
    }
    function thresholdLabel(v) {
        if (typeof v !== "number" || isNaN(v)) return ""
        if (!isNaN(w.critAt) && v >= w.critAt) return "Critical"
        if (!isNaN(w.warnAt) && v >= w.warnAt) return "Warning"
        return (!isNaN(w.warnAt) || !isNaN(w.critAt)) ? "Normal" : ""
    }
    readonly property string thresholdState: w.thresholdLabel(w.valNum)
    function errorDetails(reason) {
        if (reason === "offline") return { label: "Offline", help: "Turn off Offline mode, then retry." }
        if (reason === "blocked") return { label: "Blocked", help: "This host is not allowed by the network policy." }
        if (reason === "insecure-auth") return { label: "Blocked", help: "Bearer credentials require an HTTPS URL." }
        if (reason === "response-too-large") return { label: "Response too large", help: "Use an endpoint whose JSON response is at most 1 MiB." }
        if (reason === "timeout") return { label: "Timed out", help: "Check the endpoint and network, then retry." }
        if (reason === "unsupported-scheme") return { label: "Invalid URL", help: "Use a complete HTTP or HTTPS URL." }
        if (reason.indexOf("secret:") === 0) return { label: "Credential unavailable", help: reason.slice(7).trim() }
        if (reason.indexOf("http ") === 0) return { label: "HTTP " + reason.slice(5), help: "The server rejected the request. Check the URL and credentials." }
        return { label: "Unavailable", help: "Check the URL, network, and endpoint response." }
    }
    // The reading's colour - surfaced in the header and the value.
    status: provider.badgeLabel
    statusColor: provider.state === "loading" || provider.state === "unconfigured"
        ? w.effAccent : theme.warning
    readonly property color valColor: w.errText.length ? theme.warning
        : (typeof w.valNum === "number" ? threshColor(w.valNum) : theme.textPrimary)

    // ── Fetch ───────────────────────────────────────────────────────────────
    property var _xhr: null
    Component.onDestruction: {
        if (_xhr) _xhr.abort()
        if (_testXhr) _testXhr.abort()
    }

    function _put(obj) {
        // Persist live results into the shared settings (all ephemeral keys → no
        // disk write, but the expanded overlay + compact tile stay in sync).
        if (w.store && w.instanceId) w.store.patchSettings(w.instanceId, obj)
    }

    function _request(testOnly, gateOverride) {
        if (!w.url.length) {
            if (testOnly) w.connectionStatus = "Add a URL before testing."
            else _put({ httpErr: "", httpHelp: "", httpText: "", httpVal: undefined, httpList: [] })
            return
        }
        if (testOnly) {
            if (w._testXhr) w._testXhr.abort()
            w.testingConnection = true
            w.connectionStatus = "Testing connection..."
        } else if (w._xhr) {
            w._xhr.abort()
        }
        var self = this
        var gate = gateOverride || w._hub()
        var request = gate.request({
            url: w.url,
            // The STORED value (may be a ${env:}/file: ref). NetHub resolves it
            // and builds the header - the widget must never hold the plaintext
            // secret, or it would ride cfgKey/settings into config.toml.
            authToken: w.authToken,
            timeout: 8000,
            xhrFactory: w.xhrFactory,
            onDone: function (status, body) {
                if (testOnly) w._testXhr = null
                else w._xhr = null
                var doc
                try {
                    doc = JSON.parse(body)
                } catch (e) {
                    if (testOnly) {
                        w.testingConnection = false
                        w.connectionStatus = "Connected, but the response is not valid JSON."
                    } else {
                        _put({ httpErr: "Parse error",
                               httpHelp: "The endpoint responded, but its body is not valid JSON." })
                    }
                    return
                }
                var v = self.resolvePath(doc, w.jsonPath)
                if (v === undefined) {
                    if (testOnly) {
                        w.testingConnection = false
                        w.connectionStatus = "Connected, but JSON path \"" + w.jsonPath
                                             + "\" did not match."
                    } else {
                        _put({ httpErr: "No match",
                               httpHelp: "Check the JSON path against the endpoint response.",
                               httpText: "-" })
                    }
                    return
                }
                if (testOnly) {
                    w.testingConnection = false
                    var sample = Array.isArray(v)
                        ? v.length + " list item" + (v.length === 1 ? "" : "s")
                        : (v !== null && typeof v === "object")
                            ? "an object" : String(v).slice(0, 48)
                    w.connectionStatus = "Connected (HTTP " + status + "). Preview: " + sample
                    return
                }
                self._apply(v)
            },
            onError: function (reason) {
                if (testOnly) w._testXhr = null
                else w._xhr = null
                var detail = w.errorDetails(reason)
                if (testOnly) {
                    w.testingConnection = false
                    w.connectionStatus = detail.label + ". " + detail.help
                } else {
                    _put({ httpErr: detail.label, httpHelp: detail.help })
                }
            }
        })
        if (testOnly) w._testXhr = request
        else w._xhr = request
    }

    function refresh() {
        w._request(false, null)
    }

    function testConnection(gateOverride) {
        w._request(true, gateOverride || null)
    }

    // Map a resolved JSON value → display state (text / number / list).
    function _apply(v) {
        var patch = { httpErr: "", httpHelp: "", httpAt: w.currentMs() }
        if (Array.isArray(v)) {
            var items = []
            for (var i = 0; i < v.length && i < 24; i++) {
                var e = v[i]
                items.push((e !== null && typeof e === "object") ? JSON.stringify(e) : ("" + e))
            }
            patch.httpList = items
            patch.httpText = items.length + " item" + (items.length === 1 ? "" : "s")
            patch.httpVal = undefined
        } else if (typeof v === "number") {
            patch.httpVal = v
            patch.httpText = w.formatNumber(v)
            patch.httpList = []
            // Sparkline history (normalised against the gauge max) - shared + ephemeral.
            var h = w.hist.slice()
            var norm = w.gaugeMax > 0 ? Math.max(0, Math.min(1, v / w.gaugeMax)) : 0
            h.push(norm); if (h.length > 48) h.shift()
            w.hist = h
            patch.hist = h
        } else if (typeof v === "boolean") {
            patch.httpVal = undefined; patch.httpList = []
            patch.httpText = v ? "true" : "false"
        } else if (v === null || v === undefined) {
            patch.httpVal = undefined; patch.httpList = []; patch.httpText = "-"
        } else {
            patch.httpVal = undefined; patch.httpList = []
            patch.httpText = ("" + v).slice(0, 64)
        }
        _put(patch)
    }

    // Debounce config changes into one fetch; only the ACTIVE instance polls (the
    // inactive overlay/tile just renders the shared last reading).
    property string cfgKey: url + "|" + jsonPath + "|" + mode + "|" + authToken
    onCfgKeyChanged: if (w.active) fetchDebounce.restart()
    onActiveChanged: if (w.active) fetchDebounce.restart()
    Component.onCompleted: { _seedHist(); if (w.active) fetchDebounce.restart() }
    Timer { id: fetchDebounce; interval: 300; onTriggered: if (w.active) w.refresh() }
    Timer { interval: Math.max(5, w.pollSec) * 1000; repeat: true; running: w.active && w.url.length > 0
            onTriggered: if (w.active) w.refresh() }

    // ── Presentation ─────────────────────────────────────────────────────────
    GridLayout {
        anchors.fill: parent
        anchors.margins: w.expanded ? 8 : 2
        // Wide seats the refresh control BESIDE the content; everything else puts
        // it on its own row underneath. (Invisible items are skipped by
        // GridLayout, so at micro neither cell is consumed.)
        columns: w.horiz ? 2 : 1
        rowSpacing: w.expanded ? 10 : 4
        columnSpacing: theme.spacingSm

        // Empty / unconfigured hint. This is what the presets ship, so it scales
        // with the box rather than sitting at a flat 12px in a 1637px tile.
        Text {
            visible: !w.url.length
            Layout.fillWidth: true; Layout.fillHeight: true
            horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
            wrapMode: Text.WordWrap
            text: "Add a URL in settings\nto connect a data source"
            color: theme.textTertiary; font.pixelSize: w.hintPx
        }

        // VALUE / GAUGE - a single reading.
        Loader {
            visible: w.url.length > 0 && w.mode !== "list"
            active: visible
            Layout.fillWidth: true; Layout.fillHeight: true
            sourceComponent: w.mode === "gauge" ? gaugeView : valueView
        }

        // LIST - array of items.
        ColumnLayout {
            visible: w.url.length > 0 && w.mode === "list"
            Layout.fillWidth: true; Layout.fillHeight: true
            Layout.maximumWidth: Number.POSITIVE_INFINITY
            spacing: 2
            Repeater {
                // The model is the COUNT: a poll every N seconds moves the bound
                // text of long-lived delegates instead of rebuilding the list
                // (which is what a `listItems.slice(...)` model did - a fresh JS
                // array every tick, destroying and recreating every row).
                model: w.listShown
                delegate: Text {
                    id: listRow
                    required property int index
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.round(w.listRowH)
                    verticalAlignment: Text.AlignVCenter
                    text: "• " + (w.listItems[listRow.index] !== undefined
                                  ? w.listItems[listRow.index] : "")
                    elide: Text.ElideRight; maximumLineCount: 1
                    color: theme.textPrimary
                    font.pixelSize: Math.max(theme.fontMinimum,
                                             Math.min(w.listRowH * 0.42,
                                                          w.expanded ? 15 : 20))
                }
            }
            Item { Layout.fillHeight: true }
            Text {
                visible: w.errText.length > 0
                text: w.errText + (w.errorHelp.length ? ": " + w.errorHelp : "")
                color: theme.warning
                font.pixelSize: Math.max(theme.fontMinimum,
                                         Math.min(w.listRowH * 0.40, theme.fontLabel))
            }
        }

        // Manual refresh - a real touch target in its own cell. It used to be a
        // 34px circle (under the token) anchored over the bottom-right, which sat
        // on top of the last list row. The half-cell has no room for it, so it
        // shows the readout and leaves refreshing to the poll and the overlay.
        Item {
            visible: w.url.length > 0 && !w.micro
            Layout.preferredHeight: theme.touchTertiary
            Layout.preferredWidth: w.horiz ? theme.touchTertiary : -1
            Layout.fillWidth: !w.horiz
            Layout.alignment: w.horiz ? Qt.AlignVCenter : Qt.AlignRight
            Rectangle {
                objectName: "httpRefreshButton"
                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                width: theme.touchTertiary; height: theme.touchTertiary; radius: width / 2
                activeFocusOnTab: true
                color: Qt.rgba(w.effAccent.r, w.effAccent.g, w.effAccent.b,
                               rMA.pressed ? 0.32 : (rMA.containsMouse ? 0.22 : 0.14))
                Accessible.role: Accessible.Button
                Accessible.name: w.testingConnection ? "Refreshing data" : "Refresh data"
                Accessible.onPressAction: w.refresh()
                Keys.onSpacePressed: w.refresh()
                Keys.onEnterPressed: w.refresh()
                Keys.onReturnPressed: w.refresh()
                AppIcon { anchors.centerIn: parent; name: "ui-refresh"; size: 24; color: w.effAccent }
                MouseArea { id: rMA; anchors.fill: parent; hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { parent.forceActiveFocus(); w.refresh() } }
            }
        }
        Text {
            visible: w.expanded && w.url.length > 0
            Layout.fillWidth: true
            text: w.freshnessText + " · Requests " + w.sourceHost() + " every " + w.pollSec + "s"
            color: w.stale || w.errText.length ? theme.warning : theme.textTertiary
            font.pixelSize: theme.fontMinimum
            wrapMode: Text.WordWrap
        }
    }

    // VALUE - the number is the tile. Per size: micro shows it alone; wide puts
    // the trend beside it; tall/large hand the trend real height.
    Component {
        id: valueView
        GridLayout {
            anchors.fill: parent
            columns: w.horiz ? 2 : 1
            rowSpacing: 2
            columnSpacing: theme.spacingMd

            ColumnLayout {
                Layout.fillWidth: true
                // Exactly ONE of these two may absorb the height when they are
                // stacked in one column, or they compete and the nested Layout
                // wins - which left the trend 6px tall (a flat line) in every
                // tall tile. When the box is WIDE they sit in different columns,
                // so there is nothing to compete over. Mirrors MetricGauge, where
                // the ring cell stops filling exactly when sparkFills is on.
                Layout.fillHeight: !(w.tallish && !w.horiz)
                Layout.maximumWidth: Number.POSITIVE_INFINITY
                spacing: 0
                Item { Layout.fillHeight: true }
                // The reading + its unit. NOT a RowLayout: the number needs a
                // width cap so HorizontalFit can shrink a long value, but a Text
                // GIVEN that cap centres its glyphs inside it - which parked the
                // unit against the far edge of the tile, half a screen from the
                // number it belongs to (and squeezed "ms" down to "m").
                // So the number is capped and centred, and the unit is pinned to
                // its PAINTED right edge instead. paintedWidth is an output, so
                // there is no binding loop.
                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: valueLabel.implicitHeight
                    readonly property real unitW: unitLabel.visible ? unitLabel.implicitWidth + 4 : 0
                    Text {
                        id: valueLabel
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.horizontalCenterOffset: -parent.unitW / 2
                        width: Math.max(40, parent.width - parent.unitW)
                        text: w.valText.length ? w.valText : (w.errText.length ? "-" : "…")
                        font.pixelSize: w.valuePx; font.bold: true
                        color: w.valColor
                        horizontalAlignment: Text.AlignHCenter
                        fontSizeMode: Text.HorizontalFit; minimumPixelSize: theme.fontMinimum
                        elide: Text.ElideRight
                    }
                    Text {
                        id: unitLabel
                        visible: w.unit.length > 0 && !w.errText.length
                        text: w.unit; font.pixelSize: w.unitPx; color: theme.textSecondary
                        // Sit just past the number's painted right edge.
                        x: valueLabel.x + (valueLabel.width + valueLabel.paintedWidth) / 2 + 4
                        anchors.baseline: valueLabel.baseline
                    }
                }
                Text {
                    Layout.alignment: Qt.AlignHCenter; Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
                    // The half-cell has no room for the path caption; an error
                    // still wins at every size (it explains a missing reading).
                    visible: w.errText.length > 0
                             || ((w.expanded || w.tallish) && w.rich && w.jsonPath.length > 0)
                    text: w.errText.length ? w.errText : w.jsonPath
                    color: w.errText.length ? theme.warning : theme.textTertiary
                    font.pixelSize: Math.max(theme.fontMinimum,
                                             Math.min(w.valuePx * 0.24, theme.fontLabel))
                }
                Text {
                    visible: w.rich && w.thresholdState.length > 0
                    Layout.alignment: Qt.AlignHCenter
                    text: w.thresholdState + " threshold"
                    color: w.thresholdState === "Critical" ? theme.error
                         : w.thresholdState === "Warning" ? theme.warning
                         : theme.textSecondary
                    font.pixelSize: Math.max(15, theme.fontMinimum)
                    font.bold: w.thresholdState !== "Normal"
                }
                Item { Layout.fillHeight: true }
            }

            // Trend. Micro reserves no slot for it at all.
            Sparkline {
                visible: w.rich && w.hist.length > 1 && !w.errText.length
                Layout.fillWidth: true
                // Stacked: a strip, or real height once the box is tall.
                // Wide: the trend takes the height beside the number.
                Layout.fillHeight: w.horiz || w.tallish
                Layout.preferredHeight: (w.horiz || w.tallish) ? -1
                                        : (w.expanded ? 60 : Math.max(22, w.height * 0.14))
                values: w.hist; color: w.valColor
            }

            ColumnLayout {
                objectName: "httpSourceContext"
                visible: w.sizeClass === "large"
                Layout.columnSpan: w.horiz ? 2 : 1
                Layout.fillWidth: true
                spacing: 1
                Text {
                    Layout.fillWidth: true
                    text: w.sourceHost() + (w.jsonPath.length ? "  /  " + w.jsonPath : "")
                    color: theme.textSecondary; font.pixelSize: theme.fontMinimum
                    horizontalAlignment: Text.AlignHCenter; elide: Text.ElideMiddle
                }
                Text {
                    Layout.fillWidth: true
                    text: w.freshnessText + "  /  refresh every " + w.pollSec + "s"
                    color: w.stale ? theme.warning : theme.textTertiary; font.pixelSize: theme.fontMinimum
                    horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
                }
            }
        }
    }

    // GAUGE - the shared MetricGauge carries the ring; wave 2a gave it the
    // per-size knobs and this drives them exactly as CpuWidget does.
    Component {
        id: gaugeView
        MetricGauge {
            anchors.fill: parent
            ok: !w.errText.length && typeof w.valNum === "number"
            value: (typeof w.valNum === "number" && w.gaugeMax > 0)
                   ? Math.max(0, Math.min(1, w.valNum / w.gaugeMax)) : 0
            big: w.valText.length ? w.valText + (w.unit.length ? w.unit : "")
                                  : (w.errText.length ? "-" : "…")
            // The overlay captions with the path; a tall TILE has earned it too.
            sub: (w.expanded || w.tallish)
                 ? (w.errText.length ? w.errText : w.jsonPath) : ""
            color: w.valColor
            history: w.hist
            expanded: w.expanded
            // Per-size layout: micro is a bare ring + the one number; wide lays
            // the ring beside the sparkline; a tall TILE squares the ring and
            // hands the trend all the height below it.
            showSpark: w.rich
            horizontal: w.horiz
            sparkFills: w.tallish && !w.expanded
            bigMax: w.micro ? 72 : 60
        }
    }

}
