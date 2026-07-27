import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import QtQuick.VirtualKeyboard

ApplicationWindow {
    id: root
    // Start hidden. C++ positions the window on the target Xeneon screen,
    // then calls showFullScreen() / show(). This is critical for Wayland.
    visibility: Window.Hidden

    // Borderless when fullscreen; normal window decorations with --windowed
    flags: _windowedMode ? Qt.Window : (Qt.FramelessWindowHint | Qt.Window)

    // Properties exposed from C++
    property bool isFirstRun: _isFirstRun
    property string screensData: _screens
    property string metricsJson: _metricsJson
    property string themeMode: _themeMode
    property string targetEdidHash: _targetEdidHash
    property string targetConnector: _targetConnector
    property string targetModel: _targetModel
    property string configDir: _configDir
    property bool safeMode: _safeMode
    readonly property bool widgetsEnabled:
        typeof _widgetsEnabled === "undefined" ? !safeMode : _widgetsEnabled
    property bool startInDiagnostics: typeof _startInDiagnostics !== "undefined" ? _startInDiagnostics : false
    property bool windowedMode: typeof _windowedMode !== "undefined" ? _windowedMode : false
    property int targetScreenX: typeof _targetScreenX !== "undefined" ? _targetScreenX : 0
    property int targetScreenY: typeof _targetScreenY !== "undefined" ? _targetScreenY : 0
    property int targetScreenWidth: typeof _targetScreenWidth !== "undefined" ? _targetScreenWidth : 1920
    property int targetScreenHeight: typeof _targetScreenHeight !== "undefined" ? _targetScreenHeight : 1080

    // Screen hotplug properties
    property string screenAdded: ""
    property string screenRemoved: ""
    // C++ also sends a real org.freedesktop.Notifications desktop notice. These
    // state markers make the event observable to QML/Diagnostics without trying
    // to show a popup inside the safety-hidden Hub window.
    property string displayDisconnected: ""
    property string displaySelectionRequested: ""
    property string lastDisplayEventText: ""

    // Live UI-state pushed from the companion Manager app via the C++
    // ControlServer. Forward it to the dashboard for an immediate reload.
    property string externalUiState: ""
    property string pendingExternalUiState: ""
    property int externalUiStateRetryCount: 0
    property bool externalUiStateApplied: false
    property string persistenceWarningText:
        (typeof _startupPersistenceWarning !== "undefined")
        ? String(_startupPersistenceWarning) : ""
    property string externalPushWarningText: ""
    Connections {
        target: (typeof configBridge !== "undefined") ? configBridge : null
        ignoreUnknownSignals: true
        function onPersistenceWarning(message) {
            root.persistenceWarningText = message
        }
    }
    Connections {
        target: (typeof wizardBridge !== "undefined") ? wizardBridge : null
        ignoreUnknownSignals: true
        function onPersistenceWarning(message) {
            root.persistenceWarningText = message
        }
    }
    Connections {
        target: (typeof license !== "undefined") ? license : null
        ignoreUnknownSignals: true
        function onPersistenceWarning(message) {
            root.persistenceWarningText = message
        }
    }
    Rectangle {
        objectName: "hubPersistenceWarningBanner"
        z: 20000
        visible: root.persistenceWarningText !== ""
        anchors.top: parent.top
        anchors.topMargin: 12
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(parent.width - 32, 1100)
        height: warningRow.implicitHeight + 24
        radius: 12
        color: "#2B1717"
        border.width: 2
        border.color: "#F85149"
        RowLayout {
            id: warningRow
            anchors.fill: parent
            anchors.margins: 12
            spacing: 12
            Text {
                Layout.fillWidth: true
                text: root.persistenceWarningText
                color: "#FFFFFF"
                font.pixelSize: 18
                font.bold: true
                wrapMode: Text.Wrap
            }
            Button {
                text: "Dismiss"
                Layout.minimumWidth: 112
                Layout.minimumHeight: 52
                onClicked: root.persistenceWarningText = ""
            }
        }
    }

    // Called synchronously by the control socket before the incoming document
    // is persisted. A Dashboard can save unfinished local work and reject this
    // request as an explicit conflict. With no Dashboard yet, no widget editor
    // exists, so persistence is safe and live application remains queued.
    function preflightExternalUiState(json) {
        if (!json || !json.length)
            return "rejected"
        var target = stackView.find(function (item) {
            return item && typeof item.preflightExternalState === "function"
        })
        if (!target)
            return "queued"

        var status = target.preflightExternalState(json)
        if (status === "conflict") {
            externalPushWarningText =
                "Manager changes were not applied because this Hub had an unfinished edit. "
                + "The Hub saved that edit. Review the conflict in Manager, then retry or discard."
            persistenceWarningText = externalPushWarningText
        } else if (status === "flush-failed") {
            externalPushWarningText =
                "Manager changes were not applied because the Hub could not save an unfinished edit. "
                + "Keep this Hub open and use the recovery controls before retrying."
            persistenceWarningText = externalPushWarningText
        } else if (status === "rejected") {
            externalPushWarningText =
                "Manager changes were rejected because the layout is invalid or blocked by policy."
            persistenceWarningText = externalPushWarningText
        }
        return status
    }

    function applyExternalUiState(json) {
        if (!json || !json.length) return false
        pendingExternalUiState = json
        // Route to whichever stack item can apply it (the Dashboard), even when
        // Diagnostics or the wizard is on top - otherwise a live Manager push is
        // silently dropped while any other page is showing.
        var target = stackView.find(function (item) { return item && item.applyExternalState })
        if (!target) {
            externalUiStateRetryCount++
            return false
        }
        var applied = target.applyExternalState(json)
        if (applied === false) {
            // Preflight already excluded invalid and policy-blocked documents.
            // Keep an unexpected live-apply failure queued so getUiState cannot
            // claim that the persisted document is already on the panel.
            externalUiStateRetryCount++
            return false
        }
        pendingExternalUiState = ""
        externalUiStateRetryCount = 0
        if (persistenceWarningText === externalPushWarningText)
            persistenceWarningText = ""
        externalPushWarningText = ""
        return true
    }
    onExternalUiStateChanged: {
        externalUiStateApplied = applyExternalUiState(externalUiState)
    }
    Timer {
        id: externalUiStateRetry
        interval: 50
        repeat: false
        onTriggered: {
            if (root.pendingExternalUiState)
                root.externalUiStateApplied =
                    root.applyExternalUiState(root.pendingExternalUiState)
        }
    }
    Connections {
        target: stackView
        function onCurrentItemChanged() {
            if (root.pendingExternalUiState)
                externalUiStateRetry.restart()
        }
        function onDepthChanged() {
            if (root.pendingExternalUiState)
                externalUiStateRetry.restart()
        }
    }

    // ── Manager screen mirroring (O1) ─────────────────────────────────────────
    // The Manager tells the hub which screen the user has selected, so the panel
    // shows the screen being edited instead of always snapping back to the first.
    // Both are invoked from C++ (ControlServer): requestHubPage on setActivePage,
    // hubCurrentPage from the getUiState provider. Routed through the stack so it
    // works even when Diagnostics/the wizard is on top of the Dashboard.
    function requestHubPage(idx) {
        var t = stackView.find(function (item) { return item && item.goToPageExternal })
        if (t) t.goToPageExternal(idx)
    }
    function hubCurrentPage() {
        var t = stackView.find(function (item) { return item && item.currentPageIndex !== undefined })
        return t ? t.currentPageIndex : -1
    }

    // Clean shutdown calls this synchronously before the C++ persistence bridge
    // is detached. The Dashboard first commits widget-local editor buffers and
    // then forces its store to disk.
    function flushPendingUiState() {
        var t = stackView.find(function (item) {
            return item && typeof item.flushPendingUiState === "function"
        })
        return t ? t.flushPendingUiState() : true
    }

    // React to screen hotplug events
    onScreenAddedChanged: {
        if (screenAdded) console.log("Screen added:", screenAdded)
    }
    onScreenRemovedChanged: {
        if (screenRemoved) console.log("Screen removed:", screenRemoved)
    }
    onDisplayDisconnectedChanged: {
        var name = displayDisconnected
        if (!name) {
            lastDisplayEventText = ""
            return
        }
        lastDisplayEventText = "Dashboard display " + name
            + " disconnected. Waiting for reconnection."
        console.log(lastDisplayEventText)
    }
    onDisplaySelectionRequestedChanged: {
        var name = displaySelectionRequested
        if (!name) return
        lastDisplayEventText = "Dashboard display " + name
            + " is unavailable. Open Xeneon Edge Manager to select a display."
        console.log(lastDisplayEventText)
    }

    // Reduced-motion preference (design system: all durations → 0ms).
    property alias reduceMotion: _theme.reduceMotion

    // --- Runtime customization state (persisted best-effort) ---
    // These four are now aliases onto the shared Theme (single source of tokens),
    // so existing root.accentName / root.glassOpacity / … keep working and their
    // change signals still drive DashboardStore persistence.
    property alias accentName: _theme.accentName
    property alias glassOpacity: _theme.glassOpacity
    property alias showWidgetGlow: _theme.showWidgetGlow
    property alias textScale: _theme.textScale
    property alias fontChoice: _theme.fontChoice
    property bool animatedBackground: false  // Calm-by-default (beta): no drifting
                                             // orbs on a fresh install; opt in via
                                             // Appearance. Motion transitions stay on.

    // Shared design-system tokens (single source of truth; see ui/qml/Theme.qml).
    // Its runtime knobs (accent/glass/glow/reduceMotion) are aliased onto root above.
    Theme {
        id: _theme
        // OS reduce-motion signal, read by C++ over the XDG settings portal
        // (SystemSettingsProbe - QML/Qt cannot see this setting on any Qt 6).
        // Guarded so harnesses without the context property keep the safe
        // default (false = no OS signal). Precedence lives in Theme.qml:
        // an explicit reduceMotionPreference still beats this.
        systemReduceMotion: (typeof systemSettings !== "undefined" && systemSettings)
            ? systemSettings.reduceMotion : false
        Component.onCompleted: applyTheme(root.themeMode)
    }

    property alias theme: _theme

    // Inject live bindings for the shell-provided data (metrics/screens/config)
    // into a stack page that declares those properties (e.g. Diagnostics, which
    // shadows them with its own "" defaults). Dashboard has no such own-property
    // and reads root.metricsJson via context scope, so it's simply skipped.
    // Using Qt.binding (not a one-shot copy) keeps the initial --diagnostics page
    // and Ctrl+D pushes updating live instead of freezing at the first sample.
    function bindStackItem(item) {
        if (!item) return
        if (item.hasOwnProperty("metricsJson"))
            item.metricsJson = Qt.binding(function () { return root.metricsJson })
        if (item.hasOwnProperty("screensData"))
            item.screensData = Qt.binding(function () { return root.screensData })
        if (item.hasOwnProperty("configJson"))
            item.configJson = Qt.binding(function () {
                return (typeof configBridge !== "undefined" && configBridge)
                    ? configBridge.configJson() : ""
            })
        // Diagnostics' Network tab reads the app-global egress gate (W5
        // finding 6). The gate lives inside the Dashboard (one NetHub per
        // app), so resolve it off the stack; when no dashboard exists
        // (--diagnostics start) it stays null and the tab states that
        // honestly rather than showing zeros.
        if (item.hasOwnProperty("netHub")) {
            var dash = stackView.find(function (it) { return it && it.netGate !== undefined })
            if (dash) item.netHub = dash.netGate
        }
    }

    // ── Orientation ──────────────────────────────────────────────────────────
    // `orientationMode` (persisted appearance) is "auto" or a fixed value.
    //
    // AUTO follows the Edge's built-in orientation sensor: C++ reads it over the
    // vendor HID pipe and pushes the correct content rotation into `sensorRotation`
    // (0/90/180/270); we rotate + reflow the UI to match so it stays upright as the
    // panel turns. MANUAL modes ignore the sensor and apply a fixed rotation (for
    // wall/arm mounts). Until the sensor reports (or if the hidraw node isn't
    // readable) `sensorRotation` is -1 and auto stays at 0.
    property int sensorRotation: -1          // raw value pushed from C++ OrientationSensor
    // Debounced sensor value: the raw reading must hold steady briefly before we
    // rotate, so jitter near an orientation boundary doesn't thrash the whole UI
    // (each change triggers a 560ms rotate + a fade/scale dip).
    property int _stableSensorRotation: -1
    onSensorRotationChanged: {
        if (root.sensorRotation < 0) return
        if (root._stableSensorRotation < 0) root._stableSensorRotation = root.sensorRotation // apply the first reading promptly
        else sensorDebounce.restart()
    }
    Timer {
        id: sensorDebounce; interval: 350; repeat: false
        onTriggered: root._stableSensorRotation = root.sensorRotation
    }
    property string orientationMode: "auto"
    readonly property int contentRotation: {
        switch (orientationMode) {
        case "portrait": return 0
        case "landscape": return 90
        case "inverted-portrait": return 180
        case "inverted-landscape": return 270
        // Auto: follow the sensor once it has reported. Until then (first boot on a
        // panel that answers no startup GET_REPORT, before any physical rotation),
        // default to LANDSCAPE - the Edge's primary orientation - rather than sitting
        // in portrait. Derived from the window aspect so it's correct whether the OS
        // exposes the panel as portrait (720x2560 → rotate 90 to landscape) or already
        // landscape (2560x720 → 0). The sensor overrides this the moment it reports,
        // and the last real orientation is remembered across runs (OrientationSensor).
        default: return _stableSensorRotation >= 0 ? _stableSensorRotation
                                                   : (root.height > root.width ? 90 : 0)
        }
    }

    // NOTE: Diagnostics is reached via the ⚙ button on the dashboard and the
    // Ctrl+D shortcut. Earlier there were whole-window TapHandlers here (3-finger
    // + right-click) - removed because a root-level gesture handler can delay
    // touch delivery to the widget buttons underneath, hurting responsiveness.

    // Rotating content container - rotates + reflows the whole UI to match the
    // device orientation. When rotated 90/270 it swaps width/height so the
    // dashboard inside lays out for the effective aspect (landscape → more cols).
    Item {
        id: contentRoot
        anchors.centerIn: parent
        transformOrigin: Item.Center
        readonly property bool swapped: root.contentRotation === 90 || root.contentRotation === 270
        width: swapped ? root.height : root.width
        height: swapped ? root.width : root.height
        rotation: root.contentRotation
        // Always turn the SHORT way (0°↔270° goes -90°, not +270°) with a soft ease.
        Behavior on rotation {
            RotationAnimation {
                direction: RotationAnimation.Shortest
                // effectiveReduceMotion: the OS signal and the explicit on/off
                // preference must also collapse the rotation to a cut.
                duration: theme.effectiveReduceMotion ? 0 : 560
                easing.type: Easing.InOutCubic
            }
        }
        // Soften the reflow: as it re-orients, dip opacity + scale slightly so the
        // aspect swap (portrait↔landscape grid) is masked behind a smooth fade.
        Connections {
            target: root
            function onContentRotationChanged() {
                // Dismiss the on-screen keyboard before re-orienting so it can't
                // flash while the container height swaps underneath it.
                Qt.inputMethod.hide()
                if (!theme.effectiveReduceMotion) reorientFx.restart()
            }
        }
        SequentialAnimation {
            id: reorientFx
            ParallelAnimation {
                NumberAnimation { target: contentRoot; property: "opacity"; to: 0.25; duration: 210; easing.type: Easing.InQuad }
                NumberAnimation { target: contentRoot; property: "scale"; to: 0.93; duration: 210; easing.type: Easing.InQuad }
            }
            ParallelAnimation {
                NumberAnimation { target: contentRoot; property: "opacity"; to: 1.0; duration: 360; easing.type: Easing.OutQuad }
                NumberAnimation { target: contentRoot; property: "scale"; to: 1.0; duration: 360; easing.type: Easing.OutCubic }
            }
        }

        // Navigation stack for main ↔ diagnostics
        StackView {
            id: stackView
            objectName: "mainStack"
            anchors.fill: parent
            // Resolve each page relative to this file. In the shipped binary
            // that naturally becomes qrc:/qml/<page>; when the composed GUI
            // suite loads main.qml from the source tree it stays a file: URL.
            // Inferring the scheme from resolvedUrl(".") was unreliable and
            // made the source-loaded shell try to open a non-existent qrc page.
            initialItem: isFirstRun ? Qt.resolvedUrl("FirstRunWizard.qml").toString() :
                         startInDiagnostics ? Qt.resolvedUrl("Diagnostics.qml").toString() :
                         Qt.resolvedUrl("Dashboard.qml").toString()

            // The initial page is instantiated from a URL, so no properties get
            // passed in - inject the live bindings once it exists. Without this,
            // starting with --diagnostics shows an empty Diagnostics page.
            Component.onCompleted: root.bindStackItem(currentItem)

            // Keep the focused input above the on-screen keyboard: lift the whole
            // stack by exactly the overlap between the text cursor and the keyboard
            // top (0 when the cursor is already clear). Without this, inputs in the
            // bottom half of a 2560px panel are fully hidden behind the VK.
            transform: Translate {
                y: {
                    if (!inputPanel.active) return 0
                    // The keyboard top and the StackView we translate both live
                    // inside the rotated contentRoot, but Qt.inputMethod.cursorRectangle
                    // is in scene/window coordinates. Map the cursor rect into
                    // contentRoot's (rotated) frame first, otherwise in landscape
                    // (90°/270°) the overlap is measured on the wrong axis and the
                    // lift is wildly wrong.
                    var kbTop = contentRoot.height - inputPanel.height
                    var cur = Qt.inputMethod.cursorRectangle
                    var local = contentRoot.mapFromItem(null, cur.x, cur.y, cur.width, cur.height)
                    var need = (local.y + local.height + theme.spacingLg) - kbTop
                    return need > 0 ? -need : 0
                }
                Behavior on y { NumberAnimation { duration: theme.motionEdit; easing.type: Easing.OutCubic } }
            }
        }

        // On-screen keyboard: this is a touchscreen device with no attached
        // physical keyboard, so any focused TextField needs a way to type.
        InputPanel {
            id: inputPanel
            z: 1000
            anchors.left: parent.left
            anchors.right: parent.right
            // Only render when the keyboard is actually active, so it can never
            // flash during a rotation (when contentRoot's height changes under it).
            visible: inputPanel.active
            y: active ? contentRoot.height - height : contentRoot.height
            // Slide only for genuine show/hide - not when the container resizes
            // on rotation (which would otherwise re-animate the hidden panel).
            Behavior on y { enabled: inputPanel.active; NumberAnimation { duration: theme.motionEdit; easing.type: Easing.OutCubic } }
        }
    }


    // Keyboard shortcuts
    Shortcut {
        sequence: "Ctrl+D"
        onActivated: {
            if (stackView.depth > 1) {
                stackView.pop();
            } else {
                // Bind live (metrics/screens/config) so the Diagnostics overview
                // keeps updating, rather than freezing at the snapshot taken when
                // Ctrl+D was pressed.
                var diag = stackView.push(Qt.resolvedUrl("Diagnostics.qml").toString());
                root.bindStackItem(diag);
            }
        }
    }
    Shortcut {
        sequence: "Ctrl+Q"
        onActivated: Qt.quit()
    }
    Shortcut {
        sequence: "F11"
        onActivated: {
            if (root.visibility === Window.FullScreen) {
                root.visibility = Window.Windowed;
            } else {
                root.visibility = Window.FullScreen;
            }
        }
    }

    Component.onCompleted: {
        var version = (typeof configBridge !== "undefined" && configBridge && configBridge.appVersion)
            ? configBridge.appVersion() : "dev"
        console.log("Xeneon Edge Linux Hub " + version + " started");
        console.log("Config dir:", configDir);
        console.log("Theme mode:", themeMode);
        console.log("Is first run:", isFirstRun);
        console.log("Target screen:", targetScreenWidth + "x" + targetScreenHeight,
                     "at (" + targetScreenX + "," + targetScreenY + ")");
        if (safeMode) {
            console.log("Running in SAFE MODE");
        }
        if (windowedMode) {
            console.log("Windowed mode (--windowed)");
        }
        if (startInDiagnostics) {
            console.log("Starting in diagnostics mode (--diagnostics)");
        }
    }
}
