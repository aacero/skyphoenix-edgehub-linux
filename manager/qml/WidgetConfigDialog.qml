import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// WidgetConfigDialog - a professional, schema-driven per-widget config editor
// with a LIVE preview of the real widget that updates as you edit. Resolves
// store/catalog/theme/media/backend/m from the Manager scope (instantiated
// inline there). Open with open(id, type).
Dialog {
    id: dlg
    property string wId: ""
    property string wType: ""
    property var schema: {
        var _ = widgetStore ? widgetStore.revision : 0
        var settings = widgetStore && wId ? widgetStore.settingsFor(wId) : ({})
        var selected = wType === "gpu" ? settings.gpuDevice
                     : wType === "sensors" ? settings.gpuDevice
                     : wType === "net" ? settings.interfaceName
                     : wType === "disk" ? settings.mountPath : ""
        return schemaReg.schemaFor(wType, metricsObj, selected)
    }
    property string geoStatus: ""
    property string actionStatus: ""
    readonly property var personalDataKeys: catalog.personalDataKeys(dlg.wType)
    readonly property string personalDataLabel: catalog.personalDataLabel(dlg.wType)
    readonly property bool hasPersonalData: personalDataKeys.length > 0
    readonly property alias resetDialog: resetConfirm
    readonly property alias eraseDialog: eraseConfirm
    readonly property alias resetActionButton: resetBtn
    readonly property alias eraseActionButton: eraseBtn
    property var widgetStore: store
    property var widgetCatalog: catalog
    readonly property var widgetTimeZones: (typeof timeZones !== "undefined") ? timeZones : null
    // The city lookup below is the Manager's only intentional egress. Keep it on a
    // narrowly allow-listed gate: typing a city and pressing Search may contact the
    // documented geocoder, but merely opening a live widget preview must never poll
    // the network. The separate offline preview gate is injected into every loaded
    // network widget below, before its debounce timer can fire.
    property var netHub: null
    NetHub {
        id: _geocodeHub
        objectName: "managerGeocodeNetHub"
        allowHosts: ["geocoding-api.open-meteo.com"]
    }
    NetHub {
        id: _previewHub
        objectName: "managerPreviewNetHub"
        offline: true
    }
    NetHub {
        id: _connectionHub
        objectName: "managerConnectionTestNetHub"
        offline: {
            var revision = dlg.widgetStore ? dlg.widgetStore.revision : 0
            return dlg.widgetStore && dlg.widgetStore.appearance
                    ? dlg.widgetStore.appearance().netOffline === true : false
        }
        xhrFactory: dlg.xhrFactory
    }
    // Non-visual QtObjects are not guaranteed to appear below a Control in a
    // children/data walk. Expose the two purpose-specific gates explicitly so
    // diagnostics and tests can inspect the exact objects used by the dialog.
    property alias geocodeNetHub: _geocodeHub
    property alias previewNetHub: _previewHub
    readonly property var previewItem: previewLoader.item
    readonly property bool previewAcceptsInput: previewLoader.acceptsInput
    function _hub() { return netHub ? netHub : _geocodeHub }
    // Test seam: a per-request XHR factory handed to the gate, so a FakeXHR can be
    // injected. null in production → the gate builds the real XHR.
    property var xhrFactory: null

    function openFor(id, type) {
        wId = id; wType = type; geoStatus = ""; actionStatus = ""
        store.ensureSettings(id, catalog.defaults(type))   // seed defaults before the form/preview bind
        open()
    }

    function resetConfiguration() {
        return store.resetConfiguration(dlg.wId, catalog.defaults(dlg.wType), dlg.personalDataKeys)
    }

    function erasePersonalData() {
        if (!dlg.hasPersonalData) return 0
        return store.erasePersonalData(dlg.wId, dlg.personalDataKeys)
    }

    anchors.centerIn: parent
    // Responsive: use most of the window (capped) so the form isn't cramped/clipped.
    width: Math.min(parent ? parent.width * 0.92 : 960, 1200)
    height: Math.min(parent ? parent.height * 0.9 : 680, 900)
    modal: true
    background: Rectangle { color: m.bg; radius: m.radius; border.width: 1; border.color: m.border }

    // Custom token footer instead of the default Fusion DialogButtonBox (which
    // renders a pale light-gray Close on the dark UI). A single accent Close button.
    footer: Rectangle {
        color: "transparent"; implicitHeight: 72
        Button {
            id: closeBtn
            objectName: "closeBtn"
            text: "Close"
            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            anchors.rightMargin: 20
            implicitHeight: m.touch; implicitWidth: 132; hoverEnabled: true
            contentItem: Text {
                text: closeBtn.text; color: m.textOnAccent; font.pixelSize: 16; font.bold: true
                horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
            }
            background: Rectangle {
                radius: m.radius
                color: closeBtn.down ? Qt.darker(m.accent, 1.2)
                       : (closeBtn.hovered ? Qt.lighter(m.accent, 1.1) : m.accent)
            }
            onClicked: dlg.close()
        }
    }

    WidgetConfigSchema { id: schemaReg }

    // Live feeds for the preview widget.
    property int tick: 0
    property var metricsObj: ({})
    Timer { interval: 1000; running: dlg.visible; repeat: true; onTriggered: dlg.tick++ }
    Timer { interval: 2000; running: dlg.visible; repeat: true; triggeredOnStart: true
        onTriggered: { try { dlg.metricsObj = JSON.parse(backend.metricsJson() || "{}") } catch (e) { dlg.metricsObj = ({}) } } }

    function wsrc(type) { var s = catalog.source(type); return s ? s.replace("qrc:/qml/", "qrc:/manager/") : "" }
    // In-flight geocode request, so a new lookup aborts the previous one
    // (re-entrancy guard) and closing the dialog cancels a pending request.
    // Bumping the sequence is what actually cancels: abort() still delivers one
    // late callback, and the gate answers a refused request synchronously (no XHR
    // to compare against), so the token - not the object - decides who is current.
    property var _geoXhr: null
    property int _geoSeq: 0
    function _cancelGeo() {
        dlg._geoSeq++
        if (_geoXhr) { try { _geoXhr.abort() } catch (e) {} _geoXhr = null }
    }

    function doAction(action) {
        if (action === "geocode") {
            var place = store.settingsFor(wId).place || ""
            if (!place.trim().length) { geoStatus = "Type a place name first"; return }
            dlg._cancelGeo()                       // supersede any in-flight lookup
            geoStatus = "Searching…"
            var seq = ++dlg._geoSeq
            var xhr = dlg._hub().request({
                url: "https://geocoding-api.open-meteo.com/v1/search?count=1&name="
                     + encodeURIComponent(place.trim()),
                timeout: 8000,
                xhrFactory: dlg.xhrFactory,
                onDone: function (status, body) {
                    if (seq !== dlg._geoSeq) return
                    dlg._geoXhr = null
                    try {
                        var d = JSON.parse(body)
                        if (d && d.results && d.results.length) {
                            var r = d.results[0]
                            var label = r.name + (r.country_code ? ", " + r.country_code : "")
                            store.patchSettings(wId, { lat: r.latitude, lon: r.longitude, place: label })
                            dlg.geoStatus = "✓ Set to " + label
                        } else dlg.geoStatus = "City not found"
                    } catch (e) { dlg.geoStatus = "Lookup failed" }
                },
                onError: function (reason) {
                    if (seq !== dlg._geoSeq) return
                    dlg._geoXhr = null
                    dlg.geoStatus = reason === "offline" ? "Offline - lookup unavailable"
                        : reason === "blocked" ? "Lookup host not allowed"
                        : reason === "timeout" ? "Lookup timed out - try again" : "Lookup failed"
                }
            })
            if (seq === dlg._geoSeq) dlg._geoXhr = xhr
        } else if (action === "testConnection") {
            var item = dlg.previewItem
            if (!item || !item.hasOwnProperty("testConnection")) {
                dlg.actionStatus = "Connection test is unavailable for this widget."
                return
            }
            dlg.actionStatus = ""
            item.testConnection(_connectionHub)
        }
    }

    onClosed: dlg._cancelGeo()

    // Configuration reset and personal-data erasure have separate, explicit
    // scopes. A reset never removes classified content or progress.
    Dialog {
        id: resetConfirm
        anchors.centerIn: parent
        modal: true; title: "Reset this widget?"
        standardButtons: Dialog.Yes | Dialog.No
        background: Rectangle { color: m.panel; radius: m.radius; border.width: 1; border.color: m.border }
        // Custom token header (mirrors Manager's confirmDialog): the Fusion title
        // chrome clashed with the dark UI and its label sizing fed the Dialog an
        // implicitWidth binding loop.
        header: Rectangle {
            color: "transparent"; implicitHeight: 52
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 18; anchors.rightMargin: 18; spacing: 10
                AppIcon { name: "ui-warning"; size: 20; color: m.danger; Layout.alignment: Qt.AlignVCenter }
                Text { text: resetConfirm.title; color: m.textPrimary; font.pixelSize: 17; font.bold: true
                    Layout.fillWidth: true }
            }
        }
        contentItem: Text {
            text: "Reset " + catalog.title(dlg.wType) + " configuration to its defaults?"
                + (dlg.hasPersonalData ? " Your " + dlg.personalDataLabel + " will be kept." : "")
            color: m.textPrimary; wrapMode: Text.WordWrap; padding: 14
            font.pixelSize: m.fontMinimum
            // Same cap as Manager's confirmDialog: an uncapped Text keeps widening
            // the dialog that sizes it (implicitWidth binding loop).
            width: Math.min(implicitWidth, 360)
        }
        onAccepted: dlg.resetConfiguration()
    }

    Dialog {
        id: eraseConfirm
        objectName: "erasePersonalDataConfirm"
        anchors.centerIn: parent
        modal: true
        title: "Erase personal data?"
        standardButtons: Dialog.Yes | Dialog.No
        background: Rectangle { color: m.panel; radius: m.radius; border.width: 1; border.color: m.border }
        header: Rectangle {
            color: "transparent"; implicitHeight: 52
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 18; anchors.rightMargin: 18; spacing: 10
                AppIcon { name: "ui-warning"; size: 20; color: m.danger; Layout.alignment: Qt.AlignVCenter }
                Text { text: eraseConfirm.title; color: m.textPrimary; font.pixelSize: 17; font.bold: true
                    Layout.fillWidth: true }
            }
        }
        contentItem: Text {
            text: "Erase " + dlg.personalDataLabel + " from " + catalog.title(dlg.wType)
                + "? Widget configuration and appearance will be kept. This can't be undone."
            color: m.textPrimary; wrapMode: Text.WordWrap; padding: 14
            font.pixelSize: m.fontMinimum
            width: Math.min(implicitWidth, 380)
        }
        onAccepted: dlg.erasePersonalData()
    }

    header: Rectangle {
        color: "transparent"; implicitHeight: 74
        RowLayout {
            anchors.fill: parent; anchors.leftMargin: 20; anchors.rightMargin: 20; spacing: 14
            AppIcon { name: dlg.wType; size: 32; color: theme.accent; Layout.alignment: Qt.AlignVCenter }
            ColumnLayout {
                spacing: 1; Layout.fillWidth: true
                Text { text: catalog.title(dlg.wType) + " - Configure"; color: m.textPrimary; font.pixelSize: 20; font.bold: true }
                Text { text: catalog.desc(dlg.wType); color: m.textSecondary; font.pixelSize: m.fontMinimum
                    elide: Text.ElideRight; Layout.fillWidth: true }
            }
            // Scope pill: these settings touch ONE tile, not the widget type -
            // the owner's "which setting changes which behavior" complaint. Label +
            // hover detail come from the Manager's ONE scope vocabulary (win.scopeLabels
            // / win.scopeDetail), so this dialog can't drift from the tabs' wording.
            Rectangle {
                id: scopePill
                objectName: "scopeTag"
                Layout.alignment: Qt.AlignVCenter
                implicitWidth: scopeLbl.implicitWidth + 24; implicitHeight: 32; radius: 16
                color: "transparent"; border.width: 1; border.color: m.accent
                property alias text: scopeLbl.text
                Text { id: scopeLbl; anchors.centerIn: parent; text: win.scopeLabels.widget
                    color: m.accent; font.pixelSize: m.fontMinimum; font.bold: true }
                ToolTip.visible: scopeMA.containsMouse && ToolTip.text !== ""
                ToolTip.delay: 250
                ToolTip.text: win.scopeDetail(scopeLbl.text)
                MouseArea { id: scopeMA; anchors.fill: parent; hoverEnabled: true }
            }
        }
    }

    contentItem: RowLayout {
        spacing: 18

        // ── Live-state, passive preview ──
        ColumnLayout {
            Layout.preferredWidth: 340; Layout.maximumWidth: 340; Layout.fillHeight: true; spacing: 10
            Text { text: "Live preview"; color: m.textSecondary; font.pixelSize: m.fontLabel; font.bold: true }
            Rectangle {
                Layout.fillWidth: true; Layout.fillHeight: true
                radius: 18; color: theme.backgroundColor; border.width: 2; border.color: "#000"; clip: true
                Rectangle {
                    anchors.fill: parent; anchors.margins: 10; radius: 12; clip: true
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: theme.backgroundColor }
                        GradientStop { position: 1.0; color: theme.backgroundColor3 }
                    }
                    // WYSIWYG preview. The widget is rendered at the Edge content width
                    // (`logicalW`, ~688px) - the width it was DESIGNED for - inside a
                    // fixed-logical-size scaler, then scaled down to fit this ~300px pane
                    // (the same trick EdgeClone uses on the whole device). Without this the
                    // expanded layout (Focus's 4-button row, Media transport, Countdown's
                    // label+date+Save, Tasks add-row, Hydration) overflows the narrow pane
                    // and is clipped by WidgetChrome.body{clip:true}.
                    Item {
                        id: previewClip
                        objectName: "previewClip"
                        anchors.fill: parent; anchors.margins: 10; clip: true
                        // Edge portrait content width the expanded widgets target.
                        readonly property real logicalW: 688
                        readonly property real fit: width > 0 ? width / logicalW : 1
                        Item {
                            id: previewScaler
                            objectName: "previewScaler"
                            width: previewClip.logicalW
                            // Give the widget a tall logical canvas so that AFTER scaling it
                            // exactly fills the pane's height (fit * height === pane height).
                            height: previewClip.fit > 0 ? previewClip.height / previewClip.fit : previewClip.height
                            transformOrigin: Item.TopLeft
                            scale: previewClip.fit
                            WidgetHost {
                                id: previewLoader
                                anchors.fill: parent
                                // Recreate the tile body on every open so reopening for a DIFFERENT
                                // instance of the same type reloads and re-seeds against the new
                                // instanceId - otherwise the source is unchanged, the Loader never
                                // reloads, onLoaded never fires, and the previous instance's body
                                // (with its stale instanceId) lingers (split-brain preview).
                                loadEnabled: dlg.visible && dlg.wType !== ""
                                widgetId: dlg.wId
                                widgetType: dlg.wType
                                widgetSource: dlg.wsrc(dlg.wType)
                                store: dlg.widgetStore
                                catalog: dlg.widgetCatalog
                                metrics: dlg.metricsObj
                                netHub: _previewHub
                                timeZones: dlg.widgetTimeZones
                                tick: dlg.tick
                                expanded: true
                                sizeClass: "full"
                                driverActive: false
                                // Tasks uses the expanded live widget as its single
                                // content editor. Other previews remain read-only.
                                acceptsInput: dlg.wType === "tasks"
                                              || dlg.wType === "notes"
                                suppressHeader: true
                            }
                        }
                    }
                }
            }
            Text {
                Layout.fillWidth: true; wrapMode: Text.WordWrap
                // Honest about the commit path: "instantly on the Edge" was shown
                // even while the sidebar said "Hub offline (saved)".
                text: backend.hubConnected
                      ? "Preview only. Settings apply live to the Edge; use the Hub for widget actions."
                      : "Preview only. Settings are saved and appear when the Hub starts."
                color: m.textSecondary; font.pixelSize: m.fontMinimum
            }
            // Token-styled (mirrors Manager's MButton) so it matches the dark app
            // palette instead of rendering as a pale default Fusion button.
            Button {
                id: resetBtn
                objectName: "resetConfigurationBtn"
                text: "Reset configuration"; Layout.fillWidth: true
                implicitHeight: m.touch; hoverEnabled: true
                contentItem: Text {
                    text: resetBtn.text; color: m.textPrimary; font.pixelSize: m.fontLabel
                    horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                }
                background: Rectangle {
                    radius: m.radius
                    color: (resetBtn.down || resetBtn.hovered) ? m.panelAlt : m.panel
                    border.width: 1; border.color: m.border
                }
                onClicked: resetConfirm.open()
            }
            Button {
                id: eraseBtn
                objectName: "erasePersonalDataBtn"
                visible: dlg.hasPersonalData
                text: "Erase personal data"; Layout.fillWidth: true
                implicitHeight: m.touch; hoverEnabled: true
                contentItem: Text {
                    text: eraseBtn.text; color: m.danger; font.pixelSize: m.fontLabel
                    horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                }
                background: Rectangle {
                    radius: m.radius
                    color: eraseBtn.down ? Qt.rgba(m.danger.r, m.danger.g, m.danger.b, 0.16) : "transparent"
                    border.width: 1; border.color: m.danger
                }
                onClicked: eraseConfirm.open()
            }
        }

        Rectangle { Layout.preferredWidth: 1; Layout.fillHeight: true; color: m.border }

        // ── Form (shared panel - identical rendering to the on-device config) ──
        WidgetConfigPanel {
            Layout.fillWidth: true; Layout.fillHeight: true; Layout.minimumWidth: 320
            schema: dlg.schema
            st: store
            instanceId: dlg.wId
            col: m
            statusText: {
                if (dlg.previewItem && dlg.previewItem.hasOwnProperty("connectionStatus")
                        && dlg.previewItem.connectionStatus.length)
                    return dlg.previewItem.connectionStatus
                if (dlg.actionStatus.length) return dlg.actionStatus
                return (dlg.wType === "weather" || dlg.wType === "moon") ? dlg.geoStatus : ""
            }
            onActionRequested: (a) => dlg.doAction(a)
        }
    }
}
