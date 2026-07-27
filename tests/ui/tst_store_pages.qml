import QtQuick
import QtTest
import "../../ui/qml" as App

// Coverage for the page-level store functions added for per-page backgrounds,
// per-page columns, and unique page naming.
//
// COVERS: fn:DashboardStore.appendPreset, fn:DashboardStore._dedupPageName
// COVERS: fn:DashboardStore.pageHasRoomFor, fn:DashboardStore.pageColumns, fn:DashboardStore.setPageColumns
// COVERS: fn:DashboardStore._sizeAtShort, fn:DashboardStore._addSizeFor
// COVERS: fn:DashboardStore.pageIsFull, fn:DashboardStore.nextAddSize, fn:DashboardStore._fitSizeFor
// COVERS: fn:DashboardStore._appendBlankPage, fn:DashboardStore.pageIndexForTile
// COVERS: fn:DashboardStore.resetConfiguration, fn:DashboardStore.erasePersonalData
Item {
    width: 100; height: 100
    App.DashboardStore { id: store }

    TestCase {
        name: "StorePages"
        when: windowShown
        function init() { store.load("blank") }

        function test_unique_page_names() {
            // Blank layout starts with one "Home" page.
            store.addPage("")
            store.addPage("")
            var names = store.pages().map(function (p) { return p.name })
            var seen = {}
            for (var i = 0; i < names.length; i++) {
                verify(seen[names[i]] === undefined, "page name not duplicated: " + names[i])
                seen[names[i]] = true
            }
        }

        function test_unique_name_avoids_collision() {
            // Force a collision: rename to the name addPage would pick, then add.
            store.addPage("")           // now 2 pages
            store.renamePage(1, "Page 3")
            store.addPage("")           // would want "Page 3" → must skip to "Page 4"
            var names = store.pages().map(function (p) { return p.name })
            compare(names.filter(function (n) { return n === "Page 3" }).length, 1)
        }

        function test_per_page_background() {
            compare(store.pageBackground(0).style, undefined)
            store.setPageBackground(0, "style", "waves")
            compare(store.pageBackground(0).style, "waves")
            store.setPageBackground(0, "wallpaper", "/tmp/a.png")
            compare(store.pageBackground(0).wallpaper, "/tmp/a.png")
            // Empty clears the override (fall back to global).
            store.setPageBackground(0, "style", "")
            compare(store.pageBackground(0).style, undefined)
        }

        function test_appearance_roundtrips() {
            store.setAppearance("orientation", "landscape")
            compare(store.appearance().orientation, "landscape")
        }

        function test_bounds_guarded() {
            // Out-of-range page indices must not throw.
            store.setPageBackground(99, "style", "orbs")
            compare(store.pageBackground(99).style, undefined)
            verify(true)
        }

        // renamePage validation: blank input keeps the existing name (never yields
        // a zero-width, unclickable tab).
        function test_rename_rejects_blank() {
            var was = store.pages()[0].name
            store.renamePage(0, "   ")
            compare(store.pages()[0].name, was, "blank rename keeps the old name")
            store.renamePage(0, "Dashboard")
            compare(store.pages()[0].name, "Dashboard", "a real name is accepted")
        }

        // renamePage de-duplicates against OTHER pages so two tabs can't collide
        // (the real "two identical Page 5 tabs" bug).
        function test_rename_dedupes_against_others() {
            store.addPage("")                 // 2 pages: page0, "Page 2"
            store.renamePage(0, "Work")
            store.renamePage(1, "Work")       // collides with page0 → must be disambiguated
            compare(store.pages()[0].name, "Work")
            verify(store.pages()[1].name !== "Work", "duplicate renamed away, got " + store.pages()[1].name)
        }

        // resetSettings replaces settings with a DEEP COPY of the defaults: two
        // instances reset from the same defaults must NOT share the array instance
        // (mutating one must not leak into the other) - the B9 aliasing hazard.
        function test_reset_settings_deep_clones_defaults() {
            var defaults = { tasks: [], count: 0 }
            store.resetSettings("a", defaults)
            store.resetSettings("b", defaults)
            store.settingsFor("a").tasks.push("only-a")
            compare(store.settingsFor("a").tasks.length, 1, "a got its item")
            compare(store.settingsFor("b").tasks.length, 0, "b's array is independent")
            // And independent from the defaults object itself.
            compare(defaults.tasks.length, 0, "the defaults object is untouched")
        }

        // resetSettings drops stale keys not present in the defaults.
        function test_reset_settings_drops_stale_keys() {
            store.setSetting("c", "leftover", 42)
            store.resetSettings("c", { fresh: 1 })
            compare(store.settingsFor("c").fresh, 1)
            compare(store.settingsFor("c").leftover, undefined, "stale key removed")
        }

        function test_configuration_reset_preserves_personal_content() {
            store.patchSettings("safe", {
                goal: 99,
                title: "Temporary title",
                items: [ { id: "task-1", text: "Keep me", done: false } ],
                nextId: 7,
                staleConfig: true
            })
            verify(store.resetConfiguration("safe", { goal: 8, items: [] }, ["items", "nextId"]))
            var got = store.settingsFor("safe")
            compare(got.goal, 8, "configuration returned to its default")
            compare(got.title, undefined, "non-default configuration was removed")
            compare(got.staleConfig, undefined, "stale configuration was removed")
            compare(got.items.length, 1, "personal tasks survived")
            compare(got.items[0].text, "Keep me")
            compare(got.nextId, 7, "personal identity state survived")
        }

        function test_personal_data_erase_preserves_configuration() {
            store.patchSettings("erase", {
                goal: 12,
                accent: "gold",
                items: [ { id: "task-1", text: "Erase me", done: false } ],
                nextId: 4
            })
            compare(store.erasePersonalData("erase", ["items", "nextId"]), 2)
            var got = store.settingsFor("erase")
            compare(got.items, undefined, "task content was erased")
            compare(got.nextId, undefined, "task identity state was erased")
            compare(got.goal, 12, "widget configuration remains")
            compare(got.accent, "gold", "widget appearance remains")
        }

        function test_personal_data_erase_does_not_create_ghost_settings() {
            compare(store.erasePersonalData("missing", ["items"]), 0)
            compare(store.settingsFor("missing").items, undefined)
        }

        // ── appendPreset: add a single-page "screen" as ONE new page, additive ──
        function test_appendPreset_adds_one_page_and_leaves_appearance() {
            var before = store.pageCount()               // blank = one "Home" page
            var themeBefore = store.appearance().themeMode
            var idx = store.appendPreset("calm-focus")
            compare(idx, before, "appendPreset returns the new page index")
            compare(store.pageCount(), before + 1, "exactly one page was added")
            var pages = store.pages()
            compare(pages[idx].name, "Focus", "the added page is the screen's single page")
            verify(pages[idx].tiles.length >= 1, "the added page carries the screen's tiles")
            verify(pages[idx].bg && pages[idx].bg.style !== undefined,
                   "the screen's character rides on the page (per-page background)")
            compare(store.appearance().themeMode, themeBefore,
                    "appendPreset does NOT touch the global appearance")
            compare(pages[0].name, "Home", "the user's existing page is untouched")
        }

        function test_appendPreset_rekeys_ids_no_collision() {
            store.appendPreset("system-monitor")         // cpu/gpu/ram
            store.appendPreset("system-monitor")         // again → ids must not collide
            var ids = ({})
            var pages = store.pages()
            for (var p = 0; p < pages.length; p++)
                for (var t = 0; t < pages[p].tiles.length; t++) {
                    var id = pages[p].tiles[t].id
                    verify(ids[id] === undefined, "appendPreset re-keys tile ids uniquely: " + id)
                    ids[id] = true
                }
        }

        function test_appendPreset_unknown_id_is_refused() {
            var before = store.pageCount()
            compare(store.appendPreset("does-not-exist"), -1, "appendPreset refuses an unknown id")
            compare(store.pageCount(), before, "nothing was added")
        }

        function test_dedupPageName_avoids_collision() {
            store.appendPreset("system-monitor")         // adds a "Core" page
            var names = store.pages().map(function (p) { return p.name })
            verify(names.indexOf("Core") >= 0, "the screen added its 'Core' page")
            compare(store._dedupPageName("Core"), "Core 2", "_dedupPageName avoids the existing name")
            compare(store._dedupPageName("Brand New"), "Brand New", "a free name is returned unchanged")
        }

        // ── One page = one screen, never scrolls ─────────────────────────────
        function test_capacity_column_functions_exist() {
            verify(typeof store.pageHasRoomFor === "function", "pageHasRoomFor present")
            verify(typeof store.pageColumns === "function", "pageColumns present")
            verify(typeof store.setPageColumns === "function", "setPageColumns present")
            verify(typeof store._sizeAtShort === "function", "_sizeAtShort present")
            verify(typeof store._addSizeFor === "function", "_addSizeFor present")
            verify(typeof store._fitSizeFor === "function", "_fitSizeFor present")
            verify(typeof store._appendBlankPage === "function", "_appendBlankPage present")
            verify(typeof store.pageIndexForTile === "function", "pageIndexForTile present")
        }

        // A full screen never scrolls AND never refuses: the next widget flows onto a
        // NEW screen at its default size, so adding always succeeds.
        function test_overflow_flows_to_a_new_screen() {
            store.load("blank")                 // one screen = 6 long half-cells
            verify(store.pageHasRoomFor(0, "1x1"), "an empty page has room")
            var a = store.addTile(0, "cpu")
            var b = store.addTile(0, "gpu")
            var c = store.addTile(0, "ram")     // 3× 1x1 = full
            verify(a && b && c, "the three baselines were added")
            compare(store.pageIndexForTile(a), 0, "all three landed on the first screen")
            compare(store.pageIndexForTile(c), 0, "…still one screen so far")
            verify(store.pageIsFull(0), "the screen is now full")
            var overflow = store.addTile(0, "clock")   // no room here → new screen
            verify(overflow !== null, "adding is NEVER refused (it flows to a new screen)")
            compare(store.pageCount(), 2, "a new screen was appended")
            compare(store.pageIndexForTile(overflow), 1, "the widget landed on the new screen")
            compare(store.pages()[0].tiles.length, 3, "the first screen is untouched (no overflow on it)")
            compare(store.pages()[1].tiles[0].size, store._defaultSizeFor("clock"),
                    "on a fresh screen the widget takes its default size")
        }

        // When the preferred size does not fit but a SMALLER supported one does, the
        // widget slots into the space left rather than starting a new screen.
        function test_add_degrades_into_leftover_space() {
            store.load("blank")
            store.addTile(0, "cpu")             // 1x1  (long 0–2)
            store.addTile(0, "gpu")             // 1x1  (long 2–4)
            var d = store.addTile(0, "ram")     // 1x1  (long 4–6) → full
            store.setTileSize(0, d, "1x0.5")    // shrink ram → frees a 1x0.5 gap at long 5–6
            verify(!store.pageHasRoomFor(0, "1x1"), "no full-height 1x1 slot remains")
            verify(store.pageHasRoomFor(0, "1x0.5"), "but a 1x0.5 gap does remain")
            compare(store._fitSizeFor(0, "net"), "1x0.5",
                    "_fitSizeFor degrades net's 1x1 default down to the 1x0.5 that fits")
            var g = store.addTile(0, "net")     // default 1x1 won't fit → degrades to 1x0.5
            compare(store.pageIndexForTile(g), 0, "it fit on the same screen, not a new one")
            compare(store.pageCount(), 1, "no new screen was needed")
            verify(store._sizes.area(store.pages()[0].tiles[3].size)
                     < store._sizes.area(store._defaultSizeFor("net")),
                   "…at a smaller-than-default size, degraded to fit the leftover space")
        }

        function test_resize_refuses_overflow() {
            store.load("blank")
            var a = store.addTile(0, "cpu")
            store.addTile(0, "gpu"); store.addTile(0, "ram")   // page full (3× 1x1)
            compare(store.setTileSize(0, a, "1x1.5"), false, "a resize that would overflow the screen is refused")
            compare(store.pages()[0].tiles[0].size, "1x1", "…and the tile keeps its size")
            compare(store.setTileSize(0, a, "0.5x0.5"), true, "shrinking always fits")
        }

        function test_columns_reflow_and_default() {
            store.load("blank")
            compare(store.pageColumns(0), 1, "default is 1 column (full width)")
            store.addTile(0, "cpu")
            compare(store.pages()[0].tiles[0].size, "1x1", "1-column default is full width")
            store.setPageColumns(0, 2)
            compare(store.pageColumns(0), 2, "switched to 2 columns")
            compare(store._sizes.table[store.pages()[0].tiles[0].size].short, 0.5,
                    "the existing tile reflowed to half width")
            var id = store.addTile(0, "gpu")
            verify(id !== null, "a new tile fits (2-column tiles are narrower)")
            compare(store._sizes.table[store.pages()[0].tiles[1].size].short, 0.5,
                    "a new tile defaults to half width in 2-column mode")
            compare(store._sizes.table[store._sizeAtShort("cpu", "1x1", 0.5)].short, 0.5,
                    "_sizeAtShort finds a half-width cpu size")
            compare(store._sizeAtShort("focus", "1x1", 0.5), "",
                    "_sizeAtShort returns '' when the type has no half-width size (focus)")
            verify(store._addSizeFor(0, "gpu").length > 0, "_addSizeFor returns a size")
        }

        function test_columns_refuses_full_two_to_one_without_false_state() {
            store.load("blank")
            verify(store.setPageColumns(0, 2), "two-column mode is available")
            // Six half-width 0.5x1 tiles fill all six long half-cells. Reflowing
            // them to full width would require twelve and must be refused.
            var types = ["cpu", "gpu", "ram", "net", "disk", "clock"]
            for (var i = 0; i < types.length; i++)
                verify(store.addTile(0, types[i]) !== null, "added " + types[i])
            var before = store.pages()[0].tiles.map(function (t) { return t.size })
            verify(!store.setPageColumns(0, 1),
                   "an overflowing one-column reflow is refused")
            compare(store.pageColumns(0), 2,
                    "the persisted selector state remains two columns")
            compare(store.pages()[0].tiles.map(function (t) { return t.size }),
                    before, "every existing tile keeps its prior size")
        }

        // The Hub add-slot helpers: pageIsFull gates the "new screen" hint, nextAddSize
        // previews where/what the in-page "＋" ghost shows.
        function test_add_affordance_helpers() {
            store.load("blank")
            verify(!store.pageIsFull(0), "an empty page is not full")
            compare(store.nextAddSize(0), "1x1", "1-column add previews the baseline")
            store.setPageColumns(0, 2)
            compare(store.nextAddSize(0), "0.5x1", "2-column add previews a half-width size")
            store.setPageColumns(0, 1)                                                   // back to full width
            store.addTile(0, "cpu"); store.addTile(0, "gpu"); store.addTile(0, "ram")   // 3× 1x1 fills it
            verify(store.pageIsFull(0), "the page is now full")
            compare(store.nextAddSize(0), "", "a full page has no in-page slot to preview")
        }
    }
}
