import QtQuick
import QtQuick.Layouts

// SegmentedControl - a uniform tab/segment selector (e.g. timer modes).
Rectangle {
    id: seg
    property var options: []          // array of {label, value} or strings
    property var currentValue: options.length ? _val(options[0]) : ""
    property color tint: theme.accent
    signal selected(var value)

    function _val(o) { return (typeof o === "object") ? o.value : o }
    function _lab(o) { return (typeof o === "object") ? o.label : o }

    implicitHeight: theme.touchTertiary
    radius: height / 2
    color: Qt.rgba(0, 0, 0, 0.25)
    border.width: 1
    border.color: theme.cardBorder

    RowLayout {
        anchors.fill: parent
        anchors.margins: 3
        spacing: 3
        Repeater {
            model: seg.options
            delegate: Rectangle {
                required property var modelData
                Layout.fillWidth: true
                Layout.fillHeight: true
                radius: height / 2
                property bool active: seg._val(modelData) === seg.currentValue
                border.width: activeFocus ? 3 : 0
                border.color: theme.textPrimary
                activeFocusOnTab: true
                Accessible.role: Accessible.RadioButton
                Accessible.name: seg._lab(modelData)
                Accessible.checked: active
                Accessible.focused: activeFocus
                Accessible.onPressAction: seg.selected(seg._val(modelData))
                Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                            || event.key === Qt.Key_Space) {
                        seg.selected(seg._val(modelData))
                        event.accepted = true
                    }
                }
                color: active ? seg.tint : "transparent"
                Behavior on color { ColorAnimation { duration: theme.motionFast } }
                Text {
                    anchors.centerIn: parent
                    text: seg._lab(modelData)
                    font.pixelSize: theme.fontCaption
                    font.weight: parent.active ? Font.DemiBold : Font.Normal
                    color: parent.active ? "#0D1117" : theme.textSecondary
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    // Emit only - do NOT imperatively assign seg.currentValue, which
                    // would clobber the caller's declarative binding and stop the
                    // control from following external state changes.
                    onClicked: seg.selected(seg._val(modelData))
                }
            }
        }
    }
}
