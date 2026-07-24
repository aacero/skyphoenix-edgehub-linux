import QtQuick
import QtQuick.Layouts

// Quick note / scratchpad - persisted. Uses a plain TextEdit (not Controls
// TextArea) for consistent theming and to avoid style-specific issues. The
// editor initialises from stored text and saves on edit; the compact tile
// shows a live preview via the reactive `cfg`.
//
// Sizing (W1 wave 2b): this is ONE body of text, so - exactly like a list earning
// more rows - a bigger box earns more LINES, not bigger type. The preview was a
// flat 13px at every size, which is both too small to read on a 696x819 tile and
// the same on a 348x409 one.
//   • 0.5x0.5 (micro) - headerless: at 1/12 the note itself is the tile, and 36px
//                       of chrome is a line of text you cannot spare.
//   • every other size - the preview scales gently with the box (13px in a narrow
//                       column, up to 20px in a wide one - longer lines carry
//                       bigger type) and the taller box simply shows more of them.
//   • full (overlay)  - the editor. Editing is genuinely modal, so THAT stays
//                       keyed off `expanded` rather than off size.
// This widget has the least to gain from a big box of the nine: there is no extra
// content to earn, only more of the same note.
WidgetChrome {
    id: w
    property var metrics: ({})
    property bool expanded: false
    property bool active: true
    property var store: null
    property string instanceId: ""

    title: "Quick Note"; iconName: "notes"; accentColor: theme.catInfo
    showHeader: !micro

    // ── Per-size layout (sizeClass injected by Dashboard) ────────────────────
    // The preview scales with the COLUMN (a wider column means longer lines, which
    // carry bigger type) and is capped so a big box earns more LINES, not a
    // billboard. Height only floors it - a tall narrow sliver must not inflate.
    readonly property real previewPx: Math.max(theme.fontTitle,
        Math.min(width * 0.032, height * 0.055, 24))
    readonly property real editorPx: Math.max(theme.fontTitle,
        Math.min(width * 0.034, 26))

    readonly property var cfg: {
        var _ = store ? store.revision : 0
        return (store && instanceId) ? JSON.parse(JSON.stringify(store.settingsFor(instanceId))) : ({})
    }
    readonly property string current: cfg.text || ""
    readonly property var history: Array.isArray(cfg.history) ? cfg.history : []
    readonly property int maxNoteLength: 20000
    property string noteNotice: ""
    property string _observedCurrent: ""
    property bool _trackingCurrent: false
    property bool _suppressHistoryOnce: false
    readonly property int wordCount: current.trim().length
        ? current.trim().split(/\s+/).filter(function (s) { return s.length }).length : 0
    readonly property bool roomyPreview: !expanded && !micro
        && (sizeClass === "large" || sizeClass === "full"
            || Math.min(width, height) >= 600)
    property string saveState: "saved"
    // Equality guard: a net no-op edit (type + delete back to the stored value)
    // must not bump revision / re-persist / re-broadcast to the Manager.
    function save(t) {
        if (!store) { saveState = "error"; return false }
        if (t.length > w.maxNoteLength) {
            t = t.slice(0, w.maxNoteLength)
            w.noteNotice = "Saved the first " + w.maxNoteLength + " characters."
        }
        if (t === current) { saveState = "saved"; return true }
        var prior = history.slice()
        if (current.length && (prior.length === 0 || prior[prior.length - 1] !== current)) prior.push(current)
        if (prior.length > 10) prior = prior.slice(prior.length - 10)
        store.patchSettings(instanceId, { text: t, history: prior })
        saveState = "saved"
        return true
    }
    // Debounce writes so a store save + revision bump doesn't fire on every
    // keystroke; flushed immediately when the editor closes OR is destroyed.
    property string _pending: ""
    property bool _dirty: false
    Timer { id: saveDebounce; interval: 400; onTriggered: { w.save(w._pending); w._dirty = false } }
    function flush() { if (w._dirty) { saveDebounce.stop(); w.save(w._pending); w._dirty = false } }
    // The expanded overlay creates a SEPARATE instance that is destroyed on close
    // - before onExpandedChanged/the debounce can fire - so flush here too, or the
    // last edit is silently lost.
    Component.onCompleted: {
        w._observedCurrent = w.current
        w._trackingCurrent = true
    }
    Component.onDestruction: flush()
    onCurrentChanged: {
        if (!w._trackingCurrent) return
        var priorText = w._observedCurrent
        w._observedCurrent = w.current
        if (w._suppressHistoryOnce) {
            w._suppressHistoryOnce = false
            return
        }
        if (w.current.length > w.maxNoteLength) {
            Qt.callLater(function () {
                if (w.store && w.current.length > w.maxNoteLength) {
                    w.noteNotice = "Saved the first " + w.maxNoteLength + " characters."
                    w._suppressHistoryOnce = true
                    w.store.setSetting(w.instanceId, "text",
                                       w.current.slice(0, w.maxNoteLength))
                }
            })
            return
        }
        if (!priorText.length || priorText === w.current) return
        // The schema-driven Manager writes `text` directly. If that transaction
        // did not already include history, preserve the previous body here so
        // edits from either surface remain equally undoable.
        var h = w.history.slice()
        if (h.length && h[h.length - 1] === priorText) return
        h.push(priorText)
        if (h.length > 10) h = h.slice(h.length - 10)
        Qt.callLater(function () {
            if (w.store && w.current !== priorText)
                w.store.setSetting(w.instanceId, "history", h)
        })
    }

    // Tile preview - as many lines as the box holds, at a size the box earns.
    Text {
        id: previewText
        objectName: "notesPreviewText"
        anchors.fill: parent
        anchors.leftMargin: w.micro ? theme.spacingXs : theme.spacingSm
        anchors.rightMargin: w.micro ? theme.spacingXs : theme.spacingSm
        anchors.topMargin: w.micro ? theme.spacingXs : theme.spacingSm
        anchors.bottomMargin: previewMeta.visible
                              ? previewMeta.height + theme.spacingSm
                              : (w.micro ? theme.spacingXs : theme.spacingSm)
        visible: !w.expanded && (!w.roomyPreview || w.current.trim().length > 0)
        // A whitespace-only note is effectively empty - show the placeholder.
        text: w.current.trim().length ? w.current
                                      : (w.micro ? "Jot a note…" : "Tap to jot a note…")
        color: theme.textPrimary
        opacity: w.current.trim().length ? 1 : 0.78
        font.pixelSize: Math.round(w.previewPx)
        wrapMode: Text.WordWrap; elide: Text.ElideRight
    }

    ColumnLayout {
        objectName: "notesRichEmptyState"
        anchors.centerIn: parent
        width: Math.min(parent.width * 0.78, 520)
        visible: w.roomyPreview && w.current.trim().length === 0
        spacing: theme.spacingSm
        Rectangle {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: 64; Layout.preferredHeight: 64; radius: 20
            color: Qt.rgba(w.effAccent.r, w.effAccent.g, w.effAccent.b, 0.10)
            border.width: 1
            border.color: Qt.rgba(w.effAccent.r, w.effAccent.g, w.effAccent.b, 0.28)
            Text { anchors.centerIn: parent; text: "✎"; color: w.effAccent
                font.pixelSize: 30; font.bold: true }
        }
        Text {
            Layout.fillWidth: true
            text: "Capture it before it disappears"
            color: theme.textPrimary; font.pixelSize: 22; font.bold: true
            horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
        }
        Text {
            Layout.fillWidth: true
            text: "Tap to jot a note…"
            color: theme.textSecondary; font.pixelSize: theme.fontLabel
            horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
        }
    }

    Rectangle {
        id: previewMeta
        objectName: "notesPreviewMeta"
        anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
        anchors.leftMargin: theme.spacingSm; anchors.rightMargin: theme.spacingSm
        anchors.bottomMargin: theme.spacingXs
        height: theme.touchTertiary
        // Metadata yields to the note itself. Short notes have enough spare room
        // for an edit hint; long notes spend every available line on content.
        visible: w.roomyPreview && w.current.trim().length > 0
                 && w.wordCount <= 48 && w.current.length <= 360
        radius: theme.radiusSm
        color: Qt.rgba(w.effAccent.r, w.effAccent.g, w.effAccent.b, 0.09)
        border.width: 1
        border.color: Qt.rgba(w.effAccent.r, w.effAccent.g, w.effAccent.b, 0.26)
        Accessible.role: Accessible.StaticText
        Accessible.name: w.wordCount + (w.wordCount === 1 ? " word. " : " words. ")
                         + "Tap anywhere to edit."
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: theme.spacingMd
            anchors.rightMargin: theme.spacingMd
            spacing: theme.spacingSm
            Text {
                text: w.wordCount + (w.wordCount === 1 ? " word" : " words")
                color: theme.textPrimary; opacity: 0.78
                font.pixelSize: theme.fontLabel
            }
            Item { Layout.fillWidth: true }
            Text {
                text: "✎  Tap anywhere to edit"
                color: w.effAccent
                font.pixelSize: theme.fontLabel
                font.bold: true
            }
        }
    }

    // Expanded editor
    Flickable {
        id: editorFlick
        anchors.fill: parent
        anchors.bottomMargin: editorFooter.visible
                              ? editorFooter.height + theme.spacingSm : 0
        visible: w.expanded
        contentHeight: editor.contentHeight + 12
        clip: true
        TextEdit {
            id: editor
            width: parent.width
            text: w.current
            font.pixelSize: w.editorPx; color: theme.textPrimary
            wrapMode: TextEdit.Wrap; selectByMouse: true
            persistentSelection: true
            Accessible.name: "Quick Note editor"
            onTextChanged: { w._pending = text; w._dirty = true; w.saveState = "saving"; saveDebounce.restart() }
            // Keep the caret in view as the note grows past the viewport -
            // otherwise long notes scroll off the bottom while typing.
            onCursorRectangleChanged: {
                var top = cursorRectangle.y
                var bottom = cursorRectangle.y + cursorRectangle.height
                if (top < editorFlick.contentY)
                    editorFlick.contentY = top
                else if (bottom > editorFlick.contentY + editorFlick.height)
                    editorFlick.contentY = bottom - editorFlick.height
            }
            // Re-sync from the store when (re)opened; flush pending text on close.
            Connections {
                target: w
                function onExpandedChanged() {
                    if (w.expanded) editor.text = w.current
                    else w.flush()
                }
                // An external (Manager) push bumps the store revision and changes
                // `current`; re-sync the open editor so it doesn't keep stale local
                // text and a subsequent flush can't clobber the pushed value.
                function onCurrentChanged() {
                    if (w.expanded && editor.text !== w.current) editor.text = w.current
                    w.saveState = "saved"
                }
            }
        }
        Text {
            x: editor.x; y: editor.y
            visible: editor.text.length === 0
            text: "Type anything - it saves automatically."
            color: theme.textPrimary; opacity: 0.72
            font.pixelSize: w.editorPx
        }
    }

    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: editorFooter.height + theme.spacingMd
        visible: w.expanded && w.noteNotice.length > 0
        width: parent.width * 0.8
        text: w.noteNotice
        color: theme.textPrimary
        font.pixelSize: theme.fontLabel
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
    }

    function undoLast() {
        if (!store || history.length === 0) return
        var h = history.slice(), prior = h.pop()
        store.patchSettings(instanceId, { text: prior, history: h })
        saveState = "saved"
    }
    property bool clearArmed: false
    function requestClear() {
        if (!current.length && !editor.text.length) return
        if (clearArmed) { editor.text = ""; flush(); clearArmed = false }
        else { clearArmed = true; clearTimer.restart() }
    }
    Timer { id: clearTimer; interval: 4000; onTriggered: w.clearArmed = false }

    Rectangle {
        id: editorFooter
        objectName: "notesEditorFooter"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: w.expanded
        height: theme.touchSecondary
        radius: theme.radiusSm
        color: theme.backgroundColor
        border.width: 1
        border.color: theme.cardBorder
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: theme.spacingXs
            anchors.rightMargin: theme.spacingMd
            spacing: theme.spacingSm
            PillButton {
                label: "Undo"; glyph: "↶"
                enabled: w.history.length > 0
                onClicked: w.undoLast()
            }
            PillButton {
                label: w.clearArmed ? "Confirm clear" : "Clear"; glyph: "✕"
                tint: w.clearArmed ? theme.warning : theme.textPrimary
                onClicked: w.requestClear()
            }
            Item { Layout.fillWidth: true }
            Text {
                visible: editor.text.trim().length > 0
                text: editor.text.length + " chars · "
                      + editor.text.trim().split(/\s+/).filter(function (s) {
                            return s.length
                        }).length + " words"
                color: theme.textPrimary
                opacity: 0.78
                font.pixelSize: theme.fontLabel
                elide: Text.ElideRight
                Layout.maximumWidth: Math.max(110, w.width * 0.28)
            }
            Text {
                text: w.saveState === "saving" ? "Saving…"
                    : w.saveState === "error" ? "Save failed" : "Saved"
                color: w.saveState === "error" ? theme.error : w.effAccent
                font.pixelSize: theme.fontLabel
                font.bold: true
            }
        }
    }
}
