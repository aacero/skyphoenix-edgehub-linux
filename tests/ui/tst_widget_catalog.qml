import QtQuick
import QtTest
import "../../ui/qml" as App

// COVERS: widget:*

// WidgetCatalog (ui/qml/WidgetCatalog.qml) - the registry every widget picker,
// the grid and the expanded overlay read from. Assert every entry is complete,
// the lookup helpers behave, categories are well-formed, and every `source`
// resolves to a real widget file in ui/qml/widgets.
Item {
    id: root
    width: 300; height: 300
    App.WidgetCatalog { id: catalog }
    // The size vocabulary, so legality is checked against its definition rather than
    // a list copied into this file (which would agree with itself forever).
    App.WidgetSizes { id: sz }

    // Context globals so a widget under test loads cleanly (like WidgetHarness),
    // letting us distinguish a present file (Loader.Ready) from a missing one
    // (Loader.Error). XHR file-reads are blocked under the default harness env,
    // so a Loader is the reliable existence probe.
    property alias theme: _theme
    App.Theme { id: _theme }
    App.DashboardStore { id: store }
    MockMedia { id: media }
    property var metrics: ({})
    property int tick: 0
    property bool expanded: false
    property bool active: true
    Loader { id: probe; anchors.fill: parent; visible: false }

    function fileExists(relPath) {
        probe.source = ""
        probe.source = relPath          // local load is synchronous
        return probe.status === Loader.Ready
    }

    TestCase {
        name: "WidgetCatalog"
        when: windowShown

        function test_items_non_empty() {
            verify(catalog.items.length > 0, "catalog has widgets")
        }

        function test_every_entry_is_complete() {
            var seen = {}
            for (var i = 0; i < catalog.items.length; i++) {
                var it = catalog.items[i]
                verify(it.type && it.type.length > 0, "entry has a type")
                verify(it.title && it.title.length > 0, it.type + " has a title")
                verify(it.category && it.category.length > 0, it.type + " has a category")
                verify(it.source && it.source.length > 0, it.type + " has a source")
                verify(it.defaults !== undefined, it.type + " has a defaults object")
                verify(seen[it.type] === undefined, "duplicate type: " + it.type)
                seen[it.type] = true
            }
        }

        function test_personal_data_classification_is_explicit_and_copied() {
            var expected = ["braindump", "break", "focus", "habit", "hydration",
                            "meds", "notes", "rightnow", "routine", "tasks"]
            var actual = []
            for (var i = 0; i < catalog.items.length; i++)
                if (catalog.hasPersonalData(catalog.items[i].type)) actual.push(catalog.items[i].type)
            actual.sort()
            compare(actual.join(","), expected.join(","))
            for (var j = 0; j < actual.length; j++) {
                verify(catalog.personalDataKeys(actual[j]).length > 0)
                verify(catalog.personalDataLabel(actual[j]).length > 0)
            }
            var copy = catalog.personalDataKeys("tasks")
            copy.push("poison")
            verify(catalog.personalDataKeys("tasks").indexOf("poison") < 0,
                   "callers cannot mutate catalog classification")
        }

        // def / source / title / desc / defaults helpers.
        function test_lookup_helpers() {
            var d = catalog.def("cpu")
            verify(d !== null && d.type === "cpu", "def returns the cpu entry")
            verify(/CpuWidget\.qml$/.test(catalog.source("cpu")), "source() resolves" + " -> " + catalog.source("cpu"))
            compare(catalog.title("cpu"), "CPU", "title() resolves")
            verify(catalog.desc("cpu").length > 0, "desc() returns a description")
            compare(catalog.def("nonexistent"), null, "def of an unknown type is null")
            compare(catalog.title("nonexistent"), "nonexistent", "title() falls back to the type")
        }

        // defaults() deep-clones so callers can't mutate the catalog's seed.
        function test_defaults_are_deep_cloned() {
            var a = catalog.defaults("focus")
            var b = catalog.defaults("focus")
            verify(a !== b, "each defaults() call returns a fresh object")
            a.preset = "MUTATED"
            compare(catalog.defaults("focus").preset, "classic",
                    "mutating a returned defaults object does not poison the catalog")
        }

        // ── Categories ───────────────────────────────────────────────────────
        function test_categories_non_empty_and_unique() {
            var cats = catalog.categories()
            verify(cats.length > 0, "at least one category")
            var seen = {}
            for (var i = 0; i < cats.length; i++) {
                verify(seen[cats[i]] === undefined, "duplicate category: " + cats[i])
                seen[cats[i]] = true
            }
        }

        function test_categories_in_declaration_order() {
            // First declared entry is 'cpu' → 'System'.
            compare(catalog.categories()[0], "System", "first category follows declaration order")
        }

        function test_inCategory_correctness() {
            var cats = catalog.categories()
            var total = 0
            for (var c = 0; c < cats.length; c++) {
                var members = catalog.inCategory(cats[c])
                verify(members.length > 0, cats[c] + " has members")
                for (var m = 0; m < members.length; m++)
                    compare(members[m].category, cats[c], "every member is in " + cats[c])
                total += members.length
            }
            compare(total, catalog.items.length, "every item belongs to exactly one category bucket")
            compare(catalog.inCategory("NoSuchCategory").length, 0, "an unknown category yields nothing")
        }

        // ── Sizes ────────────────────────────────────────────────────────────
        // Every entry declares a non-empty, LEGAL size list containing its default.
        // Legality is asked of WidgetSizes, so inventing a size here (or dropping one
        // there) fails rather than silently producing an unplaceable tile.
        function test_every_entry_declares_legal_sizes() {
            for (var i = 0; i < catalog.items.length; i++) {
                var it = catalog.items[i]
                verify(it.sizes && it.sizes.length > 0, it.type + " declares at least one size")
                for (var j = 0; j < it.sizes.length; j++)
                    verify(sz.isLegal(it.sizes[j]),
                           it.type + " declares a legal size: " + it.sizes[j])
                verify(it.dflt && it.dflt.length > 0, it.type + " has a default size")
                verify(sz.isLegal(it.dflt), it.type + " default is a legal size: " + it.dflt)
                verify(it.sizes.indexOf(it.dflt) >= 0,
                       it.type + " default " + it.dflt + " is among its own sizes")
            }
        }

        // The baseline is the contract: a widget that cannot render the size a fresh
        // instance is placed at is a bug, so it must be declared by EVERY entry.
        function test_every_entry_supports_the_baseline() {
            for (var i = 0; i < catalog.items.length; i++) {
                var it = catalog.items[i]
                verify(it.sizes.indexOf(sz.baseline) >= 0,
                       it.type + " declares the " + sz.baseline + " baseline")
                compare(catalog.supports(it.type, sz.baseline), true,
                        it.type + " supports() the baseline")
            }
        }

        // No entry declares a size it has no content for. 1x3 is the WHOLE screen -
        // it is the size a stretched card hides in, so the few that claim it are
        // pinned here by name and a new claim has to be argued for in review.
        function test_full_screen_is_rare_and_deliberate() {
            var full = []
            for (var i = 0; i < catalog.items.length; i++)
                if (catalog.items[i].sizes.indexOf("1x3") >= 0) full.push(catalog.items[i].type)
            full.sort()
            compare(full.join(","), "kpi,notes,tasks",
                    "only genuinely unbounded/billboard content declares the full screen")
        }

        // sizesFor / supports / defaultSize on a real type.
        function test_size_helpers_resolve() {
            verify(catalog.sizesFor("cpu").length > 0, "sizesFor returns cpu's sizes")
            compare(catalog.supports("cpu", "1x1"), true)
            compare(catalog.supports("cpu", "1x3"), false, "a lone ring does not fill the screen")
            compare(catalog.defaultSize("cpu"), "1x1")
        }

        // sizesFor() copies, so a caller cannot mutate the catalog's live list.
        function test_sizesFor_does_not_alias_the_catalog() {
            var a = catalog.sizesFor("cpu")
            var n = a.length
            a.push("MUTATED")
            compare(catalog.sizesFor("cpu").length, n,
                    "mutating a returned size list does not poison the catalog")
        }

        // An unknown type must be answerable, not throw - and must not report that it
        // supports anything.
        function test_size_helpers_handle_an_unknown_type() {
            compare(catalog.sizesFor("nonexistent").length, 0, "unknown type has no sizes")
            compare(catalog.supports("nonexistent", "1x1"), false,
                    "unknown type supports nothing - not even the baseline")
            compare(catalog.defaultSize("nonexistent"), sz.baseline,
                    "unknown type falls back to the WidgetSizes baseline")
        }

        // The catalog is fed user/file data (config.toml, the Manager socket), so a
        // type of "constructor" must resolve via `items`, NOT via Object.prototype.
        function test_size_helpers_are_prototype_safe() {
            var keys = ["constructor", "__proto__", "toString", "hasOwnProperty", "valueOf"]
            for (var i = 0; i < keys.length; i++) {
                compare(catalog.sizesFor(keys[i]).length, 0, keys[i] + " is not a widget type")
                compare(catalog.supports(keys[i], "1x1"), false, keys[i] + " supports nothing")
                compare(catalog.defaultSize(keys[i]), sz.baseline, keys[i] + " gets the baseline")
                compare(catalog.def(keys[i]), null, keys[i] + " has no catalog entry")
            }
        }

        // ── Every source resolves to a real widget file ──────────────────────
        function test_every_source_file_exists() {
            for (var i = 0; i < catalog.items.length; i++) {
                var src = catalog.items[i].source
                // "qrc:/qml/CpuWidget.qml" → the source-tree file under ui/qml/widgets.
                var base = src.substring(src.lastIndexOf("/") + 1)
                var rel = "../../ui/qml/widgets/" + base
                verify(fileExists(rel), catalog.items[i].type + " source file exists: " + base)
            }
        }
    }
}
