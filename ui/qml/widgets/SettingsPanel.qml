import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// ─────────────────────────────────────────────────────────────────────────
// SettingsPanel - in-app customization overlay.
// Lets the user pick theme mode, accent color, glass/transparency level,
// widget glow, and reduced motion. Changes apply live to `theme` / root.
// ─────────────────────────────────────────────────────────────────────────
Rectangle {
    id: panel
    anchors.fill: parent
    color: Qt.rgba(0, 0, 0, 0.6)
    z: 200
    property bool shown: false
    signal closeRequested()
    // W5 finding 3: the "Screens" entry reopens the preset library post-setup.
    // The panel only emits - the Dashboard owns the picker and the apply.
    signal presetsRequested()
    // True when an org policy forces a preset (E9 lockToPreset): the Screens
    // entry is then ABSENT, not greyed - a managed device must not advertise
    // a choice its user cannot make. Injected by the Dashboard.
    property bool presetsLocked: false

    // E10: the app-global UpdateChecker service (injected by Dashboard; null in
    // a standalone harness). The panel only renders its result line and writes
    // the persisted opt-in flag - the checker itself decides when to talk.
    property var updateChecker: null

    visible: shown || opacity > 0.01
    opacity: shown ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: theme.motionFast } }

    // Bundled "standard" wallpapers + animated styles offered in the pickers below.
    WallpaperCatalog { id: wallpapers }
    BackgroundCatalog { id: bgCatalog }
    // Colour tokens for the shared BackgroundPicker.
    readonly property var pickerCol: ({ textPrimary: theme.textPrimary, textSecondary: theme.textSecondary,
        panel: theme.cardBackground, panelAlt: theme.cardBackgroundAlt, border: theme.cardBorder,
        accent: theme.accent, radius: theme.radiusMd, ctlH: theme.touchSecondary,
        fontBase: theme.fontLabel })

    // scrim click closes
    MouseArea { anchors.fill: parent; onClicked: panel.closeRequested() }

    // One swatch shape for both accent groups (house palette + Okabe–Ito).
    Component {
        id: accentSwatch
        Rectangle {
            required property var modelData
            width: 52; height: 52; radius: 26
            property bool active: root.accentName === modelData
            color: theme.accentPresets[modelData].a
            // Okabe–Ito includes pure black, which would otherwise disappear
            // against the dark sheet - every swatch keeps a hairline so the
            // unselected ones stay findable whatever their tone.
            border.width: active ? 3 : 1
            border.color: active ? theme.textPrimary : theme.cardBorder
            scale: active ? 1.08 : 1.0
            Behavior on scale { NumberAnimation { duration: theme.motionFast } }
            // The check sits ON the swatch, so it must contrast with the swatch,
            // not with the sheet: the palette spans near-black (oi_black) to
            // near-white (oi_yellow). Rec. 601 luma picks the readable ink.
            AppIcon {
                anchors.centerIn: parent; visible: parent.active
                name: "ui-check"; size: 22
                color: (0.299 * parent.color.r + 0.587 * parent.color.g
                        + 0.114 * parent.color.b) > 0.55 ? "#000000" : "#FFFFFF"
            }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                onClicked: theme.applyAccent(modelData) }
        }
    }

    Rectangle {
        id: sheet
        width: Math.min(parent.width * 0.9, 620)
        height: Math.min(parent.height * 0.92, 640)
        anchors.centerIn: parent
        radius: theme.radiusXl
        color: theme.backgroundColor
        border.width: 1; border.color: theme.cardBorder
        scale: panel.shown ? 1 : 0.95
        Behavior on scale { NumberAnimation { duration: theme.motionPage; easing.type: Easing.OutCubic } }
        MouseArea { anchors.fill: parent } // swallow clicks

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: theme.spacingXl
            spacing: theme.spacingLg

            // Header
            RowLayout {
                Layout.fillWidth: true
                spacing: theme.spacingSm
                AppIcon { name: "ui-settings"; color: theme.textPrimary; size: 24; Layout.alignment: Qt.AlignVCenter }
                Text {
                    text: "Appearance"; font.pixelSize: 22; font.bold: true
                    font.family: theme.fontDisplay; color: theme.textPrimary
                    Layout.fillWidth: true
                }
                Rectangle {
                    width: theme.touchSecondary; height: theme.touchSecondary
                    radius: width / 2; color: theme.cardBackground
                    border.width: 1; border.color: theme.cardBorder
                    AppIcon { anchors.centerIn: parent; name: "ui-close"; size: 18; color: theme.textPrimary }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: panel.closeRequested() }
                }
            }

            Flickable {
                Layout.fillWidth: true; Layout.fillHeight: true
                contentHeight: form.implicitHeight; clip: true
                ColumnLayout {
                    id: form
                    width: parent.width
                    spacing: theme.spacingXl

                    // --- Screens (reopen the preset library - W5 finding 3) ---
                    // The 15-screen library used to be wizard-only; this is the
                    // one post-setup way back in. Hidden entirely under an
                    // org-forced preset.
                    ColumnLayout {
                        visible: !panel.presetsLocked
                        Layout.fillWidth: true; spacing: theme.spacingSm
                        Text { text: "Screens"; font.pixelSize: theme.fontLabel; font.bold: true; color: theme.textSecondary }
                        Rectangle {
                            objectName: "screensEntry"
                            Layout.fillWidth: true
                            Layout.preferredHeight: theme.touchSecondary
                            radius: theme.radiusMd
                            color: presetsMA.pressed ? theme.cardBackgroundAlt : theme.cardBackground
                            border.width: 1; border.color: theme.cardBorder
                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: theme.spacingMd; anchors.rightMargin: theme.spacingMd
                                spacing: theme.spacingSm
                                AppIcon { name: "ui-layout"; size: theme.iconSm; color: theme.accent }
                                Text {
                                    text: "Browse screen layouts…"
                                    font.pixelSize: theme.fontLabel; color: theme.textPrimary
                                    Layout.fillWidth: true; elide: Text.ElideRight
                                }
                                AppIcon { name: "ui-caret-right"; size: theme.iconSm; color: theme.textTertiary }
                            }
                            MouseArea { id: presetsMA; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                onClicked: panel.presetsRequested() }
                        }
                        Text {
                            Layout.fillWidth: true; wrapMode: Text.WordWrap
                            text: "Ready-made screens. Adding one appends a new screen and takes you to it; your look stays."
                            font.pixelSize: theme.fontCaption; color: theme.textTertiary
                        }
                    }

                    // --- Theme (compact, grouped, Pro-gated) ---
                    // Reads the SHARED catalogue in Theme.qml (same list the Manager's
                    // dropdown shows), grouped into Standard / Premium / Distro /
                    // Accessibility. A 29-tile grid was a long scroll on the panel; these
                    // compact swatch chips scan faster and match the Manager.
                    //
                    // Pro gating: a Pro theme is locked unless `license.isPro`. The
                    // `license` bridge is a context property on the device; it is absent
                    // in the offscreen test harness, so read it defensively (→ treated as
                    // free). Tapping a locked theme explains where to unlock it instead
                    // of silently applying - the leak this fixes.
                    ColumnLayout {
                        id: themeSection
                        Layout.fillWidth: true; spacing: theme.spacingSm
                        property bool userIsPro: (typeof license !== "undefined") && license && license.isPro === true
                        property string lockHint: ""
                        function groupLabel(g) {
                            // "Inspired", never "Distro-inspired": see the naming
                            // policy in ui/qml/Theme.qml. No project name - and no
                            // phrase that re-asserts the association - appears in a
                            // user-visible string.
                            return g === "Premium" ? "Premium (Pro)"
                                 : g === "Inspired" ? "Inspired (Pro)"
                                 : g === "Accessibility" ? "Accessibility" : "Standard"
                        }
                        Text { text: "Theme"; font.pixelSize: theme.fontLabel; font.bold: true; color: theme.textSecondary }
                        Text {
                            visible: themeSection.lockHint !== ""
                            text: themeSection.lockHint; color: theme.accent
                            font.pixelSize: theme.fontCaption; wrapMode: Text.WordWrap; Layout.fillWidth: true
                        }
                        Repeater {
                            model: theme.themeGroupOrder
                            delegate: ColumnLayout {
                                required property string modelData
                                readonly property var groupThemes: theme.themesInGroup(modelData)
                                visible: groupThemes.length > 0
                                Layout.fillWidth: true; spacing: theme.spacingSm
                                Layout.topMargin: theme.spacingSm
                                Text { text: themeSection.groupLabel(modelData); font.pixelSize: theme.fontCaption
                                    font.bold: true; color: theme.textTertiary }
                                Flow {
                                    Layout.fillWidth: true; spacing: theme.spacingSm
                                    Repeater {
                                        model: groupThemes
                                        delegate: Rectangle {
                                            required property var modelData
                                            readonly property bool active: root.themeMode === modelData.k
                                            readonly property bool locked: (modelData.pro === true) && !themeSection.userIsPro
                                            implicitWidth: chipRow.implicitWidth + 20; height: theme.touchTertiary
                                            radius: theme.radiusMd
                                            color: active ? Qt.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 0.14)
                                                          : theme.cardBackgroundAlt
                                            border.width: active ? 2 : 1
                                            border.color: active ? theme.accent : theme.cardBorder
                                            opacity: locked ? 0.55 : 1.0
                                            scale: chipMA.pressed ? 0.97 : 1.0
                                            Behavior on scale { NumberAnimation { duration: theme.motionFast } }
                                            RowLayout {
                                                id: chipRow; anchors.centerIn: parent; spacing: 8
                                                Rectangle {
                                                    width: 22; height: 22; radius: 5; border.width: 1; border.color: theme.cardBorder
                                                    gradient: Gradient {
                                                        GradientStop { position: 0.0; color: modelData.c1 }
                                                        GradientStop { position: 1.0; color: modelData.c2 } }
                                                }
                                                Text { text: modelData.n; color: theme.textPrimary; font.pixelSize: theme.fontLabel }
                                                Rectangle {
                                                    visible: modelData.pro === true
                                                    implicitWidth: proBadge.implicitWidth + 12
                                                    implicitHeight: 24; radius: 12
                                                    color: locked ? Qt.rgba(theme.textSecondary.r, theme.textSecondary.g, theme.textSecondary.b, 0.25)
                                                                  : Qt.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 0.22)
                                                    Text { id: proBadge; anchors.centerIn: parent; text: "PRO"
                                                        color: locked ? theme.textSecondary : theme.accent
                                                        font.pixelSize: theme.fontMinimum; font.bold: true }
                                                }
                                                AppIcon { visible: active; name: "ui-check"; size: 16; color: theme.accent }
                                            }
                                            MouseArea {
                                                id: chipMA; anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    if (locked) {
                                                        themeSection.lockHint = "“" + modelData.n + "” is a Pro theme - add your licence in the EdgeHub Manager to use it."
                                                        return
                                                    }
                                                    themeSection.lockHint = ""
                                                    root.themeMode = modelData.k; theme.applyTheme(modelData.k)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // --- Orientation ---
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: theme.spacingSm
                        Text { text: "Orientation"; font.pixelSize: theme.fontLabel; font.bold: true; color: theme.textSecondary }
                        Text { text: "Pick how the dashboard sits on the panel. Use a fixed mode to rotate for a wall/arm mount. (Auto follows the system only when an orientation sensor is present.)"
                            font.pixelSize: theme.fontCaption; color: theme.textTertiary
                            Layout.fillWidth: true; wrapMode: Text.WordWrap }
                        Flow {
                            Layout.fillWidth: true; spacing: theme.spacingSm
                            Repeater {
                                model: [ { v: "auto", l: "Auto" }, { v: "portrait", l: "Portrait" },
                                         { v: "landscape", l: "Landscape" }, { v: "inverted-portrait", l: "Portrait (flipped)" },
                                         { v: "inverted-landscape", l: "Landscape (flipped)" } ]
                                delegate: Rectangle {
                                    required property var modelData
                                    width: oLbl.implicitWidth + 26; height: theme.touchSecondary; radius: theme.radiusMd
                                    property bool active: root.orientationMode === modelData.v
                                    color: active ? Qt.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 0.18) : theme.cardBackground
                                    border.width: active ? 2 : 1; border.color: active ? theme.accent : theme.cardBorder
                                    Text { id: oLbl; anchors.centerIn: parent; text: modelData.l; color: theme.textPrimary; font.pixelSize: theme.fontLabel }
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        onClicked: root.orientationMode = modelData.v }
                                }
                            }
                        }
                    }

                    // --- Readability ---
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: theme.spacingSm
                        Text { text: "Readability"; font.pixelSize: theme.fontLabel; font.bold: true; color: theme.textSecondary }
                        Text {
                            text: "Choose text that stays comfortable at the distance you use the Edge. This applies to every screen and the Manager preview."
                            font.pixelSize: theme.fontCaption; color: theme.textTertiary
                            Layout.fillWidth: true; wrapMode: Text.WordWrap
                        }
                        Flow {
                            Layout.fillWidth: true; spacing: theme.spacingSm
                            Repeater {
                                model: [ { v: 1.0, l: "Compact" }, { v: 1.15, l: "Comfortable" },
                                         { v: 1.3, l: "Large" }, { v: 1.45, l: "Extra large" } ]
                                delegate: Rectangle {
                                    required property var modelData
                                    width: sizeLabel.implicitWidth + 28; height: theme.touchSecondary
                                    radius: theme.radiusMd
                                    property bool active: Math.abs(theme.textScale - modelData.v) < 0.01
                                    color: active ? Qt.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 0.18)
                                                  : theme.cardBackground
                                    border.width: active ? 2 : 1
                                    border.color: active ? theme.accent : theme.cardBorder
                                    Text { id: sizeLabel; anchors.centerIn: parent; text: modelData.l
                                        color: theme.textPrimary; font.pixelSize: theme.fontLabel }
                                    MouseArea { anchors.fill: parent; onClicked: root.textScale = modelData.v }
                                }
                            }
                        }
                        Flow {
                            Layout.fillWidth: true; spacing: theme.spacingSm
                            Repeater {
                                model: [ { v: "hyperlegible", l: "Hyperlegible" },
                                         { v: "lexend", l: "Lexend" }, { v: "system", l: "System" } ]
                                delegate: Rectangle {
                                    required property var modelData
                                    width: fontLabel.implicitWidth + 28; height: theme.touchSecondary
                                    radius: theme.radiusMd
                                    property bool active: theme.fontChoice === modelData.v
                                    color: active ? Qt.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 0.18)
                                                  : theme.cardBackground
                                    border.width: active ? 2 : 1
                                    border.color: active ? theme.accent : theme.cardBorder
                                    Text { id: fontLabel; anchors.centerIn: parent; text: modelData.l
                                        color: theme.textPrimary; font.pixelSize: theme.fontLabel
                                        font.family: modelData.v === "lexend" ? theme.fontFamilyLexend
                                                     : modelData.v === "hyperlegible" ? theme.fontFamilyHyperlegible
                                                     : theme._fontDisplaySystem }
                                    MouseArea { anchors.fill: parent; onClicked: root.fontChoice = modelData.v }
                                }
                            }
                        }
                    }

                    // --- Background (one unified picker: animated style OR wallpaper) ---
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: theme.spacingSm
                        Text { text: "Background"; font.pixelSize: theme.fontLabel; font.bold: true; color: theme.textSecondary }
                        Text { text: "Pick a living animation OR a wallpaper - they show through the frosted widgets."
                            font.pixelSize: theme.fontCaption; color: theme.textTertiary
                            Layout.fillWidth: true; wrapMode: Text.WordWrap }
                        RowLayout {
                            visible: !theme.decorative; Layout.fillWidth: true; spacing: theme.spacingSm
                            AppIcon { name: "ui-warning"; size: theme.iconSm; color: theme.warning; Layout.alignment: Qt.AlignTop }
                            Text { text: "The High Contrast theme keeps backgrounds off for legibility - switch themes to see them."
                                font.pixelSize: theme.fontCaption; color: theme.warning
                                Layout.fillWidth: true; wrapMode: Text.WordWrap }
                        }
                        BackgroundPicker {
                            Layout.fillWidth: true
                            // Backgrounds have no effect in High Contrast - disable the
                            // picker there instead of letting taps silently no-op.
                            enabled: theme.decorative
                            opacity: theme.decorative ? 1.0 : 0.4
                            st: store; pageIndex: -1; col: panel.pickerCol
                            bgCatalog: bgCatalog; wpCatalog: wallpapers
                        }
                    }

                    // A "Layout Columns" picker stood here. The grid is now fixed at
                    // WidgetSizes.shortHalves across the short axis, because a size is
                    // a fraction of the SCREEN - a user-chosen column count would make
                    // `1x1` mean something different per page, which is the exact
                    // property the size model exists to remove. A tile's share of the
                    // screen is now chosen per TILE (its size), not per page.

                    // --- Accent color ---
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: theme.spacingSm
                        Text { text: "Accent Color"; font.pixelSize: theme.fontLabel; font.bold: true; color: theme.textSecondary }
                        Flow {
                            Layout.fillWidth: true; spacing: theme.spacingMd
                            Repeater {
                                model: ["blue","purple","green","orange","pink","teal","red","gold",
                                        "cyan","indigo","mint","coral","amber","magenta"]
                                delegate: accentSwatch
                            }
                        }

                        // The Okabe–Ito set stays mutually distinguishable for the
                        // ~1-in-12 of men with a colour-vision deficiency. Split out
                        // under its own heading so it reads as a deliberate choice
                        // rather than eight more decorative tones.
                        Text {
                            text: "Colour-blind safe (Okabe–Ito)"
                            font.pixelSize: theme.fontLabel; font.bold: true; color: theme.textSecondary
                            Layout.topMargin: theme.spacingSm
                        }
                        Flow {
                            Layout.fillWidth: true; spacing: theme.spacingMd
                            Repeater {
                                model: ["oi_blue","oi_sky_blue","oi_bluish_green","oi_yellow",
                                        "oi_orange","oi_vermillion","oi_reddish_purple","oi_black"]
                                delegate: accentSwatch
                            }
                        }
                    }

                    // --- Glass / transparency ---
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: theme.spacingSm
                        Text { text: "Hub display"; font.pixelSize: theme.fontLabel
                            font.bold: true; color: theme.textSecondary }
                        RowLayout {
                            Layout.fillWidth: true
                            Text { text: "Show Hub navigation bar"; font.pixelSize: theme.fontLabel
                                color: theme.textPrimary; Layout.fillWidth: true }
                            Switch {
                                objectName: "hubBarSwitch"
                                checked: { var _ = store.revision; return store.appearance().hubControlsMode !== "immersive" }
                                onToggled: {
                                    store.setAppearance("hubControlsMode", checked ? "standard" : "immersive")
                                    checked = Qt.binding(function () {
                                        var _ = store.revision
                                        return store.appearance().hubControlsMode !== "immersive"
                                    })
                                }
                            }
                        }
                        Text {
                            Layout.fillWidth: true; wrapMode: Text.WordWrap
                            text: "Turn this off for an immersive Hub. Screens and appearance are then managed in EdgeHub Manager; each widget's own corner configuration remains available on the Hub."
                            font.pixelSize: theme.fontCaption; color: theme.textTertiary
                        }
                        Text { text: "Cycle through screens"; font.pixelSize: theme.fontLabel
                            font.bold: true; color: theme.textSecondary
                            Layout.topMargin: theme.spacingSm }
                        Text {
                            Layout.fillWidth: true; wrapMode: Text.WordWrap
                            text: "Move to the next screen on its own while nobody is using the Hub. "
                                  + "Touching the panel stops it, and it starts again after the same "
                                  + "amount of time. Screens with nothing on them are skipped."
                            font.pixelSize: theme.fontCaption; color: theme.textTertiary
                        }
                        ComboBox {
                            objectName: "pageCycleCombo"
                            Layout.fillWidth: true
                            implicitHeight: theme.touchTertiary
                            textRole: "label"
                            valueRole: "secs"
                            model: [
                                { secs: 0,   label: "Off" },
                                { secs: 15,  label: "Every 15 seconds" },
                                { secs: 30,  label: "Every 30 seconds" },
                                { secs: 60,  label: "Every minute" },
                                { secs: 90,  label: "Every 90 seconds" },
                                { secs: 120, label: "Every 2 minutes" },
                                { secs: 300, label: "Every 5 minutes" }
                            ]
                            function _indexForStore() {
                                var _ = store.revision
                                var cur = Number(store.appearance().pageCycleSec)
                                for (var i = 0; i < model.length; i++)
                                    if (model[i].secs === cur) return i
                                return 0
                            }
                            currentIndex: _indexForStore()
                            // Selecting writes currentIndex internally, which would
                            // sever the binding above for good - same trap the glass
                            // slider documents. Push, then re-assert.
                            onActivated: {
                                store.setAppearance("pageCycleSec", model[currentIndex].secs)
                                currentIndex = Qt.binding(function () { return _indexForStore() })
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            Text { text: "Glass / Transparency"; font.pixelSize: theme.fontLabel; font.bold: true; color: theme.textSecondary; Layout.fillWidth: true }
                            Text { text: Math.round(root.glassOpacity * 100) + "%"; font.pixelSize: theme.fontLabel; font.family: theme.fontMono; color: theme.accent }
                        }
                        Slider {
                            Layout.fillWidth: true
                            implicitHeight: theme.touchTertiary
                            from: 0; to: 1; value: root.glassOpacity
                            // Dragging writes `value` internally, which would sever the
                            // `value: root.glassOpacity` binding forever. Push to source,
                            // then re-assert the binding so later external changes still
                            // move the handle. (S2)
                            onMoved: {
                                root.glassOpacity = value
                                value = Qt.binding(() => root.glassOpacity)
                            }
                        }
                    }

                    // --- Toggles ---
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: theme.spacingSm
                        RowLayout {
                            Layout.fillWidth: true
                            Text { text: "Accent glow"; font.pixelSize: theme.fontLabel; color: theme.textPrimary; Layout.fillWidth: true }
                            // Toggling writes `checked` internally, severing the
                            // `checked: root.showWidgetGlow` binding. Push to source,
                            // then re-bind so external/store pushes still move it. (S2)
                            Switch {
                                checked: root.showWidgetGlow
                                onToggled: {
                                    root.showWidgetGlow = checked
                                    checked = Qt.binding(() => root.showWidgetGlow)
                                }
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            Text { text: "Animated background"; font.pixelSize: theme.fontLabel; color: theme.textPrimary; Layout.fillWidth: true }
                            Switch {
                                checked: root.animatedBackground
                                onToggled: {
                                    root.animatedBackground = checked
                                    checked = Qt.binding(() => root.animatedBackground)
                                }
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            Text { text: "Reduce motion"; font.pixelSize: theme.fontLabel; color: theme.textPrimary; Layout.fillWidth: true }
                            Switch {
                                checked: root.reduceMotion
                                onToggled: {
                                    root.reduceMotion = checked
                                    checked = Qt.binding(() => root.reduceMotion)
                                }
                            }
                        }
                        // These two knobs are independent: "Animated background" decides
                        // whether the living backdrop shows at all, while "Reduce motion"
                        // keeps the backdrop but freezes its motion and removes spatial
                        // transitions, including the physical orientation turn.
                        Text {
                            Layout.fillWidth: true; wrapMode: Text.WordWrap
                            text: "Animated background shows the drifting backdrop. Reduce motion stops animation and makes physical screen turns immediate."
                            font.pixelSize: theme.fontCaption; color: theme.textTertiary
                        }
                    }

                    // --- Software updates (E10, opt-in) ---
                    // OFF by default - the product's zero-egress default is CI-attested,
                    // so this toggle is the ONLY thing that ever lets the hub ask GitHub
                    // for the latest release tag (one GET, through the NetHub gate).
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: theme.spacingSm
                        Text { text: "Software updates"; font.pixelSize: theme.fontLabel; font.bold: true; color: theme.textSecondary }
                        RowLayout {
                            Layout.fillWidth: true
                            Text { text: "Check for updates"; font.pixelSize: theme.fontLabel; color: theme.textPrimary; Layout.fillWidth: true }
                            Switch {
                                // Bound to the persisted appearance flag (default off).
                                // Toggling writes `checked` internally, severing the
                                // binding - push to the store, then re-bind. (S2)
                                checked: { var _ = store.revision; return store.appearance().updateCheck === true }
                                onToggled: {
                                    store.setAppearance("updateCheck", checked)
                                    checked = Qt.binding(function () {
                                        var _ = store.revision
                                        return store.appearance().updateCheck === true
                                    })
                                }
                            }
                        }
                        Text {
                            Layout.fillWidth: true; wrapMode: Text.WordWrap
                            text: "Off by default - EdgeHub never phones home on its own. When on, it asks "
                                  + "GitHub for the latest release tag (one request through the audited "
                                  + "network gate, nothing identifying sent) and only tells you here."
                            font.pixelSize: theme.fontCaption; color: theme.textTertiary
                        }
                        // Result line + manual re-check, shown only while opted in.
                        RowLayout {
                            visible: panel.updateChecker !== null && panel.updateChecker.enabled
                            Layout.fillWidth: true; spacing: theme.spacingSm
                            Text {
                                Layout.fillWidth: true; wrapMode: Text.WordWrap
                                text: panel.updateChecker ? panel.updateChecker.message : ""
                                font.pixelSize: theme.fontCaption
                                color: panel.updateChecker && panel.updateChecker.updateAvailable
                                       ? theme.accent : theme.textSecondary
                            }
                            Rectangle {
                                width: checkLbl.implicitWidth + 26; height: theme.touchSecondary
                                radius: theme.radiusMd; color: theme.cardBackground
                                border.width: 1; border.color: theme.cardBorder
                                Text { id: checkLbl; anchors.centerIn: parent; text: "Check now"
                                    color: theme.textPrimary; font.pixelSize: theme.fontLabel }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: if (panel.updateChecker) panel.updateChecker.check() }
                            }
                        }
                    }

                    Text {
                        Layout.fillWidth: true; wrapMode: Text.WordWrap
                        text: "Changes apply instantly. Your Xeneon Edge display will use these settings across all widgets."
                        font.pixelSize: theme.fontCaption; color: theme.textTertiary
                    }
                }
            }
        }
    }
}
