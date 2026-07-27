import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// ─────────────────────────────────────────────────────────────────────────
// Braindump - timestamped one-liners you add fast and clear often.
//
// NOT a second `notes`. Notes is a scratchpad: one body of text you edit and
// keep. This is a capture queue: many short entries, each stamped with when it
// arrived, newest first, meant to be emptied. The distinction is the whole
// feature - the cost of capture has to be one tap and one line, or the thought
// is gone before the UI is ready for it. So: the input is always present (both
// modes), Enter commits, and nothing else is required - no title, no category,
// no confirm step.
//
// Entries carry `at` (epoch ms) rather than a formatted string so the display
// format stays a rendering decision, and a device timezone change doesn't
// rewrite history.
//
// Persistence: the whole list, written only on add/remove/clear. The list is
// pruned to `maxEntries` on add - an unbounded array here would grow config.toml
// forever, and this widget is explicitly the one you dump INTO without thinking.
//
// Sizing (W1 wave 2b): a queue earns MORE ROWS, not bigger ones.
//   • wide  - the capture column BESIDE the queue. Stacking a bottom bar into a
//             846x306 banner leaves ~3 rows; beside it, ~5, and the field is
//             where the eye already is.
//   • every other shape - the queue with the capture row beneath it, as before.
// The capture row is theme.touchSecondary (60) at EVERY size; it used to be a
// fixed 40px, under theme.touchTertiary (52), which is a real miss on the one
// control the widget exists for. Entry rows carry NO tap target on a tile
// (removal is expanded-only, deliberately), so they are a readout and may be
// denser - density is only free where nothing is tappable.
// ─────────────────────────────────────────────────────────────────────────
WidgetChrome {
    id: w
    property var metrics: ({})
    property bool expanded: false
    property bool active: true
    property var store: null
    property string instanceId: ""
    property int tick: 0

    title: "Braindump"; iconName: "braindump"; accentColor: theme.catProductivity

    readonly property var cfg: {
        var _ = store ? store.revision : 0
        return (store && instanceId) ? JSON.parse(JSON.stringify(store.settingsFor(instanceId))) : ({})
    }
    // NOTE (W1 wave 2b, measured - do not "fix" this without re-measuring).
    // `cfg` is a fresh deep copy on every store.revision bump, and revision is
    // GLOBAL: it bumps on ANY widget's write, including the metric tiles' `hist`
    // sparkline write every ~2s. So `entries` below IS a new array roughly every
    // two seconds, which looks exactly like the SensorsWidget clunk (a model bound
    // to something that changes every tick).
    // It is NOT. Measured on a 40-entry list, an unrelated `hist` write leaves all
    // 28 realised delegates alive and does not move contentY: a ListView fed a JS
    // array diffs it against the previous one and reuses the delegates when the
    // content is equal. Pinning identity here (deriving `entries` off a JSON
    // signature) was tried and reverted - it swapped Qt's diff for an equivalent
    // JS stringify and fixed nothing observable.
    // tst_braindump's "BraindumpIdentity" case pins the property that actually
    // matters, so a future change that DOES start rebuilding delegates fails there.
    readonly property var entries: cfg.entries || []
    readonly property bool showTimes: cfg.showTimes !== undefined ? cfg.showTimes : true

    // The cap exists to bound config.toml, not to discipline the user. Oldest go
    // first because this is a queue you drain from the top.
    readonly property int maxEntries: 100
    readonly property int maxEntryLength: 500
    property string editingId: ""
    property string editingText: ""
    readonly property var undoSnapshot:
        Array.isArray(cfg.undoEntries)
        ? { entries: cfg.undoEntries,
            label: String(cfg.undoLabel || "Undo last change") }
        : null
    property bool clearArmed: false
    property string captureNotice: ""
    property string actionNotice: ""
    readonly property bool captureDraftPending:
        input.text.trim().length > 0
    readonly property bool editDraftPending: {
        if (!w.editingId.length)
            return false
        if (w.editingIndex < 0 || w.editingIndex >= w.entries.length)
            return w.editingText.length > 0
        var entry = w.entries[w.editingIndex] || ({})
        return w.editingText !== String(entry.text || "")
    }

    function entryId(entry, index) {
        if (entry && entry.id) return String(entry.id)
        var stamp = entry && isFinite(entry.at) ? String(entry.at) : "nostamp"
        return "dump-legacy-" + stamp + "-" + index
    }
    function entriesWithIds() {
        var result = []
        for (var i = 0; i < w.entries.length; i++) {
            var entry = w.entries[i] || ({})
            result.push({
                id: w.entryId(entry, i),
                text: String(entry.text || ""),
                at: entry.at !== undefined ? entry.at : Date.now()
            })
        }
        return result
    }
    function indexOfId(id) {
        for (var i = 0; i < w.entries.length; i++)
            if (w.entryId(w.entries[i], i) === id) return i
        return -1
    }
    readonly property int editingIndex: indexOfId(editingId)

    function reportSaveFailure() {
        w.captureNotice = ""
        w.actionNotice = "Save failed. Keep this widget open and try again."
        noticeTimer.stop()
    }
    function persistMutation(next, undoLabel, notice) {
        if (!store) {
            w.reportSaveFailure()
            return false
        }
        try {
            if (store.patchSettings(instanceId, {
                    entries: next,
                    undoEntries: w.entriesWithIds(),
                    undoLabel: undoLabel
                }) === false) {
                w.reportSaveFailure()
                return false
            }
        } catch (error) {
            w.reportSaveFailure()
            return false
        }
        w.actionNotice = notice
        noticeTimer.restart()
        return true
    }

    status: w.expanded || !w.entries.length ? "" : "" + w.entries.length

    // ── Per-size layout (sizeClass injected by Dashboard) ────────────────────
    readonly property bool horiz: sizeClass === "wide"
                                  || ((sizeClass === "large" || sizeClass === "full")
                                      && width > height * 1.25)
    // Entry rows are a READOUT on a tile (no destructive tap target), but their
    // typography still follows the user's viewing-distance scale. The row grows
    // just enough to retain a comfortable two-line viewport at the largest
    // supported scale.
    readonly property real rowFont: Math.max(theme.fontLabel, 17)
    readonly property real rowH: Math.max(
        w.expanded ? theme.touchTertiary : 52,
        Math.ceil(w.rowFont * 2.55),
        w.expanded ? 56 : Math.min(height * 0.07, 64))
    readonly property real stampFont: Math.max(
        theme.fontMinimum, Math.round(w.rowFont * 0.78))
    // Clear remains available in the expanded management surface. Compact and
    // shallow wide tiles keep that height for capture and readable queue data.
    readonly property bool showClear: w.expanded && w.entries.length > 0

    function add(text) {
        if (!store) return false
        var t = (text || "").trim()
        if (!t.length) return true
        // Newest first: the thing you just captured must be the thing you see,
        // without scrolling - otherwise a full list silently swallows the entry.
        var wasTruncated = t.length > w.maxEntryLength
        t = t.slice(0, w.maxEntryLength)
        var a = [{ id: "dump-" + Date.now() + "-" + Math.floor(Math.random() * 1000000),
                   text: t, at: Date.now() }].concat(w.entriesWithIds())
        var dropped = Math.max(0, a.length - w.maxEntries)
        if (dropped) a = a.slice(0, w.maxEntries)
        var nextCaptureNotice = wasTruncated
            ? "Saved the first " + w.maxEntryLength + " characters."
            : dropped
              ? "Saved. The oldest thought was removed because the queue is full."
              : ""
        if (!w.persistMutation(a, "Undo captured thought", "Thought captured"))
            return false
        w.captureNotice = nextCaptureNotice
        return true
    }
    function commitCapture() {
        if (!input.text.trim().length) return true
        if (!w.add(input.text))
            return false
        input.text = ""
        return true
    }
    function remove(i) {
        if (!store || i < 0 || i >= w.entries.length) return
        var a = w.entriesWithIds()
        a.splice(i, 1)
        w.editingId = ""
        w.persistMutation(a, "Restore removed thought", "Thought removed")
    }
    function requestClearAll() {
        if (!store || !w.entries.length) return
        if (!w.clearArmed) {
            w.clearArmed = true
            w.actionNotice = "Tap again to clear " + w.entries.length + " thoughts"
            noticeTimer.restart()
            clearTimer.restart()
            return
        }
        w.clearArmed = false
        w.persistMutation([], "Restore cleared thoughts", "Queue cleared")
    }
    function clearAll() { requestClearAll() }
    function beginEdit(i) {
        if (i < 0 || i >= w.entries.length) return
        w.editingId = w.entryId(w.entries[i], i)
        w.editingText = String(w.entries[i].text || "")
    }
    function commitEdit(text) {
        if (!store || w.editingIndex < 0 || w.editingIndex >= w.entries.length)
            return false
        var t = String(text === undefined ? w.editingText : text).trim().slice(0, w.maxEntryLength)
        if (!t.length) {
            w.actionNotice = "A thought cannot be empty. Save text or cancel the edit."
            noticeTimer.restart()
            return false
        }
        var a = w.entriesWithIds()
        var old = a[w.editingIndex]
        if (t === String(old.text || "")) {
            w.editingId = ""
            w.editingText = ""
            return true
        }
        a[w.editingIndex] = { id: old.id, text: t, at: old.at }
        if (!w.persistMutation(a, "Undo edit", "Thought updated"))
            return false
        w.editingId = ""
        w.editingText = ""
        return true
    }
    function cancelEdit() {
        w.editingId = ""
        w.editingText = ""
        w.actionNotice = "Edit cancelled"
        noticeTimer.restart()
        return true
    }
    function saveOrBeginEdit(index) {
        if (w.editingIndex === index)
            return w.commitEdit(w.editingText)
        w.beginEdit(index)
        return true
    }
    function cancelOrRemove(index) {
        if (w.editingIndex === index)
            return w.cancelEdit()
        w.remove(index)
        return true
    }
    function hasPendingChanges() {
        return w.captureDraftPending || w.editDraftPending
    }
    function flush() {
        // Treat the two buffers independently. A malformed inline edit must make
        // the overall flush fail closed, but it must not strand a separate valid
        // capture draft in an overlay that is about to be destroyed.
        var ok = true
        var editValidationMessage = ""
        var hadEditDraft = w.editDraftPending
        if (hadEditDraft) {
            if (w.editingIndex < 0 || w.editingIndex >= w.entries.length) {
                editValidationMessage =
                    "This thought changed elsewhere. Cancel or review the edit."
                ok = false
            } else if (!w.editingText.trim().length) {
                editValidationMessage =
                    "A thought cannot be empty. Save text or cancel the edit."
                ok = false
            } else if (!w.commitEdit(w.editingText))
                ok = false
        }
        if (w.captureDraftPending && !w.commitCapture())
            ok = false
        if (editValidationMessage.length) {
            w.captureNotice = ""
            w.actionNotice = editValidationMessage
            noticeTimer.restart()
        }
        return ok && !w.hasPendingChanges()
    }
    function undoLastChange() {
        if (!store || !w.undoSnapshot) return
        var snapshot = w.undoSnapshot
        store.patchSettings(instanceId, {
            entries: snapshot.entries,
            undoEntries: null,
            undoLabel: ""
        })
        w.actionNotice = "Last change undone"
        noticeTimer.restart()
    }

    Timer { id: clearTimer; interval: 5000; onTriggered: w.clearArmed = false }
    Timer {
        id: noticeTimer
        interval: 6000
        onTriggered: {
            w.actionNotice = ""
            w.captureNotice = ""
        }
    }
    // Dashboard overlays are separate widget instances and may be destroyed
    // without ever observing expanded=false. Commit local buffers on either
    // lifecycle path so close, shutdown, and external-layout preflight share the
    // same persistence contract.
    onExpandedChanged: {
        if (!w.expanded)
            w.flush()
    }
    Component.onDestruction: w.flush()

    // Today → just the time; older → weekday + time. An entry with no usable
    // stamp (hand-edited config, an older schema) renders blank rather than
    // "Invalid Date" - the text is what matters, the stamp is a nicety.
    function stampOf(entry) {
        if (!entry || entry.at === undefined || !isFinite(entry.at)) return ""
        var d = new Date(entry.at)
        if (isNaN(d.getTime())) return ""
        var now = new Date()
        return d.toDateString() === now.toDateString()
            ? Qt.formatTime(d, "HH:mm")
            : Qt.formatDateTime(d, "ddd HH:mm")
    }

    // `columns` flips for a wide box: the capture column sits BESIDE the queue
    // rather than under it. Only a reshape - the ListView is not rebuilt.
    GridLayout {
        anchors.fill: parent
        columns: w.horiz ? 2 : 1
        rowSpacing: theme.spacingSm
        columnSpacing: theme.spacingLg

        // ── The queue ──
        Item {
            objectName: "braindumpQueueColumn"
            Layout.fillWidth: true; Layout.fillHeight: true

            ListView {
                id: list
                objectName: "braindumpList"
                readonly property real rowPitch: w.rowH + spacing
                width: parent.width
                // Snapped to a WHOLE number of rows: filling outright slices the
                // last entry in half at the card edge.
                height: Math.max(w.rowH,
                                 Math.floor(parent.height / rowPitch) * rowPitch - spacing)
                anchors.top: parent.top
                clip: true; spacing: 3
                interactive: contentHeight > height + 1
                model: w.entries
                readonly property int visibleCapacity:
                    Math.max(1, Math.floor(height / rowPitch))
                readonly property int hiddenEntryCount:
                    Math.max(0, w.entries.length - visibleCapacity)
                // Newest-first, so an add showing you the new row at the top is
                // correct - unlike TasksWidget, which restores scroll.
                delegate: RowLayout {
                    id: entryRow
                    required property int index
                    required property var modelData
                    readonly property bool editingThis:
                        w.editingIndex === entryRow.index
                    objectName: "braindumpEntry-" + w.entryId(modelData, index)
                    width: ListView.view ? ListView.view.width : 0
                    height: w.rowH
                    spacing: theme.spacingSm
                    // ListView may retain delegates just beyond its clipped
                    // viewport. Do not paint or expose those recycled rows until
                    // they actually intersect the visible queue.
                    visible: y + height > list.contentY
                             && y < list.contentY + list.height

                    Text {
                        objectName: "braindumpStamp-" + entryRow.index
                        visible: w.showTimes
                        text: w.stampOf(entryRow.modelData)
                        color: theme.textPrimary
                        opacity: 0.72
                        font.family: theme.fontMono
                        font.pixelSize: Math.round(w.stampFont)
                        Layout.minimumWidth: Math.ceil(implicitWidth) + 1
                        Layout.preferredWidth: Layout.minimumWidth
                        Layout.alignment: Qt.AlignVCenter
                        horizontalAlignment: Text.AlignRight
                        wrapMode: Text.NoWrap
                    }
                    Flickable {
                        id: thoughtViewport
                        objectName: "braindumpThoughtViewport-" + entryRow.index
                        Layout.fillWidth: true; Layout.fillHeight: true
                        visible: w.editingIndex !== entryRow.index
                        clip: true
                        contentWidth: width
                        contentHeight: Math.max(height, thoughtText.implicitHeight)
                        flickableDirection: Flickable.VerticalFlick
                        interactive: contentHeight > height + 1
                        boundsBehavior: Flickable.StopAtBounds

                        ScrollBar.vertical: ScrollBar {
                            id: thoughtScrollBar
                            policy: thoughtViewport.contentHeight
                                    > thoughtViewport.height + 1
                                    ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
                        }

                        Text {
                            id: thoughtText
                            objectName: "braindumpThought-" + entryRow.index
                            // Reserve a stable overlay gutter. Binding width to
                            // ScrollBar.visible creates a content-height cycle:
                            // wrapping decides whether the bar is visible while
                            // visibility would change the wrapping width.
                            width: Math.max(1, thoughtViewport.width
                                            - theme.spacingSm)
                            height: Math.max(thoughtViewport.height, implicitHeight)
                            verticalAlignment: implicitHeight <= thoughtViewport.height
                                               ? Text.AlignVCenter : Text.AlignTop
                            text: entryRow.modelData
                                  && entryRow.modelData.text !== undefined
                                  ? entryRow.modelData.text : ""
                            color: theme.textPrimary
                            wrapMode: Text.Wrap
                            font.pixelSize: Math.round(w.rowFont)
                        }
                    }
                    TextField {
                        objectName: "braindumpEditor-" + w.entryId(entryRow.modelData,
                                                                   entryRow.index)
                        Layout.fillWidth: true; Layout.fillHeight: true
                        visible: w.editingIndex === entryRow.index
                        text: visible ? w.editingText : ""
                        maximumLength: w.maxEntryLength
                        color: theme.textPrimary
                        font.pixelSize: Math.round(w.rowFont)
                        selectByMouse: true
                        onTextEdited: w.editingText = text
                        onAccepted: w.commitEdit(text)
                        Keys.onEscapePressed: w.cancelEdit()
                    }
                    // Removal is expanded-only: on a small tile the ✕ would sit a
                    // thumb-width from the text and this list is meant to be added
                    // to in a hurry. Clearing is a deliberate act, so it needs room.
                    RowLayout {
                        visible: w.expanded
                        spacing: 0
                        Rectangle {
                            objectName: "braindumpEdit-" + w.entryId(entryRow.modelData,
                                                                     entryRow.index)
                            Layout.preferredWidth: theme.touchTertiary; Layout.fillHeight: true
                            radius: 8
                            color: editMA.pressed ? Qt.rgba(w.effAccent.r, w.effAccent.g,
                                                            w.effAccent.b, 0.18) : "transparent"
                            border.width: 1
                            border.color: theme.cardBorder
                            activeFocusOnTab: true
                            Accessible.role: Accessible.Button
                            Accessible.name: (entryRow.editingThis ? "Save" : "Edit")
                                             + " thought " + (entryRow.index + 1)
                            Accessible.onPressAction: w.saveOrBeginEdit(entryRow.index)
                            Keys.onSpacePressed: w.saveOrBeginEdit(entryRow.index)
                            Keys.onReturnPressed: w.saveOrBeginEdit(entryRow.index)
                            AppIcon {
                                anchors.centerIn: parent
                                name: entryRow.editingThis ? "ui-check" : "ui-edit"; size: 20
                                color: theme.textPrimary
                            }
                            MouseArea {
                                id: editMA
                                anchors.fill: parent
                                onClicked: w.saveOrBeginEdit(entryRow.index)
                            }
                        }
                        Rectangle {
                            objectName: "braindumpRemove-" + w.entryId(entryRow.modelData,
                                                                       entryRow.index)
                            Layout.preferredWidth: theme.touchTertiary; Layout.fillHeight: true
                            radius: 8
                            color: rmMA.pressed
                                   ? (entryRow.editingThis
                                      ? Qt.rgba(w.effAccent.r, w.effAccent.g,
                                                w.effAccent.b, 0.18)
                                      : Qt.rgba(theme.error.r, theme.error.g,
                                                theme.error.b, 0.16))
                                   : "transparent"
                            border.width: 1
                            border.color: theme.cardBorder
                            activeFocusOnTab: true
                            Accessible.role: Accessible.Button
                            Accessible.name: (entryRow.editingThis ? "Cancel edit for"
                                             : "Remove") + " thought "
                                             + (entryRow.index + 1)
                            Accessible.onPressAction: w.cancelOrRemove(entryRow.index)
                            Keys.onSpacePressed: w.cancelOrRemove(entryRow.index)
                            Keys.onReturnPressed: w.cancelOrRemove(entryRow.index)
                            AppIcon {
                                anchors.centerIn: parent
                                name: entryRow.editingThis ? "ui-close" : "ui-trash"; size: 20
                                color: theme.textPrimary
                            }
                            MouseArea {
                                id: rmMA
                                anchors.fill: parent
                                onClicked: w.cancelOrRemove(entryRow.index)
                            }
                        }
                    }
                }
            }

            Rectangle {
                objectName: "braindumpOverflow"
                visible: list.hiddenEntryCount > 0
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                width: overflowLabel.implicitWidth + 20
                height: Math.max(34, Math.ceil(theme.fontMinimum * 1.8))
                radius: height / 2
                color: w.effAccent
                Text {
                    id: overflowLabel
                    anchors.centerIn: parent
                    text: "+" + list.hiddenEntryCount + " more"
                    color: "#0D1117"
                    font.pixelSize: theme.fontMinimum
                    font.bold: true
                }
                Accessible.role: Accessible.StaticText
                Accessible.name: list.hiddenEntryCount + " more thoughts are below"
            }

            Text {
                anchors.centerIn: parent
                visible: w.entries.length === 0
                width: parent.width - 2 * theme.spacingSm
                horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                text: "Ready for a thought\nCapture it below"
                color: theme.textPrimary
                font.pixelSize: Math.max(theme.fontLabel, 17)
                font.bold: true
            }
        }

        // ── Capture. Always present, at every size - the capture path IS the
        // product, so it is the one thing that never gets traded for a row.
        ColumnLayout {
            objectName: "braindumpCaptureColumn"
            Layout.fillWidth: true
            Layout.maximumWidth: w.horiz ? w.width * 0.42 : Number.POSITIVE_INFINITY
            Layout.alignment: w.horiz ? Qt.AlignVCenter : Qt.AlignBottom
            spacing: theme.spacingSm

            RowLayout {
                Layout.fillWidth: true; spacing: theme.spacingSm
                Layout.minimumHeight: theme.touchSecondary
                Layout.preferredHeight: w.expanded ? 112 : 80
                Layout.maximumHeight: Layout.preferredHeight
                ScrollView {
                    id: captureViewport
                    objectName: "braindumpCaptureViewport"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.minimumHeight: theme.touchSecondary
                    Layout.maximumHeight: w.expanded ? 112 : 80
                    clip: true
                    ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

                    // The 500-character entry model needs an actual multiline,
                    // vertically scrollable editor. Ctrl+Enter commits; Enter
                    // remains available for a new line.
                    TextArea {
                        id: input
                        objectName: "braindumpCaptureField"
                        width: captureViewport.availableWidth
                        height: Math.max(captureViewport.availableHeight,
                                         contentHeight + topPadding + bottomPadding)
                        placeholderText: w.expanded || w.horiz
                                         ? "What's on your mind?" : "Dump..."
                        wrapMode: TextArea.Wrap
                        color: theme.textPrimary
                        font.pixelSize: Math.max(theme.fontLabel, 17)
                        placeholderTextColor: theme.textSecondary
                        background: Rectangle {
                            radius: theme.radiusSm
                            color: theme.backgroundColor
                            border.color: input.activeFocus
                                          ? w.effAccent : theme.cardBorder
                            border.width: 1
                        }
                        onTextChanged: {
                            if (text.length > w.maxEntryLength) {
                                var keepCursor = Math.min(cursorPosition,
                                                          w.maxEntryLength)
                                text = text.slice(0, w.maxEntryLength)
                                cursorPosition = keepCursor
                                w.captureNotice = "Maximum "
                                                  + w.maxEntryLength
                                                  + " characters."
                                noticeTimer.restart()
                            }
                        }
                        Keys.onPressed: function(event) {
                            if ((event.key === Qt.Key_Return
                                    || event.key === Qt.Key_Enter)
                                    && (event.modifiers
                                        & Qt.ControlModifier)) {
                                w.commitCapture()
                                event.accepted = true
                            }
                        }
                    }
                }
                PillButton {
                    label: w.expanded ? "Add" : ""; glyph: "＋"; primary: true; tint: w.effAccent
                    onClicked: w.commitCapture()
                }
            }

            Text {
                Layout.fillWidth: true
                visible: w.captureNotice.length === 0
                         && w.actionNotice.length === 0
                text: w.expanded
                      ? input.text.length + " / " + w.maxEntryLength
                        + " characters | Queue " + w.entries.length + " / "
                        + w.maxEntries + ", oldest replaced at limit"
                      : input.text.length + " / " + w.maxEntryLength
                        + " characters | " + w.entries.length + " / "
                        + w.maxEntries + " thoughts"
                color: theme.textPrimary
                opacity: 0.75
                font.pixelSize: Math.max(theme.fontMinimum, 13)
                font.bold: true
                wrapMode: Text.WordWrap
            }

            Text {
                objectName: "braindumpActionNotice"
                visible: w.captureNotice.length > 0 || w.actionNotice.length > 0
                Layout.fillWidth: true
                text: w.captureNotice.length > 0 ? w.captureNotice : w.actionNotice
                color: theme.textPrimary
                font.pixelSize: Math.max(theme.fontMinimum, 15)
                font.bold: true
                wrapMode: Text.WordWrap
                Accessible.role: Accessible.StaticText
                Accessible.name: text
            }

            PillButton {
                Layout.alignment: Qt.AlignHCenter
                visible: w.showClear
                label: w.clearArmed ? "Confirm clear " + w.entries.length
                                    : "Clear all " + w.entries.length
                glyph: w.clearArmed ? "!" : ""
                glyphIcon: w.clearArmed ? "" : "ui-trash"
                tint: w.clearArmed ? theme.warning : theme.textSecondary
                onClicked: w.requestClearAll()
            }
            PillButton {
                Layout.alignment: Qt.AlignHCenter
                visible: w.expanded && w.undoSnapshot !== null
                label: w.undoSnapshot ? w.undoSnapshot.label : "Undo"
                glyph: "↶"; tint: w.effAccent
                onClicked: w.undoLastChange()
            }
        }
    }
}
