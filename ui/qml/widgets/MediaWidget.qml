pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts

// Now Playing - real MPRIS control via the `media` bridge (Spotify, YouTube
// Music in a browser, any MPRIS player). Shows a genuine "nothing playing"
// state rather than fabricated data.
//
// Sizing (W1 wave 3): layout keys off the injected `sizeClass`. The old tile was
// ONE 46px-thumbnail row for every size - a 696x819 box rendered a 46px cover
// and 13px type. The content set now follows the room:
//   • 0.5x0.5 (micro) - headerless: art, the title, and ONE play target. The
//     half-cell (423x306 landscape) cannot hold prev/next + a progress bar and
//     still leave a real hit area, so it carries the readout and hands the rest
//     to the overlay rather than shrinking a button.
//   • 1x1 (baseline)  - art + title/artist + progress + the full transport.
//   • wide            - a genuinely HORIZONTAL variant: art BESIDE the
//     metadata + transport. The vertical stack (art + title + bar + transport)
//     is ~420px of content and the wide projections are 409px (1x0.5 portrait)
//     and 306px (0.5x1 landscape) tall - it simply does not fit.
//   • tall            - the vertical stack, with the art taking the height.
//   • full (overlay)  - unchanged shape (album line, centred type, big
//     transport); its art is size-derived now too.
WidgetChrome {
    id: w
    property var metrics: ({})
    property bool expanded: false
    property bool active: true
    property var store: null
    property string instanceId: ""
    readonly property var cfg: {
        var revision = store ? store.revision : 0
        return (store && instanceId)
            ? JSON.parse(JSON.stringify(store.settingsFor(instanceId))) : ({})
    }
    readonly property string preferredPlayer: cfg.preferredPlayer !== undefined
                                                ? String(cfg.preferredPlayer).trim() : ""
    // QML Image performs its own network request, outside NetHub. Until album
    // art is fetched and cached by the Hub's gated transport, accept only
    // already-local image sources. Remote artwork falls back to the deterministic
    // music glyph instead of creating an unaudited connection.
    function localArtworkSource(raw) {
        var u = ("" + (raw || "")).trim()
        if (!u.length) return ""
        if (/^(file|qrc):/i.test(u)) return u
        if (/^data:image\/(png|jpeg|jpg|webp|gif);base64,/i.test(u)) return u
        if (!/^[a-z][a-z0-9+.-]*:/i.test(u) && u.indexOf("//") !== 0) return u
        return ""
    }
    readonly property string artworkSource: w.avail
        ? w.localArtworkSource(media.artUrl) : ""
    readonly property bool remoteArtworkBlocked: w.avail && !!media.artUrl
                                                  && !w.artworkSource.length
    readonly property string artworkNotice: !w.avail || !media.artUrl ? ""
        : w.remoteArtworkBlocked ? "Artwork blocked by network policy"
        : !w.artworkSource.length ? "Artwork unavailable" : ""

    // accentColor MUST be a concrete colour: effAccent falls back to accentColor
    // (WidgetChrome), so `accentColor: effAccent` was a binding loop → the play
    // glyph/art rendered black. Content still uses w.effAccent (resolves the
    // per-widget accent preset, else this base).
    title: "Now Playing"; iconName: "media"; accentColor: theme.catEntertainment
    showHeader: !micro

    property bool avail: (typeof media !== "undefined") && media && media.available
    readonly property bool canPlayPause: w.avail && media.canPlayPause
    readonly property bool canGoNext: w.avail && media.canGoNext
    readonly property bool canGoPrevious: w.avail && media.canGoPrevious
    readonly property bool canSeek: w.avail && media.canSeek && w.durationMs > 0
    readonly property real durationMs: w.avail ? Math.max(0, Number(media.durationMs || 0)) : 0
    readonly property real positionMs: w.avail ? Math.max(0, Number(media.positionMs || 0)) : 0
    readonly property real progressFraction: w.durationMs > 0
        ? Math.max(0, Math.min(1, w.positionMs / w.durationMs))
        : Math.max(0, Math.min(1, w.avail ? Number(media.position || 0) : 0))
    readonly property string emptyStateLabel:
        (typeof media === "undefined" || !media) ? "Media service unavailable"
        : !media.busConnected ? "Media service disconnected"
        : media.scanning ? "Looking for media players"
        : media.availablePlayers && media.availablePlayers.length
            ? "No track loaded" : "No media player found"
    readonly property string playbackLabel: !w.avail ? w.emptyStateLabel
        : media.status === "Playing" ? "Playing"
        : media.status === "Paused" ? "Paused" : "Stopped"
    readonly property string fullStatus: w.avail
        ? media.playerName + " · " + w.playbackLabel : w.emptyStateLabel
    // The player state is already represented by the transport and empty-state
    // body. On narrow cards, repeating it in the header steals enough width to
    // truncate both strings. Keep the complete status on roomy cards and in the
    // overlay, and expose it to assistive technology at every size.
    readonly property bool showHeaderStatus: w.expanded
                                             || w.width >= Math.max(560,
                                                                    theme.fontMinimum * 30)
    status: w.showHeaderStatus ? w.fullStatus : ""
    readonly property string accessibleTrackSummary: w.avail
        ? "Now Playing, " + media.title
          + (media.artist ? ", by " + media.artist : "")
          + (media.album ? ", from " + media.album : "")
          + ". " + w.fullStatus
        : "Now Playing. " + w.emptyStateLabel
    Accessible.name: w.accessibleTrackSummary
    Accessible.description: w.avail
        ? "Playback controls and seek position for the current track"
        : "No active media is available"

    function formatTime(ms) {
        var seconds = Math.max(0, Math.floor(Number(ms || 0) / 1000))
        var hours = Math.floor(seconds / 3600)
        var minutes = Math.floor((seconds % 3600) / 60)
        var remaining = seconds % 60
        if (hours > 0)
            return hours + ":" + (minutes < 10 ? "0" : "") + minutes
                    + ":" + (remaining < 10 ? "0" : "") + remaining
        return minutes + ":" + (remaining < 10 ? "0" : "") + remaining
    }
    function seekTo(fraction) {
        if (w.canSeek)
            media.seekFraction(Math.max(0, Math.min(1, fraction)))
    }
    function syncPreferredPlayer() {
        if (typeof media !== "undefined" && media && media.setPreferredPlayer)
            media.setPreferredPlayer(w.preferredPlayer)
    }
    onPreferredPlayerChanged: syncPreferredPlayer()
    Component.onCompleted: syncPreferredPlayer()

    // ── Per-size layout (sizeClass injected by Dashboard) ────────────────────
    readonly property bool horiz: sizeClass === "wide"
    // A micro tile projected onto a landscape panel is too short for a useful
    // vertical stack once the user's type scale is applied. Reflow it beside
    // the artwork, just like a wide tile, while retaining the single primary
    // transport action appropriate to the micro size.
    readonly property bool microLandscape: w.micro && w.width > w.height
    readonly property bool sideBySide: w.horiz || w.microLandscape
    readonly property bool tallish: sizeClass === "tall" || sizeClass === "large"
    // Everything past "art + title + play" is gated on having more than a
    // half-cell. `micro` is chrome's half-cell footprint - not re-derived here.
    readonly property bool rich: !micro

    // The album art is a square DERIVED FROM THE BOX. It used to be
    // min(width*0.5, 260), a portrait-shaped assumption: in the 846x306
    // landscape projection of 0.5x1 that is a 260px square under a title under a
    // 52px transport row - ~420px of content in a 306px box.
    readonly property real tileContentWidth: Math.max(
        80, w.width - 2 * w.contentMargins)
    readonly property real tileContentHeight: Math.max(
        80, w.height - 2 * w.contentMargins
            - (w.showHeader ? w.headerHeight
                              + (w.big ? theme.spacingSm : theme.spacingXs) : 0))
    readonly property real artSize: {
        if (w.sideBySide) {
            // Side-by-side: bounded by the height, and capped at ~2/5 of the
            // width so the metadata keeps the majority. At larger type scales,
            // yield decorative artwork width to readable metadata first.
            var widthShare = w.microLandscape
                ? Math.max(0.34, 0.42 - (theme.textScaleEff - 1) * 0.18)
                : 0.42
            return Math.max(40, Math.min(
                w.tileContentHeight * (w.microLandscape ? 0.78 : 0.92),
                w.tileContentWidth * widthShare))
        }
        // Stacked: the art may take a chunk of the height, never so much that
        // the transport row is pushed out of the box. A micro tile similarly
        // yields decorative height when the user requests larger text.
        var narrowRichStack = w.rich && w.tileContentWidth < 400
        var heightShare = w.micro
            ? Math.max(0.38, 0.48 - (theme.textScaleEff - 1) * 0.20)
            : narrowRichStack
                ? Math.max(0.24, 0.42 - (theme.textScaleEff - 1) * 0.40)
                : 0.48
        return Math.max(40, Math.min(w.tileContentWidth * 0.72,
                                     w.tileContentHeight * heightShare,
                                     w.expanded ? 420 : 100000))
    }
    // The width the metadata actually gets - what its type is sized against.
    readonly property real infoW: w.sideBySide
        ? Math.max(80, w.tileContentWidth - w.artSize - theme.spacingMd)
        : w.tileContentWidth
    // Type scales with the box and clamps. The horizontal projections are short,
    // so their height budget is a bigger share of a smaller number.
    readonly property real titlePx: Math.max(
        theme.fontTitle,
        Math.min(w.infoW * 0.075,
                 w.tileContentHeight * (w.sideBySide ? 0.10 : 0.06),
                 Math.max(28, theme.fontTitle + 4)))
    readonly property real artistPx: Math.max(
        theme.fontLabel, Math.round(w.titlePx * 0.72))
    // Tile transport: play is the primary target, prev/next the secondary ones.
    readonly property real playSize: w.micro ? theme.touchTertiary : theme.touchSecondary

    // Nothing-playing placeholder (accurate state, not fake content). This is
    // what a media tile shows most of the day, so it scales with the box like
    // any other content instead of floating a 34px glyph in a 819px tile.
    ColumnLayout {
        anchors.centerIn: parent
        width: Math.max(60, w.width - 2 * theme.spacingMd)
        visible: !w.avail
        spacing: theme.spacingXs
        AppIcon {
            Layout.alignment: Qt.AlignHCenter
            name: "media"
            color: theme.textSecondary
            opacity: 0.65
            size: Math.max(32, Math.min(w.width * 0.18, w.height * 0.18,
                                        w.expanded ? 96 : 72))
        }
        Text {
            objectName: "mediaEmptyState"
            Layout.alignment: Qt.AlignHCenter
            text: w.emptyStateLabel
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            color: theme.textSecondary
            font.pixelSize: theme.fontLabel
            Accessible.name: w.emptyStateLabel
        }
    }

    component MediaProgress: Item {
        id: progress
        property bool showLabels: true
        objectName: "mediaProgress"
        implicitHeight: progress.showLabels
            ? Math.max(theme.touchTertiary, theme.fontLabel + 34) : 48
        activeFocusOnTab: w.canSeek
        Accessible.role: Accessible.Slider
        Accessible.name: "Playback position, " + Math.round(w.progressFraction * 100) + " percent"
        Accessible.description: w.canSeek
            ? "Seek through the current track" : "The current player does not support seeking"
        Accessible.onIncreaseAction: w.seekTo(w.progressFraction + 0.05)
        Accessible.onDecreaseAction: w.seekTo(w.progressFraction - 0.05)
        Keys.onLeftPressed: w.seekTo(w.progressFraction - 0.05)
        Keys.onRightPressed: w.seekTo(w.progressFraction + 0.05)
        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Home) {
                w.seekTo(0)
                event.accepted = true
            } else if (event.key === Qt.Key_End) {
                w.seekTo(1)
                event.accepted = true
            }
        }

        Rectangle {
            id: track
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: progress.showLabels ? -8 : 0
            height: 8
            radius: 4
            color: theme.cardBorder
            Rectangle {
                height: parent.height
                radius: parent.radius
                color: w.effAccent
                width: parent.width * w.progressFraction
                Behavior on width {
                    NumberAnimation { duration: theme.motionValue; easing.type: Easing.OutCubic }
                }
            }
        }
        Text {
            objectName: "mediaElapsed"
            visible: progress.showLabels
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            text: w.formatTime(w.positionMs)
            color: theme.textSecondary
            font.pixelSize: theme.fontLabel
        }
        Text {
            objectName: "mediaDuration"
            visible: progress.showLabels
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            text: w.durationMs > 0 ? w.formatTime(w.durationMs) : "Live"
            color: theme.textSecondary
            font.pixelSize: theme.fontLabel
        }
        MouseArea {
            anchors.fill: parent
            enabled: w.canSeek
            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onPressed: function(mouse) {
                progress.forceActiveFocus()
                w.seekTo(mouse.x / Math.max(1, width))
            }
        }
    }

    component TransportButton: Rectangle {
        id: control
        property string icon: ""
        property string accessibleName: ""
        property bool primary: false
        signal triggered()
        activeFocusOnTab: enabled
        implicitWidth: primary ? theme.touchPrimary : theme.touchSecondary
        implicitHeight: implicitWidth
        radius: width / 2
        color: primary ? w.effAccent
                       : Qt.rgba(w.effAccent.r, w.effAccent.g, w.effAccent.b,
                                 controlMouse.pressed ? 0.30 : 0.14)
        border.width: primary ? 0 : 1
        border.color: Qt.rgba(w.effAccent.r, w.effAccent.g, w.effAccent.b, 0.5)
        opacity: enabled ? 1.0 : 0.35
        scale: controlMouse.pressed ? 0.95 : 1.0
        Behavior on scale { NumberAnimation { duration: theme.motionFast } }
        Accessible.role: Accessible.Button
        Accessible.name: accessibleName
        Accessible.description: enabled ? "" : accessibleName + " is not supported by this player"
        Accessible.onPressAction: if (control.enabled) control.triggered()
        Keys.onSpacePressed: if (control.enabled) control.triggered()
        Keys.onEnterPressed: if (control.enabled) control.triggered()
        Keys.onReturnPressed: if (control.enabled) control.triggered()
        AppIcon {
            anchors.centerIn: parent
            name: control.icon
            size: Math.round(control.width * (control.primary ? 0.42 : 0.40))
            color: control.primary ? "#0D1117" : theme.textPrimary
        }
        MouseArea {
            id: controlMouse
            anchors.fill: parent
            enabled: control.enabled
            onClicked: {
                control.forceActiveFocus()
                control.triggered()
            }
        }
    }

    // ── Tile (every non-overlay size) ────────────────────────────────────────
    GridLayout {
        anchors.fill: parent
        visible: w.avail && !w.expanded
        // Wide reflows the SAME children into two columns: art beside the
        // metadata, which is the only shape that fits a 306px-tall box.
        columns: w.sideBySide ? 2 : 1
        rowSpacing: theme.spacingSm
        columnSpacing: theme.spacingMd

        // Stacked: split the slack above/below so the block sits centred rather
        // than jammed against the top edge. Invisible items are skipped by
        // GridLayout, so these never consume a cell in the 2-column arrangement.
        Item { Layout.fillWidth: true; Layout.fillHeight: true; visible: !w.sideBySide }

        Rectangle {
            id: artTile
            objectName: "mediaArtwork"
            Layout.alignment: Qt.AlignCenter
            Layout.preferredWidth: Math.round(w.artSize)
            Layout.preferredHeight: Math.round(w.artSize)
            radius: theme.radiusMd; clip: true
            gradient: Gradient { GradientStop { position: 0; color: w.effAccent } GradientStop { position: 1; color: Qt.darker(w.effAccent, 1.5) } }
            Image { id: artC; anchors.fill: parent; source: w.artworkSource
                fillMode: Image.PreserveAspectCrop; asynchronous: true; cache: false
                visible: status === Image.Ready }
            // The fallback glyph is the art at this size - scale it with the box.
            Text { anchors.centerIn: parent; text: "♪"; color: "#fff"
                font.pixelSize: Math.max(14, w.artSize * 0.42)
                visible: artC.status !== Image.Ready }
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: w.sideBySide
            // Released explicitly: a nested Layout inherits an implicit
            // maximumWidth from a child that sets Layout.alignment (the transport
            // row), which would cap this column at the transport's own width and
            // strand the metadata against the art.
            Layout.maximumWidth: Number.POSITIVE_INFINITY
            spacing: theme.spacingXs

            // Centre the metadata against the art when side-by-side.
            Item { Layout.fillHeight: true; visible: w.sideBySide }

            Text {
                objectName: "mediaTrackTitle"
                text: w.avail ? media.title : ""
                color: theme.textPrimary
                font.pixelSize: w.titlePx
                font.bold: true
                horizontalAlignment: w.sideBySide ? Text.AlignLeft : Text.AlignHCenter
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
                Layout.preferredHeight: implicitHeight
                Accessible.name: w.avail ? media.title : ""
                Accessible.description: w.avail
                    ? (media.artist ? "Track by " + media.artist : "Current track")
                    : ""
            }
            Text {
                objectName: "mediaTrackArtist"
                visible: w.rich
                text: w.avail ? media.artist : ""
                color: theme.textSecondary
                font.pixelSize: w.artistPx
                horizontalAlignment: w.sideBySide ? Text.AlignLeft : Text.AlignHCenter
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
                Layout.preferredHeight: implicitHeight
                Accessible.name: w.avail ? media.artist : ""
            }

            // Progress - the half-cell has no room for it.
            MediaProgress {
                visible: w.rich
                Layout.fillWidth: true; Layout.topMargin: theme.spacingXs
                Layout.preferredHeight: implicitHeight
                showLabels: true
            }
            Text {
                objectName: "mediaArtworkNotice"
                visible: w.rich && w.artworkNotice.length > 0
                Layout.fillWidth: true
                text: w.artworkNotice
                color: theme.textSecondary
                font.pixelSize: theme.fontMinimum
                wrapMode: Text.WordWrap
            }

            // Transport. Micro keeps ONLY play - at a full-size hit area.
            RowLayout {
                Layout.alignment: w.sideBySide ? Qt.AlignLeft : Qt.AlignHCenter
                Layout.topMargin: theme.spacingXs
                spacing: theme.spacingMd
                TransportButton {
                    objectName: "mediaPrevious"
                    visible: w.rich
                    enabled: w.canGoPrevious
                    Layout.preferredWidth: theme.touchTertiary; Layout.preferredHeight: theme.touchTertiary
                    icon: "ui-skip-back"; accessibleName: "Previous track"
                    onTriggered: media.previous()
                }
                TransportButton {
                    objectName: "mediaPlayPause"
                    enabled: w.canPlayPause
                    Layout.preferredWidth: w.playSize; Layout.preferredHeight: w.playSize
                    primary: true
                    icon: (w.avail && media.playing) ? "ui-pause" : "ui-play"
                    accessibleName: (w.avail && media.playing) ? "Pause" : "Play"
                    onTriggered: media.playPause()
                }
                TransportButton {
                    objectName: "mediaNext"
                    visible: w.rich
                    enabled: w.canGoNext
                    Layout.preferredWidth: theme.touchTertiary; Layout.preferredHeight: theme.touchTertiary
                    icon: "ui-skip-fwd"; accessibleName: "Next track"
                    onTriggered: media.next()
                }
            }

            Item { Layout.fillHeight: true; visible: w.sideBySide }
        }

        Item { Layout.fillWidth: true; Layout.fillHeight: true; visible: !w.sideBySide }
    }

    // Expanded
    ColumnLayout {
        anchors.fill: parent; anchors.margins: theme.spacingLg
        visible: w.avail && w.expanded; spacing: theme.spacingMd
        Item { Layout.fillHeight: true }
        Rectangle {
            Layout.alignment: Qt.AlignHCenter
            // Size-derived like the tile's, rather than a flat 260px cap that
            // ignored the box (the overlay is a whole 2560x720 / 720x2560 panel).
            Layout.preferredWidth: Math.round(w.artSize); Layout.preferredHeight: Math.round(w.artSize)
            radius: theme.radiusLg; clip: true
            gradient: Gradient { GradientStop { position: 0; color: w.effAccent } GradientStop { position: 1; color: Qt.darker(w.effAccent, 1.5) } }
            Image { id: artE; anchors.fill: parent; source: w.artworkSource
                fillMode: Image.PreserveAspectCrop; asynchronous: true; cache: false
                visible: status === Image.Ready }
            Text { anchors.centerIn: parent; text: "♪"; color: "#fff"
                font.pixelSize: Math.max(14, w.artSize * 0.42)
                visible: artE.status !== Image.Ready }
        }
        ColumnLayout {
            Layout.fillWidth: true; spacing: 2
            Text {
                objectName: "mediaExpandedTitle"
                Layout.fillWidth: true
                Layout.preferredHeight: implicitHeight
                horizontalAlignment: Text.AlignHCenter
                text: w.avail ? media.title : ""
                font.pixelSize: Math.max(26, theme.fontTitle + 4)
                font.bold: true
                color: theme.textPrimary
                wrapMode: Text.WordWrap
                maximumLineCount: 3
                elide: Text.ElideRight
                Accessible.name: w.avail ? media.title : ""
            }
            Text {
                objectName: "mediaExpandedByline"
                Layout.fillWidth: true
                Layout.preferredHeight: implicitHeight
                horizontalAlignment: Text.AlignHCenter
                // Join artist + album with a middot, but omit the separator (and any
                // stray leading " · ") when either side is empty (podcasts/streams).
                text: w.avail
                    ? (media.artist
                        ? (media.artist + (media.album ? "  ·  " + media.album : ""))
                        : (media.album || ""))
                    : ""
                font.pixelSize: theme.fontLabel
                color: theme.textSecondary
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                elide: Text.ElideRight
                Accessible.name: text
            }
        }
        MediaProgress {
            Layout.fillWidth: true
            Layout.preferredHeight: implicitHeight
            showLabels: true
        }
        Text {
            objectName: "mediaArtworkNoticeExpanded"
            visible: w.artworkNotice.length > 0
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            text: w.artworkNotice
            color: theme.textSecondary
            font.pixelSize: theme.fontMinimum
            wrapMode: Text.WordWrap
        }
        RowLayout {
            Layout.alignment: Qt.AlignHCenter; spacing: theme.spacingXl
            TransportButton {
                objectName: "mediaPreviousExpanded"
                enabled: w.canGoPrevious
                Layout.preferredWidth: theme.touchSecondary; Layout.preferredHeight: theme.touchSecondary
                icon: "ui-skip-back"; accessibleName: "Previous track"
                onTriggered: media.previous()
            }
            TransportButton {
                objectName: "mediaPlayPauseExpanded"
                enabled: w.canPlayPause
                Layout.preferredWidth: theme.touchPrimary; Layout.preferredHeight: theme.touchPrimary
                primary: true
                icon: (w.avail && media.playing) ? "ui-pause" : "ui-play"
                accessibleName: (w.avail && media.playing) ? "Pause" : "Play"
                onTriggered: media.playPause()
            }
            TransportButton {
                objectName: "mediaNextExpanded"
                enabled: w.canGoNext
                Layout.preferredWidth: theme.touchSecondary; Layout.preferredHeight: theme.touchSecondary
                icon: "ui-skip-fwd"; accessibleName: "Next track"
                onTriggered: media.next()
            }
        }
        Item { Layout.fillHeight: true }
    }
}
