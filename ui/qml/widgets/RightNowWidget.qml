import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// "Right Now" - one single thing to focus on (ADHD single-tasking aid).
// Persisted; the compact tile shows it large, the expanded view lets you set it.
//
// Two things here are legitimately keyed off the MODE rather than the room, and
// both stay:
//   • `showHeader: expanded` - chrome-header CONTENT, not a dimension. Tiles are
//     headerless at every size by design (the eyebrow carries the identity); the
//     overlay, a titled view of one widget, gets a header.
//   • the tile/editor split (`visible: !w.expanded` / `visible: w.expanded`) -
//     two genuinely different VIEWS, not one view at two scales. A tile displays
//     the focus; the overlay is where you type it. Room does not make a display
//     into an editor.
// Only the celebration banner was a SIZE wearing the mode's clothes - see
// celebratePx.
WidgetChrome {
    id: w
    property var metrics: ({})
    property bool expanded: false
    property bool active: true
    property var store: null
    property string instanceId: ""
    property int tick: 0

    title: "Right Now"; iconName: "rightnow"; accentColor: theme.catProductivity
    showHeader: expanded

    readonly property var cfg: {
        var _ = store ? store.revision : 0
        return (store && instanceId) ? JSON.parse(JSON.stringify(store.settingsFor(instanceId))) : ({})
    }
    readonly property string current: cfg.text || ""
    readonly property real startedAt: Number(cfg.startedAt || 0)
    property string _observedCurrent: ""
    property real _observedStartedAt: 0
    property bool _trackingCurrent: false
    readonly property string completionStyle: cfg.completionStyle || "celebrate"
    // A focus counts only if it has real (non-whitespace) content.
    readonly property bool hasFocus: current.trim().length > 0
    // Reactive on `tick` (bumped every second by the Dashboard) so it rolls over
    // at local midnight on a 24/7 device instead of freezing at load time.
    property string todayKey: (w.tick, Qt.formatDate(new Date(), "yyyy-MM-dd"))
    // Recompute the real current day here rather than trusting the todayKey
    // property: even if that ever went stale, the counter still resets correctly.
    property int finishedToday: {
        var _ = w.tick
        var key = Qt.formatDate(new Date(), "yyyy-MM-dd")
        return cfg.day === key ? (cfg.finishedToday || 0) : 0
    }
    function setText(t) {
        if (!store || t === w.current) return
        store.patchSettings(instanceId, { text: t, startedAt: t.trim().length ? Date.now() : 0 })
    }
    Component.onCompleted: {
        w._observedCurrent = w.current
        w._observedStartedAt = w.startedAt
        w._trackingCurrent = true
    }
    onCurrentChanged: {
        if (!w._trackingCurrent) return
        var previous = w._observedCurrent
        w._observedCurrent = w.current
        if (previous === w.current) return
        var shouldStart = w.current.trim().length > 0
        var expected = w.current
        var startedAtWhenTextChanged = w.startedAt
        var lifecycleSupplied = w.startedAt !== w._observedStartedAt
        w._observedStartedAt = w.startedAt
        // The Manager's schema field writes `text` without calling setText.
        // Reconcile its timer lifecycle so both editors produce the same state.
        Qt.callLater(function () {
            if (!w.store || w.current !== expected) return
            if (w.startedAt !== startedAtWhenTextChanged) return
            if (shouldStart && !lifecycleSupplied)
                w.store.setSetting(w.instanceId, "startedAt", Date.now())
            else if (!shouldStart && !lifecycleSupplied && w.startedAt !== 0)
                w.store.setSetting(w.instanceId, "startedAt", 0)
        })
    }
    onStartedAtChanged: Qt.callLater(function () {
        w._observedStartedAt = w.startedAt
    })
    function clearFocus() { if (store) store.patchSettings(instanceId, { text: "", startedAt: 0 }) }
    readonly property int elapsedSeconds: hasFocus && startedAt > 0
        ? Math.max(0, Math.floor((Date.now() - startedAt) / 1000) + (w.tick, 0)) : 0
    function elapsedLabel() {
        var m = Math.floor(elapsedSeconds / 60)
        if (m < 1) return "Started just now"
        if (m < 60) return "Focused for " + m + " min"
        var h = Math.floor(m / 60), rem = m % 60
        return "Focused for " + h + "h" + (rem ? " " + rem + "m" : "")
    }
    function startedLabel() {
        return startedAt > 0 ? Qt.formatTime(new Date(startedAt), "HH:mm") : "Not started"
    }
    property bool clearArmed: false
    function requestClear() {
        if (clearArmed) {
            clearFocus()
            clearArmed = false
        } else {
            clearArmed = true
            clearArmTimer.restart()
        }
    }
    Timer { id: clearArmTimer; interval: 3500; onTriggered: w.clearArmed = false }
    // Finishing a focus is a small win - count it and celebrate, then clear.
    // Operates on the visible text when given (Done!), else the saved focus.
    function finish(explicitText) {
        var t = explicitText !== undefined ? explicitText : w.current
        var had = t.trim().length > 0
        var patch = { text: "" }
        patch.startedAt = 0
        if (had) {
            patch.finishedToday = finishedToday + 1; patch.day = todayKey
            if (completionStyle === "celebrate") celebrateNow("Done!")
        }
        if (store) store.patchSettings(instanceId, patch)
    }

    // Celebration pop (mirrors FocusWidget).
    //
    // The banner spans the whole CARD, so the card is what sizes it. `expanded ?
    // 40 : 22` asked the wrong question and got both answers wrong: a 696x819
    // baseline tile has more room than the overlay's live-preview pane and still
    // popped at 22, while the overlay kept its 40 after W5 shrank that pane to 38%
    // of the width in landscape (~941x456 there, ~656x980 stacked in portrait).
    // Both axes bind - a wide-but-short pane must not overreach - and 40 stays the
    // designed ceiling.
    readonly property real celebratePx: Math.max(12, Math.min(width * 0.055,
                                                              height * 0.075, 40))
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
        text: w.celebrateMsg; opacity: 0
        font.pixelSize: Math.round(w.celebratePx); font.bold: true; font.family: theme.fontDisplay
        color: w.effAccent; horizontalAlignment: Text.AlignHCenter
        SequentialAnimation {
            id: celebrateAnim; running: false
            PropertyAction { target: celebrateLabel; property: "scale"; value: theme.effectiveReduceMotion ? 1 : 0.6 }
            ParallelAnimation {
                NumberAnimation { target: celebrateLabel; property: "opacity"; from: 0; to: 1; duration: theme.motionAdd }
                NumberAnimation { target: celebrateLabel; property: "scale"; to: theme.effectiveReduceMotion ? 1 : 1.12
                    duration: theme.motionPage; easing.type: theme.effectiveReduceMotion ? Easing.Linear : Easing.OutBack }
            }
            PauseAnimation { duration: 850 }
            NumberAnimation { target: celebrateLabel; property: "opacity"; to: 0; duration: theme.motionSlow }
        }
    }

    // ── Per-size layout (sizeClass is injected by Dashboard) ─────────────────
    // 0.5x0.5 and 1x1 are both "compact" (shape, not footprint); the micro
    // half-cell is told apart by the box (~344-416px short side vs ~690px+).
    readonly property bool micro: sizeClass === "compact" && Math.min(width, height) < 480
    readonly property bool horiz: sizeClass === "wide"
    readonly property bool heroRoomy: sizeClass === "large" || sizeClass === "full"
        || ((sizeClass === "tall" || sizeClass === "wide")
            && Math.min(width, height) >= 480)
    // What each size earns: micro is the focus text alone (a pure cue); every
    // larger size adds the eyebrow (identity - the header is hidden on tiles),
    // the daily momentum line, and a Done button - the single most useful
    // action, so a finished focus doesn't need a trip through the overlay.
    readonly property bool showEyebrow: !micro
    readonly property bool showDoneTile: !micro && hasFocus
    readonly property bool showCount: !micro && finishedToday > 0
    readonly property bool showElapsed: hasFocus && startedAt > 0 && !micro
    readonly property int heroMaxLines: micro ? 4 : (sizeClass === "tall" ? 5 : 4)
    readonly property int microFocusCharacterBudget: 42
    readonly property bool focusIsExcerpted:
        w.micro && w.hasFocus && w.current.trim().length > w.microFocusCharacterBudget
    readonly property string displayedFocus: {
        if (!w.hasFocus)
            return "Tap to set your one focus"
        var full = w.current.trim()
        if (!w.focusIsExcerpted)
            return full
        return full.slice(0, w.microFocusCharacterBudget - 1)
                   .replace(/\s+$/, "") + "…"
    }
    readonly property real heroMaxPx: {
        if (micro) return Math.max(36, Math.min(width * 0.145, height * 0.12, 52))
        if (sizeClass === "compact") return Math.max(42, Math.min(width * 0.082, height * 0.12, 58))
        if (horiz) return Math.max(38, Math.min(height * 0.16, width * 0.052, 54))
        return Math.max(42, Math.min(width * 0.115, height * 0.10, 60))
    }
    readonly property real heroPx: {
        var n = current.trim().length
        if (n <= 18) return heroMaxPx
        if (n <= 45) return Math.max(theme.fontTitle, heroMaxPx * 0.84)
        if (n <= 90) return Math.max(theme.fontTitle, heroMaxPx * 0.70)
        return Math.max(theme.fontTitle, heroMaxPx * 0.58)
    }

    // Tile / display mode
    GridLayout {
        id: tileLayout
        anchors.centerIn: parent
        width: parent.width * 0.92
        visible: !w.expanded
        columns: w.horiz ? 2 : 1
        columnSpacing: theme.spacingLg
        rowSpacing: w.micro ? 0 : theme.spacingSm

        ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: w.micro ? 2 : theme.spacingXs
            Text {
                objectName: "rightNowEyebrow"
                visible: w.showEyebrow
                Layout.fillWidth: true
                horizontalAlignment: w.horiz ? Text.AlignLeft : Text.AlignHCenter
                text: "RIGHT NOW"
                font.pixelSize: Math.max(theme.fontMinimum,
                                         Math.min(w.width * 0.026, theme.fontLabel))
                font.letterSpacing: 2; font.weight: Font.DemiBold
                color: w.effAccent
                elide: Text.ElideRight; maximumLineCount: 1
            }
            Text {
                objectName: "rightNowHero"
                Layout.fillWidth: true
                horizontalAlignment: w.horiz ? Text.AlignLeft : Text.AlignHCenter
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                text: w.displayedFocus
                font.pixelSize: w.hasFocus ? w.heroPx
                                           : Math.max(theme.fontLabel,
                                                      Math.min(w.width * 0.042, 22))
                font.bold: w.hasFocus
                // Hero content adopts the per-instance accent (S7); placeholder stays muted.
                color: w.hasFocus ? w.effAccent : theme.textPrimary
                opacity: w.hasFocus ? 1 : 0.78
                maximumLineCount: w.heroMaxLines
                elide: Text.ElideRight
                Accessible.name: w.hasFocus ? w.current : text
            }
            Text {
                objectName: "rightNowContinuation"
                visible: w.focusIsExcerpted
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: "Tap to read all"
                color: theme.textPrimary
                opacity: 0.78
                font.pixelSize: theme.fontMinimum
            }
            Text {
                visible: !w.hasFocus && w.heroRoomy
                Layout.fillWidth: true
                horizontalAlignment: w.horiz ? Text.AlignLeft : Text.AlignHCenter
                text: "Choose one finishable outcome. Everything else can wait."
                color: theme.textPrimary
                opacity: 0.78
                font.pixelSize: theme.fontLabel
                wrapMode: Text.WordWrap
            }
        }
        ColumnLayout {
            visible: w.showDoneTile || w.showCount
            Layout.alignment: Qt.AlignVCenter | Qt.AlignHCenter
            spacing: theme.spacingXs
            Rectangle {
                objectName: "rightNowFocusContext"
                visible: w.heroRoomy && w.hasFocus
                Layout.fillWidth: true
                Layout.preferredWidth: w.horiz ? Math.min(540, w.width * 0.43)
                                               : Math.min(620, w.width * 0.86)
                Layout.preferredHeight: 78
                radius: theme.radiusMd
                color: Qt.rgba(w.effAccent.r, w.effAccent.g, w.effAccent.b, 0.08)
                border.width: 1
                border.color: Qt.rgba(w.effAccent.r, w.effAccent.g, w.effAccent.b, 0.25)

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: theme.spacingMd
                    anchors.rightMargin: theme.spacingMd
                    spacing: theme.spacingSm
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 2
                        Text { text: "STARTED"; color: w.effAccent; font.pixelSize: theme.fontLabel
                            font.bold: true; font.letterSpacing: 1.1 }
                        Text { text: w.startedLabel(); color: theme.textPrimary
                            font.pixelSize: theme.fontLabel; font.bold: true }
                    }
                    Rectangle { Layout.preferredWidth: 1; Layout.fillHeight: true
                        Layout.topMargin: 15; Layout.bottomMargin: 15; color: theme.cardBorder }
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 2
                        Text { text: "IN FLOW"; color: w.effAccent; font.pixelSize: theme.fontLabel
                            font.bold: true; font.letterSpacing: 1.1 }
                        Text { text: w.elapsedSeconds < 60 ? "Just now"
                              : Math.floor(w.elapsedSeconds / 60) + " min"
                            color: w.effAccent; font.pixelSize: theme.fontLabel; font.bold: true }
                    }
                    Rectangle { Layout.preferredWidth: 1; Layout.fillHeight: true
                        Layout.topMargin: 15; Layout.bottomMargin: 15; color: theme.cardBorder }
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 2
                        Text { text: "FINISHED"; color: w.effAccent; font.pixelSize: theme.fontLabel
                            font.bold: true; font.letterSpacing: 1.1 }
                        Text { text: w.finishedToday + " today"; color: theme.textPrimary
                            font.pixelSize: theme.fontLabel; font.bold: true }
                    }
                }
            }
            PillButton {
                visible: w.showDoneTile
                Layout.alignment: Qt.AlignHCenter
                label: "Done"; glyph: "✓"; primary: true; tint: w.effAccent
                onClicked: w.finish()
            }
            Text {
                objectName: "rightNowCount"
                visible: w.showCount && !w.heroRoomy
                Layout.alignment: Qt.AlignHCenter
                text: "✓ " + w.finishedToday + " today"
                font.pixelSize: theme.fontLabel
                color: theme.textPrimary
                opacity: 0.78
            }
            Text {
                objectName: "rightNowElapsed"
                visible: w.showElapsed && !w.heroRoomy
                Layout.alignment: Qt.AlignHCenter
                text: w.elapsedLabel(); color: theme.textPrimary
                opacity: 0.78
                font.pixelSize: theme.fontLabel
            }
        }
    }

    // Expanded / edit mode
    ColumnLayout {
        anchors.fill: parent
        visible: w.expanded
        spacing: theme.spacingLg
        Item { Layout.fillHeight: true }
        Text {
            Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter
            text: "What's the one thing right now?"
            font.pixelSize: theme.fontTitle; color: theme.textPrimary
        }
        TextField {
            id: field
            Layout.fillWidth: true; Layout.preferredHeight: theme.touchPrimary
            text: w.current
            font.pixelSize: Math.max(theme.fontTitle, Math.min(w.width * 0.045, 32))
            horizontalAlignment: Text.AlignHCenter
            color: theme.textPrimary; placeholderText: "e.g. Finish the report"
            placeholderTextColor: theme.textTertiary
            Accessible.name: "Current focus"
            background: Rectangle { radius: theme.radiusMd; color: theme.backgroundColor
                border.color: field.activeFocus ? w.effAccent : theme.cardBorder; border.width: 2 }
            onEditingFinished: w.setText(text)
            // Resync when the focus changes elsewhere (e.g. cleared by "Done").
            Connections { target: w; function onCurrentChanged() { if (!field.activeFocus) field.text = w.current } }
        }
        Text {
            Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter
            visible: w.finishedToday > 0
            text: "✓ " + w.finishedToday + (w.finishedToday === 1 ? " thing finished today" : " things finished today")
            font.pixelSize: theme.fontLabel; color: theme.textPrimary; opacity: 0.78
        }
        RowLayout {
            Layout.alignment: Qt.AlignHCenter; spacing: theme.spacingMd
            PillButton { label: "Save"; glyph: "✓"; primary: true; tint: w.effAccent
                onClicked: w.setText(field.text) }
            PillButton { label: "Done!"; glyph: "✓"; tint: w.effAccent
                // Act on the text the user actually sees, not the stale saved value.
                enabled: field.text.trim().length > 0
                onClicked: { w.finish(field.text); field.text = "" } }
            PillButton { label: w.clearArmed ? "Confirm" : "Clear"; glyph: "✕"
                tint: w.clearArmed ? theme.warning : theme.textPrimary
                enabled: field.text.trim().length > 0
                onClicked: {
                    if (w.clearArmed) field.text = ""
                    w.requestClear()
                } }
        }
        Item { Layout.fillHeight: true }
    }

    // Tapping the compact tile opens the expanded editor (handled by the tile),
    // so no extra MouseArea is needed here.
}
