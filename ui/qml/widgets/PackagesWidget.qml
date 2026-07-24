import QtQuick
import QtQuick.Layouts

// Installed package count, read from the package manager's own database.
//
// The number is FACTUAL, not decorative: it is a count of real entries in
// /var/lib/pacman/local or /var/lib/dpkg/status, resolved by the Rust core and
// probed off-thread (see app/src/distro_bridge.h). The distro NAME shown beside
// it is whatever /etc/os-release reports about this machine - reported, never
// guessed, and never illustrated with anyone's logo.
WidgetChrome {
    id: w
    property var metrics: ({})
    property bool expanded: false
    property bool active: true
    property var store: null
    property string instanceId: ""

    title: "Packages"; iconName: "packages"; accentColor: theme.catSystem

    // ── The bridge ───────────────────────────────────────────────────────────
    // Resolved from CONTEXT as `distro` (registered in both main.cpp files).
    //
    // Deliberately NOT declared as `property var distro`: an object property
    // SHADOWS the context property of the same name, so the widget would read its
    // own null forever. WidgetHost only assigns the shared lifecycle names
    // it knows (metrics/store/timeZones/…), so nothing would ever fill it in.
    // Tests inject through `distroOverride` instead, which cannot collide.
    property var distroOverride: null
    readonly property var bridgeObject: w.distroOverride ? w.distroOverride
                                                         : ((typeof distro !== "undefined")
                                                            ? distro : null)

    // The probe result, or null when there is no bridge / no answer yet. The
    // binding touches `ready` and `info` directly so it re-evaluates when the
    // C++ side emits infoChanged.
    readonly property var probe: {
        var d = w.bridgeObject
        if (!d || !d.ready) return null
        return d.info
    }

    // Three distinct states, and conflating any two of them is a lie:
    //   • no bridge / not probed yet  → "…"      (we do not know YET)
    //   • probed, unsupported family  → "-"      (we CANNOT know; reason shown)
    //   • probed, counted             → a number (0 would be a real answer)
    readonly property bool loading: w.probe === null
    readonly property bool counted: !w.loading && w.probe.packageCount !== null
                                    && w.probe.packageCount !== undefined
    readonly property int count: w.counted ? w.probe.packageCount : 0
    readonly property string distroName: w.probe ? (w.probe.name || "") : ""
    readonly property string reason: (w.probe && w.probe.unsupportedReason)
                                     ? w.probe.unsupportedReason : ""
    readonly property string packageSource: {
        var family = w.probe ? String(w.probe.family || "") : ""
        if (family === "arch") return "/var/lib/pacman/local"
        if (family === "debian") return "/var/lib/dpkg/status"
        if (family === "rpm") return "RPM family detected · database count unavailable"
        return family.length ? family + " package database" : ""
    }
    readonly property string countScope: {
        var family = w.probe ? String(w.probe.family || "") : ""
        if (family === "arch")
            return "Installed records only · one package directory per local database entry"
        if (family === "debian")
            return "Installed records only · Status is install ok installed"
        if (family === "rpm")
            return "Detected safely from os-release · no package process is executed"
        return "Installed package records only"
    }
    readonly property bool refreshing: bridgeObject
                                       && bridgeObject.refreshing === true
    readonly property real refreshedAtMs: bridgeObject
                                          ? Number(bridgeObject.refreshedAtMs || 0) : 0
    readonly property string refreshLabel: {
        if (w.refreshing) return "Refreshing…"
        if (w.refreshedAtMs <= 0) return "Not refreshed yet"
        return "Refreshed " + Qt.formatTime(new Date(w.refreshedAtMs), "HH:mm:ss")
    }
    readonly property string updateSummary: w.probe
                                            && w.probe.updates !== null
                                            && w.probe.updates !== undefined
                                            ? String(w.probe.updates) + " available"
                                            : "Not checked"
    readonly property string securitySummary: w.probe
                                              && w.probe.securityUpdates !== null
                                              && w.probe.securityUpdates !== undefined
                                              ? String(w.probe.securityUpdates) + " security"
                                              : "Not checked"
    readonly property string updatesReason: w.probe
                                            ? String(w.probe.updatesReason || "") : ""
    function refreshNow() {
        if (w.bridgeObject && typeof w.bridgeObject.refresh === "function")
            w.bridgeObject.refresh()
    }

    // Live per-instance config (see WidgetConfigSchema "packages").
    readonly property var cfg: {
        var _ = store ? store.revision : 0
        return (store && instanceId) ? JSON.parse(JSON.stringify(store.settingsFor(instanceId))) : ({})
    }
    // Same defaults as the schema `dflt`.
    readonly property bool showDistro: cfg.showDistro !== undefined ? cfg.showDistro : true
    readonly property bool shapedTile: !w.micro && (w.sizeClass === "wide"
                                                    || w.sizeClass === "tall"
                                                    || Math.min(w.width, w.height) >= 600)
    readonly property bool shortWide: w.sizeClass === "wide" && w.height < 380
    readonly property bool richDetails: shapedTile && w.height >= 400

    // Group a big number: 1461 -> "1 461". A thin space, not a comma/point -
    // those mean different things either side of the Atlantic, and this is a
    // count read across a room, not a parsed value.
    function groupDigits(n) {
        var s = "" + Math.max(0, Math.floor(n)), out = ""
        for (var i = 0; i < s.length; i++) {
            if (i > 0 && (s.length - i) % 3 === 0) out += " "
            out += s.charAt(i)
        }
        return out
    }

    // The header carries the distro name, so the count below stays a pure number.
    status: (w.showDistro && !w.expanded) ? w.distroName : ""

    ColumnLayout {
        anchors.centerIn: parent
        spacing: w.expanded ? 8 : 2

        Text {
            Layout.alignment: Qt.AlignHCenter
            // preferredWidth (not merely maximumWidth) so HorizontalFit has a
            // fixed box to shrink into - a bare cap is ignored for an oversized
            // implicitWidth on some Qt versions and the number overflows.
            Layout.preferredWidth: w.width - 2 * w.contentMargins
            Layout.maximumWidth: w.width - 2 * w.contentMargins
            horizontalAlignment: Text.AlignHCenter
            text: w.loading ? "…" : (w.counted ? w.groupDigits(w.count) : "-")
            font.pixelSize: w.expanded ? 120 : Math.max(28, Math.min(w.width * 0.30, 64))
            fontSizeMode: Text.HorizontalFit; minimumPixelSize: theme.fontMinimum; elide: Text.ElideRight
            font.bold: true; font.family: theme.fontMono
            color: w.counted ? w.effAccent : theme.textTertiary
        }

        Text {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: w.width * 0.9
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: w.loading ? "Reading package database…"
                            : (w.counted ? (w.count === 1 ? "package installed" : "packages installed")
                                         : "Package count unavailable")
            font.pixelSize: w.expanded ? 22 : theme.fontLabel
            color: theme.textPrimary
        }

        Rectangle {
            objectName: "packageDetailCard"
            visible: w.shapedTile && !w.loading && w.showDistro
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: Math.min(w.width * 0.86, 520)
            Layout.preferredHeight: w.shortWide ? 118 : 148
            radius: theme.radiusMd
            color: Qt.rgba(theme.cardBackgroundAlt.r, theme.cardBackgroundAlt.g,
                           theme.cardBackgroundAlt.b, 0.72)
            border.width: 1
            border.color: theme.cardBorder
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 10
                spacing: 3
                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        Layout.fillWidth: true
                        text: w.distroName
                        color: theme.textPrimary
                        font.pixelSize: theme.fontLabel
                        font.weight: Font.DemiBold
                        elide: Text.ElideRight
                    }
                    Text {
                        text: "READ ONLY"
                        color: w.effAccent
                        font.pixelSize: theme.fontMinimum
                        font.bold: true
                        font.letterSpacing: 0.8
                    }
                }
                Text {
                    Layout.fillWidth: true
                    text: w.packageSource.length ? w.packageSource : "Distribution package database"
                    color: theme.textPrimary
                    font.pixelSize: theme.fontLabel
                    elide: Text.ElideRight
                }
                Text {
                    visible: !w.shortWide
                    Layout.fillWidth: true
                    text: w.countScope
                    color: theme.textSecondary
                    font.pixelSize: theme.fontLabel
                    elide: Text.ElideRight
                }
                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        Layout.fillWidth: true
                        text: w.refreshLabel
                        color: theme.textSecondary
                        font.pixelSize: theme.fontLabel
                        elide: Text.ElideRight
                    }
                    Rectangle {
                        Layout.preferredWidth: 132
                        Layout.preferredHeight: Math.max(52, theme.touchTertiary)
                        radius: theme.radiusSm
                        color: refreshArea.pressed ? w.effAccent : theme.cardBackground
                        border.width: 1
                        border.color: w.effAccent
                        opacity: w.refreshing ? 0.55 : 1
                        Text {
                            anchors.centerIn: parent
                            text: w.refreshing ? "Refreshing" : "Refresh now"
                            color: refreshArea.pressed ? theme.textOnAccent
                                                       : theme.textPrimary
                            font.pixelSize: theme.fontLabel
                            font.bold: true
                        }
                        MouseArea {
                            id: refreshArea
                            objectName: "packageRefreshAction"
                            anchors.fill: parent
                            enabled: !w.refreshing
                            onClicked: w.refreshNow()
                            Accessible.name: "Refresh package inventory now"
                            Accessible.role: Accessible.Button
                        }
                    }
                }
            }
        }

        Rectangle {
            objectName: "packageUpdateContext"
            visible: w.richDetails && w.counted
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: Math.min(w.width * 0.86, 520)
            Layout.preferredHeight: 104
            radius: theme.radiusMd
            color: Qt.rgba(theme.cardBackgroundAlt.r, theme.cardBackgroundAlt.g,
                           theme.cardBackgroundAlt.b, 0.72)
            border.width: 1
            border.color: theme.cardBorder
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 10
                spacing: 4
                RowLayout {
                    Layout.fillWidth: true
                    Text { text: "UPDATES"; color: theme.textPrimary; font.pixelSize: theme.fontLabel; font.bold: true }
                    Item { Layout.fillWidth: true }
                    Text { text: w.updateSummary; color: theme.textPrimary; font.pixelSize: theme.fontLabel; font.family: theme.fontMono }
                }
                RowLayout {
                    Layout.fillWidth: true
                    Text { text: "SECURITY"; color: theme.textPrimary; font.pixelSize: theme.fontLabel; font.bold: true }
                    Item { Layout.fillWidth: true }
                    Text { text: w.securitySummary; color: theme.textPrimary; font.pixelSize: theme.fontLabel; font.family: theme.fontMono }
                }
                Text {
                    Layout.fillWidth: true
                    text: w.updatesReason.length ? w.updatesReason
                                                 : "No package mutation or metadata refresh is performed"
                    color: theme.textSecondary
                    font.pixelSize: theme.fontMinimum
                    elide: Text.ElideRight
                }
            }
        }

        // The distro name, in the body only when the header isn't showing it
        // (expanded hides `status`) - never both.
        Text {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: w.width * 0.9
            horizontalAlignment: Text.AlignHCenter
            visible: w.expanded && w.showDistro && w.distroName.length > 0
            text: w.distroName
            font.pixelSize: 26; font.family: theme.fontDisplay
            color: theme.textPrimary
            elide: Text.ElideRight
        }

        Text {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: w.width * 0.9
            horizontalAlignment: Text.AlignHCenter
            visible: w.expanded && w.packageSource.length > 0
            text: w.packageSource + " · read-only"
            font.pixelSize: theme.fontMinimum
            color: theme.textTertiary
            elide: Text.ElideRight
        }

        // WHY the number is absent, verbatim from the core - so an RPM user sees
        // "we don't read your package db" instead of a silent dash.
        Text {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: w.width * 0.9
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            visible: !w.loading && !w.counted && w.reason.length > 0
            text: w.reason
            font.pixelSize: theme.fontLabel; color: theme.warning
        }
    }
}
