import QtQuick
import QtTest
import "../../ui/qml" as App

// COVERS: fn:PresetCatalog.list, fn:PresetCatalog.def, fn:PresetCatalog.has, fn:PresetCatalog.buildDoc, fn:PresetCatalog.buildBundle
//
// The curated preset library (ui/qml/PresetCatalog.qml) drives the first-run
// "choose a screen" picker and DashboardStore.seed(). These tests guarantee the
// presets are well-formed, NOT overloaded, reference only real widget types, and
// apply cleanly through the real store (which hardens them via _normaliseDoc).
Item {
    id: root
    width: 100; height: 100

    App.PresetCatalog { id: presets }
    App.WidgetCatalog { id: catalog }
    App.WidgetConfigSchema { id: sc }
    App.DashboardStore { id: store }
    App.WidgetSizes { id: sizes }
    // The REAL packer the Dashboard uses - the budget is measured by placing the
    // tiles, never by summing them: half-width tiles pair across the short axis, so
    // a sum would reject pages that genuinely fit.
    App.WidgetPacker { id: packer }
    // The store resolves `configBridge` by unqualified name via the scope chain;
    // null = no persistence bridge (pure in-memory), so nothing touches disk.
    property var configBridge: null

    TestCase {
        name: "PresetCatalog"
        when: windowShown

        function test_library_size_and_unique_ids() {
            var list = presets.list()
            verify(list.length >= 12, "at least 12 curated presets, got " + list.length)
            verify(list.length <= 20, "not an unbounded dump, got " + list.length)
            var ids = ({})
            for (var i = 0; i < list.length; i++) {
                var p = list[i]
                verify(p.id && p.id.length, "preset has an id")
                verify(!ids[p.id], "unique preset id: " + p.id)
                ids[p.id] = 1
                verify(p.title && p.title.length, p.id + " has a title")
                verify(p.blurb && p.blurb.length, p.id + " has a blurb")
                verify(p.purpose && p.purpose.length, p.id + " explains its intended outcome")
                verify(p.setup && p.setup.length, p.id + " explains required setup")
                verify(p.pages && p.pages.length >= 1, p.id + " has at least one page")
            }
        }

        // Every preset tile type MUST exist in WidgetCatalog, and no page may be
        // overloaded (the user requirement: purposeful, well-defined, not a dump).
        function test_tiles_exist_and_not_overloaded() {
            var list = presets.list()
            for (var i = 0; i < list.length; i++) {
                var p = list[i]
                for (var pg = 0; pg < p.pages.length; pg++) {
                    var tiles = p.pages[pg].tiles
                    verify(tiles.length >= 1 && tiles.length <= 3,
                           p.id + " page '" + p.pages[pg].name + "' has 1-3 tiles (not overloaded), got " + tiles.length)
                    for (var t = 0; t < tiles.length; t++) {
                        verify(catalog.def(tiles[t].type) !== null,
                               p.id + ": tile type '" + tiles[t].type + "' exists in WidgetCatalog")
                    }
                }
            }
        }

        // README describes these exact one-screen compositions. Keeping the full
        // type and size signature here makes a product-copy change deliberate: a
        // preset cannot silently gain, lose or resize a widget while the public
        // persona promise remains unchanged.
        function test_documented_persona_compositions_are_exact() {
            var expected = ({
                "calm-focus": "focus:1x1.5|rightnow:1x1.5",
                "notes-streak": "notes:1x1.5|habit:1x1.5",
                "home-ambient": "clock:1x1.5|weather:1x1.5",
                "ambient": "media:1x1.5|moon:1x1",
                "minimal": "clock:1x1.5|weather:0.5x1|moon:0.5x1",
                "health": "hydration:1x1|break:1x1|habit:1x1",
                "creator": "media:1x1.5|focus:1x1.5",
                "study": "focus:1x1|tasks:1x1|countdown:1x1",
                "productivity": "focus:1x1.5|tasks:1x1.5",
                "remote-work": "tasks:1x1.5|eod:1x1.5",
                "gaming": "gpu:1x1.5|cpu:0.5x1|ram:0.5x1",
                "system-monitor": "cpu:1x1|gpu:1x1|ram:1x1",
                "system-io": "net:1x1|disk:1x1|sensors:1x1",
                "day-plan": "clock:1x1|calendar:1x2",
                "developer": "httpjson:1x1.5|kpi:1x1.5",
                "homelab": "httpjson:1x1.5|httpjson:1x1.5",
                "trading-desk": "clock:0.5x1|clock:0.5x1|kpi:1x1.5",
                "analyst": "kpi:1x1.5|kpi:0.5x1|httpjson:0.5x1",
                "enterprise": "eod:1x1.5|kpi:1x1.5"
            })
            var list = presets.list()
            compare(list.length, Object.keys(expected).length,
                    "every shipped preset has an explicit persona contract")
            for (var i = 0; i < list.length; i++) {
                var preset = list[i]
                verify(expected[preset.id] !== undefined,
                       preset.id + " has a documented persona contract")
                var signature = []
                for (var t = 0; t < preset.pages[0].tiles.length; t++) {
                    var tile = preset.pages[0].tiles[t]
                    signature.push(tile.type + ":" + (tile.size || catalog.defaultSize(tile.type)))
                }
                compare(signature.join("|"), expected[preset.id],
                        preset.id + " keeps its documented widget composition and density")
            }
        }

        // A preset may only name a size the tile's TYPE declares. Legality alone is
        // not enough: `1x2` is a real size, but `focus` does not render it, and a
        // preset that asked for one would be silently coerced by the store - the
        // preset would ship a layout its author never saw.
        function test_every_preset_tile_size_is_declared_by_its_type() {
            var list = presets.list()
            for (var i = 0; i < list.length; i++) {
                var p = list[i]
                for (var pg = 0; pg < p.pages.length; pg++) {
                    var tiles = p.pages[pg].tiles
                    for (var t = 0; t < tiles.length; t++) {
                        var ty = tiles[t].type, sz = tiles[t].size
                        if (sz === undefined) continue   // the type's own default
                        verify(sizes.isLegal(sz), p.id + ": '" + sz + "' is a real size")
                        verify(catalog.supports(ty, sz),
                               p.id + " page '" + p.pages[pg].name + "': type '" + ty +
                               "' declares size '" + sz + "' (declares: " +
                               catalog.sizesFor(ty).join(", ") + ")")
                    }
                }
            }
        }

        // THE POINT OF THIS FILE: no preset page may run past one screen.
        //
        // The scroll axis follows the LONG axis, which in the default 2560x720
        // landscape is the same axis as the SwipeView's page swipe - on an
        // OVERFLOWING landscape page the inner Flickable wins the drag and the
        // PageIndicator becomes the only way to change pages. A page that fits never
        // scrolls, so the conflict cannot arise. This test is what makes that
        // property hold: 14 of the 17 original pages overflowed (worst 2.0x), and
        // without an assertion the next preset silently reintroduces it.
        //
        // Measured through the real store, so a preset is judged on the sizes it
        // ACTUALLY ships with after normalisation (including per-type defaults),
        // not on what it wrote down.
        function test_no_preset_page_exceeds_the_long_axis_budget() {
            var list = presets.list()
            for (var i = 0; i < list.length; i++) {
                var doc = presets.buildDoc(list[i].id)
                verify(store.applyExternal(JSON.stringify(doc)), list[i].id + " applies")
                var pages = store.pages()
                for (var pg = 0; pg < pages.length; pg++) {
                    var extent = packer.longExtent(packer.pack(pages[pg].tiles))
                    verify(extent <= sizes.longHalves,
                           list[i].id + " page '" + pages[pg].name + "' fits one screen: " +
                           extent + " of " + sizes.longHalves + " long half-cells" +
                           (extent > sizes.longHalves
                              ? " (overflows by " + (extent / sizes.longHalves).toFixed(2) + "x)" : ""))
                }
            }
        }

        // calm-focus's hero timer is the regression this epic's migration fix exists
        // for: `focus` tops out at 1x1.5, so a preset asking for more used to be
        // coerced to the 1x1 default and the "big timer" its blurb promises quietly
        // became an ordinary tile. Assert the shipped preset keeps a hero - a size
        // strictly larger than the baseline.
        function test_calm_focus_keeps_a_hero_timer() {
            var doc = presets.buildDoc("calm-focus")
            verify(store.applyExternal(JSON.stringify(doc)), "calm-focus applies")
            var found = null
            var pages = store.pages()
            for (var pg = 0; pg < pages.length; pg++) {
                var tiles = pages[pg].tiles
                for (var t = 0; t < tiles.length; t++)
                    if (tiles[t].type === "focus") found = tiles[t]
            }
            verify(found !== null, "calm-focus ships a focus timer")
            compare(found.size, "1x1.5", "the timer is the largest size `focus` declares")
            verify(sizes.area(found.size) > sizes.area(sizes.baseline),
                   "the timer is a HERO - bigger than the 1x1 baseline, not coerced down to it")
        }

        // A preset ships per-tile `settings`, but nothing at runtime validates them:
        // an unknown key is silently ignored, so a typo (`listmax`) would ship a tile
        // that quietly doesn't do what the preset intends. Every key must therefore be
        // either universal (honoured by WidgetChrome for ANY widget, see
        // Dashboard.injectWidget) or declared in that type's config schema.
        function test_preset_settings_keys_are_real() {
            var universal = { "title": 1, "accent": 1, "cardBackdrop": 1 }
            var list = presets.list()
            for (var i = 0; i < list.length; i++) {
                var p = list[i]
                for (var pg = 0; pg < p.pages.length; pg++) {
                    var tiles = p.pages[pg].tiles
                    for (var t = 0; t < tiles.length; t++) {
                        if (!tiles[t].settings) continue
                        var known = ({})
                        var schema = sc.schemaFor(tiles[t].type)
                        for (var s = 0; s < schema.sections.length; s++) {
                            var fields = schema.sections[s].fields || []
                            for (var f = 0; f < fields.length; f++) known[fields[f].key] = 1
                        }
                        for (var k in tiles[t].settings)
                            verify(universal[k] === 1 || known[k] === 1,
                                   p.id + ": tile '" + tiles[t].type + "' setting '" + k +
                                   "' is a real config key (universal or in its schema)")
                    }
                }
            }
        }

        // The data-connected presets are the payoff of the primitive widgets (E1):
        // they must actually carry a data tile, and must ship it UNCONFIGURED - the
        // endpoint is the user's to supply, so a preset must never guess a URL (which
        // would poll a stranger's host on first run). A blank url/filePath also means
        // the widget's own polling stays off until the user connects it.
        function test_data_presets_ship_labelled_but_unconnected_tiles() {
            var expected = ["developer", "homelab", "trading-desk", "analyst", "enterprise"]
            for (var i = 0; i < expected.length; i++) {
                var p = presets.def(expected[i])
                verify(p !== null, expected[i] + " exists")
                var dataTiles = 0
                for (var pg = 0; pg < p.pages.length; pg++) {
                    var tiles = p.pages[pg].tiles
                    for (var t = 0; t < tiles.length; t++) {
                        var ty = tiles[t].type
                        if (ty !== "httpjson" && ty !== "kpi") continue
                        dataTiles++
                        var st = tiles[t].settings || {}
                        verify(st.title && st.title.length,
                               expected[i] + ": data tile is labelled (a named slot, not a bare 'HTTP / JSON')")
                        verify(!st.url, expected[i] + ": data tile ships with NO url - the user connects it")
                        verify(!st.filePath, expected[i] + ": data tile ships with NO filePath")
                    }
                }
                verify(dataTiles >= 1, expected[i] + " carries at least one HTTP/JSON or KPI tile")
            }
        }

        // buildDoc materializes a valid ui_state with unique tile ids.
        function test_buildDoc_valid_unique_ids() {
            var list = presets.list()
            for (var i = 0; i < list.length; i++) {
                var doc = presets.buildDoc(list[i].id)
                verify(doc && doc.pages && doc.pages.length >= 1, list[i].id + " buildDoc has pages")
                compare(doc.version, 1, "doc version")
                var seen = ({})
                for (var pg = 0; pg < doc.pages.length; pg++) {
                    var tiles = doc.pages[pg].tiles
                    for (var t = 0; t < tiles.length; t++) {
                        var id = tiles[t].id
                        verify(id && !seen[id], list[i].id + ": unique tile id " + id)
                        seen[id] = 1
                        verify(tiles[t].type && tiles[t].type.length, "tile has a type")
                    }
                }
            }
        }

        // Every preset applies through the REAL store (which normalises/hardens it).
        function test_buildDoc_applies_through_store() {
            var list = presets.list()
            for (var i = 0; i < list.length; i++) {
                var doc = presets.buildDoc(list[i].id)
                var ok = store.applyExternal(JSON.stringify(doc))
                verify(ok, list[i].id + " applies through the store")
                compare(store.pages().length, doc.pages.length, list[i].id + " page count preserved")
            }
        }

        function test_unknown_id_is_null() {
            compare(presets.def("does-not-exist"), null)
            compare(presets.buildDoc("does-not-exist"), null)
            verify(!presets.has("does-not-exist"))
            verify(presets.has("productivity"), "legacy 'productivity' id is a preset")
        }

        // Every preset is now a SINGLE page (the "screen" model): applying one adds
        // exactly one page.
        function test_every_preset_is_a_single_page() {
            var list = presets.list()
            for (var i = 0; i < list.length; i++)
                compare(list[i].pages.length, 1, list[i].id + " is a single-page screen")
        }

        function test_screen_presets_never_set_accessibility_preferences() {
            for (var i = 0; i < presets.items.length; i++) {
                var p = presets.items[i]
                verify(p.appearance.reduceMotion === undefined,
                       p.id + ": reduced motion must remain an explicit user or OS preference")
            }
        }

        // buildBundle composes several single-page screens into one document - the
        // "a few starter screens" a fresh install begins with.
        function test_buildBundle_composes_several_screens() {
            var doc = presets.buildBundle(["productivity", "system-monitor", "home-ambient"])
            verify(doc && doc.pages && doc.pages.length === 3, "buildBundle makes one page per screen")
            var seen = ({})
            for (var pg = 0; pg < doc.pages.length; pg++)
                for (var t = 0; t < doc.pages[pg].tiles.length; t++) {
                    var id = doc.pages[pg].tiles[t].id
                    verify(!seen[id], "buildBundle keeps tile ids unique across the bundle: " + id)
                    seen[id] = 1
                }
            verify(doc.pages[0].bg && doc.pages[0].bg.style !== undefined,
                   "bundle pages carry their screen's character as a per-page background")
            verify(!doc.appearance.themeMode && !doc.appearance.accent,
                   "a bundle sets no global theme/accent (the user's look governs)")
            verify(store.applyExternal(JSON.stringify(doc)), "the bundle applies through the store")
            compare(store.pages().length, 3, "…as three pages")
            compare(presets.buildBundle(["productivity", "nope"]).pages.length, 1,
                    "buildBundle skips unknown ids")
        }

        // DashboardStore.seed() routes through the preset library; "blank" stays blank.
        function test_store_seed_uses_presets() {
            store.load("gaming")
            verify(store.pages().length >= 1, "seeding 'gaming' produced a layout")
            store.load("minimal")
            verify(store.pages().length >= 1, "seeding 'minimal' produced a layout")
            store.load("blank")
            compare(store.pages().length, 1, "blank has one page")
            compare(store.pages()[0].tiles.length, 0, "blank page has no tiles")
        }
    }
}
