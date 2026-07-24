import QtQuick

// Shared first-party widget host. It owns the loader and the lifecycle contract
// used by the Hub tile, Hub expanded view, Manager clone, and Manager config
// preview. The host decides whether the loaded view may drive timers, polling,
// and ephemeral state. A rendered Manager preview is always passive.
Item {
    id: host

    property string widgetId: ""
    property string widgetType: ""
    property url widgetSource: ""
    property Component widgetComponent: null
    property bool loadEnabled: widgetSource !== "" || widgetComponent !== null

    property var store: null
    property var catalog: null
    property var metrics: ({})
    property var netHub: null
    property var timeZones: null
    property int tick: 0

    property bool expanded: false
    property string sizeClass: expanded ? "full" : "compact"
    property bool driverActive: false
    property bool foreground: false
    property bool acceptsInput: true
    property bool chromeless: false
    property bool suppressHeader: false
    property bool ensureSettings: true
    property bool clipContent: true

    readonly property alias item: widgetLoader.item
    readonly property alias status: widgetLoader.status
    readonly property bool loadFailed: widgetLoader.status === Loader.Error
    signal widgetLoaded(var item)

    function _ensureCurrent() {
        if (host.ensureSettings && host.store && host.catalog && host.widgetId
                && host.store.ensureSettings && host.catalog.defaults)
            host.store.ensureSettings(host.widgetId, host.catalog.defaults(host.widgetType))
    }
    onWidgetIdChanged: _ensureCurrent()
    onWidgetTypeChanged: _ensureCurrent()
    onStoreChanged: _ensureCurrent()
    onCatalogChanged: _ensureCurrent()

    function _settings() {
        if (!host.store || !host.widgetId || !host.store.settingsFor) return ({})
        return host.store.settingsFor(host.widgetId) || ({})
    }

    // Clean-shutdown persistence hook. Most widgets write directly to the
    // shared store and need no local action. Editors such as Quick Note expose
    // flush() for their own shorter debounce; commit that buffer before the
    // DashboardStore performs its final synchronous save.
    function flushPendingState() {
        if (!host.item || typeof host.item.flush !== "function")
            return false
        host.item.flush()
        return true
    }

    function configure(item) {
        if (!item) return
        host._ensureCurrent()

        // Driver and egress bindings land before the store. A passive preview
        // must not briefly observe a writable store while still at a widget's
        // default active:true value.
        if (item.hasOwnProperty("active"))
            item.active = Qt.binding(function () { return host.driverActive })
        if (item.hasOwnProperty("foreground"))
            item.foreground = Qt.binding(function () { return host.foreground })
        if (item.hasOwnProperty("netHub"))
            item.netHub = Qt.binding(function () { return host.netHub })
        if (item.hasOwnProperty("expanded"))
            item.expanded = Qt.binding(function () { return host.expanded })
        if (item.hasOwnProperty("sizeClass"))
            item.sizeClass = Qt.binding(function () { return host.sizeClass })
        if (item.hasOwnProperty("metrics"))
            item.metrics = Qt.binding(function () { return host.metrics })
        if (item.hasOwnProperty("timeZones"))
            item.timeZones = Qt.binding(function () { return host.timeZones })
        if (item.hasOwnProperty("tick"))
            item.tick = Qt.binding(function () { return host.tick })
        if (item.hasOwnProperty("chromeless"))
            item.chromeless = Qt.binding(function () { return host.chromeless })
        if (item.hasOwnProperty("showHeader") && host.suppressHeader)
            item.showHeader = false
        if (item.hasOwnProperty("instanceId"))
            item.instanceId = Qt.binding(function () { return host.widgetId })
        if (item.hasOwnProperty("store"))
            item.store = Qt.binding(function () { return host.store })

        if (item.hasOwnProperty("titleOverride"))
            item.titleOverride = Qt.binding(function () {
                if (host.store) host.store.revision
                var s = host._settings()
                return s.title || ""
            })
        if (item.hasOwnProperty("accentName"))
            item.accentName = Qt.binding(function () {
                if (host.store) host.store.revision
                var s = host._settings()
                return s.accent || ""
            })
        if (item.hasOwnProperty("cardBackdrop"))
            item.cardBackdrop = Qt.binding(function () {
                if (host.store) host.store.revision
                var s = host._settings()
                return s.cardBackdrop || "none"
            })

        host.widgetLoaded(item)
    }

    Loader {
        id: widgetLoader
        anchors.fill: parent
        clip: host.clipContent
        active: host.loadEnabled
        source: host.widgetComponent === null && host.loadEnabled ? host.widgetSource : ""
        sourceComponent: host.widgetComponent
        onLoaded: host.configure(item)
    }

    // A known catalog entry can still fail to compile or load after packaging,
    // an incompatible Qt update, or a damaged user-widget file. Loader.Error
    // previously left the allocated tile completely blank. Keep the failure
    // local to this host and show a safe, noninteractive replacement without
    // exposing filesystem paths or engine diagnostics.
    Rectangle {
        objectName: "widgetLoadError"
        anchors.fill: parent
        z: 900
        visible: host.loadFailed
        radius: 18
        color: "#171b24"
        border.width: 2
        border.color: "#e3a84f"
        Accessible.role: Accessible.StaticText
        Accessible.name: "Widget unavailable. "
                         + (host.widgetType.length ? host.widgetType + " could not load." : "The widget could not load.")

        Column {
            anchors.centerIn: parent
            width: Math.max(80, parent.width - 40)
            spacing: 8
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: "Widget unavailable"
                color: "#ffffff"
                font.pixelSize: 20
                font.bold: true
                wrapMode: Text.WordWrap
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: host.widgetType.length
                      ? host.widgetType + " could not be loaded."
                      : "This widget could not be loaded."
                color: "#d4d8e2"
                font.pixelSize: 16
                wrapMode: Text.WordWrap
            }
        }
    }

    // Manager previews must remain visually accurate but cannot execute widget
    // actions. This shield also prevents a pointer press from giving a child
    // control keyboard focus. Hub hosts leave it disabled.
    MouseArea {
        objectName: "passiveWidgetShield"
        anchors.fill: parent
        z: 1000
        visible: !host.acceptsInput
        enabled: visible
        acceptedButtons: Qt.AllButtons
        preventStealing: true
        hoverEnabled: true
        cursorShape: Qt.ArrowCursor
    }
}
