import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Countdown - days until a user-set date. Persisted; genuinely real once set.
//
// Sizing (W1): layout keys off `sizeClass` (injected by Dashboard - compact/
// wide/tall/large/full), NEVER off `expanded`, which is only used for the
// overlay's settings editor. Each declared size earns its space:
//   • 0.5x0.5 (micro) - the day count + a one-line caption, nothing else.
//   • 1x1 (compact)   - count + caption + the target-date row.
//   • wide            - count beside a left-aligned caption/date/progress column
//                       (1x0.5 portrait, 0.5x1 + 1x1.5 landscape).
//   • tall            - count over caption/date/progress, roomier type
//                       (0.5x1 + 1x1.5 portrait, 1x0.5 landscape).
//   • full            - the overlay: hero count + date + progress + editor.
WidgetChrome {
    id: w
    property var metrics: ({})
    property bool expanded: false
    property bool active: true
    property var store: null
    property string instanceId: ""
    property int tick: 0

    title: "Countdown"; iconName: "countdown"; accentColor: theme.catInfo
    showHeader: expanded

    readonly property var cfg: {
        var _ = store ? store.revision : 0
        return (store && instanceId) ? JSON.parse(JSON.stringify(store.settingsFor(instanceId))) : ({})
    }
    readonly property string label: String(cfg.label || "")
    // Preset settings can cross a QJSValue boundary before DashboardStore
    // serializes them. Coerce explicitly so an empty preset date remains an
    // empty string instead of producing a runtime assignment warning.
    readonly property string dateStr: String(cfg.date || "")
    readonly property bool hasStructuredTime: cfg.targetHour !== undefined
                                               || cfg.targetMinute !== undefined
    readonly property int targetHour: cfg.targetHour !== undefined
        ? Number(cfg.targetHour) : Number((cfg.time || "00:00").split(":")[0])
    readonly property int targetMinute: cfg.targetMinute !== undefined
        ? Number(cfg.targetMinute) : Number((cfg.time || "00:00").split(":")[1])
    readonly property string timeStr: (targetHour < 10 ? "0" : "") + targetHour
                                      + ":" + (targetMinute < 10 ? "0" : "") + targetMinute
    readonly property string precision: cfg.precision || "days"
    readonly property string afterEvent: cfg.afterEvent || "passed"
    readonly property bool repeatYearly: cfg.repeatYearly !== undefined ? cfg.repeatYearly : false
    readonly property string leapDayPolicy: cfg.leapDayPolicy || "nextLeap"
    property double nowMsOverride: -1
    function currentDate() { return new Date(w.nowMsOverride >= 0 ? w.nowMsOverride : Date.now()) }
    function dayStart(d) { var x = new Date(d); x.setHours(0, 0, 0, 0); return x }
    // Parse "YYYY-MM-DD" into a LOCAL-midnight Date, or null when malformed -
    // new Date(str) would treat it as UTC midnight and, west of UTC, land the
    // countdown one day off. Returns null for impossible days (Feb-31, Apr-31),
    // which JS would otherwise silently roll into the following month.
    function parseDate(str) {
        if (!str || !("" + str).length) return null
        var p = ("" + str).split("-")
        if (p.length < 3) return null
        var y = +p[0], mo = +p[1] - 1, d = +p[2]
        if (isNaN(y) || isNaN(mo) || isNaN(d) || mo < 0 || mo > 11 || d < 1 || d > 31) return null
        var target = new Date(y, mo, d)
        // Reject rollovers (e.g. Feb-31 → Mar-3): the built date must round-trip.
        if (isNaN(target.getTime()) || target.getFullYear() !== y ||
            target.getMonth() !== mo || target.getDate() !== d) return null
        return target
    }
    function parseTime(str) {
        var m = /^(\d{1,2}):(\d{2})$/.exec(String(str || ""))
        if (!m) return null
        var h = Number(m[1]), minute = Number(m[2])
        return h >= 0 && h <= 23 && minute >= 0 && minute <= 59 ? [h, minute] : null
    }
    // The date the countdown is actually aiming at: the stored date, or - for a
    // yearly repeat - its next occurrence on or after today (skipping non-leap
    // years for a Feb-29 anniversary, where new Date(y,1,29) rolls to Mar-1).
    function nextTarget() {
        var target = parseDate(dateStr)
        if (!target) return null
        var clock = parseTime(w.timeStr)
        if (!clock) return null
        target.setHours(clock[0], clock[1], 0, 0)
        if (!w.repeatYearly) return target
        var now = w.currentDate()
        var today0 = dayStart(now)
        var mo = target.getMonth(), d = target.getDate()
        for (var i = 0; i < 12; i++) {
            var year = today0.getFullYear() + i
            var c = new Date(year, mo, d)
            var substituted = false
            if (mo === 1 && d === 29 && c.getMonth() !== mo) {
                if (w.leapDayPolicy === "feb28") {
                    c = new Date(year, 1, 28)
                    substituted = true
                } else if (w.leapDayPolicy === "mar1") {
                    c = new Date(year, 2, 1)
                    substituted = true
                }
                else continue
            }
            c.setHours(clock[0], clock[1], 0, 0)
            if (!substituted && (c.getMonth() !== mo || c.getDate() !== d)) continue
            if (c >= now) return c
        }
        return null
    }
    // Validity is derived from parsing, NOT from `days`: a real date exactly 999
    // days in the past legitimately yields days === -999, which must not be
    // mistaken for the invalid sentinel.
    property bool valid: parseDate(dateStr) !== null && parseTime(timeStr) !== null
                         && targetHour >= 0 && targetHour <= 23
                         && targetMinute >= 0 && targetMinute <= 59
    property int days: {
        w.tick
        var target = nextTarget()
        if (!target) return -999   // -999 sentinel = invalid/unset
        return Math.round((dayStart(target) - dayStart(w.currentDate())) / 86400000)
    }
    readonly property int hoursRemaining: {
        w.tick
        var target = w.nextTarget()
        return target ? Math.ceil((target.getTime() - w.currentDate().getTime()) / 3600000) : 0
    }
    readonly property string heroText: {
        if (!w.valid) return "-"
        if (w.days < 0 && w.afterEvent === "complete") return "✓"
        if (w.days === 0 && w.hoursRemaining <= 0) return "NOW"
        if (w.precision === "auto" && w.hoursRemaining > 0 && w.hoursRemaining < 48)
            return w.hoursRemaining + "h"
        return "" + Math.abs(w.days)
    }
    readonly property string milestoneText: w.days === 30 ? "One month to go"
        : w.days === 7 ? "One week to go" : w.days === 1 ? "Tomorrow" : ""
    readonly property string eventIdentity: w.label.length ? w.label
        : (w.repeatYearly ? "Yearly event" : "Upcoming event")
    readonly property string countdownContext: {
        if (!w.valid)
            return w.expanded ? "Set a valid date and time in the configuration panel"
                              : "Set a date in settings"
        if (w.precision === "auto" && w.hoursRemaining > 0 && w.hoursRemaining < 48)
            return "hours until " + (w.label || "the event")
        if (w.days > 0)
            return (w.days === 1 ? "day until " : "days until ")
                   + (w.label || "the day")
        if (w.days === 0)
            return (w.label || "Today") + "!"
        return w.afterEvent === "complete" ? (w.label || "Event") + " complete"
                                           : (w.label || "the day") + " passed"
    }
    readonly property string timezoneText: {
        var offset = -w.currentDate().getTimezoneOffset()
        var sign = offset >= 0 ? "+" : "-"
        var abs = Math.abs(offset)
        var hh = Math.floor(abs / 60), mm = abs % 60
        return "Device local UTC" + sign + (hh < 10 ? "0" : "") + hh
               + ":" + (mm < 10 ? "0" : "") + mm
    }
    readonly property string leapPolicyText: {
        if (!w.repeatYearly || w.parseDate(w.dateStr) === null
                || w.parseDate(w.dateStr).getMonth() !== 1
                || w.parseDate(w.dateStr).getDate() !== 29) return ""
        if (w.leapDayPolicy === "feb28") return "In non-leap years: February 28"
        if (w.leapDayPolicy === "mar1") return "In non-leap years: March 1"
        return "Only occurs in leap years"
    }
    function occurrenceExplanation() {
        var target = w.nextTarget()
        if (!target) return "Choose a valid local date and time."
        var prefix = w.repeatYearly ? "Next yearly occurrence" : "Target"
        return prefix + ": " + Qt.formatDate(target, "ddd, d MMM yyyy")
               + " at " + w.timeStr + " (" + w.timezoneText + ")"
    }
    function visibleOccurrence() {
        var target = w.nextTarget()
        if (!target) return ""
        return (w.repeatYearly ? "Next" : "Target") + " · "
               + Qt.formatDate(target, "ddd, d MMM yyyy")
               + " · " + w.timeStr + " local"
    }

    Accessible.role: Accessible.Pane
    Accessible.name: w.title + ". " + w.eventIdentity + ". " + w.countdownContext
                     + (w.valid ? ". " + w.occurrenceExplanation() : "")

    // ── Progress context (an honest baseline or none at all) ────────────────
    // • repeatYearly: previous → next occurrence (the year cycle) - always real.
    // • one-time: from the moment THIS date was stored (dateSetEpoch, stamped
    //   below). No baseline → no bar; a made-up one would be a lie.
    readonly property real progress: {
        w.tick
        var target = nextTarget()
        if (!target || w.days < 0) return -1
        var end = dayStart(target).getTime()
        var start = -1
        if (w.repeatYearly) {
            for (var back = 1; back <= 8; back++) {
                var prev = new Date(target.getFullYear() - back, target.getMonth(), target.getDate())
                if (prev.getMonth() === target.getMonth() && prev.getDate() === target.getDate()) {
                    start = dayStart(prev).getTime()
                    break
                }
            }
        } else if (cfg.dateSetFor === w.dateStr && cfg.dateSetEpoch > 0) {
            start = cfg.dateSetEpoch
        }
        if (start < 0 || end <= start) return -1
        return Math.max(0, Math.min(1, (w.currentDate().getTime() - start) / (end - start)))
    }
    // Stamp when a (valid) date is stored so the one-time progress bar has a real
    // starting line. Keyed to the date string, so re-saving the same date never
    // moves the baseline; only the active instance writes (tile + overlay are two
    // instances of the same id) and the write is deferred out of binding eval.
    onDateStrChanged: Qt.callLater(_stampDateSet)
    function _stampDateSet() {
        if (!w.active || !store || !instanceId) return
        if (!w.valid || cfg.dateSetFor === w.dateStr) return
        store.patchSettings(instanceId, { dateSetFor: w.dateStr, dateSetEpoch: Date.now() })
    }

    // ── Per-size layout flags ────────────────────────────────────────────────
    // 0.5x0.5 and 1x1 are BOTH "compact" (the class describes shape, not
    // footprint); the micro half-cell is told apart by the box itself - its short
    // side is ~344-416px in either orientation vs ~690px+ for a full cell.
    readonly property bool micro: sizeClass === "compact" && Math.min(width, height) < 480
    readonly property bool horiz: sizeClass === "wide"
    readonly property bool showDateRow: valid && !micro
    readonly property bool showProgress: progress >= 0 && sizeClass !== "compact"
    readonly property real numPx: {
        if (sizeClass === "full") return 120
        if (micro) return Math.max(24, Math.min(width * 0.30, height * 0.36))
        if (sizeClass === "compact") return Math.max(30, Math.min(width * 0.26, height * 0.22, 140))
        if (horiz) return Math.max(34, Math.min(width * 0.20, height * 0.42, 150))
        return Math.max(32, Math.min(width * 0.30, height * 0.18, 150))   // tall
    }

    GridLayout {
        id: tileLayout
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left; anchors.right: parent.right
        visible: !w.expanded || w.valid
        columns: w.horiz ? 2 : 1
        rowSpacing: w.micro ? 2 : (w.sizeClass === "full" ? theme.spacingSm : theme.spacingXs)
        columnSpacing: theme.spacingLg

        Text {
            id: numText
            Layout.alignment: Qt.AlignHCenter | Qt.AlignVCenter
            // Constrain to the cell width and shrink-to-fit so a large (5-digit)
            // day count never overflows/clips a narrow tile. preferredWidth (not
            // just maximumWidth) forces the layout to allocate exactly this
            // width, so HorizontalFit has a fixed box to shrink into - a bare
            // maximumWidth cap is ignored for an oversized implicitWidth on some
            // Qt versions (e.g. 6.7), letting the number overflow.
            Layout.preferredWidth: w.horiz ? Math.round(tileLayout.width * 0.42)
                                           : tileLayout.width
            Layout.maximumWidth: w.horiz ? Math.round(tileLayout.width * 0.42)
                                         : tileLayout.width
            horizontalAlignment: Text.AlignHCenter
            text: w.heroText
            font.pixelSize: w.numPx
            fontSizeMode: Text.HorizontalFit; minimumPixelSize: theme.fontMinimum; elide: Text.ElideRight
            font.bold: true; font.family: theme.fontMono; color: w.effAccent
        }

        ColumnLayout {
            Layout.alignment: Qt.AlignVCenter
            Layout.fillWidth: true
            spacing: w.micro ? 0 : theme.spacingXs

            Text {
                objectName: "countdownEvent"
                visible: w.valid && !w.micro
                Layout.fillWidth: true
                horizontalAlignment: w.horiz ? Text.AlignLeft : Text.AlignHCenter
                text: w.eventIdentity
                color: theme.textPrimary
                font.pixelSize: w.sizeClass === "full" ? 28
                    : Math.max(theme.fontTitle, Math.min(w.width * 0.05, 24))
                font.bold: true
                wrapMode: Text.WordWrap
            }
            Text {
                objectName: "countdownContext"
                Layout.fillWidth: true
                horizontalAlignment: w.horiz ? Text.AlignLeft : Text.AlignHCenter
                // The event name is already the heading outside the micro tile.
                // Avoid repeating an unbounded user string in the supporting
                // sentence while retaining it in the micro tile and accessible
                // summary, where no separate heading is present.
                text: (w.micro || w.expanded) ? w.countdownContext
                              : (!w.valid ? w.countdownContext
                                          : (w.precision === "auto"
                                             && w.hoursRemaining > 0
                                             && w.hoursRemaining < 48
                                             ? "hours remaining"
                                             : w.days === 1 ? "day remaining"
                                             : w.days > 1 ? "days remaining"
                                             : w.days === 0 ? "Happening now"
                                             : w.afterEvent === "complete"
                                               ? "Complete" : "Passed"))
                font.pixelSize: w.sizeClass === "full" ? 22
                                : (w.micro ? theme.fontMinimum
                                           : Math.max(theme.fontLabel, Math.min(w.width * 0.04, 19)))
                color: theme.textSecondary
                wrapMode: Text.WordWrap
            }
            Text {
                objectName: "countdownTarget"
                visible: w.showDateRow
                Layout.fillWidth: true
                horizontalAlignment: w.horiz ? Text.AlignLeft : Text.AlignHCenter
                text: w.expanded ? w.occurrenceExplanation() : w.visibleOccurrence()
                      + (w.milestoneText.length ? " · " + w.milestoneText : "")
                font.pixelSize: w.sizeClass === "full" ? 18
                                : Math.max(theme.fontLabel, Math.min(w.width * 0.038, 20))
                font.family: theme.fontMono
                color: theme.textSecondary
                wrapMode: Text.WordWrap
            }
            Text {
                visible: w.showDateRow && w.leapPolicyText.length > 0
                Layout.fillWidth: true
                horizontalAlignment: w.horiz ? Text.AlignLeft : Text.AlignHCenter
                text: w.leapPolicyText
                color: theme.textSecondary
                font.pixelSize: Math.max(theme.fontLabel, Math.min(w.width * 0.034, 18))
                elide: Text.ElideRight
            }
            // Progress toward the day: only with room (never in compact) and only
            // when a real baseline exists.
            Rectangle {
                visible: w.showProgress
                Layout.topMargin: theme.spacingSm
                Layout.fillWidth: true
                Layout.maximumWidth: w.horiz ? tileLayout.width : Math.round(tileLayout.width * 0.86)
                Layout.alignment: w.horiz ? Qt.AlignLeft : Qt.AlignHCenter
                height: 6; radius: 3
                color: Qt.rgba(theme.cardBorder.r, theme.cardBorder.g, theme.cardBorder.b, 0.6)
                Rectangle {
                    width: Math.round(parent.width * Math.max(0, Math.min(1, w.progress)))
                    height: parent.height; radius: parent.radius
                    color: w.effAccent
                }
            }
        }
    }

    // The shared WidgetConfigPanel beside this preview owns the structured
    // controls. The preview states exactly what will be counted.
    ColumnLayout {
        anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
        visible: w.expanded; spacing: theme.spacingSm
        Text {
            Layout.fillWidth: true
            text: w.valid ? w.occurrenceExplanation()
                          : "Complete the event date and bounded local-time controls."
            color: w.valid ? theme.textSecondary : theme.warning
            font.pixelSize: theme.fontLabel
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
        }
        Text {
            visible: w.leapPolicyText.length > 0
            Layout.fillWidth: true
            text: w.leapPolicyText
            color: theme.textSecondary
            font.pixelSize: theme.fontLabel
            horizontalAlignment: Text.AlignHCenter
        }
    }
}
