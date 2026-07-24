import QtQuick
import QtTest
import "../../ui/qml" as App

// COVERS: fn:DashboardStore._blankDoc
//
// Coverage for the core editable paths the dashboard is built on: tile add /
// remove / move / resize, per-instance settings lifecycle, the shared-state
// contract (one settings object backs both the tile and its expanded overlay),
// and the named starter layouts. These are the most-used mutation paths and
// were previously only exercised indirectly.
Item {
    width: 100; height: 100
    App.DashboardStore { id: store }
    App.WidgetSizes { id: sizes }
    App.WidgetCatalog { id: catalog }

    TestCase {
        name: "StoreTiles"
        when: windowShown
        function init() { store.load("blank") }   // one empty "Home" page

        function tiles() { return store.pages()[0].tiles }

        // ── add / remove ───────────────────────────────────────────────────
        function test_add_tile_returns_unique_ids() {
            var a = store.addTile(0, "cpu")
            var b = store.addTile(0, "cpu")
            verify(a && b && a !== b, "ids must be non-empty and distinct")
            compare(tiles().length, 2)
            compare(tiles()[0].type, "cpu")
        }

        function test_add_tile_out_of_range_is_noop() {
            store.addTile(5, "cpu")
            store.addTile(-1, "cpu")
            compare(tiles().length, 0)
        }

        function test_remove_tile_also_drops_its_settings() {
            var id = store.addTile(0, "notes")
            store.setSetting(id, "text", "hello")
            compare(store.settingsFor(id).text, "hello")
            store.removeTile(0, id)
            compare(tiles().length, 0)
            // settingsFor lazily recreates, so assert the map no longer carried it
            verify(store.document.settings[id] === undefined || Object.keys(store.document.settings[id]).length === 0)
        }

        function test_remove_unknown_tile_is_noop() {
            store.addTile(0, "cpu")
            store.removeTile(0, "does-not-exist")
            compare(tiles().length, 1)
        }

        // ── named sizes ────────────────────────────────────────────────────
        // A tile is born with a size, so `size === undefined` can only ever mean
        // "this document predates the size key" - never "this tile is new".
        function test_add_tile_is_born_with_a_size() {
            store.addTile(0, "cpu")
            verify(sizes.isLegal(tiles()[0].size),
                   "a fresh tile has a legal size, got " + JSON.stringify(tiles()[0].size))
            verify(tiles()[0].w === undefined, "the dead w span vocabulary is never written")
            verify(tiles()[0].h === undefined, "the dead h span vocabulary is never written")
        }

        // setTileSize takes a NAMED size and applies every legal one. `kpi` is the one
        // type that declares all seven (it is the "one number read across a room"
        // widget, so it genuinely earns the full screen), which makes it the only
        // honest subject for a whole-vocabulary sweep - legality is not the gate here,
        // the TYPE is.
        function test_set_tile_size_applies_each_legal_size() {
            var id = store.addTile(0, "kpi")
            var all = sizes.all()
            compare(catalog.sizesFor("kpi").length, all.length,
                    "precondition: kpi really does declare every legal size")
            for (var i = 0; i < all.length; i++) {
                verify(store.setTileSize(0, id, all[i]), "setTileSize accepted " + all[i])
                compare(tiles()[0].size, all[i], "the named size was stored verbatim")
            }
        }

        // The old span vocabulary is not a size: passing it must be REJECTED, not
        // coerced into something plausible-looking.
        function test_set_tile_size_rejects_illegal_sizes() {
            var id = store.addTile(0, "kpi")
            store.setTileSize(0, id, "1x2")
            var bad = ["2x2", "1x2.5", "", "constructor", 2, null, undefined]
            for (var i = 0; i < bad.length; i++) {
                verify(!store.setTileSize(0, id, bad[i]),
                       "setTileSize rejected " + JSON.stringify(bad[i]))
                compare(tiles()[0].size, "1x2", "the tile kept its prior size")
            }
        }

        // A size can be perfectly LEGAL and still be refused: the widget type decides.
        // This is the gate the resize UI (and a Manager push) rests on - without it a
        // tile can be put into a shape its widget was never built to render.
        function test_set_tile_size_rejects_a_size_the_type_does_not_declare() {
            var id = store.addTile(0, "cpu")
            verify(sizes.isLegal("1x3"), "precondition: 1x3 is a legal size")
            verify(catalog.sizesFor("cpu").indexOf("1x3") < 0, "precondition: cpu does not declare it")
            verify(!store.setTileSize(0, id, "1x3"), "setTileSize refused a size cpu cannot render")
            compare(tiles()[0].size, catalog.defaultSize("cpu"), "the tile kept its own size")
            verify(store.setTileSize(0, id, "1x1.5"), "and still accepts one cpu DOES declare")
        }

        function test_resize_out_of_range_is_noop() {
            var id = store.addTile(0, "kpi")
            verify(!store.setTileSize(9, id, "1x2"), "bad page index is rejected")
            verify(!store.setTileSize(0, "does-not-exist", "1x2"), "unknown tile id is rejected")
        }

        // ── move / reorder with clamping ───────────────────────────────────
        function test_move_reorders() {
            var a = store.addTile(0, "cpu")
            var b = store.addTile(0, "gpu")
            var c = store.addTile(0, "ram")
            store.moveTile(0, 0, 2)          // cpu to the end
            var order = tiles().map(function (t) { return t.id })
            compare(order, [b, c, a])
        }

        function test_move_clamps_target_index() {
            var a = store.addTile(0, "cpu")
            var b = store.addTile(0, "gpu")
            store.moveTile(0, 0, 99)         // clamps to last
            compare(tiles()[tiles().length - 1].id, a)
        }

        function test_move_invalid_from_is_noop() {
            store.addTile(0, "cpu")
            store.moveTile(0, 5, 0)
            store.moveTile(0, -1, 0)
            compare(tiles().length, 1)
        }

        // ── settings lifecycle ─────────────────────────────────────────────
        function test_ensure_settings_no_clobber() {
            var id = store.addTile(0, "focus")
            store.setSetting(id, "phase", "break")
            store.ensureSettings(id, { phase: "work", running: false })
            compare(store.settingsFor(id).phase, "break")   // existing kept
            compare(store.settingsFor(id).running, false)   // missing seeded
        }

        function test_patch_settings_merges() {
            var id = store.addTile(0, "weather")
            store.patchSettings(id, { lat: 1.5, lon: 2.5, place: "X" })
            store.patchSettings(id, { place: "Y" })
            var s = store.settingsFor(id)
            compare(s.lat, 1.5)
            compare(s.place, "Y")
        }

        // The design contract: a tile and its expanded overlay are two separate
        // widget instances that share ONE live settings object via the store.
        function test_shared_state_between_two_readers() {
            // The tile and its expanded overlay share per-widget state THROUGH the
            // store: once a value is set, every reader sees it. (settingsFor is now
            // a non-mutating getter - it no longer creates a persisted bucket as a
            // read side-effect, so we don't assert object identity, only shared value.)
            var id = store.addTile(0, "notes")
            store.setSetting(id, "text", "typed in the overlay")
            var readerA = store.settingsFor(id)
            var readerB = store.settingsFor(id)
            compare(readerA.text, "typed in the overlay")
            compare(readerB.text, "typed in the overlay")
        }

        // Metric sparkline history / peaks are volatile per-session state: they must
        // stay in memory (so the compact tile and its expanded overlay share one
        // sparkline) yet NEVER reach config.toml - otherwise the metric widgets
        // rewrite the config on every ~2s sample (flash wear + a save race with the
        // Manager). The persisted document strips them; a plain setting is kept.
        function test_ephemeral_metric_keys_not_persisted() {
            var id = store.addTile(0, "cpu")
            store.setSetting(id, "hist", [1, 2, 3])
            store.patchSettings(id, { peakRx: 99, peakTx: 42, place: "kept" })
            // In-memory: everything is live (shared with the expanded overlay).
            compare(store.settingsFor(id).hist, [1, 2, 3])
            compare(store.settingsFor(id).peakRx, 99)
            // On disk: the volatile keys are gone, the real setting survives.
            var disk = store._persistableData().settings[id]
            verify(disk.hist === undefined, "hist must not be persisted")
            verify(disk.peakRx === undefined, "peakRx must not be persisted")
            verify(disk.peakTx === undefined, "peakTx must not be persisted")
            compare(disk.place, "kept", "a real setting alongside volatile keys is kept")
        }

        // A write that touches ONLY volatile keys must not schedule a disk save,
        // but must still bump revision so the live sparkline redraws.
        function test_ephemeral_write_bumps_revision_without_save() {
            var id = store.addTile(0, "net")
            var r0 = store.revision
            store.patchSettings(id, { hist: [{ r: 1, t: 2 }], peakRx: 5, peakTx: 6 })
            verify(store.revision > r0, "volatile write still bumps revision for reactivity")
            verify(!store._savePending, "a volatile-only write must not schedule a disk save")
            // A mixed patch (volatile + real) DOES schedule a save.
            store.patchSettings(id, { hist: [{ r: 9, t: 9 }], units: "mbit" })
            verify(store._savePending, "a patch with a real key schedules a save")
        }

        function test_mutations_bump_revision() {
            var r0 = store.revision
            store.addTile(0, "cpu")
            verify(store.revision > r0, "structural edit bumps revision")
            var r1 = store.revision
            store.setSetting(store.pages()[0].tiles[0].id, "k", 1)
            verify(store.revision > r1, "settings edit bumps revision")
        }
    }

    // ── Starter layouts ────────────────────────────────────────────────────
    TestCase {
        name: "StoreSeeds"
        when: windowShown

        function test_seed_shapes_the_document() {
            // Presets are single-page "screens" now - each seeds exactly one page.
            var cases = {
                "blank":        { pages: ["Home"], firstTileCount: 0 },
                "minimal":      { pages: ["Home"] },
                "gaming":       { pages: ["GPU"] },
                "productivity": { pages: ["Focus"] }
            }
            for (var which in cases) {
                var doc = store.seed(which)
                var names = doc.pages.map(function (p) { return p.name })
                compare(names, cases[which].pages, which + " page names")
                // Every tile has an id + type.
                for (var i = 0; i < doc.pages.length; i++)
                    for (var j = 0; j < doc.pages[i].tiles.length; j++) {
                        verify(doc.pages[i].tiles[j].id, which + " tile has id")
                        verify(doc.pages[i].tiles[j].type, which + " tile has type")
                    }
            }
            compare(store.seed("blank").pages[0].tiles.length, 0)
        }

        function test_unknown_seed_falls_back_to_the_starter_bundle() {
            // An unknown/empty seed id resolves to the recommended starter BUNDLE -
            // a few single-page screens - not a single preset.
            var unknown = store.seed("nonsense").pages.map(function (p) { return p.name })
            var starter = store.seed("starter").pages.map(function (p) { return p.name })
            compare(unknown, starter, "unknown seed falls back to the starter bundle")
            verify(starter.length >= 2, "the starter bundle is a few screens, not one")
            verify(starter.indexOf("Focus") !== -1, "the bundle includes the Focus screen")
        }

        // The blank document is the canonical empty layout: one "Home" page, no
        // tiles, empty appearance/settings (the base seed() returns for "blank").
        function test_blank_doc_shape() {
            var d = store._blankDoc()
            compare(d.version, 1, "_blankDoc is a v1 document")
            compare(d.pages.length, 1, "_blankDoc has exactly one page")
            compare(d.pages[0].name, "Home", "_blankDoc page is Home")
            compare(d.pages[0].tiles.length, 0, "_blankDoc has no tiles")
        }

        function test_reset_to_replaces_layout() {
            store.load("blank")
            store.addTile(0, "cpu")
            store.resetTo("minimal")
            compare(store.pages().length, 1)
            compare(store.pages()[0].name, "Home")
            verify(store.pages()[0].tiles.length > 0)
        }
    }
}
