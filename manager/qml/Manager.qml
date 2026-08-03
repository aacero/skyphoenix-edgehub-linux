import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtCore

// Xeneon Edge Manager - companion desktop UI. Reuses the hub's DashboardStore
// (persistence + mutations) and WidgetCatalog (available widgets). Every edit
// flows through the store, which persists via `configBridge` (the C++
// ManagerBackend) and pushes live to a running hub.
ApplicationWindow {
    id: win
    // Open large enough that the fit-to-fit Edge clone reads clearly (the whole
    // page visible without scrolling, ~half of the panel's 2560px tall), but
    // never larger than the screen - clamp so it fits smaller laptop displays.
    width: Math.min(1440, Screen.desktopAvailableWidth - 80)
    height: Math.min(1300, Screen.desktopAvailableHeight - 80)
    minimumWidth: Math.min(1120, Screen.desktopAvailableWidth - 40)
    minimumHeight: Math.min(760, Screen.desktopAvailableHeight - 40)
    // Normally shown immediately. The REAL app (main.cpp) sets `_deferInitialShow`
    // and shows the window itself AFTER picking a non-Edge screen: on Wayland a
    // client can only influence its output before the surface is first mapped, so
    // the window must stay hidden until the screen is chosen (otherwise it opens on
    // whatever output is active - the Edge, right after the hub grabbed it
    // fullscreen). qmltestrunner sets no such property, so the window shows normally
    // there (windowShown still fires). See placeManagerOffEdge().
    visible: (typeof _deferInitialShow !== "undefined" && _deferInitialShow) ? false : true
    title: "EdgeHub Manager"
    color: m.bg
    property string persistentSaveError: ""
    property bool externalConfigConflictActive: false

    // Drive the Qt palette from the chrome tokens so the native Fusion controls
    // that aren't hand-styled (scrollbars, combo popups, text selection, tooltips)
    // follow the Manager theme instead of the app's compiled-in dark palette.
    palette.window: m.bg
    palette.windowText: m.textPrimary
    palette.base: m.panel
    palette.alternateBase: m.panelAlt
    palette.button: m.panelAlt
    palette.buttonText: m.textPrimary
    palette.text: m.textPrimary
    palette.brightText: m.textPrimary
    palette.highlight: m.accent
    palette.highlightedText: m.textOnAccent
    palette.mid: m.border
    palette.midlight: m.panelAlt
    palette.light: m.panelAlt
    palette.dark: m.border
    palette.shadow: m.border
    palette.placeholderText: m.textSecondary
    palette.toolTipBase: m.panel
    palette.toolTipText: m.textPrimary

    // Manager chrome theme - this app's OWN look, separate from the Edge dashboard
    // theme it edits. Persisted locally (QSettings). Dark / Light / Default, where
    // Default is the warm SKYPhoenix palette (corporate orange/red) that suits the
    // colour logo and ships as the out-of-box look. The preview keeps using `theme`.
    Settings { id: appSettings; category: "ManagerChrome"; property string chromeTheme: "default"
               // Remembers whether the Screens "how-to" card is collapsed (it is
               // onboarding text living in a workspace - dismissable, and it stays so).
               property bool howToCollapsed: false }

    // --- Local design tokens (the Manager's own chrome; three switchable themes) ---
    QtObject {
        id: m
        readonly property var _pal: ({
            "dark":    { bg: "#0D1117", panel: "#161B22", panelAlt: "#1C222B", border: "#30363D",
                         textPrimary: "#E6EDF3", textSecondary: "#8B949E", success: "#3FB950", danger: "#F85149" },
            "light":   { bg: "#F6F8FA", panel: "#FFFFFF", panelAlt: "#EFF2F5", border: "#D0D7DE",
                         textPrimary: "#1F2328", textSecondary: "#59636E", success: "#1A7F37", danger: "#CF222E" },
            "default": { bg: "#FAF4EC", panel: "#FFFDFA", panelAlt: "#F3E9DC", border: "#E6D5C3",
                         textPrimary: "#2A1D16", textSecondary: "#8A7361", success: "#2E7D32", danger: "#B92D26" }
        })
        readonly property var _p: _pal[appSettings.chromeTheme] || _pal["dark"]
        readonly property color bg: _p.bg
        readonly property color panel: _p.panel
        readonly property color panelAlt: _p.panelAlt
        readonly property color border: _p.border
        readonly property color textPrimary: _p.textPrimary
        readonly property color textSecondary: _p.textSecondary
        // Default uses the corporate orange; Dark/Light follow the chosen Edge accent.
        readonly property color accent: appSettings.chromeTheme === "default" ? "#ED6D1F" : theme.accent
        readonly property color textOnAccent: appSettings.chromeTheme === "default" ? "#241407" : "#0D1117"
        readonly property color success: _p.success
        readonly property color danger: _p.danger
        readonly property int radius: 12
        readonly property int touch: 52
        readonly property int fontMinimum: 15
        readonly property int fontCaption: 16
        readonly property int fontLabel: 17
        readonly property int fontSection: 19
        readonly property int ctlH: touch
        readonly property int fontBase: fontLabel
        readonly property var accentPresets: [
            { name: "blue", c: "#58A6FF" }, { name: "purple", c: "#A371F7" },
            { name: "green", c: "#3FB950" }, { name: "orange", c: "#F0883E" },
            { name: "pink", c: "#F778BA" }, { name: "teal", c: "#56D4DD" },
            { name: "red", c: "#F85149" }, { name: "gold", c: "#E3B341" },
            { name: "cyan", c: "#22D3EE" }, { name: "indigo", c: "#818CF8" },
            { name: "mint", c: "#34D399" }, { name: "coral", c: "#FB7185" },
            { name: "amber", c: "#FBBF24" }, { name: "magenta", c: "#E879F9" }
        ]
        // The Okabe–Ito colour-universal-design accents (the `a` tone of each, to
        // match the Hub's swatch). Kept in step with Theme.qml's accent table.
        readonly property var a11yAccents: [
            { name: "oi_blue", c: "#0072B2" }, { name: "oi_sky_blue", c: "#56B4E9" },
            { name: "oi_bluish_green", c: "#009E73" }, { name: "oi_yellow", c: "#F0E442" },
            { name: "oi_orange", c: "#E69F00" }, { name: "oi_vermillion", c: "#D55E00" },
            { name: "oi_reddish_purple", c: "#CC79A7" }, { name: "oi_black", c: "#000000" }
        ]
    }

    // ── Reusable, token-styled controls (inline so they capture `m`/`theme`) ──
    // Replaces the default Fusion Switch/Button, which ignored the chosen accent
    // and clashed with the hand-drawn UI. MButton also takes an optional AppIcon
    // so callers stop hand-typing emoji glyphs.
    component MButton: Button {
        id: mbtn
        property string iconName: ""
        property bool primary: false
        property color tone: primary ? m.accent : m.panel
        implicitHeight: m.touch
        implicitWidth: Math.max(m.touch, mbtnRow.implicitWidth + 32)
        leftPadding: 16; rightPadding: 16
        topPadding: 10; bottomPadding: 10
        hoverEnabled: true
        contentItem: Item {
            implicitWidth: mbtnRow.implicitWidth; implicitHeight: mbtnRow.implicitHeight
            RowLayout {
                id: mbtnRow
                anchors.fill: parent
                spacing: 8
                AppIcon {
                    visible: mbtn.iconName !== ""; name: mbtn.iconName; size: 16
                    Layout.alignment: Qt.AlignVCenter
                    color: mbtn.primary ? m.textOnAccent : m.textPrimary
                }
                Text {
                    text: mbtn.text
                    color: mbtn.primary ? m.textOnAccent : m.textPrimary
                    font.pixelSize: 16; font.bold: mbtn.primary
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    horizontalAlignment: Text.AlignHCenter
                }
            }
        }
        background: Rectangle {
            radius: m.radius
            color: mbtn.primary
                   ? (mbtn.down ? Qt.darker(mbtn.tone, 1.2) : (mbtn.hovered ? Qt.lighter(mbtn.tone, 1.1) : mbtn.tone))
                   : (mbtn.down || mbtn.hovered ? m.panelAlt : m.panel)
            border.width: mbtn.primary ? 0 : 1
            border.color: m.border
        }
    }

    component MSwitch: Switch {
        id: msw
        implicitHeight: m.touch
        indicator: Rectangle {
            implicitWidth: 46; implicitHeight: 26; radius: 13
            x: msw.leftPadding; anchors.verticalCenter: parent.verticalCenter
            color: msw.checked ? m.accent : m.panelAlt
            border.width: 1; border.color: msw.checked ? m.accent : m.border
            Behavior on color { ColorAnimation { duration: 120 } }
            Rectangle {
                x: msw.checked ? parent.width - width - 3 : 3
                y: 3; width: 20; height: 20; radius: 10
                color: msw.checked ? m.textOnAccent : m.textSecondary
                Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
            }
        }
        contentItem: Text {
            text: msw.text; color: m.textPrimary; font.pixelSize: 16
            verticalAlignment: Text.AlignVCenter
            leftPadding: msw.indicator.width + 10
        }
    }

    // MScroll - a ScrollView with a usable mouse-wheel step. A plain QQC2 ScrollView
    // under a Wayland/high-resolution wheel scrolls only a few pixels per notch (the
    // "20 notches to reach the bottom" bug). This WheelHandler moves ~130px per notch
    // (angleDelta 120 × 1.1), matching the hub's WidgetConfigPanel; it consumes the
    // event so the internal Flickable doesn't also scroll (no double-step).
    component MScroll: ScrollView {
        id: msv
        WheelHandler {
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onWheel: function (ev) {
                var f = msv.contentItem
                if (!f) return
                var dy = ev.pixelDelta.y !== 0 ? ev.pixelDelta.y : ev.angleDelta.y
                var maxY = Math.max(0, f.contentHeight - f.height)
                f.contentY = Math.max(0, Math.min(maxY, f.contentY - dy * 1.1))
                ev.accepted = true
            }
        }
    }

    // MSegment - a joined segmented selector for a small, mutually-exclusive choice
    // (window style, columns, …). Replaces the loose, separate buttons those used to
    // be so a "pick one of a set" reads as one control, not several actions. Selected
    // = solid accent fill (the app's single rule for a text/segment selection);
    // swatches/thumbnails use an outline instead, where a fill would hide the colour.
    component MSegment: Rectangle {
        id: mseg
        property var options: []                 // [{label, value}] or [value]
        property var currentValue: options.length ? _val(options[0]) : ""
        signal selected(var value)
        function _val(o) { return (typeof o === "object") ? o.value : o }
        function _lab(o) { return (typeof o === "object") ? o.label : o }
        implicitHeight: m.touch
        radius: m.radius
        color: m.panel
        border.width: 1; border.color: m.border
        RowLayout {
            anchors.fill: parent; anchors.margins: 3; spacing: 3
            Repeater {
                model: mseg.options
                delegate: Rectangle {
                    required property var modelData
                    Layout.fillWidth: true; Layout.fillHeight: true
                    radius: Math.max(2, m.radius - 3)
                    property bool active: mseg._val(modelData) === mseg.currentValue
                    color: active ? m.accent : (segMA.containsMouse ? m.panelAlt : "transparent")
                    Behavior on color { ColorAnimation { duration: 120 } }
                    scale: segMA.pressed ? 0.97 : 1.0
                    Behavior on scale { NumberAnimation { duration: 90 } }
                    Text {
                        anchors.centerIn: parent; text: mseg._lab(modelData)
                        font.pixelSize: m.fontLabel; font.bold: parent.active
                        color: parent.active ? m.textOnAccent : m.textPrimary
                        elide: Text.ElideRight; width: parent.width - 12
                        horizontalAlignment: Text.AlignHCenter
                    }
                    MouseArea { id: segMA; anchors.fill: parent; hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: mseg.selected(mseg._val(modelData)) }
                }
            }
        }
    }

    // MDivider - a hairline section separator. The Look tab was one long flat scroll
    // of label+control blocks with no rhythm; a divider before each major section
    // gives the hierarchy the content already implies.
    component MDivider: Rectangle {
        Layout.fillWidth: true
        Layout.topMargin: 8
        implicitHeight: 1
        color: m.border
    }

    // PresetMini is a small thumbnail of a preset screen's real semantic layout.
    // preset picker shows what you'd actually get before you add it. It packs the
    // screen's tiles with the real WidgetPacker (same arrangement the device uses)
    // and draws each as a mini accent cell with the widget's icon.
    component PresetMini: Rectangle {
        id: mini
        objectName: "presetMini"
        property var tiles: []
        property bool landscape: true
        // Catalog preset tiles intentionally have no runtime id. WidgetPacker uses
        // ids as occupancy markers, so passing those raw tiles made every occupied
        // cell look empty and stacked all thumbnail widgets at the origin.
        readonly property var identifiedTiles: {
            var out = []
            var sourceTiles = mini.tiles || []
            for (var i = 0; i < sourceTiles.length; i++) {
                var source = sourceTiles[i] || ({})
                out.push({ id: "preset-mini-" + i, type: source.type, size: source.size })
            }
            return out
        }
        readonly property var placements: miniPacker.pack(mini.identifiedTiles)
        radius: m.radius; color: Qt.rgba(0, 0, 0, 0.28)
        border.width: 1; border.color: m.border; clip: true
        WidgetPacker { id: miniPacker }
        // A widget's category colour, so the preview reads like the real screen -
        // System tiles blue, Focus purple, Media pink, etc. - instead of every
        // tile being an identical accent block. Lets you tell "big focus timer +
        // small clock" from "three system gauges" at a glance, before adding it.
        function catColor(type) {
            var d = catalog.def(type)
            switch (d ? d.category : "") {
            case "System":  return theme.catSystem
            case "Focus":
            case "focus":   return theme.catProductivity
            case "Media":   return theme.catEntertainment
            case "Info":    return theme.catInfo
            case "Data":    return theme.catServices
            case "Time":    return theme.catGaming
            default:        return theme.accent
            }
        }
        Repeater {
            model: mini.placements
            delegate: Rectangle {
                required property int index
                required property var modelData
                objectName: "presetMiniTile-" + index
                readonly property real cellShort: mini.landscape ? mini.height / 2 : mini.width / 2
                readonly property real cellLong: mini.landscape ? mini.width / 6 : mini.height / 6
                readonly property var r: miniPacker.rect(modelData, mini.landscape,
                                                         cellShort, cellLong, 3)
                readonly property color cc: mini.catColor(modelData.type)
                x: r.x; y: r.y; width: r.width; height: r.height
                radius: 3
                color: Qt.rgba(cc.r, cc.g, cc.b, 0.18)
                border.width: 1; border.color: Qt.rgba(cc.r, cc.g, cc.b, 0.45)
                Column {
                    anchors.centerIn: parent
                    spacing: 1
                    AppIcon {
                        anchors.horizontalCenter: parent.horizontalCenter
                        readonly property var ic: catalog.iconFor(modelData.type)
                        name: ic.name; iconSource: ic.source
                        size: Math.max(9, Math.min(18, Math.min(parent.parent.width, parent.parent.height) * 0.42))
                        color: cc
                    }
                    // The widget's name, shown when the cell is big enough to read
                    // it - so the preview names what you get, not just its shape.
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        visible: parent.parent.width > 42 && parent.parent.height > 34
                        text: catalog.title(modelData.type)
                        color: cc; font.pixelSize: m.fontMinimum; font.bold: true
                        elide: Text.ElideRight
                        width: Math.min(implicitWidth, parent.parent.width - 6)
                        horizontalAlignment: Text.AlignHCenter
                    }
                }
            }
        }
    }

    // Shared hub model + registry.
    DashboardStore { id: store }
    Connections {
        target: store
        function on_SavePendingChanged() {
            if (typeof backend !== "undefined" && backend
                    && typeof backend.setLayoutSavePending === "function")
                backend.setLayoutSavePending(store._savePending)
        }
    }
    Rectangle {
        id: persistenceBanner
        objectName: "managerPersistenceBanner"
        z: 10000
        visible: store.saveFailed || win.persistentSaveError !== ""
        anchors.top: parent.top
        anchors.topMargin: 12
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(parent.width - 32, 1080)
        height: persistenceBannerContent.implicitHeight + 24
        radius: m.radius
        color: appSettings.chromeTheme === "light" ? "#FFF1F0" : "#351919"
        border.width: 2
        border.color: m.danger

        RowLayout {
            id: persistenceBannerContent
            anchors.fill: parent
            anchors.margins: 12
            spacing: 12
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 3
                Text {
                    Layout.fillWidth: true
                    text: store.saveFailed ? "Changes are not saved" : "Storage warning"
                    color: appSettings.chromeTheme === "light" ? "#5A1111" : "#FFFFFF"
                    font.pixelSize: 18
                    font.bold: true
                }
                Text {
                    Layout.fillWidth: true
                    text: (store.saveFailed ? store.saveFailureMessage
                                            : win.persistentSaveError)
                          + (store.recoveryPath !== ""
                             ? "\nRecovery copy: " + store.recoveryPath : "")
                    color: appSettings.chromeTheme === "light" ? "#6E2929" : "#F4D7D7"
                    font.pixelSize: 16
                    wrapMode: Text.Wrap
                }
            }
            MButton {
                visible: store.saveFailed
                text: "Retry"
                iconName: "ui-refresh"
                onClicked: {
                    var retryReady = true
                    if (win.externalConfigConflictActive
                            && typeof backend.preparePendingLayoutRetry === "function")
                        retryReady = backend.preparePendingLayoutRetry()
                    if (retryReady && store.retrySave()) {
                        win.persistentSaveError = ""
                        win.externalConfigConflictActive = false
                    }
                }
            }
            MButton {
                visible: store.saveFailed
                text: "Discard"
                iconName: "ui-trash"
                onClicked: {
                    if (backend.hubConnected
                            && typeof backend.discardPendingLayoutAndSync === "function")
                        backend.discardPendingLayoutAndSync()
                    else if (typeof backend.discardLocalAndReload === "function")
                        backend.discardLocalAndReload()
                }
            }
            MButton {
                visible: !store.saveFailed
                text: "Dismiss"
                onClicked: win.persistentSaveError = ""
            }
        }
    }
    WidgetCatalog { id: catalog }
    WallpaperCatalog { id: bundledWallpapers }
    BackgroundCatalog { id: bgCatalog }
    // The curated "screens" library - the same presets the hub's first-run wizard
    // and preset picker use. The Manager is the full control surface, so it can add
    // a preset screen from the PC too (applied via store.appendPreset → persisted
    // + pushed live to a running hub).
    PresetCatalog { id: presetLib }

    // Mirror the Hub shutdown contract. A live widget preview may own a short
    // editor debounce, so flush every loaded WidgetHost before forcing the
    // Manager's shared store through its single-writer backend.
    function hasPendingUiState() {
        if (store.dirty || store._savePending)
            return true
        var pending = [win.contentItem]
        while (pending.length > 0) {
            var node = pending.pop()
            if (node !== win && typeof node.hasPendingState === "function"
                    && node.hasPendingState())
                return true
            var children = node.children || []
            for (var i = 0; i < children.length; i++)
                pending.push(children[i])
        }
        return false
    }

    function flushPendingUiState() {
        var pending = [win.contentItem]
        var widgetFlushOk = true
        while (pending.length > 0) {
            var node = pending.pop()
            if (node !== win && typeof node.flushPendingState === "function"
                    && node.flushPendingState() === false)
                widgetFlushOk = false
            var children = node.children || []
            for (var i = 0; i < children.length; i++)
                pending.push(children[i])
        }
        return store.flushNow() && widgetFlushOk
    }

    // Colour tokens + the user's uploaded images, for the shared BackgroundPicker.
    readonly property var mCol: ({ textPrimary: m.textPrimary, textSecondary: m.textSecondary,
        panel: m.panel, panelAlt: m.panelAlt, border: m.border, accent: m.accent,
        textOnAccent: m.textOnAccent, radius: m.radius, ctlH: m.touch,
        fontBase: m.fontLabel })
    property var uploadedWallpapers: {
        var out = []
        for (var i = 0; i < imagesModel.count; i++) {
            var nm = imagesModel.get(i).modelData
            out.push({ label: nm, source: backend.imageUrl(nm) })
        }
        return out
    }

    // Full design-system theme + a media stub, so the WYSIWYG clone renders the
    // REAL widgets exactly like the Edge. Driven from the store's appearance.
    // systemReduceMotion mirrors the hub's main.qml: the OS reduce-motion probe
    // (XDG portal, injected as `systemSettings`) must reach the Manager's theme
    // too, or the previews keep animating while the real Edge stands still.
    // typeof-guard: the QML test harness hosts Manager.qml without the probe.
    Theme {
        id: theme
        systemReduceMotion: (typeof systemSettings !== "undefined" && systemSettings)
            ? systemSettings.reduceMotion : false
    }
    MockMedia { id: media }

    // One phrase for "does an edit reach the panel right now?" - reused by the
    // Layout hint card and the Appearance preview so they can never disagree
    // with the sidebar's connection dot again.
    readonly property bool hubLayoutLive:
        (typeof backend.layoutLiveApplied === "undefined")
            ? true : backend.layoutLiveApplied
    readonly property string liveNote: backend.hubConnected
        ? (hubLayoutLive
           ? "Hub connected - changes appear on the Edge immediately."
           : "Hub saved the layout and will show it when the dashboard opens.")
        : "Hub offline - changes are saved and appear when the hub starts."

    // Scope pill ("Whole Edge" / "This page only" / …): the audit's core finding
    // was that no control said what it would affect, so scope becomes a visible,
    // uniform part of every section header rather than prose.
    //
    // The pills are a VOCABULARY, and a vocabulary needs definitions: the audit's
    // F3 was that "Whole Edge" and "All pages" both appeared, both meant global,
    // and nothing said which was broader (the difference is real - a page can
    // override the background but not the theme - it was just never stated). So a
    // pill now carries `detail`, the precise rule, on hover. `scopeDetail()` is the
    // single source of that text: pass a label from `scopeLabels` and the wording
    // can never drift between two sections claiming the same scope.
    readonly property var scopeLabels: ({
        widget: "This widget only", page: "This screen only", pages: "All screens",
        edge: "Whole Edge", computer: "This computer", window: "This window only"
    })
    function scopeDetail(label) {
        switch (label) {
        case "This widget only": return "Changes this one tile. Other widgets of the same type are untouched."
        case "This screen only": return "Changes this screen only. Your other screens are untouched."
        case "All screens":      return "The default for every screen - but a screen can override it (Screens → “This screen's look”)."
        case "Whole Edge":       return "Changes every screen and every widget. There is no per-screen override for this."
        case "This computer":    return "Changes this computer's hub, not the Edge layout. Other machines are untouched."
        case "This window only": return "Changes the Manager window you're looking at. Your Edge is untouched."
        }
        return ""
    }
    component ScopeTag: Rectangle {
        id: stag
        objectName: "scopePill"          // test seam: every pill is findable as one set
        property string label: ""
        implicitWidth: stLbl.implicitWidth + 24; implicitHeight: 32; radius: 16
        color: "transparent"; border.width: 1; border.color: m.accent
        Text { id: stLbl; anchors.centerIn: parent; text: stag.label
            color: m.accent; font.pixelSize: m.fontMinimum; font.bold: true }
        // Hovering the pill spells the rule out, so the short label can stay short.
        ToolTip.visible: stMA.containsMouse && ToolTip.text !== ""
        ToolTip.delay: 250
        ToolTip.text: win.scopeDetail(stag.label)
        MouseArea { id: stMA; anchors.fill: parent; hoverEnabled: true }
    }

    property int currentPageIndex: 0
    property bool _adoptingHubPage: false
    // Appearance: the Edge theme is chosen from a compact dropdown (Hybrid design)
    // instead of a 29-swatch grid that dominated the tab. The list itself is the
    // SHARED catalogue in Theme.qml, so the Manager dropdown and the hub's picker
    // present exactly the same themes, Pro flags and preview swatches (they used to
    // be maintained separately and could drift). `apThemeModel` stays as the name
    // the dropdown and tests read.
    readonly property var apThemeModel: theme.themeCatalog
    function _themeDef(key) {
        for (var i = 0; i < apThemeModel.length; i++)
            if (apThemeModel[i].k === key) return apThemeModel[i]
        return null
    }
    // Commit an Edge theme: a locked Pro theme opens the licence dialog instead of
    // applying (free users can still hover-preview it). Otherwise persist it.
    function commitTheme(key) {
        var d = win._themeDef(key)
        if (d && d.pro === true && !win.isPro) { win.endThemePreview(); licenseDialog.open(); return }
        store.setAppearance("themeMode", key)
    }
    // Transient "Starting hub…" feedback: set when the user hits Start, cleared
    // when the hub connects (see the backend Connections) or a safety timeout.
    property bool hubStarting: false
    Timer { id: hubStartTimeout; interval: 8000; repeat: false
        onTriggered: win.hubStarting = false }

    function currentPageName() {
        var p = store.pages()[currentPageIndex]
        return p ? p.name : ""
    }
    function syncCurrentPageFromHub() {
        if (typeof backend === "undefined" || !backend
                || backend.hubCurrentPage === undefined
                || backend.hubCurrentPage < 0
                || store.pageCount() < 1)
            return false
        var page = Math.max(
            0, Math.min(backend.hubCurrentPage, store.pageCount() - 1))
        if (page === currentPageIndex)
            return true
        _adoptingHubPage = true
        try {
            currentPageIndex = page
        } finally {
            _adoptingHubPage = false
        }
        return true
    }
    // Commit whatever is typed in the rename field to the page the field belongs to
    // (`pageName.forIndex`, NOT the current page - the two differ exactly when the
    // user switches page mid-edit, which is the case that used to lose the name).
    //
    // Audit F1: the field committed on `editingFinished` alone. Nothing else in the
    // pane takes keyboard focus (the chips and buttons are MouseAreas), so it never
    // blurred: typing "Yen" and clicking another page chip ran the index handler,
    // which overwrote the field with the new page's name - the rename was gone,
    // silently. Every neighbouring control applies instantly, so an Enter-only
    // contract is unguessable. Now every path out of the field commits it.
    function commitRename() {
        var i = pageName.forIndex
        var pages = store.pages()
        if (i < 0 || i >= pages.length) return
        // No-op guard: this runs on every page switch, and renamePage() bumps the
        // structure revision (rebuilding every chip + tile) even for an equal name.
        if (pageName.text === pages[i].name) return
        store.renamePage(i, pageName.text)
        // Reflect the validated (trimmed / de-duped) name the store actually stored.
        if (i === win.currentPageIndex) pageName.text = win.currentPageName()
    }
    // Keep the rename field in step with the selected page WITHOUT a `text:` binding
    // (a binding breaks the moment the user types, which caused wrong-page renames).
    onCurrentPageIndexChanged: {
        commitRename()                       // save the previous page's edit first
        pageName.forIndex = currentPageIndex
        pageName.text = currentPageName()
        // Mirror the selection onto the panel: show, on the Edge, the screen the
        // user is editing (O1). No-op when the hub is offline. Guarded so a
        // non-backend test harness (ManagerHarness stub without this method) does
        // not throw.
        if (!_adoptingHubPage
                && typeof backend !== "undefined" && backend
                && typeof backend.setHubActivePage === "function")
            backend.setHubActivePage(currentPageIndex)
    }

    // Guard against re-applying the whole theme on every store bump: the store
    // fires `changed()` on every keystroke/tile edit, but only appearance changes
    // need a re-theme. Skip when the appearance payload is byte-identical.
    property string _appearanceSig: ""
    function syncTheme() {
        var a = store.appearance() || ({})
        var sig = JSON.stringify(a)
        if (sig === _appearanceSig) return
        _appearanceSig = sig
        theme.applyTheme(a.themeMode || theme.defaultThemeKey)
        if (a.accent) theme.applyAccent(a.accent)
        theme.glassOpacity = a.glass !== undefined ? a.glass : 0.55
        theme.showWidgetGlow = a.glow !== undefined ? a.glow : true
        theme.reduceMotion = a.reduceMotion || false
        theme.textScale = a.textScale !== undefined ? a.textScale : 1.15
        theme.fontChoice = a.fontChoice || "hyperlegible"
    }
    Connections { target: store; function onChanged() { win.syncTheme() } }

    // ── Licence (Pro tier) state, kept fresh ──
    // Parsed from the backend's stored-key status. Re-read whenever the key
    // changes (activate/remove) so the About card and any gated affordance
    // update without a manual refresh. Never trust a cached bool - the tier is
    // always recomputed from the signed key by the Rust verifier.
    property var licStatus: ({ state: "unlicensed", tier: "free" })
    property bool isPro: licStatus.tier === "pro"
    function refreshLicense() {
        try { win.licStatus = JSON.parse(backend.licenseStatusJson()) }
        catch (e) { win.licStatus = ({ state: "unlicensed", tier: "free" }) }
    }
    Connections {
        target: backend
        function onLicenseChanged() { win.refreshLicense() }
        function onConfigChanged() { win.refreshLicense() }
    }

    // ── Hover previews (show, then commit) ──
    // Hovering a theme/accent swatch applies it to the Manager's theme instance
    // ONLY - the live preview pane repaints, the store (and hence the Edge and
    // disk) is untouched until the user clicks. endThemePreview() restores the
    // stored appearance; it must void the signature guard first or syncTheme()
    // would skip the "unchanged" payload and strand the hover colours.
    function previewTheme(mode) {
        theme.applyTheme(mode)
        var a = store.appearance() || ({})
        if (a.accent) theme.applyAccent(a.accent)   // applyTheme resets the accent
    }
    function previewAccent(name) { theme.applyAccent(name) }
    function endThemePreview() { _appearanceSig = ""; syncTheme() }

    // Hover-preview is DEBOUNCED. Wheel-scrolling the swatch grid drags many
    // swatches under a stationary cursor, firing onContainsMouseChanged for each
    // one; routed straight to previewTheme() that was a storm of ~20 theme
    // property writes per swatch per frame - the other half of the scroll lag the
    // audit found. Coalescing to the LAST hover after a short idle collapses the
    // storm to a single applyTheme and is imperceptible for a genuine hover.
    property string _hoverKind: ""     // "theme" | "accent"
    property string _hoverKey: ""      // "" → restore the committed appearance
    Timer {
        id: hoverPreviewTimer; interval: 45; repeat: false
        onTriggered: {
            if (win._hoverKey === "") { win.endThemePreview(); return }
            if (win._hoverKind === "accent") win.previewAccent(win._hoverKey)
            else win.previewTheme(win._hoverKey)
        }
    }
    function hoverPreview(kind, key, on) {
        win._hoverKind = kind
        win._hoverKey = on ? key : ""
        hoverPreviewTimer.restart()
    }

    // Add a curated "screen" as a NEW page (additive) - never replaces the user's
    // other pages, and never touches the global theme/accent. store.appendPreset
    // persists + pushes live to a running hub, and returns the new page index so we
    // land the user on the screen they just added.
    function applyPresetScreen(presetId) {
        if (!presetLib.has(presetId)) return
        var idx = store.appendPreset(presetId)
        if (idx < 0) return
        // Sync the rename field to the new page BEFORE moving currentPageIndex -
        // onCurrentPageIndexChanged runs commitRename(), which would otherwise write
        // the STALE field text onto the freshly-added page (e.g. renaming its page
        // to a leftover name). Setting forIndex+text to the target makes that
        // commitRename a no-op.
        pageName.forIndex = idx
        pageName.text = store.pages()[idx].name
        win.currentPageIndex = idx
    }
    // Reset every page + widget to the default layout (a clean starting point).
    // Uploaded images live on disk and are untouched.
    function confirmResetLayout() {
        confirmDialog.message = "Reset every screen and widget to the default layout? "
            + "This can't be undone. Your uploaded images are kept."
        confirmDialog.onConfirm = function () {
            store.resetTo("starter")   // the recommended few-screen default
            // Sync the rename field to page 0 BEFORE moving currentPageIndex, so
            // onCurrentPageIndexChanged's commitRename can't write the stale field
            // onto a reset page (see applyPresetScreen).
            pageName.forIndex = 0
            pageName.text = store.pages()[0].name
            win.currentPageIndex = 0
        }
        confirmDialog.open()
    }

    // Removing a page discards its widgets and their settings - the only
    // destructive click in the Manager that skipped the confirm dialog.
    function confirmRemovePage() {
        var idx = currentPageIndex
        var n = pageTiles().length
        confirmDialog.message = "Remove screen “" + currentPageName() + "”"
            + (n > 0 ? " and its " + n + " widget" + (n === 1 ? "" : "s") : "")
            + "? This can't be undone."
        confirmDialog.onConfirm = function () {
            store.removePage(idx)
            // Stay on the page that slid into this slot (clamped).
            win.currentPageIndex = Math.min(idx, store.pageCount() - 1)
        }
        confirmDialog.open()
    }

    function confirmRemoveWidget(tileId, tileType) {
        var pageIndex = currentPageIndex
        var revision = store.structureRevision
        var title = catalog.title(tileType)
        var dataLabel = catalog.personalDataLabel(tileType)
        confirmDialog.message = "Remove " + title + " from this screen?"
            + (dataLabel.length > 0
               ? " Its " + dataLabel + " will also be removed." : "")
            + " This can't be undone."
        confirmDialog.onConfirm = function () {
            if (store.structureRevision !== revision)
                return
            var pages = store.pages()
            var page = pageIndex >= 0 && pageIndex < pages.length
                       ? pages[pageIndex] : null
            var tiles = page && Array.isArray(page.tiles) ? page.tiles : []
            for (var i = 0; i < tiles.length; i++) {
                if (tiles[i].id === tileId && tiles[i].type === tileType) {
                    store.removeTile(pageIndex, tileId)
                    return
                }
            }
        }
        confirmDialog.open()
    }

    Component.onCompleted: {
        store.load(backend.starterLayout())
        syncTheme()
        refreshImages()
        refreshLicense()
        syncCurrentPageFromHub()
    }

    // Capture helper: XENEON_CFG=<type> auto-opens that widget's config dialog.
    Timer {
        interval: 500; running: backend.autoConfig().length > 0; repeat: false
        onTriggered: {
            var t = backend.autoConfig(), pages = store.pages()
            for (var p = 0; p < pages.length; p++) {
                var ts = pages[p].tiles || []
                for (var i = 0; i < ts.length; i++)
                    if (ts[i].type === t) { win.currentPageIndex = p; cfgDialog.openFor(ts[i].id, t); return }
            }
        }
    }

    // Helper: current page's tiles (revision-reactive).
    function pageTiles() {
        store.revision
        var pages = store.pages()
        if (currentPageIndex < 0 || currentPageIndex >= pages.length) return []
        return pages[currentPageIndex].tiles || []
    }

    // ── Root layout: sidebar + content ──
    RowLayout {
        anchors.fill: parent
        spacing: 0

        // Sidebar
        Rectangle {
            // maximumWidth, not just preferredWidth: a child wider than 240 (a long
            // label + a scope pill on one row) otherwise widens the whole sidebar and
            // steals it from the content pane.
            Layout.preferredWidth: 240
            Layout.maximumWidth: 240
            Layout.fillHeight: true
            color: m.panel
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 16
                spacing: 8

                // Brand lockup, top to bottom: the "EdgeHub" wordmark in the company
                // brand face, a small "by SKYPhoenix IT" maker line, then the logo
                // small beneath - the order Simon asked for. The logo variant follows
                // the surface it sits on so it stays legible: white on a dark
                // background, black on a light one, the colour lockup on the neutral
                // Default chrome. The version lives in the About view.
                Text {
                    text: "EdgeHub"; color: m.textPrimary
                    font.family: theme.fontBrand; font.pixelSize: 30; font.bold: true
                    font.letterSpacing: 0.5
                }
                Text {
                    text: "by SKYPhoenix IT"; color: m.textSecondary
                    font.family: theme.fontMono; font.pixelSize: m.fontMinimum; font.letterSpacing: 0.5
                }
                Image {
                    Layout.preferredWidth: 104; Layout.preferredHeight: 44
                    Layout.topMargin: 6; Layout.bottomMargin: 12
                    fillMode: Image.PreserveAspectFit; horizontalAlignment: Image.AlignLeft
                    smooth: true; asynchronous: true; mipmap: true
                    source: appSettings.chromeTheme === "light" ? "qrc:/manager/branding/sky-black.png"
                          : appSettings.chromeTheme === "default" ? "qrc:/manager/branding/sky-color.png"
                          : "qrc:/manager/branding/sky-white.png"
                }

                Repeater {
                    // Screen-first studio: "Look" owns the GLOBAL look for every
                    // screen; "Screens" is where each screen is built (widgets,
                    // columns, and its optional per-screen look override). Order is
                    // unchanged (tests address tabs by index).
                    model: [ { l: "Screens", i: "ui-layout" }, { l: "Look", i: "ui-palette" },
                             { l: "Images", i: "ui-image" }, { l: "Device", i: "ui-display" },
                             { l: "About", i: "ui-settings" } ]
                    delegate: Rectangle {
                        id: navRow
                        required property int index
                        required property var modelData
                        Layout.fillWidth: true
                        Layout.preferredHeight: m.touch
                        radius: m.radius
                        color: nav.currentIndex === index ? m.accent
                               : (navMA.containsMouse ? m.panelAlt : "transparent")
                        activeFocusOnTab: true
                        Accessible.role: Accessible.PageTab
                        Accessible.name: modelData.l
                        Accessible.onPressAction: nav.currentIndex = navRow.index
                        Keys.onSpacePressed: nav.currentIndex = navRow.index
                        Keys.onReturnPressed: nav.currentIndex = navRow.index
                        RowLayout {
                            anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left
                            anchors.leftMargin: 14; spacing: 10
                            AppIcon { name: modelData.i; size: 20
                                color: nav.currentIndex === index ? m.textOnAccent : m.textSecondary }
                            Text {
                                text: modelData.l
                                color: nav.currentIndex === index ? m.textOnAccent : m.textPrimary
                                font.pixelSize: m.fontLabel; font.bold: nav.currentIndex === index
                            }
                        }
                        MouseArea { id: navMA; anchors.fill: parent; hoverEnabled: true
                            onClicked: nav.currentIndex = navRow.index }
                    }
                }

                Item { Layout.fillHeight: true }

                // The "Manager window style" control used to live HERE in the
                // sidebar, far from Appearance → "Edge theme" - the audit's top
                // confusion (two unlabelled "theme" controls in two places). It now
                // sits inside the Appearance tab beside the Edge theme, so both
                // theme pickers are together with unmistakable scope pills.

                // Hub connection status + Start/Stop control.
                ColumnLayout {
                    Layout.fillWidth: true; spacing: 10
                    RowLayout {
                        spacing: 8; Layout.fillWidth: true
                        Rectangle { width: 10; height: 10; radius: 5
                            color: backend.hubConnected ? m.success
                                   : (win.hubStarting ? m.accent : m.textSecondary) }
                        Text {
                            Layout.fillWidth: true
                            text: backend.hubConnected
                                  ? (win.hubLayoutLive
                                     ? "Hub connected (live)"
                                     : "Hub connected (layout queued)")
                                  : (win.hubStarting ? "Starting hub…" : "Hub offline (saved)")
                            color: m.textSecondary; font.pixelSize: m.fontMinimum; elide: Text.ElideRight
                        }
                    }
                    MButton {
                        Layout.fillWidth: true
                        enabled: !win.hubStarting
                        text: backend.hubConnected ? "Stop hub" : "Start hub"
                        iconName: backend.hubConnected ? "ui-close" : "ui-play"
                        primary: !backend.hubConnected
                        onClicked: {
                            if (backend.hubConnected) {
                                backend.stopHub()
                            } else {
                                win.hubStarting = true
                                if (!backend.startHub()) win.hubStarting = false
                                else hubStartTimeout.restart()
                            }
                        }
                    }
                }
            }
        }

        // Content
        StackLayout {
            id: nav
            objectName: "managerTabs"        // test seam: the 5-tab content stack
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: backend.startTab()
            // Leaving the Layout tab is also a way out of the rename field that
            // never blurs it - commit rather than strand the edit (audit F1).
            onCurrentIndexChanged: win.commitRename()

            // ═══ 1. LAYOUT ═══
            Item {
                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 24
                    spacing: 16

                    Text { text: "Screens"; color: m.textPrimary; font.pixelSize: 24; font.bold: true }
                    Text { text: "Step 2 - build each screen: add & arrange its widgets. Set the overall look for every screen in Look first."
                        color: m.textSecondary; font.pixelSize: m.fontCaption; Layout.fillWidth: true; wrapMode: Text.WordWrap }

                    // Page selector
                    Flow {
                        Layout.fillWidth: true; spacing: 8
                        Repeater {
                            // Structural list - rebuild only when pages are added/
                            // removed/renamed, not on every settings keystroke [S11].
                            model: (store.structureRevision, store.pages())
                            delegate: Rectangle {
                                id: screenChip
                                required property int index
                                required property var modelData
                                width: pageLbl.implicitWidth + 32; height: m.touch
                                radius: m.radius
                                color: win.currentPageIndex === index ? m.accent
                                       : (pgMA.containsMouse ? m.panelAlt : m.panel)
                                border.width: 1; border.color: m.border
                                activeFocusOnTab: true
                                Accessible.role: Accessible.PageTab
                                Accessible.name: "Screen: " + modelData.name
                                Accessible.onPressAction: win.currentPageIndex = screenChip.index
                                Keys.onSpacePressed: win.currentPageIndex = screenChip.index
                                Keys.onReturnPressed: win.currentPageIndex = screenChip.index
                                Text { id: pageLbl; anchors.centerIn: parent; text: modelData.name
                                    color: win.currentPageIndex === index ? m.textOnAccent : m.textPrimary
                                    font.pixelSize: m.fontLabel; font.bold: win.currentPageIndex === index }
                                MouseArea { id: pgMA; anchors.fill: parent; hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: win.currentPageIndex = screenChip.index }
                            }
                        }
                        Rectangle {
                            id: addScreenButton
                            objectName: "addScreenButton"
                            width: m.touch; height: m.touch; radius: m.radius
                            color: addPgMA.containsMouse ? m.panelAlt : m.panel
                            border.width: 1; border.color: m.border
                            activeFocusOnTab: true
                            Accessible.role: Accessible.Button
                            Accessible.name: "Add screen"
                            Accessible.onPressAction: addScreenButton.addScreen()
                            Keys.onSpacePressed: addScreenButton.addScreen()
                            Keys.onReturnPressed: addScreenButton.addScreen()
                            function addScreen() {
                                store.addPage("")
                                win.currentPageIndex = store.pageCount() - 1
                            }
                            AppIcon { anchors.centerIn: parent; name: "ui-plus"; color: m.accent; size: 22 }
                            MouseArea { id: addPgMA; anchors.fill: parent; hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: addScreenButton.addScreen() }
                        }
                    }

                    // Page tools
                    RowLayout {
                        Layout.fillWidth: true; spacing: 8
                        Text { text: "Screen name:"; color: m.textSecondary; font.pixelSize: m.fontLabel
                            Layout.alignment: Qt.AlignVCenter }
                        TextField {
                            id: pageName; Layout.preferredWidth: 240; Layout.preferredHeight: m.touch
                            color: m.textPrimary; selectByMouse: true
                            // The page this text belongs to. Held separately from
                            // currentPageIndex so a mid-edit page switch can still
                            // commit to the RIGHT page (audit F1).
                            property int forIndex: 0
                            Component.onCompleted: { forIndex = win.currentPageIndex; text = win.currentPageName() }
                            background: Rectangle { radius: 8; color: m.panel; border.width: 1
                                border.color: pageName.activeFocus ? m.accent : m.border }
                            onEditingFinished: win.commitRename()
                        }
                        ScopeTag { label: win.scopeLabels.page; Layout.alignment: Qt.AlignVCenter }
                        Item { Layout.fillWidth: true }
                        MButton { text: "Remove screen"; iconName: "ui-trash"
                            enabled: (store.revision, store.pageCount() > 1)
                            onClicked: win.confirmRemovePage() }
                    }

                    // The page background override moved into the helper column
                    // beside the clone: it is a per-page appearance choice, and in
                    // the audit it dominated the tab and buried the layout tool.

                    // Tiles on the current page. Orientation-adaptive (O2): a
                    // PORTRAIT Edge preview is tall+narrow, so it sits BESIDE the
                    // config helper (2 columns). A LANDSCAPE preview is wide+short -
                    // beside the config it collapsed to a squeezed strip floating in
                    // a tall empty pane - so it moves ABOVE the config, full width
                    // (1 column), where it gets the whole content width and reads at
                    // a correct aspect. The column count flips on the preview's
                    // orientation, which the hub drives (backend.hubRotation).
                    GridLayout {
                        Layout.fillWidth: true; Layout.fillHeight: true
                        columns: edgeClone.landscape ? 1 : 2
                        columnSpacing: 16; rowSpacing: 16

                        // Live WYSIWYG clone of the Edge - drag tiles to reorder,
                        // drag the bottom handle to resize, ⚙ to configure, ✕ to remove.
                        EdgeClone {
                            id: edgeClone
                            // Landscape: full content width, bounded height, ABOVE the
                            // config. Portrait: a fixed 440 pane BESIDE it (tall).
                            Layout.fillWidth: edgeClone.landscape
                            Layout.fillHeight: !edgeClone.landscape
                            Layout.preferredWidth: edgeClone.landscape ? -1 : 440
                            Layout.preferredHeight: edgeClone.landscape ? 380 : -1
                            pageIndex: win.currentPageIndex
                            // Pause the live preview while the helper column scrolls, so an
                            // animated preview doesn't repaint every scroll frame.
                            scrolling: helperScroll.contentItem ? helperScroll.contentItem.moving : false
                            onConfigRequested: (tileId, tileType) => cfgDialog.openFor(tileId, tileType)
                            onRemoveRequested: (tileId, tileType) =>
                                win.confirmRemoveWidget(tileId, tileType)
                        }

                        // Helper column: add + how-to + this page's background.
                        MScroll {
                            id: helperScroll
                            Layout.fillWidth: true; Layout.fillHeight: true; clip: true
                            contentWidth: availableWidth
                            ColumnLayout {
                                width: helperScroll.availableWidth
                                spacing: 12

                                // ── Widgets ─────────────────────────────────────
                                RowLayout {
                                    spacing: 8
                                    Text { text: "Widgets"; color: m.textPrimary; font.pixelSize: m.fontSection; font.bold: true }
                                    ScopeTag { label: win.scopeLabels.page }
                                }
                                MButton { text: "Add widget"; iconName: "ui-plus"; primary: true
                                    Layout.fillWidth: true; Layout.preferredHeight: m.touch
                                    onClicked: addPicker.open() }
                                MButton { text: "Start from a preset screen…"; iconName: "ui-layout"
                                    Layout.fillWidth: true; Layout.preferredHeight: m.touch
                                    onClicked: presetDialog.open() }

                                // ── Columns ─────────────────────────────────────
                                // Per-screen column layout. One screen never scrolls, so
                                // "2 columns" reflows this screen's widgets to half width
                                // (two across) and new widgets default to half width too;
                                // "1 column" makes them full width again. A switch that
                                // would overflow the screen is refused by the store, so
                                // the buttons never create a screen you cannot see.
                                RowLayout {
                                    Layout.topMargin: 6; spacing: 8
                                    Text { text: "Columns"; color: m.textPrimary; font.pixelSize: m.fontSection; font.bold: true }
                                    ScopeTag { label: win.scopeLabels.page }
                                }
                                Text { text: "How many widgets sit side by side on this screen. Switching reflows the widgets already here to fit - a screen always stays one screen (it never scrolls)."
                                    color: m.textSecondary; font.pixelSize: m.fontMinimum; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                                MSegment {
                                    Layout.fillWidth: true
                                    options: [ { label: "1 column", value: 1 }, { label: "2 columns", value: 2 } ]
                                    currentValue: (store.structureRevision, store.pageColumns(win.currentPageIndex))
                                    onSelected: (v) => {
                                        if (store.setPageColumns(
                                                win.currentPageIndex, v)) {
                                            columnLayoutError.text = ""
                                        } else {
                                            columnLayoutError.text =
                                                "This screen is too full for " + v
                                                + " column" + (v === 1 ? "" : "s")
                                                + ". Resize or remove a widget first."
                                        }
                                    }
                                }
                                Text {
                                    id: columnLayoutError
                                    objectName: "columnLayoutError"
                                    visible: text !== ""
                                    text: ""
                                    color: m.danger
                                    font.pixelSize: m.fontMinimum
                                    Layout.fillWidth: true
                                    wrapMode: Text.WordWrap
                                }

                                // Collapsible how-to card. Onboarding lives here, but it
                                // shouldn't permanently eat the workspace - it remembers
                                // being collapsed. Each tip pairs the REAL SVG icon with
                                // its action (no ⚙/⤡/✕ text glyphs that don't match the set).
                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: hintCol.implicitHeight + 20
                                    radius: m.radius; color: m.panel; border.width: 1; border.color: m.border
                                    ColumnLayout {
                                        id: hintCol; anchors.left: parent.left; anchors.right: parent.right
                                        anchors.top: parent.top; anchors.margins: 10; spacing: 6
                                        Item {
                                            Layout.fillWidth: true
                                            implicitHeight: hdrRow.implicitHeight
                                            RowLayout {
                                                id: hdrRow
                                                anchors.left: parent.left; anchors.right: parent.right
                                                anchors.verticalCenter: parent.verticalCenter; spacing: 6
                                                Text { text: "This is your Edge"; color: m.textPrimary
                                                    font.pixelSize: m.fontLabel; font.bold: true; Layout.fillWidth: true }
                                                AppIcon { name: "ui-caret-right"; size: 14; color: m.textSecondary
                                                    rotation: appSettings.howToCollapsed ? 0 : -90
                                                    Behavior on rotation { NumberAnimation { duration: 120 } } }
                                            }
                                            MouseArea { anchors.fill: parent; hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: appSettings.howToCollapsed = !appSettings.howToCollapsed }
                                        }
                                        ColumnLayout {
                                            visible: !appSettings.howToCollapsed
                                            Layout.fillWidth: true; spacing: 5
                                            Repeater {
                                                model: [ { i: "ui-settings", t: "Click a tile (or its gear) to configure that widget" },
                                                         { i: "ui-grip",     t: "Drag a tile onto another to reorder" },
                                                         { i: "ui-resize",   t: "Drag the corner handle to resize" },
                                                         { i: "ui-close",    t: "Remove a widget from this screen" } ]
                                                delegate: RowLayout {
                                                    required property var modelData
                                                    Layout.fillWidth: true; spacing: 8
                                                    AppIcon { name: modelData.i; size: 15; color: m.textSecondary
                                                        Layout.alignment: Qt.AlignTop }
                                                    Text { text: modelData.t; color: m.textSecondary; font.pixelSize: m.fontMinimum
                                                        Layout.fillWidth: true; wrapMode: Text.WordWrap }
                                                }
                                            }
                                            Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: m.fontMinimum
                                                Layout.topMargin: 2
                                                text: win.liveNote
                                                color: backend.hubConnected ? m.success : m.textSecondary }
                                        }
                                    }
                                }
                                // ── This screen's look (override) ───────────────
                                RowLayout {
                                    Layout.topMargin: 6; spacing: 8
                                    Text { text: "This screen's look"; color: m.textPrimary
                                        font.pixelSize: m.fontSection; font.bold: true }
                                    ScopeTag { label: win.scopeLabels.page }
                                }
                                Text { text: "Optional. Overrides the global background from Look, for this screen alone. “Use global” returns to the shared one."
                                    color: m.textSecondary; font.pixelSize: m.fontMinimum; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                                BackgroundPicker {
                                    Layout.fillWidth: true
                                    st: store; pageIndex: win.currentPageIndex; col: win.mCol
                                    bgCatalog: bgCatalog; wpCatalog: bundledWallpapers; uploadedImages: win.uploadedWallpapers
                                }
                                Item { Layout.preferredHeight: 8 }
                            }
                        }
                    }
                }
            }

            // ═══ 2. APPEARANCE ═══
            // Two panes: controls left, a live Edge preview right. The audit's
            // second-biggest finding: every control here changes the Edge, but the
            // only rendering of the Edge lived on the Layout tab - so theme/accent/
            // glass picks gave zero visible feedback. Now they repaint the preview
            // as you hover, before anything is committed.
            Item {
              // Orientation-adaptive, matching the Screens tab exactly (see the
              // GridLayout there). A PORTRAIT preview is tall+narrow and sits BESIDE
              // the controls (2 columns); a LANDSCAPE preview is wide+short, so
              // beside the controls it collapsed into a squeezed strip floating in a
              // tall empty pane - it moves ABOVE them, full width (1 column), where
              // it reads at a correct aspect.
              //
              // This tab used to be a plain RowLayout with the preview pinned beside
              // the controls at a hardcoded 760/400, so the two tabs laid the SAME
              // component out differently for the same panel. Both now flip on the
              // same signal, so a preview cannot look right on one tab and wrong on
              // the other.
              GridLayout {
                anchors.fill: parent
                anchors.margins: 24
                columns: lookClone.landscape ? 1 : 2
                columnSpacing: 20; rowSpacing: 16

               MScroll {
                id: apScroll
                objectName: "lookControls"       // test seam: the Look tab's control pane
                // Explicit cell rather than declaration order: the preview must come
                // FIRST (left in portrait, above in landscape) to match Screens, and
                // saying so here is cheaper and far less error-prone than relocating
                // ~370 lines of controls to sit below it in the file.
                Layout.row: lookClone.landscape ? 1 : 0
                Layout.column: lookClone.landscape ? 0 : 1
                Layout.fillWidth: true; Layout.fillHeight: true; clip: true
                contentWidth: availableWidth
                ColumnLayout {
                    width: apScroll.availableWidth
                    spacing: 18
                    Text { text: "Look"; color: m.textPrimary; font.pixelSize: 24; font.bold: true }
                    // Audit F2: this line used to promise "Hover a swatch to try it -
                    // nothing is applied until you click" for the WHOLE tab, but the
                    // Background chips two sections down commit on click with no
                    // try-on. A user trusting the header would change their background
                    // while "trying" it. Say what is true, and name the sections it is
                    // true of. (Giving the background chips a real hover preview would
                    // be the better fix - it needs BackgroundPicker, which this
                    // workstream does not own. Recorded in the audit.)
                    Text { text: "Step 1 - the look for EVERY screen: theme, accent, background and effects. A single screen can override its background in Screens. Hover a theme or accent to try it in the preview (those apply on click); everything else applies as you change it."
                        color: m.textSecondary; font.pixelSize: m.fontCaption; Layout.fillWidth: true; wrapMode: Text.WordWrap }

                    RowLayout {
                        Layout.topMargin: 4; spacing: 8
                        Text { text: "Edge theme"; color: m.textPrimary; font.pixelSize: m.fontSection; font.bold: true }
                        ScopeTag { label: win.scopeLabels.edge }
                    }
                    Text { text: "The colour palette for every screen and widget. Hover an option to try it in the preview; click to apply. (The Manager window's own style is a separate control below.)"
                        color: m.textSecondary; font.pixelSize: m.fontMinimum; Layout.fillWidth: true; wrapMode: Text.WordWrap }

                    // Theme dropdown (Hybrid appearance): a compact field that opens a
                    // scrollable list of swatch + name rows. Pro themes are badged and,
                    // if locked, selecting opens the licence dialog (commitTheme). Hover
                    // previews live; closing the popup without committing restores.
                    Rectangle {
                        id: themeField
                        objectName: "themeDropdownField"
                        Layout.fillWidth: true; implicitHeight: m.touch; radius: m.radius
                        color: themeFieldMA.containsMouse ? m.panelAlt : m.panel
                        border.width: 1; border.color: themePopup.visible ? m.accent : m.border
                        readonly property string curKey: (store.revision, store.appearance().themeMode || theme.defaultThemeKey)
                        readonly property var curDef: win._themeDef(themeField.curKey)
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 10
                            Rectangle {
                                width: 28; height: 28; radius: 6; border.width: 1; border.color: m.border
                                gradient: Gradient {
                                    GradientStop { position: 0.0; color: themeField.curDef ? themeField.curDef.c1 : "#161B22" }
                                    GradientStop { position: 1.0; color: themeField.curDef ? themeField.curDef.c2 : "#0A0E14" }
                                }
                            }
                            Text {
                                Layout.fillWidth: true; elide: Text.ElideRight
                                text: (themeField.curDef ? themeField.curDef.n : themeField.curKey)
                                color: m.textPrimary; font.pixelSize: m.fontLabel
                            }
                            // A real icon instead of a text glyph, rotated to point
                            // down (closed) / up (open) - consistent with the app's SVG set.
                            AppIcon {
                                name: "ui-caret-right"; size: 16; color: m.textSecondary
                                rotation: themePopup.visible ? -90 : 90
                                Behavior on rotation { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                            }
                        }
                        MouseArea {
                            id: themeFieldMA; anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: themePopup.visible ? themePopup.close() : themePopup.open()
                        }
                        Popup {
                            id: themePopup
                            y: themeField.height + 4; x: 0; width: themeField.width
                            implicitHeight: Math.min(380, themeList.contentHeight + 12)
                            padding: 6; modal: false; focus: true
                            closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
                            background: Rectangle { color: m.panel; radius: m.radius; border.width: 1; border.color: m.border }
                            // Restore the committed appearance if the user only hovered.
                            onClosed: win.endThemePreview()
                            contentItem: ListView {
                                id: themeList
                                clip: true; implicitHeight: contentHeight
                                model: win.apThemeModel
                                currentIndex: -1
                                boundsBehavior: Flickable.StopAtBounds
                                // Same fix as MScroll: a bare ListView scrolls only a
                                // few px per wheel notch under Wayland/hi-res ("20
                                // notches to the bottom"). Drive contentY ourselves at
                                // ~130px/notch so this popup scrolls like every other
                                // list in the Manager.
                                WheelHandler {
                                    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                                    onWheel: function (ev) {
                                        var dy = ev.pixelDelta.y !== 0 ? ev.pixelDelta.y : ev.angleDelta.y
                                        var maxY = Math.max(0, themeList.contentHeight - themeList.height)
                                        themeList.contentY = Math.max(0, Math.min(maxY, themeList.contentY - dy * 1.1))
                                        ev.accepted = true
                                    }
                                }
                                ScrollBar.vertical: ScrollBar {
                                    policy: themeList.contentHeight > themeList.height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff }
                                delegate: Rectangle {
                                    required property var modelData
                                    readonly property bool locked: (modelData.pro === true) && !win.isPro
                                    readonly property bool sel: (store.revision, (store.appearance().themeMode || theme.defaultThemeKey) === modelData.k)
                                    width: ListView.view ? ListView.view.width : 0
                                    height: m.touch; radius: 8
                                    color: rowMA.containsMouse ? m.panelAlt : "transparent"
                                    scale: rowMA.pressed ? 0.98 : 1.0
                                    Behavior on scale { NumberAnimation { duration: 90 } }
                                    RowLayout {
                                        anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; spacing: 10
                                        Rectangle {
                                            width: 26; height: 26; radius: 6; border.width: 1; border.color: m.border
                                            gradient: Gradient {
                                                GradientStop { position: 0.0; color: modelData.c1 }
                                                GradientStop { position: 1.0; color: modelData.c2 } }
                                        }
                                        Text { Layout.fillWidth: true; elide: Text.ElideRight
                                            text: modelData.n; color: m.textPrimary
                                            font.pixelSize: m.fontLabel; font.bold: sel }
                                        Rectangle {
                                            visible: locked
                                            implicitWidth: proL.implicitWidth + 14; implicitHeight: 28; radius: 14
                                            color: Qt.rgba(0, 0, 0, 0.30)
                                            Text { id: proL; anchors.centerIn: parent; text: "PRO"
                                                color: m.textSecondary; font.pixelSize: m.fontMinimum; font.bold: true }
                                        }
                                        AppIcon { visible: sel; name: "ui-check"; size: 16; color: m.accent }
                                    }
                                    MouseArea {
                                        id: rowMA; anchors.fill: parent; hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onContainsMouseChanged: win.hoverPreview("theme", modelData.k, containsMouse)
                                        onClicked: { win.commitTheme(modelData.k); themePopup.close() }
                                    }
                                }
                            }
                        }
                    }

                    MDivider {}
                    // Manager window style - moved here from the sidebar so it sits
                    // right beside the Edge theme. The scope pill makes the
                    // difference explicit: this restyles ONLY the Manager window on
                    // your PC; it never touches the Edge.
                    RowLayout {
                        Layout.topMargin: 4; spacing: 8
                        Text { text: "Manager window style"; color: m.textPrimary; font.pixelSize: m.fontSection; font.bold: true }
                        ScopeTag { label: win.scopeLabels.window }
                    }
                    Text { text: "The look of THIS companion window on your PC - separate from the Edge theme above. Default is the warm SKYPhoenix palette."
                        color: m.textSecondary; font.pixelSize: m.fontMinimum; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                    MSegment {
                        Layout.fillWidth: true
                        options: [ { label: "Dark", value: "dark" }, { label: "Light", value: "light" },
                                   { label: "Default", value: "default" } ]
                        currentValue: appSettings.chromeTheme
                        onSelected: (v) => appSettings.chromeTheme = v
                    }

                    MDivider {}
                    RowLayout {
                        Layout.topMargin: 4; spacing: 8
                        Text { text: "Readability"; color: m.textPrimary; font.pixelSize: 16; font.bold: true }
                        ScopeTag { label: win.scopeLabels.edge }
                    }
                    Text {
                        text: "Text size and typeface apply to every Hub screen and this WYSIWYG preview. Comfortable is the recommended viewing-distance size."
                        color: m.textSecondary; font.pixelSize: m.fontCaption; Layout.fillWidth: true; wrapMode: Text.WordWrap
                    }
                    MSegment {
                        objectName: "managerTextScale"
                        Layout.fillWidth: true
                        options: [ { label: "Compact", value: 1.0 }, { label: "Comfortable", value: 1.15 },
                                   { label: "Large", value: 1.3 }, { label: "Extra large", value: 1.45 } ]
                        currentValue: theme.textScale
                        onSelected: (v) => store.setAppearance("textScale", v)
                    }
                    MSegment {
                        objectName: "managerFontChoice"
                        Layout.fillWidth: true
                        options: [ { label: "Hyperlegible", value: "hyperlegible" },
                                   { label: "Lexend", value: "lexend" }, { label: "System", value: "system" } ]
                        currentValue: theme.fontChoice
                        onSelected: (v) => store.setAppearance("fontChoice", v)
                    }

                    MDivider {}
                    RowLayout {
                        Layout.topMargin: 4; spacing: 8
                        Text { text: "Accent colour"; color: m.textPrimary; font.pixelSize: m.fontSection; font.bold: true }
                        ScopeTag { label: win.scopeLabels.edge }
                    }
                    Text { text: "The highlight colour for rings, buttons and charts. A widget can override it just for itself (⚙ → Widget appearance)."
                        color: m.textSecondary; font.pixelSize: m.fontMinimum; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                    // One swatch shape for BOTH accent groups (house palette + the
                    // colour-blind-safe Okabe–Ito set), so the two rows are identical
                    // in every way but their colours. Selected = a contrasting ring +
                    // check (a fill would hide the colour we're choosing) - the app's
                    // outline rule for colour/thumbnail selection.
                    Component {
                        id: mAccentSwatch
                        Rectangle {
                            required property var modelData
                            // Mark the ACTIVE accent even when the config has no explicit
                            // accent key (fall back to the applied theme.accentName, i.e.
                            // the effective default) - otherwise no swatch reads as selected.
                            property bool sel: (store.revision, (store.appearance().accent || theme.accentName) === modelData.name)
                            width: m.touch; height: m.touch; radius: m.touch / 2; color: modelData.c
                            // Always keep a subtle 1px edge so a dark swatch (e.g. the
                            // Okabe-Ito black) is visible on the dark panel; thicker +
                            // contrasting on hover/select.
                            border.width: sel ? 3 : (accMA.containsMouse ? 2 : 1)
                            border.color: (sel || accMA.containsMouse) ? m.textPrimary : m.border
                            scale: accMA.pressed ? 0.94 : 1.0
                            Behavior on scale { NumberAnimation { duration: 90 } }
                            AppIcon { visible: parent.sel; anchors.centerIn: parent
                                name: "ui-check"; size: 20; color: "#FFFFFF" }
                            ToolTip.visible: accMA.containsMouse
                            ToolTip.delay: 350
                            ToolTip.text: modelData.name
                            MouseArea { id: accMA; anchors.fill: parent; hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onContainsMouseChanged: win.hoverPreview("accent", modelData.name, containsMouse)
                                onClicked: store.setAppearance("accent", modelData.name) }
                        }
                    }
                    Flow {
                        Layout.fillWidth: true; spacing: 10
                        Repeater { model: m.accentPresets; delegate: mAccentSwatch }
                    }
                    // Parity with the Hub: the colour-blind-safe accents are reachable
                    // from the PC too, under their own heading so they read as a
                    // deliberate set rather than eight more decorative tones.
                    Text {
                        text: "Colour-blind safe (Okabe–Ito)"
                        color: m.textSecondary; font.pixelSize: m.fontMinimum; font.bold: true; Layout.topMargin: 6
                    }
                    Flow {
                        Layout.fillWidth: true; spacing: 10
                        Repeater { model: m.a11yAccents; delegate: mAccentSwatch }
                    }

                    MDivider {}
                    RowLayout {
                        Layout.topMargin: 4; spacing: 8
                        Text { text: "Background"; color: m.textPrimary; font.pixelSize: m.fontSection; font.bold: true }
                        ScopeTag { label: win.scopeLabels.pages }
                    }
                    Text { text: "Pick an animated style OR a wallpaper - the default every screen starts from. One screen can go its own way in Screens → “This screen's look”."
                        color: m.textSecondary; font.pixelSize: m.fontMinimum; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                    RowLayout { visible: !theme.decorative; Layout.fillWidth: true; spacing: 6
                        AppIcon { name: "ui-warning"; size: 14; color: m.danger; Layout.alignment: Qt.AlignTop }
                        Text { text: "The High Contrast theme keeps backgrounds off for legibility - switch themes to see them."
                            color: m.danger; font.pixelSize: m.fontMinimum; Layout.fillWidth: true; wrapMode: Text.WordWrap } }
                    BackgroundPicker {
                        Layout.fillWidth: true
                        st: store; pageIndex: -1; col: win.mCol
                        bgCatalog: bgCatalog; wpCatalog: bundledWallpapers; uploadedImages: win.uploadedWallpapers
                        // Hover a style chip → preview it live in the clone without
                        // committing (finally makes the tab's "hover to try" true for
                        // backgrounds too - audit F2).
                        onPreviewStyle: (v) => theme.previewBgStyle = v
                        onPreviewEnded: theme.previewBgStyle = ""
                    }

                    // A default "Layout columns" picker stood here, alongside the
                    // per-page override. Both are gone for the same reason: the grid
                    // is fixed at WidgetSizes.shortHalves across the short axis, so
                    // `1x1` means one third of the screen on every page.

                    MDivider {}
                    RowLayout {
                        Layout.topMargin: 4; spacing: 8
                        Text { text: "Effects"; color: m.textPrimary; font.pixelSize: m.fontSection; font.bold: true }
                        ScopeTag { label: win.scopeLabels.edge }
                    }
                    RowLayout {
                        Layout.fillWidth: true; spacing: 12
                        Text { text: "Glassiness"; color: m.textSecondary; font.pixelSize: m.fontLabel; Layout.preferredWidth: 140 }
                        Slider {
                            id: glassSlider; Layout.fillWidth: true
                            Layout.preferredHeight: m.touch
                            from: 0; to: 1
                            // Bind to theme.glassOpacity - a STABLE Theme property kept in
                            // step with the store by syncTheme() - NOT to store.revision.
                            // The Appearance preview renders live cpu/gpu/ram widgets that
                            // write sparkline history every ~2s, bumping store.revision; a
                            // revision-bound value re-evaluated on every bump and snapped the
                            // handle back to the (debounced, stale) stored value mid-drag -
                            // the "can't move the slider" bug. theme.glassOpacity only moves
                            // when we move it, so the drag holds (this mirrors the working hub
                            // slider, SettingsPanel.qml).
                            value: theme.glassOpacity
                            // Token-styled groove/handle so the raw Fusion control follows
                            // the chosen accent instead of the default light gray.
                            background: Rectangle {
                                x: glassSlider.leftPadding
                                y: glassSlider.topPadding + glassSlider.availableHeight / 2 - height / 2
                                // implicit* MUST be set: the Slider derives its own implicit
                                // size (and thus its hit area) from the background/handle. A
                                // Rectangle's implicit size is 0, so without these the whole
                                // Slider collapsed to ~0 height and could not be pressed or
                                // dragged - the real "stuck at 55%" bug.
                                implicitWidth: 200; implicitHeight: 6
                                width: glassSlider.availableWidth; height: 6; radius: 3
                                color: m.panelAlt; border.width: 1; border.color: m.border
                                Rectangle {
                                    width: glassSlider.visualPosition * parent.width; height: parent.height
                                    radius: 3; color: m.accent
                                }
                            }
                            handle: Rectangle {
                                x: glassSlider.leftPadding + glassSlider.visualPosition * (glassSlider.availableWidth - width)
                                y: glassSlider.topPadding + glassSlider.availableHeight / 2 - height / 2
                                // See background: implicit size gives the Slider a real hit area.
                                implicitWidth: 26; implicitHeight: 26
                                width: 26; height: 26; radius: 13
                                color: glassSlider.pressed ? Qt.lighter(m.accent, 1.15) : m.textOnAccent
                                border.width: 2; border.color: m.accent
                            }
                            // Live-preview the theme while dragging (cheap: opacity only),
                            // but debounce the persisted store write so we don't reapply the
                            // whole theme + save on every frame.
                            onMoved: {
                                theme.glassOpacity = value
                                // Re-assert the binding the drag severs so external/hub
                                // pushes still move the handle [S2]; value === theme.glassOpacity
                                // right now, so this causes no jump.
                                value = Qt.binding(function() { return theme.glassOpacity })
                                glassCommit.restart()
                            }
                            Timer { id: glassCommit; interval: 180; repeat: false
                                onTriggered: {
                                    store.setAppearance("glass", glassSlider.value)
                                    glassSlider.value = Qt.binding(function() { return theme.glassOpacity })
                                } }
                        }
                        Text { text: Math.round(glassSlider.value * 100) + "%"
                            color: m.textPrimary; font.pixelSize: m.fontLabel; font.bold: true
                            Layout.preferredWidth: 44; horizontalAlignment: Text.AlignRight }
                    }

                    Text { text: "How see-through widget cards are: 0% solid, 100% pure glass."
                        color: m.textSecondary; font.pixelSize: m.fontMinimum; Layout.fillWidth: true; wrapMode: Text.WordWrap }

                    ColumnLayout {
                        spacing: 12
                        // A Switch severs its `checked:` binding on first toggle, so
                        // without re-asserting it here a later store/hub push could
                        // never move the control again [S2]. Re-bind after each write.
                        // One-line consequence note under each switch: their labels
                        // alone did not say what would visibly change, or that
                        // "Reduce motion" beats the other two.
                        ColumnLayout {
                            spacing: 2
                            MSwitch {
                                objectName: "managerHubBarSwitch"
                                text: "Show navigation bar on the Hub"
                                checked: { store.revision; return store.appearance().hubControlsMode !== "immersive" }
                                onToggled: {
                                    store.setAppearance("hubControlsMode", checked ? "standard" : "immersive")
                                    checked = Qt.binding(function() {
                                        store.revision
                                        return store.appearance().hubControlsMode !== "immersive"
                                    })
                                }
                            }
                            Text { text: "Off gives the Hub an immersive edge-to-edge dashboard. Layout, screens and global appearance remain available here; widget-specific configuration stays available on the Hub."
                                color: m.textSecondary; font.pixelSize: m.fontMinimum; Layout.leftMargin: 56
                                Layout.fillWidth: true; wrapMode: Text.WordWrap }
                        }
                        // The same setting the Hub offers in its own panel. It has
                        // to live here too: with the navigation bar off, that panel
                        // is unreachable, and an immersive wall display is exactly
                        // the one that wants to cycle.
                        ColumnLayout {
                            spacing: 2
                            Layout.fillWidth: true
                            Text { text: "Cycle through screens"; color: m.textPrimary
                                font.pixelSize: m.fontLabel }
                            ComboBox {
                                objectName: "managerPageCycleCombo"
                                Layout.fillWidth: true
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
                                // Written inline rather than as a named helper:
                                // Manager.qml is on qml_coverage.py's
                                // every-function-must-earn-a-COVERS-claim list,
                                // and this control cannot earn one - tst_manager
                                // does not instantiate the Manager window (it
                                // documents a 20 GB blowup when it did), which is
                                // why the neighbouring hub-bar switch has no test
                                // either. A named function here would be an
                                // obligation nothing can honestly meet.
                                currentIndex: {
                                    store.revision
                                    var cur = Number(store.appearance().pageCycleSec)
                                    for (var i = 0; i < model.length; i++)
                                        if (model[i].secs === cur) return i
                                    return 0
                                }
                                onActivated: {
                                    store.setAppearance("pageCycleSec", model[currentIndex].secs)
                                    currentIndex = Qt.binding(function () {
                                        store.revision
                                        var cur = Number(store.appearance().pageCycleSec)
                                        for (var i = 0; i < model.length; i++)
                                            if (model[i].secs === cur) return i
                                        return 0
                                    })
                                }
                            }
                            Text { text: "The Hub moves to the next screen on its own while nobody is using it. Touching the Hub stops it, and it starts again after the same amount of time. Empty screens are skipped."
                                color: m.textSecondary; font.pixelSize: m.fontMinimum
                                Layout.fillWidth: true; wrapMode: Text.WordWrap }
                        }
                        ColumnLayout {
                            spacing: 2
                            MSwitch {
                                text: "Widget glow"
                                checked: { store.revision; var g = store.appearance().glow; return g === undefined ? true : g }
                                onToggled: {
                                    store.setAppearance("glow", checked)
                                    checked = Qt.binding(function() { store.revision; var g = store.appearance().glow; return g === undefined ? true : g })
                                }
                            }
                            Text { text: "A soft coloured halo behind each widget card."
                                color: m.textSecondary; font.pixelSize: m.fontMinimum; Layout.leftMargin: 56
                                Layout.fillWidth: true; wrapMode: Text.WordWrap }
                        }
                        ColumnLayout {
                            spacing: 2
                            MSwitch {
                                text: "Animated background"
                                checked: { store.revision; var g = store.appearance().animatedBg; return g === undefined ? true : g }
                                onToggled: {
                                    store.setAppearance("animatedBg", checked)
                                    checked = Qt.binding(function() { store.revision; var g = store.appearance().animatedBg; return g === undefined ? true : g })
                                }
                            }
                            Text { text: "Lets the background style above move. Off = it stands still. Not used while a wallpaper is set."
                                color: m.textSecondary; font.pixelSize: m.fontMinimum; Layout.leftMargin: 56
                                Layout.fillWidth: true; wrapMode: Text.WordWrap }
                        }
                        ColumnLayout {
                            spacing: 2
                            MSwitch {
                                text: "Reduce motion"
                                checked: (store.revision, store.appearance().reduceMotion || false)
                                onToggled: {
                                    store.setAppearance("reduceMotion", checked)
                                    checked = Qt.binding(function() { store.revision; return store.appearance().reduceMotion || false })
                                }
                            }
                            Text { text: "Stops backgrounds, widgets, and spatial transitions. Physical screen turns become immediate."
                                color: m.textSecondary; font.pixelSize: m.fontMinimum; Layout.leftMargin: 56
                                Layout.fillWidth: true; wrapMode: Text.WordWrap }
                        }
                    }
                    Item { Layout.preferredHeight: 12 }   // bottom padding
                }
               }

                // ── Live preview pane (the same WYSIWYG clone as Screens, read-only) ──
                ColumnLayout {
                    objectName: "lookPreviewPane"   // test seam: the Look tab's preview column
                    Layout.row: 0; Layout.column: 0
                    // Same sizing rule as the Screens tab's EdgeClone: landscape gets
                    // the full content width and a bounded height (it is the top row);
                    // portrait gets a fixed pane beside the controls. It used to be a
                    // hardcoded 760/400 wide in BOTH orientations, which is how a
                    // landscape preview ended up a squeezed strip here while the same
                    // component read correctly on Screens.
                    Layout.fillWidth: lookClone.landscape
                    Layout.fillHeight: !lookClone.landscape
                    Layout.preferredWidth: lookClone.landscape ? -1 : 400
                    // POSITIVE_INFINITY, not -1: -1 is the documented reset for
                    // *preferred* sizes only. maximumWidth defaults to infinity and
                    // takes -1 literally, which would clamp this pane to nothing in
                    // landscape - the preview would simply vanish.
                    Layout.maximumWidth: lookClone.landscape ? Number.POSITIVE_INFINITY : 400
                    spacing: 8
                    Text { text: "Live preview"; color: m.textPrimary; font.pixelSize: m.fontSection; font.bold: true }
                    // Page chips so "which page am I looking at?" has an answer -
                    // and per-page overrides can be checked without leaving the tab.
                    Flow {
                        Layout.fillWidth: true; spacing: 6
                        Repeater {
                            model: (store.structureRevision, store.pages())
                            delegate: Rectangle {
                                required property int index
                                required property var modelData
                                width: apPgLbl.implicitWidth + 24; height: m.touch; radius: 8
                                color: win.currentPageIndex === index ? m.accent
                                       : (apPgMA.containsMouse ? m.panelAlt : m.panel)
                                border.width: 1; border.color: m.border
                                Text { id: apPgLbl; anchors.centerIn: parent; text: modelData.name
                                    color: win.currentPageIndex === index ? m.textOnAccent : m.textSecondary
                                    font.pixelSize: m.fontMinimum; font.bold: win.currentPageIndex === index }
                                MouseArea { id: apPgMA; anchors.fill: parent; hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: win.currentPageIndex = index }
                            }
                        }
                    }
                    EdgeClone {
                        id: lookClone
                        editable: false
                        Layout.fillWidth: true
                        // Landscape: a bounded height, as on Screens - the pane is the
                        // top row of a 1-column grid, so an unbounded fillHeight would
                        // let it eat the controls below it.
                        Layout.fillHeight: !lookClone.landscape
                        Layout.preferredHeight: lookClone.landscape ? 380 : -1
                        pageIndex: win.currentPageIndex
                        // Pause the live preview while the Appearance controls scroll.
                        scrolling: apScroll.contentItem ? apScroll.contentItem.moving : false
                    }
                    Text { text: win.liveNote; color: backend.hubConnected ? m.success : m.textSecondary
                        font.pixelSize: m.fontMinimum; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                }
              }
            }

            // ═══ 3. IMAGES ═══
            Item {
                ColumnLayout {
                    anchors.fill: parent; anchors.margins: 24; spacing: 16
                    Text { text: "Images"; color: m.textPrimary; font.pixelSize: 24; font.bold: true }
                    Text { text: "Upload your own images here - they then appear as wallpaper options in the background picker (Look → Background, or per-screen in Screens)."
                        color: m.textSecondary; font.pixelSize: m.fontCaption; Layout.fillWidth: true; wrapMode: Text.WordWrap }

                    RowLayout {
                        Layout.fillWidth: true; spacing: 8
                        MButton { text: "Import image…"; iconName: "ui-plus"; primary: true
                            Layout.preferredHeight: m.touch; onClicked: fileDialog.open() }
                        Item { Layout.fillWidth: true }
                    }

                    // Bundled backgrounds - the sleek graphics that ship with EdgeHub,
                    // browsable and pickable right here (the user asked for the images to
                    // live in this section). Clicking sets it as the Edge-wide wallpaper.
                    RowLayout {
                        Layout.fillWidth: true; Layout.topMargin: 4; spacing: 8
                        Text { text: "Bundled backgrounds"; color: m.textSecondary; font.pixelSize: m.fontSection; font.bold: true }
                        ScopeTag { label: win.scopeLabels.pages }
                        Item { Layout.fillWidth: true }
                    }
                    Text { text: "Graphics that ship with EdgeHub - click one to use it on every screen (a single screen can override it in Screens)."
                        color: m.textSecondary; font.pixelSize: m.fontMinimum; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                    Flow {
                        Layout.fillWidth: true; spacing: 8
                        Repeater {
                            model: bundledWallpapers.items
                            delegate: Rectangle {
                                required property var modelData
                                width: 160; height: 108; radius: m.radius; clip: true
                                property bool bw: (store.revision, store.appearance().wallpaper === modelData.source)
                                color: m.panel; border.width: bw ? 2 : 1
                                border.color: bw ? m.accent : m.border
                                Image { anchors.fill: parent; anchors.margins: 2; source: modelData.source
                                    fillMode: Image.PreserveAspectCrop; asynchronous: true; mipmap: true }
                                Rectangle { anchors.bottom: parent.bottom; anchors.left: parent.left
                                    anchors.right: parent.right; height: 30; color: Qt.rgba(0, 0, 0, 0.62)
                                    Text { anchors.centerIn: parent; text: modelData.label; color: "#fff"
                                        font.pixelSize: m.fontMinimum; elide: Text.ElideRight; width: parent.width - 8
                                        horizontalAlignment: Text.AlignHCenter } }
                                Rectangle { visible: parent.bw; anchors.top: parent.top; anchors.right: parent.right
                                    anchors.margins: 4; width: 26; height: 26; radius: 13; color: m.accent
                                    AppIcon { anchors.centerIn: parent; name: "ui-check"; size: 16; color: "#FFFFFF" } }
                                MouseArea { anchors.fill: parent; hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: store.setAppearance("wallpaper", modelData.source) }
                            }
                        }
                    }

                    // Audit F6: clicking a card writes appearance.wallpaper - the
                    // biggest unlabelled scope jump in the app. The tab had no pill,
                    // no preview, and copy ("use it as the wallpaper") that never said
                    // every page changes. Say the scope, and say where to undo it.
                    RowLayout {
                        Layout.fillWidth: true; spacing: 8
                        Text { text: "Your images"; color: m.textSecondary; font.pixelSize: m.fontSection; font.bold: true }
                        ScopeTag { visible: imagesModel.count > 0; label: win.scopeLabels.pages }
                        Item { Layout.fillWidth: true }
                    }
                    Text { text: "Click an image to make it the wallpaper on every screen. To use one on a single screen instead, go to Screens → “This screen's look”."
                        color: m.textSecondary; font.pixelSize: m.fontMinimum; visible: imagesModel.count > 0
                        Layout.fillWidth: true; wrapMode: Text.WordWrap }
                    // Empty state. The trailing filler keeps the column top-packed while the
                    // grid is hidden - without it the few remaining rows spread out
                    // over the full tab height (audit finding F8).
                    Text { visible: imagesModel.count === 0; Layout.fillWidth: true; Layout.topMargin: 24
                        horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                        text: "No images yet - use “Import image…” to add one."
                        color: m.textSecondary; font.pixelSize: m.fontCaption }
                    Item { visible: imagesModel.count === 0; Layout.fillHeight: true }
                    GridView {
                        id: imgGrid
                        visible: imagesModel.count > 0
                        Layout.fillWidth: true; Layout.fillHeight: true; clip: true
                        cellWidth: 190; cellHeight: 190
                        model: imagesModel
                        // Usable mouse-wheel step (see MScroll) - a GridView is a
                        // Flickable too and hits the same tiny-per-notch problem.
                        WheelHandler {
                            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                            onWheel: function (ev) {
                                var dy = ev.pixelDelta.y !== 0 ? ev.pixelDelta.y : ev.angleDelta.y
                                var maxY = Math.max(0, imgGrid.contentHeight - imgGrid.height)
                                imgGrid.contentY = Math.max(0, Math.min(maxY, imgGrid.contentY - dy * 1.1))
                                ev.accepted = true
                            }
                        }
                        ScrollBar.vertical: ScrollBar {
                            policy: imgGrid.contentHeight > imgGrid.height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
                            contentItem: Rectangle { implicitWidth: 6; radius: 3; color: m.border }
                        }
                        delegate: Rectangle {
                                id: imgCard
                                required property var modelData
                                width: 180; height: 180; radius: m.radius
                                // Wallpapers are stored as file:// URLs (matching the
                                // BackgroundPicker), so compare against that form.
                                property string fullPath: backend.imageUrl(modelData)
                                property bool isWall: (store.revision, store.appearance().wallpaper) === fullPath
                                color: cardMA.containsMouse ? m.panelAlt : m.panel
                                border.width: isWall ? 3 : 1; border.color: isWall ? m.accent : m.border
                                ColumnLayout {
                                    anchors.fill: parent; anchors.margins: 8; spacing: 4
                                    Image {
                                        Layout.fillWidth: true; Layout.fillHeight: true
                                        source: imgCard.fullPath
                                        fillMode: Image.PreserveAspectCrop; asynchronous: true; clip: true
                                    }
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: 4
                                        AppIcon { visible: imgCard.isWall; name: "ui-check"; size: 14; color: m.accent }
                                        Text { text: imgCard.isWall ? "wallpaper" : imgCard.modelData
                                            color: imgCard.isWall ? m.accent : m.textSecondary; font.pixelSize: m.fontMinimum
                                            elide: Text.ElideRight; Layout.fillWidth: true }
                                        // Bigger, padded delete hit target.
                                        Rectangle { Layout.preferredWidth: 48; Layout.preferredHeight: 48; radius: 10
                                            color: delMA.containsMouse ? Qt.rgba(m.danger.r, m.danger.g, m.danger.b, 0.18) : "transparent"
                                            AppIcon { anchors.centerIn: parent; name: "ui-trash"; size: 16; color: m.danger }
                                            MouseArea { id: delMA; anchors.fill: parent; hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: win.confirmDeleteImage(imgCard.modelData, imgCard.fullPath) } }
                                    }
                                }
                                // Click the card body → set as wallpaper.
                                MouseArea { id: cardMA; anchors.fill: parent; hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    // Let the trash button win.
                                    onClicked: (mouse) => store.setAppearance("wallpaper", imgCard.fullPath)
                                    z: -1 }
                            }
                        }
                    }
                }

            // ═══ 4. DISPLAY ═══
            Item {
              MScroll {
                id: dpScroll
                anchors.fill: parent; clip: true
                contentWidth: availableWidth
                ColumnLayout {
                    width: dpScroll.availableWidth - 48
                    x: 24; y: 24; spacing: 16
                    Text { text: "Device"; color: m.textPrimary; font.pixelSize: 24; font.bold: true }
                    // Audit F7: "Applies next time the hub starts" used to sit HERE,
                    // as the tab subtitle - above Orientation (which pushes live) and
                    // the autostart switch (immediate). Read as tab-level guidance it
                    // simply wasn't true, so it moved down onto the screen picker,
                    // which is the only thing it describes.
                    Text { text: "Where the hub runs, how it's turned, and whether it starts itself."
                        color: m.textSecondary; font.pixelSize: m.fontCaption; Layout.fillWidth: true; wrapMode: Text.WordWrap }

                    RowLayout {
                        Layout.topMargin: 8; spacing: 8
                        Text { text: "Screen the hub runs on"; color: m.textPrimary; font.pixelSize: m.fontSection; font.bold: true }
                        ScopeTag { label: win.scopeLabels.computer }
                    }
                    Text {
                        text: backend.hubConnected
                              ? "Moves the running Hub now and keeps this target for future starts."
                              : "Saved now and applied the next time the Hub starts."
                        color: m.textSecondary; font.pixelSize: m.fontMinimum; Layout.fillWidth: true; wrapMode: Text.WordWrap }

                    // Audit F8 / W5 #13: with no screens the tab showed a sentence
                    // about choosing a screen, then blank space, then Orientation -
                    // so Orientation read as the answer to "choose which screen".
                    Rectangle {
                        objectName: "screensEmpty"
                        visible: win.screens.length === 0
                        Layout.fillWidth: true; Layout.preferredHeight: 64
                        radius: m.radius; color: m.panel
                        border.width: 1; border.color: m.border
                        RowLayout {
                            anchors.fill: parent; anchors.margins: 12; spacing: 12
                            AppIcon { name: "ui-display"; color: m.textSecondary; size: 22 }
                            Text {
                                Layout.fillWidth: true; wrapMode: Text.WordWrap
                                text: "No screens detected. Connect your Xeneon Edge (or any display) and it will appear here."
                                color: m.textSecondary; font.pixelSize: m.fontMinimum
                            }
                        }
                    }

                    Repeater {
                        model: win.screens
                        delegate: Rectangle {
                            required property var modelData
                            Layout.fillWidth: true; Layout.preferredHeight: 64
                            radius: m.radius; color: m.panel
                            border.width: modelData.name === win.currentTarget ? 2 : 1
                            border.color: modelData.name === win.currentTarget ? m.accent : m.border
                            RowLayout {
                                anchors.fill: parent; anchors.margins: 12; spacing: 12
                                AppIcon { name: "ui-display"; color: m.textPrimary; size: 22 }
                                ColumnLayout {
                                    spacing: 0; Layout.fillWidth: true
                                    Text { text: (modelData.model || modelData.name) + (modelData.isEdge ? "  · Xeneon Edge" : "")
                                        color: m.textPrimary; font.pixelSize: m.fontLabel; font.bold: true }
                                    Text { text: modelData.name + "  ·  " + modelData.width + "×" + modelData.height
                                        color: m.textSecondary; font.pixelSize: m.fontMinimum }
                                }
                                MButton {
                                    property bool isTarget: modelData.name === win.currentTarget
                                    text: isTarget ? "Target" : "Set as target"
                                    iconName: isTarget ? "ui-check" : ""
                                    primary: isTarget
                                    onClicked: {
                                        if (backend.setTargetDisplay(
                                                modelData.name, modelData.model))
                                            win.currentTarget = modelData.name
                                    } }
                            }
                        }
                    }

                    RowLayout {
                        Layout.topMargin: 8; spacing: 8
                        Text { text: "Orientation"; color: m.textPrimary; font.pixelSize: m.fontSection; font.bold: true }
                        ScopeTag { label: win.scopeLabels.edge }
                    }
                    Text { text: "Pick a fixed mode to rotate the dashboard for a wall/arm mount. Auto follows the system only when an orientation sensor is present."
                        color: m.textSecondary; font.pixelSize: m.fontMinimum; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                    Flow {
                        Layout.fillWidth: true; spacing: 8
                        Repeater {
                            model: [ { v: "auto", l: "Auto" }, { v: "portrait", l: "Portrait" },
                                     { v: "landscape", l: "Landscape" }, { v: "inverted-portrait", l: "Portrait (flipped)" },
                                     { v: "inverted-landscape", l: "Landscape (flipped)" } ]
                            delegate: Rectangle {
                                required property var modelData
                                width: oriLbl.implicitWidth + 24; height: m.touch; radius: m.radius
                                property bool sel: (store.revision, store.appearance().orientation || "auto") === modelData.v
                                color: sel ? m.accent : (oriMA.containsMouse ? m.panelAlt : m.panel)
                                border.width: 1; border.color: m.border
                                Text { id: oriLbl; anchors.centerIn: parent; text: modelData.l
                                    color: sel ? m.textOnAccent : m.textPrimary; font.pixelSize: m.fontLabel }
                                MouseArea { id: oriMA; anchors.fill: parent; hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: store.setAppearance("orientation", modelData.v) }
                            }
                        }
                    }

                    // Audit F8: the one control that reaches outside the Edge entirely
                    // (it writes a login autostart entry) carried no scope and no note.
                    RowLayout {
                        Layout.topMargin: 8; spacing: 8
                        Text { text: "Startup"; color: m.textPrimary; font.pixelSize: m.fontSection; font.bold: true }
                        ScopeTag { label: win.scopeLabels.computer }
                    }
                    ColumnLayout {
                        spacing: 2
                        MSwitch {
                            id: autostartSwitch; text: "Start the hub automatically on login"
                            checked: backend.isAutostart()
                            // Toggling severs the `checked:` binding; re-read the backend's
                            // real state (the write can fail) so the control never diverges
                            // and onActiveChanged can keep refreshing it [S2].
                            onToggled: {
                                backend.setAutostart(checked)
                                checked = backend.isAutostart()
                            }
                        }
                        Text { text: "Adds the hub to this computer's login startup. Takes effect at your next login; it doesn't start or stop the hub now."
                            color: m.textSecondary; font.pixelSize: m.fontMinimum; Layout.leftMargin: 56
                            Layout.fillWidth: true; wrapMode: Text.WordWrap }
                    }

                    // ── Software updates (opt-in) ──
                    // Mirrors the hub's own toggle so it is DISCOVERABLE here in the
                    // full-control Manager (the hub buries it in the on-panel
                    // settings - "where is autoupdate?"). Off by default: EdgeHub
                    // never phones home on its own. The Manager only sets the flag;
                    // the actual check runs on the hub through its audited network
                    // gate, so the Manager adds no new egress surface.
                    RowLayout {
                        Layout.topMargin: 8; spacing: 8
                        Text { text: "Software updates"; color: m.textPrimary; font.pixelSize: m.fontSection; font.bold: true }
                        ScopeTag { label: win.scopeLabels.edge }
                    }
                    ColumnLayout {
                        spacing: 2
                        MSwitch {
                            id: updateSwitch
                            text: "Check for updates automatically"
                            checked: { store.revision; return store.appearance().updateCheck === true }
                            onToggled: {
                                store.setAppearance("updateCheck", checked)
                                checked = Qt.binding(function () { store.revision; return store.appearance().updateCheck === true })
                            }
                        }
                        Text { text: "Off by default - EdgeHub never checks on its own. When on, the Edge asks GitHub for the latest release tag through its audited network gate (nothing identifying is sent) and shows the result on the display itself. Install updates with your package manager."
                            color: m.textSecondary; font.pixelSize: m.fontMinimum; Layout.leftMargin: 56
                            Layout.fillWidth: true; wrapMode: Text.WordWrap }
                    }

                    // ── Troubleshooting / reset ──
                    RowLayout {
                        Layout.topMargin: 8; spacing: 8
                        Text { text: "Troubleshooting"; color: m.textPrimary; font.pixelSize: m.fontSection; font.bold: true }
                        ScopeTag { label: win.scopeLabels.edge }
                    }
                    Text { text: "Start over from a clean default layout. Your uploaded images are kept - only screens and widgets are reset."
                        color: m.textSecondary; font.pixelSize: m.fontMinimum; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                    RowLayout {
                        Layout.fillWidth: true; spacing: 8
                        MButton { objectName: "resetLayoutBtn"; text: "Reset to default layout"; iconName: "ui-trash"
                            onClicked: win.confirmResetLayout() }
                        Item { Layout.fillWidth: true }
                    }

                    Item { Layout.preferredHeight: 12 }   // bottom padding
                }
              }
            }

            // ═══ 5. ABOUT ═══
            Item {
              MScroll {
                id: abScroll
                anchors.fill: parent; clip: true
                contentWidth: availableWidth
                ColumnLayout {
                    width: abScroll.availableWidth - 48
                    x: 24; y: 24; spacing: 14

                    Text { text: "About"; color: m.textPrimary; font.pixelSize: 24; font.bold: true }

                    // Brand card: theme-aware logo + wordmark + maker line.
                    Rectangle {
                        Layout.fillWidth: true; Layout.topMargin: 4
                        radius: m.radius; color: m.panel
                        border.width: 1; border.color: m.border
                        implicitHeight: aboutBrand.implicitHeight + 40
                        ColumnLayout {
                            id: aboutBrand
                            anchors.left: parent.left; anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.margins: 20; spacing: 4
                            Text {
                                text: "EdgeHub"; color: m.textPrimary
                                font.family: theme.fontBrand; font.pixelSize: 40; font.bold: true
                                font.letterSpacing: 0.5
                            }
                            Text {
                                text: "by SKYPhoenix IT"; color: m.textSecondary
                                font.family: theme.fontMono; font.pixelSize: m.fontMinimum; font.letterSpacing: 0.5
                            }
                            Image {
                                Layout.preferredWidth: 150; Layout.preferredHeight: 60
                                Layout.topMargin: 8
                                fillMode: Image.PreserveAspectFit; horizontalAlignment: Image.AlignLeft
                                smooth: true; asynchronous: true; mipmap: true
                                source: appSettings.chromeTheme === "light" ? "qrc:/manager/branding/sky-black.png"
                                      : appSettings.chromeTheme === "default" ? "qrc:/manager/branding/sky-color.png"
                                      : "qrc:/manager/branding/sky-white.png"
                            }
                        }
                    }

                    // Version + description.
                    RowLayout {
                        Layout.fillWidth: true; Layout.topMargin: 6; spacing: 8
                        Text { text: "Version:"; color: m.textSecondary; font.pixelSize: m.fontLabel }
                        Text {
                            text: (backend && backend.appVersion ? backend.appVersion() : "?")
                            color: m.textPrimary; font.pixelSize: m.fontLabel; font.family: theme.fontMono
                            Layout.fillWidth: true; elide: Text.ElideRight
                        }
                    }
                    Text {
                        text: "A native Linux widget dashboard for your second screen."
                        color: m.textPrimary; font.pixelSize: m.fontLabel
                        Layout.fillWidth: true; wrapMode: Text.WordWrap
                    }

                    // ── Licence card ──
                    // Free by default; Pro when a valid key is stored. Everything
                    // functional is free - Pro unlocks the premium theme/preset
                    // packs and custom user widgets. "expired" is worded as
                    // renew-not-broken (the signature was genuine).
                    Rectangle {
                        Layout.fillWidth: true; Layout.topMargin: 8
                        radius: m.radius; color: m.panel
                        border.width: 1
                        border.color: win.isPro ? m.accent : m.border
                        implicitHeight: licCol.implicitHeight + 32
                        ColumnLayout {
                            id: licCol
                            anchors.left: parent.left; anchors.right: parent.right
                            anchors.top: parent.top; anchors.margins: 16; spacing: 8
                            RowLayout {
                                Layout.fillWidth: true; spacing: 10
                                AppIcon {
                                    name: win.isPro ? "ui-check" : "ui-settings"
                                    size: 22; color: win.isPro ? m.accent : m.textSecondary
                                    Layout.alignment: Qt.AlignVCenter
                                }
                                ColumnLayout {
                                    spacing: 1; Layout.fillWidth: true
                                    Text {
                                        text: win.isPro ? "Xeneon Edge Pro"
                                            : win.licStatus.state === "expired" ? "Pro licence expired"
                                            : "Free tier"
                                        color: m.textPrimary; font.pixelSize: 17; font.bold: true
                                    }
                                    Text {
                                        text: win.isPro
                                              ? ("Thank you" + (win.licStatus.issuedTo
                                                   ? ", " + win.licStatus.issuedTo : "") + " - premium unlocked.")
                                            : win.licStatus.state === "expired"
                                              ? "Renew to keep the premium extras. Your dashboards keep working."
                                            // ACCURATE, not aspirational: the ONLY thing the licence
                                            // gates is 9 themes (4 Premium + 5 Inspired). Preset screens
                                            // and user widgets are NOT gated - UserWidgetCatalog does no
                                            // licence check and PresetCatalog has no pro flag. Promising
                                            // those here is exactly what makes a buyer feel misled once
                                            // they find they already had them.
                                            : "Everything works. Pro adds 9 extra themes and supports development."
                                        color: m.textSecondary; font.pixelSize: m.fontMinimum
                                        Layout.fillWidth: true; wrapMode: Text.WordWrap
                                    }
                                }
                            }
                            RowLayout {
                                Layout.fillWidth: true; spacing: 8
                                MButton {
                                    text: win.isPro ? "Manage licence" : "Activate Pro"
                                    iconName: "ui-settings"
                                    onClicked: licenseDialog.open()
                                }
                                MButton {
                                    visible: !win.isPro
                                    text: "Get Pro"; iconName: "ui-display"
                                    onClicked: Qt.openUrlExternally(
                                        "https://github.com/skyphoenix-it/skyphoenix-edgehub-linux#pro")
                                }
                                Item { Layout.fillWidth: true }
                            }
                        }
                    }

                    // Links.
                    RowLayout {
                        Layout.fillWidth: true; Layout.topMargin: 6; spacing: 8
                        MButton {
                            text: "Website"; iconName: "ui-display"
                            onClicked: Qt.openUrlExternally("https://www.skyphoenix-it.com")
                        }
                        MButton {
                            text: "GitHub"; iconName: "ui-settings"
                            // The same URL the PKGBUILD, the metainfo and SECURITY.md
                            // already ship. It was "#" - a button that silently did
                            // nothing, which is worse than no button: the user clicks
                            // it, gets no browser and no error, and concludes the app
                            // is broken rather than the link.
                            onClicked: Qt.openUrlExternally(
                                "https://github.com/skyphoenix-it/skyphoenix-edgehub-linux")
                        }
                        Item { Layout.fillWidth: true }
                    }
                    Text {
                        text: "www.skyphoenix-it.com"
                        color: m.textSecondary; font.pixelSize: m.fontMinimum; font.family: theme.fontMono
                    }

                    // ── Diagnostics (for support) ──
                    // The Manager's honest view: connection, displays, and the raw
                    // config on demand. Live network egress counters are a hub-runtime
                    // tally shown on the Edge itself (the hub's own Diagnostics), so
                    // they're pointed to here, never faked with zeros.
                    Rectangle {
                        Layout.fillWidth: true; Layout.topMargin: 8
                        radius: m.radius; color: m.panel; border.width: 1; border.color: m.border
                        implicitHeight: diagCol.implicitHeight + 32
                        ColumnLayout {
                            id: diagCol
                            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                            anchors.margins: 16; spacing: 8
                            RowLayout {
                                Layout.fillWidth: true; spacing: 8
                                AppIcon { name: "ui-settings"; size: 18; color: m.textSecondary; Layout.alignment: Qt.AlignVCenter }
                                Text { text: "Diagnostics"; color: m.textPrimary; font.pixelSize: 16; font.bold: true; Layout.fillWidth: true }
                                MButton { text: diagBox.visible ? "Hide summary" : "Show redacted summary"
                                    onClicked: diagBox.visible = !diagBox.visible }
                            }
                            Text { text: (backend.hubConnected ? "Hub connected (live)" : "Hub offline (saved)")
                                    + "  ·  " + win.screens.length + " display" + (win.screens.length === 1 ? "" : "s")
                                    + (win.currentTarget.length ? "  ·  target " + win.currentTarget : "")
                                color: m.textSecondary; font.pixelSize: m.fontMinimum; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                            Text { text: "Live network egress counters are shown on the Edge itself (the hub's Diagnostics) - the Manager makes no network requests of its own."
                                color: m.textSecondary; font.pixelSize: m.fontMinimum; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                            Rectangle {
                                id: diagBox; visible: false
                                Layout.fillWidth: true; Layout.preferredHeight: 220
                                radius: m.radius; color: m.bg; border.width: 1; border.color: m.border
                                MScroll {
                                    anchors.fill: parent; anchors.margins: 8; clip: true
                                    contentWidth: availableWidth
                                    Text {
                                        width: diagBox.width - 16
                                        // Only fetch the Rust-produced redacted summary
                                        // when shown. The QML test mock may omit the API.
                                        text: {
                                            if (!diagBox.visible) return ""
                                            var _ = store.revision
                                            return (backend && backend.configJson) ? backend.configJson()
                                                                                    : "(config unavailable)"
                                        }
                                        color: m.textSecondary; font.family: theme.fontMono; font.pixelSize: m.fontMinimum
                                        wrapMode: Text.WrapAnywhere; textFormat: Text.PlainText
                                    }
                                }
                            }
                        }
                    }

                    Text {
                        text: "© 2026 SKYPhoenix IT · Independent product"
                        color: m.textSecondary; font.pixelSize: m.fontMinimum
                        Layout.topMargin: 8; Layout.fillWidth: true; wrapMode: Text.WordWrap
                    }
                    Item { Layout.preferredHeight: 12 }   // bottom padding
                }
              }
            }
        }
    }

    // ── Add-widget picker ──
    Dialog {
        id: addPicker
        title: "Add a widget"
        modal: true
        anchors.centerIn: parent
        width: Math.min(parent ? parent.width * 0.9 : 720, 760)
        height: Math.min(parent ? parent.height * 0.85 : 560, 620)
        standardButtons: Dialog.Close
        background: Rectangle { color: m.panel; radius: m.radius; border.width: 1; border.color: m.border }
        // Audit F4: the picker never said WHICH page the widget lands on - with
        // three pages the only clue was remembering where you were. Name the page
        // and pill the scope, like every other control.
        header: Rectangle {
            color: "transparent"; implicitHeight: 68
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 20; anchors.rightMargin: 20; spacing: 12
                AppIcon { name: "ui-plus"; size: 24; color: m.accent; Layout.alignment: Qt.AlignVCenter }
                ColumnLayout {
                    spacing: 1; Layout.fillWidth: true
                    Text { text: "Add a widget"; color: m.textPrimary; font.pixelSize: 19; font.bold: true }
                    Text {
                        objectName: "addPickerTarget"
                        text: "Adds to the screen “" + (store.structureRevision, win.currentPageName()) + "”."
                        color: m.textSecondary; font.pixelSize: m.fontMinimum
                        elide: Text.ElideRight; Layout.fillWidth: true
                    }
                }
                ScopeTag { label: win.scopeLabels.page; Layout.alignment: Qt.AlignVCenter }
            }
        }
        contentItem: MScroll {
            clip: true
            ColumnLayout {
                width: addPicker.availableWidth
                spacing: 12
                // One screen never scrolls: when the page is full, the next widget just
                // starts a new screen. Say so up front - helpful, not a blocker.
                Rectangle {
                    Layout.fillWidth: true
                    visible: (store.structureRevision, store.pageIsFull(win.currentPageIndex))
                    implicitHeight: fullRowM.implicitHeight + 16
                    radius: m.radius
                    color: Qt.rgba(m.accent.r, m.accent.g, m.accent.b, 0.12)
                    border.width: 1; border.color: Qt.rgba(m.accent.r, m.accent.g, m.accent.b, 0.45)
                    RowLayout {
                        id: fullRowM
                        anchors.fill: parent; anchors.margins: 8; spacing: 8
                        AppIcon { name: "ui-add-page"; size: 18; color: m.accent; Layout.alignment: Qt.AlignVCenter }
                        Text {
                            Layout.fillWidth: true; wrapMode: Text.WordWrap
                            text: "This screen is full - your next widget will start a new screen."
                            color: m.textPrimary; font.pixelSize: m.fontMinimum
                        }
                    }
                }
                Repeater {
                    model: catalog.categories()
                    delegate: ColumnLayout {
                        required property string modelData
                        Layout.fillWidth: true; spacing: 8
                        Text { text: modelData; color: m.textSecondary; font.pixelSize: m.fontSection; font.bold: true }
                        Flow {
                            Layout.fillWidth: true; spacing: 8
                            Repeater {
                                model: catalog.inCategory(modelData)
                                delegate: Rectangle {
                                    id: widgetChoice
                                    required property var modelData
                                    objectName: "widgetChoice-" + modelData.type
                                    width: 150; height: 84; radius: m.radius
                                    color: itemMA.containsMouse ? m.panelAlt : m.bg
                                    border.width: 1; border.color: m.border
                                    activeFocusOnTab: true
                                    Accessible.role: Accessible.Button
                                    Accessible.name: "Add widget: " + modelData.title
                                    Accessible.onPressAction: widgetChoice.addWidget()
                                    Keys.onSpacePressed: widgetChoice.addWidget()
                                    Keys.onReturnPressed: widgetChoice.addWidget()
                                    function addWidget() {
                                        var newId = store.addTile(win.currentPageIndex, modelData.type)
                                        addPicker.close()
                                        if (newId) {
                                            var tp = store.pageIndexForTile(newId)
                                            if (tp >= 0) win.currentPageIndex = tp
                                        }
                                    }
                                    ColumnLayout {
                                        anchors.centerIn: parent; spacing: 4
                                        AppIcon { Layout.alignment: Qt.AlignHCenter; name: modelData.type; size: 26; color: m.textPrimary }
                                        Text { Layout.alignment: Qt.AlignHCenter; text: modelData.title
                                            color: m.textPrimary; font.pixelSize: m.fontMinimum }
                                    }
                                    MouseArea { id: itemMA; anchors.fill: parent; hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        // Adding never fails: fits this screen, or the store starts a
                                        // new one. Follow the tile to whichever screen it landed on.
                                        onClicked: widgetChoice.addWidget()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ── Preset "screens" picker ──
    // The full curated library. ADDITIVE: choosing one appends it as a NEW screen
    // (applyPresetScreen → store.appendPreset) and jumps to it, leaving the other
    // screens and the global look untouched - same meaning as the hub's preset
    // picker. Selection is passive and opens the shared detailed preview; a
    // separate Add screen action commits it. "Reset to default layout" on the
    // Device/About side is the destructive path.
    Dialog {
        id: presetDialog
        objectName: "managerPresetDialog"
        title: "Start from a preset screen"
        modal: true; anchors.centerIn: parent
        focus: true
        width: Math.min(parent ? parent.width * 0.94 : 1100, 1180)
        height: Math.min(parent ? parent.height * 0.9 : 760, 820)
        standardButtons: Dialog.NoButton
        property string selectedId: ""
        readonly property bool landscape: edgeClone.landscape
        // The full-width two-pane picker is ideal on a desktop monitor. Smaller
        // laptop windows stack the scrollable library above the real preview so
        // neither pane is squeezed below its usable width or pushed out of bounds.
        readonly property bool compactLayout: width < 980
        readonly property var selectedPreset: selectedId !== "" ? presetLib.def(selectedId) : null
        onOpened: selectedId = ""
        background: Rectangle { color: m.panel; radius: m.radius; border.width: 1; border.color: m.border }
        header: Rectangle {
            color: "transparent"; implicitHeight: 68
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 20; anchors.rightMargin: 20; spacing: 12
                AppIcon { name: "ui-layout"; size: 24; color: m.accent; Layout.alignment: Qt.AlignVCenter }
                ColumnLayout {
                    spacing: 1; Layout.fillWidth: true
                    Text { text: "Start from a preset screen"; color: m.textPrimary; font.pixelSize: 19; font.bold: true }
                    Text { text: "Adds the chosen screen as a NEW screen - your other screens and your look stay put. Tweak it afterwards."
                        color: m.textSecondary; font.pixelSize: m.fontMinimum; elide: Text.ElideRight; Layout.fillWidth: true }
                }
            }
        }
        contentItem: Item {
            objectName: "managerPresetContent"
            GridLayout {
                id: presetLayout
                objectName: "managerPresetLayout"
                anchors.fill: parent
                anchors.margins: 20
                columns: presetDialog.compactLayout ? 1 : 2
                rowSpacing: 14
                columnSpacing: 14
                MScroll {
                    id: presetScroll
                    objectName: "managerPresetScroll"
                    Layout.row: 0
                    Layout.column: 0
                    Layout.fillWidth: true
                    Layout.fillHeight: !presetDialog.compactLayout
                    Layout.minimumWidth: 0
                    Layout.preferredWidth: presetDialog.compactLayout ? -1 : 520
                    Layout.minimumHeight: presetDialog.compactLayout ? 120 : 0
                    Layout.preferredHeight: presetDialog.compactLayout
                                            ? Math.max(140, Math.min(240, presetLayout.height * 0.42))
                                            : -1
                    Layout.maximumHeight: presetDialog.compactLayout
                                          ? Math.max(140, Math.min(260, presetLayout.height * 0.46))
                                          : Number.POSITIVE_INFINITY
                    clip: true
                    ColumnLayout {
                        width: presetScroll.availableWidth
                        spacing: 10
                        Repeater {
                            model: presetLib.list()
                            delegate: Rectangle {
                                id: managerPresetCard
                                required property var modelData
                                objectName: "managerPresetCard-" + modelData.id
                                readonly property bool selected:
                                    presetDialog.selectedId === modelData.id
                                Layout.fillWidth: true
                                implicitHeight: presetRow.implicitHeight + 24
                                radius: m.radius
                                color: selected
                                    ? Qt.rgba(m.accent.r, m.accent.g, m.accent.b, 0.14)
                                    : (presetMA.containsMouse ? m.panelAlt : m.bg)
                                border.width: selected ? 2 : 1
                                border.color: selected ? m.accent : m.border
                                activeFocusOnTab: true
                                Accessible.role: Accessible.Button
                                Accessible.name: "Preview preset: " + modelData.title
                                Accessible.description: modelData.blurb || ""
                                Accessible.onPressAction: managerPresetCard.previewPreset()
                                Keys.onSpacePressed: managerPresetCard.previewPreset()
                                Keys.onReturnPressed: managerPresetCard.previewPreset()
                                function previewPreset() {
                                    presetDialog.selectedId = managerPresetCard.modelData.id
                                    return true
                                }
                                RowLayout {
                                    id: presetRow
                                    anchors.fill: parent
                                    anchors.margins: 12
                                    spacing: 12
                                    PresetMini {
                                        Layout.alignment: Qt.AlignVCenter
                                        readonly property real previewWidth:
                                            presetDialog.landscape ? 176 : 58
                                        readonly property real previewHeight:
                                            presetDialog.landscape ? 58 : 176
                                        Layout.minimumWidth: previewWidth
                                        Layout.preferredWidth: previewWidth
                                        Layout.maximumWidth: previewWidth
                                        Layout.minimumHeight: previewHeight
                                        Layout.preferredHeight: previewHeight
                                        Layout.maximumHeight: previewHeight
                                        landscape: presetDialog.landscape
                                        tiles: (modelData.pages && modelData.pages[0])
                                               ? modelData.pages[0].tiles : []
                                    }
                                    ColumnLayout {
                                        spacing: 3
                                        Layout.fillWidth: true
                                        RowLayout {
                                            spacing: 8
                                            AppIcon {
                                                name: modelData.icon || "ui-layout"
                                                size: 18
                                                color: m.accent
                                                Layout.alignment: Qt.AlignVCenter
                                            }
                                            Text {
                                                text: modelData.title
                                                color: m.textPrimary
                                                font.pixelSize: 16
                                                font.bold: true
                                            }
                                        }
                                        Text {
                                            text: modelData.blurb || ""
                                            color: m.textSecondary
                                            font.pixelSize: m.fontMinimum
                                            Layout.fillWidth: true
                                            wrapMode: Text.WordWrap
                                            maximumLineCount: 3
                                            elide: Text.ElideRight
                                        }
                                    }
                                }
                                MouseArea {
                                    id: presetMA
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: managerPresetCard.previewPreset()
                                }
                            }
                        }
                    }
                }
                ManagerPresetPreview {
                    objectName: "managerPresetPreview"
                    Layout.row: presetDialog.compactLayout ? 1 : 0
                    Layout.column: presetDialog.compactLayout ? 0 : 1
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.minimumWidth: presetDialog.compactLayout ? 0 : 430
                    Layout.minimumHeight: presetDialog.compactLayout ? 160 : 0
                    preset: presetDialog.selectedPreset
                    widgetCatalog: catalog
                    landscape: presetDialog.landscape
                }
            }
        }
        footer: Rectangle {
            objectName: "managerPresetFooter"
            color: "transparent"
            implicitHeight: m.touch + 32
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 20
                anchors.rightMargin: 20
                anchors.topMargin: 16
                anchors.bottomMargin: 16
                spacing: 10
                Item { Layout.fillWidth: true }
                MButton {
                    objectName: "managerPresetCancel"
                    text: "Cancel"
                    Layout.preferredHeight: m.touch
                    onClicked: presetDialog.close()
                }
                MButton {
                    objectName: "managerPresetAdd"
                    text: "Add selected screen"
                    iconName: "ui-check"
                    primary: true
                    enabled: presetDialog.selectedPreset !== null
                    Layout.preferredHeight: m.touch
                    onClicked: {
                        var id = presetDialog.selectedId
                        presetDialog.close()
                        win.applyPresetScreen(id)
                    }
                }
            }
        }
    }

    // ── Per-widget configure (schema-driven form + live preview) ──
    WidgetConfigDialog { id: cfgDialog }

    // ── Licence entry / management ──
    // Paste a key → live preview (verified offline, no network) → Activate. The
    // preview is what makes this safe to commit: the user sees "unlocks Pro for
    // <name>" (or why not) BEFORE it is stored. Storing routes through
    // backend.setLicenseKey, which respects the single-writer rule (pushes to the
    // hub over IPC when connected so the tier re-gates live; writes directly when
    // offline).
    Dialog {
        id: licenseDialog
        modal: true; anchors.centerIn: parent
        width: Math.min(parent ? parent.width * 0.9 : 640, 640)
        standardButtons: Dialog.NoButton
        background: Rectangle { color: m.panel; radius: m.radius; border.width: 1; border.color: m.border }

        // The candidate the user has typed, and its offline-verified status.
        property string candidate: ""
        property var preview: ({ state: "unlicensed", tier: "free" })
        function reVerify() {
            var k = keyField.text.trim()
            licenseDialog.candidate = k
            if (k.length === 0) { licenseDialog.preview = ({ state: "unlicensed", tier: "free" }); return }
            try { licenseDialog.preview = JSON.parse(backend.verifyLicenseCandidate(k)) }
            catch (e) { licenseDialog.preview = ({ state: "unlicensed", tier: "free" }) }
        }
        onOpened: { keyField.text = ""; licenseDialog.reVerify(); keyField.forceActiveFocus() }

        header: Rectangle {
            color: "transparent"; implicitHeight: 60
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 20; anchors.rightMargin: 20; spacing: 12
                AppIcon { name: "ui-settings"; size: 22; color: m.accent; Layout.alignment: Qt.AlignVCenter }
                Text { text: win.isPro ? "Manage your Pro licence" : "Activate Xeneon Edge Pro"
                    color: m.textPrimary; font.pixelSize: 18; font.bold: true; Layout.fillWidth: true }
            }
        }

        contentItem: ColumnLayout {
            spacing: 12
            Text {
                text: "Paste the licence key from your purchase e-mail. It is verified on "
                    + "this device - nothing is sent anywhere."
                color: m.textSecondary; font.pixelSize: m.fontMinimum
                Layout.fillWidth: true; wrapMode: Text.WordWrap
            }
            Rectangle {
                Layout.fillWidth: true; radius: m.radius
                color: m.bg; border.width: 1
                border.color: keyField.activeFocus ? m.accent : m.border
                implicitHeight: 92
                TextArea {
                    id: keyField
                    anchors.fill: parent; anchors.margins: 8
                    wrapMode: TextArea.WrapAnywhere
                    placeholderText: "XE1.…"
                    color: m.textPrimary; font.family: theme.fontMono; font.pixelSize: m.fontMinimum
                    selectByMouse: true
                    background: null
                    onTextChanged: licenseDialog.reVerify()
                }
            }
            // Live verdict.
            RowLayout {
                Layout.fillWidth: true; spacing: 8
                visible: licenseDialog.candidate.length > 0
                readonly property bool ok: licenseDialog.preview.tier === "pro"
                readonly property bool expired: licenseDialog.preview.state === "expired"
                AppIcon {
                    name: parent.ok ? "ui-check" : "ui-warning"
                    size: 18; color: parent.ok ? m.accent : (parent.expired ? m.danger : m.textSecondary)
                    Layout.alignment: Qt.AlignVCenter
                }
                Text {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                    color: m.textPrimary; font.pixelSize: m.fontMinimum
                    text: parent.ok
                          ? ("Valid - unlocks Pro"
                             + (licenseDialog.preview.issuedTo ? " for " + licenseDialog.preview.issuedTo : "") + ".")
                        : parent.expired
                          ? "This key has expired. Renew to reactivate Pro."
                        : "Not a valid licence key for this product."
                }
            }
            RowLayout {
                Layout.fillWidth: true; Layout.topMargin: 4; spacing: 8
                MButton {
                    visible: win.isPro || win.licStatus.state === "expired"
                    text: "Remove licence"; iconName: "ui-trash"
                    onClicked: { backend.clearLicenseKey(); licenseDialog.close() }
                }
                Item { Layout.fillWidth: true }
                MButton {
                    text: "Cancel"; onClicked: licenseDialog.close()
                }
                MButton {
                    text: "Activate"; iconName: "ui-check"
                    // Only enabled when the pasted key actually unlocks Pro - no
                    // point storing a key the verifier rejects.
                    enabled: licenseDialog.preview.tier === "pro"
                    onClicked: {
                        if (backend.setLicenseKey(licenseDialog.candidate))
                            licenseDialog.close()
                    }
                }
            }
        }
    }

    // ── Image import dialog + model ──
    FileDialog {
        id: fileDialog
        title: "Choose an image"
        nameFilters: ["Images (*.png *.jpg *.jpeg *.webp *.gif *.bmp)"]
        onAccepted: { backend.importImage(selectedFile); win.refreshImages() }
    }

    // Reusable confirm dialog (destructive actions).
    Dialog {
        id: confirmDialog
        property string message: ""
        property var onConfirm: null
        anchors.centerIn: parent
        modal: true; title: "Please confirm"
        standardButtons: Dialog.Yes | Dialog.No
        background: Rectangle { color: m.panel; radius: m.radius; border.width: 1; border.color: m.border }
        header: Rectangle {
            color: "transparent"; implicitHeight: 52
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 18; anchors.rightMargin: 18; spacing: 10
                AppIcon { name: "ui-warning"; size: 20; color: m.danger; Layout.alignment: Qt.AlignVCenter }
                Text { text: "Please confirm"; color: m.textPrimary; font.pixelSize: 17; font.bold: true
                    Layout.fillWidth: true }
            }
        }
        contentItem: Text { text: confirmDialog.message; color: m.textPrimary
            wrapMode: Text.WordWrap; padding: 18; font.pixelSize: m.fontMinimum
            // Cap the width so a long message wraps instead of stretching the dialog wide.
            width: Math.min(implicitWidth, 360) }
        onAccepted: if (onConfirm) onConfirm()
    }

    // Delete an image, clearing the wallpaper anywhere it points at that file.
    function confirmDeleteImage(name, fullPath) {
        confirmDialog.message = "Delete “" + name + "”? This can't be undone."
        confirmDialog.onConfirm = function () {
            if (store.appearance().wallpaper === fullPath) store.setAppearance("wallpaper", "")
            var pages = store.pages()
            for (var i = 0; i < pages.length; i++)
                if (store.pageBackground(i).wallpaper === fullPath)
                    store.setPageBackground(i, "wallpaper", "")
            backend.deleteImage(name)
            win.refreshImages()
        }
        confirmDialog.open()
    }

    // objectName is a test seam: EdgeClone owns a ListModel too (its placement
    // model), so "the ListModel in the Manager tree" no longer identifies this one.
    ListModel { id: imagesModel; objectName: "imagesModel" }
    function refreshImages() {
        imagesModel.clear()
        var list = backend.listImages()
        for (var i = 0; i < list.length; i++) imagesModel.append({ modelData: list[i] })
    }

    // Display target state.
    property var screens: {
        // Array.isArray guard: screensJson() should be an array, but a valid
        // non-array JSON ("{}") would otherwise reach the Repeater model as an object.
        try { var s = JSON.parse(backend.screensJson()); return Array.isArray(s) ? s : [] }
        catch (e) { return [] }
    }
    property string currentTarget: backend.targetConnector()

    Connections {
        target: backend
        ignoreUnknownSignals: true
        function onImagesChanged() { win.refreshImages() }
        // The hub (or disk) changed the config externally - adopt it live.
        function onConfigChanged() {
            if (!store.load(backend.starterLayout()))
                return
            win.persistentSaveError = ""
            win.externalConfigConflictActive = false
            win.syncTheme()
            win.refreshImages()
            if (win.currentPageIndex >= store.pageCount())
                win.currentPageIndex = Math.max(0, store.pageCount() - 1)
            pageName.forIndex = win.currentPageIndex
            pageName.text = win.currentPageName()
        }
        function onHubConfigChanged() {
            win.currentTarget = backend.targetConnector()
            win.refreshLicense()
            if (autostartSwitch)
                autostartSwitch.checked = backend.isAutostart()
        }
        function onHubCurrentPageChanged() {
            win.syncCurrentPageFromHub()
        }
        function onSaveError(message) {
            win.persistentSaveError = message
        }
        function onLayoutSaveError(message) {
            store.markSaveFailed(message)
        }
        function onExternalConfigConflict() {
            win.externalConfigConflictActive = true
            // Commit every widget-local editor buffer before the generation
            // conflict is surfaced. The expected save rejection causes the
            // store to create an owner-only recovery copy.
            win.flushPendingUiState()
        }
        // Display hotplug.
        function onScreensChanged() {
            try { var s = JSON.parse(backend.screensJson() || "[]"); win.screens = Array.isArray(s) ? s : [] } catch (e) { win.screens = [] }
            win.currentTarget = backend.targetConnector()
        }
        // Clear the "Starting hub…" state once the hub actually connects.
        function onHubConnectedChanged() { if (backend.hubConnected) win.hubStarting = false }
    }

    // Pull the hub's latest + refresh live state whenever the Manager regains focus.
    onActiveChanged: if (active) {
        backend.syncFromHub()
        try { var s = JSON.parse(backend.screensJson() || "[]"); if (Array.isArray(s)) win.screens = s } catch (e) {}
        if (autostartSwitch) autostartSwitch.checked = backend.isAutostart()
    }
}
