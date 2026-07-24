import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// ConfigField - renders a single schema field into the right control. Reads/
// writes live through the shared store, so edits apply immediately (and, in the
// Manager, push to the Edge). `col` carries colour + sizing tokens so the SAME
// component works in the desktop Manager and the on-device (touch) config view.
//
// col keys: textPrimary, textSecondary, bg, accent, border, panelAlt
//           (+ optional ctlH = control height, fontBase = base font size)
Item {
    id: f
    objectName: "field-" + (field.key || field.type || "")   // test hook
    property var field: ({})
    property var st: null        // the store (named 'st' to avoid a self-binding
                                 // collision with the caller's `store` id)
    property string instanceId: ""
    property var col: null
    property var timeZoneBridge: null
    signal actionRequested(string action)

    // Touch/desktop sizing: larger controls on the Edge, compact in the Manager.
    readonly property real ctlH: (col && col.ctlH) ? col.ctlH : 52
    readonly property real fontBase: (col && col.fontBase) ? col.fontBase : 17
    readonly property real fontMinimum: Math.max(15, fontBase - 2)

    function conditionMatches() {
        if (!field.visibleWhen) return true
        if (!st) return false
        st.revision
        // Arrays passed through a Repeater's modelData can arrive as array-like
        // QML values for which JavaScript's Array.isArray() returns false.
        // Detect those by shape as well, or a multi-rule condition is treated as
        // one object with no key and every supposedly hidden field stays visible.
        var rawRules = field.visibleWhen
        var listLike = Array.isArray(rawRules)
                       || (rawRules.key === undefined
                           && typeof rawRules.length === "number")
        var rules = listLike ? rawRules : [rawRules]
        var settings = st.settingsFor(instanceId)
        for (var i = 0; i < rules.length; i++) {
            var rule = rules[i]
            var value = settings[rule.key]
            if (value === undefined && rule.dflt !== undefined) value = rule.dflt
            if (rule.equals !== undefined && value !== rule.equals) return false
            if (rule.notEquals !== undefined && value === rule.notEquals) return false
            if (rule.truthy === true && !value) return false
            if (rule.truthy === false && !!value) return false
        }
        return true
    }
    readonly property bool conditionVisible: conditionMatches()
    visible: conditionVisible
    implicitHeight: conditionVisible ? body.implicitHeight : 0
    Layout.fillWidth: true

    function cur() {
        if (!st) return field.dflt !== undefined ? field.dflt : ""
        st.revision
        var v = st.settingsFor(instanceId)[field.key]
        if (v !== undefined) return v
        return field.dflt !== undefined ? field.dflt : ""
    }
    function setV(v) { if (st && instanceId !== "") st.setSetting(instanceId, field.key, v) }
    // Text legible on an accent fill. Prefer a theme token so a dark accent can't
    // make selected/on labels vanish; fall back to the historic literal.
    function onAccent() { return (col && col.textOnAccent) ? col.textOnAccent : "#0D1117" }
    // Tasks values are user/IPC-sourced - coerce to an array so a corrupt (non-array)
    // stored value renders as empty instead of throwing on .slice()/Repeater.
    function curTasks() { var v = cur(); return Array.isArray(v) ? v : [] }
    function numStr() {
        var n = Number(cur())
        if (isNaN(n)) n = 0
        if (field.type === "hour") return (n < 10 ? "0" + n : n) + ":00"
        var s = (field.step && field.step < 1) ? n.toFixed(2) : String(n)
        return s + (field.suffix || "")
    }
    function validQtDatePattern(pattern) {
        var p = String(pattern || "").trim()
        if (!p.length) return false
        var inQuote = false
        var unquoted = ""
        for (var i = 0; i < p.length; i++) {
            if (p[i] === "'") {
                if (i + 1 < p.length && p[i + 1] === "'") {
                    i++
                    continue
                }
                inQuote = !inQuote
            } else if (!inQuote) {
                unquoted += p[i]
            }
        }
        return !inQuote && /[dMy]/.test(unquoted)
    }
    function qtDatePreview(pattern) {
        return validQtDatePattern(pattern) ? Qt.formatDate(new Date(), pattern) : ""
    }

    ColumnLayout {
        id: body
        width: f.width
        spacing: 5
        Text {
            visible: field.label !== undefined && field.label !== ""
            text: field.label || ""
            color: f.col.textSecondary; font.pixelSize: f.fontBase
            font.bold: true
        }
        Text {
            visible: field.help !== undefined && field.help !== ""
            text: field.help || ""
            color: f.col.textSecondary; opacity: 0.9; font.pixelSize: f.fontMinimum
            wrapMode: Text.WordWrap; Layout.fillWidth: true
        }
        Loader {
            Layout.fillWidth: true
            sourceComponent: {
                switch (field.type) {
                case "text": return textC
                case "secret": return textC
                case "textarea": return areaC
                case "number": return numberC
                case "hour": return numberC
                case "slider": return sliderC
                case "toggle": return toggleC
                case "segmented": return segC
                case "select": return selectC
                case "timezone": return timezoneC
                case "timezoneList": return timezoneListC
                case "weekdays": return weekdaysC
                case "medSchedule": return medScheduleC
                case "routineSteps": return routineStepsC
                case "accent": return accentC
                case "date": return dateC
                case "tasks": return tasksC
                case "reorder": return reorderC
                case "action": return actionC
                case "info": return infoC
                default: return infoC
                }
            }
        }
    }
    Component {
        id: selectC
        ComboBox {
            id: optionBox
            objectName: "control"
            implicitHeight: f.ctlH
            model: f.field.options || []
            textRole: "label"
            valueRole: "value"
            Accessible.name: f.field.label || "Select option"

            function storedIndex() {
                var options = f.field.options || []
                var selected = String(f.cur())
                for (var i = 0; i < options.length; i++)
                    if (String(options[i].value) === selected) return i
                return options.length ? 0 : -1
            }
            Component.onCompleted: currentIndex = storedIndex()
            onModelChanged: currentIndex = storedIndex()
            onActivated: function(index) {
                if (index >= 0 && index < model.length) f.setV(model[index].value)
            }
            Connections {
                target: f.st
                function onRevisionChanged() {
                    var next = optionBox.storedIndex()
                    if (optionBox.currentIndex !== next) optionBox.currentIndex = next
                }
            }
            contentItem: Text {
                leftPadding: 12
                rightPadding: optionBox.indicator.width + 18
                text: optionBox.displayText
                color: f.col.textPrimary
                font.pixelSize: f.fontBase
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
            }
            background: Rectangle {
                radius: 8
                color: f.col.bg
                border.width: 1
                border.color: optionBox.activeFocus ? f.col.accent : f.col.border
            }
            popup: Popup {
                y: optionBox.height + 4
                width: optionBox.width
                implicitHeight: Math.min(contentItem.implicitHeight + 8, 320)
                padding: 4
                contentItem: ListView {
                    clip: true
                    implicitHeight: contentHeight
                    model: optionBox.popup.visible ? optionBox.delegateModel : null
                    currentIndex: optionBox.highlightedIndex
                    ScrollIndicator.vertical: ScrollIndicator {}
                }
                background: Rectangle {
                    radius: 8
                    color: f.col.panelAlt
                    border.width: 1
                    border.color: f.col.border
                }
            }
            delegate: ItemDelegate {
                required property var modelData
                required property int index
                width: optionBox.width - 8
                implicitHeight: Math.max(48, f.ctlH)
                highlighted: optionBox.highlightedIndex === index
                contentItem: Text {
                    text: modelData.label
                    color: f.col.textPrimary
                    font.pixelSize: f.fontBase
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                }
                background: Rectangle {
                    radius: 7
                    color: parent.highlighted ? f.col.accent : "transparent"
                    opacity: parent.highlighted ? 0.28 : 1
                }
            }
        }
    }
    Component {
        id: timezoneC
        ComboBox {
            id: zoneBox
            objectName: "control"
            editable: true
            implicitHeight: f.ctlH
            model: {
                var bridge = f.timeZoneBridge
                if (!bridge && typeof timeZones !== "undefined") bridge = timeZones
                return bridge && bridge.ids ? [""].concat(bridge.ids()) : [""]
            }
            displayText: editText.length ? editText : "Fixed offset"
            Component.onCompleted: editText = String(f.cur())
            onAccepted: f.setV(editText.trim())
            onActivated: function (index) { f.setV(model[index]); editText = model[index] }
            contentItem: TextField {
                text: zoneBox.editText
                placeholderText: "Type or choose an IANA zone"
                color: f.col.textPrimary; placeholderTextColor: f.col.textSecondary
                font.pixelSize: f.fontBase; leftPadding: 12; rightPadding: 34
                background: null
                onTextEdited: zoneBox.editText = text
                onEditingFinished: f.setV(text.trim())
            }
            background: Rectangle { radius: 8; color: f.col.bg; border.width: 1
                border.color: zoneBox.activeFocus ? f.col.accent : f.col.border }
            Connections { target: f.st
                function onRevisionChanged() {
                    if (!zoneBox.activeFocus) zoneBox.editText = String(f.cur())
                }
            }
        }
    }

    Component {
        id: timezoneListC
        ColumnLayout {
            id: zoneList
            objectName: "timezone-list-control"
            spacing: 7
            property var values: []
            property bool syncing: false

            function parsed() {
                return String(f.cur() || "").split(",").map(function(value) {
                    return value.trim()
                }).filter(function(value, index, all) {
                    return value.length && all.indexOf(value) === index
                }).slice(0, 3)
            }
            function reload() {
                syncing = true
                var next = parsed()
                if (!next.length) next = [""]
                values = next
                syncing = false
            }
            function commit(index, value) {
                var next = values.slice(0)
                value = String(value || "").trim()
                if (value.length) next[index] = value
                else next.splice(index, 1)
                next = next.filter(function(entry, pos, all) {
                    return entry.length && all.indexOf(entry) === pos
                }).slice(0, 3)
                values = next.length ? next : [""]
                f.setV(next.join(", "))
            }
            Component.onCompleted: reload()
            Connections {
                target: f.st
                function onRevisionChanged() {
                    if (!zoneList.syncing) zoneList.reload()
                }
            }

            Repeater {
                model: zoneList.values
                delegate: RowLayout {
                    required property string modelData
                    required property int index
                    Layout.fillWidth: true
                    spacing: 7
                    ComboBox {
                        id: zoneEntry
                        objectName: "timezone-list-entry-" + index
                        Layout.fillWidth: true
                        implicitHeight: f.ctlH
                        editable: true
                        model: {
                            var bridge = f.timeZoneBridge
                            if (!bridge && typeof timeZones !== "undefined") bridge = timeZones
                            return bridge && bridge.ids ? bridge.ids() : []
                        }
                        Component.onCompleted: editText = modelData
                        onAccepted: zoneList.commit(index, editText)
                        onActivated: function(selectedIndex) {
                            editText = model[selectedIndex]
                            zoneList.commit(index, editText)
                        }
                        contentItem: TextField {
                            text: zoneEntry.editText
                            placeholderText: "Type or choose an IANA zone"
                            color: f.col.textPrimary
                            placeholderTextColor: f.col.textSecondary
                            font.pixelSize: f.fontBase
                            leftPadding: 12
                            rightPadding: 34
                            background: null
                            onTextEdited: zoneEntry.editText = text
                            onEditingFinished: zoneList.commit(index, text)
                        }
                        background: Rectangle {
                            radius: 8
                            color: f.col.bg
                            border.width: 1
                            border.color: zoneEntry.activeFocus ? f.col.accent : f.col.border
                        }
                    }
                    Rectangle {
                        Layout.preferredWidth: f.ctlH
                        Layout.preferredHeight: f.ctlH
                        radius: 9
                        color: removeArea.pressed ? f.col.accent : f.col.panelAlt
                        border.width: 1
                        border.color: f.col.border
                        AppIcon {
                            anchors.centerIn: parent
                            name: "ui-minus"
                            size: 18
                            color: f.col.textPrimary
                        }
                        MouseArea {
                            id: removeArea
                            objectName: "timezone-list-remove-" + index
                            anchors.fill: parent
                            Accessible.name: "Remove additional time zone " + (index + 1)
                            onClicked: zoneList.commit(index, "")
                        }
                    }
                }
            }

            Rectangle {
                objectName: "timezone-list-add"
                visible: zoneList.values.length < 3
                Layout.fillWidth: true
                Layout.preferredHeight: f.ctlH
                radius: 9
                color: addArea.pressed ? f.col.accent : f.col.panelAlt
                border.width: 1
                border.color: f.col.border
                RowLayout {
                    anchors.centerIn: parent
                    spacing: 8
                    AppIcon { name: "ui-plus"; size: 18; color: f.col.textPrimary }
                    Text {
                        text: "Add time zone"
                        color: f.col.textPrimary
                        font.pixelSize: f.fontBase
                        font.bold: true
                    }
                }
                MouseArea {
                    id: addArea
                    anchors.fill: parent
                    Accessible.name: "Add another time zone"
                    onClicked: {
                        var next = zoneList.values.slice(0)
                        next.push("")
                        zoneList.values = next.slice(0, 3)
                    }
                }
            }
        }
    }

    // ── Controls ──
    Component {
        id: textC
        ColumnLayout {
            spacing: 5
            TextField {
                id: txtIn
                objectName: "control"
                Layout.fillWidth: true
                implicitHeight: f.ctlH
                text: f.cur()
                placeholderText: f.field.placeholder || ""
                color: f.col.textPrimary; placeholderTextColor: f.col.textSecondary
                font.pixelSize: f.fontBase
                echoMode: f.field.type === "secret" ? TextInput.Password : TextInput.Normal
                leftPadding: 12; rightPadding: 12
                readonly property bool validInput:
                    f.field.validator !== "qtDatePattern" || f.validQtDatePattern(text)
                background: Rectangle { radius: 8; color: f.col.bg; border.width: 1
                    border.color: !parent.validInput ? theme.warning
                                  : parent.activeFocus ? f.col.accent : f.col.border }
                onEditingFinished: {
                    if (validInput) f.setV(text)
                }
                // S2: typing severs the `text:` binding, so re-assert from the store on
                // any external push (Manager live mirror / geocode) when not being edited.
                Connections { target: f.st
                    function onRevisionChanged() { if (!txtIn.activeFocus) txtIn.text = f.cur() } }
            }
            Text {
                objectName: "field-preview"
                visible: f.field.preview === "qtDatePattern"
                Layout.fillWidth: true
                text: txtIn.validInput
                      ? "Preview: " + f.qtDatePreview(txtIn.text)
                      : "Enter a date pattern with d, M, or y and balanced quotes."
                color: txtIn.validInput ? f.col.textSecondary : theme.warning
                font.pixelSize: f.fontMinimum
                wrapMode: Text.WordWrap
            }
        }
    }
    Component {
        id: areaC
        Rectangle {
            implicitHeight: 150; radius: 8; color: f.col.bg; border.width: 1
            border.color: ta.activeFocus ? f.col.accent : f.col.border
            ScrollView {
                anchors.fill: parent; anchors.margins: 6; clip: true
                // Dark, token-styled scrollbar (default Fusion bar clashes on the dark UI).
                ScrollBar.vertical: ScrollBar {
                    id: areaSb
                    contentItem: Rectangle {
                        implicitWidth: 5; radius: 3
                        color: areaSb.pressed ? f.col.accent : f.col.border
                        opacity: areaSb.active ? 0.9 : 0.35
                    }
                    background: Rectangle {
                        implicitWidth: 5; radius: 3; color: f.col.panelAlt
                        opacity: areaSb.active ? 0.4 : 0
                    }
                }
                TextArea {
                    id: ta
                    text: f.cur(); wrapMode: TextArea.Wrap
                    placeholderText: f.field.placeholder || ""
                    color: f.col.textPrimary; placeholderTextColor: f.col.textSecondary
                    font.pixelSize: f.fontBase; background: null
                    // Commit on blur, not on every keystroke - otherwise each character
                    // bumps store.revision and re-runs every revision-bound binding.
                    onActiveFocusChanged: if (!activeFocus && text !== f.cur()) f.setV(text)
                    // S2: re-assert from the store on external pushes when not editing.
                    Connections { target: f.st
                        function onRevisionChanged() { if (!ta.activeFocus) ta.text = f.cur() } }
                }
            }
        }
    }
    Component {
        id: numberC
        RowLayout {
            spacing: 10
            function step() { return f.field.step || 1 }
            function clamp(v) {
                var isHour = f.field.type === "hour"
                var lo = f.field.min !== undefined ? f.field.min : (isHour ? 0 : -1e9)
                var hi = f.field.max !== undefined ? f.field.max : (isHour ? 23 : 1e9)
                return Math.max(lo, Math.min(hi, v))
            }
            // Snap to the field's step precision so sub-1 steps (lat/lon, 0.01)
            // don't accumulate binary FP error into the persisted config.
            function snap(v) {
                var s = step()
                if (s < 1) {
                    var frac = String(s).split(".")[1]
                    return Number(v.toFixed(frac ? frac.length : 2))
                }
                return Math.round(v)
            }
            Rectangle {
                Layout.preferredWidth: f.ctlH; Layout.preferredHeight: f.ctlH
                radius: 10; color: dec.pressed ? f.col.accent : f.col.panelAlt; border.width: 1; border.color: f.col.border
                AppIcon { anchors.centerIn: parent; name: "ui-minus"; size: 18; color: f.col.textPrimary }
                MouseArea {
                    id: dec
                    objectName: "numberDecrement"
                    anchors.fill: parent
                    Accessible.role: Accessible.Button
                    Accessible.name: "Decrease " + (f.field.label || "value")
                    Accessible.onPressAction: clicked(null)
                    onClicked: f.setV(parent.parent.snap(parent.parent.clamp(Number(f.cur()) - parent.parent.step())))
                }
            }
            Rectangle {
                Layout.fillWidth: true; Layout.preferredHeight: f.ctlH; radius: 10
                color: f.col.bg; border.width: 1
                border.color: numIn.activeFocus ? f.col.accent : f.col.border
                // Keyboard entry path - steppers alone can't reach e.g. lat/lon at
                // step 0.01. Typed input is parsed, clamped and snapped on commit.
                TextField {
                    id: numIn
                    anchors.fill: parent
                    text: f.numStr()
                    horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                    color: f.col.textPrimary; font.pixelSize: f.fontBase + 3; font.bold: true
                    background: null; selectByMouse: true
                    inputMethodHints: Qt.ImhFormattedNumbersOnly
                    onEditingFinished: {
                        var raw = String(text)
                        var n = (f.field.type === "hour") ? parseInt(raw, 10)
                                                          : parseFloat(raw.replace(/[^0-9.eE+\-]/g, ""))
                        // Reject NaN AND non-finite (e.g. "1e400" → Infinity) before
                        // clamp/snap, so a bad parse can't persist ±Infinity.
                        if (!isFinite(n)) { text = f.numStr(); return }
                        f.setV(parent.parent.snap(parent.parent.clamp(n)))
                    }
                    // S2: re-assert the display after a stepper/external push (typing
                    // severs the `text:` binding).
                    Connections { target: f.st
                        function onRevisionChanged() { if (!numIn.activeFocus) numIn.text = f.numStr() } }
                }
            }
            Rectangle {
                Layout.preferredWidth: f.ctlH; Layout.preferredHeight: f.ctlH
                radius: 10; color: inc.pressed ? f.col.accent : f.col.panelAlt; border.width: 1; border.color: f.col.border
                AppIcon { anchors.centerIn: parent; name: "ui-plus"; size: 18; color: f.col.textPrimary }
                MouseArea {
                    id: inc
                    objectName: "numberIncrement"
                    anchors.fill: parent
                    Accessible.role: Accessible.Button
                    Accessible.name: "Increase " + (f.field.label || "value")
                    Accessible.onPressAction: clicked(null)
                    onClicked: f.setV(parent.parent.snap(parent.parent.clamp(Number(f.cur()) + parent.parent.step())))
                }
            }
        }
    }
    Component {
        id: sliderC
        RowLayout {
            spacing: 12
            Slider {
                id: sld
                objectName: "control"
                Layout.fillWidth: true; implicitHeight: f.ctlH
                from: f.field.min || 0; to: f.field.max || 100; stepSize: f.field.step || 1
                value: Number(f.cur())
                onMoved: f.setV(value)
                // Dark groove + accent-filled portion (mirrors the MSwitch/MButton
                // token look instead of the pale default Fusion slider).
                background: Rectangle {
                    objectName: "groove"
                    x: sld.leftPadding; y: sld.topPadding + sld.availableHeight / 2 - height / 2
                    width: sld.availableWidth; height: 6; radius: 3
                    color: f.col.panelAlt
                    Rectangle {
                        objectName: "grooveFill"
                        width: sld.visualPosition * parent.width; height: parent.height
                        radius: 3; color: f.col.accent
                    }
                }
                handle: Rectangle {
                    objectName: "handle"
                    x: sld.leftPadding + sld.visualPosition * (sld.availableWidth - width)
                    y: sld.topPadding + sld.availableHeight / 2 - height / 2
                    width: 20; height: 20; radius: 10
                    color: sld.pressed ? Qt.lighter(f.col.accent, 1.15) : f.col.accent
                    border.width: 1; border.color: f.col.border
                }
            }
            Text { text: f.cur() + (f.field.suffix || ""); color: f.col.accent
                font.pixelSize: f.fontBase + 1; font.bold: true; Layout.preferredWidth: 90; horizontalAlignment: Text.AlignRight }
        }
    }
    Component {
        id: toggleC
        // Token-styled toggle mirroring the Manager's MSwitch: accent track when on,
        // dark panelAlt track when off, so it matches the app design in both hosts
        // instead of the pale default Fusion switch. Behaviour/signals unchanged.
        Switch {
            id: sw
            objectName: "control"
            checked: f.cur() === true
            onToggled: f.setV(checked)
            implicitHeight: f.ctlH
            padding: 0
            indicator: Rectangle {
                objectName: "track"
                implicitHeight: Math.max(26, f.ctlH * 0.5)
                implicitWidth: implicitHeight * 1.85
                x: sw.leftPadding; anchors.verticalCenter: parent.verticalCenter
                radius: height / 2
                color: sw.checked ? f.col.accent : f.col.panelAlt
                border.width: 1; border.color: sw.checked ? f.col.accent : f.col.border
                Behavior on color { ColorAnimation { duration: 120 } }
                Rectangle {
                    objectName: "knob"
                    width: parent.height - 6; height: width; radius: height / 2
                    y: 3
                    x: sw.checked ? parent.width - width - 3 : 3
                    color: sw.checked ? f.onAccent() : f.col.textSecondary
                    Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                }
            }
        }
    }
    Component {
        id: segC
        // A JOINED segmented control (one bordered track, segments inside), matching
        // the Manager's MSegment and the app's SegmentedControl - reads as "pick one
        // of a set" rather than the old row of loose pills. Selected = accent fill;
        // uses the shared f.col tokens so it themes for both the hub and the Manager.
        Rectangle {
            // Track wraps the segments (content-sized, +6 for the 3px margins) rather
            // than the segments filling the track - so each chip keeps its explicit
            // touch height even where the parent has no resolved height (e.g. a config
            // column that sizes to content), exactly like the accent swatches.
            implicitHeight: segRow.implicitHeight + 6
            radius: 10
            color: f.col.bg
            border.width: 1; border.color: f.col.border
            RowLayout {
                id: segRow
                anchors.left: parent.left; anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 3; anchors.rightMargin: 3; spacing: 3
                Repeater {
                    model: f.field.options || []
                    delegate: Rectangle {
                        required property var modelData
                        // Explicit touch height, independent of the parent -
                        // the width still fills the track evenly across the segments.
                        Layout.fillWidth: true
                        implicitHeight: Math.max(48, f.ctlH - 2)
                        radius: 8
                        property bool sel: f.cur() === modelData.value
                        color: sel ? f.col.accent
                                   : (segMA.containsMouse ? f.col.panelAlt : "transparent")
                        Behavior on color { ColorAnimation { duration: 120 } }
                        scale: segMA.pressed ? 0.97 : 1.0
                        Behavior on scale { NumberAnimation { duration: 90 } }
                        Text {
                            anchors.centerIn: parent; text: modelData.label
                            width: parent.width - 8; horizontalAlignment: Text.AlignHCenter
                            elide: Text.ElideRight
                            color: parent.sel ? f.onAccent() : f.col.textPrimary
                            font.pixelSize: f.fontBase - 1; font.bold: parent.sel
                        }
                        MouseArea { id: segMA; anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: f.setV(modelData.value) }
                    }
                }
            }
        }
    }
    Component {
        id: weekdaysC
        GridLayout {
            id: weekdayGrid
            objectName: "weekday-control"
            columns: width >= 560 ? 7 : 4
            columnSpacing: 6
            rowSpacing: 6

            readonly property var days: [
                { value: "0", shortLabel: "Sun", label: "Sunday" },
                { value: "1", shortLabel: "Mon", label: "Monday" },
                { value: "2", shortLabel: "Tue", label: "Tuesday" },
                { value: "3", shortLabel: "Wed", label: "Wednesday" },
                { value: "4", shortLabel: "Thu", label: "Thursday" },
                { value: "5", shortLabel: "Fri", label: "Friday" },
                { value: "6", shortLabel: "Sat", label: "Saturday" }
            ]

            function selectedValues() {
                return String(f.cur() || "").split(",").map(function(value) {
                    return String(value).trim()
                }).filter(function(value, index, all) {
                    return /^[0-6]$/.test(value) && all.indexOf(value) === index
                })
            }
            function toggle(value) {
                var selected = selectedValues()
                var index = selected.indexOf(value)
                if (index >= 0) selected.splice(index, 1)
                else selected.push(value)
                selected.sort(function(a, b) { return Number(a) - Number(b) })
                f.setV(selected.join(","))
            }

            Repeater {
                model: weekdayGrid.days
                delegate: Rectangle {
                    required property var modelData
                    objectName: "weekday-" + modelData.value
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.max(48, f.ctlH - 2)
                    radius: 9
                    property bool sel: weekdayGrid.selectedValues().indexOf(modelData.value) >= 0
                    color: sel ? f.col.accent
                               : (weekdayArea.containsMouse ? f.col.panelAlt : f.col.bg)
                    border.width: 1
                    border.color: sel ? f.col.accent : f.col.border

                    Text {
                        anchors.centerIn: parent
                        text: modelData.shortLabel
                        color: parent.sel ? f.onAccent() : f.col.textPrimary
                        font.pixelSize: f.fontMinimum
                        font.bold: parent.sel
                    }
                    MouseArea {
                        id: weekdayArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        Accessible.role: Accessible.CheckBox
                        Accessible.name: modelData.label
                        Accessible.checked: parent.sel
                        onClicked: weekdayGrid.toggle(modelData.value)
                    }
                }
            }
        }
    }
    Component {
        id: medScheduleC
        ColumnLayout {
            id: medSchedule
            objectName: "med-schedule-control"
            spacing: 10

            readonly property var dayDefs: [
                { value: "0", label: "Sun" }, { value: "1", label: "Mon" },
                { value: "2", label: "Tue" }, { value: "3", label: "Wed" },
                { value: "4", label: "Thu" }, { value: "5", label: "Fri" },
                { value: "6", label: "Sat" }
            ]

            function legacyEntries() {
                if (!f.st || !f.field.legacyKey) return []
                var settings = f.st.settingsFor(f.instanceId)
                var text = String(settings[f.field.legacyKey] || "")
                var lines = text.split("\n")
                var result = []
                var occurrences = ({})
                for (var i = 0; i < lines.length; i++) {
                    var line = lines[i].trim()
                    if (!line.length) continue
                    var match = /^(\d{1,2}):(\d{2})\s*(.*)$/.exec(line)
                    var occurrence = occurrences[line] || 0
                    occurrences[line] = occurrence + 1
                    result.push({
                        id: occurrence === 0 ? line : line + "\u001f" + (occurrence + 1),
                        time: match ? (("0" + match[1]).slice(-2) + ":" + match[2]) : "",
                        name: match && match[3].trim().length ? match[3].trim() : line,
                        days: "0,1,2,3,4,5,6"
                    })
                }
                return result
            }
            function entries() {
                var raw = f.cur()
                if (Array.isArray(raw) && raw.length) return raw
                return legacyEntries()
            }
            function normalized(entry, index) {
                var days = String(entry.days !== undefined ? entry.days : "0,1,2,3,4,5,6")
                return {
                    id: String(entry.id || ("dose-" + index)),
                    time: String(entry.time || ""),
                    name: String(entry.name || "").trim(),
                    days: days
                }
            }
            function commit(entries) {
                var clean = []
                for (var i = 0; i < entries.length; i++) {
                    var item = normalized(entries[i], i)
                    if (item.name.length) clean.push(item)
                }
                if (f.st && f.instanceId !== "" && f.field.migrationMarker) {
                    var patch = ({})
                    patch[f.field.key] = clean
                    patch[f.field.migrationMarker] = "structured"
                    f.st.patchSettings(f.instanceId, patch)
                } else {
                    f.setV(clean)
                }
            }
            function addDose() {
                var next = entries().slice(0)
                next.push({ id: "dose-" + Date.now() + "-" + next.length,
                              time: "08:00", name: "New dose",
                              days: "0,1,2,3,4,5,6" })
                commit(next)
            }
            function updateDose(index, key, value) {
                var next = entries().map(function(entry, pos) {
                    return normalized(entry, pos)
                })
                if (index < 0 || index >= next.length) return
                next[index][key] = value
                commit(next)
            }
            function removeDose(index) {
                var next = entries().slice(0)
                if (index >= 0 && index < next.length) next.splice(index, 1)
                commit(next)
            }
            function selectedDays(entry) {
                return String(entry.days !== undefined ? entry.days : "0,1,2,3,4,5,6")
                    .split(",").map(function(value) { return value.trim() })
                    .filter(function(value, pos, all) {
                        return /^[0-6]$/.test(value) && all.indexOf(value) === pos
                    })
            }
            function toggleDay(index, value) {
                var next = entries().map(function(entry, pos) {
                    return normalized(entry, pos)
                })
                if (index < 0 || index >= next.length) return
                var selected = selectedDays(next[index])
                var pos = selected.indexOf(value)
                if (pos >= 0) selected.splice(pos, 1)
                else selected.push(value)
                selected.sort(function(a, b) { return Number(a) - Number(b) })
                next[index].days = selected.join(",")
                commit(next)
            }

            Repeater {
                model: {
                    var _ = f.st ? f.st.revision : 0
                    return medSchedule.entries()
                }
                delegate: Rectangle {
                    id: doseCard
                    required property int index
                    required property var modelData
                    readonly property int doseIndex: index
                    readonly property var doseData: modelData
                    objectName: "med-schedule-row-" + index
                    Layout.fillWidth: true
                    implicitHeight: doseColumn.implicitHeight + 20
                    radius: 10
                    color: f.col.bg
                    border.width: 1
                    border.color: f.col.border

                    ColumnLayout {
                        id: doseColumn
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: 10
                        spacing: 8

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            TextField {
                                id: doseTime
                                objectName: "med-schedule-time-" + index
                                Layout.preferredWidth: 112
                                implicitHeight: f.ctlH
                                text: String(modelData.time || "")
                                placeholderText: "HH:MM"
                                inputMethodHints: Qt.ImhTime
                                color: f.col.textPrimary
                                placeholderTextColor: f.col.textSecondary
                                font.pixelSize: f.fontBase
                                validator: RegularExpressionValidator {
                                    regularExpression: /^$|^([01]\d|2[0-3]):[0-5]\d$/
                                }
                                background: Rectangle {
                                    radius: 8
                                    color: f.col.panelAlt
                                    border.width: 1
                                    border.color: doseTime.acceptableInput
                                                  ? (doseTime.activeFocus ? f.col.accent : f.col.border)
                                                  : theme.warning
                                }
                                onEditingFinished: {
                                    if (acceptableInput)
                                        medSchedule.updateDose(index, "time", text)
                                }
                            }
                            TextField {
                                id: doseName
                                objectName: "med-schedule-name-" + index
                                Layout.fillWidth: true
                                implicitHeight: f.ctlH
                                text: String(modelData.name || "")
                                placeholderText: "Dose name"
                                color: f.col.textPrimary
                                placeholderTextColor: f.col.textSecondary
                                font.pixelSize: f.fontBase
                                background: Rectangle {
                                    radius: 8
                                    color: f.col.panelAlt
                                    border.width: 1
                                    border.color: doseName.activeFocus ? f.col.accent : f.col.border
                                }
                                onEditingFinished: medSchedule.updateDose(index, "name", text)
                            }
                            Rectangle {
                                Layout.preferredWidth: f.ctlH
                                Layout.preferredHeight: f.ctlH
                                radius: 8
                                color: removeDoseArea.pressed ? f.col.accent : f.col.panelAlt
                                border.width: 1
                                border.color: f.col.border
                                AppIcon {
                                    anchors.centerIn: parent
                                    name: "ui-minus"
                                    size: 18
                                    color: f.col.textPrimary
                                }
                                MouseArea {
                                    id: removeDoseArea
                                    objectName: "med-schedule-remove-" + index
                                    anchors.fill: parent
                                    Accessible.role: Accessible.Button
                                    Accessible.name: "Remove " + String(modelData.name || "dose")
                                    onClicked: medSchedule.removeDose(index)
                                }
                            }
                        }

                        Text {
                            text: "Repeat on"
                            color: f.col.textSecondary
                            font.pixelSize: f.fontMinimum
                            font.bold: true
                        }
                        GridLayout {
                            Layout.fillWidth: true
                            columns: width >= 540 ? 7 : 4
                            columnSpacing: 5
                            rowSpacing: 5
                            Repeater {
                                model: medSchedule.dayDefs
                                delegate: Rectangle {
                                    required property var modelData
                                    objectName: "med-schedule-day-" + doseCard.doseIndex
                                                + "-" + modelData.value
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: Math.max(44, f.ctlH - 4)
                                    radius: 8
                                    property bool sel:
                                        medSchedule.selectedDays(doseCard.doseData)
                                            .indexOf(modelData.value) >= 0
                                    color: sel ? f.col.accent : f.col.panelAlt
                                    border.width: 1
                                    border.color: sel ? f.col.accent : f.col.border
                                    Text {
                                        anchors.centerIn: parent
                                        text: modelData.label
                                        color: parent.sel ? f.onAccent() : f.col.textPrimary
                                        font.pixelSize: f.fontMinimum
                                        font.bold: parent.sel
                                    }
                                    MouseArea {
                                        anchors.fill: parent
                                        Accessible.role: Accessible.CheckBox
                                        Accessible.name: modelData.label + " for "
                                                         + String(doseCard.doseData.name || "dose")
                                        Accessible.checked: parent.sel
                                        onClicked: medSchedule.toggleDay(
                                            doseCard.doseIndex,
                                            modelData.value)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Rectangle {
                objectName: "med-schedule-add"
                Layout.fillWidth: true
                Layout.preferredHeight: f.ctlH
                radius: 9
                color: addDoseArea.pressed ? f.col.accent : f.col.panelAlt
                border.width: 1
                border.color: f.col.accent
                RowLayout {
                    anchors.centerIn: parent
                    spacing: 8
                    AppIcon { name: "ui-plus"; size: 18; color: f.col.textPrimary }
                    Text {
                        text: "Add dose"
                        color: f.col.textPrimary
                        font.pixelSize: f.fontBase
                        font.bold: true
                    }
                }
                MouseArea {
                    id: addDoseArea
                    anchors.fill: parent
                    Accessible.role: Accessible.Button
                    Accessible.name: "Add a scheduled dose"
                    onClicked: medSchedule.addDose()
                }
            }
        }
    }
    Component {
        id: routineStepsC
        ColumnLayout {
            id: routineSteps
            objectName: "routine-steps-control"
            spacing: 7

            function legacyEntries() {
                if (!f.st || !f.field.legacyKey) return []
                var settings = f.st.settingsFor(f.instanceId)
                var lines = String(settings[f.field.legacyKey] || "").split("\n")
                var result = []
                var occurrences = ({})
                for (var i = 0; i < lines.length; i++) {
                    var text = lines[i].trim()
                    if (!text.length) continue
                    var occurrence = occurrences[text] || 0
                    occurrences[text] = occurrence + 1
                    result.push({
                        id: occurrence === 0 ? text : text + "\u001f" + (occurrence + 1),
                        text: text
                    })
                }
                return result
            }
            function entries() {
                var raw = f.cur()
                if (Array.isArray(raw) && raw.length) return raw
                if (f.st && f.field.migrationMarker
                        && f.st.settingsFor(f.instanceId)[f.field.migrationMarker]
                           === "structured")
                    return []
                return legacyEntries()
            }
            function normalize(entry, index) {
                return {
                    id: String(entry.id || ("routine-" + index)),
                    text: String(entry.text || "").trim()
                }
            }
            function commit(entries) {
                var clean = []
                for (var i = 0; i < entries.length; i++) {
                    var item = normalize(entries[i], i)
                    if (item.text.length) clean.push(item)
                }
                if (!f.st || f.instanceId === "") return
                var patch = ({})
                patch[f.field.key] = clean
                if (f.field.migrationMarker)
                    patch[f.field.migrationMarker] = "structured"
                f.st.patchSettings(f.instanceId, patch)
            }
            function update(index, text) {
                var next = entries().map(function(entry, pos) {
                    return normalize(entry, pos)
                })
                if (index < 0 || index >= next.length) return
                next[index].text = String(text || "").trim()
                commit(next)
            }
            function move(index, delta) {
                var next = entries().map(function(entry, pos) {
                    return normalize(entry, pos)
                })
                var target = index + delta
                if (index < 0 || target < 0 || index >= next.length
                        || target >= next.length) return
                var item = next[index]
                next[index] = next[target]
                next[target] = item
                commit(next)
            }
            function remove(index) {
                var next = entries().slice(0)
                if (index >= 0 && index < next.length) next.splice(index, 1)
                commit(next)
            }
            function add(text) {
                text = String(text || "").trim()
                if (!text.length) return
                var next = entries().map(function(entry, pos) {
                    return normalize(entry, pos)
                })
                next.push({
                    id: "routine-" + Date.now() + "-" + next.length,
                    text: text
                })
                commit(next)
            }

            Repeater {
                model: {
                    var _ = f.st ? f.st.revision : 0
                    return routineSteps.entries()
                }
                delegate: Rectangle {
                    id: routineRow
                    required property int index
                    required property var modelData
                    objectName: "routine-config-row-" + index
                    Layout.fillWidth: true
                    implicitHeight: Math.max(52, f.ctlH)
                    radius: 8
                    color: f.col.bg
                    border.width: 1
                    border.color: f.col.border

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        spacing: 5
                        TextField {
                            objectName: "routine-config-text-" + routineRow.index
                            Layout.fillWidth: true
                            implicitHeight: Math.max(48, f.ctlH - 4)
                            text: String(routineRow.modelData.text || "")
                            color: f.col.textPrimary
                            font.pixelSize: f.fontBase
                            Accessible.name: "Edit routine step "
                                             + (routineRow.index + 1)
                            background: Rectangle {
                                radius: 7
                                color: f.col.panelAlt
                                border.width: 1
                                border.color: parent.activeFocus
                                              ? f.col.accent : f.col.border
                            }
                            onEditingFinished:
                                routineSteps.update(routineRow.index, text)
                        }
                        Button {
                            objectName: "routine-config-up-" + routineRow.index
                            Layout.preferredWidth: f.ctlH
                            Layout.preferredHeight: f.ctlH
                            enabled: routineRow.index > 0
                            text: "↑"
                            Accessible.name: "Move step " + (routineRow.index + 1) + " up"
                            onClicked: routineSteps.move(routineRow.index, -1)
                        }
                        Button {
                            objectName: "routine-config-down-" + routineRow.index
                            Layout.preferredWidth: f.ctlH
                            Layout.preferredHeight: f.ctlH
                            enabled: routineRow.index < routineSteps.entries().length - 1
                            text: "↓"
                            Accessible.name: "Move step " + (routineRow.index + 1) + " down"
                            onClicked: routineSteps.move(routineRow.index, 1)
                        }
                        Rectangle {
                            objectName: "routine-config-remove-" + routineRow.index
                            Layout.preferredWidth: f.ctlH
                            Layout.preferredHeight: f.ctlH
                            radius: 7
                            color: removeRoutineArea.pressed
                                   ? f.col.accent : f.col.panelAlt
                            border.width: 1
                            border.color: f.col.border
                            AppIcon {
                                anchors.centerIn: parent
                                name: "ui-trash"
                                size: 18
                                color: f.col.textPrimary
                            }
                            MouseArea {
                                id: removeRoutineArea
                                anchors.fill: parent
                                Accessible.role: Accessible.Button
                                Accessible.name: "Remove step "
                                                 + (routineRow.index + 1)
                                onClicked: routineSteps.remove(routineRow.index)
                            }
                        }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 7
                TextField {
                    id: newRoutineStep
                    objectName: "routine-config-add-text"
                    Layout.fillWidth: true
                    implicitHeight: f.ctlH
                    placeholderText: "Add a routine step"
                    color: f.col.textPrimary
                    placeholderTextColor: f.col.textSecondary
                    font.pixelSize: f.fontBase
                    background: Rectangle {
                        radius: 8
                        color: f.col.bg
                        border.width: 1
                        border.color: parent.activeFocus
                                      ? f.col.accent : f.col.border
                    }
                    function commit() {
                        routineSteps.add(text)
                        text = ""
                    }
                    onAccepted: commit()
                }
                Rectangle {
                    objectName: "routine-config-add"
                    Layout.preferredWidth: 76
                    Layout.preferredHeight: f.ctlH
                    radius: 8
                    color: addRoutineArea.pressed ? f.col.accent : f.col.panelAlt
                    border.width: 1
                    border.color: f.col.accent
                    Text {
                        anchors.centerIn: parent
                        text: "Add"
                        color: f.col.textPrimary
                        font.pixelSize: f.fontBase
                        font.bold: true
                    }
                    MouseArea {
                        id: addRoutineArea
                        anchors.fill: parent
                        Accessible.role: Accessible.Button
                        Accessible.name: "Add routine step"
                        onClicked: newRoutineStep.commit()
                    }
                }
            }
        }
    }
    // Accent-colour swatches (theme presets) + a "Default" (no override) chip.
    Component {
        id: accentC
        Flow {
            spacing: 8
            Rectangle {
                width: f.ctlH; height: f.ctlH; radius: 10
                property bool sel: f.cur() === "" || f.cur() === undefined
                color: f.col.panelAlt; border.width: sel ? 3 : 1
                border.color: sel ? f.col.accent : f.col.border
                Text { anchors.centerIn: parent; text: "Auto"; color: f.col.textSecondary
                    font.pixelSize: f.fontMinimum }
                MouseArea { anchors.fill: parent; onClicked: f.setV("") }
            }
            Repeater {
                model: Object.keys(theme.accentPresets)
                delegate: Rectangle {
                    required property var modelData
                    width: f.ctlH; height: f.ctlH; radius: 10
                    property bool sel: f.cur() === modelData
                    color: theme.accentPresets[modelData].a
                    border.width: sel ? 3 : 1; border.color: sel ? "#FFFFFF" : f.col.border
                    MouseArea { anchors.fill: parent; onClicked: f.setV(modelData) }
                }
            }
        }
    }
    Component {
        id: dateC
        TextField {
            id: dateIn
            implicitHeight: f.ctlH
            text: f.cur(); inputMask: "9999-99-99"
            placeholderText: "YYYY-MM-DD"
            color: f.col.textPrimary; placeholderTextColor: f.col.textSecondary; font.pixelSize: f.fontBase
            leftPadding: 12
            // The mask restricts to digits but still allows impossible dates
            // (2026-19-45); the validator rejects out-of-range month/day and keeps
            // partial input in the Intermediate state (feedback, not committed).
            validator: RegularExpressionValidator {
                regularExpression: /^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/ }
            background: Rectangle { radius: 8; color: f.col.bg; border.width: 1
                border.color: parent.activeFocus ? f.col.accent : f.col.border }
            onEditingFinished: f.setV(text)
            // S2: re-assert from the store on external pushes when not editing.
            Connections { target: f.st
                function onRevisionChanged() { if (!dateIn.activeFocus) dateIn.text = f.cur() } }
        }
    }
    Component {
        id: actionC
        Rectangle {
            objectName: "action-" + (f.field.action || "")
            implicitHeight: f.ctlH; radius: 10
            activeFocusOnTab: true
            color: actMA.pressed ? f.col.accent : f.col.panelAlt
            border.width: 1; border.color: f.col.accent
            Accessible.role: Accessible.Button
            Accessible.name: f.field.actionLabel || "Run action"
            Accessible.onPressAction: f.actionRequested(f.field.action)
            Keys.onSpacePressed: f.actionRequested(f.field.action)
            Keys.onEnterPressed: f.actionRequested(f.field.action)
            Keys.onReturnPressed: f.actionRequested(f.field.action)
            Text { anchors.centerIn: parent; text: f.field.actionLabel || "Run"
                color: actMA.pressed ? f.onAccent() : f.col.textPrimary; font.pixelSize: f.fontBase }
            MouseArea { id: actMA; anchors.fill: parent
                onClicked: { parent.forceActiveFocus(); f.actionRequested(f.field.action) } }
        }
    }
    Component {
        id: infoC
        Text {
            width: f.width; wrapMode: Text.WordWrap
            text: f.field.text || ""; color: f.col.textSecondary; font.pixelSize: f.fontMinimum
        }
    }

    Component {
        id: reorderC
        ColumnLayout {
            id: reorderBox
            spacing: 6

            function orderedValues() {
                var options = f.field.options || []
                var raw = f.cur()
                var requested = Array.isArray(raw) ? raw.slice()
                                                   : String(raw || "").split(",")
                var result = []
                function canonical(token) {
                    var cleaned = String(token || "").trim()
                    for (var i = 0; i < options.length; i++) {
                        if (String(options[i].value) === cleaned
                                || String(options[i].label).toUpperCase()
                                   === cleaned.toUpperCase())
                            return String(options[i].value)
                    }
                    return ""
                }
                for (var j = 0; j < requested.length; j++) {
                    var value = canonical(requested[j])
                    if (value.length && result.indexOf(value) < 0) result.push(value)
                }
                for (var k = 0; k < options.length; k++) {
                    var fallback = String(options[k].value)
                    if (result.indexOf(fallback) < 0) result.push(fallback)
                }
                return result
            }
            function labelFor(value) {
                var options = f.field.options || []
                for (var i = 0; i < options.length; i++)
                    if (String(options[i].value) === String(value))
                        return String(options[i].label)
                return String(value)
            }
            function move(index, delta) {
                var values = orderedValues()
                var target = index + delta
                if (index < 0 || target < 0 || index >= values.length
                        || target >= values.length) return
                var item = values[index]
                values[index] = values[target]
                values[target] = item
                f.setV(values)
            }

            Repeater {
                model: {
                    var _ = f.st ? f.st.revision : 0
                    return reorderBox.orderedValues()
                }
                delegate: Rectangle {
                    required property int index
                    required property string modelData
                    objectName: "reorder-row-" + modelData
                    Layout.fillWidth: true
                    implicitHeight: Math.max(f.ctlH, 54)
                    radius: 8
                    color: f.col.bg
                    border.width: 1
                    border.color: f.col.border

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        spacing: 8
                        Text {
                            text: (index + 1) + ". " + reorderBox.labelFor(modelData)
                            color: f.col.textPrimary
                            font.pixelSize: f.fontBase
                            font.bold: true
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                        }
                        Button {
                            objectName: "move-up-" + modelData
                            Layout.preferredWidth: f.ctlH
                            Layout.preferredHeight: f.ctlH
                            enabled: index > 0
                            text: "↑"
                            Accessible.name: "Move " + reorderBox.labelFor(modelData) + " up"
                            font.pixelSize: f.fontBase + 4
                            contentItem: Text {
                                text: parent.text
                                color: parent.enabled ? f.col.textPrimary : f.col.textSecondary
                                opacity: parent.enabled ? 1 : 0.45
                                font: parent.font
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }
                            background: Rectangle {
                                radius: 7
                                color: parent.pressed ? f.col.accent : f.col.panelAlt
                                border.width: 1
                                border.color: f.col.border
                            }
                            onClicked: reorderBox.move(index, -1)
                        }
                        Button {
                            objectName: "move-down-" + modelData
                            Layout.preferredWidth: f.ctlH
                            Layout.preferredHeight: f.ctlH
                            enabled: index < reorderBox.orderedValues().length - 1
                            text: "↓"
                            Accessible.name: "Move " + reorderBox.labelFor(modelData) + " down"
                            font.pixelSize: f.fontBase + 4
                            contentItem: Text {
                                text: parent.text
                                color: parent.enabled ? f.col.textPrimary : f.col.textSecondary
                                opacity: parent.enabled ? 1 : 0.45
                                font: parent.font
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }
                            background: Rectangle {
                                radius: 7
                                color: parent.pressed ? f.col.accent : f.col.panelAlt
                                border.width: 1
                                border.color: f.col.border
                            }
                            onClicked: reorderBox.move(index, 1)
                        }
                    }
                }
            }
        }
    }

    // ── Task list editor ──
    Component {
        id: tasksC
        ColumnLayout {
            spacing: 6
            Repeater {
                model: f.curTasks()
                delegate: RowLayout {
                    required property int index
                    required property var modelData
                    Layout.fillWidth: true; spacing: 8
                    Rectangle {
                        function activate() {
                            var a = f.curTasks().slice()
                            if (!a[index]) return
                            a[index] = Object.assign({}, a[index], {
                                text: a[index].text !== undefined ? String(a[index].text) : "",
                                done: !a[index].done
                            })
                            f.setV(a)
                        }
                        width: Math.max(48, Math.min(f.ctlH, f.ctlH - 4)); height: width; radius: 6
                        color: modelData.done ? f.col.accent : "transparent"
                        border.width: 2; border.color: modelData.done ? f.col.accent : f.col.border
                        activeFocusOnTab: true
                        Accessible.role: Accessible.CheckBox
                        Accessible.name: (modelData.done ? "Mark incomplete: " : "Complete: ")
                                         + String(modelData.text || "")
                        Accessible.checked: modelData.done === true
                        Accessible.onPressAction: activate()
                        Keys.onSpacePressed: activate()
                        Keys.onReturnPressed: activate()
                        AppIcon { anchors.centerIn: parent; visible: modelData.done; name: "ui-check"; size: 16; color: f.onAccent() }
                        MouseArea { anchors.fill: parent; onClicked: parent.activate() }
                    }
                    TextField {
                        Layout.fillWidth: true; text: modelData.text; implicitHeight: Math.max(48, f.ctlH - 8)
                        color: f.col.textPrimary; font.pixelSize: f.fontBase - 1
                        Accessible.name: "Edit task: " + String(modelData.text || "")
                        background: Rectangle { radius: 6; color: f.col.bg; border.width: 1
                            border.color: parent.activeFocus ? f.col.accent : f.col.border }
                        onEditingFinished: {
                            var a = f.curTasks().slice()
                            if (!a[index]) return   // row vanished (live push) - drop the edit
                            a[index] = Object.assign({}, a[index], {
                                text: text, done: a[index].done === true
                            }); f.setV(a)
                        }
                    }
                    Rectangle {
                        function activate() {
                            var a = f.curTasks().slice()
                            if (index < 0 || index >= a.length) return
                            a.splice(index, 1)
                            f.setV(a)
                        }
                        width: Math.max(48, Math.min(f.ctlH, f.ctlH - 4)); height: width; radius: 6; color: f.col.panelAlt
                        activeFocusOnTab: true
                        Accessible.role: Accessible.Button
                        Accessible.name: "Remove task: " + String(modelData.text || "")
                        Accessible.onPressAction: activate()
                        Keys.onSpacePressed: activate()
                        Keys.onReturnPressed: activate()
                        AppIcon { anchors.centerIn: parent; name: "ui-close"; size: 13; color: f.col.textSecondary }
                        MouseArea { anchors.fill: parent; onClicked: parent.activate() }
                    }
                }
            }
            RowLayout {
                Layout.fillWidth: true; spacing: 8
                TextField {
                    id: newTask; Layout.fillWidth: true; placeholderText: "Add a task…"; implicitHeight: Math.max(38, f.ctlH - 10)
                    color: f.col.textPrimary; placeholderTextColor: f.col.textSecondary; font.pixelSize: f.fontBase - 1
                    background: Rectangle { radius: 6; color: f.col.bg; border.width: 1
                        border.color: parent.activeFocus ? f.col.accent : f.col.border }
                    function commit() {
                        if (!text.trim().length) return
                        var a = f.curTasks().slice()
                        a.push({ id: "task-" + Date.now() + "-" + (a.length + 1),
                                   text: text.trim(), done: false })
                        f.setV(a)
                        text = ""
                    }
                    onAccepted: commit()
                }
                Rectangle {
                    Layout.preferredWidth: 64; Layout.preferredHeight: Math.max(38, f.ctlH - 10); radius: 8
                    color: addMA.pressed ? f.col.accent : f.col.panelAlt; border.width: 1; border.color: f.col.accent
                    Text { anchors.centerIn: parent; text: "Add"; color: f.col.textPrimary; font.pixelSize: f.fontBase - 1 }
                    MouseArea { id: addMA; anchors.fill: parent; onClicked: newTask.commit() }
                }
            }
        }
    }
}
