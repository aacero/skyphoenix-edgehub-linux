import QtQuick
import QtQuick.Layouts

// End of Day - progress through the workday + time remaining. Real (system
// clock). Start/end hours are configurable and persisted.
//
// Sizing (W1 wave 2a): layout keys off the injected `sizeClass`.
//   • 0.5x0.5 (micro) - headerless: the remaining time + a slim bar.
//   • 1x1 (baseline)  - remaining + bar + "% of window" caption (the classic).
//   • wide            - remaining/caption beside the progress (bar or ring -
//                       progressStyle is finally honoured outside the overlay).
//   • tall            - progress hero (ring or bar) + a Started/Ends/Elapsed
//                       detail column: the workday spelled out.
//   • full (overlay)  - optional ring + the Start/End pills, sized by the pane it
//                       is actually given (see ringPx / remainingPx). It is NOT a
//                       full screen: Dashboard hosts it in a live-preview pane
//                       beside the config form - ~941x456 landscape, ~656x980
//                       portrait - so "full" is a class like any other and reads
//                       its own box rather than a set of literals.
//
// The Start/End pill row is the one thing here still keyed off the MODE, and that
// is correct: it is the config EDITOR, and the overlay is where this widget is
// edited (Dashboard puts the config form right beside it). It is an affordance
// question, not a dimension - a tall tile has the room for the pills and still
// should not become an editor.
WidgetChrome {
    id: w
    property var metrics: ({})
    property bool expanded: false
    property bool active: true
    property var store: null
    property string instanceId: ""
    property int tick: 0

    title: "End of Day"; iconName: "eod"; accentColor: theme.catInfo
    showHeader: !micro

    readonly property var cfg: {
        var _ = store ? store.revision : 0
        return (store && instanceId) ? JSON.parse(JSON.stringify(store.settingsFor(instanceId))) : ({})
    }
    // Config can arrive out of range (the number stepper writes raw values, or a
    // pushed doc). Wrap the start into 0..23 (25:00 → 01:00) and clamp the end
    // into 0..24 (24:00 = next-day midnight is a valid "end of day"), so a bad
    // config can never corrupt the window.
    property int startHour: {
        var raw = cfg.startHour !== undefined ? Math.round(cfg.startHour) : 9
        return ((raw % 24) + 24) % 24
    }
    property int endHour: {
        var raw = cfg.endHour !== undefined ? Math.round(cfg.endHour) : 17
        return Math.max(0, Math.min(24, raw))
    }
    readonly property bool showPercent: cfg.showPercent !== undefined ? cfg.showPercent : true
    readonly property string progressStyle: cfg.progressStyle !== undefined ? cfg.progressStyle : "bar"
    readonly property int startMinute: [0, 15, 30, 45].indexOf(Number(cfg.startMinute)) >= 0
        ? Number(cfg.startMinute) : 0
    readonly property int endMinute: endHour === 24 ? 0
        : ([0, 15, 30, 45].indexOf(Number(cfg.endMinute)) >= 0 ? Number(cfg.endMinute) : 0)
    readonly property bool allowOvernight: cfg.allowOvernight === true
    readonly property string workDays: cfg.workDays !== undefined
        ? String(cfg.workDays) : "0,1,2,3,4,5,6"
    readonly property int startTotalMinutes: startHour * 60 + startMinute
    readonly property int endTotalMinutes: endHour * 60 + endMinute
    readonly property bool overnightWindow: endTotalMinutes <= startTotalMinutes
    readonly property int windowMinutes: endTotalMinutes > startTotalMinutes
        ? endTotalMinutes - startTotalMinutes
        : 1440 - startTotalMinutes + endTotalMinutes
    readonly property bool hasActiveDays: {
        var configured = String(w.workDays).split(",")
        for (var i = 0; i < configured.length; i++)
            if (/^[0-6]$/.test(configured[i].trim())) return true
        return false
    }
    readonly property bool validHours: endTotalMinutes !== startTotalMinutes
        && (!overnightWindow || (w.allowOvernight && windowMinutes <= w.maxOvernightSpan * 60))
    readonly property string invalidReason: {
        if (endTotalMinutes === startTotalMinutes) return "Start and end must differ"
        if (overnightWindow && !allowOvernight) return "Enable overnight mode"
        if (overnightWindow && windowMinutes > maxOvernightSpan * 60)
            return "Overnight window exceeds 12 hours"
        return ""
    }
    // Longest overnight (end < start) window we treat as a real night shift; a
    // longer wrap is almost certainly swapped hours, so it stays invalid.
    readonly property int maxOvernightSpan: 12
    // Test seam: force a deterministic "now" (a Date) so the time math can be
    // exercised without the wall clock. null → live system clock.
    property var nowOverride: null
    function nowDate() { return nowOverride !== null ? nowOverride : new Date() }
    function activeOn(ref) {
        if (!ref || typeof ref.getDay !== "function") return true
        var configured = String(w.workDays).split(",")
        for (var i = 0; i < configured.length; i++)
            if (Number(configured[i].trim()) === ref.getDay()) return true
        return false
    }
    // Window endpoints containing (or, failing that, next after) `ref`.
    //   • Same-day windows (start < end) anchor both ends on ref's date.
    //   • Overnight windows (end ≤ start, within maxOvernightSpan) span midnight,
    //     so a single date-anchoring is wrong after midnight. We consider TWO
    //     candidate anchorings - one that started YESTERDAY and ends today, and
    //     one that starts today and ends tomorrow - and return whichever
    //     currently CONTAINS ref. So at 03:00 a 22→06 shift resolves to
    //     [yesterday 22:00, today 06:00] (in-window, ~62%, 3h left), while at
    //     23:00 it resolves to [today 22:00, tomorrow 06:00] (7h left).
    //     If neither contains ref, the today-anchored window is the next
    //     upcoming one and drives the "Starts in …" label.
    // Calendar construction (new Date(y,m,d,h,…)) keeps this DST-safe.
    function windowBounds(ref) {
        if (!w.validHours) return [ref, ref]
        var y = ref.getFullYear(), mo = ref.getMonth(), d = ref.getDate()
        if (!w.overnightWindow)                               // same-day window
            return [new Date(y, mo, d, startHour, startMinute, 0, 0),
                    new Date(y, mo, d, endHour,   endMinute, 0, 0)]
        var sPrev = new Date(y, mo, d - 1, startHour, startMinute, 0, 0)   // started yesterday
        var ePrev = new Date(y, mo, d,     endHour,   endMinute, 0, 0)   // ends today
        if (ref >= sPrev && ref < ePrev) return [sPrev, ePrev]
        return [new Date(y, mo, d,     startHour, startMinute, 0, 0),      // starts today
                new Date(y, mo, d + 1, endHour,   endMinute, 0, 0)]      // ends tomorrow
    }
    property real frac: {
        w.tick
        var n = nowDate()
        var wb = windowBounds(n)
        var s = wb[0], e = wb[1]
        if (e <= s) return 0
        // Overnight windows belong to the weekday on which they start.
        if (!w.activeOn(s)) return 0
        return Math.max(0, Math.min(1, (n - s) / (e - s)))
    }
    function fmtDur(secs) {
        return Math.floor(secs / 3600) + "h " + Math.floor((secs % 3600) / 60) + "m"
    }
    function fmtHour(h) { return w.fmtTime(h, 0) }
    function fmtTime(h, minute) {
        var hh = h === 24 ? "24" : (h < 10 ? "0" + h : "" + h)
        return hh + ":" + (minute < 10 ? "0" + minute : minute)
    }
    property string remaining: {
        w.tick
        if (!w.validHours) return w.invalidReason
        if (!w.hasActiveDays) return "No active weekdays"
        var n = nowDate()
        var wb = windowBounds(n)
        var s = wb[0], e = wb[1]
        if (!w.activeOn(s)) return "Off today"
        if (n < s) return "Starts in " + fmtDur((s - n) / 1000)  // before the workday
        var d = (e - n) / 1000
        if (d <= 0) return "Complete"
        return fmtDur(d)
    }
    readonly property string phase: {
        w.tick
        if (!w.validHours) return "invalid"
        if (!w.hasActiveDays) return "no-days"
        var n = nowDate()
        var wb = windowBounds(n)
        if (!w.activeOn(wb[0])) return "off"
        if (n < wb[0]) return "before"
        if (n >= wb[1]) return "complete"
        return "working"
    }
    readonly property string stateLabel: {
        if (phase === "invalid") return "Invalid schedule"
        if (phase === "no-days") return "Schedule paused"
        if (phase === "off") return "Off day"
        if (phase === "before") return "Starts later"
        if (phase === "complete") return "Complete"
        return "Working"
    }
    readonly property string scheduleRange: w.fmtTime(w.startHour, w.startMinute)
        + " to " + w.fmtTime(w.endHour, w.endMinute)
    readonly property string progressSummary: {
        if (phase === "working")
            return Math.round(w.frac * 100) + "% elapsed | " + w.elapsedStr
                + " elapsed | " + w.remaining + " remaining"
        if (phase === "before") return w.scheduleRange
        if (phase === "complete") return w.scheduleRange + " finished"
        if (phase === "off") return "Not scheduled for this start day"
        return w.remaining
    }
    status: w.stateLabel
    // Keep a 1-hour minimum span: whichever end the user moved yields, so the
    // work window can never invert (end ≤ start) and get stuck.
    function setHours(sh, eh) {
        var s = Math.max(0, Math.min(23, sh))
        var e = Math.max(1, Math.min(24, eh))
        if (s >= e && !w.allowOvernight) {
            if (sh !== w.startHour) s = e - 1
            else e = s + 1
        }
        if (store) store.patchSettings(instanceId, { "startHour": s, "endHour": e })
    }

    // ── Per-size layout (sizeClass injected by Dashboard) ────────────────────
    readonly property bool horiz: sizeClass === "wide"
    readonly property bool tallish: sizeClass === "tall" || sizeClass === "large"
    // Has this instance got room to spare? The overlay is a size CLASS ("full",
    // injected by Dashboard alongside expanded), not a mode - so it belongs here
    // rather than in a `w.expanded ?` branch repeated down the file. `large` is
    // unreachable for this type's declared sizes (1x2/1x3 are not offered); kept
    // so a forced class degrades sanely.
    // 1x1.5 landscape is classified wide, but has the same generous area as
    // its tall portrait projection. It earns the detail strip and ring too.
    readonly property bool roomy: tallish || sizeClass === "full"
                                  || (!expanded && width * height > 700000)
    // The ring style is honoured wherever a ring has room - the overlay (as
    // before) and tall/wide tiles. micro/baseline keep the quiet bar.
    // (`expanded ||` dropped: `roomy` covers sizeClass "full", so it was a
    // synonym for the class, not an extra condition.)
    readonly property bool useRing: progressStyle === "ring" && (roomy || horiz)
    // The remaining time lives INSIDE the ring in vertical ring layouts; wide
    // keeps it beside the ring (the ring centre carries the percent instead).
    readonly property bool timeInRing: useRing && !horiz
    // Elapsed time inside the current window (for the tall detail column).
    readonly property string elapsedStr: {
        w.tick
        var n = nowDate()
        var wb = windowBounds(n)
        if (wb[1] <= wb[0] || n < wb[0]) return "0h 0m"
        return fmtDur((Math.min(n, wb[1]) - wb[0]) / 1000)
    }

    // ── Sizes, derived from the BOX ─────────────────────────────────────────
    // The ring diameter. The `w.expanded ?` branch this used to lead with picked
    // a whole different FORMULA for the overlay (w*0.7, h*0.55, cap 320); the
    // overlay is just the roomiest class, so it now shares the general non-wide
    // TILE term unchanged - every already-shipped tile keeps its exact ring, and
    // the overlay is sized by the pane it is actually given instead of by a
    // formula that assumed a 2560x720 screen:
    //   overlay 941x456 -> 191.5   ·  overlay 656x980 -> 300 (the two 38%-preview
    //   panes, which the old single formula rendered at 250.8 and 320).
    readonly property real ringPx: w.horiz
        ? Math.min(w.height * 0.58, w.width * 0.34, 280)
        : Math.min(w.width * 0.62, w.height * 0.42, 300)
    // The hero "time remaining". `expanded ? 80` ignored its pane and outranked
    // the box on every tile; the two-axis term below sizes both overlay panes
    // (63.8 landscape, 96 portrait) and lets a tall TILE stop rendering the
    // baseline's 52 in twice the room. micro keeps its own single-axis branch, so
    // its 64 is untouched; the 52 ceiling still binds on compact/wide, so every
    // already-shipped non-roomy tile is byte-identical.
    readonly property real remainingPx: w.micro
        ? Math.max(24, Math.min(w.width * 0.24, 64))
        : Math.max(24, Math.min(w.width * 0.18, w.height * 0.14, w.roomy ? 96 : 52))

    GridLayout {
        id: lay
        anchors.centerIn: parent
        width: parent.width * 0.88
        columns: w.horiz ? 2 : 1
        columnSpacing: theme.spacingLg
        rowSpacing: w.roomy ? 14 : 6     // air is room, not mode

        // Circular progress - the overlay's ring, now also earned by tall/wide
        // ring-style tiles.
        Item {
            id: ringBox
            visible: w.useRing
            Layout.alignment: Qt.AlignHCenter | Qt.AlignVCenter
            Layout.preferredWidth: Math.round(w.ringPx)
            Layout.preferredHeight: Layout.preferredWidth
            RingProgress {
                anchors.fill: parent
                value: w.frac
                progressColor: w.effAccent; progressColor2: w.effAccent
            }
            ColumnLayout {
                anchors.centerIn: parent; spacing: 2
                width: Math.max(24, ringBox.width * 0.72)
                Text { Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: w.timeInRing ? w.remaining : Math.round(w.frac * 100) + "%"
                    elide: Text.ElideRight; fontSizeMode: Text.HorizontalFit
                    minimumPixelSize: theme.fontMinimum
                    font.pixelSize: Math.min(ringBox.width * 0.22, 56)
                    font.bold: true; font.family: theme.fontMono; color: w.effAccent }
                Text { Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    visible: w.timeInRing && w.showPercent
                    text: Math.round(w.frac * 100) + "%"; font.pixelSize: 18; color: theme.textSecondary }
            }
        }

        // Text + bar column (everything that is not the ring).
        ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: w.roomy ? 14 : 6        // room, not mode - see rowSpacing above

            Text {
                visible: !w.timeInRing
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter; text: w.remaining
                elide: Text.ElideRight; fontSizeMode: Text.HorizontalFit
                font.pixelSize: Math.round(w.remainingPx)
                font.bold: true; font.family: theme.fontMono; color: w.effAccent
            }
            Rectangle {
                visible: !w.useRing
                // The bar's weight follows the room too (14 was "the overlay").
                Layout.fillWidth: true
                Layout.preferredHeight: w.micro ? 8 : w.roomy ? 14 : 10
                radius: height / 2; color: theme.cardBorder
                Rectangle { height: parent.height; radius: height / 2; width: parent.width * w.frac; color: w.effAccent
                    Behavior on width { NumberAnimation { duration: theme.motionValue; easing.type: Easing.OutCubic } } }
            }
            // The percent-of-window caption. micro is the one number + bar; a
            // tall TILE's detail column below spells the window out instead.
            //
            // The `&& !w.expanded` that used to sit in both this condition and the
            // detail column's was DEAD: `tallish` is "tall" or "large", and the
            // overlay is injected as "full", so `w.tallish` is already false
            // whenever `w.expanded` is true. It only ever did anything in a test
            // host that set expanded:true without the "full" that Dashboard always
            // pairs with it - i.e. it encoded the harness, not the product.
            Text {
                visible: w.showPercent && !w.timeInRing && !w.micro
                         && !(w.tallish && w.validHours)
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight; fontSizeMode: Text.HorizontalFit
                text: Math.round(w.frac * 100) + "% elapsed | "
                      + (w.phase === "working" ? w.remaining + " remaining" : w.stateLabel)
                      + " | " + w.scheduleRange
                // Tied to the hero it annotates rather than to the mode: the
                // caption only ever renders when the remaining time is shown
                // (!timeInRing), so it always has a hero to scale against. The
                // `expanded ? 15` it replaces gave both overlay panes one number;
                // 12 is still exactly what every non-roomy tile gets.
                font.pixelSize: Math.round(Math.max(theme.fontLabel,
                                                    Math.min(w.remainingPx * 0.34, 26)))
                color: theme.textPrimary
            }
            // Tall tiles spell the workday out - genuinely more information.
            ColumnLayout {
                visible: w.tallish && w.validHours
                Layout.fillWidth: true
                Layout.topMargin: theme.spacingSm
                spacing: theme.spacingXs
                Repeater {
                    model: [
                        { k: "Start", val: w.fmtTime(w.startHour, w.startMinute) },
                        { k: "End",   val: w.fmtTime(w.endHour, w.endMinute) },
                        { k: "Elapsed", val: w.elapsedStr },
                        { k: "Remaining", val: w.phase === "working" ? w.remaining : "0h 0m" },
                        { k: "Done",    val: Math.round(w.frac * 100) + "%" }
                    ]
                    delegate: RowLayout {
                        Layout.fillWidth: true
                        spacing: theme.spacingMd
                        // The Done row duplicates the caption's percent - it
                        // honours the same showPercent switch.
                        visible: modelData.k !== "Done" || w.showPercent
                        Text { text: modelData.k
                            font.pixelSize: Math.max(theme.fontLabel, Math.min(w.width * 0.045, 19))
                            font.weight: Font.Medium
                            color: theme.textPrimary }
                        Item { Layout.fillWidth: true }
                        Text { text: modelData.val
                            font.pixelSize: Math.max(theme.fontLabel, Math.min(w.width * 0.05, 21))
                            font.family: theme.fontMono; color: theme.textPrimary }
                    }
                }
            }
            RowLayout {
                Layout.alignment: Qt.AlignHCenter; visible: w.expanded; spacing: theme.spacingMd
                PillButton { label: "Start −"; onClicked: w.setHours(w.startHour - 1, w.endHour) }
                PillButton { label: "Start +"; onClicked: w.setHours(w.startHour + 1, w.endHour) }
                PillButton { label: "End −"; onClicked: w.setHours(w.startHour, w.endHour - 1) }
                PillButton { label: "End +"; onClicked: w.setHours(w.startHour, w.endHour + 1) }
            }
        }
    }
}
