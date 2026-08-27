import QtQuick
import QtQuick.Layouts

// Systems - Fleet health and system metrics monitor.
// Polls Prometheus node_exporter processes across multiple Kubuntu / Linux machines
// over the local network via NetHub egress (no raw XHR, local-only safety).
// Extracts CPU, memory (RAM), disk usage, load averages, uptime, and network I/O.
//
// Shared ephemeral keys (sysNodes, sysSummary, sysAt, sysErr) keep compact tiles
// and expanded views synchronized without triggering config.toml disk writes.
WidgetChrome {
    id: w
    property var metrics: ({})
    property bool expanded: false
    property bool active: true
    property var store: null
    property string instanceId: ""
    property int tick: 0
    property double nowMsOverride: -1

    // Egress gate: injected by Dashboard, fallback for standalone/tests.
    property var netHub: null
    NetHub { id: _fallbackHub }
    function _hub() { return netHub ? netHub : _fallbackHub }

    // Test seam for offline deterministic testing
    property var xhrFactory: null

    title: "Systems"
    iconName: "systems"
    accentColor: theme.catSystem
    showHeader: !micro

    Accessible.name: "Systems Monitor"
    Accessible.description: w.configuredList.length === 0
        ? "No systems configured. Add hostnames in settings."
        : (w.onlineCount + " of " + w.totalCount + " systems online")

    // ── Per-size layout ──────────────────────────────────────────────────────
    readonly property bool horiz: sizeClass === "wide"
                                  || (sizeClass === "large" && width > height * 1.4)
    readonly property bool tallish: sizeClass === "tall"
                                    || (sizeClass === "large" && !horiz)
    readonly property bool rich: !micro

    // ── Live per-instance config ─────────────────────────────────────────────
    readonly property var cfg: {
        var _ = store ? store.revision : 0
        return (store && instanceId) ? JSON.parse(JSON.stringify(store.settingsFor(instanceId))) : ({})
    }
    readonly property string hostsRaw: cfg.hosts !== undefined ? String(cfg.hosts) : "localhost:9100"
    readonly property int defaultPort: cfg.defaultPort !== undefined ? Number(cfg.defaultPort) : 9100
    readonly property int pollSec: cfg.pollSec !== undefined ? Math.max(5, Number(cfg.pollSec)) : 10
    readonly property real warnCpu: Number(cfg.warnCpu !== undefined ? cfg.warnCpu : 85)
    readonly property real warnRam: Number(cfg.warnRam !== undefined ? cfg.warnRam : 85)
    readonly property real warnDisk: Number(cfg.warnDisk !== undefined ? cfg.warnDisk : 90)

    function currentMs() { return w.nowMsOverride >= 0 ? w.nowMsOverride : Date.now() }

    // ── Host parsing ─────────────────────────────────────────────────────────
    function normalizeUrl(target, dfltPort) {
        var item = String(target || "").trim()
        if (!item.length) return { label: "", url: "" }
        var url = item
        var label = item
        if (!/^https?:\/\//i.test(url)) {
            if (url.indexOf(":") === -1) {
                url = "http://" + url + ":" + (dfltPort || 9100) + "/metrics"
            } else {
                url = "http://" + url + "/metrics"
            }
        } else if (!/\/metrics$/i.test(url)) {
            url = url.replace(/\/+$/, "") + "/metrics"
        }
        label = label.replace(/^https?:\/\//i, "").replace(/\/metrics$/i, "").replace(/\/+$/, "")
        return { label: label, url: url }
    }

    readonly property var configuredList: {
        var raw = w.hostsRaw.split(/[\n,;]+/)
        var list = []
        var seen = {}
        for (var i = 0; i < raw.length; i++) {
            var parsed = normalizeUrl(raw[i], w.defaultPort)
            if (parsed.url.length && !seen[parsed.url]) {
                seen[parsed.url] = true
                list.push(parsed)
            }
        }
        return list
    }

    // ── Internal polling & parsing state ─────────────────────────────────────
    property var _prevSamples: ({})
    property var _activeXhrs: []
    property var localNodes: []
    property string lastGlobalError: ""
    property double lastSuccessAt: 0
    property string connectionStatus: ""
    property bool testingConnection: false
    property int selectedIndex: 0

    // Ephemeral store integration
    readonly property var storedNodes: (cfg.sysNodes && Array.isArray(cfg.sysNodes)) ? cfg.sysNodes : []
    readonly property var displayNodes: localNodes.length > 0 ? localNodes
                                       : (storedNodes.length > 0 ? storedNodes : initPlaceholderNodes())

    function initPlaceholderNodes() {
        var res = []
        for (var i = 0; i < configuredList.length; i++) {
            res.push({
                label: configuredList[i].label,
                url: configuredList[i].url,
                status: "offline",
                error: "Waiting for poll",
                lastSeenMs: 0,
                cpuPercent: 0,
                cpuCores: 1,
                load1: 0, load5: 0, load15: 0,
                ramPercent: 0, ramUsedBytes: 0, ramTotalBytes: 0,
                diskPercent: 0, diskUsedBytes: 0, diskTotalBytes: 0,
                netRxRate: 0, netTxRate: 0,
                uptimeSec: 0, uptimeStr: "-"
            })
        }
        return res
    }

    // Aggregates
    readonly property int totalCount: displayNodes.length
    readonly property int onlineCount: {
        var c = 0
        for (var i = 0; i < displayNodes.length; i++)
            if (displayNodes[i].status && displayNodes[i].status !== "offline") c++
        return c
    }
    readonly property int offlineCount: totalCount - onlineCount
    readonly property real avgCpu: {
        var sum = 0, count = 0
        for (var i = 0; i < displayNodes.length; i++) {
            if (displayNodes[i].status !== "offline") {
                sum += Number(displayNodes[i].cpuPercent || 0)
                count++
            }
        }
        return count > 0 ? (sum / count) : 0
    }
    readonly property real avgRam: {
        var sum = 0, count = 0
        for (var i = 0; i < displayNodes.length; i++) {
            if (displayNodes[i].status !== "offline") {
                sum += Number(displayNodes[i].ramPercent || 0)
                count++
            }
        }
        return count > 0 ? (sum / count) : 0
    }
    readonly property real totalNetRx: {
        var sum = 0
        for (var i = 0; i < displayNodes.length; i++) sum += Number(displayNodes[i].netRxRate || 0)
        return sum
    }
    readonly property real totalNetTx: {
        var sum = 0
        for (var i = 0; i < displayNodes.length; i++) sum += Number(displayNodes[i].netTxRate || 0)
        return sum
    }
    readonly property string fleetStatus: {
        if (totalCount === 0) return "unconfigured"
        if (onlineCount === 0) return "offline"
        for (var i = 0; i < displayNodes.length; i++)
            if (displayNodes[i].status === "critical") return "critical"
        for (var j = 0; j < displayNodes.length; j++)
            if (displayNodes[j].status === "warning") return "warning"
        return "online"
    }

    // ── Prometheus Metrics Parser ────────────────────────────────────────────
    function isIgnoredNetDevice(key) {
        return key.indexOf('device="lo"') >= 0 || key.indexOf('device="docker') >= 0
            || key.indexOf('device="veth') >= 0 || key.indexOf('device="br-') >= 0
            || key.indexOf('device="virbr') >= 0
    }

    function parseNodeExporter(text) {
        var lines = String(text || "").split("\n")
        var data = {
            cpuTotal: 0,
            cpuIdle: 0,
            cpuCores: 0,
            coresSeen: ({}),
            memTotal: 0,
            memAvailable: 0,
            diskTotal: 0,
            diskAvail: 0,
            netRx: 0,
            netTx: 0,
            load1: 0,
            load5: 0,
            load15: 0,
            bootTime: 0
        }
        for (var i = 0; i < lines.length; i++) {
            var line = lines[i].trim()
            if (!line || line.charCodeAt(0) === 35) continue
            var spaceIdx = line.lastIndexOf(" ")
            if (spaceIdx === -1) continue
            var key = line.substring(0, spaceIdx)
            var val = parseFloat(line.substring(spaceIdx + 1))
            if (isNaN(val)) continue

            if (key === "node_load1" || key.indexOf("node_load1 ") === 0 || key.indexOf("node_load1{") === 0) data.load1 = val
            else if (key === "node_load5" || key.indexOf("node_load5 ") === 0 || key.indexOf("node_load5{") === 0) data.load5 = val
            else if (key === "node_load15" || key.indexOf("node_load15 ") === 0 || key.indexOf("node_load15{") === 0) data.load15 = val
            else if (key === "node_memory_MemTotal_bytes" || key.indexOf("node_memory_MemTotal_bytes{") === 0) data.memTotal = val
            else if (key === "node_memory_MemAvailable_bytes" || key.indexOf("node_memory_MemAvailable_bytes{") === 0) data.memAvailable = val
            else if (key === "node_boot_time_seconds" || key.indexOf("node_boot_time_seconds{") === 0) data.bootTime = val
            else if (key.indexOf("node_filesystem_size_bytes") === 0 && (key.indexOf('mountpoint="/"') >= 0 || (data.diskTotal === 0 && key.indexOf('fstype="ext4"') >= 0))) data.diskTotal = val
            else if (key.indexOf("node_filesystem_avail_bytes") === 0 && (key.indexOf('mountpoint="/"') >= 0 || (data.diskAvail === 0 && key.indexOf('fstype="ext4"') >= 0))) data.diskAvail = val
            else if (key.indexOf("node_cpu_seconds_total") === 0) {
                data.cpuTotal += val
                if (key.indexOf('mode="idle"') >= 0) data.cpuIdle += val
                var cm = key.match(/cpu="(\d+)"/)
                if (cm && cm[1] && !data.coresSeen[cm[1]]) {
                    data.coresSeen[cm[1]] = true
                    data.cpuCores++
                }
            }
            else if (key.indexOf("node_network_receive_bytes_total") === 0) {
                if (!isIgnoredNetDevice(key)) data.netRx += val
            }
            else if (key.indexOf("node_network_transmit_bytes_total") === 0) {
                if (!isIgnoredNetDevice(key)) data.netTx += val
            }
        }
        if (data.cpuCores === 0) data.cpuCores = 1
        return data
    }

    // ── Formatting helpers ───────────────────────────────────────────────────
    function formatBytes(bytes) {
        var b = Number(bytes || 0)
        if (b <= 0) return "0 B"
        if (b >= 1099511627776) return (b / 1099511627776).toFixed(1) + " TB"
        if (b >= 1073741824) return (b / 1073741824).toFixed(1) + " GB"
        if (b >= 1048576) return (b / 1048576).toFixed(0) + " MB"
        if (b >= 1024) return (b / 1024).toFixed(0) + " KB"
        return b.toFixed(0) + " B"
    }

    function formatRate(bytesSec) {
        var r = Number(bytesSec || 0)
        if (r <= 0) return "0 B/s"
        if (r >= 1048576) return (r / 1048576).toFixed(1) + " MB/s"
        if (r >= 1024) return (r / 1024).toFixed(0) + " KB/s"
        return r.toFixed(0) + " B/s"
    }

    function formatUptime(seconds) {
        var s = Number(seconds || 0)
        if (s <= 0) return "-"
        var d = Math.floor(s / 86400)
        var rem = s % 86400
        var h = Math.floor(rem / 3600)
        var m = Math.floor((rem % 3600) / 60)
        if (d > 0) return d + "d " + h + "h"
        if (h > 0) return h + "h " + m + "m"
        return m + "m"
    }

    function statusColor(status) {
        if (status === "critical") return theme.error
        if (status === "warning") return theme.warning
        if (status === "online") return theme.success
        return theme.textTertiary
    }

    // ── Polling Engine ───────────────────────────────────────────────────────
    Timer {
        id: pollTimer
        interval: w.pollSec * 1000
        repeat: true
        running: w.active && w.configuredList.length > 0
        onTriggered: w.refresh()
    }

    Component.onCompleted: {
        if (w.active && w.configuredList.length > 0) w.refresh()
    }

    onConfiguredListChanged: {
        if (w.active && w.configuredList.length > 0) w.refresh()
    }

    function refresh() {
        if (w.configuredList.length === 0) {
            w.localNodes = []
            return
        }
        var targets = w.configuredList
        var updatedNodes = []
        var pending = targets.length
        var nowMs = currentMs()

        // Clone current state as base
        var stateMap = ({})
        for (var i = 0; i < w.displayNodes.length; i++) {
            var n = w.displayNodes[i]
            if (n && n.url) stateMap[n.url] = n
        }

        for (var t = 0; t < targets.length; t++) {
            (function (target) {
                var prevSample = w._prevSamples[target.url] || null
                _hub().request({
                    url: target.url,
                    xhrFactory: w.xhrFactory,
                    onDone: function (status, body) {
                        if (status >= 200 && status < 300) {
                            var parsed = parseNodeExporter(body)
                            var elapsedSec = prevSample ? Math.max(0.1, (nowMs - prevSample.timeMs) / 1000) : 0
                            var cpuPct = 0
                            if (prevSample && prevSample.cpuTotal > 0 && parsed.cpuTotal > prevSample.cpuTotal) {
                                var totalDelta = parsed.cpuTotal - prevSample.cpuTotal
                                var idleDelta = Math.max(0, parsed.cpuIdle - prevSample.cpuIdle)
                                cpuPct = Math.max(0, Math.min(100, (1 - (idleDelta / totalDelta)) * 100))
                            } else if (parsed.load1 > 0 && parsed.cpuCores > 0) {
                                cpuPct = Math.max(0, Math.min(100, (parsed.load1 / parsed.cpuCores) * 100))
                            }

                            var ramUsed = Math.max(0, parsed.memTotal - parsed.memAvailable)
                            var ramPct = parsed.memTotal > 0
                                ? Math.max(0, Math.min(100, (ramUsed / parsed.memTotal) * 100))
                                : 0

                            var diskUsed = Math.max(0, parsed.diskTotal - parsed.diskAvail)
                            var diskPct = parsed.diskTotal > 0
                                ? Math.max(0, Math.min(100, (diskUsed / parsed.diskTotal) * 100))
                                : 0

                            var rxRate = (prevSample && prevSample.netRx > 0 && parsed.netRx >= prevSample.netRx && elapsedSec > 0)
                                ? (parsed.netRx - prevSample.netRx) / elapsedSec : 0
                            var txRate = (prevSample && prevSample.netTx > 0 && parsed.netTx >= prevSample.netTx && elapsedSec > 0)
                                ? (parsed.netTx - prevSample.netTx) / elapsedSec : 0

                            var uptimeSec = parsed.bootTime > 0 ? Math.max(0, Math.floor(nowMs / 1000 - parsed.bootTime)) : 0

                            var nodeStatus = "online"
                            if (cpuPct >= 95 || ramPct >= 95 || diskPct >= 95) nodeStatus = "critical"
                            else if (cpuPct >= w.warnCpu || ramPct >= w.warnRam || diskPct >= w.warnDisk) nodeStatus = "warning"

                            w._prevSamples[target.url] = {
                                timeMs: nowMs,
                                cpuTotal: parsed.cpuTotal,
                                cpuIdle: parsed.cpuIdle,
                                netRx: parsed.netRx,
                                netTx: parsed.netTx
                            }

                            stateMap[target.url] = {
                                label: target.label,
                                url: target.url,
                                status: nodeStatus,
                                error: "",
                                lastSeenMs: nowMs,
                                cpuPercent: cpuPct,
                                cpuCores: parsed.cpuCores,
                                load1: parsed.load1,
                                load5: parsed.load5,
                                load15: parsed.load15,
                                ramPercent: ramPct,
                                ramUsedBytes: ramUsed,
                                ramTotalBytes: parsed.memTotal,
                                diskPercent: diskPct,
                                diskUsedBytes: diskUsed,
                                diskTotalBytes: parsed.diskTotal,
                                netRxRate: rxRate,
                                netTxRate: txRate,
                                uptimeSec: uptimeSec,
                                uptimeStr: formatUptime(uptimeSec)
                            }
                            w.lastSuccessAt = nowMs
                        } else {
                            stateMap[target.url] = {
                                label: target.label,
                                url: target.url,
                                status: "offline",
                                error: "HTTP " + status,
                                lastSeenMs: stateMap[target.url] ? stateMap[target.url].lastSeenMs : 0,
                                cpuPercent: 0, cpuCores: 1, load1: 0, load5: 0, load15: 0,
                                ramPercent: 0, ramUsedBytes: 0, ramTotalBytes: 0,
                                diskPercent: 0, diskUsedBytes: 0, diskTotalBytes: 0,
                                netRxRate: 0, netTxRate: 0, uptimeSec: 0, uptimeStr: "-"
                            }
                        }
                        finalizeOne()
                    },
                    onError: function (reason) {
                        stateMap[target.url] = {
                            label: target.label,
                            url: target.url,
                            status: "offline",
                            error: reason || "Offline",
                            lastSeenMs: stateMap[target.url] ? stateMap[target.url].lastSeenMs : 0,
                            cpuPercent: 0, cpuCores: 1, load1: 0, load5: 0, load15: 0,
                            ramPercent: 0, ramUsedBytes: 0, ramTotalBytes: 0,
                            diskPercent: 0, diskUsedBytes: 0, diskTotalBytes: 0,
                            netRxRate: 0, netTxRate: 0, uptimeSec: 0, uptimeStr: "-"
                        }
                        finalizeOne()
                    }
                })
            })(targets[t])
        }

        function finalizeOne() {
            pending--
            if (pending <= 0) {
                var merged = []
                for (var k = 0; k < targets.length; k++) {
                    if (stateMap[targets[k].url]) merged.push(stateMap[targets[k].url])
                }
                w.localNodes = merged
                _commitEphemeral(merged)
            }
        }
    }

    function _commitEphemeral(nodeList) {
        if (!store || !instanceId) return
        store.patchSettings(instanceId, {
            sysNodes: nodeList,
            sysAt: w.currentMs(),
            sysErr: w.lastGlobalError
        })
    }

    function testConnection() {
        w.testingConnection = true
        w.connectionStatus = "Testing reachability of " + w.configuredList.length + " target(s)..."
        w.refresh()
        var checkTimer = Qt.createQmlObject('import QtQuick; Timer { interval: 1500; repeat: false }', w)
        checkTimer.triggered.connect(function () {
            w.testingConnection = false
            w.connectionStatus = w.onlineCount + "/" + w.totalCount + " systems reachable"
            checkTimer.destroy()
        })
        checkTimer.start()
    }

    // ── Content View Hierarchy ───────────────────────────────────────────────
    Item {
        anchors.fill: parent

        // ── UNCONFIGURED STATE ───────────────────────────────────────────────
        ColumnLayout {
            anchors.centerIn: parent
            width: Math.min(parent.width - 24, 380)
            visible: w.configuredList.length === 0
            spacing: theme.spacingSm

            AppIcon {
                Layout.alignment: Qt.AlignCenter
                name: "systems"
                size: w.micro ? 24 : (w.expanded ? 48 : 36)
                tint: theme.textTertiary
            }
            Text {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: "No Systems Configured"
                color: theme.textPrimary
                font.pixelSize: w.micro ? theme.fontMinimum : (w.expanded ? 20 : 14)
                font.family: theme.fontDisplay
                font.weight: Font.DemiBold
            }
            Text {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                visible: !w.micro
                text: "Add hostnames in settings to monitor Prometheus node_exporter metrics."
                color: theme.textTertiary
                font.pixelSize: 12
                font.family: theme.fontDisplay
            }
        }

        // ── MICRO MODE (0.5x0.5 tile: ~348x409 / ~423x306) ───────────────────
        Item {
            anchors.fill: parent
            visible: w.micro && w.configuredList.length > 0

            ColumnLayout {
                anchors.centerIn: parent
                spacing: 4

                RowLayout {
                    Layout.alignment: Qt.AlignCenter
                    spacing: 6
                    Rectangle {
                        width: 10; height: 10; radius: 5
                        color: w.statusColor(w.fleetStatus)
                    }
                    Text {
                        text: w.onlineCount + "/" + w.totalCount + " UP"
                        color: theme.textPrimary
                        font.pixelSize: Math.max(16, Math.min(w.width * 0.12, w.height * 0.15, 24))
                        font.family: theme.fontDisplay
                        font.weight: Font.Bold
                    }
                }

                Text {
                    Layout.alignment: Qt.AlignCenter
                    text: "CPU " + w.avgCpu.toFixed(0) + "% · RAM " + w.avgRam.toFixed(0) + "%"
                    color: theme.textSecondary
                    font.pixelSize: Math.max(theme.fontMinimum, Math.min(w.width * 0.08, 12))
                    font.family: theme.fontMono
                }
            }
        }

        // ── STANDARD TILE (Compact / Wide / Tall / Large) ────────────────────
        Item {
            anchors.fill: parent
            anchors.topMargin: w.headerHeight
            anchors.margins: theme.spacingSm
            visible: !w.micro && !w.expanded && w.configuredList.length > 0

            ColumnLayout {
                anchors.fill: parent
                spacing: theme.spacingSm

                // Compact summary strip
                RowLayout {
                    Layout.fillWidth: true
                    spacing: theme.spacingSm

                    Rectangle {
                        width: 8; height: 8; radius: 4
                        color: w.statusColor(w.fleetStatus)
                    }
                    Text {
                        text: w.onlineCount + "/" + w.totalCount + " Systems Online"
                        color: theme.textSecondary
                        font.pixelSize: 12
                        font.family: theme.fontDisplay
                        font.weight: Font.Medium
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                        text: "↓" + w.formatRate(w.totalNetRx) + " ↑" + w.formatRate(w.totalNetTx)
                        color: theme.textTertiary
                        font.pixelSize: 11
                        font.family: theme.fontMono
                    }
                }

                // Systems List
                ListView {
                    id: tileListView
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    spacing: 6
                    model: w.displayNodes
                    delegate: Rectangle {
                        width: tileListView.width
                        height: w.tallish ? 58 : 46
                        radius: theme.radiusSm
                        color: theme.cardBackgroundAlt
                        border.color: theme.cardBorder
                        border.width: 1

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 6
                            spacing: 2

                            // Top line: Status dot, Label, Uptime / Error
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 6

                                Rectangle {
                                    width: 8; height: 8; radius: 4
                                    color: w.statusColor(modelData.status)
                                }
                                Text {
                                    text: modelData.label || "System"
                                    color: theme.textPrimary
                                    font.pixelSize: 13
                                    font.family: theme.fontDisplay
                                    font.weight: Font.DemiBold
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                                Text {
                                    text: modelData.status === "offline"
                                          ? (modelData.error || "Offline")
                                          : ("up " + modelData.uptimeStr)
                                    color: modelData.status === "offline" ? theme.error : theme.textTertiary
                                    font.pixelSize: 11
                                    font.family: theme.fontMono
                                }
                            }

                            // Bottom line: Mini meters for CPU, RAM, Disk
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                visible: modelData.status !== "offline"

                                // CPU Bar
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 4
                                    Text {
                                        text: "C"
                                        color: theme.textTertiary
                                        font.pixelSize: 10
                                        font.family: theme.fontMono
                                    }
                                    Rectangle {
                                        Layout.fillWidth: true
                                        height: 5; radius: 2.5
                                        color: theme.cardBorder
                                        Rectangle {
                                            width: parent.width * (Math.min(100, Math.max(0, modelData.cpuPercent || 0)) / 100)
                                            height: parent.height; radius: 2.5
                                            color: modelData.cpuPercent >= w.warnCpu ? theme.warning : theme.catSystem
                                        }
                                    }
                                    Text {
                                        text: Math.round(modelData.cpuPercent || 0) + "%"
                                        color: theme.textSecondary
                                        font.pixelSize: 10
                                        font.family: theme.fontMono
                                    }
                                }

                                // RAM Bar
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 4
                                    Text {
                                        text: "M"
                                        color: theme.textTertiary
                                        font.pixelSize: 10
                                        font.family: theme.fontMono
                                    }
                                    Rectangle {
                                        Layout.fillWidth: true
                                        height: 5; radius: 2.5
                                        color: theme.cardBorder
                                        Rectangle {
                                            width: parent.width * (Math.min(100, Math.max(0, modelData.ramPercent || 0)) / 100)
                                            height: parent.height; radius: 2.5
                                            color: modelData.ramPercent >= w.warnRam ? theme.warning : theme.accent2
                                        }
                                    }
                                    Text {
                                        text: Math.round(modelData.ramPercent || 0) + "%"
                                        color: theme.textSecondary
                                        font.pixelSize: 10
                                        font.family: theme.fontMono
                                    }
                                }

                                // Net rate
                                Text {
                                    text: w.formatRate(modelData.netRxRate)
                                    color: theme.textTertiary
                                    font.pixelSize: 10
                                    font.family: theme.fontMono
                                    visible: w.width > 280
                                }
                            }
                        }
                    }
                }
            }
        }

        // ── EXPANDED FULL-SCREEN OVERLAY ─────────────────────────────────────
        Item {
            anchors.fill: parent
            anchors.topMargin: w.headerHeight
            anchors.margins: theme.spacingLg
            visible: w.expanded && w.configuredList.length > 0

            ColumnLayout {
                anchors.fill: parent
                spacing: theme.spacingMd

                // 1. Fleet Overview Header Banner
                Rectangle {
                    Layout.fillWidth: true
                    height: 80
                    radius: theme.radiusMd
                    color: theme.cardBackgroundAlt
                    border.color: theme.cardBorder
                    border.width: 1

                    RowLayout {
                        anchors.fill: parent
                        anchors.margins: theme.spacingMd
                        spacing: theme.spacingLg

                        // Status pill + Total
                        RowLayout {
                            spacing: theme.spacingSm
                            Rectangle {
                                width: 14; height: 14; radius: 7
                                color: w.statusColor(w.fleetStatus)
                            }
                            ColumnLayout {
                                spacing: 0
                                Text {
                                    text: w.onlineCount + " / " + w.totalCount + " ONLINE"
                                    color: theme.textPrimary
                                    font.pixelSize: 16
                                    font.family: theme.fontDisplay
                                    font.weight: Font.Bold
                                }
                                Text {
                                    text: w.offlineCount > 0 ? (w.offlineCount + " unreachable") : "All healthy"
                                    color: w.offlineCount > 0 ? theme.error : theme.textTertiary
                                    font.pixelSize: 12
                                }
                            }
                        }

                        Item { Layout.fillWidth: true }

                        // Fleet Avg CPU
                        ColumnLayout {
                            spacing: 0
                            Text {
                                text: "FLEET AVG CPU"
                                color: theme.textTertiary
                                font.pixelSize: 10
                                font.family: theme.fontMono
                            }
                            Text {
                                text: w.avgCpu.toFixed(1) + "%"
                                color: w.avgCpu >= w.warnCpu ? theme.warning : theme.textPrimary
                                font.pixelSize: 18
                                font.family: theme.fontDisplay
                                font.weight: Font.Bold
                            }
                        }

                        // Fleet Avg RAM
                        ColumnLayout {
                            spacing: 0
                            Text {
                                text: "FLEET AVG RAM"
                                color: theme.textTertiary
                                font.pixelSize: 10
                                font.family: theme.fontMono
                            }
                            Text {
                                text: w.avgRam.toFixed(1) + "%"
                                color: w.avgRam >= w.warnRam ? theme.warning : theme.textPrimary
                                font.pixelSize: 18
                                font.family: theme.fontDisplay
                                font.weight: Font.Bold
                            }
                        }

                        // Total Network Rx / Tx
                        ColumnLayout {
                            spacing: 0
                            Text {
                                text: "FLEET BANDWIDTH"
                                color: theme.textTertiary
                                font.pixelSize: 10
                                font.family: theme.fontMono
                            }
                            Text {
                                text: "↓ " + w.formatRate(w.totalNetRx) + "  ↑ " + w.formatRate(w.totalNetTx)
                                color: theme.textPrimary
                                font.pixelSize: 14
                                font.family: theme.fontMono
                                font.weight: Font.Bold
                            }
                        }
                    }
                }

                // 2. Node Selector Tabs
                RowLayout {
                    Layout.fillWidth: true
                    spacing: theme.spacingSm

                    Text {
                        text: "SELECT SYSTEM:"
                        color: theme.textTertiary
                        font.pixelSize: 11
                        font.family: theme.fontMono
                    }

                    ListView {
                        id: nodeTabsList
                        Layout.fillWidth: true
                        height: 36
                        orientation: ListView.Horizontal
                        spacing: 8
                        clip: true
                        model: w.displayNodes
                        delegate: Rectangle {
                            height: 34
                            width: tabRow.implicitWidth + 24
                            radius: 17
                            color: w.selectedIndex === index ? theme.accent : theme.cardBackgroundAlt
                            border.color: w.selectedIndex === index ? theme.accent : theme.cardBorder
                            border.width: 1

                            RowLayout {
                                id: tabRow
                                anchors.centerIn: parent
                                spacing: 6
                                Rectangle {
                                    width: 8; height: 8; radius: 4
                                    color: w.selectedIndex === index ? "#FFFFFF" : w.statusColor(modelData.status)
                                }
                                Text {
                                    text: modelData.label || "System"
                                    color: w.selectedIndex === index ? "#0D1117" : theme.textPrimary
                                    font.pixelSize: 12
                                    font.family: theme.fontDisplay
                                    font.weight: Font.DemiBold
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                onClicked: w.selectedIndex = index
                            }
                        }
                    }
                }

                // 3. Selected Node Deep-Dive Panel
                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    readonly property var selNode: (w.selectedIndex >= 0 && w.selectedIndex < w.displayNodes.length)
                                                   ? w.displayNodes[w.selectedIndex]
                                                   : (w.displayNodes.length > 0 ? w.displayNodes[0] : null)

                    ColumnLayout {
                        anchors.fill: parent
                        spacing: theme.spacingMd
                        visible: parent.selNode !== null

                        // 4 Primary Metric Cards
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: theme.spacingMd

                            // CPU Gauge Card
                            Rectangle {
                                Layout.fillWidth: true
                                height: 130
                                radius: theme.radiusMd
                                color: theme.cardBackgroundAlt
                                border.color: theme.cardBorder
                                border.width: 1

                                ColumnLayout {
                                    anchors.fill: parent
                                    anchors.margins: 12
                                    spacing: 4

                                    Text {
                                        text: "PROCESSOR"
                                        color: theme.textTertiary
                                        font.pixelSize: 11
                                        font.family: theme.fontMono
                                    }
                                    Text {
                                        text: Math.round(selNode ? selNode.cpuPercent : 0) + "%"
                                        color: (selNode && selNode.cpuPercent >= w.warnCpu) ? theme.warning : theme.textPrimary
                                        font.pixelSize: 28
                                        font.family: theme.fontDisplay
                                        font.weight: Font.Bold
                                    }
                                    Text {
                                        text: (selNode ? selNode.cpuCores : 1) + " cores · Load: "
                                              + (selNode ? Number(selNode.load1 || 0).toFixed(2) : "0.00") + ", "
                                              + (selNode ? Number(selNode.load5 || 0).toFixed(2) : "0.00")
                                        color: theme.textSecondary
                                        font.pixelSize: 11
                                        font.family: theme.fontMono
                                    }
                                }
                            }

                            // Memory Gauge Card
                            Rectangle {
                                Layout.fillWidth: true
                                height: 130
                                radius: theme.radiusMd
                                color: theme.cardBackgroundAlt
                                border.color: theme.cardBorder
                                border.width: 1

                                ColumnLayout {
                                    anchors.fill: parent
                                    anchors.margins: 12
                                    spacing: 4

                                    Text {
                                        text: "MEMORY (RAM)"
                                        color: theme.textTertiary
                                        font.pixelSize: 11
                                        font.family: theme.fontMono
                                    }
                                    Text {
                                        text: Math.round(selNode ? selNode.ramPercent : 0) + "%"
                                        color: (selNode && selNode.ramPercent >= w.warnRam) ? theme.warning : theme.textPrimary
                                        font.pixelSize: 28
                                        font.family: theme.fontDisplay
                                        font.weight: Font.Bold
                                    }
                                    Text {
                                        text: w.formatBytes(selNode ? selNode.ramUsedBytes : 0) + " / "
                                              + w.formatBytes(selNode ? selNode.ramTotalBytes : 0)
                                        color: theme.textSecondary
                                        font.pixelSize: 11
                                        font.family: theme.fontMono
                                    }
                                }
                            }

                            // Disk Gauge Card
                            Rectangle {
                                Layout.fillWidth: true
                                height: 130
                                radius: theme.radiusMd
                                color: theme.cardBackgroundAlt
                                border.color: theme.cardBorder
                                border.width: 1

                                ColumnLayout {
                                    anchors.fill: parent
                                    anchors.margins: 12
                                    spacing: 4

                                    Text {
                                        text: "STORAGE (/)"
                                        color: theme.textTertiary
                                        font.pixelSize: 11
                                        font.family: theme.fontMono
                                    }
                                    Text {
                                        text: Math.round(selNode ? selNode.diskPercent : 0) + "%"
                                        color: (selNode && selNode.diskPercent >= w.warnDisk) ? theme.warning : theme.textPrimary
                                        font.pixelSize: 28
                                        font.family: theme.fontDisplay
                                        font.weight: Font.Bold
                                    }
                                    Text {
                                        text: w.formatBytes(selNode ? selNode.diskUsedBytes : 0) + " / "
                                              + w.formatBytes(selNode ? selNode.diskTotalBytes : 0)
                                        color: theme.textSecondary
                                        font.pixelSize: 11
                                        font.family: theme.fontMono
                                    }
                                }
                            }

                            // Network Bandwidth Card
                            Rectangle {
                                Layout.fillWidth: true
                                height: 130
                                radius: theme.radiusMd
                                color: theme.cardBackgroundAlt
                                border.color: theme.cardBorder
                                border.width: 1

                                ColumnLayout {
                                    anchors.fill: parent
                                    anchors.margins: 12
                                    spacing: 4

                                    Text {
                                        text: "NETWORK BANDWIDTH"
                                        color: theme.textTertiary
                                        font.pixelSize: 11
                                        font.family: theme.fontMono
                                    }
                                    Text {
                                        text: "↓ " + w.formatRate(selNode ? selNode.netRxRate : 0)
                                        color: theme.textPrimary
                                        font.pixelSize: 20
                                        font.family: theme.fontMono
                                        font.weight: Font.Bold
                                    }
                                    Text {
                                        text: "↑ " + w.formatRate(selNode ? selNode.netTxRate : 0)
                                        color: theme.textSecondary
                                        font.pixelSize: 14
                                        font.family: theme.fontMono
                                    }
                                }
                            }
                        }

                        // Detailed Specs & Diagnostic Info
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            radius: theme.radiusMd
                            color: theme.cardBackgroundAlt
                            border.color: theme.cardBorder
                            border.width: 1

                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: theme.spacingMd
                                spacing: 8

                                Text {
                                    text: "SYSTEM DETAILS & TELEMETRY"
                                    color: theme.textTertiary
                                    font.pixelSize: 11
                                    font.family: theme.fontMono
                                }

                                GridLayout {
                                    Layout.fillWidth: true
                                    columns: 2
                                    rowSpacing: 8
                                    columnSpacing: 24

                                    Text { text: "Endpoint URL:"; color: theme.textTertiary; font.pixelSize: 13 }
                                    Text { text: selNode ? selNode.url : ""; color: theme.textPrimary; font.pixelSize: 13; font.family: theme.fontMono }

                                    Text { text: "System Uptime:"; color: theme.textTertiary; font.pixelSize: 13 }
                                    Text { text: selNode ? selNode.uptimeStr : "-"; color: theme.textPrimary; font.pixelSize: 13; font.family: theme.fontMono }

                                    Text { text: "Load Averages (1m, 5m, 15m):"; color: theme.textTertiary; font.pixelSize: 13 }
                                    Text {
                                        text: selNode ? (Number(selNode.load1 || 0).toFixed(2) + "  "
                                                         + Number(selNode.load5 || 0).toFixed(2) + "  "
                                                         + Number(selNode.load15 || 0).toFixed(2)) : "-"
                                        color: theme.textPrimary; font.pixelSize: 13; font.family: theme.fontMono
                                    }

                                    Text { text: "Connection Status:"; color: theme.textTertiary; font.pixelSize: 13 }
                                    Text {
                                        text: selNode ? (selNode.status.toUpperCase() + (selNode.error ? " (" + selNode.error + ")" : "")) : "-"
                                        color: selNode ? w.statusColor(selNode.status) : theme.textPrimary
                                        font.pixelSize: 13; font.family: theme.fontDisplay; font.weight: Font.Bold
                                    }
                                }

                                Item { Layout.fillHeight: true }

                                // Action Buttons Row
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: theme.spacingMd

                                    PillButton {
                                        text: w.testingConnection ? "Testing..." : "Test Connection"
                                        iconName: "ui-refresh"
                                        onClicked: w.testConnection()
                                    }

                                    PillButton {
                                        text: "Refresh All Now"
                                        iconName: "ui-refresh"
                                        accent: true
                                        onClicked: w.refresh()
                                    }

                                    Text {
                                        Layout.fillWidth: true
                                        text: w.connectionStatus
                                        color: theme.textSecondary
                                        font.pixelSize: 12
                                        elide: Text.ElideRight
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

