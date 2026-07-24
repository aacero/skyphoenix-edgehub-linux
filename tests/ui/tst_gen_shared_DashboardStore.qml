import QtQuick
import QtTest
import "../../ui/qml" as App

// COVERS: fn:DashboardStore._bucket, fn:DashboardStore._clone, fn:DashboardStore._commitStructure, fn:DashboardStore._flush, fn:DashboardStore._hasBridge, fn:DashboardStore._isEphemeralKey
// COVERS: fn:DashboardStore._mk, fn:DashboardStore._newId, fn:DashboardStore._normaliseDoc, fn:DashboardStore._page, fn:DashboardStore._persistableData, fn:DashboardStore._touchSettings
// COVERS: fn:DashboardStore._uniquePageName, fn:DashboardStore.addPage, fn:DashboardStore.addTile, fn:DashboardStore.appearance, fn:DashboardStore.applyExternal, fn:DashboardStore.ensureSettings
// COVERS: fn:DashboardStore.flushNow, fn:DashboardStore.load, fn:DashboardStore.moveTile, fn:DashboardStore.pageBackground, fn:DashboardStore.pageCount
// COVERS: fn:DashboardStore.pages, fn:DashboardStore.patchSettings, fn:DashboardStore.removePage, fn:DashboardStore.removeTile, fn:DashboardStore.renamePage, fn:DashboardStore.resetSettings
// COVERS: fn:DashboardStore.resetTo, fn:DashboardStore.seed, fn:DashboardStore.setAppearance, fn:DashboardStore.setPageBackground, fn:DashboardStore.setSetting
// COVERS: fn:DashboardStore.setTileSize, fn:DashboardStore.settingsFor

