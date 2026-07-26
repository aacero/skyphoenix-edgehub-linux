import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: wizard
    // NO `anchors.fill: parent` here. This item is a StackView PAGE (main.qml
    // pushes it), and StackView sets its pages' x/y/width/height itself. Anchoring
    // as well produced, on every launch:
    //     QML StackView: StackView has detected conflicting anchors.
    //     Transitions may not execute properly.
    // i.e. Qt telling us the push/pop transitions may not run. Every other host
    // sizes this item too: the tests' Loaders are `anchors.fill: parent`, and a
    // Loader resizes its loaded item to itself. A host that does NEITHER must set
    // width/height explicitly.

    property int currentStep: 0
    onCurrentStepChanged: {
        // Reset immediately and once more after the newly visible layout has
        // recalculated its height. This keeps every step's heading and actions
        // in view after moving away from a long, scrolled preset list.
        flick.contentY = 0
        Qt.callLater(function() { flick.contentY = 0 })
    }
    property var selectedScreen: null
    // Default to the recommended few-screen starter bundle (see DashboardStore.seed).
    property string selectedLayout: "starter"

    // The curated preset library drives the "choose a screen" step.
    PresetCatalog { id: presetCatalog }
    WidgetCatalog { id: wizardWidgets }
    readonly property var starterPreview: ({
        id: "starter", title: "Recommended starter",
        purpose: "Begin with three useful screens to swipe between: focused work, core system health, and home context.",
        setup: "The Focus and System Core screens work immediately. Set your weather location on the Home screen.",
        pages: presetCatalog.def("productivity").pages
    })
    readonly property var blankPreview: ({
        id: "blank", title: "Blank dashboard",
        purpose: "Start with an empty screen and add only the widgets you choose.",
        setup: "Nothing is configured or connected. Add widgets after setup.",
        pages: [ { name: "Blank", tiles: [] } ]
    })
    readonly property var selectedLayoutPreview: selectedLayout === "starter" ? starterPreview
        : (selectedLayout === "blank" ? blankPreview : presetCatalog.def(selectedLayout))
    property string finishError: ""

    // Parse the detected screens once at the root (the old per-step
    // `parent.screensList` lookup was fragile and could silently resolve empty).
    readonly property var screensList: {
        try { return JSON.parse(_screens || "[]") } catch (e) { return [] }
    }
    // Step 1 can advance once a display is picked - OR immediately if none were
    // detected (otherwise a headless/odd-EDID setup is a hard dead-end).
    readonly property bool canAdvance: currentStep !== 1 || selectedScreen !== null
                                       || screensList.length === 0

    Rectangle {
        anchors.fill: parent
        color: theme.backgroundColor
    }

    // Wrap the whole wizard in a Flickable so it scrolls when the on-screen
    // keyboard lifts content or the panel is rotated to landscape. Content is
    // centred vertically when it fits, and scrolls when it does not.
    Flickable {
        id: flick
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: Math.max(content.implicitHeight + 48, height)
        flickableDirection: Flickable.VerticalFlick
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
            id: content
            width: Math.min(flick.width * 0.85, 800)
            x: (flick.width - width) / 2
            y: Math.max(24, (flick.contentHeight - implicitHeight) / 2)
            spacing: 24

            // Step 0: Welcome
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: welcomeContent.implicitHeight
                visible: currentStep === 0

                ColumnLayout {
                    id: welcomeContent
                    anchors.fill: parent
                    spacing: 20

                    Item { Layout.preferredHeight: 40 }

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: "🖥️"
                        font.pixelSize: 64
                    }

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.fillWidth: true
                        text: "Welcome to Xeneon Edge Linux Hub"
                        font.pixelSize: 28
                        font.bold: true
                        color: theme.textPrimary
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                    }

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.preferredWidth: welcomeContent.width * 0.8
                        text: "Set up your secondary touchscreen dashboard in just a few taps."
                        font.pixelSize: 16
                        color: theme.textSecondary
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                    }
                }
            }

            // Step 1: Display Selection
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: step1Content.implicitHeight
                visible: currentStep === 1

                ColumnLayout {
                    id: step1Content
                    anchors.fill: parent
                    spacing: 12

                    Text {
                        Layout.fillWidth: true
                        text: "Select Your Dashboard Display"
                        font.pixelSize: 22
                        font.bold: true
                        color: theme.textPrimary
                    }

                    Text {
                        text: "Choose the display where your dashboard will appear.\nDisplays matching the Xeneon Edge are highlighted."
                        font.pixelSize: theme.fontMinimum
                        color: theme.textSecondary
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                    }

                    ListView {
                        id: screenList
                        Layout.fillWidth: true
                        // Size to the rows and let the outer Flickable do the
                        // scrolling - a fillHeight ListView inside an unsized
                        // parent collapsed the whole step to 0px.
                        Layout.preferredHeight: contentHeight
                        interactive: false
                        clip: true
                        model: wizard.screensList
                        spacing: 8

                        delegate: Rectangle {
                            width: screenList.width
                            height: 80
                            radius: 12
                            color: modelData.likelyXeneonEdge ? "#1A3A2A" : theme.cardBackground
                            border.width: selectedScreen && selectedScreen.name === modelData.name ? 2 : 1
                            border.color: selectedScreen && selectedScreen.name === modelData.name ? theme.accent : theme.cardBorder

                            RowLayout {
                                anchors.fill: parent
                                anchors.margins: 12
                                spacing: 16

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 4

                                    RowLayout {
                                        spacing: 8
                                        Text {
                                            text: modelData.model || "Unknown Display"
                                            font.pixelSize: 16
                                            font.bold: true
                                            color: theme.textPrimary
                                        }
                                        Rectangle {
                                            // Coerced: a screen record without the key yields
                                            // undefined, and "Unable to assign [undefined] to bool"
                                            // is a QWARN the new gate treats as a failure.
                                            visible: modelData.likelyXeneonEdge === true
                                            color: theme.success
                                            radius: 4
                                            width: detectedLabel.width + 8
                                            height: detectedLabel.height + 4
                                            Text {
                                                id: detectedLabel
                                                anchors.centerIn: parent
                                                text: "⭐ Detected"
                                                font.pixelSize: theme.fontMinimum
                                                color: "#000000"
                                            }
                                        }
                                    }

                                    Text {
                                        Layout.fillWidth: true
                                        text: (modelData.manufacturer || "") + " • " +
                                              modelData.size.width + "×" + modelData.size.height + " • " +
                                              modelData.name
                                        font.pixelSize: theme.fontMinimum
                                        color: theme.textSecondary
                                        elide: Text.ElideRight
                                    }
                                }

                                Button {
                                    text: selectedScreen && selectedScreen.name === modelData.name ? "✓ Selected" : "Select"
                                    flat: selectedScreen && selectedScreen.name === modelData.name
                                    leftPadding: 18; rightPadding: 18; topPadding: 12; bottomPadding: 12
                                    onClicked: selectedScreen = modelData
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                // Sit behind the Select button so it keeps its own click.
                                z: -1
                                onClicked: selectedScreen = modelData
                            }
                        }
                    }

                    Text {
                        visible: screenList.count === 0
                        text: "No displays detected. You can continue and choose a display later from Settings."
                        color: theme.warning
                        font.pixelSize: theme.fontMinimum
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                    }
                }
            }

            // Step 2: Choose Layout
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: step2Content.implicitHeight
                visible: currentStep === 2

                ColumnLayout {
                    id: step2Content
                    anchors.fill: parent
                    spacing: 16

                    Text {
                        Layout.fillWidth: true
                        text: "Choose a Starter Layout"
                        font.pixelSize: 22
                        font.bold: true
                        color: theme.textPrimary
                    }

                    Text {
                        text: "You can customize everything later."
                        font.pixelSize: theme.fontMinimum
                        color: theme.textSecondary
                    }

                    // The recommended few-screen starter (work + system + home) -
                    // selected by default, so a new user has pages to swipe at once.
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: recCol.implicitHeight + 28
                        radius: 12
                        color: selectedLayout === "starter" ? Qt.lighter(theme.cardBackground, 1.15) : theme.cardBackground
                        border.width: selectedLayout === "starter" ? 2 : 1
                        border.color: selectedLayout === "starter" ? theme.accent : theme.cardBorder
                        ColumnLayout {
                            id: recCol
                            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                            anchors.margins: 14; spacing: 4
                            Text { Layout.fillWidth: true; text: "✨  Recommended starter"
                                font.pixelSize: 17; font.bold: true; color: theme.textPrimary }
                            Text { Layout.fillWidth: true; wrapMode: Text.WordWrap
                                text: "A few ready-made screens to swipe between - focus & tasks, system stats, and home. Add or remove screens any time."
                                font.pixelSize: theme.fontMinimum; color: theme.textSecondary }
                        }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onClicked: selectedLayout = "starter" }
                    }

                    PresetPreview {
                        id: starterLayoutPreview
                        objectName: "wizardPresetPreview"
                        Layout.fillWidth: true
                        Layout.preferredHeight: 390
                        preset: wizard.selectedLayoutPreview
                        widgetCatalog: wizardWidgets
                        landscape: wizard.width >= wizard.height
                    }

                    Text {
                        text: "…or start from a single screen:"
                        font.pixelSize: theme.fontMinimum
                        color: theme.textSecondary
                    }

                    GridLayout {
                        Layout.fillWidth: true
                        columns: 2
                        columnSpacing: 12
                        rowSpacing: 12

                        Repeater {
                            model: presetCatalog.list()

                            Rectangle {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 120
                                radius: 12
                                color: selectedLayout === modelData.id ? Qt.lighter(theme.cardBackground, 1.15) : theme.cardBackground
                                border.width: selectedLayout === modelData.id ? 2 : 1
                                border.color: selectedLayout === modelData.id ? theme.accent : theme.cardBorder

                                ColumnLayout {
                                    anchors.fill: parent
                                    anchors.margins: 14
                                    spacing: 6

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 10
                                        AppIcon { name: modelData.icon || "ui-layout"
                                            size: 22; color: theme.accent; Layout.alignment: Qt.AlignVCenter }
                                        Text {
                                            Layout.fillWidth: true
                                            text: modelData.title
                                            font.pixelSize: 17
                                            font.bold: true
                                            color: theme.textPrimary
                                            elide: Text.ElideRight
                                        }
                                    }
                                    Text {
                                        text: modelData.blurb
                                        font.pixelSize: theme.fontMinimum
                                        color: theme.textSecondary
                                        wrapMode: Text.WordWrap
                                        maximumLineCount: 3
                                        elide: Text.ElideRight
                                        Layout.fillWidth: true
                                        Layout.fillHeight: true
                                    }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: selectedLayout = modelData.id
                                }
                            }
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 56
                        radius: 12
                        color: selectedLayout === "blank" ? Qt.lighter(theme.cardBackground, 1.15) : theme.cardBackground
                        border.width: selectedLayout === "blank" ? 2 : 1
                        border.color: selectedLayout === "blank" ? theme.accent : theme.cardBorder

                        Text {
                            anchors.centerIn: parent
                            text: "Or start with a blank dashboard"
                            font.pixelSize: 16
                            color: theme.textPrimary
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: selectedLayout = "blank"
                        }
                    }
                }
            }

            // Step 3: Options & Finish
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: step3Content.implicitHeight
                visible: currentStep === 3

                ColumnLayout {
                    id: step3Content
                    anchors.fill: parent
                    spacing: 20

                    Text {
                        Layout.fillWidth: true
                        text: "Almost Done!"
                        font.pixelSize: 22
                        font.bold: true
                        color: theme.textPrimary
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 12

                        RowLayout {
                            Layout.fillWidth: true
                            CheckBox {
                                id: autostartCheck
                                checked: true
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2
                                Text {
                                    Layout.fillWidth: true
                                    text: "Start automatically when I log in"
                                    font.pixelSize: 16
                                    color: theme.textPrimary
                                    wrapMode: Text.WordWrap
                                }
                                Text {
                                    text: "Adds to system autostart"
                                    font.pixelSize: theme.fontMinimum
                                    color: theme.textSecondary
                                }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            CheckBox {
                                id: reconnectCheck
                                checked: true
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2
                                Text {
                                    Layout.fillWidth: true
                                    text: "Reopen dashboard when display is reconnected"
                                    font.pixelSize: 16
                                    color: theme.textPrimary
                                    wrapMode: Text.WordWrap
                                }
                                Text {
                                    text: "Recommended"
                                    font.pixelSize: theme.fontMinimum
                                    color: theme.textSecondary
                                }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            CheckBox {
                                id: notifyCheck
                                checked: true
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2
                                Text {
                                    Layout.fillWidth: true
                                    text: "Show notification when display is disconnected"
                                    font.pixelSize: 16
                                    color: theme.textPrimary
                                    wrapMode: Text.WordWrap
                                }
                            }
                        }
                    }
                }
            }

            // Navigation buttons
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 8

                Button {
                    text: "← Back"
                    visible: currentStep > 0
                    flat: true
                    leftPadding: 22; rightPadding: 22; topPadding: 14; bottomPadding: 14
                    onClicked: currentStep--
                }

                Item { Layout.fillWidth: true }

                // Step indicators
                Row {
                    Layout.alignment: Qt.AlignCenter
                    spacing: 8
                    Repeater {
                        model: 4
                        Rectangle {
                            width: 10
                            height: 10
                            radius: 5
                            color: wizard.currentStep === index ? theme.accent : theme.cardBorder
                        }
                    }
                }

                Item { Layout.fillWidth: true }

                Button {
                    text: currentStep === 0 ? "Get Started →" :
                          currentStep === 3 ? "Finish Setup" : "Next →"
                    enabled: wizard.canAdvance
                    leftPadding: 22; rightPadding: 22; topPadding: 14; bottomPadding: 14
                    onClicked: {
                        if (currentStep === 3)
                            wizardCompleted(selectedScreen, selectedLayout, autostartCheck.checked);
                        else
                            currentStep++;
                    }
                }
            }

            // Surfaced failure (previously only a console.error → the user was stuck on
            // "Finish Setup" with no feedback).
            Text {
                Layout.fillWidth: true
                visible: wizard.finishError.length > 0
                text: wizard.finishError
                color: theme.error; font.pixelSize: theme.fontMinimum
                horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
            }
        }
    }

    function wizardCompleted(screen, layout, autostart) {
        console.log("Wizard complete. Selected:", screen ? screen.model : "none",
                    "Layout:", layout, "Autostart:", autostart);

        // Persist all wizard choices via WizardBridge → Rust config. Default the
        // theme/accent to whatever the app booted with (root), not a hardcoded pair.
        wizard.finishError = "";
        var ok = wizardBridge.completeWizard(
            screen ? (screen.edidHash || "") : "",
            screen ? (screen.name || "") : "",
            screen ? (screen.model || "") : "",
            layout,
            root.themeMode || theme.defaultThemeKey,
            (theme.accentPresets[root.accentName] ? theme.accentPresets[root.accentName].a : "#58A6FF"),
            autostart,
            reconnectCheck.checked,
            notifyCheck.checked
        );

        if (ok) {
            console.log("Wizard complete, navigating to dashboard");
            var sv = wizard.StackView.view;
            if (sv)
                sv.replace(Qt.resolvedUrl("Dashboard.qml").toString());
            else
                wizard.finishError = "Setup saved, but couldn't open the dashboard. Please restart the hub.";
        } else {
            console.error("WizardBridge.completeWizard failed");
            wizard.finishError = "Couldn't save your setup. Please check permissions and try again.";
        }
    }
}
