import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Task tracker - persisted per-instance. Add / check-off / remove; the tile
// and the expanded view share the same list (via the store + revision).
//
// Sizing (W1 wave 2b): a checklist earns MORE ROWS, not bigger ones - and never
// a smaller target. The tile rows were 24px with an 18px-wide checkbox cell that
// carried a MouseArea: an 18x24 hit area for "complete this task", a third of
// theme.touchTertiary (52). Rows are touchTertiary at every size now, the
// checkbox owns a full-height touchTertiary cell, and the add field is
// touchSecondary (60) rather than a fixed 40.
//   • wide  - the list BESIDE its progress + add controls; a 696x409 box stacked
//             into bar/list/field/button is almost all chrome.
//   • every other shape - progress, the list, then the add row, as before.
//   • 1x3 (the whole 720x2560 panel) - the same list, ~40 rows of it.
// Removal stays expanded-only, deliberately: a ✕ on a tile is a mis-tap away
// from the checkbox, and the tile's own tap-to-expand is the way to get it.
// (No 0.5x0.5 is declared, so `micro` is never true here - see WidgetCatalog.)
WidgetChrome {
    id: w
    property var metrics: ({})
    property bool expanded: false
    property bool active: true
    property var store: null
    property string instanceId: ""

    title: "Tasks"; iconName: "tasks"; accentColor: theme.catProductivity

    // Reactive read: clone from the store keyed on revision so nested edits fire.
    readonly property var cfg: {
        var _ = store ? store.revision : 0
        return (store && instanceId) ? JSON.parse(JSON.stringify(store.settingsFor(instanceId))) : ({})
    }
    // Keep one malformed or hostile saved list from creating an unbounded
    // number of delegates. The complete dashboard payload has its own byte cap,
    // but a single widget still needs a smaller interaction-oriented contract.
    readonly property int maxTasks: 200
    readonly property int maxTaskLength: 500
    readonly property int maxTaskScanEntries: 1000
    readonly property var rawItems: Array.isArray(cfg.items) ? cfg.items : []
    function _boundedItems(value) {
        if (!Array.isArray(value)) return []
        var bounded = []
        for (var i = 0; i < value.length
                && i < maxTaskScanEntries
                && bounded.length < maxTasks; i++) {
            var entry = value[i]
            if (!entry || typeof entry !== "object") continue
            bounded.push(Object.assign({}, entry, {
                text: String(entry.text === undefined ? "" : entry.text)
                          .slice(0, maxTaskLength),
                done: entry.done === true,
                sourceIndex: i
            }))
        }
        return bounded
    }
    readonly property var items: _boundedItems(rawItems)
    readonly property bool taskLimitReached: items.length >= maxTasks
    readonly property bool hideCompleted: cfg.hideCompleted !== undefined ? cfg.hideCompleted : false
    readonly property string behaviorProfile: cfg.behaviorProfile || "custom"
    readonly property bool celebrate: behaviorProfile === "calm" ? false
        : behaviorProfile === "momentum" ? true : (cfg.celebrate !== undefined ? cfg.celebrate : true)
    readonly property string displayMode: cfg.displayMode || "all"
    // View-only projection: optionally drop done items, but carry each item's
    // original storage index so toggle/remove still target the right entry.
    readonly property var visibleItems: {
        var a = []
        for (var i = 0; i < items.length; i++) {
            if (hideCompleted && items[i].done) continue
            a.push(Object.assign({}, items[i], {
                text: items[i].text !== undefined ? String(items[i].text) : "",
                done: items[i].done === true,
                idx: items[i].sourceIndex
            }))
            if (displayMode === "top3" && a.length === 3) break
        }
        return a
    }
    readonly property int eligibleCount: {
        var n = 0
        for (var i = 0; i < items.length; i++)
            if (!(hideCompleted && items[i].done)) n++
        return n
    }
    readonly property int storageHiddenCount:
        Math.max(0, rawItems.length - items.length)
    readonly property int modeHiddenCount:
        Math.max(0, eligibleCount - visibleItems.length)
    property int doneCount: {
        var n = 0
        for (var i = 0; i < items.length; i++)
            if (items[i].done === true)
                n++
        return n
    }
    readonly property int openCount: Math.max(0, items.length - doneCount)
    readonly property int completionPercent: items.length
        ? Math.round(doneCount * 100 / items.length) : 0
    status: items.length ? doneCount + "/" + items.length : ""

    // ── Per-size layout (sizeClass injected by Dashboard) ────────────────────
    readonly property bool horiz: sizeClass === "wide"
                                  || ((sizeClass === "large" || sizeClass === "full")
                                      && width > height * 1.25)

    // Does this instance have half-screen room? HabitWidget's predicate, derived
    // the same way and for the same reason - the room itself answers it, not a
    // size name. Reachable here as a TILE: 1x1.5 (696x1229 / 1269x612) clears the
    // 480 half-cell threshold WidgetChrome uses, and 1x2 / 1x3 are `large`.
    readonly property bool roomy: sizeClass === "large" || sizeClass === "full"
        || ((sizeClass === "tall" || sizeClass === "wide")
            && Math.min(width, height) >= 480)

    // The progress bar + count is real content, so every size with room shows it
    // rather than keeping it behind the overlay.
    readonly property bool showSummary: !w.micro
    // A row is a real touch target at every size. At larger text settings it
    // also has to hold two honest lines, otherwise a narrow tile turns ordinary
    // task names into ellipses. Room buys rows, never a thinner target.
    readonly property real rowH:
        Math.max(theme.touchTertiary, Math.ceil(theme.fontLabel * 3))
    // The `w.expanded ? 18` this used to open with is gone and costs exactly
    // nothing: both overlay panes (941 and 656 wide) drive the width term well
    // past the 18 cap it hardcoded, so the derived branch already returned 18
    // there. It is dropped because it asked the wrong question, not because the
    // answer moved.
    readonly property real rowFont:
        Math.max(theme.fontLabel,
                 Math.min((w.horiz ? width * 0.55 : width) * 0.038, 21))
    // The 1x0.5 portrait projection is still a wide tile, but at 125 percent
    // output scaling its action column is too narrow for the long bulk-action
    // label at the largest text setting. Keep the action, use its concise label,
    // and let the add field yield width to its atomic button.
    readonly property bool compactHorizontalActions:
        w.horiz && w.width * 0.4 < theme.fontLabel * 12
    // The checkbox is sized by its ROW, and the row is theme.touchTertiary at
    // EVERY size by explicit design (see the header). So the box is a constant
    // too, and `w.expanded ? 30` was a mode-keyed exception to a deliberate
    // constant - the overlay's rows are not one pixel taller than a tile's. The
    // overlay's box is therefore 27 rather than 30; the 52px TARGET around it is
    // unchanged, which is the number that matters.
    readonly property real boxSize: Math.max(20, Math.min(w.rowH * 0.52, 30))
    // The celebration banner spans the whole CARD, so the card sizes it - the
    // same shape HabitWidget uses. `expanded ? 34 : 18` asked the wrong question
    // and got both answers wrong: a 696x819 baseline tile has more room than the
    // overlay's live-preview pane and still popped at 18, while the overlay kept
    // its 34 after W5 shrank that pane to 38% of the width. Both axes bind (the
    // text wraps to at most 2 lines, so a wide-but-short pane must not overreach)
    // and 34 stays the designed ceiling.
    readonly property real celebratePx: Math.max(theme.fontMinimum, Math.min(width * 0.055,
                                                              height * 0.075, 34))

    function _save(arr) { if (store) store.setSetting(instanceId, "items", arr) }
    property var undoAction: null
    property int undoRevision: -1
    readonly property bool canUndo: undoAction !== null
        && (!store || store.revision === undoRevision)
    readonly property string undoMessage: canUndo ? String(undoAction.message || "") : ""
    function _snapshot() {
        return rawItems.slice()
    }
    function _dismissUndo() {
        undoTimer.stop()
        undoAction = null
        undoRevision = -1
    }
    function _rememberUndo(message, before) {
        undoAction = { message: message, items: before }
        undoRevision = store ? store.revision : -1
        undoTimer.restart()
    }
    function undoLast() {
        if (!canUndo) { _dismissUndo(); return false }
        var before = undoAction.items
        _dismissUndo()
        _save(before)
        return true
    }
    Timer { id: undoTimer; interval: 7000; onTriggered: w._dismissUndo() }
    // Key of the last list we celebrated, so re-completing an already-finished
    // set (un-check then re-check) doesn't re-fire the burst.
    property string _celebratedKey: ""
    function _itemsKey(arr) {
        return arr.map(function (t) {
            return String(t && typeof t === "object" ? t.text : "")
        }).join("")
    }
    function toggle(i) {
        // A rendered row's idx can go stale after an external shrink; ignore it
        // rather than crash (a[i].text on undefined) or mutate the wrong entry.
        if (i < 0 || i >= rawItems.length
                || !rawItems[i] || typeof rawItems[i] !== "object")
            return
        var before = _snapshot()
        var a = _snapshot()
        var it = a[i]
        // Preserve any extra fields (e.g. a Manager-assigned id) and never
        // re-persist a malformed item with text:undefined.
        a[i] = Object.assign({}, it, { text: it.text !== undefined ? it.text : "", done: !it.done })
        _save(a)
        _rememberUndo((a[i].done ? "Completed " : "Reopened ") + String(a[i].text || "task"), before)
        // Dopamine hit: a burst when checking the box that clears the whole list.
        var projected = _boundedItems(a)
        if (a[i].done && celebrate && projected.length > 0
                && projected.length === a.length
                && projected.every(function (t) {
                    return t.done === true
                })) {
            var key = _itemsKey(a)
            if (key !== _celebratedKey) { _celebratedKey = key; celebrateNow("🎉 All done!") }
        }
    }
    function remove(i) {
        if (i < 0 || i >= rawItems.length) return
        var before = _snapshot(), a = _snapshot()
        var removed = a.splice(i, 1)[0]
        _save(a)
        _rememberUndo("Removed " + String(removed.text || "task"), before)
    }
    function add(t) {
        if (taskLimitReached || t === undefined || t === null) return false
        var boundedText = String(t).trim().slice(0, maxTaskLength)
        if (!boundedText.length) return false
        _dismissUndo()
        var a = _snapshot(), serial = Number(cfg.nextId || 0) + 1
        var entry = { id: "task-" + Date.now() + "-" + serial,
                      text: boundedText, done: false }
        if (storageHiddenCount > 0)
            a.unshift(entry)
        else
            a.push(entry)
        if (store) store.patchSettings(instanceId, { items: a, nextId: serial })
        return true
    }
    function edit(i, text) {
        if (i < 0 || i >= rawItems.length
                || !rawItems[i] || typeof rawItems[i] !== "object"
                || text === undefined || text === null)
            return false
        var boundedText = String(text).trim().slice(0, maxTaskLength)
        if (!boundedText.length) return false
        _dismissUndo()
        var a = _snapshot()
        a[i] = Object.assign({}, a[i], { text: boundedText })
        _save(a)
        return true
    }
    function move(i, delta) {
        var j = i + delta
        if (i < 0 || i >= rawItems.length || j < 0 || j >= rawItems.length) return
        _dismissUndo()
        var a = _snapshot(), entry = a.splice(i, 1)[0]; a.splice(j, 0, entry); _save(a)
    }
    function clearCompleted() {
        if (!doneCount) return
        var before = _snapshot(), count = doneCount
        var a = _snapshot()
        var doneIndices = []
        for (var i = 0; i < items.length; i++)
            if (items[i].done === true)
                doneIndices.push(items[i].sourceIndex)
        for (var j = doneIndices.length - 1; j >= 0; j--)
            a.splice(doneIndices[j], 1)
        _save(a)
        _rememberUndo("Cleared " + count + " completed " + (count === 1 ? "task" : "tasks"), before)
    }
    property bool clearArmed: false
    function requestClearCompleted() {
        if (clearArmed) { clearCompleted(); clearArmed = false }
        else { clearArmed = true; clearArmTimer.restart() }
    }
    Timer { id: clearArmTimer; interval: 4000; onTriggered: w.clearArmed = false }

    // Celebration pop, mirroring FocusWidget's honest little reward.
    property string celebrateMsg: ""
    function celebrateNow(msg) { celebrateMsg = msg; celebrateAnim.restart(); flash.restart() }

    Rectangle {
        anchors.fill: parent; radius: theme.radiusLg; color: w.effAccent; opacity: 0; z: 5
        SequentialAnimation on opacity {
            id: flash; running: false
            NumberAnimation { to: theme.effectiveReduceMotion ? 0 : 0.30; duration: theme.motionFast }
            NumberAnimation { to: 0.0; duration: theme.motionSlow }
        }
    }
    Text {
        id: celebrateLabel; anchors.centerIn: parent; z: 20
        // Bounded to the card and allowed to wrap/elide. It had no width, no
        // wrapMode and no elide, so a centred banner longer than the card simply
        // spilled out of both edges - celebrateNow() takes an arbitrary string and
        // the only thing keeping this honest was that today's is short.
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

    // `columns` flips for a wide box: the progress + add controls sit BESIDE the
    // list rather than stacking four bands into it. Only a reshape.
    GridLayout {
        anchors.fill: parent
        columns: w.horiz ? 2 : 1
        rowSpacing: theme.spacingSm
        columnSpacing: theme.spacingLg

        // ── The list ──
        Item {
            id: listPane
            Layout.fillWidth: true; Layout.fillHeight: true
            readonly property int rawRowCapacity: Math.max(1,
                Math.floor(height / taskList.rowPitch))
            readonly property int viewHiddenCount:
                w.storageHiddenCount + w.modeHiddenCount
            readonly property bool needsOverflowFooter: viewHiddenCount > 0
                || (!w.expanded && w.visibleItems.length > rawRowCapacity)
            readonly property int rowCapacity: Math.max(1, Math.floor(
                (height - (needsOverflowFooter ? overflowFooter.height + theme.spacingXs : 0))
                / taskList.rowPitch))
            readonly property int hiddenCount: viewHiddenCount
                + (w.expanded ? 0
                    : Math.max(0, w.visibleItems.length - rowCapacity))

            ListView {
                id: taskList
                objectName: "tasksList"
                readonly property real rowPitch: w.rowH + spacing
                width: parent.width
                // Snapped to a WHOLE number of rows: filling outright slices the
                // last task in half at the card edge.
                height: Math.max(w.rowH, listPane.rowCapacity * rowPitch - spacing)
                anchors.top: parent.top
                clip: true; spacing: 3
                interactive: w.expanded
                model: w.visibleItems
                // The model is a fresh array on every revision bump. Remember where
                // the user was and restore it so an add / external push doesn't
                // yank the list back to row 0.
                property real _savedY: 0
                onContentYChanged: if (contentY > 0) _savedY = contentY
                onModelChanged: contentY = _savedY
                delegate: RowLayout {
                    required property int index
                    required property var modelData
                    objectName: "taskRow-" + index
                    width: ListView.view ? ListView.view.width : 0
                    // A full touch target at EVERY size - see the header.
                    height: w.rowH
                    spacing: theme.spacingSm
                    // Checkbox in a full touchTertiary cell (the visual box stays
                    // smaller). This cell was 18px wide on a tile.
                    Item {
                        objectName: "taskToggle-" + index
                        Layout.preferredWidth: theme.touchTertiary
                        Layout.fillHeight: true
                        activeFocusOnTab: true
                        Accessible.role: Accessible.CheckBox
                        Accessible.name: (modelData.done ? "Mark incomplete: " : "Complete: ")
                                         + modelData.text
                        Accessible.checked: modelData.done
                        Accessible.onPressAction: w.toggle(modelData.idx)
                        Keys.onSpacePressed: w.toggle(modelData.idx)
                        Keys.onReturnPressed: w.toggle(modelData.idx)
                        Rectangle {
                            anchors.centerIn: parent
                            width: Math.round(w.boxSize); height: width; radius: 7
                            color: modelData.done ? w.effAccent : "transparent"
                            border.width: 2; border.color: modelData.done ? w.effAccent : theme.cardBorder
                            Text {
                                objectName: "taskCheckmark-" + index
                                anchors.centerIn: parent; visible: modelData.done; text: "✓"
                                color: "#0D1117"; font.bold: true
                                font.pixelSize: Math.max(theme.fontMinimum,
                                                         Math.round(w.boxSize * 0.57))
                            }
                        }
                        // Tapping the box toggles done in BOTH modes - the tile is
                        // a live control surface (config lives in the corner).
                        MouseArea { anchors.fill: parent; onClicked: w.toggle(modelData.idx) }
                    }
                    Text {
                        objectName: "taskLabel-" + index
                        visible: !w.expanded
                        Layout.fillWidth: true; Layout.fillHeight: true; verticalAlignment: Text.AlignVCenter
                        text: modelData.text !== undefined ? modelData.text : ""
                        wrapMode: Text.WordWrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                        font.pixelSize: Math.round(w.rowFont)
                        font.family: theme.fontDisplay
                        font.strikeout: modelData.done
                        color: theme.textPrimary
                        opacity: modelData.done ? 0.62 : 1
                    }
                    TextField {
                        visible: w.expanded
                        Layout.fillWidth: true; Layout.fillHeight: true
                        text: modelData.text !== undefined ? modelData.text : ""
                        property bool userEdited: false
                        maximumLength: w.maxTaskLength
                        color: theme.textPrimary
                        opacity: modelData.done ? 0.62 : 1
                        font.pixelSize: Math.round(w.rowFont)
                        font.family: theme.fontDisplay
                        font.strikeout: modelData.done
                        Accessible.name: "Edit task: " + modelData.text
                        Accessible.description: "Changes are saved when editing finishes"
                        background: Rectangle {
                            color: "transparent"; radius: 6
                            border.width: parent.activeFocus ? 1 : 0; border.color: w.effAccent
                        }
                        onTextEdited: userEdited = true
                        onEditingFinished: {
                            if (userEdited)
                                w.edit(modelData.idx, text)
                            userEdited = false
                        }
                    }
                    Item {
                        objectName: "taskMoveUp-" + index
                        visible: w.expanded; Layout.preferredWidth: theme.touchTertiary; Layout.fillHeight: true
                        enabled: modelData.idx > 0
                        activeFocusOnTab: visible && enabled
                        Accessible.role: Accessible.Button
                        Accessible.name: "Move " + modelData.text + " up"
                        Accessible.ignored: !visible
                        Accessible.onPressAction: if (enabled) w.move(modelData.idx, -1)
                        Keys.onSpacePressed: if (enabled) w.move(modelData.idx, -1)
                        Keys.onReturnPressed: if (enabled) w.move(modelData.idx, -1)
                        Text { anchors.centerIn: parent; text: "↑"; color: modelData.idx > 0 ? theme.textSecondary : theme.cardBorder; font.pixelSize: 22 }
                        MouseArea { anchors.fill: parent; enabled: parent.enabled; onClicked: w.move(modelData.idx, -1) }
                    }
                    Item {
                        objectName: "taskMoveDown-" + index
                        visible: w.expanded; Layout.preferredWidth: theme.touchTertiary; Layout.fillHeight: true
                        enabled: modelData.idx < w.rawItems.length - 1
                        activeFocusOnTab: visible && enabled
                        Accessible.role: Accessible.Button
                        Accessible.name: "Move " + modelData.text + " down"
                        Accessible.ignored: !visible
                        Accessible.onPressAction: if (enabled) w.move(modelData.idx, 1)
                        Keys.onSpacePressed: if (enabled) w.move(modelData.idx, 1)
                        Keys.onReturnPressed: if (enabled) w.move(modelData.idx, 1)
                        Text { anchors.centerIn: parent; text: "↓"; color: modelData.idx < w.rawItems.length - 1 ? theme.textSecondary : theme.cardBorder; font.pixelSize: 22 }
                        MouseArea { anchors.fill: parent; enabled: parent.enabled; onClicked: w.move(modelData.idx, 1) }
                    }
                    // Remove in a full touchTertiary cell. Expanded-only: on a tile
                    // a ✕ is a mis-tap away from the checkbox.
                    Item {
                        objectName: "taskRemove-" + index
                        visible: w.expanded; Layout.preferredWidth: theme.touchTertiary; Layout.fillHeight: true
                        activeFocusOnTab: visible
                        Accessible.role: Accessible.Button
                        Accessible.name: "Remove task: " + modelData.text
                        Accessible.description: "Can be undone for seven seconds"
                        Accessible.ignored: !visible
                        Accessible.onPressAction: w.remove(modelData.idx)
                        Keys.onSpacePressed: w.remove(modelData.idx)
                        Keys.onReturnPressed: w.remove(modelData.idx)
                        Text { anchors.centerIn: parent; text: "✕"; color: theme.error
                            opacity: rmMA.pressed ? 1 : 0.82
                            font.pixelSize: 22 }
                        MouseArea { id: rmMA; anchors.fill: parent; onClicked: w.remove(modelData.idx) }
                    }
                }
            }

            Rectangle {
                id: overflowFooter
                objectName: "tasksOverflowFooter"
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: w.expanded && w.storageHiddenCount > 0
                        ? theme.touchSecondary : theme.touchTertiary
                visible: listPane.needsOverflowFooter
                radius: theme.radiusSm
                color: Qt.rgba(w.effAccent.r, w.effAccent.g, w.effAccent.b, 0.11)
                border.width: 1
                border.color: Qt.rgba(w.effAccent.r, w.effAccent.g, w.effAccent.b, 0.30)
                Accessible.role: Accessible.StaticText
                Accessible.name: w.expanded
                    ? (w.storageHiddenCount > 0
                       ? w.storageHiddenCount
                         + " stored entries are hidden by safety limits and preserved."
                       : w.modeHiddenCount + " tasks are hidden by the current view settings.")
                    : listPane.hiddenCount + " more "
                      + (listPane.hiddenCount === 1 ? "task" : "tasks")
                      + ". Open for details."
                Text {
                    id: overflowFooterText
                    objectName: "tasksOverflowFooterText"
                    anchors.centerIn: parent
                    width: parent.width - 2 * theme.spacingMd
                    text: w.expanded
                        ? (w.storageHiddenCount > 0
                           ? w.storageHiddenCount
                             + " stored entries hidden by safety limits. They are preserved."
                           : w.modeHiddenCount
                             + " tasks hidden by the current view settings.")
                        : (width < theme.fontLabel * 17
                           ? "+" + listPane.hiddenCount + " more | open"
                           : "+" + listPane.hiddenCount + " more "
                             + (listPane.hiddenCount === 1 ? "task" : "tasks")
                             + " | open for details")
                    color: theme.textPrimary
                    font.pixelSize: theme.fontLabel
                    font.bold: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                }
            }

            ColumnLayout {
                objectName: "tasksEmptyState"
                anchors.centerIn: parent
                anchors.verticalCenterOffset:
                    listPane.needsOverflowFooter ? -overflowFooter.height / 2 : 0
                visible: w.items.length === 0
                width: Math.min(parent.width - 2 * theme.spacingSm, 620)
                spacing: w.roomy ? theme.spacingMd : theme.spacingXs

                Rectangle {
                    visible: w.roomy
                    Layout.alignment: Qt.AlignHCenter
                    Layout.preferredWidth: 62; Layout.preferredHeight: 62
                    radius: 31
                    color: Qt.rgba(w.effAccent.r, w.effAccent.g, w.effAccent.b, 0.11)
                    border.width: 1
                    border.color: Qt.rgba(w.effAccent.r, w.effAccent.g, w.effAccent.b, 0.30)
                    Text { anchors.centerIn: parent; text: "✓"; color: w.effAccent
                        font.pixelSize: 28; font.bold: true }
                }

                Text {
                    Layout.fillWidth: true
                    text: "No tasks"
                    horizontalAlignment: Text.AlignHCenter
                    color: w.roomy ? w.effAccent : theme.textTertiary
                    font.bold: w.roomy
                    font.pixelSize: Math.round(Math.max(theme.fontMinimum,
                        Math.min((w.horiz ? w.width * 0.55 : w.width) * 0.034,
                                 w.roomy ? 22 : 15)))
                }

                Text {
                    visible: w.roomy
                    Layout.fillWidth: true
                    text: "Make the next move obvious. Add one outcome or start with a prompt."
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    color: theme.textSecondary
                    font.pixelSize: theme.fontMinimum
                }

                RowLayout {
                    visible: w.roomy
                    Layout.fillWidth: true
                    spacing: theme.spacingSm
                    Repeater {
                        model: ["Plan today", "Follow up", "Review progress"]
                        delegate: Rectangle {
                            required property int index
                            required property string modelData
                            objectName: "taskPrompt-" + index
                            function activate() { w.add(modelData) }
                            Layout.fillWidth: true
                            Layout.preferredHeight: theme.touchTertiary
                            radius: theme.radiusSm
                            color: promptMouse.pressed
                                   ? Qt.rgba(w.effAccent.r, w.effAccent.g, w.effAccent.b, 0.18)
                                   : theme.backgroundColor
                            border.width: 1
                            border.color: theme.cardBorder
                            Text { anchors.centerIn: parent; width: parent.width - 12
                                text: modelData; color: theme.textPrimary
                                font.pixelSize: theme.fontMinimum; font.bold: true
                                horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight }
                            MouseArea { id: promptMouse; anchors.fill: parent
                                onClicked: parent.activate() }
                        }
                    }
                }
            }

            ColumnLayout {
                objectName: "tasksFilteredState"
                anchors.centerIn: parent
                anchors.verticalCenterOffset:
                    listPane.needsOverflowFooter ? -overflowFooter.height / 2 : 0
                visible: w.items.length > 0 && w.visibleItems.length === 0
                width: Math.min(parent.width - 2 * theme.spacingSm, 520)
                spacing: theme.spacingSm

                Text {
                    Layout.fillWidth: true
                    text: "All " + w.doneCount + " "
                        + (w.doneCount === 1 ? "task" : "tasks") + " completed"
                    color: w.effAccent
                    font.pixelSize: theme.fontTitle
                    font.bold: true
                    horizontalAlignment: Text.AlignHCenter
                }
                Text {
                    Layout.fillWidth: true
                    text: "Completed tasks are hidden."
                    color: theme.textPrimary
                    opacity: 0.78
                    font.pixelSize: theme.fontLabel
                    horizontalAlignment: Text.AlignHCenter
                }
                PillButton {
                    Layout.alignment: Qt.AlignHCenter
                    label: "Show completed"
                    glyph: "✓"
                    tint: w.effAccent
                    onClicked: if (w.store)
                        w.store.setSetting(w.instanceId, "hideCompleted", false)
                }
            }
        }

        // ── Progress + add. The wide shape's control column.
        ColumnLayout {
            id: controlPane
            objectName: "tasksControlPane"
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            Layout.maximumWidth: w.horiz ? w.width * 0.4 : Number.POSITIVE_INFINITY
            Layout.alignment: w.horiz ? Qt.AlignVCenter : Qt.AlignBottom
            spacing: theme.spacingSm

            Rectangle {
                objectName: "tasksProgressSummary"
                visible: w.roomy && w.items.length > 0
                Layout.fillWidth: true
                Layout.preferredHeight: 68
                radius: theme.radiusMd
                color: Qt.rgba(w.effAccent.r, w.effAccent.g, w.effAccent.b, 0.08)
                border.width: 1
                border.color: Qt.rgba(w.effAccent.r, w.effAccent.g, w.effAccent.b, 0.24)

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: theme.spacingMd
                    anchors.rightMargin: theme.spacingMd
                    spacing: theme.spacingMd
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 1
                        Text { text: w.openCount + " open"; color: theme.textPrimary
                            font.pixelSize: theme.fontLabel; font.bold: true }
                        Text { text: w.doneCount + " completed"; color: theme.textPrimary
                            opacity: 0.78; font.pixelSize: theme.fontLabel }
                    }
                    Text { text: w.completionPercent + "%"; color: w.effAccent
                        font.pixelSize: 25; font.bold: true; font.family: theme.fontMono }
                }
            }

            // Progress toward "all done" - a glanceable momentum bar, now earned
            // by any tile with room rather than kept behind the overlay.
            Rectangle {
                visible: w.showSummary && w.items.length > 0
                Layout.fillWidth: true; Layout.preferredHeight: 6
                radius: 3; color: theme.cardBorder
                Rectangle {
                    height: parent.height; radius: 3
                    width: parent.width * (w.items.length
                                           ? w.doneCount / w.items.length : 0)
                    color: w.effAccent
                    Behavior on width { NumberAnimation { duration: theme.motionValue; easing.type: Easing.OutCubic } }
                }
            }

            // Quick add - available at EVERY size; both paths call add().
            RowLayout {
                objectName: "tasksAddRow"
                Layout.fillWidth: true; spacing: theme.spacingSm
                TextField {
                    id: input
                    objectName: "tasksAddField"
                    Layout.fillWidth: true
                    Layout.minimumWidth: theme.fontMinimum * 3
                    // theme.touchSecondary at EVERY size: this was a fixed 40px on
                    // tiles, under theme.touchTertiary (52).
                    Layout.preferredHeight: theme.touchSecondary
                    Layout.minimumHeight: theme.touchSecondary
                    Layout.maximumHeight: theme.touchSecondary
                    // placeholderText stays as it is: content, and already half
                    // room-keyed via `horiz`.
                    placeholderText: w.expanded || w.horiz ? "Add a task…" : "Add…"
                    maximumLength: w.maxTaskLength
                    enabled: !w.taskLimitReached
                    // The field is a constant theme.touchSecondary tall at every
                    // size, but the COLUMN it sits in is not - `horiz` caps that
                    // column at 40% of the card (see Layout.maximumWidth below),
                    // so the text measures against the room it actually has. 16
                    // stays the designed ceiling; the overlay's narrow portrait
                    // pane now honestly reports that it has a tile's room, not a
                    // screen's.
                    color: theme.textPrimary
                    font.pixelSize: Math.round(Math.max(theme.fontLabel,
                        Math.min((w.horiz ? w.width * 0.4 : w.width) * 0.026,
                                 w.height * 0.04, 20)))
                    placeholderTextColor: theme.textTertiary
                    background: Rectangle { radius: theme.radiusSm; color: theme.backgroundColor
                        border.color: input.activeFocus ? w.effAccent : theme.cardBorder; border.width: 1 }
                    onAccepted: {
                        if (w.add(text))
                            text = ""
                    }
                }
                PillButton {
                    objectName: "tasksAddButton"
                    label: w.expanded ? "Add" : ""; glyph: "＋"; primary: true; tint: w.effAccent
                    enabled: !w.taskLimitReached
                    onClicked: {
                        if (w.add(input.text))
                            input.text = ""
                    } }
            }
            Text {
                objectName: "tasksLimitNotice"
                visible: w.taskLimitReached
                Layout.fillWidth: true
                text: "Task limit reached (" + w.maxTasks + "). Complete or remove an item to add another."
                color: theme.warning
                font.pixelSize: theme.fontMinimum
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                elide: Text.ElideRight
                Accessible.role: Accessible.StaticText
                Accessible.name: text
            }
            Rectangle {
                objectName: "tasksUndoBar"
                visible: w.canUndo
                Layout.fillWidth: true
                Layout.preferredHeight: theme.touchSecondary
                radius: theme.radiusSm
                color: Qt.rgba(w.effAccent.r, w.effAccent.g, w.effAccent.b, 0.12)
                border.width: 1
                border.color: Qt.rgba(w.effAccent.r, w.effAccent.g, w.effAccent.b, 0.34)
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: theme.spacingMd
                    anchors.rightMargin: theme.spacingXs
                    spacing: theme.spacingSm
                    Text {
                        Layout.fillWidth: true
                        text: w.undoMessage
                        color: theme.textPrimary
                        font.pixelSize: theme.fontLabel
                        elide: Text.ElideRight
                    }
                    PillButton {
                        label: "Undo"
                        glyph: "↶"
                        tint: w.effAccent
                        Accessible.name: "Undo " + w.undoMessage
                        onClicked: w.undoLast()
                    }
                }
            }
            // Bulk "clear completed" - only when there's something to clear, and
            // only where there is room for a deliberate act.
            PillButton {
                objectName: "tasksClearCompleted"
                Layout.alignment: Qt.AlignHCenter
                visible: (w.expanded || w.horiz) && w.doneCount > 0
                label: w.clearArmed
                       ? (w.compactHorizontalActions ? "Confirm clear" : "Tap again to clear")
                       : (w.compactHorizontalActions
                          ? "Clear " + w.doneCount
                          : "Clear " + w.doneCount + " completed")
                glyph: "🧹"; tint: w.clearArmed ? theme.warning : theme.textSecondary
                onClicked: w.requestClearCompleted()
            }
        }
    }
}
