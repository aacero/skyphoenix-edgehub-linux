import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// ─────────────────────────────────────────────────────────────────────────
// QuickActionsWidget - tactile touch macro tile for wake-on-lan and actions.
//
// Provides direct one-tap triggers for waking homelab servers (WoL magic
// packets over local UDP broadcast), launching local maintenance commands,
// and triggering automation webhooks.
//
// Actions:
//   • wol:     Broadcasts a standard WoL magic packet to the target MAC address.
//   • command: Spawns a background detached shell command.
//   • webhook: Dispatches an HTTP request through NetHub's egress gate.
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

    function defaultIconForType(t) {
        if (t === "wol") return "hard-drives"
        if (t === "ping") return "heartbeat"
        if (t === "ssh") return "code"
        if (t === "mosh") return "sparkle"
        if (t === "command") return "code"
        if (t === "webhook") return "httpjson"
        return "sparkle"
    }

    function parseActionsText(text) {
        if (!text || typeof text !== "string") return []
        var lines = text.split("\n")
        var list = []
        for (var i = 0; i < lines.length; i++) {
            var line = lines[i].trim()
            if (!line || line.startsWith("#")) continue
            var parts = line.split("|").map(function(p) { return p.trim() })
            if (parts.length >= 3) {
                var label = parts[0]
                var type = parts[1].toLowerCase()
                var target = parts[2]
                var broadcast = parts.length >= 4 ? parts[3] : "255.255.255.255"
                list.push({
                    id: "act-" + i + "-" + label.toLowerCase().replace(/[^a-z0-9]/g, "-"),
                    label: label,
                    type: type,
                    target: target,
                    broadcast: broadcast,
                    icon: defaultIconForType(type)
                })
            }
        }
        return list
    }

    function formatActionsText(actionList) {
        if (!actionList || !Array.isArray(actionList)) return ""
        var lines = []
        for (var i = 0; i < actionList.length; i++) {
            var a = actionList[i]
            var line = (a.label || "Action") + " | " + (a.type || "wol") + " | " + (a.target || "")
            if (a.type === "wol" && a.broadcast && a.broadcast !== "255.255.255.255") {
                line += " | " + a.broadcast
            }
            lines.push(line)
        }
        return lines.join("\n")
    }

    readonly property var defaultActions: [
        { id: "wol-aframe", label: "Wake aframe", icon: "hard-drives", type: "wol", target: "00:11:22:33:44:55", broadcast: "255.255.255.255" },
        { id: "wol-deerpark", label: "Wake deerpark", icon: "hard-drives", type: "wol", target: "00:11:22:33:44:56", broadcast: "255.255.255.255" },
        { id: "wol-palatka", label: "Wake palatka", icon: "hard-drives", type: "wol", target: "00:11:22:33:44:57", broadcast: "255.255.255.255" },
        { id: "wol-pelican", label: "Wake pelican", icon: "hard-drives", type: "wol", target: "00:11:22:33:44:58", broadcast: "255.255.255.255" }
    ]

    readonly property var actions: {
        if (cfg.actionsText && typeof cfg.actionsText === "string" && cfg.actionsText.trim().length > 0) {
            var parsed = parseActionsText(cfg.actionsText)
            if (parsed.length > 0) return parsed
        }
        if (cfg.actions && Array.isArray(cfg.actions) && cfg.actions.length > 0) {
            return cfg.actions
        }
        return defaultActions
    }
    readonly property bool showStatusBanner: cfg.showStatusBanner !== undefined ? cfg.showStatusBanner : true

    property var actionStates: ({})
    property string lastNotice: ""
    property color lastNoticeColor: theme.textSecondary

    // Inline editor state for expanded mode
    property bool isAdding: false
    property string editId: ""
    property string editLabel: ""
    property string editType: "wol"
    property string editTarget: ""
    property string editBroadcast: "255.255.255.255"
    property string editIcon: "hard-drives"

    Timer {
        id: resetNoticeTimer
        interval: 3500
        repeat: false
        onTriggered: {
            w.lastNotice = ""
        }
    }

    function triggerAction(action) {
        if (!action) return
        var actionId = action.id || action.label || "act"
        var actType = action.type || "wol"

        // Mark as executing
        var copy = JSON.parse(JSON.stringify(w.actionStates))
        copy[actionId] = { status: "sending", time: Date.now() }
        w.actionStates = copy

        if (actType === "wol") {
            var mac = action.target || ""
            var bcast = action.broadcast || ""
            var res = -1
            if (w.bridge && typeof w.bridge.sendWakeOnLan === "function") {
                res = w.bridge.sendWakeOnLan(mac, bcast)
            } else {
                console.warn("QuickActions: bridge.sendWakeOnLan unavailable")
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
        } else if (actType === "ping") {
            var pingTarget = (action.target || "").trim()
            if (!pingTarget.length) {
                var pingErr = JSON.parse(JSON.stringify(w.actionStates))
                pingErr[actionId] = { status: "error", time: Date.now(), detail: "No host" }
                w.actionStates = pingErr
                w.lastNotice = "✕ Target host missing"
                w.lastNoticeColor = theme.error
                resetNoticeTimer.restart()
                return
            }

            var pingRes = { ok: false, error: "Unavailable", latencyMs: -1 }
            if (w.bridge && typeof w.bridge.pingHost === "function") {
                pingRes = w.bridge.pingHost(pingTarget, 2)
            }
            var updatedPing = JSON.parse(JSON.stringify(w.actionStates))
            if (pingRes && pingRes.ok) {
                var lat = (pingRes.latencyMs >= 0) ? (pingRes.latencyMs.toFixed(1) + " ms") : "ok"
                updatedPing[actionId] = { status: "ok", time: Date.now(), detail: lat }
                w.lastNotice = "✓ " + pingTarget + " is reachable (" + lat + ")"
                w.lastNoticeColor = theme.success
            } else {
                var errDetail = (pingRes && pingRes.error) ? pingRes.error : "unreachable"
                updatedPing[actionId] = { status: "error", time: Date.now(), detail: errDetail }
                w.lastNotice = "✕ " + pingTarget + " is " + errDetail
                w.lastNoticeColor = theme.error
            }
            w.actionStates = updatedPing
            resetNoticeTimer.restart()
        } else if (actType === "ssh" || actType === "mosh") {
            var targetHost = (action.target || "").trim()
            if (!targetHost.length) {
                var errStates = JSON.parse(JSON.stringify(w.actionStates))
                errStates[actionId] = { status: "error", time: Date.now() }
                w.actionStates = errStates
                w.lastNotice = "✕ Target host missing"
                w.lastNoticeColor = theme.error
                resetNoticeTimer.restart()
                return
            }

            var bin = (actType === "ssh") ? "ssh" : "mosh"
            // Spawn an interactive terminal emulator running ssh or mosh to target
            var launchCmd = "for t in \"$TERMINAL\" foot alacritty kitty ghostty konsole gnome-terminal xterm; do "
                          + "if command -v \"$t\" >/dev/null 2>&1; then "
                          + "exec \"$t\" -e " + bin + " " + targetHost + "; "
                          + "fi; done"

            var termOk = false
            if (w.bridge && typeof w.bridge.executeCommand === "function") {
                termOk = w.bridge.executeCommand(launchCmd)
            }
            var updatedTerm = JSON.parse(JSON.stringify(w.actionStates))
            if (termOk) {
                updatedTerm[actionId] = { status: "ok", time: Date.now() }
                w.lastNotice = "✓ Launched " + bin.toUpperCase() + " terminal for " + targetHost
                w.lastNoticeColor = theme.success
            } else {
                updatedTerm[actionId] = { status: "error", time: Date.now() }
                w.lastNotice = "✕ Failed to launch terminal for " + targetHost
                w.lastNoticeColor = theme.error
            }
            w.actionStates = updatedTerm
            resetNoticeTimer.restart()
        } else if (actType === "command") {
            var cmd = action.target || ""
            var ok = false
            if (w.bridge && typeof w.bridge.executeCommand === "function") {
                ok = w.bridge.executeCommand(cmd)
            }
            var updatedCmd = JSON.parse(JSON.stringify(w.actionStates))
            if (ok) {
                updatedCmd[actionId] = { status: "ok", time: Date.now() }
                w.lastNotice = "✓ Command launched: " + cmd
                w.lastNoticeColor = theme.success
            } else {
                updatedCmd[actionId] = { status: "error", time: Date.now() }
                w.lastNotice = "✕ Command failed to launch"
                w.lastNoticeColor = theme.error
            }
            w.actionStates = updatedCmd
            resetNoticeTimer.restart()
        } else if (actType === "webhook") {
            var url = action.target || ""
            w.effHub.request(url, { method: "POST" }, function(reply) {
                var updatedWeb = JSON.parse(JSON.stringify(w.actionStates))
                if (reply && reply.ok) {
                    updatedWeb[actionId] = { status: "ok", time: Date.now() }
                    w.lastNotice = "✓ Webhook triggered successfully"
                    w.lastNoticeColor = theme.success
                } else {
                    updatedWeb[actionId] = { status: "error", time: Date.now() }
                    w.lastNotice = "✕ Webhook error: " + (reply ? reply.status : "network")
                    w.lastNoticeColor = theme.error
                }
                w.actionStates = updatedWeb
                resetNoticeTimer.restart()
            })
        }
    }

    function saveActionList(newList) {
        if (!store || !instanceId) return
        store.setSetting(instanceId, "actions", newList)
        store.setSetting(instanceId, "actionsText", formatActionsText(newList))
    }

    function deleteAction(actionId) {
        var list = []
        for (var i = 0; i < w.actions.length; i++) {
            if (w.actions[i].id !== actionId) {
                list.push(w.actions[i])
            }
        }
        saveActionList(list)
    }

    function startEdit(action) {
        if (!action) return
        w.isAdding = false
        w.editId = action.id || ""
        w.editLabel = action.label || ""
        w.editType = action.type || "wol"
        w.editTarget = action.target || ""
        w.editBroadcast = action.broadcast || "255.255.255.255"
        w.editIcon = action.icon || defaultIconForType(action.type)
    }

    function commitEdit() {
        if (!w.editLabel.trim().length || !w.editTarget.trim().length) return
        var list = JSON.parse(JSON.stringify(w.actions))
        var item = {
            id: w.editId.length ? w.editId : ("act-" + Date.now()),
            label: w.editLabel.trim(),
            type: w.editType,
            target: w.editTarget.trim(),
            broadcast: w.editBroadcast.trim(),
            icon: w.editIcon || defaultIconForType(w.editType)
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
        saveActionList(list)
        cancelEdit()
    }

    function startAdd() {
        w.isAdding = true
        w.editId = "act-" + Date.now()
        w.editLabel = ""
        w.editType = "wol"
        w.editTarget = ""
        w.editBroadcast = "255.255.255.255"
        w.editIcon = "hard-drives"
    }

    function cancelEdit() {
        w.isAdding = false
        w.editId = ""
        w.editLabel = ""
        w.editTarget = ""
    }

    // Main Content
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: w.expanded ? 20 : 10
        spacing: 8

        // Macro button grid
        GridLayout {
            Layout.fillWidth: true
            Layout.fillHeight: !w.expanded || (!w.isAdding && w.editId.length === 0)
            columns: {
                if (w.sizeClass === "wide" || w.width > 600) return 4
                if (w.sizeClass === "tall" || w.width < 280) return 1
                return 2
            }
            rowSpacing: 8
            columnSpacing: 8

            Repeater {
                model: w.actions
                delegate: Rectangle {
                    id: btnRect
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.minimumHeight: 52
                    Layout.maximumHeight: w.expanded ? 70 : 85

                    readonly property var act: modelData
                    readonly property var stateObj: w.actionStates[act.id] || ({})
                    readonly property string st: stateObj.status || "idle"
                    readonly property bool isPressed: btnMouse.pressed

                    radius: theme.radiusMd
                    color: {
                        if (isPressed) return Qt.darker(w.effAccent, 1.3)
                        if (st === "ok") return Qt.rgba(theme.success.r, theme.success.g, theme.success.b, 0.22)
                        if (st === "error") return Qt.rgba(theme.error.r, theme.error.g, theme.error.b, 0.22)
                        if (btnMouse.containsMouse) return Qt.rgba(theme.textPrimary.r, theme.textPrimary.g, theme.textPrimary.b, 0.12)
                        return Qt.rgba(theme.textPrimary.r, theme.textPrimary.g, theme.textPrimary.b, 0.06)
                    }

                    border.width: 1
                    border.color: {
                        if (st === "ok") return theme.success
                        if (st === "error") return theme.error
                        if (st === "sending") return w.effAccent
                        if (btnMouse.containsMouse) return Qt.rgba(w.effAccent.r, w.effAccent.g, w.effAccent.b, 0.5)
                        return Qt.rgba(theme.textPrimary.r, theme.textPrimary.g, theme.textPrimary.b, 0.12)
                    }

                    scale: isPressed ? 0.97 : 1.0
                    Behavior on scale { NumberAnimation { duration: 80 } }
                    Behavior on color { ColorAnimation { duration: 150 } }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        spacing: 10

                        // Action Icon
                        AppIcon {
                            id: actIcon
                            Layout.alignment: Qt.AlignVCenter
                            name: act.icon || w.defaultIconForType(act.type)
                            size: 22
                            color: {
                                if (st === "ok") return theme.success
                                if (st === "error") return theme.error
                                if (st === "sending") return w.effAccent
                                return isPressed ? "#FFFFFF" : theme.textPrimary
                            }
                        }

                        // Label and Subtitle
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            spacing: 2

                            Text {
                                Layout.fillWidth: true
                                text: act.label || "Action"
                                color: theme.textPrimary
                                font.family: theme.fontDisplay
                                font.pixelSize: theme.fontLabel
                                font.weight: Font.DemiBold
                                elide: Text.ElideRight
                            }

                            Text {
                                Layout.fillWidth: true
                                text: {
                                    if (st === "sending") {
                                        if (act.type === "ping") return "Pinging..."
                                        if (act.type === "ssh" || act.type === "mosh") return "Launching..."
                                        if (act.type === "wol") return "Waking..."
                                        return "Sending..."
                                    }
                                    if (st === "ok") {
                                        if (act.type === "ping" && stateObj.detail) return "✓ " + stateObj.detail
                                        if (act.type === "ssh" || act.type === "mosh") return "Terminal open"
                                        if (act.type === "wol") return "Packet sent"
                                        return "Done"
                                    }
                                    if (st === "error") {
                                        if (act.type === "ping" && stateObj.detail) return "✕ " + stateObj.detail
                                        return "Failed"
                                    }
                                    if (act.type === "wol") return "WoL · " + (act.target || "")
                                    if (act.type === "ping") return "Ping · " + (act.target || "")
                                    if (act.type === "ssh") return "SSH · " + (act.target || "")
                                    if (act.type === "mosh") return "Mosh · " + (act.target || "")
                                    if (act.type === "command") return "Command"
                                    return "Webhook"
                                }
                                color: {
                                    if (st === "ok") return theme.success
                                    if (st === "error") return theme.error
                                    return theme.textTertiary
                                }
                                font.family: theme.fontDisplay
                                font.pixelSize: theme.fontCaption
                                elide: Text.ElideRight
                            }
                        }

                        // Type Badge or Status Indicator
                        Rectangle {
                            Layout.alignment: Qt.AlignVCenter
                            implicitWidth: Math.max(38, typeBadgeText.implicitWidth + 8)
                            height: 20
                            radius: 4
                            color: {
                                if (st === "ok") return theme.success
                                if (st === "error") return theme.error
                                if (st === "sending") return w.effAccent
                                return Qt.rgba(theme.textPrimary.r, theme.textPrimary.g, theme.textPrimary.b, 0.12)
                            }

                            Text {
                                id: typeBadgeText
                                anchors.centerIn: parent
                                text: {
                                    if (st === "sending") return "..."
                                    if (st === "ok") {
                                        if (act.type === "ping" && stateObj.detail) return stateObj.detail
                                        return "✓"
                                    }
                                    if (st === "error") return "✕"
                                    if (act.type === "wol") return "WoL"
                                    if (act.type === "ping") return "PING"
                                    if (act.type === "ssh") return "SSH"
                                    if (act.type === "mosh") return "MOSH"
                                    if (act.type === "command") return "CMD"
                                    return "URL"
                                }
                                color: (st === "ok" || st === "error" || st === "sending") ? "#FFFFFF" : theme.textSecondary
                                font.family: theme.fontDisplay
                                font.pixelSize: 10
                                font.weight: Font.Bold
                            }
                        }
                    }

                    MouseArea {
                        id: btnMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: {
                            w.triggerAction(act)
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
                    text: "Configured Actions (" + w.actions.length + ")"
                    font.family: theme.fontDisplay
                    font.pixelSize: theme.fontTitle
                    font.weight: Font.Bold
                    color: theme.textPrimary
                }

                PillButton {
                    label: "+ Add Action"
                    visible: !w.isAdding
                    onClicked: w.startAdd()
                }
            }

            // Inline action editor form
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: (w.isAdding || w.editId.length > 0) ? 210 : 0
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

                        Text {
                            text: "Type:"
                            color: theme.textSecondary
                            font.family: theme.fontDisplay
                            font.pixelSize: theme.fontCaption
                        }

                        SegmentedControl {
                            Layout.fillWidth: true
                            options: [
                                { label: "Wake-on-LAN", value: "wol" },
                                { label: "Ping", value: "ping" },
                                { label: "SSH", value: "ssh" },
                                { label: "Mosh", value: "mosh" },
                                { label: "Command", value: "command" },
                                { label: "Webhook", value: "webhook" }
                            ]
                            currentValue: w.editType
                            onSelected: function(v) { w.editType = v }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10

                        TextField {
                            Layout.preferredWidth: 200
                            placeholderText: "Action Label (e.g. Wake aframe)"
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
                            placeholderText: {
                                if (w.editType === "wol") return "MAC Address (e.g. 00:11:22:33:44:55)"
                                if (w.editType === "ping") return "Hostname or IP (e.g. deerpark or 192.168.1.10)"
                                if (w.editType === "ssh" || w.editType === "mosh") return "Host or user@host (e.g. deerpark or acero@deerpark)"
                                if (w.editType === "command") return "Shell command (e.g. systemctl restart ...)"
                                return "Webhook URL (e.g. http://192.168.1.5:8123/...)"
                            }
                            text: w.editTarget
                            onTextChanged: w.editTarget = text
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

                        TextField {
                            Layout.preferredWidth: 200
                            visible: w.editType === "wol"
                            placeholderText: "Broadcast IP (default 255.255.255.255)"
                            text: w.editBroadcast
                            onTextChanged: w.editBroadcast = text
                            color: theme.textPrimary
                            background: Rectangle {
                                radius: 4
                                color: Qt.rgba(theme.textPrimary.r, theme.textPrimary.g, theme.textPrimary.b, 0.08)
                                border.color: parent.activeFocus ? w.effAccent : Qt.rgba(theme.textPrimary.r, theme.textPrimary.g, theme.textPrimary.b, 0.2)
                            }
                        }

                        Item { Layout.fillWidth: true }

                        PillButton {
                            label: "Cancel"
                            onClicked: w.cancelEdit()
                        }

                        PillButton {
                            label: w.isAdding ? "Add Action" : "Save Changes"
                            primary: true
                            onClicked: w.commitEdit()
                        }
                    }
                }
            }

            // List of configured actions for management
            Repeater {
                model: w.actions
                delegate: RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    AppIcon {
                        name: modelData.icon || w.defaultIconForType(modelData.type)
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
                        text: "(" + (modelData.type || "wol").toUpperCase() + ": " + (modelData.target || "") + ")"
                        color: theme.textTertiary
                        font.family: theme.fontDisplay
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
                        onClicked: w.deleteAction(modelData.id)
                    }
                }
            }
        }
    }
}