// ─────────────────────────────────────────────────────────────────────────
// Comprehensive coverage for the shared area  ui/qml/DashboardStore.qml.
//
// The store resolves the C++ `configBridge` global by UNQUALIFIED name via the
// QML scope chain (exactly as a widget resolves `theme`/`store`/`media` off the
// WidgetHarness). So we expose a mock `configBridge` as a property on this
// document's root object; the store's _hasBridge()/_flush()/load() then talk to
// it and we can observe every save + control every load.
//
// Tests marked "(BUG)" encode the behaviour the audit says the store SHOULD
// have; they FAIL against the current code and the failure is the finding.
// Tests marked "(OK)" pin down correct behaviour and are expected to pass.
// ─────────────────────────────────────────────────────────────────────────
Item {
    id: root
    width: 100; height: 100

    // Mock persistence bridge, resolved by the store as the `configBridge` global.
    QtObject {
        id: _bridge
        property string stored: ""     // what uiState() will return (prior saved doc)
        property int    saveCount: 0   // number of saveUiState() calls
        property string lastJson: ""   // JSON of the most recent save
        function saveUiState(json) { lastJson = json; stored = json; saveCount++ }
        function uiState() { return stored }
        function reset() { stored = ""; saveCount = 0; lastJson = "" }
    }
    property var configBridge: _bridge

    App.DashboardStore { id: store }

    // Helper: build a stored doc string.
    function docStr(o) { return JSON.stringify(o) }

    // ── 0. Mock wiring sanity ───────────────────────────────────────────────
    TestCase {
        name: "StoreBridgeWiring"
        when: windowShown

        // (OK) The store must actually see the injected configBridge; if this
        // fails, every bridge-observing test below is meaningless.
        function test_bridge_is_reachable() {
            _bridge.reset()
            store.load("blank")   // stored=="" ⇒ seed path ⇒ immediate _flush()
            verify(_bridge.saveCount >= 1, "seed-on-load flushes through the mock bridge (bridge reachable)")
        }

        // (OK) A stored doc is read back by load() through the bridge.
        function test_bridge_roundtrip_on_load() {
            _bridge.reset()
            _bridge.stored = docStr({ version: 1, appearance: {}, settings: {},
                pages: [ { name: "Persisted", tiles: [] } ] })
            store.load("productivity")
            compare(store.pageCount(), 1)
            compare(store.pages()[0].name, "Persisted")
        }
    }

    // ── 1. Force-flush semantics of structural edits ────────────────────────
    TestCase {
        name: "StoreForceFlush"
        when: windowShown
        function init() { _bridge.reset(); store.load("blank"); _bridge.reset() }

        // (OK) resetTo() calls flushNow() → immediate, synchronous save.
        function test_resetTo_flushes_immediately() {
            store.resetTo("minimal")
            compare(_bridge.saveCount, 1, "resetTo persists immediately (flushNow)")
        }

        // (BUG) _commitStructure only debounces (saveTimer.restart), so a page
        // added from the tab bar outside edit mode is not persisted for 400ms
        // and is lost on abrupt power-off.
        function test_addPage_force_flushes() {
            store.addPage("Extra")
            compare(_bridge.saveCount, 1,
                "a structural edit (addPage) should force an immediate save, not a 400ms debounce")
        }

        // (BUG) Same debounce hole for addTile.
        function test_addTile_force_flushes() {
            store.addTile(0, "cpu")
            compare(_bridge.saveCount, 1,
                "addTile should force an immediate save")
        }

        // (BUG) …and for setPageBackground.
        function test_setPageBackground_force_flushes() {
            store.setPageBackground(0, "style", "waves")
            compare(_bridge.saveCount, 1,
                "setPageBackground should force an immediate save")
        }
    }

    // ── 2. Page-index bounds ────────────────────────────────────────────────
    TestCase {
        name: "StorePageBounds"
        when: windowShown
        function init() {
            _bridge.reset()
            store.load("blank")
            store.addPage("B"); store.addPage("C")   // 3 pages: Home, B, C
            _bridge.reset()
        }

        // (BUG) removePage(-1) splices from the end and deletes the LAST page.
        function test_removePage_negative_is_noop() {
            var before = store.pageCount()
            var names = store.pages().map(function (p) { return p.name })
            store.removePage(-1)
            compare(store.pageCount(), before,
                "removePage(-1) must not delete any page (negative index deletes the last)")
            compare(store.pages().map(function (p) { return p.name }), names,
                "page list unchanged after removePage(-1)")
        }

        // (BUG) removePage(999) removes nothing but still bumps revisions + queues a save.
        function test_removePage_oob_no_side_effects() {
            var sr = store.structureRevision
            var rv = store.revision
            store.removePage(999)
            compare(store.structureRevision, sr,
                "an out-of-range removePage must not bump structureRevision")
            compare(store.revision, rv,
                "an out-of-range removePage must not bump revision")
            compare(_bridge.saveCount, 0,
                "an out-of-range removePage must not queue/force a save")
        }

        // (OK) A valid removePage deletes exactly that page and its tiles' settings.
        function test_removePage_valid_drops_only_that_pages_settings() {
            store.load("blank")
            var id0 = store.addTile(0, "cpu")
            store.addPage("Two")
            var id1 = store.addTile(1, "gpu")
            store.setSetting(id0, "a", 1)
            store.setSetting(id1, "b", 2)
            store.removePage(1)
            compare(store.pageCount(), 1, "page removed")
            verify(store.document.settings.hasOwnProperty(id0), "surviving page's tile settings kept")
            verify(!store.document.settings.hasOwnProperty(id1), "removed page's tile settings dropped")
        }

        // (OK) removePage never drops below one page.
        function test_removePage_keeps_last_page() {
            store.load("blank")   // one page
            store.removePage(0)
            compare(store.pageCount(), 1, "the last page is protected")
        }
    }

    // ── 3. Tile-mutation bounds (must not throw) ────────────────────────────
    TestCase {
        name: "StoreTileBounds"
        when: windowShown
        function init() { _bridge.reset(); store.load("blank"); _bridge.reset() }

        // (BUG) removeTile dereferences document.pages[pageIdx].tiles with no guard.
        function test_removeTile_oob_page_does_not_throw() {
            var threw = false
            try { store.removeTile(5, "whatever") } catch (e) { threw = true }
            verify(!threw, "removeTile with an out-of-range pageIdx must return safely, not throw")
        }

        // (BUG) moveTile dereferences document.pages[pageIdx].tiles with no guard.
        function test_moveTile_oob_page_does_not_throw() {
            var threw = false
            try { store.moveTile(5, 0, 0) } catch (e) { threw = true }
            verify(!threw, "moveTile with an out-of-range pageIdx must return safely, not throw")
        }

        // (OK) removeTile / moveTile on a valid page still behave.
        function test_removeTile_valid_still_works() {
            var id = store.addTile(0, "cpu")
            store.removeTile(0, id)
            compare(store.pages()[0].tiles.length, 0)
        }
    }

    // ── 4. load()/applyExternal() normalisation & pruning ───────────────────
    TestCase {
        name: "StoreLoadNormalise"
        when: windowShown
        function init() { _bridge.reset(); store.load("blank"); _bridge.reset() }

        // (BUG) load() does not guarantee each page has a tiles array; addTile
        // then throws on the un-normalised page.
        function test_load_normalises_tiles_array() {
            _bridge.stored = docStr({ version: 1, appearance: {}, settings: {},
                pages: [ { name: "NoTiles" } ] })    // page WITHOUT a tiles array
            store.load("productivity")
            var threw = false
            try { store.addTile(0, "cpu") } catch (e) { threw = true }
            verify(!threw,
                "load() should normalise every page to have a tiles array so addTile does not throw")
        }

        // (BUG) applyExternal() accepts a page without a tiles array.
        function test_applyExternal_normalises_tiles_array() {
            verify(store.applyExternal(docStr({ version: 1, pages: [ { name: "NoTiles" } ] })))
            var threw = false
            try { store.addTile(0, "cpu") } catch (e) { threw = true }
            verify(!threw,
                "applyExternal() should normalise pages so a later addTile does not throw")
        }

        // (BUG) applyExternal() keeps settings for tile ids no longer present.
        function test_applyExternal_prunes_orphan_settings() {
            store.applyExternal(docStr({ version: 1,
                pages: [ { name: "P", tiles: [ { id: "keep-1", type: "cpu" } ] } ],
                settings: { "keep-1": { a: 1 }, "orphan-9": { b: 2 } } }))
            verify(store.document.settings.hasOwnProperty("keep-1"), "live tile settings kept")
            verify(!store.document.settings.hasOwnProperty("orphan-9"),
                "settings for a tile absent from every page should be pruned")
        }

        // (BUG) load() keeps orphaned settings too.
        function test_load_prunes_orphan_settings() {
            _bridge.stored = docStr({ version: 1, appearance: {}, settings: { "orphan-x": { z: 1 } },
                pages: [ { name: "P", tiles: [ { id: "keep-2", type: "cpu" } ] } ] })
            store.load("productivity")
            verify(!store.document.settings.hasOwnProperty("orphan-x"),
                "load() should prune settings whose ids no longer exist in any page")
        }

        // (OK) load() scrubs the stray empty-id settings entry.
        function test_load_scrubs_empty_id_settings() {
            _bridge.stored = docStr({ version: 1, appearance: {},
                settings: { "": { junk: 1 }, "t1": { ok: 1 } },
                pages: [ { name: "P", tiles: [ { id: "t1", type: "cpu" } ] } ] })
            store.load("productivity")
            verify(!store.document.settings.hasOwnProperty(""), "empty-id settings scrubbed on load")
        }

        // (BUG) load() discards a valid saved doc with pages:[] and re-seeds,
        // while applyExternal() honours it - an inconsistency the audit flags.
        function test_load_honours_empty_pages_like_applyExternal() {
            // Prove applyExternal honours pages:[].
            store.applyExternal(docStr({ version: 1, appearance: {}, settings: {}, pages: [] }))
            compare(store.pageCount(), 0, "applyExternal accepts an intentionally-blank layout")
            // load() of the same saved doc should be consistent (also blank).
            _bridge.stored = docStr({ version: 1, appearance: {}, settings: {}, pages: [] })
            store.load("productivity")
            compare(store.pageCount(), 0,
                "load() should honour a saved pages:[] consistently with applyExternal, not re-seed")
        }

        // (BUG) applyExternal() does not stop a pending debounced save, so the
        // externally-applied doc gets echoed back to the hub 400ms later.
        function test_applyExternal_cancels_pending_save() {
            store.load("blank"); store.flushNow(); _bridge.reset()
            store.setSetting("someTile", "k", 1)    // schedules saveTimer (400ms), no save yet
            compare(_bridge.saveCount, 0, "settings edit is debounced, not saved yet")
            store.applyExternal(docStr({ version: 1, appearance: {}, settings: {},
                pages: [ { name: "Ext", tiles: [] } ] }))
            wait(600)                                 // let any pending timer fire
            compare(_bridge.saveCount, 0,
                "applyExternal should cancel the pending save so external state is never written back")
        }

        // (OK) applyExternal rejects clearly invalid docs.
        function test_applyExternal_rejects_garbage() {
            verify(!store.applyExternal("not json"))
            verify(!store.applyExternal('{"no":"pages"}'))
        }
    }

    // ── 5. settingsFor / ensureSettings semantics ───────────────────────────
    TestCase {
        name: "StoreSettingsSemantics"
        when: windowShown
        function init() { _bridge.reset(); store.load("blank"); _bridge.reset() }

        // (BUG) settingsFor() lazily creates a persisted empty {} entry as a
        // side effect of a read used inside widget bindings.
        function test_settingsFor_read_creates_no_persisted_entry() {
            verify(!store.document.settings.hasOwnProperty("ghost-id"), "precondition: no entry yet")
            store.settingsFor("ghost-id")
            verify(!store.document.settings.hasOwnProperty("ghost-id"),
                "reading settingsFor for an unknown id must not permanently create a persisted {} entry")
        }

        // (BUG) ensureSettings() seeds defaults but never bumps revision, so a
        // second instance (expanded overlay) never re-reads the seeded values.
        function test_ensureSettings_bumps_revision() {
            var r0 = store.revision
            store.ensureSettings("e1", { foo: 1, bar: 2 })
            verify(store.revision > r0,
                "ensureSettings should bump revision so a second instance sees the seeded defaults")
        }

        // (BUG) ensureSettings() never schedules a save, so seeded defaults are
        // lost if the app closes before any other mutation.
        function test_ensureSettings_schedules_save() {
            store.flushNow()   // stop any pending debounced save leaked from an earlier test
            _bridge.reset()
            store.ensureSettings("e2", { foo: 1 })
            wait(600)          // only a save scheduled BY ensureSettings could land here
            verify(_bridge.saveCount > 0,
                "ensureSettings should schedule a save so the seeded defaults are persisted")
        }

        // (OK) ensureSettings only fills missing keys, never clobbers existing.
        function test_ensureSettings_no_clobber() {
            store.setSetting("e3", "phase", "break")
            store.ensureSettings("e3", { phase: "work", running: false })
            compare(store.settingsFor("e3").phase, "break", "existing value kept")
            compare(store.settingsFor("e3").running, false, "missing default seeded")
        }

        // (OK) resetSettings deep-copies the defaults so two resets do not share
        // the same array/object reference.
        function test_resetSettings_deep_clones() {
            var defaults = { tasks: [], n: 0 }
            store.resetSettings("a", defaults)
            store.resetSettings("b", defaults)
            store.settingsFor("a").tasks.push("only-a")
            compare(store.settingsFor("a").tasks.length, 1)
            compare(store.settingsFor("b").tasks.length, 0, "b's array is independent")
            compare(defaults.tasks.length, 0, "the shared defaults object is untouched")
        }

        // (OK) resetSettings drops stale keys not present in defaults.
        function test_resetSettings_drops_stale_keys() {
            store.setSetting("c", "leftover", 42)
            store.resetSettings("c", { fresh: 1 })
            compare(store.settingsFor("c").fresh, 1)
            compare(store.settingsFor("c").leftover, undefined, "stale key removed")
        }

        // (OK) Two tiles added in quick succession get distinct ids AND distinct
        // settings objects.
        function test_two_tiles_distinct_ids_and_settings() {
            var a = store.addTile(0, "cpu")
            var b = store.addTile(0, "cpu")
            verify(a && b && a !== b, "distinct ids")
            store.setSetting(a, "x", 1)
            store.setSetting(b, "y", 2)
            verify(store.settingsFor(a) !== store.settingsFor(b), "distinct settings objects")
            compare(store.settingsFor(a).y, undefined, "settings objects do not bleed")
        }
    }

    // ── 6. Reactivity: revision vs structureRevision ────────────────────────
    TestCase {
        name: "StoreReactivity"
        when: windowShown
        function init() { _bridge.reset(); store.load("blank"); _bridge.reset() }

        // (OK) Every kind of settings/appearance mutation bumps revision.
        function test_revision_bumps_on_every_settings_mutation() {
            var r = store.revision
            store.setSetting("t", "k", 1);              verify(store.revision > r, "setSetting bumps"); r = store.revision
            store.patchSettings("t", { k2: 2 });        verify(store.revision > r, "patchSettings bumps"); r = store.revision
            store.resetSettings("t", { k3: 3 });        verify(store.revision > r, "resetSettings bumps"); r = store.revision
            store.setAppearance("accent", "purple");    verify(store.revision > r, "setAppearance bumps")
        }

        // (OK) A structural edit bumps structureRevision; a settings edit does NOT
        // (so tile Loaders don't rebuild on every keystroke).
        function test_structureRevision_only_on_structural_edits() {
            var sr = store.structureRevision
            store.setSetting("t", "k", 1)
            compare(store.structureRevision, sr, "a settings edit must NOT bump structureRevision")
            store.addTile(0, "cpu")
            verify(store.structureRevision > sr, "a tile add must bump structureRevision")
        }

        // (OK) The per-page background override is structural.
        function test_page_overrides_bump_structureRevision() {
            var sr = store.structureRevision
            store.setPageBackground(0, "style", "orbs")
            verify(store.structureRevision > sr, "setPageBackground is structural")
        }

        // (OK) Appearance is readable + reactive via revision.
        function test_global_appearance_is_revision_keyed() {
            var r = store.revision
            store.setAppearance("orientation", "landscape")
            compare(store.appearance().orientation, "landscape")
            verify(store.revision > r, "appearance change is revision-keyed")
        }
    }

    // ── 7. Page / tile utility behaviour ────────────────────────────────────
    TestCase {
        name: "StorePageUtils"
        when: windowShown
        function init() { _bridge.reset(); store.load("blank") }

        // (OK) setPageBackground clears on empty value.
        function test_setPageBackground_clear() {
            store.setPageBackground(0, "style", "waves")
            compare(store.pageBackground(0).style, "waves")
            store.setPageBackground(0, "style", "")
            compare(store.pageBackground(0).style, undefined, "empty value clears the override")
        }

        // (OK) renamePage trims, keeps the old name when blank, de-dupes.
        function test_renamePage_validation() {
            var was = store.pages()[0].name
            store.renamePage(0, "   ")
            compare(store.pages()[0].name, was, "blank rename keeps the old name")
            store.renamePage(0, "  Work  ")
            compare(store.pages()[0].name, "Work", "trimmed")
            store.addPage("Play")
            store.renamePage(1, "Work")     // collides with page 0
            verify(store.pages()[1].name !== "Work", "duplicate disambiguated, got " + store.pages()[1].name)
        }

        // (OK) _uniquePageName avoids collisions.
        function test_unique_page_name() {
            store.addPage(""); store.addPage("")
            var names = store.pages().map(function (p) { return p.name })
            var seen = {}
            for (var i = 0; i < names.length; i++) {
                verify(seen[names[i]] === undefined, "no duplicate page name: " + names[i])
                seen[names[i]] = true
            }
        }

        // (OK) moveTile clamps and has no off-by-one at first/last positions.
        function test_moveTile_first_and_last() {
            var a = store.addTile(0, "cpu")
            var b = store.addTile(0, "gpu")
            var c = store.addTile(0, "ram")
            store.moveTile(0, 2, 0)   // ram to the very front
            compare(store.pages()[0].tiles[0].id, c, "moved to first position")
            store.moveTile(0, 0, 99)  // clamp to last
            compare(store.pages()[0].tiles[store.pages()[0].tiles.length - 1].id, c, "clamped to last")
        }

        // (OK) bounds-guarded page ops don't throw.
        function test_page_ops_bounds_guarded() {
            var threw = false
            try {
                store.setPageBackground(-1, "style", "x")
                store.renamePage(99, "z")
            } catch (e) { threw = true }
            verify(!threw, "out-of-range page ops are guarded")
        }
    }

    // ── 8. Id generation / collisions ───────────────────────────────────────
    TestCase {
        name: "StoreIds"
        when: windowShown
        function init() { _bridge.reset(); store.load("blank") }

        // (OK) seed() now materialises a preset via PresetCatalog.buildDoc(), which
        // mints each tile id from a per-document counter (`type-1`, `type-2`, …) and
        // ships a self-contained `settings` map keyed only by those new ids. A stale
        // per-tile settings bucket left over from a prior session is therefore never
        // silently inherited by a freshly-seeded tile.
        function test_seed_ids_do_not_inherit_persisted_settings() {
            store.setSetting("clock-0", "persisted", 1)   // as if left over from a prior session
            store._idSeq = 0                               // even after a fresh-launch counter reset…
            var doc = store.seed("minimal")                // first tile type is "clock"
            var firstId = doc.pages[0].tiles[0].id
            verify(firstId && firstId.indexOf("clock-") === 0,
                "seeded ids are freshly minted from the preset (type-N)")
            verify(firstId !== "clock-0",
                "a seeded id must not reproduce the stale clock-0 an old tile still owns settings for")
            // The seeded doc only carries the preset's own settings, never the leftover bucket.
            verify(!doc.settings || !doc.settings.hasOwnProperty("clock-0"),
                "a stale persisted id is not carried into the seeded document")
        }

        // (OK) Within a live session, addTile ids are globally distinct.
        function test_addTile_ids_globally_distinct() {
            var seen = {}
            for (var i = 0; i < 6; i++) {
                var id = store.addTile(0, "cpu")
                verify(seen[id] === undefined, "addTile id reused: " + id)
                seen[id] = true
            }
        }
    }

    // ── 9. Direct API contract for the store's helpers / mutators ────────────
    // Each helper is exercised directly and its OWN result/effect asserted (the
    // behaviour-matrix backing), complementing the effect-level tests above.
    TestCase {
        name: "StoreApiContract"
        when: windowShown
        function init() { _bridge.reset(); store.load("blank") }

        // Bridge detection + ephemeral-key classification.
        function test_hasBridge_and_ephemeral_keys() {
            verify(store._hasBridge(), "_hasBridge detects the injected configBridge")
            verify(store._isEphemeralKey("hist"), "_isEphemeralKey flags a volatile metric key")
            verify(!store._isEphemeralKey("place"), "_isEphemeralKey passes a real setting key")
        }

        // _bucket get-or-create semantics + ensureSettings seed-and-return.
        function test_bucket_and_ensureSettings() {
            compare(store._bucket(""), null, "_bucket rejects an empty id")
            verify(store._bucket("api-1") !== null, "_bucket materialises a real bucket")
            compare(store.ensureSettings("api-2", { seeded: 7 }).seeded, 7,
                    "ensureSettings seeds the default and returns the bucket")
        }

        // Id generation is type-prefixed and unique per call.
        function test_newId_prefix_and_uniqueness() {
            verify(store._newId("cpu").indexOf("cpu-") === 0, "_newId prefixes the id with the type")
            verify(store._newId("cpu") !== store._newId("cpu"), "_newId is unique per call")
        }

        // _clone is a deep copy; mutating the clone cannot reach the source.
        function test_clone_is_deep() {
            var src = { a: [1, 2] }
            var cl = store._clone(src); cl.a.push(3)
            compare(src.a.length, 2, "_clone deep-copies (clone edits never touch the source)")
        }

        // _normaliseDoc backfills the standard maps and a tiles array per page.
        function test_normaliseDoc_backfills() {
            var nd = store._normaliseDoc({})
            verify(nd.pages !== undefined && nd.settings !== undefined && nd.appearance !== undefined,
                   "_normaliseDoc backfills pages/settings/appearance")
            var nd2 = store._normaliseDoc({ pages: [ { name: "P" } ] })
            verify(nd2.pages[0].tiles !== undefined, "_normaliseDoc gives every page a tiles array")
        }

        // _persistableData returns the versioned on-disk doc (volatile keys stripped).
        function test_persistableData_returns_doc() {
            verify(store._persistableData().version === 1,
                   "_persistableData returns the versioned on-disk document")
        }

        // _uniquePageName yields a collision-free "Page N" name.
        function test_uniquePageName_shape() {
            verify(store._uniquePageName().indexOf("Page ") === 0, "_uniquePageName yields a 'Page N' name")
        }

        // _mk stamps an {id,type} tile record; _page builds a {name,tiles} page.
        function test_mk_and_page_builders() {
            compare(store._mk("clock").type, "clock", "_mk stamps the tile type")
            var pg = store._page("PX", ["cpu", "gpu"])
            compare(pg.name, "PX", "_page sets the page name")
            compare(pg.tiles.length, 2, "_page builds one tile per requested type")
        }

        // Reactivity primitives: _touchSettings bumps revision, _commitStructure
        // bumps structureRevision (and revision).
        function test_touch_and_commit_bump_revisions() {
            var r = store.revision; store._touchSettings()
            verify(store.revision > r, "_touchSettings bumps revision for reactivity")
            var sr = store.structureRevision; store._commitStructure()
            verify(store.structureRevision > sr, "_commitStructure bumps structureRevision")
        }

        // Direct tile/page mutators name themselves on the assertion of their effect.
        function test_setTileSize_addPage_rename_remove() {
            // `tasks` because it declares 1x2 - setTileSize is gated on the TYPE, so a
            // subject that cannot render the size would prove the rejection, not the apply.
            var tid = store.addTile(0, "tasks")
            store.setTileSize(0, tid, "1x2")
            compare(store.pages()[0].tiles[0].size, "1x2", "setTileSize applied the new named size")
            var pc = store.pageCount(); store.addPage("Added")
            compare(store.pageCount(), pc + 1, "addPage appended a page")
            store.renamePage(store.pageCount() - 1, "Renamed")
            compare(store.pages()[store.pageCount() - 1].name, "Renamed", "renamePage set the new name")
            var pc2 = store.pageCount(); store.removePage(store.pageCount() - 1)
            compare(store.pageCount(), pc2 - 1, "removePage dropped exactly one page")
        }

        // _flush / flushNow persist the current document through the bridge.
        function test_flush_and_flushNow_persist() {
            store.addTile(0, "cpu")
            _bridge.reset(); store.flushNow()
            verify(_bridge.saveCount >= 1, "flushNow drives an immediate _flush through the bridge")
        }
    }
}
