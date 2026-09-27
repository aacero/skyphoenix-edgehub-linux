import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// ─────────────────────────────────────────────────────────────────────────
// QuickActionsWidget - tactile touch system cards for homelab hosts.
//
// Every configured system is presented as a tactile card showing its
// hostname/IP, reachability badge, and instant macro action buttons:
//   • Ping:  Checks live reachability and measures RTT latency.
//   • SSH:   Launches an interactive SSH session in a local terminal.
//   • Mosh:  Launches a mobile-resilient Mosh session in a local terminal.
//
// Wake-on-LAN functionality is hosted directly within the Systems widget,
// where MAC addresses and physical node power states are tracked.
// ─────────────────────────────────────────────────────────────────────────
WidgetChrome {
    id: w
    property var metrics: ({})
    property bool expanded: false
    property bool active: true
    property var store: null
    property string instanceId: ""
    property int tick: 0
    property var netHub: null
    property var bridgeOverride: null

    title: "Quick Actions"; iconName: "sparkle"; accentColor: theme.accent

    NetHub { id: _fallbackHub }
    readonly property var effHub: netHub || _fallbackHub

    readonly property var bridge: {
        if (bridgeOverride) return bridgeOverride
        if (typeof configBridge !== "undefined" && configBridge) return configBridge
        if (store && store.configBridge) return store.configBridge
        return null
    }

    readonly property var cfg: {
        var _ = store ? store.revision : 0
        return (store && instanceId) ? JSON.parse(JSON.stringify(store.settingsFor(instanceId))) : ({})
    }

    // Default systems matching homelab topology
    readonly property var defaultHosts: [
        { id: "host-palatka", label: "palatka", host: "10.0.0.227", user: "" },
        { id: "host-deerpark", label: "deerpark", host: "10.0.0.88", user: "" },
        { id: "host-bframe", label: "bframe", host: "100.69.69.10", user: "acero" },
        { id: "host-aframe", label: "aframe", host: "10.0.0.50", user: "" }
    ]
    readonly property var defaultActions: defaultHosts

    function parseHostsText(text) {
        if (!text || typeof text !== "string") return []
        var lines = text.split("\n")
        var list = []
        for (var i = 0; i < lines.length; i++) {
            var line = lines[i].trim()
            if (!line || line.startsWith("#")) continue
            var parts = line.split("|").map(function(p) { return p.trim() })
            if (parts.length >= 2) {
                var label = parts[0]
                var host = parts[1]
                var user = parts.length >= 3 ? parts[2] : ""

                // Handle legacy actionsText syntax: Label | Type | Target
                var legacyTypes = ["ping", "ssh", "mosh", "command", "webhook", "wol"]
                if (parts.length >= 3 && legacyTypes.indexOf(parts[1].toLowerCase()) !== -1) {
                    label = parts[0]
                    host = parts[2]
                    user = ""
                }
                list.push({
                    id: "host-" + i + "-" + label.toLowerCase().replace(/[^a-z0-9]/g, "-"),
                    label: label,
                    host: host,
                    user: user
                })
            } else if (parts.length === 1 && parts[0].length > 0) {
                list.push({
                    id: "host-" + i + "-" + parts[0].toLowerCase().replace(/[^a-z0-9]/g, "-"),
                    label: parts[0],
                    host: parts[0],
                    user: ""
                })
            }
        }
        return list
    }

    function formatHostsText(hostList) {
        if (!hostList || !Array.isArray(hostList)) return ""
        var lines = []
        for (var i = 0; i < hostList.length; i++) {
            var h = hostList[i]
            var line = (h.label || "Host") + " | " + (h.host || "")
            if (h.user && h.user.trim().length > 0) {
                line += " | " + h.user.trim()
            }
            lines.push(line)
        }
        return lines.join("\n")
    }

    function parseActionsText(text) { return parseHostsText(text) }
    function formatActionsText(list) { return formatHostsText(list) }

    readonly property var hosts: {
        if (cfg.hostsText && typeof cfg.hostsText === "string" && cfg.hostsText.trim().length > 0) {
            var parsedH = parseHostsText(cfg.hostsText)
            if (parsedH.length > 0) return parsedH
        }
        if (cfg.actionsText && typeof cfg.actionsText === "string" && cfg.actionsText.trim().length > 0) {
            var parsedA = parseHostsText(cfg.actionsText)
            if (parsedA.length > 0) return parsedA
        }
        if (cfg.hosts && Array.isArray(cfg.hosts) && cfg.hosts.length > 0) {
            return cfg.hosts
        }
        if (cfg.actions && Array.isArray(cfg.actions) && cfg.actions.length > 0) {
            return cfg.actions.map(function(a, idx) {
                return {
                    id: a.id || ("host-" + idx),
                    label: a.label || "Host",
                    host: a.host || a.target || "",
                    user: a.user || ""
                }
            })
        }
        return defaultHosts
    }
    readonly property var actions: hosts

    readonly property bool showStatusBanner: cfg.showStatusBanner !== undefined ? cfg.showStatusBanner : true

    property var actionStates: ({})
    readonly property var hostStates: actionStates

    property string lastNotice: ""
    property color lastNoticeColor: theme.textSecondary

    // Inline editor state for expanded mode
    property bool isAdding: false
    property string editId: ""
    property string editLabel: ""
    property string editHost: ""
    property string editUser: ""

    // Backward-compat aliases for tests
    property alias editTarget: w.editHost
    property string editType: "ssh"

    Timer {
        id: resetNoticeTimer
        interval: 3500
        repeat: false
        onTriggered: {
            w.lastNotice = ""
        }
    }

    function pingHost(item) {
        if (!item) return
        var host = typeof item === "string" ? item.trim() : (item.host || item.target || "").trim()
        var hostId = (typeof item === "object" && (item.id || item.label)) ? (item.id || item.label) : host
        if (!host.length) {
            var errCopy = JSON.parse(JSON.stringify(w.actionStates))
            errCopy[hostId] = { status: "error", detail: "No host", time: Date.now() }
            w.actionStates = errCopy
            w.lastNotice = "✕ Target host missing"
            w.lastNoticeColor = theme.error
            resetNoticeTimer.restart()
            return
        }

        // Mark as pinging
        var copy = JSON.parse(JSON.stringify(w.actionStates))
        copy[hostId] = { status: "pinging", time: Date.now() }
        w.actionStates = copy

        var pingRes = { ok: false, error: "Unavailable", latencyMs: -1 }
        if (w.bridge && typeof w.bridge.pingHost === "function") {
            pingRes = w.bridge.pingHost(host, 2)
        }
        var updatedPing = JSON.parse(JSON.stringify(w.actionStates))
        if (pingRes && pingRes.ok) {
            var lat = (pingRes.latencyMs >= 0) ? (pingRes.latencyMs.toFixed(1) + " ms") : "ok"
            updatedPing[hostId] = { status: "ok", time: Date.now(), latency: lat, detail: lat }
            w.lastNotice = "✓ " + host + " is reachable (" + lat + ")"
            w.lastNoticeColor = theme.success
        } else {
            var errDetail = (pingRes && pingRes.error) ? pingRes.error : "unreachable"
            updatedPing[hostId] = { status: "error", time: Date.now(), detail: errDetail }
            w.lastNotice = "✕ " + host + " is " + errDetail
            w.lastNoticeColor = theme.error
        }
        w.actionStates = updatedPing
        resetNoticeTimer.restart()
    }

    function launchSsh(item) {
        if (!item) return
        var host = typeof item === "string" ? item.trim() : (item.host || item.target || "").trim()
        var user = (typeof item === "object" && item.user) ? item.user.trim() : ""
        var hostId = (typeof item === "object" && (item.id || item.label)) ? (item.id || item.label) : host
        if (!host.length) {
            var errCopy = JSON.parse(JSON.stringify(w.actionStates))
            errCopy[hostId] = { status: "error", detail: "No host", time: Date.now() }
            w.actionStates = errCopy
            w.lastNotice = "✕ Target host missing"
            w.lastNoticeColor = theme.error
            resetNoticeTimer.restart()
            return
        }

        var targetStr = user.length > 0 ? (user + "@" + host) : host
        var launchCmd = "for t in \"$TERMINAL\" foot alacritty kitty ghostty konsole gnome-terminal xterm; do "
                      + "if command -v \"$t\" >/dev/null 2>&1; then "
                      + "exec \"$t\" -e ssh " + targetStr + "; "
                      + "fi; done"

        var copy = JSON.parse(JSON.stringify(w.actionStates))
        copy[hostId] = { status: "launching", time: Date.now() }
        w.actionStates = copy

        var termOk = false
        if (w.bridge && typeof w.bridge.executeCommand === "function") {
            termOk = w.bridge.executeCommand(launchCmd)
        }
        var updated = JSON.parse(JSON.stringify(w.actionStates))
        if (termOk) {
            updated[hostId] = { status: "ok", time: Date.now(), terminalType: "SSH" }
            w.lastNotice = "✓ Launched SSH terminal for " + targetStr
            w.lastNoticeColor = theme.success
        } else {
            updated[hostId] = { status: "error", time: Date.now(), detail: "Launch failed" }
            w.lastNotice = "✕ Failed to launch terminal for " + targetStr
            w.lastNoticeColor = theme.error
        }
        w.actionStates = updated
        resetNoticeTimer.restart()
    }

    function launchMosh(item) {
        if (!item) return
        var host = typeof item === "string" ? item.trim() : (item.host || item.target || "").trim()
        var user = (typeof item === "object" && item.user) ? item.user.trim() : ""
        var hostId = (typeof item === "object" && (item.id || item.label)) ? (item.id || item.label) : host
        if (!host.length) {
            var errCopy = JSON.parse(JSON.stringify(w.actionStates))
            errCopy[hostId] = { status: "error", detail: "No host", time: Date.now() }
            w.actionStates = errCopy
            w.lastNotice = "✕ Target host missing"
            w.lastNoticeColor = theme.error
            resetNoticeTimer.restart()
            return
        }

        var targetStr = user.length > 0 ? (user + "@" + host) : host
        var launchCmd = "for t in \"$TERMINAL\" foot alacritty kitty ghostty konsole gnome-terminal xterm; do "
                      + "if command -v \"$t\" >/dev/null 2>&1; then "
                      + "exec \"$t\" -e mosh " + targetStr + "; "
                      + "fi; done"

        var copy = JSON.parse(JSON.stringify(w.actionStates))
        copy[hostId] = { status: "launching", time: Date.now() }
        w.actionStates = copy

        var termOk = false
        if (w.bridge && typeof w.bridge.executeCommand === "function") {
            termOk = w.bridge.executeCommand(launchCmd)
        }
        var updated = JSON.parse(JSON.stringify(w.actionStates))
        if (termOk) {
            updated[hostId] = { status: "ok", time: Date.now(), terminalType: "MOSH" }
            w.lastNotice = "✓ Launched MOSH terminal for " + targetStr
            w.lastNoticeColor = theme.success
        } else {
            updated[hostId] = { status: "error", time: Date.now(), detail: "Launch failed" }
            w.lastNotice = "✕ Failed to launch terminal for " + targetStr
            w.lastNoticeColor = theme.error
        }
        w.actionStates = updated
        resetNoticeTimer.restart()
    }

    // Unified action trigger with full backward-compatibility
    function triggerAction(action) {
        if (!action) return
        var actType = action.type || ""
        if (actType === "ping") {
            pingHost(action)
        } else if (actType === "ssh") {
            launchSsh(action)
        } else if (actType === "mosh") {
            launchMosh(action)
        } else if (actType === "wol") {
            var mac = action.target || action.mac || ""
            var bcast = action.broadcast || "255.255.255.255"
            var actionId = action.id || action.label || "act"
            var copy = JSON.parse(JSON.stringify(w.actionStates))
            copy[actionId] = { status: "sending", time: Date.now() }
            w.actionStates = copy
            var res = -1
            if (w.bridge && typeof w.bridge.sendWakeOnLan === "function") {
                res = w.bridge.sendWakeOnLan(mac, bcast)
            }
            var updated = JSON.parse(JSON.stringify(w.actionStates))
            if (res === 0) {
                updated[actionId] = { status: "ok", time: Date.now() }
                w.lastNotice = "⚡ Magic packet broadcast to " + mac
                w.lastNoticeColor = theme.success
            } else {
                updated[actionId] = { status: "error", time: Date.now() }
                w.lastNotice = "✕ WoL failed: " + (res === -1 ? "invalid MAC" : "socket error")
                w.lastNoticeColor = theme.error
            }
            w.actionStates = updated
            resetNoticeTimer.restart()
        } else if (actType === "command") {
            var cmd = action.target || ""
            var cmdId = action.id || action.label || "act"
            var cmdCopy = JSON.parse(JSON.stringify(w.actionStates))
            cmdCopy[cmdId] = { status: "sending", time: Date.now() }
            w.actionStates = cmdCopy
            var ok = false
            if (w.bridge && typeof w.bridge.executeCommand === "function") {
                ok = w.bridge.executeCommand(cmd)
            }
            var updatedCmd = JSON.parse(JSON.stringify(w.actionStates))
            if (ok) {
                updatedCmd[cmdId] = { status: "ok", time: Date.now() }
                w.lastNotice = "✓ Command launched: " + cmd
                w.lastNoticeColor = theme.success
            } else {
                updatedCmd[cmdId] = { status: "error", time: Date.now() }
                w.lastNotice = "✕ Command failed to launch"
                w.lastNoticeColor = theme.error
            }
            w.actionStates = updatedCmd
            resetNoticeTimer.restart()
        } else if (actType === "webhook") {
            var url = action.target || ""
            var hookId = action.id || action.label || "act"
            var hookCopy = JSON.parse(JSON.stringify(w.actionStates))
            hookCopy[hookId] = { status: "sending", time: Date.now() }
            w.actionStates = hookCopy
            w.effHub.request(url, { method: "POST" }, function(reply) {
                var updatedWeb = JSON.parse(JSON.stringify(w.actionStates))
                if (reply && reply.ok) {
                    updatedWeb[hookId] = { status: "ok", time: Date.now() }
                    w.lastNotice = "✓ Webhook triggered successfully"
                    w.lastNoticeColor = theme.success
                } else {
                    updatedWeb[hookId] = { status: "error", time: Date.now() }
                    w.lastNotice = "✕ Webhook error: " + (reply ? reply.status : "network")
                    w.lastNoticeColor = theme.error
                }
                w.actionStates = updatedWeb
                resetNoticeTimer.restart()
            })
        } else {
            // Default to pinging host
            pingHost(action)
        }
    }

    function saveHostsList(newList) {
        if (!store || !instanceId) return
        store.setSetting(instanceId, "hosts", newList)
        store.setSetting(instanceId, "hostsText", formatHostsText(newList))
        store.setSetting(instanceId, "actions", newList)
        store.setSetting(instanceId, "actionsText", formatHostsText(newList))
    }

    function deleteHost(hostId) {
        var list = []
        for (var i = 0; i < w.hosts.length; i++) {
            if (w.hosts[i].id !== hostId) {
                list.push(w.hosts[i])
            }
        }
        saveHostsList(list)
    }

    function deleteAction(actionId) {
        deleteHost(actionId)
    }

    function startEdit(hostItem) {
        if (!hostItem) return
        w.isAdding = false
        w.editId = hostItem.id || ""
        w.editLabel = hostItem.label || ""
        w.editHost = hostItem.host || hostItem.target || ""
        w.editUser = hostItem.user || ""
    }

    function commitEdit() {
        if (!w.editLabel.trim().length || !w.editHost.trim().length) return
        var list = JSON.parse(JSON.stringify(w.hosts))
        var item = {
            id: w.editId.length ? w.editId : ("host-" + Date.now()),
            label: w.editLabel.trim(),
            host: w.editHost.trim(),
            user: w.editUser.trim()
        }

        if (w.isAdding) {
            list.push(item)
        } else {
            var found = false
            for (var i = 0; i < list.length; i++) {
                if (list[i].id === w.editId) {
                    list[i] = item
                    found = true
                    break
                }
            }
            if (!found) list.push(item)
        }
        saveHostsList(list)
        cancelEdit()
    }

    function startAdd() {
        w.isAdding = true
        w.editId = "host-" + Date.now()
        w.editLabel = ""
        w.editHost = ""
        w.editUser = ""
    }

    function cancelEdit() {
        w.isAdding = false
        w.editId = ""
        w.editLabel = ""
        w.editHost = ""
        w.editUser = ""
    }

    // Main Content
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: w.expanded ? 20 : 10
        spacing: 8

        // Host Cards Grid / Column
        GridLayout {
            Layout.fillWidth: true
            Layout.fillHeight: !w.expanded || (!w.isAdding && w.editId.length === 0)
            columns: {
                if (w.sizeClass === "wide" || w.width > 560) return 2
                return 1
            }
            rowSpacing: 8
            columnSpacing: 8

            Repeater {
                model: w.hosts
                delegate: Rectangle {
                    id: hostCard
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.minimumHeight: isCompact ? 48 : 82
                    Layout.maximumHeight: isCompact ? 56 : 105

                    readonly property var hostItem: modelData
                    readonly property var stateObj: w.actionStates[hostItem.id || hostItem.label] || ({})
                    readonly property string st: stateObj.status || "idle"
                    readonly property bool isCompact: w.height < 240 && !w.expanded

                    radius: theme.radiusMd
                    color: theme.cardBackgroundAlt
                    border.width: 1
                    border.color: {
                        if (st === "ok") return theme.success
                        if (st === "error") return theme.error
                        if (st === "pinging" || st === "launching") return w.effAccent
                        return theme.cardBorder
                    }

                    Behavior on border.color { ColorAnimation { duration: 150 } }

                    // Compact single-row layout
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        spacing: 8
                        visible: hostCard.isCompact

                        AppIcon {
                            name: "hard-drives"
                            size: 16
                            color: theme.accent
                        }

                        Text {
                            text: hostItem.label || "Host"
                            color: theme.textPrimary
                            font.family: theme.fontDisplay
                            font.pixelSize: 13
                            font.weight: Font.Bold
                        }

                        Text {
                            text: hostItem.user && hostItem.user.length > 0
                                  ? (hostItem.user + "@" + (hostItem.host || ""))
                                  : (hostItem.host || "")
                            color: theme.textTertiary
                            font.family: theme.fontMono
                            font.pixelSize: 11
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                        }

                        // Compact buttons: Ping, SSH, Mosh
                        RowLayout {
                            spacing: 4

                            Rectangle {
                                implicitWidth: 44; implicitHeight: 28; radius: 4
                                color: cPingMa.containsMouse ? theme.cardBackgroundHover : theme.cardBorder
                                Text {
                                    anchors.centerIn: parent
                                    text: "Ping"
                                    font.pixelSize: 11
                                    font.weight: Font.DemiBold
                                    color: theme.textPrimary
                                }
                                MouseArea {
                                    id: cPingMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: w.pingHost(hostItem)
                                }
                            }

                            Rectangle {
                                implicitWidth: 42; implicitHeight: 28; radius: 4
                                color: cSshMa.containsMouse ? theme.cardBackgroundHover : theme.cardBorder
                                Text {
                                    anchors.centerIn: parent
                                    text: "SSH"
                                    font.pixelSize: 11
                                    font.weight: Font.DemiBold
                                    color: theme.textPrimary
                                }
                                MouseArea {
                                    id: cSshMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: w.launchSsh(hostItem)
                                }
                            }

                            Rectangle {
                                implicitWidth: 46; implicitHeight: 28; radius: 4
                                color: cMoshMa.containsMouse ? theme.cardBackgroundHover : theme.cardBorder
                                Text {
                                    anchors.centerIn: parent
                                    text: "Mosh"
                                    font.pixelSize: 11
                                    font.weight: Font.DemiBold
                                    color: theme.textPrimary
                                }
                                MouseArea {
                                    id: cMoshMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: w.launchMosh(hostItem)
                                }
                            }
                        }
                    }

                    // Standard two-tier card layout
                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 10
                        spacing: 8
                        visible: !hostCard.isCompact

                        // Top Row: Icon, Hostname, Target Address, Status pill
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8

                            AppIcon {
                                name: "hard-drives"
                                size: 16
                                color: theme.accent
                            }

                            Text {
                                text: hostItem.label || "Host"
                                color: theme.textPrimary
                                font.family: theme.fontDisplay
                                font.pixelSize: 14
                                font.weight: Font.Bold
                            }

                            Text {
                                text: hostItem.user && hostItem.user.length > 0
                                      ? (hostItem.user + "@" + (hostItem.host || ""))
                                      : (hostItem.host || "")
                                color: theme.textTertiary
                                font.family: theme.fontMono
                                font.pixelSize: 11
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                            }

                            // Reachability Badge
                            Rectangle {
                                visible: st !== "idle"
                                implicitWidth: statusTxt.implicitWidth + 12
                                implicitHeight: 20
                                radius: 4
                                color: st === "ok" ? Qt.rgba(theme.success.r, theme.success.g, theme.success.b, 0.2)
                                       : (st === "error" ? Qt.rgba(theme.error.r, theme.error.g, theme.error.b, 0.2)
                                       : Qt.rgba(theme.warning.r, theme.warning.g, theme.warning.b, 0.2))
                                border.width: 1
                                border.color: st === "ok" ? theme.success
                                              : (st === "error" ? theme.error : theme.warning)
                                Text {
                                    id: statusTxt
                                    anchors.centerIn: parent
                                    text: {
                                        if (st === "pinging") return "Pinging..."
                                        if (st === "launching") return "Opening..."
                                        if (st === "ok") {
                                            if (stateObj.terminalType) return stateObj.terminalType + " ✓"
                                            if (stateObj.latency) return stateObj.latency
                                            return "✓"
                                        }
                                        if (st === "error") return stateObj.detail ? ("✕ " + stateObj.detail) : "✕"
                                        return ""
                                    }
                                    font.pixelSize: 10
                                    font.weight: Font.DemiBold
                                    color: st === "ok" ? theme.success
                                           : (st === "error" ? theme.error : theme.warning)
                                }
                            }
                        }

                        // Bottom Row: Tactile Action Buttons (Ping, SSH, Mosh)
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8

                            // Ping Button
                            Rectangle {
                                Layout.fillWidth: true
                                Layout.minimumWidth: 60
                                implicitHeight: 34
                                radius: 6
                                color: pingMa.containsMouse ? theme.cardBackgroundHover : theme.cardBorder
                                RowLayout {
                                    anchors.centerIn: parent
                                    spacing: 4
                                    AppIcon { name: "heartbeat"; size: 13; color: theme.textPrimary }
                                    Text {
                                        text: "Ping"
                                        font.pixelSize: 12
                                        font.weight: Font.DemiBold
                                        color: theme.textPrimary
                                    }
                                }
                                MouseArea {
                                    id: pingMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: w.pingHost(hostItem)
                                }
                            }

                            // SSH Button
                            Rectangle {
                                Layout.fillWidth: true
                                Layout.minimumWidth: 60
                                implicitHeight: 34
                                radius: 6
                                color: sshMa.containsMouse ? theme.cardBackgroundHover : theme.cardBorder
                                RowLayout {
                                    anchors.centerIn: parent
                                    spacing: 4
                                    AppIcon { name: "code"; size: 13; color: theme.textPrimary }
                                    Text {
                                        text: "SSH"
                                        font.pixelSize: 12
                                        font.weight: Font.DemiBold
                                        color: theme.textPrimary
                                    }
                                }
                                MouseArea {
                                    id: sshMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: w.launchSsh(hostItem)
                                }
                            }

                            // Mosh Button
                            Rectangle {
                                Layout.fillWidth: true
                                Layout.minimumWidth: 60
                                implicitHeight: 34
                                radius: 6
                                color: moshMa.containsMouse ? theme.cardBackgroundHover : theme.cardBorder
                                RowLayout {
                                    anchors.centerIn: parent
                                    spacing: 4
                                    AppIcon { name: "sparkle"; size: 13; color: theme.textPrimary }
                                    Text {
                                        text: "Mosh"
                                        font.pixelSize: 12
                                        font.weight: Font.DemiBold
                                        color: theme.textPrimary
                                    }
                                }
                                MouseArea {
                                    id: moshMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: w.launchMosh(hostItem)
                                }
                            }
                        }
                    }
                }
            }
        }

        // Status banner readout
        Rectangle {
            id: statusBanner
            Layout.fillWidth: true
            Layout.preferredHeight: (w.lastNotice.length > 0 && w.showStatusBanner) ? 28 : 0
            visible: w.lastNotice.length > 0 && w.showStatusBanner
            radius: 6
            color: Qt.rgba(w.lastNoticeColor.r, w.lastNoticeColor.g, w.lastNoticeColor.b, 0.12)
            border.width: 1
            border.color: Qt.rgba(w.lastNoticeColor.r, w.lastNoticeColor.g, w.lastNoticeColor.b, 0.3)
            clip: true

            Behavior on Layout.preferredHeight { NumberAnimation { duration: 150 } }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                spacing: 8

                Text {
                    Layout.fillWidth: true
                    text: w.lastNotice
                    color: w.lastNoticeColor
                    font.family: theme.fontDisplay
                    font.pixelSize: theme.fontCaption
                    elide: Text.ElideRight
                }
            }
        }

        // Expanded management section
        ColumnLayout {
            Layout.fillWidth: true
            visible: w.expanded
            spacing: 12

            Rectangle {
                Layout.fillWidth: true
                height: 1
                color: Qt.rgba(theme.textPrimary.r, theme.textPrimary.g, theme.textPrimary.b, 0.15)
            }

            RowLayout {
                Layout.fillWidth: true
                Text {
                    Layout.fillWidth: true
                    text: "Configured Systems (" + w.hosts.length + ")"
                    font.family: theme.fontDisplay
                    font.pixelSize: theme.fontTitle
                    font.weight: Font.Bold
                    color: theme.textPrimary
                }

                PillButton {
                    label: "+ Add System"
                    visible: !w.isAdding
                    onClicked: w.startAdd()
                }
            }

            // Inline system editor form
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: (w.isAdding || w.editId.length > 0) ? 140 : 0
                visible: w.isAdding || w.editId.length > 0
                clip: true
                radius: theme.radiusMd
                color: Qt.rgba(theme.textPrimary.r, theme.textPrimary.g, theme.textPrimary.b, 0.05)
                border.width: 1
                border.color: Qt.rgba(w.effAccent.r, w.effAccent.g, w.effAccent.b, 0.3)

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 14
                    spacing: 8

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10

                        TextField {
                            Layout.preferredWidth: 180
                            placeholderText: "System Name (e.g. palatka)"
                            text: w.editLabel
                            onTextChanged: w.editLabel = text
                            color: theme.textPrimary
                            background: Rectangle {
                                radius: 4
                                color: Qt.rgba(theme.textPrimary.r, theme.textPrimary.g, theme.textPrimary.b, 0.08)
                                border.color: parent.activeFocus ? w.effAccent : Qt.rgba(theme.textPrimary.r, theme.textPrimary.g, theme.textPrimary.b, 0.2)
                            }
                        }

                        TextField {
                            Layout.fillWidth: true
                            placeholderText: "Hostname or IP (e.g. 10.0.0.227)"
                            text: w.editHost
                            onTextChanged: w.editHost = text
                            color: theme.textPrimary
                            background: Rectangle {
                                radius: 4
                                color: Qt.rgba(theme.textPrimary.r, theme.textPrimary.g, theme.textPrimary.b, 0.08)
                                border.color: parent.activeFocus ? w.effAccent : Qt.rgba(theme.textPrimary.r, theme.textPrimary.g, theme.textPrimary.b, 0.2)
                            }
                        }

                        TextField {
                            Layout.preferredWidth: 160
                            placeholderText: "SSH User (optional)"
                            text: w.editUser
                            onTextChanged: w.editUser = text
                            color: theme.textPrimary
                            background: Rectangle {
                                radius: 4
                                color: Qt.rgba(theme.textPrimary.r, theme.textPrimary.g, theme.textPrimary.b, 0.08)
                                border.color: parent.activeFocus ? w.effAccent : Qt.rgba(theme.textPrimary.r, theme.textPrimary.g, theme.textPrimary.b, 0.2)
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10

                        Item { Layout.fillWidth: true }

                        PillButton {
                            label: "Cancel"
                            onClicked: w.cancelEdit()
                        }

                        PillButton {
                            label: w.isAdding ? "Add System" : "Save Changes"
                            primary: true
                            onClicked: w.commitEdit()
                        }
                    }
                }
            }

            // List of configured systems for management
            Repeater {
                model: w.hosts
                delegate: RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    AppIcon {
                        name: "hard-drives"
                        size: 18
                        color: theme.textSecondary
                    }

                    Text {
                        text: modelData.label
                        color: theme.textPrimary
                        font.family: theme.fontDisplay
                        font.pixelSize: theme.fontLabel
                        font.weight: Font.DemiBold
                    }

                    Text {
                        text: "(" + (modelData.user && modelData.user.length > 0 ? (modelData.user + "@" + modelData.host) : modelData.host) + ")"
                        color: theme.textTertiary
                        font.family: theme.fontMono
                        font.pixelSize: theme.fontCaption
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                    }

                    PillButton {
                        label: "Edit"
                        onClicked: w.startEdit(modelData)
                    }

                    PillButton {
                        label: "Delete"
                        danger: true
                        onClicked: w.deleteHost(modelData.id)
                    }
                }
            }
        }
    }
}
