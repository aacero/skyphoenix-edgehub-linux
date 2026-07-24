import QtQuick
import QtTest
import "../../ui/qml" as App
import "../../ui/qml/widgets" as Wg

// WidgetChrome (ui/qml/widgets/WidgetChrome.qml) - the shared card frame. We
// assert the DRIVING PROPS + visual-tree wiring: title override, status text,
// chromeless surface, big layout, header-right (config-button) injection + its
// clicked signal, and the effAccent resolution (preset / fallback / loop guard).
Item {
    id: root
    width: 400; height: 400

    property alias theme: _theme
    App.Theme { id: _theme }

    property int cfgClicks: 0

    Item {
        id: host
        anchors.fill: parent
        Wg.WidgetChrome {
            id: chrome
            anchors.fill: parent
            title: "CPU"
            iconName: "cpu"
            status: ""
            // A host-injected trailing "config" button (this is how widgets add a
            // gear to the shared chrome - via the headerRightItem alias).
            headerRightItem: [
                Wg.PillButton { id: cfgBtn; glyph: "⚙"; onClicked: root.cfgClicks++ }
            ]
        }
    }

    // ── tree helpers ─────────────────────────────────────────────────────────
    function eachItem(node, fn) {
        if (!node) return
        fn(node)
        var kids = node.children
        if (kids) for (var i = 0; i < kids.length; i++) eachItem(kids[i], fn)
    }
    function findPred(node, pred) {
        var f = null
        eachItem(node, function (n) { if (!f && pred(n)) f = n })
        return f
    }
    function findText(node, str) {
        return findPred(node, function (n) {
            return n.text !== undefined && typeof n.text === "string" && n.text === str
        })
    }
    // The card surface is the sole direct-child Rectangle of the chrome root.
    function surfaceOf(c) {
        var kids = c.children
        for (var i = 0; i < kids.length; i++)
            if (kids[i].border !== undefined && kids[i].radius !== undefined) return kids[i]
        return null
    }

    TestCase {
        name: "WidgetChrome"
        when: windowShown

        function init() {
            chrome.title = "CPU"; chrome.titleOverride = ""; chrome.iconName = "cpu"
            chrome.status = ""; chrome.chromeless = false; chrome.showHeader = true
            chrome.accentName = ""; chrome.accentColor = _theme.accent
            root.cfgClicks = 0
            // Restore the DEFAULT binding, not a value: cases below assign sizeClass
            // directly, which would otherwise leak into the next case (QtTest runs
            // them alphabetically, so the geometry case ran after an override and saw
            // a stale "compact").
            chrome.sizeClass = Qt.binding(function () { return chrome.height > 240 ? "tall" : "compact" })
        }

        // ── Title / titleOverride ────────────────────────────────────────────
        function test_title_rendered() {
            verify(findText(chrome, "CPU") !== null, "the base title is rendered in the header")
        }

        function test_titleOverride_wins() {
            chrome.titleOverride = "Processor"
            verify(findText(chrome, "Processor") !== null, "a custom title override is rendered")
            verify(findText(chrome, "CPU") === null, "the base title is replaced by the override")
        }

        function test_empty_override_falls_back_to_title() {
            chrome.titleOverride = ""
            verify(findText(chrome, "CPU") !== null, "an empty override falls back to the base title")
        }

        // ── Status text ──────────────────────────────────────────────────────
        function test_status_text_rendered() {
            chrome.status = "58°C"
            var s = findText(chrome, "58°C")
            verify(s !== null, "status text is rendered top-right")
            verify(s.visible, "status is visible when non-empty")
        }

        function test_status_color() {
            chrome.status = "hot"
            chrome.statusColor = "#FF0000"
            var s = findText(chrome, "hot")
            verify(Qt.colorEqual(s.color, "#FF0000"), "status uses statusColor")
        }

        // ── Chromeless hides the frame ───────────────────────────────────────
        function test_chromeless_hides_surface_and_zeroes_margins() {
            var surf = surfaceOf(chrome)
            verify(surf !== null, "found the card surface")
            verify(surf.visible, "surface visible when framed")
            compare(chrome.contentMargins > 0, true, "framed chrome has content margins")
            chrome.chromeless = true
            verify(!surf.visible, "chromeless hides the card surface")
            compare(chrome.contentMargins, 0, "chromeless zeroes the content margins (no card-in-card padding)")
        }

        // ── Big (expanded) layout ────────────────────────────────────────────
        function test_big_derives_from_height_and_scales_header() {
            // host is 400px tall → the default sizeClass is "tall" → big (>240).
            compare(chrome.big, true, "height > 240 makes the chrome 'big'")
            compare(chrome.headerHeight, 46, "big header height")
        }

        // ── size vs expanded ─────────────────────────────────────────────────
        // REGRESSION: every widget used to declare `big: expanded`, so "big" meant
        // "is the full-screen overlay" and a 2-row TILE rendered the compact layout
        // stretched. `big` is now derived from how much ROOM the instance has.
        function test_big_is_driven_by_sizeClass_not_by_the_overlay_mode() {
            chrome.sizeClass = "compact"
            compare(chrome.big, false, "a 1x1 tile is not big")
            compare(chrome.headerHeight, 42, "and gets the compact header")

            chrome.sizeClass = "wide"
            compare(chrome.big, false, "2x1 is wide but SHORT - no vertical room, not big")

            chrome.sizeClass = "tall"
            compare(chrome.big, true, "a 1x2 tile HAS vertical room - this is the fix: " +
                                      "it used to render the compact layout stretched")
            compare(chrome.headerHeight, 46, "and now earns the big header")

            chrome.sizeClass = "large"
            compare(chrome.big, true, "2x2 is big")

            chrome.sizeClass = "full"
            compare(chrome.big, true, "the overlay is still big - unchanged from before")

            chrome.sizeClass = "compact"   // restore for the other cases
        }

        // ── micro footprint ──────────────────────────────────────────────────
        // `0.5x0.5` and `1x1` are the same SHAPE (both sizeClass "compact"), so
        // wave-1 widgets each re-derived "am I the half-cell?" locally as
        // min(width,height) < 480. That distinction now lives on the chrome -
        // derived + readonly like `big` - so later waves key off `micro` instead
        // of copy-pasting the constant.
        function test_micro_derives_from_compact_footprint() {
            chrome.sizeClass = "compact"
            // 400x400 host ≈ the half-cell footprint → micro.
            compare(chrome.micro, true, "a half-cell-sized compact tile is micro")
            // The baseline third (~696x819 portrait) is compact but NOT micro.
            root.width = 696; root.height = 819
            compare(chrome.micro, false, "the baseline 1x1 is compact but not micro")
            root.width = 400; root.height = 400
            // micro is strictly a refinement of compact - never any other class.
            chrome.sizeClass = "tall"
            compare(chrome.micro, false, "a tall tile is never micro, whatever its pixels")
            chrome.sizeClass = "compact"
        }

        // `big` must not be re-tiable to `expanded` - that override is exactly what
        // this change removes, so the property is readonly by design.
        function test_big_cannot_be_overridden_by_a_widget() {
            chrome.sizeClass = "compact"
            compare(chrome.big, false)
            // Readonly: the assignment is rejected (silently from JS - QML raises no
            // warning here), so `big` must still track sizeClass afterwards. This is
            // the guard against `big: expanded` creeping back in.
            try { chrome.big = true } catch (e) { /* expected for a readonly prop */ }
            compare(chrome.big, false, "big stayed derived - a widget cannot pin it")
            chrome.sizeClass = "tall"
            compare(chrome.big, true, "and it still follows sizeClass after the attempt")
        }

        // ── Header visibility gating ─────────────────────────────────────────
        function test_header_hidden_when_no_title_or_icon() {
            chrome.title = ""; chrome.iconName = ""
            // The header row is hidden; its title Text should no longer be visible.
            var t = findText(chrome, "CPU")
            verify(t === null || !t.visible, "header hides when there is no title and no icon")
        }

        // ── Header-right config button injection + clicked signal ────────────
        function test_config_button_injected_and_visible() {
            verify(cfgBtn !== null, "the injected config button exists")
            verify(cfgBtn.visible, "the injected config button is visible in the header")
        }

        function test_config_button_clicked_fires() {
            compare(root.cfgClicks, 0, "no clicks yet")
            cfgBtn.clicked()
            compare(root.cfgClicks, 1, "the config button's clicked signal fires to the host")
        }

        // ── effAccent resolution ─────────────────────────────────────────────
        function test_effAccent_uses_named_preset() {
            chrome.accentName = "green"
            verify(Qt.colorEqual(chrome.effAccent, _theme.accentPresets["green"].a),
                   "a named accent preset wins for effAccent")
        }

        function test_effAccent_adapts_an_unsafe_named_preset() {
            _theme.applyTheme("dark")
            chrome.accentName = "oi_black"
            verify(!Qt.colorEqual(chrome.effAccent, _theme.accentPresets["oi_black"].a),
                   "black is adapted instead of disappearing on a dark card")
            verify(_theme._minimumCardContrast(chrome.effAccent) >= 3.0,
                   "the rendered named accent clears 3:1 on every card surface")
        }

        function test_effAccent_falls_back_to_accentColor() {
            chrome.accentName = ""
            chrome.accentColor = "#AA5500"
            verify(Qt.colorEqual(chrome.effAccent, "#AA5500"),
                   "with no preset, effAccent uses accentColor")
        }

        function test_effAccent_loop_guard_uses_theme_accent() {
            chrome.accentName = ""
            chrome.accentColor = "transparent"   // a<=0 → invalid/loop → guard
            verify(Qt.colorEqual(chrome.effAccent, _theme.accent),
                   "a transparent accentColor is guarded to theme.accent (never invisible)")
        }

        // effAccent flows into the header icon tint.
        function test_effAccent_flows_to_icon() {
            chrome.accentName = "red"
            var icon = findPred(chrome, function (n) {
                return n.name === "cpu" && n.tint !== undefined && n.size !== undefined
            })
            verify(icon !== null, "header icon present")
            verify(Qt.colorEqual(icon.color, _theme.accentPresets["red"].a),
                   "the header icon is tinted with effAccent")
        }
    }
}
