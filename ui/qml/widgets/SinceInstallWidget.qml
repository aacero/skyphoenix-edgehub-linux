import QtQuick
import QtQuick.Layouts

// How long this system has been installed, derived from the package manager's
// own history (the first `installed` line in pacman.log, or the installer's
// timestamp on a dpkg system) - resolved by the Rust core, probed off-thread.
//
// It measures what it can actually see: on a system whose package log has been
// rotated away, that is the age of the LOG. The expanded view says so rather
// than presenting a confident wrong number.
WidgetChrome {
    id: w
    property var metrics: ({})
    property bool expanded: false
    property bool active: true
    property var store: null
    property string instanceId: ""
    property int tick: 0

    title: "System Age"; iconName: "sinceinstall"; accentColor: theme.catSystem

    // Resolved from CONTEXT as `distro`. NOT declared as `property var distro`:
    // an object property shadows the context property of the same name, and
    // WidgetHost never assigns this one, so a declared `distro`
    // would stay null forever in the real app. See PackagesWidget for the full
    // note. Tests inject via `distroOverride`.
    property var distroOverride: null

    readonly property var probe: {
        var d = w.distroOverride ? w.distroOverride
                                 : ((typeof distro !== "undefined") ? distro : null)
        if (!d || !d.ready) return null
        return d.info
    }

    // Three states, kept apart on purpose (see PackagesWidget): unknown-yet,
    // cannot-know, and a real epoch. `installEpoch` is null - never 0 - when
    // absent, so a missing date can never render as "installed in 1970".
    readonly property bool loading: w.probe === null
    readonly property bool known: !w.loading && w.probe.installEpoch !== null
                                  && w.probe.installEpoch !== undefined
    readonly property real installEpoch: w.known ? w.probe.installEpoch : 0
    readonly property string distroName: w.probe ? (w.probe.name || "") : ""
    readonly property string reason: (w.probe && w.probe.installReason)
                                     ? w.probe.installReason : ""
    readonly property string installSource: w.probe ? String(w.probe.installSource || "") : ""
    readonly property string evidencePath: w.probe ? String(w.probe.installEvidence || "") : ""
    readonly property string evidenceNote: w.probe ? String(w.probe.installEvidenceNote || "") : ""
    readonly property bool estimated: w.known && w.installSource !== "installer-record"
    readonly property string sourceLabel: w.installSource === "installer-record"
                                                   ? "Installer record"
                                                   : "Package history estimate"

    readonly property var cfg: {
        var _ = store ? store.revision : 0
        return (store && instanceId) ? JSON.parse(JSON.stringify(store.settingsFor(instanceId))) : ({})
    }
    // Same defaults as the schema `dflt`.
    readonly property string ageUnit: cfg.ageUnit !== undefined ? cfg.ageUnit : "auto"
    readonly property bool showDate: cfg.showDate !== undefined ? cfg.showDate : true
    readonly property bool shapedTile: !w.micro && (w.sizeClass === "wide" || w.sizeClass === "tall")
    readonly property bool richTile: w.shapedTile || (!w.micro && Math.min(w.width, w.height) >= 600)
    readonly property bool shortTile: w.height < 380

    // Whole days since install. `tick` keeps it current across midnight without a
    // per-widget timer. Clamped at 0: a clock skew that puts the install slightly
    // in the future must read "today", not "-1 days".
    readonly property int days: {
        w.tick
        if (!w.known) return 0
        var secs = (Date.now() / 1000) - w.installEpoch
        return Math.max(0, Math.floor(secs / 86400))
    }

    function anniversaryAfterMonths(start, monthCount) {
        var targetMonth = start.getMonth() + monthCount
        var targetYear = start.getFullYear() + Math.floor(targetMonth / 12)
        targetMonth = ((targetMonth % 12) + 12) % 12
        var finalDay = new Date(targetYear, targetMonth + 1, 0).getDate()
        return new Date(targetYear, targetMonth, Math.min(start.getDate(), finalDay),
                        start.getHours(), start.getMinutes(), start.getSeconds(),
                        start.getMilliseconds())
    }

    readonly property int completedMonths: {
        w.tick
        if (!w.known) return 0
        var start = new Date(w.installEpoch * 1000)
        var now = new Date()
        var months = (now.getFullYear() - start.getFullYear()) * 12
                     + now.getMonth() - start.getMonth()
        if (w.anniversaryAfterMonths(start, months) > now) months--
        return Math.max(0, months)
    }

    readonly property string displayUnit: {
        if (w.ageUnit !== "auto") return w.ageUnit
        if (w.days < 60) return "days"
        if (w.completedMonths < 24) return "months"
        return "years"
    }

    // Automatic mode promotes days, months, then years. Month anniversaries
    // are calendar-based, including end-of-month clamping.
    readonly property string valueText: {
        if (w.loading) return "…"
        if (!w.known) return "-"
        if (w.displayUnit === "days") return "" + w.days
        if (w.displayUnit === "months") return "" + w.completedMonths
        return (w.completedMonths / 12).toFixed(1)
    }
    readonly property string unitText: {
        if (w.loading) return "Reading install history…"
        if (!w.known) return "System age unavailable"
        var singular = (w.displayUnit === "days" && w.days === 1)
                       || (w.displayUnit === "months" && w.completedMonths === 1)
        var label = singular ? w.displayUnit.slice(0, -1) : w.displayUnit
        return label + (w.estimated ? " since earliest record" : " since install")
    }

    // The install date itself, in the user's locale.
    readonly property string dateText: {
        if (!w.known) return ""
        return Qt.formatDate(new Date(w.installEpoch * 1000), Qt.DefaultLocaleShortDate)
    }

    status: (w.showDate && !w.expanded && w.known)
            ? (w.estimated ? "Est. " + w.dateText : w.dateText) : ""

    ColumnLayout {
        anchors.centerIn: parent
        spacing: w.expanded ? 8 : 2

        Text {
            Layout.alignment: Qt.AlignHCenter
            // preferredWidth so HorizontalFit has a fixed box to shrink into -
            // see the same note in PackagesWidget.
            Layout.preferredWidth: w.width - 2 * w.contentMargins
            Layout.maximumWidth: w.width - 2 * w.contentMargins
            horizontalAlignment: Text.AlignHCenter
            text: w.valueText
            font.pixelSize: w.expanded ? 120 : Math.max(30, Math.min(w.width * 0.34, 68))
            fontSizeMode: Text.HorizontalFit; minimumPixelSize: theme.fontMinimum; elide: Text.ElideRight
            font.bold: true; font.family: theme.fontMono
            color: w.known ? w.effAccent : theme.textTertiary
        }

        Text {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: w.width * 0.9
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: w.unitText
            font.pixelSize: w.expanded ? 22 : theme.fontMinimum
            color: theme.textSecondary
        }

        Rectangle {
            objectName: "systemAgeDetailCard"
            visible: w.richTile && w.known && w.showDate && !w.expanded
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: Math.min(w.width * 0.88, 560)
            Layout.preferredHeight: w.shortTile ? 92 : 148
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
                        text: w.distroName.length ? w.distroName : "Linux system"
                        color: theme.textPrimary
                        font.pixelSize: theme.fontLabel
                        font.weight: Font.DemiBold
                        elide: Text.ElideRight
                    }
                    Text {
                        text: w.estimated ? "ESTIMATED" : "CONFIRMED"
                        color: w.estimated ? theme.warning : w.effAccent
                        font.pixelSize: theme.fontMinimum
                        font.bold: true
                        font.letterSpacing: 0.8
                    }
                }
                Text {
                    Layout.fillWidth: true
                    text: (w.estimated ? "Earliest record " : "Installed ") + w.dateText
                    color: theme.textSecondary
                    font.pixelSize: theme.fontLabel
                    elide: Text.ElideRight
                }
                Text {
                    Layout.fillWidth: true
                    text: w.sourceLabel + (w.evidencePath.length ? " · " + w.evidencePath : "")
                    color: theme.textTertiary
                    font.pixelSize: theme.fontMinimum
                    elide: Text.ElideMiddle
                }
                Text {
                    Layout.fillWidth: true
                    visible: !w.shortTile
                    text: w.evidenceNote
                    color: theme.textTertiary
                    font.pixelSize: theme.fontMinimum
                    wrapMode: Text.WordWrap
                    maximumLineCount: 3
                    elide: Text.ElideRight
                }
            }
        }

        Rectangle {
            objectName: "systemAgeUnavailableCard"
            visible: w.richTile && !w.loading && !w.known && w.reason.length > 0
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: Math.min(w.width * 0.88, 560)
            Layout.preferredHeight: 82
            radius: theme.radiusMd
            color: Qt.rgba(theme.cardBackgroundAlt.r, theme.cardBackgroundAlt.g,
                           theme.cardBackgroundAlt.b, 0.72)
            border.width: 1
            border.color: theme.cardBorder
            Text {
                anchors.fill: parent
                anchors.margins: 12
                text: w.reason
                wrapMode: Text.WordWrap
                verticalAlignment: Text.AlignVCenter
                color: theme.warning
                font.pixelSize: theme.fontLabel
            }
        }

        // Expanded: the exact date + the distro, since the header hides `status`.
        Text {
            Layout.alignment: Qt.AlignHCenter
            visible: w.expanded && w.showDate && w.known
            text: (w.distroName.length ? w.distroName + " · " : "")
                  + (w.estimated ? "Earliest record " : "Installed ") + w.dateText
            font.pixelSize: 26; font.family: theme.fontDisplay
            color: theme.textPrimary
            elide: Text.ElideRight
            Layout.preferredWidth: w.width * 0.9
            horizontalAlignment: Text.AlignHCenter
        }

        // Say what was actually measured. On a rotated log this age is the log's,
        // not the system's, and quietly implying otherwise would be the one real
        // dishonesty available to this widget.
        Text {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: w.width * 0.9
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            visible: w.expanded
            text: w.reason.length > 0 ? w.reason
                                      : w.sourceLabel
                                        + (w.evidencePath.length ? " · " + w.evidencePath : "")
                                        + ". " + w.evidenceNote
            font.pixelSize: theme.fontLabel; color: theme.textSecondary
        }
    }
}
