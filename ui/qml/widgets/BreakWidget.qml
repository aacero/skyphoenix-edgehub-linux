import QtQuick
import QtQuick.Layouts

// Break reminder - a repeating interval timer that nudges you to take a break
// (ADHD time-blindness aid). Interval is persisted; the countdown runs while
// the tile is active (single-driver via `active`).
WidgetChrome {
    id: w
    property var metrics: ({})
    property bool expanded: false
    property bool active: true
    property var store: null
    property string instanceId: ""
    property bool foreground: true
    property var notificationBridge:
        (typeof notifications !== "undefined" ? notifications : null)
    // Per-minute tick injected by the Dashboard (S6): keeps todayKey/breaksToday
    // rolling over at midnight on a 24/7 device instead of freezing at boot-day.
    property int tick: 0

    title: "Break Reminder"; iconName: "break"; accentColor: theme.success
    // The micro tile is a bare ring - a header would compete for a twelfth of
    // the screen (see the sizing flags below WidgetChrome's contract props).
    showHeader: !micro

    // All state lives in the store (absolute end-epoch, running, paused-remaining,
    // due), so the tile and the expanded view are the SAME timer and it survives
    // a restart. Derived from cfg exactly like FocusWidget.
    readonly property var cfg: {
        var _ = store ? store.revision : 0
        return (store && instanceId) ? JSON.parse(JSON.stringify(store.settingsFor(instanceId))) : ({})
    }
    property int intervalMin: cfg.intervalMin || 30
    property bool running: cfg.running !== undefined ? cfg.running : true
    property bool due: cfg.due || false
    // Custom reminder text shown when a break is due; empty → default wording.
    readonly property string message: cfg.message !== undefined ? cfg.message : ""
    readonly property bool showSuggestion: cfg.showSuggestion !== undefined ? cfg.showSuggestion : true
    readonly property bool notifyWhenHidden: cfg.notifyWhenHidden === true
    readonly property int workStartHour: cfg.workStartHour !== undefined ? cfg.workStartHour : 9
    readonly property int workEndHour: cfg.workEndHour !== undefined ? cfg.workEndHour : 17
    readonly property string workDays: cfg.workDays !== undefined ? cfg.workDays : "1,2,3,4,5"
    readonly property int snoozeMin: cfg.snoozeMin !== undefined ? cfg.snoozeMin : 5
    readonly property bool snoozed: cfg.snoozed === true
    readonly property var selectedWorkDays: workDays.split(",").map(function (v) {
        return String(v).trim()
    }).filter(function (v, index, all) {
        return /^[0-6]$/.test(v) && all.indexOf(v) === index
    }).map(function (v) { return Number(v) })
    readonly property bool scheduleEnabled: selectedWorkDays.length > 0
    function withinScheduleAt(hour, day) {
        var days = selectedWorkDays
        if (workStartHour === workEndHour) return days.indexOf(day) >= 0
        if (workEndHour > workStartHour)
            return days.indexOf(day) >= 0 && hour >= workStartHour && hour < workEndHour
        // An overnight window belongs to the day on which the shift starts.
        // Tuesday 02:00 is therefore part of Monday's 22:00 to 06:00 window.
        var shiftDay = hour < workEndHour ? (day + 6) % 7 : day
        return days.indexOf(shiftDay) >= 0
               && (hour >= workStartHour || hour < workEndHour)
    }
    function withinSchedule() { var n = new Date(); return withinScheduleAt(n.getHours(), n.getDay()) }
    // Breaks acknowledged today (momentum), auto-resets across midnight.
    property string todayKey: (w.tick, Qt.formatDate(new Date(), "yyyy-MM-dd"))
    property int breaksToday: cfg.day === todayKey ? (cfg.breaksToday || 0) : 0
    readonly property string stateLabel: {
        if (w.due) return "Break due"
        if (!w.scheduleEnabled) return "Schedule disabled"
        if (!w.running) return "Paused"
        if (w.cfg.scheduleSuspended) return "Outside active hours"
        if (w.snoozed) return "Snoozed"
        return "Running"
    }
    readonly property string stateDescription: {
        if (!w.scheduleEnabled) return "No active weekdays selected"
        if (!w.running) return "Timer paused"
        if (w.cfg.scheduleSuspended) return "Waiting for active hours"
        if (w.snoozed) return "Snoozed until the next reminder"
        return "until next break"
    }
    status: w.stateLabel
    readonly property var breakIdeas: [
        "Stand up & stretch", "Drink some water", "Look 20ft away for 20s",
        "Roll your shoulders", "Take 5 slow breaths", "Quick walk around"
    ]

    property int pulse: 0
    property int remaining: {
        pulse
        if (due) return 0
        if (running && cfg.endEpoch)
            return Math.max(0, Math.round((cfg.endEpoch - Date.now()) / 1000))
        return cfg.pausedRemaining !== undefined ? cfg.pausedRemaining : intervalMin * 60
    }

    function save(o) { if (store) store.patchSettings(instanceId, o) }
    function reset() {
        var scheduled = withinSchedule()
        save({ due: false, running: true, snoozed: false, pausedRemaining: intervalMin * 60,
               scheduleSuspended: !scheduled,
               endEpoch: scheduled ? Date.now() + intervalMin * 60 * 1000 : 0 })
    }
    // Acknowledge a due break: count it toward today's total, then restart the timer.
    function takeBreak() {
        var scheduled = withinSchedule()
        var nextBreakCount = w.breaksToday + 1
        // Assign the count explicitly. Qt's QML compiler can otherwise confuse
        // the object-literal key with the same-named bound widget property.
        var patch = {
            due: false,
            running: true,
            snoozed: false,
            day: w.todayKey,
            pausedRemaining: w.intervalMin * 60,
            scheduleSuspended: !scheduled,
            endEpoch: scheduled ? Date.now() + w.intervalMin * 60 * 1000 : 0
        }
        patch.breaksToday = nextBreakCount
        save(patch)
    }
    function snooze() {
        var secs = Math.max(1, snoozeMin) * 60
        var scheduled = withinSchedule()
        save({ due: false, running: true, snoozed: true, pausedRemaining: secs,
               scheduleSuspended: !scheduled,
               endEpoch: scheduled ? Date.now() + secs * 1000 : 0 })
    }
    // A config-side interval change reseeds the countdown to the new length (so the
    // slider isn't half-honored), preserving the running/paused state. Only the
    // active instance writes, and it's deferred to avoid a write during binding eval.
    onIntervalMinChanged: Qt.callLater(_applyInterval)
    function _applyInterval() {
        if (!w.active || cfg.intervalMin === undefined) return
        var secs = w.intervalMin * 60
        if (w.running) {
            var scheduled = w.withinSchedule()
            save({ due: false, snoozed: false, pausedRemaining: secs, scheduleSuspended: !scheduled,
                   endEpoch: scheduled ? Date.now() + secs * 1000 : 0 })
        }
        else save({ due: false, snoozed: false, pausedRemaining: secs, endEpoch: 0 })
    }
    function toggleRun() {
        if (running) {
            // While due, `remaining` is forced to 0 - snapshotting it would
            // persist pausedRemaining:0 and corrupt the timer. Fall back to the
            // last stored remaining (or a full interval) instead.
            var snap = w.due ? (cfg.pausedRemaining !== undefined ? cfg.pausedRemaining : intervalMin * 60)
                             : remaining
            save({ running: false, pausedRemaining: snap })
        } else {
            var scheduled = withinSchedule()
            save({ running: true, scheduleSuspended: !scheduled,
                   endEpoch: scheduled ? Date.now() + remaining * 1000 : 0 })
        }
    }
    function setInterval(m) {
        var v = Math.max(5, Math.min(120, m))
        // Preserve the running/paused state: tapping ±5m while paused must not
        // silently resume the countdown.
        var run = w.running
        var scheduled = w.withinSchedule()
        save({ intervalMin: v, due: false, snoozed: false, running: run, pausedRemaining: v * 60,
               scheduleSuspended: run && !scheduled,
               endEpoch: run && scheduled ? Date.now() + v * 60 * 1000 : 0 })
    }
    function fmt(s) {
        var mm = Math.floor(s / 60), ss = s % 60
        return (mm < 10 ? "0" : "") + mm + ":" + (ss < 10 ? "0" : "") + ss
    }
    function notifyDue() {
        if (!w.notifyWhenHidden || w.foreground || !w.notificationBridge
                || !w.notificationBridge.send)
            return false
        var body = w.message.length ? w.message
            : "Time to stand up, reset, and take a short break."
        return w.notificationBridge.send("Break reminder", body)
    }
    function markDue() {
        if (w.due || w.remaining > 0 || !w.withinSchedule()) return false
        w.save({ due: true, snoozed: false })
        w.notifyDue()
        flash.restart()
        return true
    }

    // Seed an end time so a fresh (auto-running) reminder actually counts down.
    // Component.onCompleted runs BEFORE the store/instanceId are injected, so the
    // original seed here was a no-op and the timer stayed frozen. Instead, run the
    // seed reactively once the store is wired up (and again if the endEpoch key is
    // cleared). Only the active instance seeds, to avoid a double write, and only
    // when endEpoch is genuinely absent (undefined) - an explicit endEpoch:0 means
    // "no live end time, use the fallback" and must be left alone.
    function _seedIfNeeded() {
        if (!w.active || !store || !instanceId) return
        if (w.running && !w.due && cfg.endEpoch === undefined) {
            var scheduled = w.withinSchedule()
            save({ scheduleSuspended: !scheduled,
                   endEpoch: scheduled ? Date.now() + remaining * 1000 : 0 })
        }
    }
    Component.onCompleted: _seedIfNeeded()
    onStoreChanged: _seedIfNeeded()
    onInstanceIdChanged: _seedIfNeeded()
    Connections {
        target: w.store
        function onRevisionChanged() { w._seedIfNeeded() }
    }

    function applyScheduleState(scheduled) {
        if (!w.running || w.due) return
        if (!scheduled && !cfg.scheduleSuspended) {
            var snap = cfg.endEpoch
                ? Math.max(1, Math.round((cfg.endEpoch - Date.now()) / 1000))
                : Math.max(1, w.remaining)
            save({ scheduleSuspended: true, pausedRemaining: snap, endEpoch: 0 })
        } else if (scheduled && cfg.scheduleSuspended) {
            var secs = Math.max(1, cfg.pausedRemaining !== undefined
                                   ? cfg.pausedRemaining : intervalMin * 60)
            save({ scheduleSuspended: false,
                   endEpoch: Date.now() + secs * 1000 })
        }
    }

    Timer {
        interval: 1000; repeat: true; running: w.active
        onTriggered: {
            w.pulse++
            var scheduled = w.withinSchedule()
            w.applyScheduleState(scheduled)
            if (scheduled && w.running && !w.due && !w.cfg.scheduleSuspended
                    && w.remaining <= 0) {
                w.markDue()
            }
        }
    }
    Rectangle {
        anchors.fill: parent; radius: theme.radiusLg; color: w.effAccent; opacity: 0; z: 5
        SequentialAnimation on opacity {
            id: flash; running: false; loops: theme.effectiveReduceMotion ? 1 : 3
            NumberAnimation { to: theme.effectiveReduceMotion ? 0 : 0.30; duration: theme.motionFast }
            NumberAnimation { to: 0.0; duration: theme.motionSlow }
        }
    }

    // ── Per-size layout (sizeClass is injected by Dashboard) ─────────────────
    // 0.5x0.5 and 1x1 are both "compact" (shape, not footprint); the micro
    // half-cell is told apart by the box (~344-416px short side vs ~690px+).
    readonly property bool micro: sizeClass === "compact" && Math.min(width, height) < 480
    readonly property bool horiz: sizeClass === "wide"
    // What each size earns: micro is a bare progress ring (headerless, timer +
    // a tiny caption inside; when due, the message + a Done pill - a due break
    // must always be acknowledgeable). Every larger tile adds the caption, the
    // pause/reset controls at touch-token size, and today's momentum. ±5m and
    // the full control set stay in the overlay (a mode, not a size).
    readonly property bool showTileControls: !expanded && !micro
    readonly property bool showDetails: !expanded && !micro && Math.min(width, height) >= 600
    function scheduleLabel() {
        function hour(h) { return (h < 10 ? "0" : "") + h + ":00" }
        return workStartHour === workEndHour ? "All day"
             : hour(workStartHour) + " to " + hour(workEndHour)
    }
    function daysLabel() {
        if (!scheduleEnabled) return "No active days"
        if (selectedWorkDays.length === 7) return "Every day"
        if (workDays === "1,2,3,4,5") return "Weekdays"
        if (workDays === "0,6") return "Weekends"
        var names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return selectedWorkDays.map(function(day) { return names[day] }).join(", ")
    }
    readonly property real ringFrac: due ? 1
                                     : Math.max(0, Math.min(1, remaining / Math.max(1, intervalMin * 60)))
    readonly property real ringDia: {
        if (micro) return Math.min(width, height) * 0.78
        if (sizeClass === "compact") return Math.min(width * 0.60, height * 0.52)
        if (horiz) return Math.min(height * 0.78, width * 0.42)
        return Math.min(width * 0.72, height * 0.42)   // tall
    }

    // ── Tile layout (all sizes; the overlay has its own below) ──────────────
    GridLayout {
        id: tileLayout
        anchors.centerIn: parent
        width: parent.width * 0.94
        visible: !w.expanded && !w.due
        columns: w.horiz ? 2 : 1
        columnSpacing: theme.spacingLg
        rowSpacing: w.micro ? 0 : theme.spacingSm

        // Interval progress ring with the countdown inside - the tile reads at a
        // glance how far into the interval you are, not just a floating number.
        Item {
            id: ringBox
            Layout.alignment: Qt.AlignHCenter | Qt.AlignVCenter
            Layout.preferredWidth: Math.round(w.ringDia)
            Layout.preferredHeight: Math.round(w.ringDia)
            RingProgress {
                anchors.fill: parent
                value: w.ringFrac
                progressColor: w.effAccent; progressColor2: w.effAccent
                trackColor: Qt.rgba(theme.cardBorder.r, theme.cardBorder.g, theme.cardBorder.b, 0.6)
            }
            Column {
                anchors.centerIn: parent
                width: Math.round(ringBox.width * 0.62)
                spacing: 0
                Text {
                    objectName: "breakTimerValue"
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: w.fmt(w.remaining)
                    font.pixelSize: Math.max(20, Math.min(ringBox.width * 0.26, 64))
                    fontSizeMode: Text.HorizontalFit; minimumPixelSize: theme.fontMinimum; elide: Text.ElideRight
                    font.bold: true; font.family: theme.fontMono
                    color: theme.textPrimary
                }
                Text {
                    objectName: "breakRingState"
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    // Identity for the headerless micro ring; larger tiles already
                    // say "until next break" outside - only "paused" earns a
                    // duplicate mention there.
                    visible: w.micro || w.stateLabel !== "Running"
                    text: w.micro && w.stateLabel === "Running" ? "break"
                        : w.stateLabel.toLowerCase()
                    font.pixelSize: Math.max(18,
                                             Math.min(ringBox.width * 0.075, theme.fontLabel))
                    color: theme.textPrimary
                    opacity: 0.78
                }
            }
        }

        ColumnLayout {
            visible: w.showTileControls
            Layout.alignment: Qt.AlignVCenter | Qt.AlignHCenter
            Layout.fillWidth: true
            spacing: theme.spacingSm
            Text {
                objectName: "breakStateDescription"
                Layout.alignment: Qt.AlignHCenter
                text: w.stateDescription
                font.pixelSize: Math.max(18,
                                         Math.min(w.width * 0.032, theme.fontLabel))
                color: theme.textPrimary
                opacity: 0.82
            }
            Rectangle {
                objectName: "breakDetails"
                visible: w.showDetails
                Layout.fillWidth: true
                Layout.preferredWidth: Math.min(580, w.width * 0.86)
                Layout.preferredHeight: 92
                radius: theme.radiusMd
                color: Qt.rgba(w.effAccent.r, w.effAccent.g, w.effAccent.b, 0.08)
                border.width: 1
                border.color: Qt.rgba(w.effAccent.r, w.effAccent.g, w.effAccent.b, 0.24)
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: theme.spacingMd
                    anchors.rightMargin: theme.spacingMd
                    spacing: theme.spacingSm
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 2
                        Text { text: "RHYTHM"; color: theme.textPrimary; opacity: 0.72
                            font.pixelSize: Math.max(theme.fontMinimum, 16)
                            font.bold: true; font.letterSpacing: 1.1 }
                        Text { text: "Every " + w.intervalMin + " min"; color: theme.textPrimary
                            font.pixelSize: Math.max(theme.fontLabel, 18); font.bold: true }
                    }
                    Rectangle { Layout.preferredWidth: 1; Layout.fillHeight: true
                        Layout.topMargin: 14; Layout.bottomMargin: 14; color: theme.cardBorder }
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 2
                        Text { text: "SCHEDULE"; color: theme.textPrimary; opacity: 0.72
                            font.pixelSize: Math.max(theme.fontMinimum, 16)
                            font.bold: true; font.letterSpacing: 1.1 }
                        Text { text: w.scheduleLabel(); color: theme.textPrimary
                            font.pixelSize: Math.max(theme.fontLabel, 18); font.bold: true }
                        Text { text: w.daysLabel(); color: theme.textPrimary; opacity: 0.72
                            font.pixelSize: Math.max(theme.fontMinimum, 16); elide: Text.ElideRight
                            Layout.fillWidth: true }
                    }
                    Rectangle { Layout.preferredWidth: 1; Layout.fillHeight: true
                        Layout.topMargin: 14; Layout.bottomMargin: 14; color: theme.cardBorder }
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 2
                        Text { text: "TODAY"; color: theme.textPrimary; opacity: 0.72
                            font.pixelSize: Math.max(theme.fontMinimum, 16)
                            font.bold: true; font.letterSpacing: 1.1 }
                        Text { text: w.breaksToday + (w.breaksToday === 1 ? " break" : " breaks")
                            color: w.effAccent; font.pixelSize: Math.max(theme.fontLabel, 18); font.bold: true }
                    }
                }
            }
            RowLayout {
                objectName: "breakTileControls"
                Layout.alignment: Qt.AlignHCenter; spacing: theme.spacingSm
                PillButton { implicitHeight: theme.touchTertiary
                    label: w.running ? "Pause" : "Resume"; glyph: w.running ? "⏸" : "▶"
                    onClicked: w.toggleRun() }
                PillButton { implicitHeight: theme.touchTertiary
                    label: "Reset"; glyph: "⟲"; tint: w.effAccent; onClicked: w.reset() }
            }
            // Momentum: how many breaks acknowledged today.
            Text {
                Layout.alignment: Qt.AlignHCenter; visible: w.breaksToday > 0
                text: "✓ " + w.breaksToday + (w.breaksToday === 1 ? " break today" : " breaks today")
                font.pixelSize: Math.max(18,
                                         Math.min(w.width * 0.03, theme.fontLabel))
                color: theme.textPrimary; opacity: 0.72
            }
        }
    }

    // ── Due state on the tile: the reminder is the content ──────────────────
    ColumnLayout {
        anchors.centerIn: parent
        width: parent.width * 0.92
        visible: !w.expanded && w.due
        spacing: w.micro ? theme.spacingXs : theme.spacingSm
        Text {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            // Custom due-messages are user text and can be long - cap the width and
            // wrap/elide so they never overflow the tile (S12).
            wrapMode: Text.WordWrap; maximumLineCount: w.micro ? 2 : 3; elide: Text.ElideRight
            text: w.message.length ? w.message : "Take a break!"
            font.pixelSize: w.micro ? Math.max(18, Math.min(w.width * 0.09, 26))
                                    : Math.max(22, Math.min(w.width * 0.06, 44))
            font.bold: true; font.family: theme.fontDisplay
            color: w.effAccent
        }
        // Break-activity suggestion when a break is due (ADHD "what do I do now?").
        Text {
            Layout.fillWidth: true; visible: w.showSuggestion && !w.micro
            horizontalAlignment: Text.AlignHCenter
            text: "Try: " + w.breakIdeas[w.breaksToday % w.breakIdeas.length]
            font.pixelSize: Math.max(theme.fontMinimum, Math.min(w.width * 0.035, 18))
            font.italic: true; color: theme.textPrimary; opacity: 0.78
            elide: Text.ElideRight; maximumLineCount: 1
        }
        // Quick acknowledge - reachable at touch size in EVERY tile size.
        PillButton { Layout.alignment: Qt.AlignHCenter
            label: "Done"; primary: true; tint: w.effAccent; onClicked: w.takeBreak() }
        PillButton { Layout.alignment: Qt.AlignHCenter; visible: !w.micro
            label: "Snooze " + w.snoozeMin + "m"; glyph: "⏱"; onClicked: w.snooze() }
    }

    // ── Expanded overlay: the full control set ───────────────────────────────
    ColumnLayout {
        anchors.centerIn: parent; spacing: 14
        visible: w.expanded
        Text {
            Layout.alignment: Qt.AlignHCenter
            Layout.maximumWidth: w.width * 0.92
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap; maximumLineCount: 3; elide: Text.ElideRight
            text: w.due ? (w.message.length ? w.message : "Take a break!") : w.fmt(w.remaining)
            font.pixelSize: w.due ? 44 : 88
            font.bold: true; font.family: w.due ? theme.fontDisplay : theme.fontMono
            color: w.due ? w.effAccent : theme.textPrimary
        }
        Text {
            Layout.alignment: Qt.AlignHCenter; visible: !w.due
            text: w.stateDescription; font.pixelSize: Math.max(theme.fontLabel, 18)
            color: theme.textPrimary; opacity: 0.82
        }
        Text {
            Layout.alignment: Qt.AlignHCenter; visible: w.due && w.showSuggestion
            // preferredWidth pairs the cap so elide binds on a long suggestion.
            Layout.preferredWidth: w.width * 0.9
            Layout.maximumWidth: w.width * 0.9; horizontalAlignment: Text.AlignHCenter
            text: "Try: " + w.breakIdeas[w.breaksToday % w.breakIdeas.length]
            font.pixelSize: 18; font.italic: true; color: theme.textPrimary; opacity: 0.78
            elide: Text.ElideRight
        }
        RowLayout {
            Layout.alignment: Qt.AlignHCenter; spacing: theme.spacingSm
            PillButton { label: w.running ? "Pause" : "Resume"; glyph: w.running ? "⏸" : "▶"
                onClicked: w.toggleRun() }
            PillButton { label: w.due ? "Took it" : "Reset"; glyph: w.due ? "✓" : "⟲"; primary: true
                tint: w.effAccent; onClicked: w.due ? w.takeBreak() : w.reset() }
            PillButton { visible: w.due; label: "Snooze " + w.snoozeMin + "m"; glyph: "⏱"
                onClicked: w.snooze() }
        }
        RowLayout {
            Layout.alignment: Qt.AlignHCenter; spacing: theme.spacingSm
            PillButton { label: "−5m"; onClicked: w.setInterval(w.intervalMin - 5) }
            Text { text: "every " + w.intervalMin + "m"; color: theme.textPrimary; opacity: 0.82
                font.pixelSize: Math.max(theme.fontMinimum, 18)
                Layout.alignment: Qt.AlignVCenter }
            PillButton { label: "+5m"; onClicked: w.setInterval(w.intervalMin + 5) }
        }
        // Momentum: how many breaks acknowledged today.
        Text {
            Layout.alignment: Qt.AlignHCenter; visible: w.breaksToday > 0
            text: "✓ " + w.breaksToday + (w.breaksToday === 1 ? " break today" : " breaks today")
            font.pixelSize: Math.max(theme.fontMinimum, 18); color: theme.textPrimary; opacity: 0.72
        }
    }
}
