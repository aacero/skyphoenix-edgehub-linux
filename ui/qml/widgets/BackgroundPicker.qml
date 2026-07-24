import QtQuick
import QtQuick.Layouts

// BackgroundPicker - ONE control for choosing a background, so the scattered
// "animated style" / "wallpaper" / "set as wallpaper" options collapse into a
// single, obvious, mutually-exclusive choice. Works for the GLOBAL default
// (pageIndex < 0) or a PER-PAGE override (pageIndex >= 0), which makes the
// precedence explicit ("Use global" vs a specific pick for this page).
//
// Required: st, col (tokens: textPrimary/textSecondary/panel/panelAlt/border/
// accent/radius), bgCatalog (BackgroundCatalog), wpCatalog (WallpaperCatalog).
// Optional: uploadedImages = [{ label, source }] to include the user's images.
Item {
    id: bp
    // Named `st`, NOT `store`: a call site binding `store: store` from an
    // enclosing scope resolves the RHS to this component's OWN property (the QML
    // self-binding trap), leaving it undefined - every write then threw
    // "Cannot call method 'setAppearance' of undefined" and the picker silently
    // did nothing. That is exactly what happened in the hub's SettingsPanel, so
    // the on-panel Background picker could not change the background at all.
    // WidgetConfigPanel/ConfigField already use `st` for this reason.
    property var st
    property int pageIndex: -1          // <0 = global default; >=0 = that page
    property var col
    property var bgCatalog
    property var wpCatalog
    property var uploadedImages: []
    readonly property real controlHeight: col && col.ctlH ? col.ctlH : 52
    readonly property real fontBase: col && col.fontBase ? col.fontBase : 16

    // Hover-preview hooks for animated styles (the host - e.g. the Manager - wires
    // these to a live preview without committing). Unconnected in the hub, which is
    // harmless.
    signal previewStyle(string v)
    signal previewEnded()

    implicitHeight: col2.implicitHeight

    // Text legible on an accent fill - prefer a theme token so a dark accent can't
    // make the selected chip's label vanish; fall back to the historic literal.
    function onAccent() { return (col && col.textOnAccent) ? col.textOnAccent : "#0D1117" }

    // ── Current selection (reactive on st.revision) ──
    // Returns { kind: "global"|"style"|"wallpaper", val }.
    function current() {
        if (!st) return { kind: "global" }      // before the store is wired in
        st.revision
        if (pageIndex < 0) {
            var a = st.appearance() || ({})
            if (a.wallpaper) return { kind: "wallpaper", val: a.wallpaper }
            return { kind: "style", val: a.bgStyle || "orbs" }
        }
        var p = st.pageBackground(pageIndex) || ({})
        if (p.wallpaper) return { kind: "wallpaper", val: p.wallpaper }
        if (p.style) return { kind: "style", val: p.style }
        return { kind: "global" }
    }
    function selStyle(v) { var c = current(); return c.kind === "style" && c.val === v }
    function selWall(s) { var c = current(); return c.kind === "wallpaper" && c.val === s }
    function selGlobal() { return current().kind === "global" }

    // ── Mutually-exclusive writes ──
    function pickStyle(v) {
        if (pageIndex < 0) { st.setAppearance("bgStyle", v); st.setAppearance("wallpaper", "") }
        else { st.setPageBackground(pageIndex, "style", v); st.setPageBackground(pageIndex, "wallpaper", "") }
    }
    function pickWallpaper(src) {
        if (pageIndex < 0) st.setAppearance("wallpaper", src)
        else st.setPageBackground(pageIndex, "wallpaper", src)
    }
    function useGlobal() {   // pages only: drop the override
        st.setPageBackground(pageIndex, "style", "")
        st.setPageBackground(pageIndex, "wallpaper", "")
    }

    ColumnLayout {
        id: col2
        width: bp.width
        spacing: 10

        // Animated styles (+ "Use global" for pages).
        Flow {
            Layout.fillWidth: true; spacing: 8
            // "Use global" - only meaningful for a page override.
            Rectangle {
                id: globalChip
                visible: bp.pageIndex >= 0
                width: gLbl.implicitWidth + 28; height: bp.controlHeight; radius: bp.col.radius
                property bool sel: bp.selGlobal()
                color: sel ? bp.col.accent : bp.col.panelAlt
                border.width: sel ? 2 : 1; border.color: sel ? bp.col.accent : bp.col.border
                // Reference the chip's `sel` via its id - this Rectangle is NOT a
                // delegate/component root, so a bare `sel` in the child Text doesn't
                // resolve (it threw "sel is not defined").
                Text { id: gLbl; anchors.centerIn: parent; text: "Use global"
                    color: globalChip.sel ? bp.onAccent() : bp.col.textPrimary; font.pixelSize: bp.fontBase }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: bp.useGlobal() }
            }
            Repeater {
                model: bp.bgCatalog ? bp.bgCatalog.styles : []
                delegate: Rectangle {
                    required property var modelData
                    width: sLbl.implicitWidth + 28; height: bp.controlHeight; radius: bp.col.radius
                    property bool sel: bp.selStyle(modelData.v)
                    color: sel ? bp.col.accent : bp.col.panelAlt
                    border.width: sel ? 2 : 1; border.color: sel ? bp.col.accent : bp.col.border
                    Text { id: sLbl; anchors.centerIn: parent; text: modelData.l
                        color: sel ? bp.onAccent() : bp.col.textPrimary; font.pixelSize: bp.fontBase }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        hoverEnabled: true
                        onContainsMouseChanged: containsMouse ? bp.previewStyle(modelData.v) : bp.previewEnded()
                        onClicked: { bp.pickStyle(modelData.v); bp.previewEnded() } }
                }
            }
        }

        Text { text: "…or a wallpaper (replaces the animation):"; color: bp.col.textSecondary
            font.pixelSize: bp.fontBase; wrapMode: Text.WordWrap; Layout.fillWidth: true }

        // Wallpaper thumbnails: bundled + the user's uploaded images.
        Flow {
            Layout.fillWidth: true; spacing: 8
            Repeater {
                model: (bp.wpCatalog ? bp.wpCatalog.items : []).concat(bp.uploadedImages)
                delegate: Rectangle {
                    required property var modelData
                    width: 88; height: 116; radius: bp.col.radius; clip: true
                    property bool sel: bp.selWall(modelData.source)
                    color: bp.col.panel; border.width: sel ? 3 : 1
                    border.color: sel ? bp.col.accent : bp.col.border
                    Image { anchors.fill: parent; anchors.margins: 2; source: modelData.source
                        fillMode: Image.PreserveAspectCrop; asynchronous: true }
                    Rectangle { anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.right: parent.right
                        height: 30; color: Qt.rgba(0, 0, 0, 0.62)
                        Text { anchors.centerIn: parent; text: modelData.label
                            color: "#fff"; font.pixelSize: Math.max(15, bp.fontBase - 1)
                            elide: Text.ElideRight; width: parent.width - 8
                            horizontalAlignment: Text.AlignHCenter } }
                    // Selected state as a check BADGE (real icon), matching the app's
                    // icon set instead of a "✓" text glyph in the label.
                    Rectangle {
                        objectName: "wallpaperCheckBadge"
                        visible: parent.sel
                        anchors.top: parent.top; anchors.right: parent.right; anchors.margins: 4
                        width: 26; height: 26; radius: 13; color: bp.col.accent
                        AppIcon { anchors.centerIn: parent; name: "ui-check"; size: 16; color: "#FFFFFF" }
                    }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        onClicked: bp.pickWallpaper(modelData.source) }
                }
            }
        }
    }
}
