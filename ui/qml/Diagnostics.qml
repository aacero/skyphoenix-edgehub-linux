import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: diag
    objectName: "diagnosticsPage"
    // NO `anchors.fill: parent` here. This item is a StackView PAGE (main.qml
    // pushes it), and StackView sets its pages' x/y/width/height itself. Anchoring
    // as well produced, on every launch:
    //     QML StackView: StackView has detected conflicting anchors.
    //     Transitions may not execute properly.
    // i.e. Qt telling us the push/pop transitions may not run. Every other host
    // sizes this item too: the tests' Loaders are `anchors.fill: parent`, and a
    // Loader resizes its loaded item to itself. A host that does NEITHER must set
    // width/height explicitly.

    property string metricsJson: ""
    property string configJson: ""
    property string screensData: ""
    // Tier-0 user-widget loader report (JSON from UserWidgetCatalog.reportJson):
    // { enabled, dir, loaded: [{type,title,dir}], skipped: [{dir,reason}] }.
    property string userWidgetsJson: ""
    property int currentPage: 0

    // The app-global NetHub egress gate (W5 finding 6): injected by the
    // Dashboard's ⚙ push (or resolved off the stack by main.qml's
    // bindStackItem). Null when no dashboard is running in this session
    // (--diagnostics start) - the Network tab then states that honestly
    // instead of rendering zeros that look like an attestation.
    property var netHub: null

    // byHost ({ host: count }) flattened to sorted rows for the Repeater.
    // Reactive: NetHub reassigns byHost on every bump, and swapping netHub
    // itself re-evaluates too.
    readonly property var netHosts: {
        if (!diag.netHub) return []
        var m = diag.netHub.byHost || {}
        var out = []
        for (var k in m) out.push({ host: k, n: m[k] })
        out.sort(function (a, b) { return b.n !== a.n ? b.n - a.n : (a.host < b.host ? -1 : 1) })
        return out
    }

    // Human-readable rendering of the loader report - every skipped directory
    // shows its reason HERE, so a broken manifest is diagnosable on-device.
    readonly property string userWidgetsText: {
        var r = null
        try { r = JSON.parse(diag.userWidgetsJson || "") } catch (e) { r = null }
        if (!r || r.enabled === undefined)
            return "No loader report available."
        if (!r.enabled)
            return "Disabled (enableUserWidgets is off - the default).\nThe widgets directory is not scanned."
        var lines = ["Directory: " + (r.dir || "?")]
        var loaded = r.loaded || [], skipped = r.skipped || []
        lines.push("Loaded: " + loaded.length)
        for (var i = 0; i < loaded.length; i++)
            lines.push("  + " + loaded[i].type + "  (" + loaded[i].title + ")  " + loaded[i].dir)
        lines.push("Skipped: " + skipped.length)
        for (var j = 0; j < skipped.length; j++)
            lines.push("  ! " + skipped[j].dir + "\n      reason: " + skipped[j].reason)
        return lines.join("\n")
    }

    // Parse the metrics ONCE per push (guarded), instead of re-parsing inside every
    // Overview card's text binding (6× per second, unguarded → a malformed payload
    // blanked the whole grid).
    readonly property var parsedMetrics: {
        try { return JSON.parse(metricsJson || "{}") } catch (e) { return {} }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 12

        // Header
        RowLayout {
            Layout.fillWidth: true
            Text {
                text: "Diagnostics"
                color: theme.accent
                font.pixelSize: 22
                font.bold: true
            }
            Item { Layout.fillWidth: true }
            Button {
                text: "← Back"
                onClicked: stackView.pop()
                flat: true
                leftPadding: 18; rightPadding: 18; topPadding: 14; bottomPadding: 14
                contentItem: Text {
                    text: "← Back"
                    color: theme.textSecondary
                    verticalAlignment: Text.AlignVCenter
                }
                background: Rectangle {
                    color: parent.down ? theme.cardBackgroundAlt : (parent.hovered ? Qt.lighter(theme.cardBackground, 1.1) : "transparent")
                    radius: 6
                }
            }
        }

        // Tab bar
        RowLayout {
            Layout.fillWidth: true
            spacing: 4
            Repeater {
                // "Network" is appended (index 4) so the existing page indexes
                // stay stable for callers and tests.
                model: ["Overview", "Config", "Screens", "Log", "Network"]
                Button {
                    text: modelData; flat: true; checked: diag.currentPage === index
                    checkable: true; autoExclusive: true
                    onClicked: diag.currentPage = index
                    leftPadding: 16; rightPadding: 16; topPadding: 14; bottomPadding: 14
                    contentItem: Text {
                        text: modelData
                        color: parent.checked ? theme.textPrimary : theme.textSecondary
                        font.weight: parent.checked ? Font.Bold : Font.Normal
                        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                    }
                    background: Rectangle {
                        color: parent.checked ? Qt.lighter(theme.cardBackground, 1.1) : "transparent"
                        radius: 6
                        Rectangle {
                            anchors.bottom: parent.bottom; width: parent.width; height: 2
                            color: parent.parent.checked ? theme.accent : "transparent"
                        }
                    }
                }
            }
        }

        // Page content
        StackLayout {
            Layout.fillWidth: true; Layout.fillHeight: true
            currentIndex: diag.currentPage

            // Page 0: Overview
            Item {
                Flickable {
                    anchors.fill: parent; contentHeight: overviewCol.implicitHeight; clip: true
                    ColumnLayout {
                    id: overviewCol
                    width: parent.width; spacing: 10
                    Text { text: "System Overview"; color: theme.textPrimary; font.pixelSize: 16; font.bold: true }
                    GridLayout {
                        columns: 3; columnSpacing: 12; rowSpacing: 12; Layout.fillWidth: true
                        Repeater {
                            model: [
                                { label: "CPU Usage", key: "cpu_usage_percent", unit: "%", color: theme.success },
                                { label: "CPU Temp", key: "cpu_temp_celsius", unit: "°C", color: theme.warning },
                                { label: "RAM Usage", key: "ram_usage_percent", unit: "%", color: theme.accent },
                                { label: "RAM Total", key: "ram_total_bytes", unit: "GB", color: theme.textSecondary, fmt: "bytes_to_gb" },
                                { label: "RAM Used", key: "ram_used_bytes", unit: "GB", color: theme.error, fmt: "bytes_to_gb" },
                                { label: "CPU Cores", key: "cpu_core_count", unit: "", color: theme.catProductivity }
                            ]
                            Rectangle {
                                Layout.fillWidth: true; Layout.preferredHeight: 80; radius: 8
                                color: theme.cardBackground; border.color: theme.cardBorder
                                ColumnLayout {
                                    anchors.centerIn: parent; spacing: 4
                                    Text { text: modelData.label; color: theme.textSecondary; font.pixelSize: theme.fontMinimum; Layout.alignment: Qt.AlignHCenter }
                                    Text {
                                        text: {
                                            var val = diag.parsedMetrics[modelData.key];
                                            if (val === undefined || val === null) return "N/A";
                                            if (modelData.fmt === "bytes_to_gb") return (val/(1024*1024*1024)).toFixed(1)+" "+modelData.unit;
                                            if (typeof val === "number") return val.toFixed(1)+modelData.unit;
                                            return val+modelData.unit;
                                        }
                                        color: modelData.color
                                        font.pixelSize: 20; font.bold: true; Layout.alignment: Qt.AlignHCenter
                                    }
                                }
                            }
                        }
                    }
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: 100; radius: 8
                        color: theme.backgroundColor; border.color: theme.cardBorder
                        ColumnLayout {
                            anchors.fill: parent; anchors.margins: 12; spacing: 4
                            readonly property string appVer: (typeof configBridge !== "undefined" && configBridge && configBridge.appVersion) ? configBridge.appVersion() : "dev"
                            Text { text: "Xeneon Edge Hub " + parent.appVer; color: theme.textPrimary; font.pixelSize: theme.fontLabel; font.bold: true }
                            Text { text: "Platform: " + Qt.platform.os + " | Build " + parent.appVer; color: theme.textSecondary; font.pixelSize: theme.fontMinimum }
                            Text { text: "Build: " + (typeof _buildType !== "undefined" && _buildType ? _buildType : "unknown"); color: theme.textSecondary; font.pixelSize: theme.fontMinimum }
                        }
                    }
                    }
                }
            }

            // Page 1: Config
            Item {
                Flickable {
                    anchors.fill: parent; contentHeight: configCol.implicitHeight+20; clip: true
                    ColumnLayout {
                        id: configCol; width: parent.width; spacing: 8
                        Text { text: "Redacted configuration summary"; color: theme.textPrimary; font.pixelSize: 16; font.bold: true }
                        Rectangle {
                            Layout.fillWidth: true; implicitHeight: configText.implicitHeight+24; radius: 8
                            color: theme.backgroundColor; border.color: theme.cardBorder
                            Text {
                                id: configText; anchors.fill: parent; anchors.margins: 12
                                text: diag.configJson || "Loading..."; color: theme.textPrimary
                                font.family: theme.fontMono; font.pixelSize: theme.fontMinimum; wrapMode: Text.Wrap
                            }
                        }
                        Text { text: "User widgets (Tier-0)"; color: theme.textPrimary; font.pixelSize: 16; font.bold: true }
                        Rectangle {
                            Layout.fillWidth: true; implicitHeight: uwText.implicitHeight+24; radius: 8
                            color: theme.backgroundColor; border.color: theme.cardBorder
                            Text {
                                id: uwText; anchors.fill: parent; anchors.margins: 12
                                text: diag.userWidgetsText; color: theme.textPrimary
                                font.family: theme.fontMono; font.pixelSize: theme.fontMinimum; wrapMode: Text.Wrap
                            }
                        }
                    }
                }
            }

            // Page 2: Screens
            Item {
                Flickable {
                    anchors.fill: parent; contentHeight: screensCol.implicitHeight+20; clip: true
                    ColumnLayout {
                        id: screensCol; width: parent.width; spacing: 12
                        Text { text: "Connected Displays"; color: theme.textPrimary; font.pixelSize: 16; font.bold: true }
                        Repeater {
                            model: { try { return JSON.parse(diag.screensData||"[]") } catch(e) { return [] } }
                            Rectangle {
                                Layout.fillWidth: true; implicitHeight: 160; radius: 8
                                color: theme.cardBackground
                                border.color: modelData.likelyXeneonEdge ? theme.success : theme.cardBorder
                                ColumnLayout {
                                    anchors.fill: parent; anchors.margins: 12; spacing: 4
                                    RowLayout {
                                        Text { text: modelData.model||"Unknown"; color: theme.textPrimary; font.pixelSize: theme.fontLabel; font.bold: true }
                                        Rectangle {
                                            visible: modelData.likelyXeneonEdge
                                            color: theme.success; radius: 4
                                            implicitWidth: badgeText.implicitWidth+16; implicitHeight: 30
                                            Text { id: badgeText; anchors.centerIn: parent; text: "XENEON EDGE"; color: theme.backgroundColor; font.pixelSize: theme.fontMinimum; font.bold: true }
                                        }
                                        Rectangle {
                                            visible: modelData.isPrimary
                                            color: theme.accent; radius: 4
                                            implicitWidth: primaryText.implicitWidth+16; implicitHeight: 30
                                            Text { id: primaryText; anchors.centerIn: parent; text: "PRIMARY"; color: theme.backgroundColor; font.pixelSize: theme.fontMinimum; font.bold: true }
                                        }
                                    }
                                    Text { text: (modelData.geometry?modelData.geometry.width+"×"+modelData.geometry.height:"?")+" @ "+(modelData.refreshRate?modelData.refreshRate.toFixed(0):"?")+"Hz | "+(modelData.orientation||"?"); color: theme.textSecondary; font.pixelSize: theme.fontMinimum }
                                    Text { text: "DPI: "+(modelData.logicalDpi?modelData.logicalDpi.toFixed(0):"?")+" logical / "+(modelData.physicalDpi?modelData.physicalDpi.toFixed(0):"?")+" physical"; color: theme.textSecondary; font.pixelSize: theme.fontMinimum }
                                    Text { text: "Connector: "+(modelData.name||"?"); color: theme.textSecondary; font.pixelSize: theme.fontMinimum }
                                    Text { text: "EDID Hash: "+(modelData.edidHash||"N/A"); color: theme.textSecondary; font.family: theme.fontMono; font.pixelSize: theme.fontMinimum; elide: Text.ElideMiddle; Layout.fillWidth: true }
                                }
                            }
                        }
                    }
                }
            }

            // Page 3: Log
            Item {
                ColumnLayout {
                    anchors.fill: parent; spacing: 8
                    Text { text: "Log Output"; color: theme.textPrimary; font.pixelSize: 16; font.bold: true }
                    Text {
                        text: "Logs are written to stdout/stderr via the Rust tracing subscriber.\nUse --diagnostics to view live logs, or check journal/syslog."
                        color: theme.textSecondary; font.pixelSize: theme.fontMinimum; wrapMode: Text.WordWrap; Layout.fillWidth: true
                    }
                    Rectangle {
                        Layout.fillWidth: true; Layout.fillHeight: true; radius: 8
                        color: theme.backgroundColor; border.color: theme.cardBorder
                        Text {
                            anchors.fill: parent; anchors.margins: 12
                            text: "Run with RUST_LOG=debug for detailed logs.\n\nConfig dir: "+_configDir
                            color: theme.textPrimary; font.family: theme.fontMono; font.pixelSize: theme.fontMinimum; wrapMode: Text.Wrap
                        }
                    }
                }
            }

            // Page 4: Network - the NetHub attestation surface (W5 finding 6).
            // NetHub.qml has counted "for Diagnostics" since it shipped and the
            // README promises per-host counters; this is the page that finally
            // reads them: kill-switch state, allowlist, sent/blocked totals,
            // and per-host counts, straight off the injected gate.
            Item {
                Flickable {
                    anchors.fill: parent; contentHeight: netCol.implicitHeight+20; clip: true
                    ColumnLayout {
                        id: netCol; width: parent.width; spacing: 10
                        Text { text: "Network (egress gate)"; color: theme.textPrimary; font.pixelSize: 16; font.bold: true }
                        Text {
                            text: "Every outbound request a widget makes goes through one audited gate. These counters are that gate's own tally for this session."
                            color: theme.textSecondary; font.pixelSize: theme.fontMinimum; wrapMode: Text.WordWrap; Layout.fillWidth: true
                        }

                        // No gate in this session (--diagnostics starts without a
                        // dashboard): say so - zeros here would read as an attestation.
                        Text {
                            visible: !diag.netHub
                            text: "The network gate is not available in this session (no dashboard is running)."
                            color: theme.warning; font.pixelSize: theme.fontMinimum; wrapMode: Text.WordWrap; Layout.fillWidth: true
                        }

                        Rectangle {
                            visible: !!diag.netHub
                            Layout.fillWidth: true; implicitHeight: gateCol.implicitHeight+24; radius: 8
                            color: theme.cardBackground; border.color: theme.cardBorder
                            ColumnLayout {
                                id: gateCol
                                anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                                anchors.margins: 12; spacing: 6
                                Text {
                                    text: "Offline kill switch: " + (diag.netHub && diag.netHub.offline
                                          ? "On - all remote requests are refused" : "Off")
                                    color: diag.netHub && diag.netHub.offline ? theme.warning : theme.textPrimary
                                    font.pixelSize: theme.fontMinimum; wrapMode: Text.WordWrap; Layout.fillWidth: true
                                }
                                Text {
                                    text: "Allowed hosts: " + (diag.netHub && diag.netHub.allowHosts
                                                               && diag.netHub.allowHosts.length
                                          ? diag.netHub.allowHosts.join(", ")
                                          : "any host (no allowlist active)")
                                    color: theme.textPrimary; font.pixelSize: theme.fontMinimum
                                    wrapMode: Text.WrapAnywhere; Layout.fillWidth: true
                                }
                                Text {
                                    text: "Requests sent: " + (diag.netHub ? diag.netHub.requests : 0)
                                    color: theme.textPrimary; font.pixelSize: theme.fontMinimum
                                }
                                Text {
                                    text: "Blocked by the gate: " + (diag.netHub ? diag.netHub.blocked : 0)
                                    color: theme.textPrimary; font.pixelSize: theme.fontMinimum
                                }
                            }
                        }

                        Text {
                            visible: !!diag.netHub
                            text: "Requests by host"; color: theme.textPrimary; font.pixelSize: 16; font.bold: true
                        }
                        Text {
                            visible: !!diag.netHub && diag.netHosts.length === 0
                            text: "No requests have been sent this session."
                            color: theme.textSecondary; font.pixelSize: theme.fontMinimum
                        }
                        Repeater {
                            model: diag.netHosts
                            Rectangle {
                                Layout.fillWidth: true; implicitHeight: 40; radius: 8
                                color: theme.backgroundColor; border.color: theme.cardBorder
                                RowLayout {
                                    anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12
                                    Text {
                                        text: modelData.host; color: theme.textPrimary
                                        font.family: theme.fontMono; font.pixelSize: theme.fontMinimum
                                        elide: Text.ElideMiddle; Layout.fillWidth: true
                                    }
                                    Text {
                                        text: modelData.n + (modelData.n === 1 ? " request" : " requests")
                                        color: theme.textSecondary; font.pixelSize: theme.fontMinimum
                                    }
                                }
                            }
                        }
                        Text {
                            visible: !!diag.netHub
                            text: "\"(local)\" counts file:/qrc: reads - they never leave this machine."
                            color: theme.textTertiary; font.pixelSize: theme.fontMinimum; wrapMode: Text.WordWrap; Layout.fillWidth: true
                        }
                    }
                }
            }
        }
    }
}
