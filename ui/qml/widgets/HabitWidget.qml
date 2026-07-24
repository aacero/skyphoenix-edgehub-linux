import QtQuick
import QtQuick.Layouts

// Habit streak - daily check-ins with a real streak count + heatmap.
// Persisted; streak is computed from consecutive days ending today/yesterday.
//
// Sizing (W1 wave 2b): the heatmap used to be expanded-only, on the reasoning
// (still in WidgetCatalog) that "a tile shows a streak number + one button,
// whatever room it is given". That outlived its truth: the 28-day grid is 7x4
// cells, which fits a 696x819 baseline tile with room to spare - so a tile with
// the space now earns the history rather than showing a lone number in a big box.
//   • 0.5x0.5 (micro) - headerless: the streak number + Check in. The heatmap is
//                       genuinely too small to read at 348x409, so it stays off.
//   • 1x1 (baseline)  - streak + the 28-day heatmap + Check in.
//   • wide            - the streak/button column BESIDE the heatmap.
//   • tall            - streak, heatmap, button stacked; the map transposes to
//                       4x7 so it fits the box instead of sitting as a squat
//                       block in a column of air (see heatCols).
//   • full (overlay)  - streak + best + heatmap + button, sized by the pane it is
//                       actually given (see streakPx). It is NOT a full screen:
//                       Dashboard hosts it in a live-preview pane beside the
//                       config form - ~941x456 in landscape, ~656x980 stacked in
//                       portrait - so "full" is a class like any other and reads
//                       its own box rather than a set of literals.
// The check-in button is a PillButton (theme.touchSecondary) at every size - it is
// the whole interaction, so it is never shrunk to make a layout fit.
//
// Sizing (W1 wave 2c): 1x1.5 - a half screen, and NOT the baseline stretched. It
// projects to two genuinely different boxes, and gets a different card in each:
//   • portrait 696x1229 (tall) - the 4x7 map above the streak, the record and the
//                                button. Cells reach ~86px vs the baseline's 34.
//   • landscape 1269x612 (wide) - the 7x4 map BESIDE the streak/record/button
//                                 column.
// What it earns over 1x1 is CONTENT, not scale: the best-ever record line, which
// was `visible: w.expanded` and so appeared in the overlay while a half-screen
// tile with twice the baseline's room went without it (see showBest).
// NOT 1x2/1x3: the stored history is pruned to 28 days, so past a half screen
// there is nothing further to show and the map would only inflate.
WidgetChrome {
    id: w
    property var metrics: ({})
    property bool expanded: false
    property bool active: true
    property var store: null
    property string instanceId: ""
    property int tick: 0

    title: w.name.length ? w.name : "Habit"; iconName: "habit"; accentColor: theme.catProductivity
    showHeader: !micro

    readonly property var cfg: {
        var _ = store ? store.revision : 0
        return (store && instanceId) ? JSON.parse(JSON.stringify(store.settingsFor(instanceId))) : ({})
    }
    readonly property var checkins: cfg.checkins || []
    // Optional habit name; empty → default "Habit" header.
    readonly property string name: cfg.name !== undefined ? cfg.name : ""
    readonly property string cadence: cfg.cadence || "daily"
    readonly property string activeDays: cfg.activeDays !== undefined ? cfg.activeDays : "1,2,3,4,5"
    readonly property bool paused: cfg.paused === true
    readonly property bool showStreak: cfg.showStreak !== undefined ? cfg.showStreak : true
    readonly property bool celebrate: cfg.celebrate !== undefined ? cfg.celebrate : true
    function key(d) { return Qt.formatDate(d, "yyyy-MM-dd") }
    // DST-safe previous-calendar-day step (S6): anchor at local noon and use
    // setDate() so a fixed-24h jump can never skip/duplicate a date across a
    // spring-forward / fall-back boundary near midnight.
    function prevDay(d) { var n = new Date(d); n.setHours(12, 0, 0, 0); n.setDate(n.getDate() - 1); return n }
    function scheduled(d) {
        var day = d.getDay()
        if (cadence === "weekdays") return day >= 1 && day <= 5
        if (cadence === "weekends") return day === 0 || day === 6
        if (cadence === "custom") {
            var days = activeDays.split(",").map(function (v) {
                return String(v).trim()
            }).filter(function (v, index, all) {
                return /^[0-6]$/.test(v) && all.indexOf(v) === index
            }).map(function (v) { return Number(v) })
            return days.indexOf(day) >= 0
        }
        return true
    }
    function prevScheduledDay(d) {
        var n = prevDay(d)
        for (var i = 0; i < 7 && !scheduled(n); i++) n = prevDay(n)
        return n
    }
    // Parse a "yyyy-MM-dd" key into a local-noon Date (mirrors CountdownWidget's
    // component-wise construction - never `new Date(str)`, which is UTC).
    function parseKey(k) { var p = String(k).split("-"); return new Date(+p[0], (+p[1]) - 1, +p[2], 12, 0, 0, 0) }
    // Calendar day immediately before a key, DST-safe.
    function prevDayKey(k) { return key(prevDay(parseKey(k))) }
    property string todayKey: (w.tick, key(new Date()))
    property bool doneToday: checkins.indexOf(todayKey) >= 0
    readonly property bool scheduledToday: scheduled(new Date())

    // Streak from an arbitrary check-in list - used ONLY to (a) derive an initial
    // streak from a legacy config that predates the stored number, and (b)
    // recompute after un-checking today. The live streak itself is a persisted
    // NUMBER (see `streak` / `streakState`), so it is NOT capped by the pruned
    // heatmap window the way `streakOf(checkins)` alone would be.
    function streakOf(arr) {
        if (!arr.length) return 0
        var set = {}
        for (var i = 0; i < arr.length; i++) set[arr[i]] = true
        var d = new Date(); d.setHours(12, 0, 0, 0)
        var n = 0
        if (!scheduled(d) || !set[key(d)]) d = prevScheduledDay(d)
        while (set[key(d)]) { n++; d = prevScheduledDay(d) }
        return n
    }
    // The maintained streak state, from storage when present, else derived once
    // from the (possibly pruned) check-in array for BACKWARD COMPAT with old
    // configs that only ever stored `checkins`. Returns { n, last }.
    function streakState() {
        if (cfg.streak !== undefined && cfg.lastCheckinDay !== undefined)
            return { n: cfg.streak, last: cfg.lastCheckinDay }
        var arr = checkins
        if (!arr.length) return { n: 0, last: "" }
        var sorted = arr.slice().sort()
        return { n: streakOf(arr), last: sorted[sorted.length - 1] }
    }
    // Live current streak: the stored number, valid while its last check-in is
    // today or yesterday (grace day); a wider gap means the run has lapsed → 0.
    // Falls back to array-derivation for legacy configs (no stored number).
    property int streak: {
        w.tick
        if (cfg.streak !== undefined && cfg.lastCheckinDay !== undefined) {
            var last = cfg.lastCheckinDay
            if (last === todayKey) return cfg.streak
            var due = key(prevScheduledDay(parseKey(todayKey)))
            if (last === due) return cfg.streak                    // next scheduled day grace
            return 0                                               // lapsed
        }
        return streakOf(checkins)                                  // legacy derive
    }
    // Best streak ever - persisted, but never less than the current run.
    readonly property int bestStreak: Math.max(cfg.bestStreak || 0, streak)
    // The one thing here that IS legitimately keyed off the mode rather than the
    // room: `status` is chrome-header content, and the overlay hosts this widget
    // with showHeader false and a header of its own. It is not a size.
    status: w.expanded ? "" : (w.paused ? "Paused"
        : (!w.scheduledToday ? "Rest day" : (w.doneToday ? "Checked in" : "Ready")))

    // ── Per-size layout (sizeClass injected by Dashboard) ────────────────────
    readonly property bool horiz: sizeClass === "wide"

    // ── 1x1.5 (W1 wave 2c) ───────────────────────────────────────────────────
    // Dashboard injects sizeClass, never the size NAME, so "does this instance
    // have half-screen room?" has to be answered from the room itself. Among the
    // sizes this widget declares, 1x1.5 is the only one that is BOTH off-square
    // and full-short-axis:
    //   0.5x1  -> tall  348x819  / wide  846x306   (short side <= 423)
    //   1x0.5  -> wide  696x409  / tall  423x612   (short side <= 423)
    //   1x1.5  -> tall  696x1229 / wide 1269x612   (short side >= 612)
    // so the same 480 threshold WidgetChrome uses to tell the half-cell from the
    // baseline separates them here too, with no size-name special case. `large`
    // and `full` are roomier still; this widget declares neither as a tile, but
    // they must not read as cramped if it ever does.
    readonly property bool roomy: sizeClass === "large" || sizeClass === "full"
        || ((sizeClass === "tall" || sizeClass === "wide")
            && Math.min(width, height) >= 480)

    // The heatmap's GRID FOLLOWS THE BOX. 28 days is either 7x4 or 4x7, and both
    // keep the structure that makes the map readable - cells 7 apart share a
    // weekday - they just swap which axis carries the week:
    //   7 cols -> a ROW is a week, a COLUMN is a weekday   (square / wide boxes)
    //   4 cols -> a COLUMN is a week, a ROW is a weekday   (tall boxes)
    // Handing a tall box the 7x4 map is precisely the "one layout stretched"
    // failure: 1x1.5 portrait is 696x1229 (aspect 0.57) and a 4x7 grid is aspect
    // 0.57, so the transposed map is the one that genuinely fits the box. This is
    // keyed off the SHAPE, not off 1x1.5, so 0.5x1 portrait and 1x0.5 landscape
    // (also tall) get the arrangement that suits them for the same reason.
    readonly property bool tallBox: sizeClass === "tall"
    readonly property int heatCols: w.tallBox ? 4 : 7
    readonly property int heatRows: w.tallBox ? 7 : 4
    function dateForIndex(index) {
        var d = new Date()
        d.setHours(12, 0, 0, 0)
        d.setDate(d.getDate() - w.daysAgoFor(index))
        return d
    }

    // The heatmap is 28 cells; a micro tile cannot show them legibly. Room, not
    // mode: the `|| w.expanded` this used to lead with was already dead - micro
    // requires sizeClass "compact" and the overlay is injected as "full" - but it
    // said the decision was partly the overlay's, which is the habit being removed.
    readonly property bool showHeatmap: !w.micro

    // The best-ever line is CONTENT that the ROOM earns, not a mode. It used to be
    // `visible: w.expanded`, which is the exact size/mode conflation WidgetChrome
    // warns about: the overlay showed the record while a half-screen tile with far
    // more room than the baseline did not.
    // (`|| w.expanded` dropped: `roomy` already includes sizeClass "full", which
    // is what the overlay is injected as, so the mode term was dead weight.)
    readonly property bool showBest: w.roomy && w.bestStreak > 0

    // The streak number is sized by its BOX at every class, the overlay included.
    // It used to open with `w.expanded ? 40`, and that literal was frozen twice
    // over: it ignored the box it was actually in, and it never noticed when W5
    // shrank the overlay's live-preview pane to 38% of the screen in landscape -
    // the pane is ~941x456 there and ~656x980 stacked in portrait, not a full
    // 2560x720. Fed through the general term those boxes ask for 46px and 66px
    // respectively; 40 was neither. Every already-shipped tile class is untouched
    // (the branch only ever fired for the overlay).
    readonly property real streakPx: w.micro
        ? Math.max(18, Math.min(width * 0.22, height * 0.20, 64))
        : Math.max(theme.fontMinimum, Math.min((w.horiz ? width * 0.5 : width) * 0.10,
                                height * 0.10, w.roomy ? 72 : 44))

    // Cell size follows the box AND the grid shape it just chose. The old terms
    // baked the 7x4 shape into their /9 and *0.06 divisors, so a 7-row grid sized
    // with a 4-row budget would run straight off the bottom.
    //   tall : 4 cols span 4.54c, so width/5 fills ~91% of the width; 7 rows span
    //          8.08c, so height*0.07 gives the map ~57% of the height and leaves
    //          the header, streak, record and button theirs (~250px at 1x1.5).
    //          Tuned against renders, not arithmetic: at 0.085 the cells came out
    //          bigger than the streak number itself and inverted the hierarchy.
    //   else : unchanged, so every already-shipped size keeps its exact cell size.
    // The cap is a guard rail rather than the active term at 1x1.5 - the axis
    // terms bind first there (86 vs 120 tall, 70.5 vs 120 wide) - and it is what
    // holds the baseline tile at its current 34.
    readonly property real heatCellCap: w.roomy ? 120 : 34
    // Same story as streakPx: the leading `w.expanded ? 24` is gone, so the map
    // in the overlay is sized by the pane it is really in (27px in the 941x456
    // landscape pane, 59px in the 656x980 portrait one) instead of by a literal
    // that was chosen when that pane was a different shape. Tile classes unchanged.
    readonly property real heatCell: w.tallBox
        ? Math.max(8, Math.min(width / 5, height * 0.07, w.heatCellCap))
        : Math.max(8, Math.min((w.horiz ? width * 0.5 : width) / 9,
                               height * (w.horiz ? 0.14 : 0.06), w.heatCellCap))

    // Days-ago for a row-major cell index under the CURRENT grid shape; index 27
    // is always today. With 7 columns the natural row-major order already runs a
    // week per row. With 4 columns the week has to run DOWN each column instead -
    // left as row-major, every row would be 4 consecutive days and the weekday
    // alignment (the entire point of a habit heatmap) would be lost.
    function daysAgoFor(index) {
        if (w.heatCols === 7) return 27 - index
        var r = Math.floor(index / w.heatCols)
        var c = index % w.heatCols
        return (w.heatCols - 1 - c) * 7 + (w.heatRows - 1 - r)
    }

    readonly property var milestones: [7, 14, 30, 60, 100, 200, 365]
    // Keep this as one stable QObject. Returning a new JS object from a property
    // binding here crashed Qt 6.11's QV4 property cache when a live card crossed
    // into the roomy 1x1.5 layout and three bindings read its members at once.
    // Primitive QObject properties also give the bindings narrower dependencies.
    QtObject {
        id: recentStatsState
        readonly property int total: {
            w.tick
            var count = 0
            var d = new Date(); d.setHours(12, 0, 0, 0)
            for (var i = 0; i < 28; i++) {
                if (w.scheduled(d)) count++
                d = w.prevDay(d)
            }
            return count
        }
        readonly property int done: {
            w.tick
            var count = 0
            var d = new Date(); d.setHours(12, 0, 0, 0)
            for (var i = 0; i < 28; i++) {
                if (w.scheduled(d) && w.checkins.indexOf(w.key(d)) >= 0) count++
                d = w.prevDay(d)
            }
            return count
        }
        readonly property int percent: total ? Math.round(done * 100 / total) : 0
    }
    readonly property var recentStats: recentStatsState
    readonly property string heatmapRange: {
        w.tick
        return Qt.formatDate(w.dateForIndex(0), "d MMM") + " to "
                + Qt.formatDate(w.dateForIndex(27), "d MMM")
    }
    readonly property string heatmapSummary: "Last 28 days, " + w.heatmapRange
        + ": " + w.recentStats.done + " of " + w.recentStats.total
        + " scheduled check-ins completed, " + w.recentStats.percent + " percent."
    readonly property string todayFeedback: {
        w.tick
        var date = Qt.formatDate(new Date(), "ddd d MMM")
        if (w.paused) return date + ": Habit paused"
        if (!w.scheduledToday) return date + ": Rest day"
        return date + (w.doneToday ? ": Checked in" : ": Ready to check in")
    }
    readonly property int nextMilestone: {
        for (var i = 0; i < milestones.length; i++)
            if (milestones[i] > streak) return milestones[i]
        return streak + 30
    }
    function milestoneMsg(n) {
        if (milestones.indexOf(n) >= 0) return n + "-day milestone!"
        return n + (n === 1 ? " day complete!" : " days complete!")
    }

    // Only the most recent HEATMAP_DAYS check-ins are ever shown, so the stored
    // `checkins` array is pruned to that window (prevents unbounded growth of the
    // config over years of use). The STREAK is stored independently as a number,
    // so it is not capped by this pruning - a 40-day run reports 40, not 28.
    readonly property int heatmapDays: 28
    function toggleToday() {
        if (!store || paused || !scheduledToday) return
        var a = checkins.slice()
        var i = a.indexOf(todayKey)
        var checking = i < 0
        var prevBest = w.bestStreak
        if (checking) {
            a.push(todayKey)
            var st = streakState()
            var ns
            if (st.last === todayKey) ns = st.n                       // idempotent: already counted today
            else if (st.last === key(prevScheduledDay(parseKey(todayKey)))) ns = st.n + 1
            else ns = 1                                               // gap or first-ever → fresh streak
            var newBest = Math.max(prevBest, ns)
            // Announce a milestone only when it's a genuinely NEW best; a plain
            // re-check of an already-reached day shows the flame message instead.
            if (celebrate) {
                var message = ns > prevBest ? milestoneMsg(ns)
                    : ns + (ns === 1 ? " day complete!" : " days complete!")
                celebrateNow(message)
            }
            // Prune the heatmap array (keys sort chronologically as strings), but
            // persist the full streak NUMBER + the last check-in day.
            a.sort()
            if (a.length > heatmapDays) a = a.slice(a.length - heatmapDays)
            store.patchSettings(instanceId, { checkins: a, streak: ns,
                                lastCheckinDay: todayKey, bestStreak: newBest })
        } else {
            // Un-check today from the maintained streak NUMBER. Recomputing from
            // the pruned 28-day heatmap collapses a 100-day run to 27, even
            // though only one check-in was removed.
            var prior = streakState()
            a.splice(i, 1)
            var sorted = a.slice().sort()
            var recomputed
            var newLast
            if (prior.last === todayKey) {
                recomputed = Math.max(0, prior.n - 1)
                newLast = recomputed > 0
                    ? key(prevScheduledDay(parseKey(todayKey))) : ""
            } else {
                // Defensive inconsistent state: today's heatmap key existed but
                // the maintained streak already ended earlier. Removing the key
                // must not change that stored run.
                recomputed = prior.n
                newLast = prior.last || (sorted.length ? sorted[sorted.length - 1] : "")
            }
            a.sort()
            if (a.length > heatmapDays) a = a.slice(a.length - heatmapDays)
            store.patchSettings(instanceId, { checkins: a, streak: recomputed,
                                lastCheckinDay: newLast, bestStreak: prevBest })
        }
    }

    // Celebration pop (mirrors FocusWidget) - the check-in dopamine hit.
    //
    // The banner spans the whole CARD, so the card is what sizes it. `expanded ?
    // 34 : 17` asked the wrong question and got both answers wrong: a 696x819
    // baseline tile has more room than the overlay's live-preview pane and still
    // popped at 17, while the overlay kept its 34 after W5 shrank that pane to
    // 38% of the screen. Both axes bind (the text wraps to at most 2 lines, so a
    // wide-but-short pane must not overreach), and 34 stays the designed ceiling.
    readonly property real celebratePx: Math.max(theme.fontMinimum, Math.min(width * 0.055,
                                                              height * 0.075, 34))
    property string celebrateMsg: ""
    function celebrateNow(msg) { celebrateMsg = msg; celebrateAnim.restart(); flash.restart() }
    Rectangle {
        anchors.fill: parent; radius: theme.radiusLg; color: w.effAccent; opacity: 0; z: 5
        SequentialAnimation on opacity {
            id: flash; running: false
            NumberAnimation { to: theme.effectiveReduceMotion ? 0 : 0.32; duration: theme.motionFast }
            NumberAnimation { to: 0.0; duration: theme.motionSlow }
        }
    }
    Text {
        id: celebrateLabel; anchors.centerIn: parent; z: 20
        width: parent.width - 2 * theme.spacingLg
        text: w.celebrateMsg; opacity: 0
        font.pixelSize: Math.round(w.celebratePx); font.bold: true; font.family: theme.fontDisplay
        color: w.effAccent; horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
        SequentialAnimation {
            id: celebrateAnim; running: false
            PropertyAction { target: celebrateLabel; property: "scale"; value: theme.effectiveReduceMotion ? 1 : 0.6 }
            ParallelAnimation {
                NumberAnimation { target: celebrateLabel; property: "opacity"; from: 0; to: 1; duration: theme.motionAdd }
                NumberAnimation { target: celebrateLabel; property: "scale"; to: theme.effectiveReduceMotion ? 1 : 1.12
                    duration: theme.motionPage; easing.type: theme.effectiveReduceMotion ? Easing.Linear : Easing.OutBack }
            }
            PauseAnimation { duration: 900 }
            NumberAnimation { target: celebrateLabel; property: "opacity"; to: 0; duration: theme.motionSlow }
        }
    }

    // `columns` flips for a wide box; that only RESHAPES - no delegate is rebuilt
    // (the heatmap's model is the literal 28, so its cells live for the widget's
    // whole life and a check-in only moves their bound values).
    GridLayout {
        anchors.centerIn: parent
        width: parent.width
        columns: w.horiz ? 2 : 1
        // Air is room, not mode. 14 was "the overlay" and 6 "not the overlay";
        // what actually earns the wider gap is having the space for it, which is
        // the same `roomy` predicate the cell cap and the record line already use
        // - so a 1x1.5 tile, with cells up to 86px and a ~70px streak number, now
        // gets the breathing room its own contents ask for instead of the
        // baseline third's tighter 6. Compact/micro tiles are unchanged.
        rowSpacing: w.roomy ? 14 : 6
        columnSpacing: theme.spacingLg

        // The date range and state legend travel with the map in every non-micro
        // layout. Each cell also carries a visible state mark, so color is never
        // the only way to read progress.
        ColumnLayout {
            Layout.alignment: Qt.AlignCenter
            visible: w.showHeatmap
            spacing: 7

            Text {
                objectName: "habitHeatmapRange"
                Layout.alignment: Qt.AlignHCenter
                text: "LAST 28 DAYS  ·  " + w.heatmapRange
                color: theme.textPrimary
                opacity: 0.82
                font.pixelSize: Math.max(theme.fontMinimum, 18)
                font.bold: true
                font.letterSpacing: 0.8
            }
            GridLayout {
                objectName: "habitHeatmap"
                Layout.alignment: Qt.AlignCenter
                columns: w.heatCols
                rowSpacing: Math.max(2, w.heatCell * 0.18)
                columnSpacing: Math.max(2, w.heatCell * 0.18)
                Accessible.role: Accessible.StaticText
                Accessible.name: w.heatmapSummary
                Repeater {
                    model: 28
                    delegate: Rectangle {
                        required property int index
                        objectName: "habitDay-" + index
                        Layout.preferredWidth: Math.round(w.heatCell)
                        Layout.preferredHeight: Math.round(w.heatCell)
                        radius: Math.max(2, Math.round(w.heatCell) * 0.17)
                        property date dayDate: w.dateForIndex(index)
                        property string dk: w.key(dayDate)
                        property bool on: w.checkins.indexOf(dk) >= 0
                        property bool isScheduled: w.scheduled(dayDate)
                        property string stateLabel: on ? "completed"
                            : (isScheduled ? "scheduled, not completed" : "rest day")
                        color: on ? w.effAccent : theme.cardBorder
                        opacity: on ? 1 : (isScheduled ? 0.58 : 0.28)
                        border.width: dk === w.todayKey ? 2 : 1
                        border.color: dk === w.todayKey ? theme.textPrimary : theme.cardBorder
                        Accessible.role: Accessible.StaticText
                        Accessible.name: Qt.formatDate(dayDate, "dddd d MMMM")
                                         + ", " + stateLabel
                        Text {
                            anchors.centerIn: parent
                            text: parent.on ? "✓" : (parent.isScheduled ? "○" : "−")
                            color: parent.on ? theme.backgroundColor : theme.textSecondary
                            font.pixelSize: Math.max(10, Math.round(parent.width * 0.54))
                            font.bold: parent.on
                        }
                    }
                }
            }
            Text {
                objectName: "habitHeatmapLegend"
                Layout.alignment: Qt.AlignHCenter
                text: "✓ Done   ○ Scheduled   − Rest"
                color: theme.textPrimary
                opacity: 0.82
                font.pixelSize: Math.max(theme.fontMinimum, 18)
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignCenter
            // A roomy landscape tile places this column beside a 7x4 heatmap.
            // Its available height is the short axis, so use slightly tighter
            // vertical rhythm than the portrait stack. The previous 14px gaps
            // plus a 76px insight panel pushed the check-in pill 26px below the
            // 1x1.5 landscape card.
            spacing: w.roomy ? (w.horiz ? 12 : 14) : 4

            Text {
                visible: w.showStreak
                Layout.alignment: Qt.AlignHCenter; Layout.fillWidth: true
                text: w.streak + (w.streak === 1 ? " day" : " days")
                font.pixelSize: Math.round(w.streakPx); font.bold: true; color: w.effAccent
                horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
            }
            // Best streak - a record to beat. Shown wherever the ROOM earns it
            // (see showBest), which is what lets 1x1.5 carry something the
            // baseline third does not, rather than the same tile stretched.
            Text {
                Layout.alignment: Qt.AlignHCenter; Layout.fillWidth: true
                visible: w.showStreak && w.showBest
                text: "Best: " + w.bestStreak + (w.bestStreak === 1 ? " day" : " days")
                      + (w.streak >= w.bestStreak && w.streak > 0 ? "  ·  personal best!" : "")
                // Tied to the streak readout rather than left at the caption
                // token: at 1x1.5 the number is ~70px and a 13px record line
                // beside it reads as a rendering artefact rather than a stat.
                // The `w.expanded ? 14` that used to precede this is gone and
                // costs nothing: the overlay's landscape pane drives streakPx to
                // ~46, and 46 * 0.3 rounds to exactly the 14 it hardcoded.
                font.pixelSize: Math.round(Math.max(theme.fontCaption, w.streakPx * 0.3))
                color: theme.textSecondary
                horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
            }
            Rectangle {
                objectName: "habitInsightPanel"
                visible: w.roomy
                Layout.fillWidth: true
                Layout.preferredWidth: w.horiz ? Math.min(520, w.width * 0.43)
                                               : Math.min(620, w.width * 0.88)
                // Preserve the full 76px treatment in the portrait stack. In a
                // wide card, 56px still fits both label and value rows while
                // keeping the primary action fully inside the touch surface.
                Layout.preferredHeight: w.horiz ? 56 : 76
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
                        Text { text: "28 DAYS"; color: theme.textTertiary; font.pixelSize: theme.fontMinimum
                            font.bold: true; font.letterSpacing: 1.1 }
                        Text { text: w.recentStats.done + " / " + w.recentStats.total
                            color: theme.textPrimary; font.pixelSize: theme.fontLabel; font.bold: true }
                    }
                    Rectangle { Layout.preferredWidth: 1; Layout.fillHeight: true
                        Layout.topMargin: 14; Layout.bottomMargin: 14; color: theme.cardBorder }
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 2
                        Text { text: "CONSISTENCY"; color: theme.textTertiary; font.pixelSize: theme.fontMinimum
                            font.bold: true; font.letterSpacing: 1.1 }
                        Text { text: w.recentStats.percent + "%"; color: w.effAccent
                            font.pixelSize: theme.fontLabel; font.bold: true }
                    }
                    Rectangle { Layout.preferredWidth: 1; Layout.fillHeight: true
                        Layout.topMargin: 14; Layout.bottomMargin: 14; color: theme.cardBorder }
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 2
                        Text { text: "NEXT GOAL"; color: theme.textTertiary; font.pixelSize: theme.fontMinimum
                            font.bold: true; font.letterSpacing: 1.1 }
                        Text { text: Math.max(0, w.nextMilestone - w.streak) + " days"
                            color: theme.textPrimary; font.pixelSize: theme.fontLabel; font.bold: true }
                    }
                }
            }
            Text {
                objectName: "habitTodayFeedback"
                visible: !w.micro
                Layout.fillWidth: true
                text: w.todayFeedback
                color: w.doneToday ? w.effAccent : theme.textSecondary
                font.pixelSize: Math.max(theme.fontMinimum, 18)
                font.bold: w.doneToday
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                Accessible.role: Accessible.StaticText
                Accessible.name: w.todayFeedback
            }
            // Check in from every size - a PillButton is theme.touchSecondary (60),
            // above the 52 minimum, and this is the widget's whole interaction.
            PillButton {
                Layout.alignment: Qt.AlignHCenter
                // The long form is spelled out wherever there is room for it, not
                // only in the overlay - the pill is content-sized (see PillButton),
                // so this is a legibility choice the box makes, not the mode.
                label: w.paused ? "Paused" : (!w.scheduledToday ? "Rest day"
                    : (w.doneToday ? (w.roomy ? "Done today ✓" : "✓ today") : "Check in"))
                glyph: ""
                enabled: !w.paused && w.scheduledToday
                primary: enabled && !w.doneToday; tint: w.effAccent
                onClicked: w.toggleToday()
            }
        }
    }
}
