import QtQuick
import QtTest
import "../../ui/qml" as App


// PackagesWidget - the installed-package count.
//
// The widget reads a C++ bridge (`distro`) that does not exist in this harness,
// which is the point of two of these cases: with no bridge it must render a
// waiting state, never "0 packages". Everything else injects a FAKE probe via
// `distroOverride`, so the numbers here are pinned rather than whatever the box
// running the suite happens to have installed.
Item {
    id: root
    width: 420; height: 320
    property int refreshCalls: 0

    // The shape the real DistroBridge exposes: `ready` + `info`.
    function fakeDistro(info) { return { ready: true, info: info } }
    function archInfo(count) {
        return { id: "arch", name: "Arch Linux", family: "arch", packageCount: count,
                 unsupportedReason: null, updates: null, securityUpdates: null,
                 updatesReason: "Local package metadata may be stale.",
                 installEpoch: 1709251200 }
    }
    function findObjectName(node, name) {
        if (!node) return null
        if (node.objectName === name) return node
        var children = node.children || []
        for (var i = 0; i < children.length; i++) {
            var found = findObjectName(children[i], name)
            if (found) return found
        }
        return null
    }

    // Resolve a Text by its exact content, so an assertion can name the surface a
    // setting governs when that surface has no objectName (audit 2026-08-03).
    function findText(node, exact) {
        if (!node) return null
        if (node.text !== undefined && String(node.text) === exact) return node
        var kids = node.children || []
        for (var i = 0; i < kids.length; i++) {
            var found = findText(kids[i], exact)
            if (found) return found
        }
        return null
    }

    WidgetHarness { id: h; anchors.fill: parent; widgetFile: "PackagesWidget.qml" }
    App.WidgetConfigSchema { id: sc }
    App.WidgetCatalog { id: catalog }

    TestCase {
        name: "PackagesWidget"
        when: windowShown

        function init() {
            tryVerify(function () { return h.ready }, 3000)
            var s = h.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            h.storeCtl._touchSettings()
            h.item.distroOverride = null
            h.expanded = false
            root.height = 320
            h.item.sizeClass = "compact"
            root.refreshCalls = 0
        }
        function set(k, v) { h.storeCtl.setSetting("test-instance", k, v) }

        // No bridge (this harness, and any host that fails to register it): the
        // widget must say "we don't know yet", NOT "you have 0 packages".
        function test_degrades_when_the_bridge_is_absent() {
            var w = h.item
            verify(w !== null, "widget loaded with no `distro` context property")
            compare(w.loading, true, "no bridge -> loading")
            compare(w.counted, false, "no bridge -> nothing counted")
            compare(w.distroName, "", "no bridge -> no distro name")
        }

        // A bridge that exists but has not answered yet is still "loading".
        function test_unready_bridge_is_still_loading() {
            var w = h.item
            w.distroOverride = { ready: false, info: ({}) }
            compare(w.loading, true, "ready:false -> loading")
            compare(w.counted, false)
        }

        function test_shows_a_real_count() {
            var w = h.item
            w.distroOverride = fakeDistro(archInfo(1461))
            compare(w.loading, false)
            compare(w.counted, true)
            compare(w.count, 1461)
            compare(w.distroName, "Arch Linux")
            compare(w.packageSource, "/var/lib/pacman/local")
            verify(w.countScope.indexOf("one package directory") >= 0)
        }

        // Zero is a REAL answer (a scratch chroot) and must not be confused with
        // "unknown" - this is the whole reason the core sends null, not 0.
        function test_zero_packages_is_a_real_count_not_unknown() {
            var w = h.item
            w.distroOverride = fakeDistro(archInfo(0))
            compare(w.counted, true, "0 is counted")
            compare(w.count, 0)
            compare(w.loading, false)
        }

        // The documented RPM outcome: no number, and the reason is surfaced
        // rather than swallowed.
        function test_unsupported_family_shows_a_reason_not_a_number() {
            var w = h.item
            w.distroOverride = fakeDistro({
                id: "fedora", name: "Fedora Linux 40", family: "rpm",
                packageCount: null, updates: null, installEpoch: null,
                unsupportedReason: "RPM systems need librpm to read the package database; this build does not shell out to rpm."
            })
            compare(w.counted, false, "null count -> not counted")
            compare(w.loading, false, "we DID get an answer; it just isn't a number")
            verify(w.reason.indexOf("librpm") >= 0, "the reason is shown verbatim")
            compare(w.distroName, "Fedora Linux 40")
            compare(w.packageSource, "RPM family detected · database count unavailable")
            verify(w.countScope.indexOf("no package process") >= 0)
        }

        // Grouped with a THIN SPACE (U+2009) - a comma or a point means different
        // things either side of the Atlantic. Written as an escape, not a literal:
        // the separator is invisible in source, and asserting it with a plain
        // ASCII space would "fail" against correct output for reasons no one could
        // see in the diff.
        function test_group_digits() {
            var w = h.item
            var sep = "\u2009"
            compare(w.groupDigits(0), "0")
            compare(w.groupDigits(7), "7")
            compare(w.groupDigits(999), "999", "no separator below 1000")
            compare(w.groupDigits(1461), "1" + sep + "461")
            compare(w.groupDigits(12345), "12" + sep + "345")
            compare(w.groupDigits(1234567), "1" + sep + "234" + sep + "567")
            // It is a thin space, NOT an ASCII space.
            verify(w.groupDigits(1461).indexOf(" ") < 0, "must not use an ASCII space")
        }

        // The option must actually change what's rendered - no decorative toggles.
        function test_showDistro_controls_the_header_status() {
            var w = h.item
            w.distroOverride = fakeDistro(archInfo(1461))
            set("showDistro", true)
            compare(w.showDistro, true)
            compare(w.status, "Arch Linux", "the distro name rides in the header")
            set("showDistro", false)
            compare(w.showDistro, false)
            compare(w.status, "", "toggled off -> no name in the header")
        }

        // Audit 2026-08-03: the header status was covered above, but showDistro
        // gates THREE surfaces (PackagesWidget.qml:123 header, :158 the shaped
        // tile's detail card, :287 the expanded distro name). The other two had
        // no coverage, so the toggle could have stopped governing either of them
        // unnoticed.
        function test_showDistro_also_gates_the_card_and_the_expanded_name() {
            var w = h.item
            w.distroOverride = fakeDistro(archInfo(1461))

            // Shaped tile: the detail card.
            h.expanded = false
            w.sizeClass = "wide"
            verify(w.shapedTile, "precondition: a shaped tile")
            set("showDistro", true)
            var card = findObjectName(w, "packageDetailCard")
            verify(card !== null, "the detail card exists")
            verify(card.visible, "the detail card shows while the toggle is on")
            set("showDistro", false)
            compare(card.visible, false, "the detail card hides when the toggle is off")

            // Expanded: the large distro name.
            h.expanded = true
            set("showDistro", true)
            var name = findText(w, "Arch Linux")
            verify(name !== null, "the expanded view names the distro while the toggle is on")
            verify(name.visible, "and it is visible")
            set("showDistro", false)
            compare(name.visible, false,
                    "the expanded distro name hides when the toggle is off")
            h.expanded = false
        }

        // Defaults must match the schema's `dflt`, or a fresh tile and its config
        // form disagree about what is on.
        function test_defaults_match_the_schema() {
            var w = h.item
            compare(w.showDistro, true, "default matches schema dflt")
            var fields = sc.schemaFor("packages").sections[0].fields
            compare(fields[0].key, "showDistro")
            compare(fields[0].dflt, true)
        }

        function test_renders_expanded_without_errors() {
            var w = h.item
            w.distroOverride = fakeDistro(archInfo(1461))
            h.expanded = true
            wait(0)
            compare(w.count, 1461, "count survives the expanded relayout")
            compare(w.status, "", "expanded hides the header status")
        }

        function test_catalog_caps_packages_at_one_by_one() {
            var item = null
            for (var i = 0; i < catalog.items.length; i++)
                if (catalog.items[i].type === "packages") item = catalog.items[i]
            verify(item !== null)
            compare(item.sizes.indexOf("1x1.5"), -1)
            verify(item.sizes.indexOf("1x1") >= 0)
        }

        function test_manual_refresh_is_read_only_visible_and_touch_safe() {
            var w = h.item
            root.height = 640
            w.sizeClass = "tall"
            w.distroOverride = {
                ready: true,
                info: archInfo(1461),
                refreshing: false,
                refreshedAtMs: Date.now(),
                refresh: function () { root.refreshCalls++ }
            }
            verify(w.shapedTile)
            verify(w.refreshLabel.indexOf("Refreshed") === 0)
            w.refreshNow()
            compare(root.refreshCalls, 1)
            var card = findObjectName(w, "packageDetailCard")
            verify(card !== null && card.visible)
            var touchTargets = []
            function scan(node) {
                if (!node) return
                if (node.objectName === "packageRefreshAction")
                    touchTargets.push(node)
                var children = node.children || []
                for (var i = 0; i < children.length; i++) scan(children[i])
            }
            scan(w)
            compare(touchTargets.length, 1)
            verify(touchTargets[0].width >= 52 && touchTargets[0].height >= 52)
        }

        function test_large_layout_explains_unknown_update_and_security_counts() {
            var w = h.item
            root.height = 640
            w.sizeClass = "tall"
            w.distroOverride = fakeDistro(archInfo(1461))
            compare(w.updateSummary, "Not checked")
            compare(w.securitySummary, "Not checked")
            verify(w.updatesReason.indexOf("stale") >= 0)
            var card = findObjectName(w, "packageUpdateContext")
            verify(card !== null && card.visible)
        }
    }
}
