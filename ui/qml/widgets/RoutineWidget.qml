import QtQuick
import QtQuick.Layouts

// ─────────────────────────────────────────────────────────────────────────
// Routine - a daily checklist that resets each day, with nothing to lose.
//
// THE NO-SHAMING RULE IS STRUCTURAL, NOT COSMETIC. It is not "we chose calm
// colours"; it is that the widget stores NO CROSS-DAY STATE AT ALL. There is no
// streak, no completion history, no "you did 3/5 yesterday" - so there is
// literally nothing for a bad day to break, and no number a missed day can make
// go down. That is why this is a separate widget from `habit` (which is a streak,
// on purpose, for people who want one) rather than a flag on it: you cannot bolt
// "no consequences" onto a design whose consequence IS the feature.
//
// Consequently: an unchecked step is `textPrimary` (a normal thing you might do),
// never red, never a warning. A new day silently unchecks everything. Nothing
// blinks or animates on a timer - the only clinically-grounded number in the
// whole a11y literature here is the Epilepsy Foundation's <2 Hz flash advice, and
// the cheapest way to honour it is to have no timed animation whatsoever.
//
// Persistence: `day` + `done` (step keys). Reading ignores a `day` that isn't
// today, so the reset is a read-time decision - no timer, no write at midnight,
// and it cannot half-apply if the device was asleep.
//
// Sizing (W1 wave 2b): this is a LIST, so a bigger box earns MORE ROWS, not
// bigger ones. Every row is a full touch target at every size - the tile rows
// used to be 22px tall WITH a MouseArea on them, which is a 22px hit area for a
// tick, less than half theme.touchTertiary (52). A row is now touchTertiary
// everywhere and the box simply shows as many as it fits; the footer count says
// where you are, and tapping the tile opens the rest. Shrinking the target to fit
// more rows would trade the one interaction this widget has for density.
//   • 0.5x1 / 1x0.5 / 1x1 / 1x1.5 / 1x2 - the same list, more rows per size.
//   • wide  - the list BESIDE its summary (progress + count) rather than under
//             it; a 696x409 box stacked into three bands is all chrome.
//   • tall / large - the summary bar is earned above the list.
// (No 0.5x0.5 is declared, so `micro` is never true here - see WidgetCatalog.)
// ─────────────────────────────────────────────────────────────────────────
WidgetChrome {
    id: w
    property var metrics: ({})
    property bool expanded: false
    property bool active: true
    property var store: null
    property string instanceId: ""
    property int tick: 0

    title: "Routine"; iconName: "routine"; accentColor: theme.catProductivity

    readonly property var cfg: {
        var _ = store ? store.revision : 0
        return (store && instanceId) ? JSON.parse(JSON.stringify(store.settingsFor(instanceId))) : ({})
    }
    // One step per line. Same reasoning as Meds' schedule: a small adjustment
    // surface beats a structured editor.
    readonly property string steps: cfg.steps !== undefined ? cfg.steps : ""
    readonly property var routineItems:
        Array.isArray(cfg.routineItems) ? cfg.routineItems : []
    readonly property string activeDays: cfg.activeDays !== undefined ? cfg.activeDays : "0,1,2,3,4,5,6"
    property int dayOfWeekOverride: -1

    function todayKey() { return Qt.formatDate(new Date(), "yyyy-MM-dd") }
    property string dayKey: (w.tick, todayKey())
    // Today's ticks only. A stored day that is not today reads as empty - that IS
    // the daily reset.
    readonly property var doneToday: (cfg.day === dayKey && cfg.done) ? cfg.done : []

    readonly property var stepItems: {
        var out = []
        if (cfg.routineFormat === "structured" || w.routineItems.length) {
            for (var r = 0; r < w.routineItems.length; r++) {
                var item = w.routineItems[r] || ({})
                var label = String(item.text || "").trim()
                if (!label.length) continue
                out.push({
                    text: label,
                    key: String(item.id || ("routine-" + r))
                })
            }
            return out
        }
        var lines = String(w.steps).split("\n")
        var occurrences = ({})
        for (var i = 0; i < lines.length; i++) {
            var t = lines[i].trim()
            if (!t.length) continue
            var occurrence = occurrences[t] || 0
            occurrences[t] = occurrence + 1
            out.push({
                text: t,
                key: occurrence === 0 ? t : t + "\u001f" + (occurrence + 1)
            })
        }
        return out
    }
    readonly property var stepList: {
        var out = []
        for (var i = 0; i < w.stepItems.length; i++)
            out.push(w.stepItems[i].text)
        return out
    }

    function currentWeekday() {
        return w.dayOfWeekOverride >= 0 ? w.dayOfWeekOverride : new Date().getDay()
    }
    function isActiveToday() {
        var configured = String(w.activeDays).split(",")
        for (var i = 0; i < configured.length; i++)
            if (Number(configured[i].trim()) === w.currentWeekday()) return true
        return false
    }
    function keyOf(step) { return typeof step === "object" ? step.key : String(step) }

    function isDone(step) { return w.doneToday.indexOf(w.keyOf(step)) >= 0 }
    readonly property int doneCount: {
        var n = 0
        for (var i = 0; i < w.stepItems.length; i++) if (w.isDone(w.stepItems[i])) n++
        return n
    }
    readonly property bool allDone: w.isActiveToday() && w.stepItems.length > 0
                                    && w.doneCount === w.stepItems.length
    status: w.expanded || !w.stepList.length ? "" : w.doneCount + "/" + w.stepList.length

    // ── Per-size layout (sizeClass injected by Dashboard) ────────────────────
    readonly property bool horiz: sizeClass === "wide"
                                  || ((sizeClass === "large" || sizeClass === "full")
                                      && width > height * 1.25)
    // The summary (a neutral fill bar + the count) is real content, so every size
    // with room shows it rather than keeping it behind the overlay. Only a micro
    // tile falls back to the bare footer count - and routine declares no 0.5x0.5,
    // so that path exists for a standalone host (tests, the Manager preview).
    readonly property bool showSummary: !w.micro
    // Every row is a real touch target. This is NOT scaled down for small tiles:
    // a tick is the only thing you do here.
    readonly property real rowH: Math.max(theme.touchTertiary, 60)
    readonly property real rowFont: w.expanded ? Math.max(theme.fontLabel, 17)
        : Math.max(17,
                   Math.min((w.horiz ? width * 0.5 : width) * 0.038, 21))
    readonly property real boxSize: w.expanded ? 28 : Math.max(20, Math.min(w.rowH * 0.5, 28))

    function toggle(step) {
        if (!store || !w.isActiveToday()) return
        var key = w.keyOf(step)
        var a = w.doneToday.slice()
        var i = a.indexOf(key)
        if (i >= 0) a.splice(i, 1)
        else a.push(key)
        store.patchSettings(instanceId, { day: w.dayKey, done: a })
    }

    // ── Empty state ─────────────────────────────────────────────────────────
    Text {
        anchors.centerIn: parent
        width: parent.width - 2 * theme.spacingSm
        visible: w.stepList.length === 0
        text: w.expanded ? "Add and arrange routine steps in settings."
                         : "Add steps\nin settings"
        color: theme.textPrimary
        font.pixelSize: w.expanded ? Math.max(theme.fontLabel, 18) : 17
        font.bold: true
        horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
    }

    // `columns` flips for a wide box: the summary sits BESIDE the list instead of
    // stacked above it. Only a reshape - the ListView is not rebuilt.
    GridLayout {
        anchors.fill: parent
        visible: w.stepList.length > 0
        columns: w.horiz ? 2 : 1
        rowSpacing: theme.spacingSm
        columnSpacing: theme.spacingLg

        // ── Summary: progress, stated as a fact and nothing more. No
        // "x% - keep going!", no target, no comparison to yesterday (there is no
        // yesterday here).
        ColumnLayout {
            visible: w.showSummary
            Layout.fillWidth: true
            Layout.maximumWidth: w.horiz ? lay_w() * 0.34 : Number.POSITIVE_INFINITY
            Layout.alignment: w.horiz ? Qt.AlignVCenter : Qt.AlignTop
            spacing: theme.spacingSm

            Text {
                Layout.fillWidth: true
                text: !w.isActiveToday() ? "Rest day, nothing scheduled"
                      : w.allDone ? "All done for today ✓"
                                : w.doneCount + " of " + w.stepList.length + " done"
                color: w.allDone ? theme.success : theme.textPrimary
                font.pixelSize: Math.round(w.rowFont * 0.95)
                font.bold: true
                elide: Text.ElideRight
            }
            // A neutral fill bar: it shows what IS done and simply stays short
            // when little is. The remainder is cardBorder, not a red "gap to close".
            Rectangle {
                Layout.fillWidth: true; Layout.preferredHeight: 6
                radius: 3; color: theme.cardBorder
                Rectangle {
                    height: parent.height; radius: 3
                    width: parent.width * (w.stepList.length ? w.doneCount / w.stepList.length : 0)
                    color: w.allDone ? theme.success : w.effAccent
                    // A width tween on an explicit tap is the one motion here: it is
                    // interaction-triggered (WCAG 2.3.3 territory, AAA) and single-shot,
                    // so it is nowhere near a flash - and it still respects reduceMotion.
                    Behavior on width { NumberAnimation { duration: theme.motionValue; easing.type: Easing.OutCubic } }
                }
            }
        }

        // The viewport is snapped to a WHOLE number of rows: filling the height
        // outright sliced the last row in half at the card edge (clearest on a
        // 846x306 wide box), which reads as broken rather than as "there is more".
        Item {
            Layout.fillWidth: true; Layout.fillHeight: true
            ListView {
            id: stepList
            objectName: "routineStepList"
            readonly property real rowPitch: w.rowH + spacing
            readonly property int visibleCapacity:
                Math.max(1, Math.floor(height / rowPitch))
            readonly property int hiddenStepCount:
                Math.max(0, w.stepItems.length - visibleCapacity)
            width: parent.width
            height: Math.max(w.rowH,
                             Math.floor(parent.height / rowPitch) * rowPitch - spacing)
            anchors.top: parent.top
            clip: true; spacing: w.expanded ? theme.spacingSm : 2
            interactive: w.expanded
            model: w.stepItems
            delegate: Item {
                id: stepRow
                required property int index
                required property var modelData
                objectName: "routineStep-" + stepRow.modelData.key
                readonly property bool done: w.isDone(stepRow.modelData)
                width: ListView.view ? ListView.view.width : 0
                // A full touch target at EVERY size. This row used to be 22px on
                // a tile - a 22px hit area for the only action the widget has.
                // More room buys more rows, never a thinner target.
                height: w.rowH

                RowLayout {
                    anchors.fill: parent
                    spacing: theme.spacingSm
                    Item {
                        objectName: "routineStepAction-" + stepRow.modelData.key
                        Layout.preferredWidth: theme.touchTertiary
                        Layout.fillHeight: true
                        activeFocusOnTab: w.isActiveToday()
                        Accessible.role: Accessible.CheckBox
                        Accessible.name: (stepRow.done ? "Mark incomplete: " : "Complete: ")
                                         + stepRow.modelData.text
                        Accessible.checked: stepRow.done
                        Accessible.onPressAction: w.toggle(stepRow.modelData)
                        Keys.onSpacePressed: w.toggle(stepRow.modelData)
                        Keys.onReturnPressed: w.toggle(stepRow.modelData)

                        Rectangle {
                            anchors.centerIn: parent
                            width: Math.round(w.boxSize)
                            height: width
                            radius: width / 2
                            color: stepRow.done ? w.effAccent : "transparent"
                            border.width: 2
                            border.color: stepRow.done ? w.effAccent : theme.cardBorder
                            Text {
                                anchors.centerIn: parent; visible: stepRow.done
                                text: "✓"; color: "#0D1117"; font.bold: true
                                font.pixelSize: Math.round(w.boxSize * 0.58)
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            enabled: w.isActiveToday()
                            onClicked: w.toggle(stepRow.modelData)
                        }
                    }
                    Text {
                        objectName: "routineStepLabel-" + stepRow.modelData.key
                        Layout.fillWidth: true; Layout.fillHeight: true
                        verticalAlignment: Text.AlignVCenter
                        text: stepRow.modelData.text
                        // A done step is de-emphasised; an undone one is just
                        // normal text. Neither is an error.
                        color: theme.textPrimary
                        opacity: stepRow.done ? 0.72 : 1
                        font.pixelSize: Math.round(w.rowFont)
                        font.strikeout: stepRow.done
                        elide: Text.ElideRight
                    }
                }
            }
            }

            Rectangle {
                objectName: "routineOverflow"
                visible: stepList.hiddenStepCount > 0
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                width: routineOverflowLabel.implicitWidth + 20
                height: 34
                radius: 17
                color: w.effAccent
                Text {
                    id: routineOverflowLabel
                    anchors.centerIn: parent
                    text: "+" + stepList.hiddenStepCount + " more"
                    color: "#0D1117"
                    font.pixelSize: 14
                    font.bold: true
                }
                Accessible.role: Accessible.StaticText
                Accessible.name: stepList.hiddenStepCount
                                 + " more routine steps are below"
            }
        }

        // Footer: the count, so a glance answers "where am I" without expanding.
        // Deliberately not a percentage. Redundant once the summary is shown.
        Text {
            visible: !w.expanded && !w.showSummary
            Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter
            text: w.allDone ? "All done ✓" : w.doneCount + " of " + w.stepList.length
            color: w.allDone ? theme.success : theme.textSecondary
            font.pixelSize: Math.max(theme.fontMinimum,
                                     Math.round(w.rowFont * 0.8)); elide: Text.ElideRight
        }
    }
    // The content width the wide summary measures against (the chrome's body).
    function lay_w() { return w.width - 2 * w.contentMargins }
}
