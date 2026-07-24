import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// ─────────────────────────────────────────────────────────────────────────
// PresetPicker - the post-setup "Screens" surface (W5 finding 3).
//
// The curated 15-preset library used to be reachable exactly once, in the
// first-run wizard; a user who finished setup could never apply a preset
// again (the only route was the --reset-wizard CLI flag). This full-screen
// overlay reopens the same library from the Settings sheet.
//
// Selecting a card ARMS it; a light confirm bar then ADDS it as a new screen
// (additive - the user's other screens and their look are untouched). The apply
// is emitted upward (applyRequested) and performed by the Dashboard via
// store.appendPreset, so this stays a dumb surface with no store access of its own.
//
// Org policy (E9): under a forced preset (`lockToPreset`) the surface is
// ABSENT, not greyed out - `locked` gates visibility outright, so a managed
// device never advertises a choice its user cannot make. The Dashboard's
// applyPreset() guards independently, so even a stray signal cannot bypass
// the policy.
// ─────────────────────────────────────────────────────────────────────────
Rectangle {
    id: picker
    anchors.fill: parent
    z: 210
    color: Qt.rgba(0, 0, 0, 0.6)

    property bool shown: false
    // Org-forced preset active → this surface does not exist for the user.
    property bool locked: false
    // A PresetCatalog instance (injected by the Dashboard).
    property var catalog: null
    // The shared widget registry gives the preview truthful titles, icons, and
    // category colors without instantiating any live widget.
    property var widgetCatalog: null
    // The card awaiting confirmation ("" = nothing armed).
    property string pendingId: ""

    signal applyRequested(string presetId)
    signal closeRequested()

    readonly property string pendingTitle: {
        if (pendingId === "blank") return "a blank dashboard"
        var d = (catalog && pendingId !== "") ? catalog.def(pendingId) : null
        return d ? "“" + d.title + "”" : ""
    }
    readonly property var blankPreset: ({
        id: "blank", title: "Blank dashboard",
        purpose: "Start with an empty screen and add only the widgets you choose.",
        setup: "Nothing is configured or connected. Add widgets after creating the screen.",
        pages: [ { name: "Blank", tiles: [] } ]
    })
    readonly property var pendingPreset: pendingId === "blank" ? blankPreset
        : ((catalog && pendingId !== "") ? catalog.def(pendingId) : null)

    WidgetCatalog { id: fallbackWidgetCatalog }

    visible: (shown && !locked) || opacity > 0.01
    opacity: (shown && !locked) ? 1.0 : 0.0
    Behavior on opacity { NumberAnimation { duration: theme.motionFast } }
    // A fresh open never inherits a half-armed confirm from last time.
    onShownChanged: pendingId = ""

    // Scrim click closes (same behaviour as the add-widget picker/settings).
    MouseArea { anchors.fill: parent; onClicked: picker.closeRequested() }

    Rectangle {
        anchors.centerIn: parent
        width: Math.min(parent.width * 0.92, 1500)
        height: Math.min(parent.height * 0.9, 2200)
        radius: theme.radiusXl
        color: theme.backgroundColor
        border.width: 1; border.color: theme.cardBorder
        // Same entrance as every modal in the hub (instant under reduce-motion).
        scale: picker.shown ? 1.0 : 0.96
        Behavior on scale { NumberAnimation { duration: theme.motionPage; easing.type: Easing.OutCubic } }
        MouseArea { anchors.fill: parent } // swallow clicks

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: theme.spacingLg
            spacing: theme.spacingMd

            // Header
            RowLayout {
                Layout.fillWidth: true
                spacing: theme.spacingMd
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    Text {
                        text: "Screens"
                        font.pixelSize: 22; font.bold: true; font.family: theme.fontDisplay
                        color: theme.textPrimary
                    }
                    Text {
                        Layout.fillWidth: true
                        text: "Ready-made screens. Adding one appends a new screen and takes you to it; your other screens and your look stay as they are."
                        font.pixelSize: theme.fontCaption; color: theme.textSecondary
                        wrapMode: Text.WordWrap
                    }
                }
                Rectangle {
                    objectName: "presetPickerClose"
                    Layout.preferredWidth: theme.touchSecondary
                    Layout.preferredHeight: theme.touchSecondary
                    Layout.alignment: Qt.AlignTop
                    radius: width / 2; color: theme.cardBackgroundAlt
                    AppIcon { anchors.centerIn: parent; name: "ui-close"; size: theme.iconSm; color: theme.textPrimary }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        onClicked: picker.closeRequested() }
                }
            }

            // Pick first, inspect the exact blueprint and purpose, then confirm.
            // On a wide Edge the library and preview sit side by side. In portrait
            // the preview moves above the list instead of becoming a thin strip.
            GridLayout {
                id: selectionArea
                Layout.fillWidth: true
                Layout.fillHeight: true
                columns: width >= 900 ? 2 : 1
                columnSpacing: theme.spacingMd
                rowSpacing: theme.spacingMd

                PresetPreview {
                    id: selectedPreview
                    Layout.row: 0
                    Layout.column: selectionArea.columns === 2 ? 1 : 0
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.preferredWidth: selectionArea.columns === 2 ? 520 : -1
                    Layout.preferredHeight: selectionArea.columns === 1 ? 420 : -1
                    Layout.minimumHeight: 300
                    preset: picker.pendingPreset
                    widgetCatalog: picker.widgetCatalog || fallbackWidgetCatalog
                    landscape: selectionArea.columns === 2
                }

                Flickable {
                    objectName: "presetListScroll"
                    Layout.row: selectionArea.columns === 2 ? 0 : 1
                    Layout.column: 0
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.preferredWidth: selectionArea.columns === 2 ? 720 : -1
                    Layout.minimumWidth: selectionArea.columns === 2 ? 360 : 0
                    Layout.minimumHeight: 280
                    clip: true
                    contentHeight: presetGrid.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                    GridLayout {
                        id: presetGrid
                        width: parent.width
                        columns: width > 700 ? 2 : 1
                        columnSpacing: theme.spacingMd
                        rowSpacing: theme.spacingMd

                        Repeater {
                            model: picker.catalog ? picker.catalog.list() : []
                            delegate: Rectangle {
                                id: presetCard
                                required property var modelData
                                objectName: "presetCard-" + modelData.id
                                property bool sel: picker.pendingId === modelData.id
                                Layout.fillWidth: true
                                Layout.preferredHeight: Math.max(120, cardCol.implicitHeight + 28)
                                radius: theme.radiusLg
                                color: sel ? Qt.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 0.14)
                                           : (cardMA.pressed ? theme.cardBackgroundAlt : theme.cardBackground)
                                border.width: sel ? 2 : 1
                                border.color: sel ? theme.accent : theme.cardBorder

                                ColumnLayout {
                                    id: cardCol
                                    anchors.fill: parent
                                    anchors.margins: 14
                                    spacing: 6
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 10
                                        AppIcon {
                                            name: presetCard.modelData.icon || "ui-layout"
                                            size: 22
                                            color: theme.accent
                                            Layout.alignment: Qt.AlignVCenter
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            text: presetCard.modelData.title
                                            font.pixelSize: theme.fontTitle
                                            font.bold: true
                                            font.family: theme.fontDisplay
                                            color: theme.textPrimary
                                            elide: Text.ElideRight
                                        }
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        Layout.fillHeight: true
                                        text: presetCard.modelData.blurb
                                        font.pixelSize: theme.fontMinimum
                                        color: theme.textSecondary
                                        wrapMode: Text.WordWrap
                                        maximumLineCount: 3
                                        elide: Text.ElideRight
                                    }
                                }
                                MouseArea {
                                    id: cardMA
                                    objectName: "presetCardTap-" + presetCard.modelData.id
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: picker.pendingId = presetCard.modelData.id
                                }
                            }
                        }

                        Rectangle {
                            objectName: "presetCard-blank"
                            property bool sel: picker.pendingId === "blank"
                            Layout.fillWidth: true
                            Layout.columnSpan: presetGrid.columns
                            Layout.preferredHeight: theme.touchSecondary
                            radius: theme.radiusMd
                            color: sel ? Qt.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 0.14)
                                       : theme.cardBackground
                            border.width: sel ? 2 : 1
                            border.color: sel ? theme.accent : theme.cardBorder
                            Text {
                                anchors.centerIn: parent
                                text: "Or start from a blank dashboard"
                                font.pixelSize: theme.fontLabel
                                color: theme.textPrimary
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: picker.pendingId = "blank"
                            }
                        }
                    }
                }
            }

            // Confirm bar - armed by a selection. Adding is additive (a new screen),
            // so this is a light touch-confirm, not a "you're about to replace
            // everything" gate.
            Rectangle {
                objectName: "presetConfirmBar"
                Layout.fillWidth: true
                visible: picker.pendingId !== ""
                radius: theme.radiusMd
                color: theme.cardBackgroundAlt
                border.width: 1; border.color: theme.cardBorder
                implicitHeight: confirmRow.implicitHeight + theme.spacingMd * 2

                RowLayout {
                    id: confirmRow
                    anchors.fill: parent
                    anchors.margins: theme.spacingMd
                    spacing: theme.spacingMd

                    Text {
                        Layout.fillWidth: true
                        text: "Add " + picker.pendingTitle + " as a new screen?"
                        color: theme.textPrimary; font.pixelSize: theme.fontLabel
                        wrapMode: Text.WordWrap
                    }
                    Rectangle {
                        objectName: "presetConfirmCancel"
                        Layout.preferredWidth: Math.max(cancelLbl.implicitWidth + 34, theme.touchPrimary)
                        Layout.preferredHeight: theme.touchSecondary
                        radius: theme.radiusMd
                        color: cancelMA.pressed ? theme.cardBackground : theme.backgroundColor
                        border.width: 1; border.color: theme.cardBorder
                        Text { id: cancelLbl; anchors.centerIn: parent; text: "Cancel"
                            color: theme.textPrimary; font.pixelSize: theme.fontLabel }
                        MouseArea { id: cancelMA; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onClicked: picker.pendingId = "" }
                    }
                    Rectangle {
                        objectName: "presetConfirmApply"
                        Layout.preferredWidth: applyLbl.implicitWidth + 34
                        Layout.preferredHeight: theme.touchSecondary
                        radius: theme.radiusMd
                        color: applyMA.pressed ? Qt.darker(theme.accent, 1.2) : theme.accent
                        Text { id: applyLbl; anchors.centerIn: parent; text: "Add screen"
                            color: theme.backgroundColor; font.pixelSize: theme.fontLabel; font.bold: true }
                        MouseArea { id: applyMA; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onClicked: if (picker.pendingId !== "") picker.applyRequested(picker.pendingId) }
                    }
                }
            }
        }
    }
}
