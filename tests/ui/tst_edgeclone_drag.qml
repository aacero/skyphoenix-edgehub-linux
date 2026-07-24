import QtQuick
import QtTest
import "../../ui/qml" as App

// COVERS: fn:EdgeClone._row, fn:EdgeClone._syncPlacements, fn:EdgeClone._reapRow
//
// REGRESSION 1: the floating drag "name-tag" must NOT stay stuck after a
// drag-and-drop reorder in manager/qml/EdgeClone.qml.
//
// The bug: on drop, EdgeClone reset its drag state (clone.dragIdx = -1) AFTER
// calling store.moveTile(...). moveTile reorders the model, which can destroy the
// dragged delegate and its still-running onReleased handler, so the reset never
// executed and the floating name-tag (the z:100 Rectangle whose `visible` binding
// tracks clone.dragIdx) stayed stranded on screen.
//
// The fix: onReleased now clears ma.dragging=false / clone.dragIdx=-1 /
// clone.targetIdx=-1 BEFORE calling store.moveTile.
//
// REGRESSION 2 (below): a reorder TELEPORTED the tile. `model: clone.placements`
// handed the Repeater a fresh JS array on every re-pack, which resets its whole
// delegate model - so the tile that should have travelled was destroyed and a new
// one appeared already at the destination. Proven before the fix: the identity
// guard failed. The Repeater now takes a ListModel synced by id.
//
// EdgeClone resolves store/catalog/theme/media/backend from the Manager scope; we
// provide them on this wrapper (backend is a light stub, copied from tst_manager)
// and load the REAL EdgeClone.qml via a Loader - exactly as tst_edgeclone.qml does.
Item {
    id: root
    width: 560; height: 860

    App.Theme { id: theme }
    App.DashboardStore { id: store }
    App.WidgetCatalog { id: catalog }
    MockMedia { id: media }

    QtObject {
        id: backend
        property bool hubConnected: false
        function imageUrl(n) { return "file:///imgs/" + n }
        function metricsJson() { return "{}" }
    }

    Loader {
        id: ld
        anchors.fill: parent
        source: "../../manager/qml/EdgeClone.qml"
        onLoaded: if (item) item.pageIndex = 0
    }

    // ── tree helpers (same shape as tst_edgeclone / tst_manager) ──────────────
    function eachItem(node, fn) {
        if (!node) return
        fn(node)
        var kids = node.children
        if (kids) for (var i = 0; i < kids.length; i++) eachItem(kids[i], fn)
    }
    function findPred(n, pred) {
        var f = null
        eachItem(n, function (x) { if (!f && pred(x)) f = x })
        return f
    }
    function findAll(n, pred) {
        var out = []
        eachItem(n, function (x) { if (pred(x)) out.push(x) })
        return out
    }

    function tileDelegates() {
        return findAll(ld.item, function (x) {
            return x && x.effSize !== undefined && x.pvSize !== undefined && x.tileId !== undefined
        })
    }
    // Keyed on the STORE tile index the delegate carries - deliberately not on the
    // Repeater's row number. Rows are patched in place by _syncPlacements, so after a
    // reorder row order is no longer tile order; a helper that assumed otherwise
    // would quietly hand back the wrong tile.
    //
    // Ghosts are skipped for the SAME reason EdgeClone.targetAt skips them: a removal
    // shifts every later store index down, and a dying row is not in that packing any
    // more, so its `tileIdx` is stale. Looking a tile up BY the index death
    // invalidates has to ignore the dead - this helper handed back a ghost of an
    // earlier test's tile until it did.
    function tileAtIdx(i) {
        var ds = tileDelegates()
        for (var k = 0; k < ds.length; k++) if (!ds[k].dying && ds[k].tileIdx === i) return ds[k]
        return null
    }
    // By id, ghosts INCLUDED: an id is stable across a removal, so this is how a test
    // gets hold of a fading tile at all.
    function tileById(id) {
        var ds = tileDelegates()
        for (var k = 0; k < ds.length; k++) if (ds[k].tileId === id) return ds[k]
        return null
    }
    // The drag/select overlay MouseArea (`ma`) carries `dragging`; the resize-handle
    // MouseArea does not - so `dragging !== undefined` disambiguates them.
    function dragMA(i) {
        var t = tileAtIdx(i)
        if (!t) return null
        return findPred(t, function (x) { return x && x.dragging !== undefined && x.sx !== undefined })
    }
    // The floating name-tag: the only z:100 Rectangle in EdgeClone.
    function nameTag() {
        return findPred(ld.item, function (x) { return x && x.z === 100 && x.radius !== undefined })
    }
    function tileIds() {
        var ts = store.pages()[0].tiles
        return ts.map(function (t) { return t.id })
    }

    function seed3() {
        store.load("blank")
        store.addTile(0, "cpu")
        store.addTile(0, "clock")
        store.addTile(0, "focus")
    }
    // Two 1x1 tiles = 4 of the 6 long half-cells, leaving room for exactly one more
    // (a page is one screen now - addTile refuses once it is full, so the add-a-tile
    // tests must start from a page that still has room).
    function seed2() {
        store.load("blank")
        store.addTile(0, "cpu")
        store.addTile(0, "clock")
    }

    TestCase {
        name: "EdgeCloneDrag"
        when: windowShown

        function initTestCase() {
            tryVerify(function () { return ld.status === Loader.Ready && ld.item !== null }, 5000)
        }

        // Drag tile 0 onto tile 2 → reorder commits AND the name-tag is cleared on
        // drop. This is the exact regression: pre-fix the name-tag stayed visible
        // because the reset ran after moveTile destroyed the dragged delegate.
        function test_drag_reorders_and_clears_nametag() {
            seed3()
            tryVerify(function () {
                var t0 = tileAtIdx(0), t2 = tileAtIdx(2)
                return t0 && t2 && t0.width > 0 && t2.width > 0 && dragMA(0) !== null
            }, 4000, "three tiles laid out with a drag MouseArea on tile 0")

            var tag = nameTag()
            verify(tag, "found the floating name-tag (z:100)")
            verify(!tag.visible, "name-tag hidden before any drag")

            var before = tileIds()
            compare(before.length, 3, "seeded three tiles")
            var movedId = before[0]                       // the tile we will drag away from index 0
            var draggedType = store.pages()[0].tiles[0].type

            var t0 = tileAtIdx(0), t2 = tileAtIdx(2)
            var ma = dragMA(0)

            // Press near tile-0 centre (in the MouseArea's local space, which shares
            // tile-0's origin - the overlay is anchors.fill).
            var px = t0.width / 2, py = t0.height / 2
            // A point that maps (tile-0 local → grid) onto tile-2's centre, so the
            // handler's targetAt() reports index 2 (grid coords are what it compares).
            var overX = (t2.x + t2.width / 2) - t0.x
            var overY = (t2.y + t2.height / 2) - t0.y

            mousePress(ma, px, py)
            mouseMove(ma, px + 20, py + 20)               // cross the 8px threshold → dragging starts
            mouseMove(ma, overX, overY)                   // hover over tile 2

            // ── during the drag: state is live and the name-tag is showing ──
            compare(ld.item.dragIdx, 0, "dragIdx tracks the dragged tile (0) mid-drag")
            verify(nameTag().visible, "the floating name-tag is visible during the drag")
            var tagText = findPred(nameTag(), function (x) {
                return x && typeof x.text === "string" && x.text.length > 0 })
            verify(tagText, "the name-tag hosts a title Text")
            compare(tagText.text, catalog.title(draggedType),
                    "the name-tag shows the dragged tile's title")
            compare(ld.item.targetIdx, 2, "the drop target resolved to tile 2")

            mouseRelease(ma, overX, overY)

            // ── after drop: the REGRESSION - drag state cleared, name-tag hidden ──
            tryVerify(function () { return ld.item.dragIdx === -1 }, 2000,
                      "dragIdx reset to -1 on drop")
            compare(ld.item.targetIdx, -1, "targetIdx reset to -1 on drop")
            tryVerify(function () { return nameTag().visible === false }, 2000,
                      "BUG GUARD: the floating name-tag is hidden after drop (not stuck on screen)")

            // ── the reorder actually happened: index-0 tile moved later ──
            var after = tileIds()
            compare(after.length, 3, "no tile lost in the reorder")
            verify(after.indexOf(movedId) > 0,
                   "the tile that started at index 0 is now later in page-0 order")
            compare(after[after.length - 1], movedId,
                    "moveTile(0,0,2) placed the dragged tile at the end")
        }

        // ── REGRESSION 2: a reorder MOVES the tile, it does not rebuild it ──────
        // Three 1x1 tiles stack down the clone's long axis at l = 0, 2, 4.
        //
        // "Laid out" has to mean SETTLED, not merely "has geometry". Tiles now ARRIVE
        // (they fade in) and ghosts now LINGER (they fade out), and this suite shares
        // one Loader across every test, so a probe that only waited for width > 0
        // handed tests a page that was still moving: a tile measured mid-entrance was
        // at lifeOpacity 0, and the previous test's ghosts - killed by seed3's
        // store.load("blank") - were still on screen being counted. Both bit for real
        // before this waited properly. So: exactly three tiles, no ghost, all whole.
        function _laidOut3() {
            seed3()
            tryVerify(function () {
                if (tileDelegates().length !== 3) return false      // no ghost still fading
                for (var i = 0; i < 3; i++) {
                    var t = tileAtIdx(i)
                    if (!t || t.width <= 0) return false
                    if (t.dying || t.lifeOpacity !== 1) return false   // entrance has landed
                }
                return true
            }, 4000, "three tiles laid out, settled and whole")
        }
        function _laidOut2() {
            seed2()
            tryVerify(function () {
                if (tileDelegates().length !== 2) return false
                for (var i = 0; i < 2; i++) {
                    var t = tileAtIdx(i)
                    if (!t || t.width <= 0 || t.dying || t.lifeOpacity !== 1) return false
                }
                return true
            }, 4000, "two tiles laid out, settled and whole")
        }

        // The two halves of the sync asserted directly: `_row` maps one packer
        // placement onto the model's roles, and `_syncPlacements` reconciles the whole
        // model to the current packing - idempotently, because the rows ARE the
        // delegates' identity, so re-running it must churn nothing.
        function test_placement_row_and_sync_map_the_packing_onto_the_model() {
            _laidOut3()
            var c = ld.item
            var placement = { id: "z", type: "cpu", size: "1x1", idx: 2, s: 0, l: 4 }
            compare(c._row(placement).tileId, "z", "_row carries the tile id")
            compare(c._row(placement).tileType, "cpu", "_row carries the type")
            compare(c._row(placement).tileSize, "1x1", "_row carries the size")
            compare(c._row(placement).tileIdx, 2, "_row carries the STORE tile index, not a row number")
            var r = c._row(placement)
            compare(r.ps + "," + r.pl, "0,4", "_row carries the semantic origin")
            // The role types a ListModel fixes on first append: a typeless tile must
            // seed "" (what wsrc/catalog.title already treat as "no such type"), not
            // `undefined`.
            compare(c._row({ id: "q", idx: 0, s: 0, l: 0 }).tileType, "",
                    "a missing type is coerced to \"\", never undefined")

            var a = tileAtIdx(0)
            compare(c._syncPlacements(), 3, "_syncPlacements holds one row per placed tile")
            compare(c._syncPlacements(), 3, "_syncPlacements is idempotent - no duplicate rows")
            verify(tileAtIdx(0) === a, "and it rebuilt nothing: same delegate after two syncs")
        }

        // THE TELEPORT GUARD. Pre-fix this failed: `model: clone.placements` handed the
        // Repeater a fresh array, which reset the whole delegate model.
        function test_reorder_moves_the_same_delegate_instead_of_rebuilding_it() {
            theme.reduceMotionPreference = "off"
            _laidOut3()
            var ids = tileIds()
            var a = tileById(ids[0]), b = tileById(ids[1]), c = tileById(ids[2])
            verify(a && b && c, "all three delegates found")
            compare(b.pl, 2, "precondition: b is the second tile down the long axis")
            // b's widget Loader - the object that OWNS the widget instance's lifetime.
            // (The widget itself cannot be asserted on here: every catalog source is a
            // `qrc:` path and this harness has no compiled resources, so no tile widget
            // ever instantiates offscreen. The Loader surviving with an unchanged `wId`
            // is exactly the condition under which its widget survives - a reload needs
            // either the Loader destroyed or its source key changed.)
            var bLoader = findPred(b, function (x) { return x && x.wId === ids[1] })
            verify(bLoader !== null, "found b's widget Loader")

            store.moveTile(0, 1, 0)
            tryVerify(function () { return tileById(ids[1]).pl === 0 }, 4000,
                      "b's placement moved to the first slot")

            // IDENTITY: a rebuilt delegate would be a different object.
            verify(tileById(ids[1]) === b, "b's tile is the SAME object after the reorder")
            verify(tileById(ids[0]) === a, "a's tile is the SAME object after the reorder")
            verify(tileById(ids[2]) === c, "the untouched tile c is the SAME object too")
            var bLoader2 = findPred(tileById(ids[1]), function (x) { return x && x.wId === ids[1] })
            verify(bLoader2 === bLoader, "b's Loader is the SAME object - its widget was never torn down")
            compare(bLoader2.wId, ids[1], "and its source key never changed, so it never reloaded")
            compare(tileDelegates().length, 3, "still exactly three tiles")
            compare(tileById(ids[1]).tileIdx, 0, "b's store index tracked the reorder")
        }

        // A move EASES: the surviving delegate leaves its old pixels behind gradually.
        // (The eye can only follow a tile it can see travelling - that is the fix.)
        function test_reorder_eases_the_tile_to_its_new_slot() {
            theme.reduceMotionPreference = "off"
            compare(theme.motionPage, 250, "precondition: move easing enabled")
            _laidOut3()
            var ids = tileIds()
            var b = tileById(ids[1])
            var startY = b.y
            compare(b.animL, 2, "precondition: b's eased mirror sits at its real slot")

            store.moveTile(0, 1, 0)

            // Frame 0: the TARGET slot is already the new one, but the eased mirror -
            // and therefore the pixels - have not jumped.
            compare(b.pl, 0, "b's target slot updated immediately")
            verify(b.animL > 0, "but it has NOT teleported: the eased mirror is still en route")
            fuzzyCompare(b.y, startY, 1.0, "and its pixels are still at the old slot on frame 0")

            // …and it does arrive.
            tryVerify(function () { return b.animL === 0 }, 4000, "the eased mirror lands on the new slot")
            verify(b.y < startY - 1, "b ended up further up the page than it started")
        }

        // REDUCE MOTION: smooth is not more motion. The move must be INSTANT - not a
        // 0ms animation that still lands a frame late.
        function test_reduce_motion_makes_a_reorder_instant() {
            theme.reduceMotionPreference = "on"
            compare(theme.motionPage, 0, "precondition: reduce-motion collapses the move token")
            _laidOut3()
            var ids = tileIds()
            var b = tileById(ids[1])
            var startY = b.y

            store.moveTile(0, 1, 0)

            // No tryVerify: with the Behavior disabled the write is direct, so the new
            // slot is already in the pixels on this very line.
            compare(b.pl, 0, "b's target slot updated")
            compare(b.animL, 0, "and the mirror is ALREADY there - no animation ran")
            verify(b.y < startY - 1, "b's pixels moved instantly, in the same event")
            verify(tileById(ids[1]) === b, "instant, but still the same delegate - not a rebuild")
            theme.reduceMotionPreference = "auto"
        }

        // ADD / REMOVE reuse the same machinery: survivors are moved, not rebuilt.
        function test_add_and_remove_keep_the_surviving_delegates() {
            theme.reduceMotionPreference = "off"
            _laidOut3()
            var ids = tileIds()
            var a = tileById(ids[0]), c = tileById(ids[2])

            // Remove the MIDDLE tile - c must slide up, not be reborn there.
            store.removeTile(0, ids[1])
            tryVerify(function () { return tileDelegates().length === 2 }, 4000, "b's tile is gone")
            verify(tileById(ids[1]) === null, "b really is removed")
            verify(tileById(ids[0]) === a, "a survived the removal")
            verify(tileById(ids[2]) === c, "c MOVED into the freed slot - same object, not a rebuild")
            tryVerify(function () { return tileById(ids[2]).pl === 2 }, 4000, "c's placement closed the gap")

            store.addTile(0, "disk")
            tryVerify(function () { return tileDelegates().length === 3 }, 4000, "the new tile is placed")
            verify(tileById(ids[0]) === a, "a survived the add")
            verify(tileById(ids[2]) === c, "and so did c")
        }

        // THE ROW-ORDER GUARD, and the reason `targetAt` reports a tileIdx rather than
        // a row number. _syncPlacements patches rows IN PLACE, so after one reorder row
        // order is no longer tile order. Any code that read `placements[rowNumber]`
        // would now address the wrong tile - silently, and only after the first drag.
        // So: reorder once to desynchronise the rows, then drag and check the RIGHT
        // tile moved.
        function test_a_second_drag_is_correct_after_rows_stop_matching_tile_order() {
            theme.reduceMotionPreference = "on"   // no in-flight geometry to hit-test
            _laidOut3()
            store.moveTile(0, 2, 0)               // rows now disagree with tile order
            tryVerify(function () { return tileAtIdx(0) && tileAtIdx(0).pl === 0 }, 4000,
                      "the page re-packed after the priming reorder")

            // PRECONDITION - without this the test would pass vacuously on the old
            // row==tile assumption and prove nothing.
            var rows = tileDelegates().map(function (d) { return d.tileIdx })
            verify(rows.join(",") !== "0,1,2",
                   "precondition: Repeater row order really is NOT tile order any more")

            var ids = tileIds()
            var t0 = tileAtIdx(0), t2 = tileAtIdx(2)
            var ma = dragMA(0)
            verify(t0 && t2 && ma, "the tile now at store index 0 has a drag overlay")
            var movedId = ids[0]

            var px = t0.width / 2, py = t0.height / 2
            var overX = (t2.x + t2.width / 2) - t0.x
            var overY = (t2.y + t2.height / 2) - t0.y
            mousePress(ma, px, py)
            mouseMove(ma, px + 20, py + 20)
            mouseMove(ma, overX, overY)
            compare(ld.item.dragIdx, 0, "the drag reports the STORE index of the held tile")
            compare(ld.item.targetIdx, 2, "and the drop target resolves to store index 2")
            mouseRelease(ma, overX, overY)

            var after = tileIds()
            compare(after.length, 3, "no tile lost")
            compare(after[2], movedId, "the tile that was at store index 0 landed at index 2")
            theme.reduceMotionPreference = "auto"
        }

        // ── THE POP GUARD ───────────────────────────────────────────────────────
        // PREMISE CHECK, run RED before the fix: a removed tile vanished in the same
        // event the store dropped it, while its neighbours glided into the space it
        // left - the only motion on screen belonged to everything EXCEPT the thing
        // the user had just acted on. Its delegate must now OUTLIVE the packing that
        // dropped it, so there is something left to fade.
        function test_a_removed_tile_fades_out_instead_of_popping() {
            theme.reduceMotionPreference = "off"
            compare(theme.motionRemove, 150, "precondition: the exit token is live")
            _laidOut3()
            var ids = tileIds()
            var b = tileById(ids[1])
            verify(b, "precondition: b has a delegate")

            store.removeTile(0, ids[1])

            // Frame 0: the store has let the tile go, but the GHOST is still on screen
            // and still fully opaque - nothing has popped.
            var ghost = tileById(ids[1])
            verify(ghost === b, "the delegate OUTLIVED its removal - same object, not gone")
            verify(ghost.dying, "and it knows it is dying")
            compare(ghost.lifeOpacity, 1.0, "the fade starts from fully visible, so the eye can follow it out")

            // …it really is a fade, not a delayed pop: partway through it is partway out.
            tryVerify(function () {
                var g = tileById(ids[1])
                return g === null || (g.lifeOpacity > 0.01 && g.lifeOpacity < 0.99)
            }, 1000, "the ghost is observed mid-fade, between fully opaque and gone")

            // …and it reaps itself: the row does not leak.
            tryVerify(function () { return tileById(ids[1]) === null }, 2000,
                      "the ghost reaped its own row when the fade ended")
            compare(tileDelegates().length, 2, "no leaked rows: exactly the two survivors remain")
            theme.reduceMotionPreference = "auto"
        }

        // A ghost is not a tile. It must not answer a tap or offer edit chrome for a
        // tile the store has already let go.
        function test_a_ghost_offers_no_chrome_for_a_tile_the_store_dropped() {
            theme.reduceMotionPreference = "off"
            _laidOut3()
            var ids = tileIds()
            store.removeTile(0, ids[1])

            var ghost = tileById(ids[1])
            verify(ghost, "precondition: the ghost is still on screen")
            verify(!ghost.enabled, "the ghost is disabled: no ⚙, no ✕, no drag, no tap")
            theme.reduceMotionPreference = "auto"
        }

        // REDUCE MOTION: the DURATION TOKEN does the work, not a gate. A removal must
        // be INSTANT - gone in the same event, not a 0ms fade that still lands late.
        function test_reduce_motion_removes_a_tile_instantly() {
            theme.reduceMotionPreference = "on"
            compare(theme.motionRemove, 0, "precondition: reduce-motion collapses the exit token")
            _laidOut3()
            var ids = tileIds()

            store.removeTile(0, ids[1])

            // No tryVerify: the row is already gone on this very line.
            compare(tileById(ids[1]), null, "the tile is gone in the same event - no ghost, no fade")
            compare(tileDelegates().length, 2, "and the two survivors are all that is left")
            theme.reduceMotionPreference = "auto"
        }

        // RESURRECTION. An id removed and re-added inside the fade window (an undo, a
        // live push from the hub) reuses its row: the tile EXISTS, so it must not
        // vanish when a fade nobody is watching any more happens to finish.
        function test_a_tile_re_added_inside_its_own_fade_survives() {
            theme.reduceMotionPreference = "off"
            _laidOut3()
            var ids = tileIds()
            var b = tileById(ids[1])
            // The document as it stands WITH b - exactly what an undo would restore.
            var withB = JSON.stringify(store.document)

            store.removeTile(0, ids[1])
            verify(tileById(ids[1]) === b, "precondition: the ghost is mid-fade")
            verify(b.dying, "precondition: and marked dying")

            // Re-add the SAME id inside the 150ms window (what an undo/live-push does).
            store.applyExternal(withB)
            tryVerify(function () {
                var t = tileById(ids[1]); return t && !t.dying
            }, 1000, "the resurrected row is live again, not dying")

            // The fade's own duration has now comfortably elapsed - the tile must still
            // be here and whole.
            wait(400)
            var back = tileById(ids[1])
            verify(back !== null, "the resurrected tile did NOT vanish when the stale fade ended")
            compare(back.lifeOpacity, 1.0, "and it is whole again, not left half-faded")
            theme.reduceMotionPreference = "auto"
        }

        // _reapRow closes the row a fade opened - it is NOT a general-purpose delete,
        // which is what makes a resurrected row safe from its own stale animation.
        // Pinned on a LIVE row on purpose: asserted on an unknown id instead, this
        // would pass with the `dying` recheck deleted and prove nothing.
        function test_reapRow_refuses_to_reap_a_live_row() {
            theme.reduceMotionPreference = "off"
            _laidOut3()
            var ids = tileIds()
            var b = tileById(ids[1])
            verify(b && !b.dying, "precondition: b is live, not dying")

            compare(ld.item._reapRow(ids[1]), false,
                    "a LIVE row is refused: reaping is a fade closing its own row, not a delete")
            verify(tileById(ids[1]) === b, "and b is untouched, same object, still on screen")
            compare(ld.item._reapRow("no-such-tile"), false, "an unknown id reaps nothing")
            compare(tileDelegates().length, 3, "nothing was reaped")
            theme.reduceMotionPreference = "auto"
        }

        // THE ENTRANCE. An added tile is the one thing on screen the user just asked
        // for, so it arrives in its own right instead of merely already being there.
        function test_an_added_tile_fades_in_at_its_slot() {
            theme.reduceMotionPreference = "off"
            compare(theme.motionAdd, 200, "precondition: the entrance token is live")
            _laidOut2()   // room for one more (a full page refuses the add now)

            store.addTile(0, "disk")
            tryVerify(function () { return tileAtIdx(2) !== null }, 4000, "the new tile got a delegate")
            var t = tileAtIdx(2)
            // It fades in AT its slot: the packer put it where it belongs, so there is
            // no truthful place to fly in from.
            compare(t.animL, t.pl, "it is born AT its slot - it does not fly in from anywhere")
            verify(t.lifeOpacity < 1.0, "and it is arriving, not simply already there")
            tryVerify(function () { return tileAtIdx(2) && tileAtIdx(2).lifeOpacity === 1.0 }, 2000,
                      "the entrance completes")
            theme.reduceMotionPreference = "auto"
        }

        // REDUCE MOTION, the entrance half: an added tile is simply THERE, whole, in
        // the same event. (The exit half is test_reduce_motion_removes_a_tile_instantly.)
        function test_reduce_motion_adds_a_tile_instantly() {
            theme.reduceMotionPreference = "on"
            compare(theme.motionAdd, 0, "precondition: reduce-motion collapses the entrance token")
            _laidOut2()   // room for one more

            store.addTile(0, "disk")
            tryVerify(function () { return tileAtIdx(2) !== null }, 4000, "the new tile is placed")
            compare(tileAtIdx(2).lifeOpacity, 1.0,
                    "it is whole immediately - no entrance ran, not even a 0ms one")
            theme.reduceMotionPreference = "auto"
        }

        // OPACITY HAS TWO OWNERS. A tile being dragged is held at 0.3; a tile coming or
        // going is faded. Those are independent facts, and an animation ASSIGNS a
        // property - so a fade that wrote `opacity` directly (the hub's shape, where
        // opacity means only one thing) would destroy the drag's binding for the rest
        // of the delegate's life. This drags a tile that has ALREADY animated.
        function test_a_tile_that_has_faded_in_still_dims_when_dragged() {
            theme.reduceMotionPreference = "off"
            _laidOut2()   // room for one more

            // Add a tile and let its ENTRANCE run to completion - an animation has now
            // owned this delegate's fade property.
            store.addTile(0, "disk")
            tryVerify(function () {
                var t = tileAtIdx(2); return t && t.lifeOpacity === 1.0 && t.width > 0
            }, 4000, "the new tile arrived and its entrance finished")

            var t3 = tileAtIdx(2)
            compare(t3.opacity, 1.0, "precondition: settled and fully opaque")
            var ma = dragMA(2)
            verify(ma, "the new tile has a drag overlay")
            mousePress(ma, t3.width / 2, t3.height / 2)
            mouseMove(ma, t3.width / 2 + 20, t3.height / 2 + 20)

            compare(ld.item.dragIdx, 2, "precondition: the drag is live on the new tile")
            compare(t3.opacity, 0.3,
                    "the drag still dims it: the entrance never clobbered the drag binding")
            mouseRelease(ma, t3.width / 2 + 20, t3.height / 2 + 20)
            theme.reduceMotionPreference = "auto"
        }

        // …but the tiles a page is BORN with are its starting state, not an add. Nothing
        // may fade in just because the clone was shown a page.
        function test_switching_page_is_not_an_add_and_not_a_remove() {
            theme.reduceMotionPreference = "off"
            store.load("blank")
            store.addTile(0, "cpu")
            store.addPage("")
            store.addTile(1, "clock")
            ld.item.pageIndex = 0
            tryVerify(function () { return tileDelegates().length === 1 }, 4000, "page 0 shows its one tile")

            ld.item.pageIndex = 1
            // Frame 0 after the switch: page 1's tile is simply THERE, and page 0's tile
            // is simply GONE. A page switch is not an edit - the user asked to look
            // somewhere else, and neither set is being added or removed.
            compare(tileDelegates().length, 1, "exactly one tile: no ghost of page 0 lingering")
            var t = tileDelegates()[0]
            compare(t.tileId, store.pages()[1].tiles[0].id, "and it is page 1's tile")
            verify(!t.dying, "page 0's row was not left dying on page 1")
            compare(t.lifeOpacity, 1.0, "page 1's tile did not fade IN - it was already there to look at")

            ld.item.pageIndex = 0
            theme.reduceMotionPreference = "auto"
        }

        // THE GHOST/TARGET MAPPING GUARD. `targetAt` reports a STORE tile index, and a
        // removal SHIFTS every later store index down. A dying row keeps its old
        // `tileIdx`, so a ghost that answered a hit-test would report an index that now
        // addresses a DIFFERENT tile - a drop onto empty air would silently move the
        // wrong widget. A ghost is not a drop target.
        function test_a_fading_ghost_is_not_a_drop_target() {
            theme.reduceMotionPreference = "off"
            _laidOut3()
            var ids = tileIds()
            var b = tileById(ids[1])
            var gx = b.x + b.width / 2, gy = b.y + b.height / 2
            compare(ld.item.targetAt(gx, gy), 1, "precondition: b's box hit-tests to store index 1")

            store.removeTile(0, ids[1])
            var ghost = tileById(ids[1])
            verify(ghost && ghost.dying, "precondition: the ghost is still occupying those pixels")
            compare(ghost.tileIdx, 1, "precondition: and still carries its now-STALE store index 1")
            // Store index 1 is now tile c - hit-testing the ghost's pixels must never
            // report it.
            compare(ld.item.targetAt(gx, gy), -1,
                    "the ghost's pixels target NOTHING: it is not a tile any more")
            theme.reduceMotionPreference = "auto"
        }

        // A FADE MUST NOT FIGHT A DRAG. The drop path already clears dragIdx before
        // moveTile, so a drop can never race its own re-pack. The other way in is a
        // removal from OUTSIDE (a live push, the ✕ on a second clone): the tile being
        // held is deleted mid-drag. Its ghost is `enabled: false`, so the MouseArea's
        // grab dies with it and onReleased never runs - which is exactly how the
        // stranded name-tag (REGRESSION 1, above) came back. So a tile that dies while
        // it is being dragged ends the drag itself.
        function test_removing_the_dragged_tile_mid_drag_ends_the_drag() {
            theme.reduceMotionPreference = "off"
            _laidOut3()
            var ids = tileIds()
            var t0 = tileAtIdx(0)
            var ma = dragMA(0)
            var px = t0.width / 2, py = t0.height / 2

            mousePress(ma, px, py)
            mouseMove(ma, px + 20, py + 20)
            compare(ld.item.dragIdx, 0, "precondition: a drag is live on tile 0")
            verify(nameTag().visible, "precondition: the name-tag is showing")

            // The tile in the user's hand is deleted out from under them.
            store.removeTile(0, ids[0])

            compare(ld.item.dragIdx, -1, "the drag ended with the tile it was holding")
            compare(ld.item.targetIdx, -1, "and the drop target was cleared with it")
            verify(!nameTag().visible, "BUG GUARD: the name-tag is not stranded on screen")
            mouseRelease(ma, px + 20, py + 20)
            theme.reduceMotionPreference = "auto"
        }

        // A press with movement UNDER the 8px threshold is a click, not a drag:
        // no reorder, and the name-tag never appears.
        function test_subthreshold_is_click_no_reorder() {
            seed3()
            tryVerify(function () {
                var t0 = tileAtIdx(0)
                return t0 && t0.width > 0 && dragMA(0) !== null
            }, 4000, "tiles laid out with a drag MouseArea on tile 0")

            var spy = configSpy
            spy.clear()
            var before = tileIds()
            var t0 = tileAtIdx(0)
            var ma = dragMA(0)
            var px = t0.width / 2, py = t0.height / 2

            mousePress(ma, px, py)
            mouseMove(ma, px + 3, py + 3)                 // 3px - below the 8px threshold
            mouseMove(ma, px + 5, py + 2)                 // still under threshold
            // never entered a drag → name-tag must stay hidden
            compare(ld.item.dragIdx, -1, "no drag started for a sub-threshold move")
            verify(!nameTag().visible, "the name-tag never shows for a click")
            mouseRelease(ma, px + 5, py + 2)

            compare(ld.item.dragIdx, -1, "still no drag after release")
            verify(!nameTag().visible, "name-tag stays hidden after a click release")
            compare(spy.count, 1, "the sub-threshold release was treated as a configure click")

            var after = tileIds()
            compare(after.length, before.length, "tile count unchanged")
            for (var i = 0; i < before.length; i++)
                compare(after[i], before[i], "tile order unchanged by a click at index " + i)
        }
    }

    // Catches EdgeClone.configRequested so the sub-threshold test can prove the
    // release was handled as a click (the else branch of onReleased).
    SignalSpy {
        id: configSpy
        target: ld.item
        signalName: "configRequested"
    }
}
