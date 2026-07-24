import QtQuick
import QtTest
import "../../ui/qml" as App

// COVERS: fn:Dashboard._loadUserWidgets, fn:Dashboard._userWidgetsFlag
//
// Tier-0 user widgets (E3) - ui/qml/UserWidgetCatalog.qml + the Dashboard
// loader wiring + the WidgetCatalog.userItems seam:
//   • a valid manifest loads, registers, and its entry QML renders (both
//     standalone and through the real Dashboard tile pipeline)
//   • malformed JSON / missing manifest / wrong manifestVersion / missing
//     entry file / bad sizes / bad dflt / bad config fields → skipped, each
//     with a human-readable reason, never a throw
//   • a type colliding with a shipped type is rejected (and even a forcibly
//     injected duplicate cannot shadow shipped: def() scans shipped first)
//   • sizes are validated against WidgetSizes and only declared sizes are
//     offered (resize cycle) or accepted (store.setTileSize)
//   • no icon → the bundled fallback glyph, never a blank picker tile
//   • flag off (the DEFAULT) → nothing is scanned at all: the injected scan
//     provider is provably never invoked
Item {
    id: root
    width: 900; height: 600

    // ── Shell surface the real Dashboard binds to (as in tst_dashboard) ──────
    property alias theme: _theme
    App.Theme { id: _theme }
    property string accentName: "blue"
    property real glassOpacity: 0.5
    property bool showWidgetGlow: true
    property bool reduceMotion: false
    property string themeMode: "dark"
    property bool animatedBackground: true
    property string orientationMode: "auto"
    property string metricsJson: "{}"
    property string screensData: "[]"

    Loader {
        id: ld
        anchors.fill: parent
        source: "../../ui/qml/Dashboard.qml"
    }

    // ── Standalone instances for pure validation tests ───────────────────────
    App.WidgetSizes { id: wsizes }
    App.WidgetCatalog { id: shipped }
    App.WidgetConfigSchema { id: sharedSchema }
    App.UserWidgetCatalog {
        id: uwc
        sizesModel: wsizes
        shippedTypes: {
            var out = []
            for (var i = 0; i < shipped.items.length; i++) out.push(shipped.items[i].type)
            return out
        }
    }

    // Render probe for a validated entry's source URL.
    Loader { id: renderLd; width: 300; height: 200 }

    // ── Fixture material ─────────────────────────────────────────────────────
    // Absolute path of the on-disk fixture widget directory.
    readonly property string fixtureDir: {
        var u = Qt.resolvedUrl("fixtures/user-widgets/hello").toString()
        return u.replace(/^file:\/\//, "")
    }
    function helloManifest(over) {
        var m = { manifestVersion: 1, type: "user.hello", title: "Hello",
                  category: "User", description: "A minimal Tier-0 fixture widget.",
                  entry: "HelloTile.qml", sizes: ["1x2", "1x1"], dflt: "1x1",
                  defaults: { who: "fixture" },
                  config: [ { key: "who", label: "Name", type: "text",
                              placeholder: "world", dflt: "world" } ] }
        for (var k in over) m[k] = over[k]
        return m
    }
    // A scan entry exactly as ConfigBridge.listUserWidgets() emits one.
    function scanEntry(over) {
        var e = { dir: root.fixtureDir, dirName: "hello",
                  files: ["HelloTile.qml", "manifest.json"],
                  manifest: JSON.stringify(root.helloManifest({})) }
        for (var k in over) e[k] = over[k]
        return JSON.stringify(e)
    }

    // ── Dashboard-shell helpers (as in tst_dashboard) ────────────────────────
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
    property var _store: null
    function store() {
        if (!_store)
            _store = findPred(ld.item, function (x) {
                return x && x.applyExternal !== undefined && x.structureRevision !== undefined
            })
        return _store
    }
    function makeDoc(tiles, appearance) {
        return JSON.stringify({ version: 1, appearance: appearance || {}, settings: {},
            pages: [ { name: "P1", tiles: tiles || [] } ] })
    }
    property int scanCalls: 0

    // ═════════════════════════════════════════════════════════════════════════
    TestCase {
        name: "UserWidgetCatalog"
        when: windowShown

        function init() { uwc.clear(); renderLd.source = "" }

        function test_valid_manifest_loads() {
            uwc.load([root.scanEntry({})])
            compare(uwc.rejects.length, 0, "nothing skipped")
            compare(uwc.items.length, 1, "one widget registered")
            var it = uwc.items[0]
            compare(it.type, "user.hello")
            compare(it.title, "Hello")
            compare(it.category, "User")
            compare(it.dflt, "1x1")
            // Declared ["1x2","1x1"] → presented smallest → largest.
            compare(JSON.stringify(it.sizes), JSON.stringify(["1x1", "1x2"]))
            compare(it.defaults.who, "fixture")
            compare(it.source, "file://" + root.fixtureDir + "/HelloTile.qml")
            verify(it.user === true)
        }

        function test_valid_entry_renders() {
            uwc.load([root.scanEntry({})])
            compare(uwc.items.length, 1)
            renderLd.source = uwc.items[0].source
            tryVerify(function () { return renderLd.status === Loader.Ready }, 5000,
                      "user entry QML loads from the file:// source")
            verify(renderLd.item !== null, "entry instantiated")
            compare(renderLd.item.who, "world", "widget default honoured with no store")
        }

        function test_malformed_json_skipped_with_reason() {
            uwc.load([root.scanEntry({ manifest: "{ this is not json" })])
            compare(uwc.items.length, 0, "nothing registered")
            compare(uwc.rejects.length, 1, "one skip recorded")
            compare(uwc.rejects[0].dir, root.fixtureDir)
            verify(uwc.rejects[0].reason.indexOf("not valid JSON") >= 0,
                   "reason names the malformed JSON: " + uwc.rejects[0].reason)
        }

        function test_missing_manifest_skipped() {
            uwc.load([root.scanEntry({ manifest: undefined, error: "missing manifest.json" })])
            compare(uwc.items.length, 0)
            compare(uwc.rejects[0].reason, "missing manifest.json")
        }

        function test_wrong_version_skipped() {
            uwc.load([root.scanEntry({ manifest: JSON.stringify(root.helloManifest({ manifestVersion: 2 })) })])
            compare(uwc.items.length, 0)
            verify(uwc.rejects[0].reason.indexOf("manifestVersion") >= 0)
        }

        function test_unnamespaced_type_rejected() {
            uwc.load([root.scanEntry({ manifest: JSON.stringify(root.helloManifest({ type: "cpu" })) })])
            compare(uwc.items.length, 0, "a shipped-style bare type never registers")
            verify(uwc.rejects[0].reason.indexOf("user.<name>") >= 0,
                   "namespace rule cited: " + uwc.rejects[0].reason)
        }

        function test_shipped_collision_rejected() {
            // Defence in depth: even a correctly-namespaced type is refused if a
            // (hypothetical future) shipped type claims the same name.
            var guarded = ["user.hello"]
            var prev = uwc.shippedTypes
            uwc.shippedTypes = guarded
            uwc.load([root.scanEntry({})])
            var reason = uwc.rejects.length ? uwc.rejects[0].reason : "<none>"
            var count = uwc.items.length
            uwc.shippedTypes = prev
            compare(count, 0, "collision with a shipped type never registers")
            verify(reason.indexOf("collides with a shipped widget type") >= 0,
                   "collision reason cited: " + reason)
        }

        function test_duplicate_user_type_skipped() {
            uwc.load([root.scanEntry({}), root.scanEntry({ dirName: "hello2" })])
            compare(uwc.items.length, 1, "first directory wins")
            compare(uwc.rejects.length, 1)
            verify(uwc.rejects[0].reason.indexOf("duplicate") >= 0)
        }

        function test_missing_entry_file_skipped() {
            uwc.load([root.scanEntry({ manifest: JSON.stringify(root.helloManifest({ entry: "Nope.qml" })) })])
            compare(uwc.items.length, 0)
            verify(uwc.rejects[0].reason.indexOf("not found") >= 0)
        }

        function test_entry_path_escape_rejected() {
            uwc.load([root.scanEntry({ manifest: JSON.stringify(root.helloManifest({ entry: "../evil.qml" })) })])
            compare(uwc.items.length, 0, "parent traversal in entry is refused")
            verify(uwc.rejects[0].reason.indexOf("plain .qml file name") >= 0)
        }

        function test_illegal_size_skipped() {
            uwc.load([root.scanEntry({ manifest: JSON.stringify(root.helloManifest({ sizes: ["1x1", "2x2"] })) })])
            compare(uwc.items.length, 0)
            verify(uwc.rejects[0].reason.indexOf("illegal size") >= 0,
                   "size vocabulary enforced: " + uwc.rejects[0].reason)
            // Empty list is refused too.
            uwc.load([root.scanEntry({ manifest: JSON.stringify(root.helloManifest({ sizes: [] })) })])
            compare(uwc.items.length, 0)
        }

        function test_dflt_must_be_declared() {
            uwc.load([root.scanEntry({ manifest: JSON.stringify(root.helloManifest({ dflt: "1x3" })) })])
            compare(uwc.items.length, 0)
            verify(uwc.rejects[0].reason.indexOf("dflt") >= 0)
            // Omitted dflt falls back to the baseline when declared.
            var m = root.helloManifest({}); delete m.dflt
            uwc.load([root.scanEntry({ manifest: JSON.stringify(m) })])
            compare(uwc.items.length, 1)
            compare(uwc.items[0].dflt, "1x1")
        }

        function test_bad_config_fields_skipped() {
            uwc.load([root.scanEntry({ manifest: JSON.stringify(root.helloManifest(
                { config: [ { key: "title", label: "X", type: "text" } ] })) })])
            compare(uwc.items.length, 0, "reserved key refused")
            verify(uwc.rejects[0].reason.indexOf("reserved") >= 0)
            uwc.load([root.scanEntry({ manifest: JSON.stringify(root.helloManifest(
                { config: [ { key: "run", label: "Run", type: "action" } ] })) })])
            compare(uwc.items.length, 0, "host-owned field type refused")
            verify(uwc.rejects[0].reason.indexOf("unsupported field type") >= 0)
        }

        function test_missing_icon_gets_fallback_glyph() {
            // No icon declared → bundled fallback glyph (never a blank tile).
            uwc.load([root.scanEntry({})])
            compare(uwc.items[0].iconName, uwc.fallbackIcon)
            compare(uwc.items[0].iconSource, "")
            // Declared but absent on disk → still loads, still the fallback.
            uwc.load([root.scanEntry({ manifest: JSON.stringify(root.helloManifest({ icon: "nope.svg" })) })])
            compare(uwc.items.length, 1, "missing icon file is not fatal")
            compare(uwc.items[0].iconName, uwc.fallbackIcon)
            // Declared and present → the widget's own file, untinted.
            uwc.load([root.scanEntry({ files: ["HelloTile.qml", "manifest.json", "own.svg"],
                                       manifest: JSON.stringify(root.helloManifest({ icon: "own.svg" })) })])
            compare(uwc.items[0].iconName, "")
            compare(uwc.items[0].iconSource, "file://" + root.fixtureDir + "/own.svg")
        }

        function test_catalog_seam_and_iconFor() {
            uwc.load([root.scanEntry({})])
            shipped.userItems = uwc.items
            compare(shipped.source("user.hello"), "file://" + root.fixtureDir + "/HelloTile.qml")
            compare(shipped.title("user.hello"), "Hello")
            compare(shipped.desc("user.hello"), "A minimal Tier-0 fixture widget.")
            compare(JSON.stringify(shipped.sizesFor("user.hello")), JSON.stringify(["1x1", "1x2"]))
            compare(shipped.defaultSize("user.hello"), "1x1")
            verify(shipped.categories().indexOf("User") >= 0, "user category appears in the picker")
            compare(shipped.inCategory("User").length, 1)
            // Icon resolution: user fallback glyph vs shipped by-type.
            compare(shipped.iconFor("user.hello").name, uwc.fallbackIcon)
            compare(shipped.iconFor("cpu").name, "cpu")
            // SHIPPED WINS: even a forcibly-injected duplicate of a shipped type
            // cannot shadow it - def() consults shipped items first.
            shipped.userItems = [{ type: "cpu", title: "Evil", category: "User",
                                   source: "file:///tmp/evil.qml", defaults: {},
                                   sizes: ["1x1"], dflt: "1x1" }]
            verify(/CpuWidget\.qml$/.test(shipped.source("cpu")), "def() resolves the shipped entry, not the user one" + " -> " + shipped.source("cpu"))
            shipped.userItems = []
        }

        function test_schema_composition() {
            uwc.load([root.scanEntry({})])
            var s = uwc.schemaFor("user.hello", sharedSchema)
            verify(s && s.sections && s.sections.length === 4,
                   "Settings + General + About + Appearance")
            compare(s.sections[0].title, "Settings")
            compare(s.sections[0].fields[0].key, "who")
            compare(s.sections[1].fields[0].key, "title")
            compare(s.sections[3].fields[0].key, "accent")
            // Unknown type falls through to the shared schema.
            var u = uwc.schemaFor("cpu", sharedSchema)
            verify(u && u.sections && u.sections.length > 0)
        }

        function test_report_json() {
            uwc.load([root.scanEntry({}), root.scanEntry({ dirName: "bad", dir: "/tmp/bad",
                                                           manifest: "{ nope" })])
            var r = JSON.parse(uwc.reportJson(true, "/data/widgets"))
            compare(r.enabled, true)
            compare(r.dir, "/data/widgets")
            compare(r.loaded.length, 1)
            compare(r.loaded[0].type, "user.hello")
            compare(r.skipped.length, 1)
            verify(r.skipped[0].reason.indexOf("not valid JSON") >= 0)
            r = JSON.parse(uwc.reportJson(false, ""))
            compare(r.enabled, false)
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    TestCase {
        name: "DashboardUserWidgets"
        when: windowShown

        function initTestCase() {
            tryVerify(function () { return ld.status === Loader.Ready && ld.item !== null }, 5000)
            verify(root.store() !== null, "found Dashboard's private DashboardStore")
        }

        function init() {
            var d = ld.item
            root.scanCalls = 0
            d.userWidgetProvider = function () { root.scanCalls++; return [root.scanEntry({})] }
        }

        function cleanup() {
            var d = ld.item
            d.userWidgetProvider = null
            root.store().applyExternal(root.makeDoc([], {}))
            d._loadUserWidgets()
        }

        function test_flag_off_by_default_nothing_scanned() {
            var d = ld.item
            // A document WITHOUT the flag - the default state.
            root.store().applyExternal(root.makeDoc([], {}))
            verify(!d._userWidgetsFlag(), "enableUserWidgets defaults to OFF")
            compare(d._loadUserWidgets(), 0, "flag off registers nothing")
            compare(root.scanCalls, 0, "flag off → the scan provider was NEVER invoked")
            compare(root.store()._catalog.userItems.length, 0, "store catalog untouched")
        }

        function test_flag_on_loads_and_renders() {
            var d = ld.item
            root.store().applyExternal(root.makeDoc([], { enableUserWidgets: true }))
            verify(d._userWidgetsFlag(), "flag read from persisted appearance")
            compare(d._loadUserWidgets(), 1, "one user widget registered")
            compare(root.scanCalls, 1, "exactly one scan")
            // Registered in the store's catalog too (size validation path).
            compare(root.store()._catalog.sizesFor("user.hello").length, 2)

            // Add a tile of the user type through the real store → the real
            // tile pipeline loads the file:// entry and WidgetHost seeds the
            // manifest defaults ({who:"fixture"}).
            root.store().addTile(0, "user.hello")
            var tiles = root.store().pages()[0].tiles
            compare(tiles.length, 1)
            compare(tiles[0].size, "1x1", "fresh instance gets the manifest dflt")
            tryVerify(function () {
                return root.findPred(ld.item, function (x) { return x && x.who === "fixture" }) !== null
            }, 5000, "user widget rendered inside the dashboard with its manifest defaults")
        }

        function test_sizes_validated_and_offered() {
            var d = ld.item
            root.store().applyExternal(root.makeDoc([], { enableUserWidgets: true }))
            compare(d._loadUserWidgets(), 1)
            var id = root.store().addTile(0, "user.hello")
            // Only declared sizes are accepted…
            compare(root.store().setTileSize(0, id, "1x3"), false, "undeclared size refused")
            compare(root.store().setTileSize(0, id, "1x2"), true, "declared size accepted")
            // …and the resize affordance cycles exactly the declared list.
            compare(d.nextSize("user.hello", "1x1"), "1x2")
            compare(d.nextSize("user.hello", "1x2"), "1x1", "cycle wraps within declared sizes")
        }

        function test_flag_off_again_clears_without_scan() {
            var d = ld.item
            root.store().applyExternal(root.makeDoc([], { enableUserWidgets: true }))
            compare(d._loadUserWidgets(), 1)
            compare(root.scanCalls, 1)
            // A pushed document that drops the flag (e.g. managed config
            // forcing user widgets off) - applyExternalState re-runs the
            // loader by itself.
            d.applyExternalState(root.makeDoc([], {}))
            verify(!d._userWidgetsFlag(), "pushed appearance turned the flag off")
            compare(root.store()._catalog.userItems.length, 0, "registry cleared")
            compare(root.scanCalls, 1, "no further scan after the flag went off")
        }

        function test_malformed_manifest_never_breaks_the_dashboard() {
            var d = ld.item
            d.userWidgetProvider = function () {
                root.scanCalls++
                return [root.scanEntry({ manifest: "{ nope" }), root.scanEntry({ dirName: "ok" })]
            }
            root.store().applyExternal(root.makeDoc([], { enableUserWidgets: true }))
            compare(d._loadUserWidgets(), 1, "the valid sibling still loads")
            // The dashboard is intact: shipped types still resolve and render.
            verify(/ClockWidget\.qml$/.test(root.store()._catalog.source("clock")),
                   "source() resolves to ClockWidget (bundle or tree): " + root.store()._catalog.source("clock"))
        }
    }
}
