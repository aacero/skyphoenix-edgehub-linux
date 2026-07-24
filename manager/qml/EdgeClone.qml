import QtQuick

// EdgeClone - a live WYSIWYG "clone" of the Xeneon Edge. Renders the REAL widgets
// of the current page in a device frame, placed by the SAME WidgetPacker the hub
// uses, so the clone is one layout viewed twice rather than a second opinion.
// Interactions:
//   • drag a tile onto another  → reorder (commit on drop)
//   • drag the corner handle    → resize, snapping to the nearest size the widget
//                                 type actually supports
//   • ⚙ configure   ✕ remove
// All edits go through the shared store → persist + push live to a running hub.
// Resolves store/catalog/theme/media/backend from the Manager scope.
Item {
    id: clone
    property int pageIndex: 0
    // false = pure live preview (Appearance tab): the same WYSIWYG render with
    // every edit affordance (drag, resize, ⚙, ✕) hidden, so "what does this
    // setting change?" can be answered next to the setting without also
    // offering a second, competing place to edit the layout.
    property bool editable: true
    signal configRequested(string tileId, string tileType)

    // Explicit references avoid relying on dynamic id lookup inside the shared
    // WidgetHost component.
    property var widgetStore: store
    property var widgetCatalog: catalog
    readonly property var widgetTimeZones: (typeof timeZones !== "undefined") ? timeZones : null

    // Manager previews never perform widget egress. The Hub is the sole active
    // driver and pushes persisted state back through the shared store.
    NetHub { id: passivePreviewHub; offline: true }

    WidgetSizes { id: sizes }
    WidgetPacker { id: packer }

    // Structural list → key on structureRevision, NOT revision, so a settings
    // keystroke (title/accent/…) doesn't rebuild every tile Loader (flicker/reload).
    property var tiles: {
        store.structureRevision
        var p = store.pages()[pageIndex]
        return p ? (p.tiles || []) : []
    }
    // The page's placement, in semantic space - the hub's own packing, byte for byte
    // (same packer, same input, no orientation), which is what makes this a clone.
    property var placements: {
        store.structureRevision
        return packer.pack(clone.tiles)
    }
    // Orientation of the clone, mirroring what the Edge actually shows:
    //   • a FIXED orientation mode (portrait/landscape/…) → use it directly;
    //   • AUTO → follow the panel's live rotation, pulled from the hub over the
    //     control socket (backend.hubRotation) so turning the panel refreshes the
    //     preview. Unknown/offline (-1) stays portrait, which is also what the
    //     offscreen tests (no backend) see, so the semantic packing is unchanged there.
    readonly property bool landscape: {
        store.revision   // re-evaluate when the orientation mode changes
        var mode = (typeof store !== "undefined" && store && store.appearance)
                   ? (store.appearance().orientation || "auto") : "auto"
        if (mode === "landscape" || mode === "inverted-landscape") return true
        if (mode === "portrait" || mode === "inverted-portrait") return false
        var r = (typeof backend !== "undefined" && backend && backend.hubRotation !== undefined)
                ? backend.hubRotation : -1
        return r === 90 || r === 270
    }
    // The Manager must preview the same usable widget area as the Hub. Standard
    // mode reserves the Hub's bottom controls; Immersive mode gives that space
    // back to the widgets. Missing values stay compatible with existing configs.
    readonly property bool showHubBar: {
        store.revision
        var a = (typeof store !== "undefined" && store && store.appearance)
                ? (store.appearance() || ({})) : ({})
        return (a.hubControlsMode || "standard") !== "immersive"
    }
    // How long the device drawn here must be, in half-cells: a full screen (6), or
    // the page if it is longer. An over-long page is shown WHOLE - a taller device
    // scaled down - rather than clipped: the Manager is where you see that a page
    // runs past the screen, so hiding it here would defeat the tool.
    property int longExtent: Math.max(sizes.longHalves, packer.longExtent(clone.placements))

    // ── The tile Repeater's model ────────────────────────────────────────────
    // `placements` is a fresh JS array every time it re-packs, and a Repeater handed
    // a new array resets its whole delegate model: every tile was destroyed and
    // rebuilt for a single reorder, so there was nothing left alive to animate and
    // the replacement was simply already at the destination. That is the teleport.
    //
    // This ListModel is SYNCED to `placements` by id instead: a tile that still
    // exists keeps its row, so it keeps its delegate, so it keeps its loaded widget
    // - and its new slot arrives as a property change it can EASE to (see animS/animL
    // on the cell). Dragging a tile is exactly where a teleport reads worst, which is
    // why the clone needs this at least as much as the hub does.
    //
    // Row order carries no meaning: a cell is positioned absolutely from its own
    // (s, l) and the packer never overlaps two tiles, so rows are patched in place
    // rather than moved - the minimum churn that still expresses the edit. Nothing
    // downstream may assume row order IS tile order; see `targetAt`.
    //
    // The model is also where a tile's LIFETIME lives, which is what lets a removed
    // tile fade instead of blinking out: `dying` keeps the row - and therefore the
    // delegate - alive past the packing that dropped it, and `entering` marks a row
    // the page grew after it was seeded. Both are properties of the ROW (a removed
    // tile is exactly "a row that is no longer in the packing"), so neither is a mode
    // flag that can drift out of sync with what is on screen.
    ListModel { id: placementModel }

    // Which page the model currently holds rows FOR - null until the first sync.
    //
    // This is the clone's own problem, and the reason it needs no `_live` flag. The
    // hub gives each page its own delegate, so a page can only ever be BORN or edited.
    // The Manager has ONE clone and moves `pageIndex` (Manager.qml binds it to
    // currentPageIndex), so every tile on screen changes at once when the user clicks
    // another page in the sidebar. That is not an edit: nothing was added and nothing
    // was removed - the user asked to look somewhere else. Read as an edit it would be
    // the worst frame in the app: every tile of the old page fading out as a ghost
    // while every tile of the new one faded in through them.
    //
    // So a page switch RE-SEEDS: rows are dropped outright and re-appended inert. It
    // doubles as the hub's `_live` - nothing has been seeded yet at construction, so
    // the first sync is a re-seed and the tiles the clone opens with never fade in.
    // `null` rather than -1 because -1 is a real pageIndex ("no page") in this app.
    property var _shownPage: null

    // One packer placement → one model row. The string roles are coerced because a
    // ListModel FIXES each role's type on the first append: a tile reaching the clone
    // without a `type` would otherwise seed the role as `undefined`, and "" is the
    // value `wsrc`/`catalog.title`/`catalog.sizesFor` already treat as "no such type".
    //
    // The extent (the packer's es/el) is deliberately NOT a role: the cell derives its
    // extent from `effSize`, which the resize drag previews live, so a role here would
    // be a second and staler copy of `semiUnits(size)` - the identical fact.
    //
    // `dying`/`entering` are declared here for the same reason: the first append fixes
    // the ROLE SET too, so a role that only ever appeared later would not exist at all.
    function _row(p) {
        return ({ tileId: p.id || "", tileType: p.type || "", tileSize: p.size || "",
                  tileIdx: p.idx, ps: p.s, pl: p.l, dying: false, entering: false })
    }
    // Drop a faded-out row. Called by the cell when its exit fade ends - by id,
    // because rows shift as others are reaped.
    //
    // Only a DYING row may be reaped: this is a fade closing the row it opened, not a
    // general-purpose delete. A row resurrected mid-fade (see _syncPlacements) is live
    // again and must survive the animation that was removing it.
    function _reapRow(id) {
        for (var r = 0; r < placementModel.count; r++)
            if (placementModel.get(r).tileId === id && placementModel.get(r).dying) {
                placementModel.remove(r)
                return true
            }
        return false
    }
    // Reconciles the model to the current packing. Returns the row count - one per
    // PLACED tile, plus any still fading out - so the caller and the tests can check
    // the sync against it.
    function _syncPlacements() {
        var ps = clone.placements || []
        var byId = Object.create(null)
        for (var i = 0; i < ps.length; i++) byId[ps[i].id] = ps[i]

        // A PAGE SWITCH is not an edit (see `_shownPage`): drop everything, ghosts
        // included, and re-seed inert below. Doing this first also means the rest of
        // this function only ever sees one page's tiles, so a stale row from the page
        // we just left can never be mistaken for a removal.
        var reseed = (clone._shownPage !== clone.pageIndex)
        if (reseed) {
            placementModel.clear()
            clone._shownPage = clone.pageIndex
        }

        // Gone → the tile was removed. Its delegate has to OUTLIVE the packing that
        // dropped it or there is nothing left to fade, so the row is marked `dying`
        // and the cell reaps it when its fade ends (see the exit fade below).
        //
        // REDUCE MOTION: the DURATION TOKEN does the real work - at motionRemove 0 the
        // exit fade finishes SYNCHRONOUSLY when it is started, so the row is reaped in
        // this same event even by the `dying` path. Measured here, not assumed: with
        // this branch deleted, test_reduce_motion_removes_a_tile_instantly still
        // passes. The branch is kept as the explicit statement of intent, and to skip
        // marking, animating and reaping a row for a fade that cannot be seen - it is
        // NOT the mechanism. Smooth is not more motion.
        for (var r = placementModel.count - 1; r >= 0; r--) {
            if (byId[placementModel.get(r).tileId] !== undefined) continue
            if (theme.motionRemove > 0) {
                if (!placementModel.get(r).dying)
                    placementModel.setProperty(r, "dying", true)
            } else {
                placementModel.remove(r)   // backwards: remove() shifts the tail
            }
        }

        // Survivors → patch in place. THIS is the move: same row, same delegate
        // object, new slot. set() only touches rows that actually differ, so an
        // unmoved tile is not even notified.
        var seen = Object.create(null)
        for (var r2 = 0; r2 < placementModel.count; r2++) {
            var row = placementModel.get(r2)
            var p = byId[row.tileId]
            // A row with no placement is one of the dying rows above, held open only
            // for its fade. It is not in the packing, so there is nothing to reconcile
            // it against - and reading `p.s` off it would throw.
            if (p === undefined) continue
            seen[row.tileId] = true
            // Resurrection: this id was fading out and is back (an undo, or a live
            // push that re-adds it). Cancel the exit - the tile exists, so it must not
            // vanish when a fade nobody is watching any more happens to finish.
            if (row.dying) placementModel.setProperty(r2, "dying", false)
            if (row.ps !== p.s || row.pl !== p.l || row.tileIdx !== p.idx
                || row.tileSize !== p.size || row.tileType !== p.type)
                placementModel.set(r2, clone._row(p))
        }

        // Genuinely new tiles → append. A new delegate is born at its final slot (a
        // Behavior does not fire on initial binding), so an add slides its NEIGHBOURS
        // and never itself - the tile's own arrival is the `entering` fade instead.
        // Never on a re-seed (the tiles a page is shown with are not an add), and only
        // while the token allows it.
        //
        // REDUCE MOTION, exactly as on the exit above: `theme.motionAdd > 0` is NOT the
        // mechanism - measured, with that clause deleted a 0ms entrance still lands its
        // end value synchronously and test_reduce_motion_adds_a_tile_instantly still
        // passes. The DURATION TOKEN does the work. The clause is the statement of
        // intent, and skips animating an arrival nobody can see.
        for (var k = 0; k < ps.length; k++) {
            if (seen[ps[k].id] !== undefined) continue
            var fresh = clone._row(ps[k])
            fresh.entering = !reseed && theme.motionAdd > 0
            placementModel.append(fresh)
        }

        return placementModel.count
    }
    // onPlacementsChanged alone is not enough: a property change signal is not
    // guaranteed for the binding's FIRST evaluation. Both paths are idempotent.
    onPlacementsChanged: clone._syncPlacements()
    Component.onCompleted: clone._syncPlacements()

    // ── Page background (mirrors Dashboard.qml so the clone is truly WYSIWYG:
    //    animated style OR wallpaper, per-page override → global default) ──
    property var pageBg: {
        store.revision
        // Live hover-preview of a background style from the Appearance picker
        // (Manager only): show it over everything without touching the store.
        if (theme.previewBgStyle && theme.previewBgStyle.length)
            return { wallpaper: "", style: theme.previewBgStyle }
        var pages = store.pages()
        var p = (pageIndex >= 0 && pageIndex < pages.length) ? pages[pageIndex] : ({})
        var pbg = p.bg || ({})
        var a = store.appearance() || ({})
        if (pbg.wallpaper) return { wallpaper: pbg.wallpaper, style: pbg.style || a.bgStyle || "orbs" }
        if (pbg.style)     return { wallpaper: "", style: pbg.style }
        return { wallpaper: a.wallpaper || "", style: a.bgStyle || "orbs" }
    }
    // Wallpapers are stored as file:// URLs into the Manager's images dir. Re-derive
    // a properly percent-encoded URL from the basename via backend.imageUrl(name) so
    // names with spaces / non-ASCII characters load (mirrors the hub, fixes raw paths).
    property string wallpaperSource: {
        var wp = clone.pageBg.wallpaper
        if (!wp || !wp.length) return ""
        var s = String(wp)
        var name = s.substring(s.lastIndexOf("/") + 1)
        return name.length ? backend.imageUrl(name) : ""
    }
    property bool animatedBg: {
        store.revision
        var a = store.appearance() || ({})
        // Calm-by-default, exactly like the hub (main.qml `animatedBackground:
        // false`): an unset config means the orbs backdrop stays STILL. The old
        // `true` default made every preview drive the animated Shapes backdrop
        // out of the box - a continuous repaint beside the scrolled controls,
        // and the single biggest source of the Manager's scroll lag.
        return a.animatedBg === undefined ? false : a.animatedBg
    }
    // effectiveReduceMotion (not the raw store flag): the theme folds in the OS
    // reduce-motion probe, so the preview stills exactly when the hub would.
    property bool reduceMotion: theme.effectiveReduceMotion

    // Host-driven: true while the surrounding controls are being scrolled. A
    // continuously-animating preview (animated background, metric sweeps) beside a
    // scrolling ScrollView forces a full-window repaint every scroll frame - the
    // Manager's scroll lag. Pausing the preview for the duration of the flick keeps
    // scrolling smooth; it resumes the instant the scroll settles.
    property bool scrolling: false

    // Pause everything that repaints continuously (the animated backdrop, the
    // per-second tick and the metrics poll) whenever this clone is off-screen OR
    // the controls beside it are being scrolled. A non-current Manager tab sets the
    // whole subtree's `visible` to false, so this reads it directly.
    readonly property bool previewLive: clone.visible && !clone.scrolling

    property int tick: 0
    property var metricsObj: ({})
    Timer { interval: 1000; running: clone.previewLive; repeat: true; onTriggered: clone.tick++ }
    Timer {
        interval: 2000; running: clone.previewLive; repeat: true; triggeredOnStart: true
        onTriggered: {
            try { clone.metricsObj = JSON.parse(backend.metricsJson() || "{}") }
            catch (e) { clone.metricsObj = ({}) }
        }
    }

    function wsrc(type) {
        var s = catalog.source(type)
        return s ? s.replace("qrc:/qml/", "qrc:/manager/") : ""
    }
    // The size class comes from WidgetSizes.classFor - the SAME function the hub's
    // Dashboard calls, evaluated at THIS clone's live orientation.
    //
    // This used to be a copy of the derivation with `landscape` hardcoded to false,
    // on the reasoning that "the clone is a portrait mirror of the panel". That
    // reasoning stopped being true when the frame learned to draw landscape pages
    // wide (see `_shortPx` below, and the `clone.landscape` already threaded into
    // `packer.rect`), and the copy was left behind. The result: in landscape the hub
    // rendered a tile `wide` and the Manager rendered the same tile `tall` - a
    // different layout variant with different information density, which is exactly
    // the "widgets are not WYSIWYG in the Manager" report. Call it; never copy it.
    // ── Drag-move state ──
    // These are indices into the STORE's tile array (the placement's `idx`) - the
    // thing moveTile addresses and the thing `tiles` is indexed by. They are NOT
    // Repeater row numbers: rows are patched in place by _syncPlacements, so after
    // one reorder row order is no longer tile order, and the two would silently
    // disagree. Naming them `Idx` matches the `idx` the packer and store already use.
    property int dragIdx: -1
    property int targetIdx: -1
    property real dragX: 0
    property real dragY: 0

    // The STORE tile index of the delegate under (gx, gy), in the tile container's
    // coordinates; -1 for a miss. Iterates the Repeater's own rows - the delegates
    // that actually exist - and reads each one's `tileIdx`, rather than assuming a
    // row number is a tile number. (`tiles` is one per stored tile and an unplaceable
    // one has no delegate, so counting tiles here would walk past the end.)
    //
    // A GHOST IS NOT A DROP TARGET. A dying row still occupies a row here and still
    // sits on its old pixels, but it reports a STALE `tileIdx`: removing a tile shifts
    // every later store index down, and the ghost is by definition not in that packing
    // any more. Hit-testing it would hand moveTile an index that now addresses a
    // DIFFERENT tile - a drop onto a fading box would silently move the wrong widget -
    // or an index past the end. So dying rows are skipped, and the pixels they are
    // vacating target nothing, exactly as the empty space they are becoming would.
    function targetAt(gx, gy) {
        for (var r = 0; r < rep.count; r++) {
            var it = rep.itemAt(r)
            if (!it || it.dying) continue
            if (gx >= it.x && gx <= it.x + it.width && gy >= it.y && gy <= it.y + it.height)
                return it.tileIdx
        }
        return -1
    }

    // ── Device frame - the WHOLE page, scaled to fit (no scrolling) ──
    Rectangle {
        id: frame
        anchors.centerIn: parent
        transformOrigin: Item.Center
        // Frame follows the screen's intrinsic size (which follows orientation), so a
        // landscape page draws wide instead of overflowing a fixed portrait frame.
        width: screen.width + 16
        height: screen.height + 16
        // Scale the entire device so the full page is visible at once. Grows and
        // shrinks with the Manager window (the fit ratio tracks clone.width/height),
        // capped at 1.6x so a short page doesn't upscale to blur. The scene inside
        // stays at the Edge's real 720 logical-pixel short axis, then this outer
        // transform alone fits it into the Manager. Keeping true internal geometry
        // is required for the widgets' pixel-based micro/readability boundaries.
        scale: Math.max(0.22, Math.min(clone.width / width, clone.height / height, 1.6))
        radius: 26; color: "#050507"; border.width: 2; border.color: "#000000"
        Behavior on scale { NumberAnimation { duration: 150 } }

        Rectangle {
            id: screen
            objectName: "cloneDashboardScreen"
            anchors.centerIn: parent
            // The Edge's real 2560x720 aspect, extended when the page runs longer than
            // one screen. `_deviceAspect` makes a cell here the same SHAPE as a cell on
            // the panel - the one thing a clone at a different pixel scale can get
            // wrong, and exactly what widget authors judge their `sizes` against.
            readonly property real _deviceAspect: 2560 / 720
            // Cells derive from ONE SCREEN (a 0.5x0.5 is a twelfth here too), and the
            // frame grows along the LONG axis for a longer page. Orientation-aware:
            // portrait draws tall (short axis = width), landscape draws wide (short
            // axis = height, long axis = width) - mirroring the panel so a landscape
            // preview is not cut off by a portrait-shaped frame.
            readonly property real _shortPx: 720          // real Edge logical short axis
            readonly property real _longPx: _shortPx * _deviceAspect
            readonly property real _uiScale: _shortPx / 720
            readonly property real contentMargin: theme.spacingMd * _uiScale
            readonly property real barHeight: theme.touchPrimary * _uiScale
            readonly property real barGap: theme.spacingSm * _uiScale
            readonly property real barReserve: clone.showHubBar ? barHeight + barGap : 0
            // Derive cells from the Hub's real widget viewport, not the bare
            // panel. The control bar reduces the physical vertical axis, which
            // is the semantic long axis in portrait and short axis in landscape.
            readonly property real cellShort:
                (_shortPx - 2 * contentMargin - (clone.landscape ? barReserve : 0))
                / sizes.shortHalves
            readonly property real cellLong:
                (_longPx - 2 * contentMargin - (clone.landscape ? 0 : barReserve))
                / sizes.longHalves
            readonly property real _overflowPx:
                Math.max(0, clone.longExtent - sizes.longHalves) * cellLong
            width: clone.landscape ? _longPx + _overflowPx : _shortPx
            height: clone.landscape ? _shortPx : _longPx + _overflowPx
            radius: 20; clip: true
            gradient: Gradient {
                GradientStop { position: 0.0; color: theme.backgroundColor }
                GradientStop { position: 0.55; color: theme.backgroundColor2 }
                GradientStop { position: 1.0; color: theme.backgroundColor3 }
            }

            // Background style, shown when no wallpaper is set. The style renders
            // STATICALLY in the Manager preview (running: false): a small companion
            // thumbnail does not need a live 60fps animation, and an animating
            // backdrop beside a scrolling ScrollView forces a full-window repaint
            // every scroll frame - the Manager's scroll lag. The chosen style is
            // still visible; the real Edge animates it. (Wheel scrolling doesn't set
            // Flickable.moving, so a static backdrop is more robust than pausing.)
            BackdropLayer {
                anchors.fill: parent
                // Mirror the hub exactly: show the animated backdrop only when the
                // page has no wallpaper, the theme is decorative, AND the animated
                // background is on (the hub gates on animatedBg too - calm by
                // default, so a default config is legitimately still here).
                visible: clone.wallpaperSource === "" && theme.decorative && clone.animatedBg
                style: clone.pageBg.style
                accent: theme.accent
                // ACTUALLY ANIMATE, like the hub - this was hard-coded false, which
                // made every style a still image in the preview (not WYSIWYG). Gate
                // on previewLive (already false while the tab is hidden or the helper
                // column is scrolling, which was the original scroll-lag concern) and
                // on reduceMotion, so it stills exactly when the hub would.
                running: clone.previewLive && clone.animatedBg && !clone.reduceMotion
            }
            Image {
                id: cloneWall
                anchors.fill: parent
                source: clone.wallpaperSource
                visible: source != ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true; cache: true
            }
            Rectangle {
                anchors.fill: parent; visible: cloneWall.visible
                color: Qt.rgba(theme.backgroundColor.r, theme.backgroundColor.g, theme.backgroundColor.b, 0.28)
            }
            // Match Dashboard.qml's final colour layer exactly. Omitting this
            // made a blue-accent Midnight Hub look purple or red in Manager even
            // though both sides had loaded the same stored theme.
            Rectangle {
                objectName: "cloneAccentWash"
                property color startColor: theme.accent
                property color endColor: theme.accent2
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
                objectName: "cloneDashboardArea"
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.leftMargin: screen.contentMargin
                anchors.rightMargin: screen.contentMargin
                anchors.topMargin: screen.contentMargin
                anchors.bottom: clone.showHubBar ? hubBar.top : parent.bottom
                anchors.bottomMargin: clone.showHubBar ? screen.barGap : screen.contentMargin

                    Repeater {
                        id: rep
                        model: placementModel
                        delegate: Item {
                            id: tile
                            // The placement's roles. `tileIdx` - NOT the Repeater's row
                            // number - is what every store call here addresses.
                            required property string tileId
                            required property string tileType
                            required property string tileSize
                            required property int tileIdx
                            required property int ps
                            required property int pl
                            // Lifetime, not layout: `dying` is set on a row the packing
                            // has dropped and kept until this cell has faded out;
                            // `entering` is fixed at append time and says this cell was
                            // grown by the page, not seeded with it.
                            required property bool dying
                            required property bool entering
                            // Live preview during a resize drag: the size the drag has
                            // snapped to, "" when not dragging. Only the dragged tile's
                            // own box previews - the page re-packs on commit, because a
                            // repack per mouse-move would shuffle the neighbours under
                            // the cursor the drag is aimed at.
                            property string pvSize: ""
                            readonly property string effSize: tile.pvSize !== "" ? tile.pvSize : tile.tileSize

                            // ── The move ──────────────────────────────────────
                            // The eased mirror of the semantic ORIGIN. Easing the SLOT
                            // rather than x/y keeps the ease attached to the one thing
                            // that means "this tile moved", so a structure edit glides
                            // and nothing else has to opt out. No flag, no settling
                            // timer - the distinction is structural, so it cannot drift.
                            //
                            // The hub eases the EXTENT here too, and separates the ease
                            // from ROTATION that way (a turn re-projects the slot, so it
                            // stays instant). Neither half of that carries over:
                            //   • the clone's grid follows the same available viewport
                            //     as the Hub. Rotation re-projects it directly, while a
                            //     Standard/Immersive change intentionally updates the
                            //     available room. There is no delayed projection state
                            //     to keep in sync.
                            //   • the thing that must stay instant here is the resize
                            //     PREVIEW. A reorder never changes an extent; only a
                            //     resize does, and here a resize is a live corner DRAG
                            //     (on the hub it is a discrete button). The previewed box
                            //     has to sit under the cursor, so easing the extent would
                            //     put the tile 250ms behind the hand sizing it.
                            // So the extent stays direct, and no animation can fight a
                            // drag: a move drag re-packs nothing until the drop (by which
                            // point dragIdx is already cleared, so the tile glides home at
                            // full opacity), and a resize drag never moves an origin.
                            //
                            // REDUCE MOTION: the duration token does the real work -
                            // motionPage is 0, and a 0ms Behavior lands its end value
                            // synchronously on write. The `enabled` gate is the explicit
                            // statement of intent, and skips building an animation per
                            // tile per edit for a value that cannot move - it is not the
                            // mechanism. Smooth is not more motion.
                            property real animS: tile.ps
                            property real animL: tile.pl
                            Behavior on animS { enabled: theme.motionPage > 0
                                NumberAnimation { duration: theme.motionPage; easing.type: Easing.OutCubic } }
                            Behavior on animL { enabled: theme.motionPage > 0
                                NumberAnimation { duration: theme.motionPage; easing.type: Easing.OutCubic } }

                            // The (eased) origin, re-extended to whatever the drag is
                            // previewing. The ORIGIN stays put during a preview (only a
                            // commit re-packs), so this is the placement with a swapped
                            // extent. `semiUnits(size)` IS the packer's (es, el) - the
                            // same derivation, evaluated on the previewed size.
                            readonly property var _u: sizes.semiUnits(tile.effSize)
                            readonly property var _r: packer.rect(
                                { s: tile.animS, l: tile.animL, es: _u.s, el: _u.l },
                                clone.landscape, screen.cellShort, screen.cellLong,
                                theme.spacingMd * screen._uiScale)
                            x: _r.x; y: _r.y
                            width: _r.width; height: _r.height

                            // ── Opacity has TWO owners here, so it is composed ──
                            // The hub's cell animates `opacity` directly, because there
                            // the only thing opacity means is "am I coming or going".
                            // In the clone it ALREADY means something else: a tile being
                            // dragged is held at 0.3 so the page reads through it. Those
                            // are independent facts - a tile can be dragged AND dying (a
                            // live push can delete the widget in your hand) - and an
                            // animation ASSIGNS a property, destroying any binding on it.
                            // Animating `opacity` here would silently break the drag
                            // binding for the rest of the delegate's life the first time
                            // anything faded.
                            //
                            // So the fade owns its own property and the two are
                            // multiplied: neither has to know about the other, and
                            // neither can clobber the other.
                            property real lifeOpacity: tile.entering ? 0 : 1
                            opacity: (clone.dragIdx === tile.tileIdx ? 0.3 : 1.0) * tile.lifeOpacity

                            // ── The exit ──────────────────────────────────────
                            // A removed tile used to blink out of existence while its
                            // neighbours glided into the space it left - the one motion
                            // on screen belonged to everything EXCEPT the thing the user
                            // actually acted on. (Confirmed before fixing: the delegate
                            // did not outlive its removal, so there was nothing left to
                            // fade - the guard was red on the old code.)
                            //
                            // The delegate has to outlive its removal from the packing
                            // for there to be anything to fade, so the ROW is the thing
                            // held open (`dying`, set by _syncPlacements) and this cell
                            // is what closes it: when the fade ends, it reaps its own
                            // row. That keeps the lifetime in ONE place - no delegate can
                            // be orphaned by a fade that never ran, because the only
                            // thing that starts a fade is the role that also holds the
                            // row open.
                            //
                            // motionRemove (150ms) is shorter than the 250ms move, so
                            // the ghost is gone before its neighbours arrive over it.
                            // Under reduce-motion that token is 0, and THAT is what makes
                            // a removal instant rather than merely quick: a 0ms fade
                            // lands and reaps in the same event it starts.
                            //
                            // A ghost is not a tile: it must not answer a tap, or offer
                            // ⚙/✕/resize chrome for a tile the store no longer has. (It
                            // is not a drop target either - see `targetAt`.)
                            enabled: !tile.dying
                            onDyingChanged: {
                                if (tile.dying) {
                                    // A FADE MUST NOT FIGHT A DRAG. The drop path clears
                                    // dragIdx before it calls moveTile, so a drop can
                                    // never race its own re-pack. The way in is a removal
                                    // from OUTSIDE - a live push, or the ✕ on the other
                                    // clone - deleting the tile being held. `enabled`
                                    // just went false, so this MouseArea's grab dies with
                                    // it and onReleased will never run: the drag state
                                    // would be stranded and the floating name-tag with
                                    // it (the exact shape of REGRESSION 1 in
                                    // tst_edgeclone_drag). A tile that dies mid-drag ends
                                    // its own drag.
                                    if (clone.dragIdx === tile.tileIdx) {
                                        clone.dragIdx = -1; clone.targetIdx = -1
                                    }
                                    // Only ever one animation owns lifeOpacity. A tile can
                                    // be removed inside its own entrance (add a widget,
                                    // think better of it, hit ✕ - 200ms is easy to beat),
                                    // and two animations writing the same property every
                                    // tick fight rather than blend.
                                    enterFade.stop(); exitFade.start()
                                } else {
                                    exitFade.stop(); tile.lifeOpacity = 1   // resurrected
                                }
                            }
                            NumberAnimation {
                                id: exitFade
                                target: tile; property: "lifeOpacity"; to: 0
                                duration: theme.motionRemove; easing.type: Easing.OutCubic
                                onFinished: clone._reapRow(tile.tileId)
                            }

                            // ── The entrance ──────────────────────────────────
                            // An added tile is the one thing on screen the user just
                            // asked for, so it arrives in its own right instead of simply
                            // already being there. It fades in AT its slot: it does not
                            // fly in, because the packer put it where it belongs and
                            // there is no truthful "from" to fly from.
                            //
                            // `entering` is decided once, when the row is appended (see
                            // _syncPlacements), so a page SWITCH - which re-seeds - cannot
                            // trigger it, and reduce-motion means it is never set and
                            // lifeOpacity stays bound at 1.
                            Component.onCompleted: if (tile.entering) enterFade.start()
                            NumberAnimation {
                                id: enterFade
                                target: tile; property: "lifeOpacity"; from: 0; to: 1
                                duration: theme.motionAdd; easing.type: Easing.OutCubic
                            }

                            Rectangle {   // placeholder / loading
                                anchors.fill: parent; radius: theme.radiusLg
                                color: theme.cardFill(); border.width: 1; border.color: theme.cardBorder
                                visible: wl.status !== Loader.Ready
                                Column {
                                    anchors.centerIn: parent; spacing: 6
                                    AppIcon { anchors.horizontalCenter: parent.horizontalCenter
                                        name: tile.tileType; size: 28; color: theme.textSecondary }
                                    Text { anchors.horizontalCenter: parent.horizontalCenter
                                        text: catalog.title(tile.tileType); color: theme.textSecondary
                                        font.pixelSize: theme.fontMinimum }
                                }
                            }
                            WidgetHost {
                                id: wl
                                anchors.fill: parent
                                property string wId: tile.tileId
                                widgetId: tile.tileId
                                widgetType: tile.tileType
                                widgetSource: clone.wsrc(tile.tileType)
                                store: clone.widgetStore
                                catalog: clone.widgetCatalog
                                metrics: clone.metricsObj
                                netHub: passivePreviewHub
                                timeZones: clone.widgetTimeZones
                                tick: clone.tick
                                expanded: false
                                // Bound on BOTH the previewed size and the live
                                // orientation, so a rotation re-classes the tile
                                // exactly as it does on the hub.
                                sizeClass: sizes.classFor(tile.effSize, clone.landscape)
                                driverActive: false
                                acceptsInput: false
                            }

                            // Drop-target highlight.
                            Rectangle {
                                anchors.fill: parent; radius: theme.radiusLg
                                color: "transparent"; border.width: 3; border.color: theme.accent
                                visible: clone.dragIdx >= 0 && clone.targetIdx === tile.tileIdx
                                         && clone.dragIdx !== tile.tileIdx
                            }

                            // Drag / select overlay.
                            MouseArea {
                                id: ma
                                visible: clone.editable
                                anchors.fill: parent
                                anchors.rightMargin: 26; anchors.bottomMargin: 26   // leave the corner handle
                                cursorShape: clone.dragIdx === tile.tileIdx ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                                preventStealing: true
                                property real sx: 0; property real sy: 0
                                property bool dragging: false
                                onPressed: (mouse) => { ma.sx = mouse.x; ma.sy = mouse.y; ma.dragging = false }
                                onPositionChanged: (mouse) => {
                                    if (!ma.dragging && (Math.abs(mouse.x - ma.sx) > 8 || Math.abs(mouse.y - ma.sy) > 8)) {
                                        ma.dragging = true; clone.dragIdx = tile.tileIdx
                                    }
                                    if (ma.dragging) {
                                        var g = tile.mapToItem(grid, mouse.x, mouse.y)
                                        var c = tile.mapToItem(clone, mouse.x, mouse.y)
                                        clone.dragX = c.x; clone.dragY = c.y
                                        clone.targetIdx = clone.targetAt(g.x, g.y)
                                    }
                                }
                                onReleased: {
                                    if (ma.dragging) {
                                        // Both are STORE tile indices - targetAt reports the
                                        // hit delegate's own `tileIdx` - so they address
                                        // moveTile directly. There is no longer a placement
                                        // array to index through, which is what kept this
                                        // correct only for as long as row order happened to
                                        // equal tile order.
                                        var to = clone.targetIdx
                                        var from = tile.tileIdx
                                        // Clear the drag state (which hides the floating
                                        // name-tag) BEFORE moveTile: a reset placed after it
                                        // may never execute if this handler's delegate dies,
                                        // leaving the name-tag stuck in air. The delegate now
                                        // SURVIVES a reorder, so this is belt-and-braces -
                                        // but it is also what lets the dragged tile glide
                                        // home at full opacity instead of being animated
                                        // while still visibly held.
                                        ma.dragging = false
                                        clone.dragIdx = -1; clone.targetIdx = -1
                                        if (to >= 0 && to !== from)
                                            store.moveTile(clone.pageIndex, from, to)
                                    } else {
                                        clone.configRequested(tile.tileId, tile.tileType)
                                    }
                                }
                            }

                            // Top-right controls.
                            Row {
                                visible: clone.editable
                                anchors.top: parent.top; anchors.right: parent.right; anchors.margins: 8
                                spacing: 6; z: 5
                                Rectangle {
                                    width: 52; height: 52; radius: 26; color: Qt.rgba(0, 0, 0, 0.55)
                                    AppIcon { anchors.centerIn: parent; name: "ui-settings"; color: "#fff"; size: 20 }
                                    MouseArea { anchors.fill: parent
                                        onClicked: clone.configRequested(tile.tileId, tile.tileType) }
                                }
                                Rectangle {
                                    width: 52; height: 52; radius: 26
                                    color: Qt.rgba(theme.error.r, theme.error.g, theme.error.b, 0.7)
                                    AppIcon { anchors.centerIn: parent; name: "ui-close"; color: "#fff"; size: 20 }
                                    MouseArea { anchors.fill: parent
                                        onClicked: store.removeTile(clone.pageIndex, tile.tileId) }
                                }
                            }

                            // Corner resize handle. The drag is free-form but the sizes
                            // are not: the dragged box is SNAPPED to the nearest size the
                            // widget type actually declares, so an illegal shape is never
                            // offered rather than being offered and then corrected. There
                            // is deliberately no fixed pixel "flip threshold" any more -
                            // the old one hard-coded a 180px row height, which is not a
                            // thing the size model has. Previews live; commits on release.
                            Rectangle {
                                anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: 5
                                width: 36; height: 36; radius: 10; z: 6
                                visible: clone.editable && catalog.sizesFor(tile.tileType).length > 1
                                color: Qt.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 0.75)
                                AppIcon { anchors.centerIn: parent; name: "ui-resize"; color: "#0D1117"; size: 15 }
                                MouseArea {
                                    anchors.fill: parent; anchors.margins: -8
                                    cursorShape: Qt.SizeFDiagCursor
                                    preventStealing: true
                                    property real sx: 0; property real sy: 0
                                    // Work in the UNSCALED content ("screen") space so the drag
                                    // distance needed to reach a size matches the visible tile
                                    // edge regardless of the device frame's fit-to-view scale.
                                    onPressed: (mp) => {
                                        var c = mapToItem(screen, mp.x, mp.y)
                                        sx = c.x; sy = c.y
                                        tile.pvSize = tile.tileSize
                                    }
                                    onPositionChanged: (mp) => {
                                        var c = mapToItem(screen, mp.x, mp.y)
                                        // The box the cursor is describing, resolved onto the
                                        // SEMANTIC axes - so this reads identically whichever
                                        // way the device is turned.
                                        var pxW = tile.width + (c.x - sx), pxH = tile.height + (c.y - sy)
                                        var pxShort = clone.landscape ? pxH : pxW
                                        var pxLong = clone.landscape ? pxW : pxH
                                        // Snap only among sizes that FIT the page, so the
                                        // preview can never grow the widget past the space
                                        // left - no transient overflow/scroll during the
                                        // drag, and "make bigger with no room" simply does
                                        // not move. Falls back to all declared sizes if the
                                        // store can't answer (defensive).
                                        var fitting = store.fittingSizesFor(clone.pageIndex, tile.tileId)
                                        if (!fitting || fitting.length === 0)
                                            fitting = catalog.sizesFor(tile.tileType)
                                        var snapped = packer.snap(fitting,
                                                                  pxShort, pxLong,
                                                                  screen.cellShort, screen.cellLong)
                                        if (snapped !== "") tile.pvSize = snapped
                                    }
                                    onReleased: {
                                        var next = tile.pvSize
                                        tile.pvSize = ""
                                        // setTileSize is the gate, not this handler: `snap`
                                        // only ever proposes a supported size, and the store
                                        // still refuses anything else.
                                        if (next !== "") store.setTileSize(clone.pageIndex, tile.tileId, next)
                                    }
                                }
                            }
                        }
                    }
                }

            Text {
                anchors.centerIn: grid
                visible: clone.tiles.length === 0
                text: "This page is empty.\nUse “Add widget”."
                horizontalAlignment: Text.AlignHCenter
                color: theme.textTertiary; font.pixelSize: theme.fontMinimum
            }

            // Passive representation of the real Hub controls. EdgeClone is a
            // preview, so these controls do not compete with the Manager editor,
            // but their footprint and information remain visible in Standard mode.
            Item {
                id: hubBar
                objectName: "cloneHubBottomBar"
                visible: clone.showHubBar
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.leftMargin: screen.contentMargin
                anchors.rightMargin: screen.contentMargin
                anchors.bottomMargin: screen.contentMargin
                height: screen.barHeight

                Rectangle {
                    anchors.fill: parent
                    radius: Math.max(4, theme.radiusMd * screen._uiScale)
                    color: Qt.rgba(theme.cardBackgroundAlt.r,
                                   theme.cardBackgroundAlt.g,
                                   theme.cardBackgroundAlt.b, 0.72)
                    border.width: 1
                    border.color: theme.cardBorder
                }

                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: theme.spacingMd * screen._uiScale
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width * 0.25
                    text: {
                        store.structureRevision
                        var ps = store.pages()
                        return clone.pageIndex >= 0 && clone.pageIndex < ps.length
                               ? (ps[clone.pageIndex].name || "Screen") : "Screen"
                    }
                    elide: Text.ElideRight
                    color: theme.textSecondary
                    font.pixelSize: Math.max(7, theme.fontLabel * screen._uiScale)
                    font.weight: Font.DemiBold
                }

                Row {
                    anchors.centerIn: parent
                    spacing: theme.spacingXs * screen._uiScale
                    Repeater {
                        model: {
                            store.structureRevision
                            return Math.max(1, store.pageCount())
                        }
                        delegate: Rectangle {
                            required property int index
                            width: index === clone.pageIndex ? 18 * screen._uiScale : 7 * screen._uiScale
                            height: 7 * screen._uiScale
                            radius: height / 2
                            color: theme.accent
                            opacity: index === clone.pageIndex ? 0.95 : 0.3
                        }
                    }
                }

                Row {
                    anchors.right: parent.right
                    anchors.rightMargin: theme.spacingMd * screen._uiScale
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: theme.spacingSm * screen._uiScale
                    Repeater {
                        model: ["ui-edit", "ui-palette", "ui-settings"]
                        delegate: Rectangle {
                            required property string modelData
                            width: screen.barHeight * 0.64
                            height: width
                            radius: width / 2
                            color: theme.cardBackgroundAlt
                            border.width: 1
                            border.color: theme.cardBorder
                            AppIcon {
                                anchors.centerIn: parent
                                name: modelData
                                size: Math.max(8, parent.width * 0.42)
                                color: theme.textSecondary
                            }
                        }
                    }
                }
            }
        }
    }

    // Floating drag ghost - tracks the cursor (both axes) and stays on-screen.
    // `dragIdx` indexes `tiles` directly and correctly: it is the store tile index,
    // which is exactly what `tiles` is ordered by. (It used to be a placement/row
    // number that indexed `tiles` anyway, and agreed only while no tile was ever
    // skipped by the packer.)
    Rectangle {
        id: dragGhost
        visible: clone.dragIdx >= 0 && clone.dragIdx < clone.tiles.length
        width: 210; height: 46; radius: 12; z: 100
        x: Math.max(6, Math.min(clone.width - width - 6, clone.dragX + 18))
        y: Math.max(6, Math.min(clone.height - height - 6, clone.dragY - height / 2))
        color: theme.cardBackgroundAlt; border.width: 1; border.color: theme.accent
        Row {
            anchors.centerIn: parent; spacing: 10
            AppIcon { anchors.verticalCenter: parent.verticalCenter; size: 22; color: theme.textPrimary
                name: clone.dragIdx >= 0 && clone.dragIdx < clone.tiles.length
                      ? clone.tiles[clone.dragIdx].type : "" }
            Text { text: clone.dragIdx >= 0 && clone.dragIdx < clone.tiles.length
                ? catalog.title(clone.tiles[clone.dragIdx].type) : ""
                color: theme.textPrimary; font.pixelSize: theme.fontMinimum }
        }
    }
}
