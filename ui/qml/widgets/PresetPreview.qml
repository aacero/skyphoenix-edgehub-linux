import QtQuick
import QtQuick.Layouts

// Passive WYSIWYG preview for a curated screen. It uses the same store,
// WidgetPacker, WidgetSizes, WidgetHost, and real widget QML as the Hub. Drivers,
// input, and network access stay disabled while browsing presets.
Rectangle {
    id: preview
    objectName: "presetPreview"

    property var preset: null
    property var widgetCatalog: null
    property bool landscape: preview.width >= preview.height
    property bool showHubBar: true
    property var metrics: ({})
    property var widgetTimeZones: null
    readonly property bool passive: true
    readonly property var tiles: {
        previewStore.structureRevision
        var pages = previewStore.pages()
        return pages.length ? (pages[0].tiles || []) : []
    }
    readonly property var placements: packer.pack(tiles)
    readonly property int previewTileCount: placements.length
    readonly property alias canvasItem: canvas
    readonly property alias titleItem: previewTitle
    readonly property alias purposeItem: previewPurpose
    readonly property alias setupItem: previewSetup

    radius: theme.radiusLg
    color: theme.cardBackground
    border.width: 1
    border.color: theme.cardBorder
    clip: true

    DashboardStore { id: previewStore }
    WidgetPacker { id: packer }
    WidgetSizes { id: sizes }
    NetHub { id: passivePreviewHub; offline: true }

    function titleFor(type) {
        return widgetCatalog ? widgetCatalog.title(type) : type
    }

    function _copy(value) {
        return JSON.parse(JSON.stringify(value || {}))
    }

    function _documentFor(p) {
        if (!p || !p.pages)
            return { version: 1, appearance: {}, settings: {},
                     pages: [ { name: "Preview", tiles: [] } ] }

        var seq = 0
        var pages = []
        var settings = ({})
        for (var pi = 0; pi < p.pages.length; pi++) {
            var sourcePage = p.pages[pi]
            var pageTiles = []
            var sourceTiles = sourcePage.tiles || []
            for (var ti = 0; ti < sourceTiles.length; ti++) {
                var sourceTile = sourceTiles[ti]
                var tileId = sourceTile.type + "-preview-" + (++seq)
                var tile = { id: tileId, type: sourceTile.type }
                if (sourceTile.size) tile.size = sourceTile.size
                pageTiles.push(tile)

                // Seed every default before WidgetHost loads. The preview store
                // therefore never creates settings or schedules a real config save.
                var bucket = widgetCatalog && widgetCatalog.defaults
                           ? widgetCatalog.defaults(sourceTile.type) : ({})
                bucket = preview._copy(bucket)
                var overrides = sourceTile.settings || {}
                for (var key in overrides) bucket[key] = preview._copy(overrides[key])
                settings[tileId] = bucket
            }
            pages.push({ name: sourcePage.name || "Preview", tiles: pageTiles })
        }
        return { version: 1,
                 appearance: preview._copy(p.appearance),
                 settings: settings,
                 pages: pages.length ? pages : [ { name: "Preview", tiles: [] } ] }
    }

    function syncPreset() {
        previewStore.applyExternal(JSON.stringify(preview._documentFor(preview.preset)))
    }

    function widgetSource(type) {
        if (!widgetCatalog || !widgetCatalog.source) return ""
        var source = widgetCatalog.source(type) || ""
        var here = Qt.resolvedUrl(".").toString()
        if (here.indexOf("qrc:/manager") === 0)
            source = source.replace("qrc:/qml/", "qrc:/manager/")
        return source
    }

    onPresetChanged: presetSync.restart()
    onWidgetCatalogChanged: presetSync.restart()
    Component.onCompleted: presetSync.restart()
    Timer {
        id: presetSync
        interval: 0
        repeat: false
        onTriggered: preview.syncPreset()
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: theme.spacingMd
        spacing: theme.spacingMd

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 4
            Text {
                id: previewTitle
                objectName: "presetPreviewTitle"
                Layout.fillWidth: true
                text: preview.preset ? preview.preset.title : "Choose a screen to preview"
                color: theme.textPrimary
                font.pixelSize: theme.fontTitle
                font.bold: true
                font.family: theme.fontDisplay
                wrapMode: Text.WordWrap
            }
            Text {
                id: previewPurpose
                objectName: "presetPreviewPurpose"
                Layout.fillWidth: true
                text: preview.preset
                    ? (preview.preset.purpose || preview.preset.blurb || "")
                    : "Nothing is added until you review the layout and confirm."
                color: theme.textSecondary
                font.pixelSize: theme.fontCaption
                font.family: theme.fontDisplay
                wrapMode: Text.WordWrap
            }
        }

        Rectangle {
            id: canvas
            objectName: "presetPreviewCanvas"
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: 180
            radius: theme.radiusMd
            color: Qt.rgba(0, 0, 0, 0.26)
            border.width: 1
            border.color: theme.cardBorder
            clip: true

            Item {
                id: device
                objectName: "presetPreviewDevice"
                width: preview.landscape ? 2560 : 720
                height: preview.landscape ? 720 : 2560
                anchors.centerIn: parent
                transformOrigin: Item.Center
                scale: Math.max(0.01, Math.min((canvas.width - 20) / width,
                                               (canvas.height - 20) / height))

                Rectangle {
                    id: screen
                    objectName: "presetPreviewScreen"
                    anchors.fill: parent
                    radius: 24
                    clip: true
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: theme.backgroundColor }
                        GradientStop { position: 0.55; color: theme.backgroundColor2 }
                        GradientStop { position: 1.0; color: theme.backgroundColor3 }
                    }

                    readonly property real contentMargin: theme.spacingMd
                    readonly property real barHeight: theme.touchPrimary
                    readonly property real barGap: theme.spacingSm
                    readonly property real barReserve: preview.showHubBar ? barHeight + barGap : 0
                    readonly property real cellShort:
                        (720 - 2 * contentMargin - (preview.landscape ? barReserve : 0))
                        / sizes.shortHalves
                    readonly property real cellLong:
                        (2560 - 2 * contentMargin - (preview.landscape ? 0 : barReserve))
                        / sizes.longHalves

                    BackdropLayer {
                        anchors.fill: parent
                        visible: !!(preview.preset && preview.preset.appearance
                                    && preview.preset.appearance.animatedBg
                                    && theme.decorative)
                        style: preview.preset && preview.preset.appearance
                             ? (preview.preset.appearance.bgStyle || "none") : "none"
                        accent: theme.accent
                        running: false
                    }

                    Rectangle {
                        anchors.fill: parent
                        opacity: theme.decorative ? 0.10 : 0.0
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: theme.accent }
                            GradientStop { position: 0.5; color: "transparent" }
                            GradientStop { position: 1.0; color: theme.accent2 }
                        }
                    }

                    Item {
                        id: grid
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.leftMargin: screen.contentMargin
                        anchors.rightMargin: screen.contentMargin
                        anchors.topMargin: screen.contentMargin
                        anchors.bottom: preview.showHubBar ? hubBar.top : parent.bottom
                        anchors.bottomMargin: preview.showHubBar ? screen.barGap : screen.contentMargin

                        Repeater {
                            model: preview.placements
                            delegate: Item {
                                id: tile
                                required property int index
                                required property var modelData
                                readonly property var box: packer.rect(
                                    modelData, preview.landscape,
                                    screen.cellShort, screen.cellLong, theme.spacingMd)
                                objectName: "presetPreviewTile-" + modelData.type + "-" + index
                                x: box.x
                                y: box.y
                                width: box.width
                                height: box.height

                                Rectangle {
                                    anchors.fill: parent
                                    radius: theme.radiusLg
                                    color: theme.cardFill()
                                    border.width: 1
                                    border.color: theme.cardBorder
                                    visible: widgetHost.status !== Loader.Ready
                                }

                                WidgetHost {
                                    id: widgetHost
                                    objectName: "presetPreviewHost-" + tile.modelData.type + "-" + tile.index
                                    anchors.fill: parent
                                    widgetId: tile.modelData.id
                                    widgetType: tile.modelData.type
                                    widgetSource: preview.widgetSource(tile.modelData.type)
                                    store: previewStore
                                    catalog: preview.widgetCatalog
                                    metrics: preview.metrics
                                    netHub: passivePreviewHub
                                    timeZones: preview.widgetTimeZones
                                    tick: 0
                                    expanded: false
                                    sizeClass: sizes.classFor(tile.modelData.size, preview.landscape)
                                    driverActive: false
                                    acceptsInput: false
                                }
                            }
                        }
                    }

                    Rectangle {
                        id: hubBar
                        objectName: "presetPreviewHubBar"
                        visible: preview.showHubBar
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.leftMargin: screen.contentMargin
                        anchors.rightMargin: screen.contentMargin
                        anchors.bottomMargin: screen.contentMargin
                        height: screen.barHeight
                        radius: height / 2
                        color: Qt.rgba(theme.cardBackground.r, theme.cardBackground.g,
                                       theme.cardBackground.b, 0.92)
                        border.width: 1
                        border.color: theme.cardBorder

                        Row {
                            anchors.centerIn: parent
                            spacing: theme.spacingLg
                            Repeater {
                                model: [ "Screens", "Appearance", "Edit", "Settings" ]
                                Text {
                                    text: modelData
                                    color: theme.textSecondary
                                    font.pixelSize: theme.fontLabel
                                    font.family: theme.fontDisplay
                                }
                            }
                        }
                    }
                }
            }

            Text {
                anchors.centerIn: parent
                visible: preview.preset && preview.tiles.length === 0
                text: "Blank screen\nAdd exactly what you need"
                color: theme.textSecondary
                font.pixelSize: theme.fontLabel
                font.family: theme.fontDisplay
                horizontalAlignment: Text.AlignHCenter
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            visible: preview.preset !== null
            spacing: 4
            Text {
                Layout.fillWidth: true
                text: "On this screen: " + preview.tiles.map(function (tile) {
                    return preview.titleFor(tile.type)
                }).join("  •  ")
                color: theme.textPrimary
                font.pixelSize: theme.fontCaption
                font.family: theme.fontDisplay
                wrapMode: Text.WordWrap
            }
            Text {
                id: previewSetup
                objectName: "presetPreviewSetup"
                Layout.fillWidth: true
                text: preview.preset ? (preview.preset.setup || "Ready immediately.") : ""
                color: theme.textSecondary
                font.pixelSize: theme.fontCaption
                font.family: theme.fontDisplay
                wrapMode: Text.WordWrap
            }
        }
    }
}
