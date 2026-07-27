import QtQuick
import QtTest
import "../../ui/qml" as App

// COVERS: fn:EdgeClone.targetAt, fn:EdgeClone.wsrc
// COVERS: fn:EdgeClone._shortestTurn, fn:EdgeClone._startOrientationTransition
//
// manager/qml/EdgeClone.qml -
//   • wsrc(type): rewrites the hub qrc path to the manager alias; "" for unknown
//   • WidgetHost: injects the shared store/render contract while keeping every
//     Manager copy passive and pointer-shielded
//   • targetAt(gx,gy): hit-tests placed tiles (in-bounds → the hit delegate's STORE
//     tile index, outside → -1)
//   • resize handle drag → snaps to a size the TYPE declares → store.setTileSize
//
// `spanH(h) = 180n + 10(n-1)` is GONE with its test: it hard-coded a 180px row
// height, and the size model has no such thing - a cell is a fraction of the screen,
// so there is no fixed pixel row to encode. Placement now comes from WidgetPacker.
//
// EdgeClone resolves store/catalog/theme/media/backend from the Manager scope;
// we provide them on this wrapper (backend is a light stub) and load the REAL
// EdgeClone.qml via a Loader. Assertions target the store + driving props.
Item {
    id: root
    width: 560; height: 860

    App.Theme { id: theme }
    App.DashboardStore { id: store }
    App.WidgetCatalog { id: catalog }
    App.WidgetSizes { id: hubSizes }   // the HUB's copy - the parity reference
    MockMedia { id: media }

    QtObject {
        id: backend
        property bool hubConnected: false
        property int hubRotation: -1
        function imageUrl(n) { return "file:///imgs/" + n }
        function metricsJson() { return "{}" }
    }

    Loader {
        id: ld
        anchors.fill: parent
        source: "../../manager/qml/EdgeClone.qml"
        onLoaded: if (item) item.pageIndex = 0
    }

    // ── tree helpers ─────────────────────────────────────────────────────────
    function eachItem(node, fn) {
        if (!node) return
        fn(node)
        var kids = node.children
        if (kids) for (var i = 0; i < kids.length; i++) eachItem(kids[i], fn)
    }
    function findAll(n, pred) {
        var out = []
        eachItem(n, function (x) { if (pred(x)) out.push(x) })
        return out
    }
    function findByObjectName(name) {
        var found = findAll(ld.item, function (x) { return x && x.objectName === name })
        return found.length > 0 ? found[0] : null
    }
    function tileDelegates() {
        return findAll(ld.item, function (x) {
            return x && x.effSize !== undefined && x.pvSize !== undefined && x.tileId !== undefined
        })
    }
    // Keyed on the STORE tile index the delegate carries, not the Repeater's row
    // number: rows are patched in place by _syncPlacements, so the two part company
    // after the first reorder.
    //
    // Ghosts (dying rows, held open for their exit fade) are skipped for the SAME
    // reason EdgeClone.targetAt skips them: a removal shifts every later store index
    // down, so a dying row's `tileIdx` is stale. This suite shares one Loader and
    // re-seeds per test, so an earlier test's ghost really was answering to `tileIdx`
    // here and handing back the wrong box - test_targetAt's corner probe caught it.
    function tileAtIdx(i) {
        var ds = tileDelegates()
        for (var k = 0; k < ds.length; k++) if (!ds[k].dying && ds[k].tileIdx === i) return ds[k]
        return null
    }
    // The resize-handle MouseArea: it carries the press-origin (sx/sy) but, unlike
    // the drag/select overlay, no `dragging` flag.
    function resizeHandles() {
        return findAll(ld.item, function (x) {
            return x && x.sx !== undefined && x.dragging === undefined && typeof x.pressed === "boolean"
        })
    }

    // The widget instance the clone ACTUALLY loaded for a tile, reached through the
    // delegate's own WidgetHost (`wId`). Going through the real host is the point:
    // a synthetic binding test cannot see the clone passing the wrong size class,
    // which is precisely how the hardcoded-portrait size class survived.
    // Ghosts are skipped for the SAME reason tileAtIdx skips them: a dying row is
    // held open for its exit fade, and since this suite re-seeds per case the store
    // hands out the same tile id again - so an earlier case's ghost answers to the
    // new id and returns ITS class. That cost a real debugging round: the landscape
    // pass read the portrait pass's fading tile and reported "tall" for a fix that
    // was correctly in place.
    function loadedWidget(tileId) {
        var ds = tileDelegates()
        for (var d = 0; d < ds.length; d++) {
            if (ds[d].dying || ds[d].tileId !== tileId) continue
            var ls = findAll(ds[d], function (x) { return x && x.wId !== undefined })
            for (var i = 0; i < ls.length; i++) if (ls[i].item) return ls[i].item
        }
        return null
    }

    function seed(tileList) {
        store.load("blank")
        // Geometry interaction cases below intentionally exercise portrait.
        // Auto now truthfully defaults to the Hub's landscape-first fallback,
        // so make this helper's test projection explicit.
        store.setAppearance("orientation", "portrait")
        for (var i = 0; i < tileList.length; i++)
            store.addTile(0, tileList[i].type)
    }
    function tile0() { return store.pages()[0].tiles[0] }

    TestCase {
        name: "EdgeClone"
        when: windowShown

        function initTestCase() {
            tryVerify(function () { return ld.status === Loader.Ready && ld.item !== null }, 5000)
        }

        function init() {
            backend.hubRotation = -1
            store.load("blank")
        }

        // ── wsrc ──────────────────────────────────────────────────────────────
        function test_wsrc_rewrites_known_and_blanks_unknown() {
            var c = ld.item
            var hub = catalog.source("cpu")
            var mgr = c.wsrc("cpu")
            verify(hub.length > 0, "precondition: the catalog resolves cpu")
            verify(/CpuWidget\.qml$/.test(hub), "hub path points at CpuWidget.qml: " + hub)
            verify(/CpuWidget\.qml$/.test(mgr), "manager path points at CpuWidget.qml: " + mgr)
            // Bundled, the Manager has its OWN alias for the same bytes, and the
            // rewrite must produce it. Run from the source tree there is only one
            // copy of the file, so the rewrite is correctly a no-op - asserting
            // the qrc literal there would pin the harness, not the behaviour.
            if (hub.indexOf("qrc:") === 0)
                compare(mgr, "qrc:/manager/CpuWidget.qml", "rewritten to the manager alias")
            else
                compare(mgr, hub, "source-tree run: both apps load the same file")
            compare(c.wsrc("does-not-exist"), "", "unknown type yields empty source")
        }

        function test_preview_includes_the_hubs_accent_wash() {
            var wash = findByObjectName("cloneAccentWash")
            verify(wash !== null, "the WYSIWYG preview includes the Hub accent layer")
            compare(wash.opacity, 0.10)

            theme.applyAccent("blue")
            var before = theme.accent.toString()
            compare(wash.startColor.toString(), before)
            theme.applyAccent("red")
            verify(theme.accent.toString() !== before, "precondition: accent changed")
            compare(wash.startColor.toString(), theme.accent.toString(),
                    "the preview wash tracks the stored/live accent")
            compare(wash.opacity, 0.10, "the same live layer remains active after an accent change")
            theme.applyAccent("blue")
        }

        // ── shared host contract ──────────────────────────────────────────────
        function test_widget_host_sets_props_binds_and_stays_passive() {
            var c = ld.item
            root.seed([ { type: "cpu" } ])
            var id = tile0().id
            var w = null
            tryVerify(function () { w = loadedWidget(id); return w !== null }, 3000)
            compare(w.instanceId, id, "instanceId set")
            compare(w.store, store, "store injected")
            compare(w.expanded, false, "clone always renders the compact (non-expanded) form")
            compare(w.active, false, "Manager clone never becomes a state driver")

            store.setSetting(id, "title", "Rig")
            compare(w.titleOverride, "Rig", "titleOverride binding tracks the store")
            store.setSetting(id, "accent", "teal")
            compare(w.accentName, "teal", "accentName binding tracks the store")
            store.setSetting(id, "cardBackdrop", "orbs")
            compare(w.cardBackdrop, "orbs", "cardBackdrop binding tracks the store")

            c.metricsObj = ({ q: 9 })
            compare(w.metrics.q, 9, "metrics binding tracks clone.metricsObj")

            var shields = findAll(c, function (x) {
                return x && x.objectName === "passiveWidgetShield" && x.visible
            })
            verify(shields.length >= 1, "Manager widget is pointer-shielded")
        }

        // COVERS: fn:WidgetSizes.classFor
        //
        // THE WYSIWYG PARITY PIN. The clone used to own a copy-paste of the hub's
        // derivation with `landscape` hardcoded to false. In landscape the hub
        // rendered a tile `wide` and the Manager rendered the SAME tile `tall` - a
        // different layout variant at a different information density, which is what
        // "widgets are not WYSIWYG in the Manager" meant.
        //
        // The old test could not see it: it compared the clone's answer to STRING
        // LITERALS ("1x1" is "compact", …), never to the hub, and only ever in
        // portrait - where the two agree. Two implementations could drift arbitrarily
        // and stay green. They did.
        //
        // What this asserts instead: the class the clone ACTUALLY hands a rendered
        // widget equals the hub's answer for the same size at the same orientation,
        // over the full size × orientation cross product. The reference is the hub's
        // own WidgetSizes instance, not a literal - so if the hub's derivation
        // changes, this fails until the preview follows.
        function test_size_class_matches_the_hub_in_BOTH_orientations() {
            var c = ld.item
            var all = hubSizes.all()
            verify(all.length >= 7, "precondition: the size vocabulary is populated")

            var orientations = [
                { mode: "portrait",  landscape: false },
                { mode: "landscape", landscape: true  }
            ]
            var checked = 0
            for (var o = 0; o < orientations.length; o++) {
                for (var i = 0; i < all.length; i++) {
                    var sz = all[i]
                    // cpu declares only a subset of the vocabulary; skip what it
                    // cannot honestly render rather than asserting on a rejected set.
                    if (catalog.sizesFor("cpu").indexOf(sz) < 0) continue

                    // Order matters: `load` replaces the whole document, appearance
                    // included, so the orientation has to be set AFTER it. Setting it
                    // first silently reverted every case to portrait - which is the
                    // very answer this test exists to distinguish from, so the test
                    // would have agreed with the bug it is meant to catch.
                    store.load("blank")
                    store.setAppearance("orientation", orientations[o].mode)
                    compare(c.landscape, orientations[o].landscape,
                            orientations[o].mode + ": the clone mirrors the panel's orientation")

                    store.addTile(0, "cpu")
                    var id = tile0().id
                    store.setTileSize(0, id, sz)
                    compare(tile0().size, sz, "precondition: the store took the size " + sz)

                    // The REAL rendered widget, classed by the clone's OWN call site.
                    var w = null
                    tryVerify(function () { w = loadedWidget(id); return w !== null }, 3000,
                              orientations[o].mode + " " + sz + ": the tile's widget loaded")
                    compare(w.sizeClass, hubSizes.classFor(sz, orientations[o].landscape),
                            orientations[o].mode + " " + sz + ": preview class matches the hub")
                    checked++
                }
            }
            // Anti-vacuity: a `continue` that skipped everything would otherwise
            // report a green cross-product over zero cases.
            verify(checked >= 8, "cross product actually ran (" + checked + " cases)")
            store.load("blank")
        }

        // The same size is a DIFFERENT class per orientation - that asymmetry is the
        // whole point of a rotating panel, and it is the specific thing the hardcode
        // erased. Stated as its own case so a regression names itself.
        function test_orientation_actually_changes_the_class() {
            compare(hubSizes.classFor("1x0.5", false), "wide",  "portrait: a full-width sliver is wide")
            compare(hubSizes.classFor("1x0.5", true),  "tall",  "landscape: the SAME size is tall")
            compare(hubSizes.classFor("0.5x1", false), "tall",  "portrait: half-width is tall")
            compare(hubSizes.classFor("0.5x1", true),  "wide",  "landscape: and now it is wide")
            compare(hubSizes.classFor("bogus", false), "compact", "unknown size assumes least room")
        }

        function test_auto_orientation_matches_the_hubs_landscape_first_fallback() {
            var c = ld.item
            store.setAppearance("orientation", "auto")
            backend.hubRotation = -1
            compare(c.landscape, true,
                    "unknown Hub telemetry uses the Hub's landscape-first fallback")
            backend.hubRotation = 0
            compare(c.landscape, false, "a reported portrait rotation is mirrored")
            backend.hubRotation = 90
            compare(c.landscape, true, "a reported landscape rotation is mirrored")
            backend.hubRotation = 180
            compare(c.landscape, false, "inverted portrait remains portrait-shaped")
            backend.hubRotation = 270
            compare(c.landscape, true, "inverted landscape remains landscape-shaped")
        }

        function test_orientation_reflows_immediately_while_the_device_turns_smoothly() {
            var c = ld.item
            var screenItem = findByObjectName("cloneDashboardScreen")
            var frame = findByObjectName("cloneDeviceFrame")
            verify(screenItem !== null && frame !== null,
                   "the preview exposes its semantic screen and animated device frame")
            compare(c._shortestTurn(0, 270), -90,
                    "a turn toward 270 degrees takes the short reverse path")
            compare(c._shortestTurn(270, 0), 90,
                    "a turn back through zero takes the short forward path")

            theme.reduceMotionPreference = "off"
            store.setAppearance("orientation", "portrait")
            tryCompare(c, "orientationVisualAngle", 0, 1500,
                       "the portrait starting position settled")
            verify(screenItem.height > screenItem.width,
                   "the settled semantic layout starts portrait")

            store.setAppearance("orientation", "landscape")
            compare(c.landscape, true,
                    "the semantic orientation changes in the committing event")
            verify(screenItem.width > screenItem.height,
                   "the WYSIWYG screen reflows to landscape immediately")
            verify(Math.abs(c.orientationVisualAngle) > 1,
                   "the device presentation starts from the previous physical angle")
            verify(c.orientationTransitionRunning,
                   "the physical device turn is animated when motion is enabled")
            wait(Math.round(c.orientationTransitionDuration * 0.45))
            verify(Math.abs(c.orientationVisualAngle) > 1
                   && Math.abs(c.orientationVisualAngle) < 89,
                   "the device occupies an intermediate angle instead of snapping")
            tryCompare(c, "orientationVisualAngle", 0, 1500,
                       "the device settles upright in the new orientation")
            compare(frame.rotation, 0)

            theme.reduceMotionPreference = "auto"
        }

        function test_start_orientation_transition_reports_and_draws_a_real_turn() {
            var c = ld.item
            theme.reduceMotionPreference = "off"
            c._orientationReady = true

            compare(c._startOrientationTransition(0, 0), false,
                    "no physical turn does not start an animation")
            compare(c.orientationVisualAngle, 0,
                    "the no-op transition leaves the device upright")
            verify(!c.orientationTransitionRunning,
                   "the no-op transition leaves no animation running")

            verify(c._startOrientationTransition(0, 90),
                   "a real orientation change reports that its turn started")
            compare(c.orientationVisualAngle, 90,
                    "the drawn device starts at the previous physical angle")
            verify(c.orientationTransitionRunning,
                   "the reported transition owns a running animation")
            tryCompare(c, "orientationVisualAngle", 0, 1500,
                       "the directly started device turn settles upright")

            theme.reduceMotionPreference = "on"
            compare(c._startOrientationTransition(90, 180), false,
                    "reduced motion declines the animated transition")
            compare(c.orientationVisualAngle, 0,
                    "reduced motion keeps the drawn device upright")
            verify(!c.orientationTransitionRunning,
                   "reduced motion leaves no transition running")
            theme.reduceMotionPreference = "auto"
        }

        function test_reduce_motion_keeps_orientation_reflow_immediate_and_skips_the_turn() {
            var c = ld.item
            var screenItem = findByObjectName("cloneDashboardScreen")
            verify(screenItem !== null, "the semantic preview screen exists")

            theme.reduceMotionPreference = "off"
            store.setAppearance("orientation", "landscape")
            tryCompare(c, "orientationVisualAngle", 0, 1500,
                       "precondition: the landscape turn settled")

            theme.reduceMotionPreference = "on"
            compare(c.orientationTransitionDuration, 0,
                    "reduced motion collapses the duration token")
            store.setAppearance("orientation", "portrait")
            compare(c.landscape, false,
                    "the semantic orientation still changes immediately")
            verify(screenItem.height > screenItem.width,
                   "the WYSIWYG layout is immediately portrait")
            compare(c.orientationVisualAngle, 0,
                    "the presentation does not rotate under reduced motion")
            verify(!c.orientationTransitionRunning,
                   "no orientation animation remains active under reduced motion")

            theme.reduceMotionPreference = "auto"
        }

        // ANTI-RE-COPY. The bug was not a wrong constant, it was a SECOND copy of a
        // derivation that must have exactly one. If someone reintroduces a private
        // `sizeClassFor` on the clone, this fails immediately rather than waiting for
        // the orientations to disagree again.
        function test_the_clone_has_no_private_size_class_derivation() {
            compare(typeof ld.item.sizeClassFor, "undefined",
                    "EdgeClone must call WidgetSizes.classFor, never own a copy")
        }

        // Standard and Immersive are not just a settings label. The clone must
        // reserve exactly the same control footprint that the Hub does, then give
        // it back to the live widget viewport when Immersive is selected.
        function test_hub_controls_mode_changes_preview_geometry() {
            var c = ld.item
            store.setAppearance("orientation", "portrait")
            store.setAppearance("hubControlsMode", "standard")

            var bar = findByObjectName("cloneHubBottomBar")
            var area = findByObjectName("cloneDashboardArea")
            var screenItem = findByObjectName("cloneDashboardScreen")
            verify(bar !== null, "the preview contains the Hub control bar")
            verify(area !== null, "the preview exposes the widget viewport")
            verify(screenItem !== null, "the preview exposes the panel geometry")
            verify(c.showHubBar, "Standard mode shows the Hub controls")
            verify(bar.visible, "the control footprint is visible")
            var standardHeight = area.height

            store.setAppearance("hubControlsMode", "immersive")
            tryCompare(c, "showHubBar", false)
            verify(!bar.visible, "Immersive mode hides the Hub controls")
            verify(area.height > standardHeight, "Immersive mode gives the space back to widgets")
            fuzzyCompare(area.height - standardHeight,
                         screenItem.barHeight + screenItem.barGap, 0.01,
                         "the reclaimed space equals the real bar and layout gap")

            store.setAppearance("hubControlsMode", "standard")
            tryCompare(c, "showHubBar", true)
        }

        function test_clone_uses_hub_pixel_geometry_for_widget_breakpoints() {
            var c = ld.item
            store.setAppearance("orientation", "portrait")
            root.seed([ { type: "cpu" } ])
            var id = tile0().id
            var screenItem = findByObjectName("cloneDashboardScreen")
            compare(screenItem._shortPx, 720, "clone lays out at the Edge's real logical short axis")

            var widget = null
            tryVerify(function () { widget = loadedWidget(id); return widget !== null }, 3000,
                      "the real CPU widget loaded")
            compare(tile0().size, "1x1")
            compare(widget.sizeClass, "compact")
            verify(!widget.micro, "1x1 remains the full compact design, as on the Hub")

            store.setTileSize(0, id, "0.5x0.5")
            tryVerify(function () { return widget.micro }, 1000,
                      "the true 1/12 tile selects the micro design")
        }

        function test_host_size_class_is_live_on_size_and_rotation() {
            var c = ld.item
            store.setAppearance("orientation", "portrait")
            root.seed([ { type: "cpu" } ])
            var id = tile0().id
            var w = null
            tryVerify(function () { w = loadedWidget(id); return w !== null }, 3000)
            store.setTileSize(0, id, "1x0.5")
            compare(w.sizeClass, "wide", "portrait: a full-width sliver is wide")
            store.setAppearance("orientation", "landscape")
            compare(w.sizeClass, "tall", "and rotating the panel re-classes it in place")
            store.setAppearance("orientation", "auto")
        }

        // ── targetAt ──────────────────────────────────────────────────────────
        function test_targetAt_hits_cells_and_misses_outside() {
            var c = ld.item
            root.seed([ { type: "cpu" }, { type: "clock" } ])
            tryVerify(function () {
                var t0 = tileAtIdx(0), t1 = tileAtIdx(1)
                return t0 && t1 && t0.width > 0 && t1.width > 0
            }, 3000, "two tiles laid out")

            var t0 = tileAtIdx(0), t1 = tileAtIdx(1)
            // Delegate x/y are in the tile container's coordinate space - exactly what
            // targetAt() compares against (it reads rep.itemAt(i).x/y).
            var c0x = t0.x + t0.width / 2, c0y = t0.y + t0.height / 2
            var c1x = t1.x + t1.width / 2, c1y = t1.y + t1.height / 2
            compare(c.targetAt(c0x, c0y), 0, "centre of tile 0 hits index 0")
            compare(c.targetAt(c1x, c1y), 1, "centre of tile 1 hits index 1")
            compare(c.targetAt(-1000, -1000), -1, "far out-of-bounds hits nothing")

            // Boundary: the top-left corner is inclusive (gx >= it.x && …) → still a hit.
            compare(c.targetAt(t0.x, t0.y), 0, "the tile's top-left corner is inside (inclusive bound)")
            compare(c.targetAt(t0.x + t0.width, t0.y + t0.height), 0,
                    "the tile's bottom-right corner is inside (inclusive bound)")

            // Two 1x1 tiles are two thirds of the SCREEN, stacked along its long axis -
            // so the gap between them runs across, not down. (Under the old column grid
            // they sat side by side; the gap has simply changed axis with the layout.)
            verify(t1.y > t0.y && Math.abs(t1.x - t0.x) < 1,
                   "the second baseline tile is BELOW the first, not beside it")
            var gapY = (t0.y + t0.height + t1.y) / 2
            verify(gapY > t0.y + t0.height && gapY < t1.y, "the probe y sits in the inter-cell gap")
            compare(c.targetAt(c0x, gapY), -1, "a point in the inter-cell gap targets nothing")
        }

        // ── resize drag → snap → store.setTileSize ────────────────────────────
        // The drag is free-form; the SIZES are not. The old handler flipped a 1↔2 span
        // past a hard-coded pixel threshold; there are now seven named sizes and a
        // per-type list of which are legal, so the drag snaps to the nearest one the
        // widget actually declares.
        function test_resize_drag_grows_the_tile_to_a_bigger_declared_size() {
            root.seed([ { type: "cpu" } ])
            tryVerify(function () {
                var t = tileAtIdx(0)
                return t && t.width > 0 && resizeHandles().length === 1
            }, 3000, "single tile + its resize handle are ready")

            var id = tile0().id
            compare(tile0().size, catalog.defaultSize("cpu"), "starts at cpu's default size")
            var t0 = tileAtIdx(0)
            var startH = t0.height
            var h = resizeHandles()[0]

            // Drag the corner DOWN - along the long axis - by most of a third of the
            // screen. In the unscaled `screen` space the handler measures in.
            mousePress(h, 12, 12)
            mouseMove(h, 12, 12 + startH * 0.4)
            mouseMove(h, 12, 12 + startH * 0.5)
            mouseRelease(h, 12, 12 + startH * 0.5)

            compare(tile0().size, "1x1.5", "drag down grew it to the next size cpu declares")
            verify(catalog.supports("cpu", tile0().size), "and that size is one cpu really supports")
            verify(id.length > 0, "tile id was stable through the resize")
        }

        // THE EXTENT IS NOT EASED. A reorder now glides the tile to its new slot, but
        // the corner drag is DIRECT MANIPULATION: the previewed box has to be under the
        // cursor in the same event, not 250ms behind the hand sizing it. This is the
        // deliberate difference from the hub's Dashboard, where a resize is a discrete
        // button click and easing the extent costs nothing.
        //
        // PIN: copying the hub's animEs/animEl into EdgeClone would make this red.
        function test_resize_preview_tracks_the_cursor_instantly() {
            theme.reduceMotionPreference = "off"
            compare(theme.motionPage, 250, "precondition: easing is ON, so any lag would show")
            root.seed([ { type: "cpu" } ])
            tryVerify(function () {
                var t = tileAtIdx(0)
                return t && t.height > 0 && resizeHandles().length === 1
            }, 3000, "a cpu tile + its resize handle are ready")

            var t0 = tileAtIdx(0)
            var startH = t0.height
            var h = resizeHandles()[0]

            mousePress(h, 12, 12)
            mouseMove(h, 12, 12 + startH * 0.5)
            // Read the geometry in the SAME event as the move - before any animation
            // could have ticked.
            var immediate = t0.height
            compare(t0.pvSize, "1x1.5", "the drag snapped the preview to the next declared size")
            verify(immediate > startH + 1, "and the box really did grow on the spot")

            wait(400)   // comfortably longer than motionPage (250ms)
            compare(t0.height, immediate,
                    "the box was ALREADY at its previewed size - the extent never eased")

            mouseRelease(h, 12, 12 + startH * 0.5)
            theme.reduceMotionPreference = "auto"
        }

        // The SHRINK branch: drag the handle up-and-left and the tile snaps down.
        function test_resize_drag_shrinks_the_tile() {
            root.seed([ { type: "cpu" } ])
            var id = tile0().id
            store.setTileSize(0, id, "1x1")
            tryVerify(function () {
                var t = tileAtIdx(0)
                return t && t.width > 100 && resizeHandles().length === 1
            }, 3000, "a baseline tile + its resize handle are ready")
            compare(tile0().size, "1x1", "precondition: a full third of the screen")

            var t0 = tileAtIdx(0)
            var h = resizeHandles()[0]
            mousePress(h, 12, 12)
            mouseMove(h, 12 - t0.width * 0.3, 12 - t0.height * 0.3)
            mouseMove(h, 12 - t0.width * 0.5, 12 - t0.height * 0.5)
            mouseRelease(h, 12 - t0.width * 0.5, 12 - t0.height * 0.5)

            compare(tile0().size, "0.5x0.5", "dragging back to a quarter box snapped to the twelfth")
        }

        // THE GUARD: a drag can never produce a size the widget type does not declare.
        // `focus` needs a squarish box (its ring is min(w,h)-scaled with the Start row
        // anchored over it), so it declares only 1x1 and 1x1.5 - no half sizes at all.
        // A huge drag must stop at 1x1.5, and a tiny one must not reach 0.5x0.5.
        function test_resize_drag_never_lands_on_a_size_the_type_lacks() {
            root.seed([ { type: "focus" } ])
            compare(catalog.sizesFor("focus").join(","), "1x1,1x1.5",
                    "precondition: focus declares only two sizes")
            tryVerify(function () {
                var t = tileAtIdx(0)
                return t && t.width > 0 && resizeHandles().length === 1
            }, 3000, "the focus tile + its resize handle are ready")

            var t0 = tileAtIdx(0)
            var h = resizeHandles()[0]
            // A runaway drag down-and-right: way past the whole screen.
            mousePress(h, 12, 12)
            mouseMove(h, 12 + t0.width * 4, 12 + t0.height * 6)
            mouseRelease(h, 12 + t0.width * 4, 12 + t0.height * 6)
            compare(tile0().size, "1x1.5",
                    "a runaway drag stops at focus's largest DECLARED size - never 1x2 or 1x3")

            // …and a runaway drag inward cannot reach the half sizes it does not declare.
            t0 = tileAtIdx(0)
            h = resizeHandles()[0]
            mousePress(h, 12, 12)
            mouseMove(h, 12 - t0.width * 2, 12 - t0.height * 2)
            mouseRelease(h, 12 - t0.width * 2, 12 - t0.height * 2)
            compare(tile0().size, "1x1", "and inward it stops at 1x1 - never 0.5x0.5")
            verify(catalog.supports("focus", tile0().size), "whatever the drag, the size is one focus declares")
        }

        // A type with exactly one legal size has nothing to resize TO, so the handle is
        // not offered - a control that provably cannot do anything should not be there.
        function test_resize_handle_is_hidden_when_there_is_only_one_size() {
            root.seed([ { type: "cpu" } ])
            tryVerify(function () { return resizeHandles().length === 1 }, 3000,
                      "cpu declares several sizes, so it gets a handle")
            verify(catalog.sizesFor("cpu").length > 1, "precondition: cpu really has more than one")
        }

        // Preview mode (Appearance tab): editable=false renders the same WYSIWYG
        // clone but hides every edit affordance - drag/select overlay, ⚙/✕
        // controls, resize handle - so the preview can't become a second,
        // competing layout editor.
        function test_editable_false_hides_every_edit_affordance() {
            root.seed([ { type: "cpu" } ])
            tryVerify(function () {
                var t = tileAtIdx(0)
                return t && t.width > 0 && resizeHandles().length === 1
            }, 3000, "an editable tile with its handle is ready")
            var c = ld.item
            verify(c.editable, "clone starts editable (Layout-tab default)")

            c.editable = false
            // The drag/select overlay (the MouseArea carrying `dragging`).
            var overlays = findAll(ld.item, function (x) {
                return x && x.dragging !== undefined && typeof x.pressed === "boolean"
            })
            verify(overlays.length > 0, "found the drag/select overlay")
            for (var i = 0; i < overlays.length; i++)
                verify(!overlays[i].visible, "drag/select overlay hidden in preview mode")
            // The ⚙/✕ controls row (the z:5 Row on each tile).
            var rows = findAll(ld.item, function (x) {
                return x && x.z === 5 && x.spacing !== undefined
            })
            verify(rows.length > 0, "found the tile controls row")
            for (var r = 0; r < rows.length; r++)
                verify(!rows[r].visible, "⚙/✕ controls hidden in preview mode")
            // The resize handle (its parent Rectangle owns the visible flag).
            verify(!resizeHandles()[0].parent.visible, "resize handle hidden in preview mode")

            c.editable = true   // restore the shared Loader for the other tests
            verify(resizeHandles()[0].parent.visible, "handle returns when editable again")
        }
    }
}
