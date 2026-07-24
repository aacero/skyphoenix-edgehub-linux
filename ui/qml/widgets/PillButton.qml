import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// PillButton - uniform, touch-friendly button used across all widgets.
//
// SIZING (why the box is what it is):
// The pill hosts two runs with genuinely different font metrics, and the box is
// derived from BOTH rather than sized for latin and hoped-for by the glyph:
//   • a latin label run - at pixelSize 18 its box is 25 tall (ascent 1.068em +
//     descent 0.293em ≈ 1.39em) and its ink sits INSIDE that box with real side
//     bearing.
//   • an emoji glyph run - Noto Color Emoji is a CBDT bitmap strike, so Qt
//     reports line height 1.0em and advance 1.0625em. At pixelSize 18 that box
//     is 19.125x18 and the ink FILLS it: measured ink bbox (2,-1)-(17,17), i.e.
//     zero bearing, overshooting the reported box by a pixel at the top.
// So an emoji has no slack to give. Two consequences are designed for here:
//   1. the glyph is sized RELATIVE to the label (below), never fixed, and
//   2. under width pressure the LABEL elides - the glyph is atomic and can only
//      be cut, so it must never be the thing that gives way.
Rectangle {
    id: btn
    property string label: ""
    property string glyph: ""
    property string glyphIcon: ""
    property color tint: theme.accent
    property bool primary: false      // filled vs. outline
    property bool danger: false
    property bool enabledState: true
    property string accessibleName: ""
    // A caller's floor for a HERO action - "this one is large, do not shrink-wrap
    // it to its text". A FLOOR, exactly like theme.touchSecondary below: content
    // wins whenever it is wider, so a longer label can never be capped by it.
    //
    // This is what `implicitWidth: <n>` at a call site was reaching for and got
    // wrong in KIND, not in value. An assigned implicitWidth is the box, full
    // stop: it silently CAPS the content it was meant to be generous to, and the
    // pill has nothing left to give - the row is bounded by btn.width (below), so
    // the label just elides inside a button that had no reason to be that narrow.
    property int minWidth: 0
    signal clicked()

    activeFocusOnTab: enabledState
    Accessible.role: Accessible.Button
    Accessible.name: accessibleName !== "" ? accessibleName
                     : (label !== "" ? label : (glyphIcon !== "" ? glyphIcon : glyph))
    Accessible.description: danger ? "Destructive action" : ""
    Accessible.onPressAction: if (btn.enabledState) btn.clicked()
    Keys.onPressed: function(event) {
        if (!btn.enabledState) return
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                || event.key === Qt.Key_Space) {
            btn.clicked()
            event.accepted = true
        }
    }

    // The glyph is a font-sized SIBLING of the label, not a fixed 18px. The label
    // is theme.fontLabel (15 * textScale, clamped 0.8-1.6), so a literal 18 froze
    // the designed 1.2x ratio at textScale 1.0: round(15 * 1.2) === 18 exactly.
    // Frozen, it left the emoji at 75% of the label at the a11y maximum and drove
    // the two runs' baselines 3.4px apart. Derived, the ratio survives the scale
    // and textScale 1.0 renders exactly as before.
    readonly property int glyphPx: Math.round(theme.fontLabel * 1.2)

    // Horizontal padding, halved from the old single spacingXl term so the total
    // (2 * 12 = 24) is unchanged - the pill keeps its current width at every
    // existing call site.
    readonly property int _padH: Math.round(theme.spacingXl / 2)

    // The touch target is a FLOOR, not the box: the height used to be a flat
    // theme.touchSecondary that referenced the content nowhere, so a scaled-up
    // label had no way to make the pill grow. Content + padding wins when it is
    // taller; touchSecondary still guarantees the tap area.
    implicitHeight: Math.max(theme.touchSecondary,
                             Math.ceil(contentRow.implicitHeight) + 2 * theme.spacingSm)
    implicitWidth: Math.max(theme.touchSecondary, btn.minWidth,
                            Math.ceil(contentRow.implicitWidth) + 2 * _padH)
    radius: height / 2
    opacity: enabledState ? 1.0 : 0.4

    property color _c: danger ? theme.error : tint
    color: primary ? _c : Qt.rgba(_c.r, _c.g, _c.b, ma.containsMouse ? 0.22 : 0.12)
    border.width: activeFocus ? 3 : (primary ? 0 : 1)
    border.color: activeFocus ? theme.textPrimary
                              : Qt.rgba(_c.r, _c.g, _c.b, 0.5)
    Accessible.focused: activeFocus
    Behavior on color { ColorAnimation { duration: theme.motionFast } }
    scale: ma.pressed && enabledState ? 0.96 : 1.0
    Behavior on scale { NumberAnimation { duration: theme.motionFast; easing.type: Easing.OutCubic } }

    RowLayout {
        id: contentRow
        anchors.centerIn: parent
        // Bounded by the pill's ACTUAL width, not just its implicit one. Normally
        // btn.width == implicitWidth so this resolves to implicitWidth and nothing
        // moves; when a caller's layout is narrower than the pill wants, the row
        // stops overflowing symmetrically (which cut the LEADING glyph off) and
        // hands the pressure to the label's elide instead.
        width: Math.min(implicitWidth, Math.max(0, btn.width - 2 * btn._padH))
        spacing: theme.spacingXs

        AppIcon {
            visible: btn.glyphIcon !== ""
            name: btn.glyphIcon
            size: btn.glyphPx
            color: btn.primary ? "#0D1117" : btn._c
            Layout.alignment: Qt.AlignVCenter
        }
        Text {
            visible: btn.glyph !== "" && btn.glyphIcon === ""
            text: btn.glyph
            font.pixelSize: btn.glyphPx
            color: btn.primary ? "#0D1117" : btn._c
            // Aligned by BASELINE, not by box centre. The two runs' boxes have
            // different heights for the same pixelSize (1.0em emoji vs ~1.39em
            // latin), so centring the boxes only coincidentally lined the glyph up
            // at textScale 1.0 and drifted 3.4px at 1.6. On the baseline the drift
            // is 0.00 at every scale.
            //
            // Deliberately NOT pinned with a Layout.minimumWidth: a RowLayout takes
            // space back from its fillWidth item first, and the label is the only
            // one, so the glyph keeps its full advance down to a 40px pill
            // (measured). A pin looked prudent and was dead code.
            Layout.alignment: Qt.AlignBaseline
        }
        Text {
            visible: btn.label !== ""
            text: btn.label
            font.pixelSize: theme.fontLabel
            font.weight: Font.DemiBold
            color: btn.primary ? "#0D1117" : theme.textPrimary
            // The label is the elastic half of the pair: it gives way so the
            // glyph never has to. fillWidth is a no-op at the natural size (the
            // row is exactly its implicitWidth) and only bites once constrained.
            elide: Text.ElideRight
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignBaseline
        }
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        enabled: btn.enabledState
        onClicked: btn.clicked()
    }
}
