import QtQuick
import QtTest
import "../../ui/qml" as App

// COVERS: fn:DashboardStore._isPlainObject, fn:DashboardStore._catalogFn, fn:DashboardStore._defaultSizeFor
// COVERS: fn:DashboardStore._sizeSupported, fn:DashboardStore._nearestSize, fn:DashboardStore._migratedSize
// COVERS: fn:DashboardStore._coerceTileSize, fn:DashboardStore._largestSupportedAtMost
//
// Robustness (Phase 3a): `_normaliseDoc` is a real VALIDATOR. A corrupt or hostile
// UI-state document - pushed over the control socket (applyExternal) or read from a
// clobbered config.toml (load) - must SELF-HEAL into a well-formed structure rather
// than reaching the page/tile Repeater and `addTile` as a number/string/id-less
// object → TypeError → blank dashboard. Both entry points share `_normaliseDoc`, so
// each malformed shape is exercised end-to-end through applyExternal AND directly
// through _normaliseDoc (the coercion the load path applies to the parsed object).
Item {
    width: 100; height: 100
    App.DashboardStore { id: store }
    App.WidgetSizes { id: sizes }
    // The per-type size contract the store enforces on the way in - asserted here
    // against the REAL catalog, so a widget that changes the sizes it declares
    // shows up as a migration change rather than a surprise on someone's device.
    App.WidgetCatalog { id: catalog }

    TestCase {
        name: "StoreValidation"
        when: windowShown
        function init() { store.load("blank") }

        // "pages":5 - a non-array pages field is discarded to an empty array.
        function test_pages_number_self_heals() {
            var ok = store.applyExternal('{"pages":5}')
            verify(ok, "applyExternal accepted (truthy pages) and did not throw")
            verify(Array.isArray(store.pages()), "pages() is an array")
            compare(store.pageCount(), 0, "junk pages coerced to []")
        }

        // "pages":{} - an object (not an array) is likewise discarded.
        function test_pages_object_self_heals() {
            var ok = store.applyExternal('{"pages":{}}')
            verify(ok, "did not throw")
            verify(Array.isArray(store.pages()), "pages() is an array")
            compare(store.pageCount(), 0, "object pages coerced to []")
        }

        // A page whose `tiles` is a string → tiles reset to [], the page survives.
        function test_page_tiles_non_array_reset() {
            var ok = store.applyExternal('{"pages":[{"name":"A","tiles":"x"}]}')
            verify(ok, "did not throw")
            compare(store.pageCount(), 1, "page kept")
            compare(store.pages()[0].name, "A", "name preserved")
            verify(Array.isArray(store.pages()[0].tiles), "tiles coerced to array")
            compare(store.pages()[0].tiles.length, 0, "non-array tiles reset to []")
        }

        // A crafted/corrupt tile span (w:9999/h:-5) can no longer drive a runaway
        // rowSpan: w/h are migrated into a NAMED size and then dropped, so the only
        // geometry that survives is one of the seven legal names.
        function test_tile_span_migrated_not_clamped() {
            var ok = store.applyExternal('{"pages":[{"tiles":[{"id":"a","type":"cpu","w":9999,"h":-5},{"id":"b","type":"ram","h":2}]}]}')
            verify(ok, "did not throw")
            var tiles = store.pages()[0].tiles
            compare(tiles.length, 2, "both valid tiles kept")
            verify(sizes.isLegal(tiles[0].size), "a hostile w/h still yields a legal size (got " + tiles[0].size + ")")
            verify(tiles[0].w === undefined && tiles[0].h === undefined, "the dead w/h keys are dropped")
            verify(tiles[1].w === undefined && tiles[1].h === undefined, "dropped for every tile")
            // h:9999-style values must not become the FULL SCREEN: no pre-migration
            // document could mean more than 2 rows, so the old [1,2] clamp's intent
            // is carried into the mapping.
            verify(!sizes.isFullScreen(tiles[0].size), "a crafted span cannot migrate to a full-screen tile")
        }

        // A size pushed over the control socket by another process is COERCED unless
        // the TYPE declares it - being one of the seven legal names is not enough.
        // Tile "e" is the sharp case: `1x3` is perfectly legal and `cpu` still cannot
        // render it, so a push must not be able to force it.
        function test_hostile_size_coerced_via_applyExternal() {
            var ok = store.applyExternal('{"pages":[{"tiles":[' +
                '{"id":"a","type":"cpu","size":"9999x9999"},' +
                '{"id":"b","type":"ram","size":"constructor"},' +
                '{"id":"c","type":"gpu","size":{"short":1}},' +
                '{"id":"e","type":"cpu","size":"1x3"},' +
                '{"id":"d","type":"tasks","size":"1x2"}]}]}')
            verify(ok, "did not throw")
            var tiles = store.pages()[0].tiles
            compare(tiles.length, 5, "no tile is dropped over a bad size")
            // a/b/c are JUNK - not one of the seven names, so there is no size to rank
            // them against and the type's default is the only honest answer.
            for (var i = 0; i < 3; i++)
                compare(tiles[i].size, store._defaultSizeFor(tiles[i].type),
                        tiles[i].type + ": an unrankable size falls back to its default")
            // "e" is the sharp one: LEGAL but unsupported, so it coerces DOWN to what
            // cpu declares. Refusal is what matters - 1x3 is a full screen, 1x1.5 is
            // half - and a hostile push still cannot claim a shape cpu cannot render.
            verify(sizes.isLegal("1x3"), "1x3 is a LEGAL size …")
            verify(!store._sizeSupported("cpu", "1x3"), "… that cpu does not declare")
            compare(tiles[3].size, "1x1.5", "so the push is clamped to cpu's largest")
            verify(sizes.area(tiles[3].size) < sizes.area("1x3"), "the forced size was refused")
            compare(tiles[4].size, "1x2",
                    "a legal size the type DOES declare (tasks/1x2) is still honoured")
        }

        // Page names that collide with JS prototype members (toString/valueOf/
        // constructor/hasOwnProperty) must NOT be spuriously renamed by the dedup -
        // the name-set uses a null-prototype object, so these aren't false collisions.
        function test_prototype_name_not_spuriously_renamed() {
            var ok = store.applyExternal('{"pages":[{"name":"valueOf","tiles":[]},{"name":"toString","tiles":[]},{"name":"constructor","tiles":[]}]}')
            verify(ok, "did not throw")
            var names = store.pages().map(function(p){ return p.name })
            compare(names[0], "valueOf", "'valueOf' page keeps its name (not 'valueOf 2')")
            compare(names[1], "toString", "'toString' page keeps its name")
            compare(names[2], "constructor", "'constructor' page keeps its name")
        }

        // Mixed tile array: a bare string and a number are dropped; the only valid
        // tile (a plain object with a non-empty string id) survives.
        function test_bad_tiles_dropped_valid_survives() {
            var ok = store.applyExternal('{"pages":[{"tiles":["bad",3,{"id":"ok","type":"cpu"}]}]}')
            verify(ok, "did not throw")
            compare(store.pageCount(), 1, "page kept")
            var tiles = store.pages()[0].tiles
            compare(tiles.length, 1, "only the valid tile survived")
            compare(tiles[0].id, "ok", "the valid tile is the one kept")
            compare(tiles[0].type, "cpu", "its fields are intact")
            // A nameless page gets a synthesised default name (never undefined).
            compare(typeof store.pages()[0].name, "string", "page has a string name")
            verify(store.pages()[0].name.length > 0, "default page name is non-empty")
        }

        // The `_isPlainObject` predicate underpins every heal above: it is the exact
        // gate that decides whether appearance/settings/a page/a tile is a usable
        // object or junk to drop. Assert it across every branch (null / non-object /
        // array / plain object) so a regression in the predicate is caught here.
        function test_isPlainObject_predicate() {
            verify(store._isPlainObject({}), "an empty object is a plain object")
            verify(store._isPlainObject({ a: 1 }), "a populated object is a plain object")
            verify(!store._isPlainObject(null), "null is not a plain object")
            verify(!store._isPlainObject([]), "an array is not a plain object")
            verify(!store._isPlainObject(5), "a number is not a plain object")
            verify(!store._isPlainObject("x"), "a string is not a plain object")
            verify(!store._isPlainObject(undefined), "undefined is not a plain object")
        }

        // Id-less / empty-id tile objects are dropped (they'd poison settings keys).
        function test_idless_tiles_dropped() {
            var doc = store._normaliseDoc({ pages: [ { name: "P", tiles: [
                { type: "cpu" },        // no id
                { id: "", type: "gpu" },// empty id
                { id: "keep", type: "ram" }
            ] } ] })
            compare(doc.pages[0].tiles.length, 1, "only the id-bearing tile kept")
            compare(doc.pages[0].tiles[0].id, "keep")
        }

        // Missing `settings` - the doc is accepted and settings becomes an object,
        // so settingsFor() / mutations don't throw.
        function test_missing_settings_becomes_object() {
            var ok = store.applyExternal('{"pages":[{"name":"A","tiles":[{"id":"t1","type":"cpu"}]}]}')
            verify(ok, "did not throw")
            compare(typeof store.document.settings, "object", "settings is an object")
            verify(store.document.settings !== null, "settings not null")
            // Round-trips a normal read/write without exception.
            compare(store.settingsFor("t1").anything, undefined)
            store.setSetting("t1", "k", 1)
            compare(store.settingsFor("t1").k, 1)
        }

        // A non-object `settings` (e.g. a number) is coerced to {}.
        function test_settings_non_object_coerced() {
            var doc = store._normaliseDoc({ pages: [], settings: 5 })
            compare(typeof doc.settings, "object")
            verify(!Array.isArray(doc.settings), "settings is a plain object, not an array")
        }

        // Non-object pages inside the array are dropped entirely.
        function test_non_object_pages_dropped() {
            var doc = store._normaliseDoc({ pages: [ 5, "x", null, { name: "Real", tiles: [] } ] })
            compare(doc.pages.length, 1, "only the real page survived")
            compare(doc.pages[0].name, "Real")
        }

        // A well-formed document is passed through UNCHANGED (no false positives).
        function test_normal_doc_unchanged() {
            var good = {
                version: 1,
                appearance: { themeMode: "dark", accent: "cyan" },
                pages: [
                    { name: "System", tiles: [ { id: "cpu-1", type: "cpu" }, { id: "ram-1", type: "ram" } ] },
                    { name: "Life", tiles: [ { id: "clk-1", type: "clock" } ] }
                ],
                settings: { "cpu-1": { title: "CPU" } }
            }
            var ok = store.applyExternal(JSON.stringify(good))
            verify(ok, "accepted")
            compare(store.pageCount(), 2, "both pages kept")
            compare(store.pages()[0].name, "System")
            compare(store.pages()[0].tiles.length, 2)
            compare(store.pages()[0].tiles[0].id, "cpu-1")
            compare(store.pages()[1].tiles[0].type, "clock")
            compare(store.settingsFor("cpu-1").title, "CPU", "live settings preserved")
        }

        // Duplicate page names are still de-duplicated (existing behaviour intact).
        function test_duplicate_page_names_disambiguated() {
            var doc = store._normaliseDoc({ pages: [
                { name: "Work", tiles: [] }, { name: "Work", tiles: [] }
            ] })
            compare(doc.pages[0].name, "Work")
            verify(doc.pages[1].name !== "Work", "second duplicate renamed, got " + doc.pages[1].name)
        }
    }

    // ── Migration: the w/h span vocabulary → the named `size` key ────────────
    // Old `w` was a column span against the page's declared column count (so it
    // recovers exactly as w/cols). Old `h` was a row span against SIBLING tiles -
    // its real height depended on how many rows the page packed, which nothing on
    // disk records - while the new long axis is a fixed count of thirds. That half
    // of the mapping is therefore best-effort and genuinely lossy; these tests pin
    // down what it does, not that it is perfect.
    TestCase {
        name: "StoreSizeMigration"
        when: windowShown
        function init() { store.load("blank") }

        function mig(tiles, cols) {
            var page = { name: "P", tiles: tiles }
            if (cols) page.cols = cols
            return store._normaliseDoc({ pages: [page] }).pages[0].tiles
        }

        // THE COMMON CASE BY FAR: `addTile` never wrote w/h, so almost every stored
        // tile is a bare {id,type}. With the default 1-column grid it really did
        // render full-width, so the baseline `1x1` is the faithful mapping.
        function test_bare_tile_migrates_to_the_baseline() {
            var t = mig([ { id: "a", type: "cpu" } ])
            compare(t[0].size, "1x1", "a tile with no geometry lands on the baseline")
            compare(t[0].size, sizes.baseline, "which is exactly WidgetSizes.baseline")
        }

        // The mapping table, asserted case by case. `_migratedSize` is the unit
        // under test; the on-disk `cols` is what `w` was ever measured against.
        function test_migration_mapping_table() {
            // A 1-column page (the default): every tile is full-width whatever w says.
            compare(store._migratedSize({}, 1), "1x1", "1 col, no geometry → baseline")
            compare(store._migratedSize({ h: 2 }, 1), "1x2", "1 col, h:2 → two thirds tall")
            // A 2-column page: w is genuinely a half.
            compare(store._migratedSize({ w: 1, h: 1 }, 2), "0.5x1", "2 cols, w:1 → half the short axis")
            compare(store._migratedSize({ w: 2, h: 1 }, 2), "1x1", "2 cols, w:2 → the full short axis")
            compare(store._migratedSize({ w: 2, h: 2 }, 2), "1x2", "2 cols, w:2 h:2 → two thirds")
            // The case with NO exact target: half-wide + two-thirds-tall is not one
            // of the seven (the short axis has no 2-thirds partner). Area is kept.
            compare(store._migratedSize({ w: 1, h: 2 }, 2), "1x1",
                    "2 cols, w:1 h:2 (0.5x2 - illegal) keeps its THIRD of the screen as 1x1")
        }

        // The area-preserving fallback that the illegal-combination case rests on.
        function test_nearest_size_keeps_the_share_of_the_screen() {
            compare(store._nearestSize(1, 1), "1x1", "an exact match wins outright")
            compare(store._nearestSize(0.5, 0.5), "0.5x0.5", "exact, smallest")
            compare(store._nearestSize(0.5, 2), "1x1", "0.5x2 is illegal → the same 1/3 area as 1x1")
            compare(store._nearestSize(0.5, 3), "1x1.5", "0.5x3 is illegal → the same 1/2 area as 1x1.5")
        }

        // ── An unsupported size coerces DOWN, never to the default ──────────
        //
        // THE REGRESSION THIS PREVENTS: a legacy calm-focus on disk has its timer at
        // h:2, which maps to `1x2` - a real size, but not one `focus` declares (it
        // renders 1x1 and 1x1.5 only). Defaulting sent it to `1x1` and the user's
        // hero timer silently became an ordinary tile on upgrade. The size the tile
        // cannot have still carries one recoverable fact - that it was THIS BIG - so
        // it lands on the largest shape the widget can actually render.
        function test_focus_h2_coerces_down_to_its_hero_not_to_the_default() {
            var t = mig([ { id: "f", type: "focus", h: 2 } ], 1)
            compare(store._migratedSize({ h: 2 }, 1), "1x2", "h:2 maps to 1x2 …")
            verify(!catalog.supports("focus", "1x2"), "… which `focus` does not declare")
            compare(t[0].size, "1x1.5",
                    "so it coerces DOWN to the largest size focus declares - the hero timer")
            verify(t[0].size !== catalog.defaultSize("focus"),
                    "and NOT to focus's 1x1 default, which would drop the hero")
            verify(sizes.area(t[0].size) > sizes.area(sizes.baseline),
                   "the tile keeps 'this was big': half the screen, not a third")
        }

        // The same rule for the other two types the note named, so a `1x1.5`-capped
        // widget can never be quietly demoted to the baseline again.
        function test_media_and_clock_h2_also_keep_their_emphasis() {
            compare(mig([ { id: "m", type: "media", h: 2 } ], 1)[0].size, "1x1.5",
                    "media tops out at 1x1.5 and keeps it")
            compare(mig([ { id: "c", type: "clock", h: 2 } ], 1)[0].size, "1x1.5",
                    "clock tops out at 1x1.5 and keeps it")
        }

        // Coercing DOWN means down: a type whose largest is the baseline gets the
        // baseline, and never something bigger than it declares.
        // The exemplar is `hydration`, not `habit`: habit grew a 1x1.5 in W1 wave
        // 2c (it earns the best-ever record line and a transposed map), so it no
        // longer tops out at the baseline. Hydration still does, and for a reason
        // that will not drift - it keeps no history, so there is nothing to grow
        // into. The rule under test is unchanged; only the type that illustrates
        // it moved.
        function test_coerce_down_stops_at_what_the_type_declares() {
            verify(!catalog.supports("hydration", "1x1.5"), "hydration tops out at 1x1")
            compare(mig([ { id: "h", type: "hydration", h: 2 } ], 1)[0].size, "1x1",
                    "1x2 → the largest hydration declares, which IS 1x1")
        }

        // The unit rule, independent of migration.
        function test_largest_supported_at_most() {
            compare(store._largestSupportedAtMost("focus", "1x3"), "1x1.5", "clamped to the type's max")
            compare(store._largestSupportedAtMost("focus", "1x1"), "1x1", "an exact/legal size is its own answer")
            compare(store._largestSupportedAtMost("focus", "0.5x0.5"), "",
                    "focus declares nothing that small → no answer, and the caller defaults")
            compare(store._largestSupportedAtMost("nope", "1x1"), "",
                    "an unknown type declares nothing at all")
        }

        // A tile that declares nothing smaller falls back to the type's default -
        // the coercion is a preference, not a way to end up sizeless.
        function test_no_smaller_declared_size_falls_back_to_the_default() {
            var t = mig([ { id: "f", type: "focus", size: "0.5x0.5" } ], 1)
            compare(t[0].size, catalog.defaultSize("focus"),
                    "focus renders nothing at 1/12, so its default is the honest answer")
        }

        // Junk is still junk: a size that is not one of the seven cannot be ranked,
        // so it defaults rather than silently picking a neighbour.
        function test_illegal_size_still_defaults() {
            var t = mig([ { id: "c", type: "cpu", size: "banana" } ], 1)
            compare(t[0].size, catalog.defaultSize("cpu"), "an unknown size name defaults")
        }

        // A page's declared column count changes what the SAME w meant.
        function test_same_w_means_different_things_per_page() {
            var one = mig([ { id: "a", type: "cpu", w: 1 } ], 1)
            var two = mig([ { id: "a", type: "cpu", w: 1 } ], 2)
            compare(one[0].size, "1x1", "w:1 of 1 column was the whole width")
            compare(two[0].size, "0.5x1", "the same w:1 of 2 columns was only half")
        }

        // The global gridCols setting is the fallback the page override sits on.
        function test_global_gridCols_is_the_fallback_column_count() {
            var doc = store._normaliseDoc({
                appearance: { gridCols: 2 },
                pages: [ { name: "P", tiles: [ { id: "a", type: "cpu", w: 1 } ] } ]
            })
            compare(doc.pages[0].tiles[0].size, "0.5x1",
                    "w:1 is measured against the global gridCols when the page has no override")
        }

        // IDEMPOTENCE: migration is detected by `size === undefined`, so a second
        // pass must be a strict no-op - including for a size that migration itself
        // produced.
        function test_migration_is_idempotent() {
            var once = store._normaliseDoc({ pages: [ { name: "P", cols: 2, tiles: [
                { id: "a", type: "cpu" }, { id: "b", type: "ram", w: 1, h: 2 },
                { id: "c", type: "gpu", w: 2, h: 2 }
            ] } ] })
            var snapshot = JSON.stringify(once)
            var twice = store._normaliseDoc(JSON.parse(snapshot))
            compare(JSON.stringify(twice), snapshot, "a second normalise pass changes NOTHING")
            var thrice = store._normaliseDoc(JSON.parse(JSON.stringify(twice)))
            compare(JSON.stringify(thrice), snapshot, "and so does a third")
        }

        // A migrated `size` must never be re-migrated from stale w/h left beside it.
        function test_existing_size_wins_over_stale_wh() {
            var t = mig([ { id: "a", type: "cpu", size: "0.5x0.5", w: 2, h: 2 } ], 2)
            compare(t[0].size, "0.5x0.5", "the explicit size is authoritative, not the stale w/h")
            verify(t[0].w === undefined, "and the stale w is dropped so it cannot come back")
        }

        // THE HARD GUARANTEE: migration may reshape a tile, but it must never lose
        // one. A user's layout is reinterpreted, never destroyed or re-seeded.
        function test_migration_never_loses_a_tile() {
            var src = []
            for (var i = 0; i < 12; i++)
                src.push({ id: "t" + i, type: "cpu", w: (i % 2) + 1, h: (i % 2) + 1 })
            var t = mig(src, 2)
            compare(t.length, 12, "every tile survived migration")
            for (var j = 0; j < 12; j++) {
                compare(t[j].id, "t" + j, "tile " + j + " kept its id AND its order")
                verify(sizes.isLegal(t[j].size), "tile " + j + " has a legal size")
            }
        }

        // Six baseline tiles now need 12 half-rows against a 6-half-row grid. This
        // is a KNOWN, accepted consequence: capacity/packing is a separate problem,
        // and forcing tiles to fit here would destroy the layout migration exists to
        // preserve. Pinned so the overflow is a decision, not a surprise.
        function test_migrated_page_may_exceed_the_grid_capacity() {
            var src = []
            for (var i = 0; i < 6; i++) src.push({ id: "t" + i, type: "cpu" })
            var t = mig(src, 1)
            var halves = 0
            for (var j = 0; j < t.length; j++) halves += sizes.halfUnits(t[j].size, false).h
            compare(t.length, 6, "all six tiles are kept")
            compare(halves, 12, "6 x 1x1 = 12 half-rows - twice the grid's 6 (overflow is deferred, not solved)")
            verify(halves > sizes.gridRows(false), "the page genuinely overflows the grid")
        }

        // The catalog is consulted defensively: the store is instantiated standalone
        // here, and the per-type size API landed separately, so an absent/older
        // catalog degrades to "legality alone" instead of throwing.
        function test_catalog_absence_degrades_to_legality() {
            verify(store._sizeSupported("cpu", "1x1"), "a legal size is supported")
            verify(!store._sizeSupported("cpu", "2x2"), "the old span vocabulary is never supported")
            verify(!store._sizeSupported("cpu", ""), "empty is never supported")
            verify(sizes.isLegal(store._defaultSizeFor("cpu")), "the default size is always legal")
            verify(sizes.isLegal(store._defaultSizeFor("no-such-widget-type")),
                   "even for an unknown type, the fallback is legal")
            // The lookup helper returns null (not a throw) when the API is absent.
            compare(store._catalogFn("definitelyNotAFunction"), null, "an absent catalog fn resolves to null")
        }

        // The per-tile coercion helper, exercised directly on each of its branches.
        // `tasks` is the subject for the migration branch because it actually declares
        // `1x2` - with a type that does not, the two branches would fire in sequence
        // and the test could not tell which one produced the result.
        function test_coerce_tile_size_branches() {
            var fresh = { id: "a", type: "tasks", w: 2, h: 2 }
            var note = store._coerceTileSize(fresh, 2)
            compare(fresh.size, "1x2", "_coerceTileSize migrated the w/h pair")
            verify(note.length > 0, "and reported the change for the migration log")
            var hostile = { id: "b", type: "cpu", size: "2x2" }
            verify(store._coerceTileSize(hostile, 1).length > 0, "an unsupported size is reported too")
            compare(hostile.size, store._defaultSizeFor("cpu"), "and coerced to the type's default")
            var settled = { id: "c", type: "cpu", size: "1x1" }
            compare(store._coerceTileSize(settled, 1), "", "a settled tile reports nothing")
        }

        // BOTH branches on ONE tile, which is the common real case: `cpu` with h:2 on a
        // 1-column page migrates to `1x2` (geometry alone - `_migratedSize` does not
        // know about types) and is THEN coerced against the type, because cpu tops out
        // at half the screen. The two rules compose; migration does not get to smuggle
        // in a size the widget cannot render. This is exactly what the shipped presets
        // used to hit - `{ type: "focus", h: 2 }` and friends.
        function test_migration_output_is_still_type_checked() {
            compare(store._migratedSize({ h: 2 }, 1), "1x2", "geometry alone says 1x2")
            verify(!store._sizeSupported("cpu", "1x2"), "but cpu does not declare 1x2")
            var t = mig([ { id: "a", type: "cpu", h: 2 } ], 1)
            verify(t[0].size !== "1x2", "so the migrated tile does NOT land on 1x2")
            compare(t[0].size, "1x1.5",
                    "it coerces DOWN to the largest size cpu declares, keeping 'this was big'")
        }
    }
}
