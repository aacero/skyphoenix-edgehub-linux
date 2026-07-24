import QtQuick
import QtQuick.Layouts
import QtTest
import "../../ui/qml" as App
import "../../ui/qml/widgets" as Wg

// Shared touch controls: PillButton + SegmentedControl. Assert selection state,
// clicked / selected signals, disabled state and declarative-binding integrity.
//
// PillButton GLYPH SIZING (see PillButtonGlyph below): these assertions are
// deliberately FONT-INDEPENDENT. CI installs fonts-dejavu-core and NO emoji
// font, so the emoji codepoints here resolve to a real colour font locally and
// to a fallback/notdef box on CI - any assertion on emoji ink or on a specific
// metric value would mean two different things on the two machines. What is
// asserted instead is the structure the fix guarantees regardless of which font
// answers: the glyph size is arithmetic on theme tokens, the two runs' baselines
// COINCIDE (whatever they are), and the content row stays inside the pill.
Item {
    id: root
    width: 500; height: 300

    property alias theme: _theme
    App.Theme { id: _theme }

    property int pillClicks: 0
    property var lastSelected: undefined
    property int selectCount: 0

    // External selection source for the segmented control (declarative binding
    // that the control must NOT clobber when a segment is tapped).
    property string mode: "work"

    // A pill whose host layout is NARROWER than the pill wants to be, wired the
    // way a caller must constrain it (fillWidth + preferredWidth; maximumWidth
    // alone is ignored for an oversized implicitWidth on Qt 6.7).
    property int squeezeWidth: 90
    Item {
        id: squeezeHost
        x: 0; y: 250; width: 300; height: 90
        ColumnLayout {
            anchors.fill: parent
            Wg.PillButton {
                id: squeezed
                label: "Clear all completed"; glyph: "🧹"; primary: true
                Layout.alignment: Qt.AlignHCenter
                Layout.fillWidth: true
                Layout.preferredWidth: root.squeezeWidth
                Layout.maximumWidth: root.squeezeWidth
            }
        }
    }

    // A pill carrying a caller's "this is a hero action" floor, as the Hydration
    // overlay's Remove/Add buttons do.
    Wg.PillButton {
        id: floored
        x: 0; y: 180
        label: "Remove"; glyph: "−"; minWidth: 170
    }

    Column {
        anchors.fill: parent
        Wg.PillButton {
            id: pill
            label: "Start"; glyph: "▶"; primary: true
            onClicked: root.pillClicks++
        }
        Wg.SegmentedControl {
            id: seg
            width: 400; height: 52
            options: [ { label: "Work", value: "work" },
                       { label: "Short", value: "short" },
                       { label: "Long", value: "long" } ]
            currentValue: root.mode
            onSelected: function (v) { root.lastSelected = v; root.selectCount++ }
        }
    }

    function eachItem(node, fn) {
        if (!node) return
        fn(node)
        var kids = node.children
        if (kids) for (var i = 0; i < kids.length; i++) eachItem(kids[i], fn)
    }
    function findAll(node, pred) {
        var out = []
        eachItem(node, function (n) { if (pred(n)) out.push(n) })
        return out
    }
    // Segment delegates carry the distinctive `active` bool alongside modelData.
    function segments() {
        return findAll(seg, function (n) {
            return n.active !== undefined && n.modelData !== undefined && n.radius !== undefined
        })
    }

    TestCase {
        name: "PillButton"
        when: windowShown

        function init() { root.pillClicks = 0; pill.enabledState = true; pill.focus = false }

        function test_defaults_and_labels() {
            compare(pill.label, "Start", "label stored")
            compare(pill.glyph, "▶", "glyph stored")
            verify(pill.implicitHeight >= _theme.touchTertiary, "meets a touch-sized height")
        }

        function test_clicked_signal_fires() {
            var spy = signalSpy.createObject(root, { target: pill, signalName: "clicked" })
            mouseClick(pill)
            compare(spy.count, 1, "a tap emits clicked once")
            compare(root.pillClicks, 1, "handler ran")
            spy.destroy()
        }

        function test_keyboard_activation_fires_once() {
            pill.forceActiveFocus()
            verify(pill.activeFocus, "button accepts keyboard focus")
            keyClick(Qt.Key_Space)
            compare(root.pillClicks, 1, "Space activates the focused button")
        }

        function test_primary_vs_outline_border() {
            pill.primary = true
            compare(pill.border.width, 0, "primary (filled) button has no outline border")
            pill.primary = false
            compare(pill.border.width, 1, "outline button has a 1px border")
            pill.primary = true
        }

        function test_disabled_blocks_clicks_and_dims() {
            pill.enabledState = false
            compare(pill.opacity, 0.4, "disabled button is dimmed")
            var before = root.pillClicks
            mouseClick(pill)
            compare(root.pillClicks, before, "a disabled button does not fire clicked")
        }

        function test_danger_recolors() {
            pill.danger = true
            verify(Qt.colorEqual(pill._c, _theme.error), "danger uses the error colour")
            pill.danger = false
        }
    }

    // ── Glyph sizing / alignment / bounding ────────────────────────────────
    // The emoji glyph and the latin label are two runs with different metrics.
    // A colour-emoji run (a CBDT bitmap strike) reports line height 1.0em and
    // its ink FILLS that box with zero bearing, where a latin run's box is
    // ~1.39em with the ink inside it. The pill used to size the glyph at a
    // literal 18px and centre the two BOXES, which only lined up at textScale
    // 1.0 by coincidence.
    TestCase {
        name: "PillButtonGlyph"
        when: windowShown

        function init() { _theme.textScale = 1.0; settle() }
        function cleanup() { _theme.textScale = 1.0; settle() }

        // A textScale change re-polishes the layout. wait(0) returns BEFORE the
        // new y/height are applied, so a read then pairs a fresh baselineOffset
        // with a stale y and invents a drift that is NOT there (this bit: it
        // reported a 1.07px drift that a standalone probe measured as 0.000).
        // waitForRendering is not the tool - offscreen never swaps a frame, so it
        // just burns its 5s timeout per call. A real event-loop turn is what lets
        // the layout polish.
        function settle() { wait(16) }

        // The two Text children of the pill's content row.
        function runs(p) {
            var t = root.findAll(p, function (n) {
                return n.hasOwnProperty("text") && n.hasOwnProperty("font")
                       && n.hasOwnProperty("baselineOffset")
            })
            return { glyph: t[0], label: t[1] }
        }

        // The glyph tracks the label through the whole a11y range. Pure
        // arithmetic on theme tokens - no font is consulted, so this means the
        // same thing on CI as it does locally.
        // Asserted on the rendered Text's OWN font.pixelSize, not on btn.glyphPx:
        // checking the property only proves the arithmetic, and a Text that
        // ignores it and hardcodes 18 again would sail straight through that.
        // (Confirmed: re-freezing the Text at 18 left a glyphPx-only assertion
        // green.)
        function test_glyph_scales_with_label_font() {
            var scales = [0.8, 1.0, 1.3, 1.6]
            for (var i = 0; i < scales.length; i++) {
                _theme.textScale = scales[i]
                settle()
                var want = Math.round(_theme.fontLabel * 1.2)
                compare(pill.glyphPx, want,
                        "glyph token keeps the designed 1.2x ratio to the label at textScale "
                        + scales[i] + " (label=" + _theme.fontLabel + "px)")
                compare(runs(pill).glyph.font.pixelSize, want,
                        "…and the rendered glyph actually USES it at textScale " + scales[i])
            }
        }

        // The ratio's anchor: at textScale 1.0 the derived size reproduces the
        // literal 18 the pill used to hardcode, which is what makes this a
        // restoration of the original intent rather than a re-tune.
        function test_glyph_matches_legacy_18px_at_default_scale() {
            _theme.textScale = 1.0
            compare(_theme.fontLabel, 15, "the default label token is 15px")
            compare(pill.glyphPx, 18, "…so the derived glyph is exactly the legacy 18px")
        }

        // A frozen glyph size is what drove the two runs apart; the fix must
        // actually MOVE the glyph when the user scales text up.
        function test_glyph_is_not_frozen_across_scales() {
            _theme.textScale = 0.8
            var small = pill.glyphPx
            _theme.textScale = 1.6
            var large = pill.glyphPx
            verify(large > small,
                   "the glyph grows with the a11y text scale (0.8 -> " + small
                   + "px, 1.6 -> " + large + "px), rather than staying frozen")
        }

        // The structural guarantee that replaces box-centring. Both runs sit on
        // ONE baseline whatever the fonts are: if a fallback changes the metrics,
        // both sides of this equality move together, so it is not a font assertion.
        function test_glyph_and_label_share_a_baseline_at_every_scale() {
            var scales = [0.8, 1.0, 1.3, 1.6]
            for (var i = 0; i < scales.length; i++) {
                _theme.textScale = scales[i]
                settle()
                var r = runs(pill)
                verify(r.glyph && r.label, "both runs exist")
                var gBase = r.glyph.y + r.glyph.baselineOffset
                var lBase = r.label.y + r.label.baselineOffset
                fuzzyCompare(gBase, lBase, 0.51,
                             "glyph and label sit on the same baseline at textScale "
                             + scales[i] + " (glyph=" + gBase.toFixed(2)
                             + " label=" + lBase.toFixed(2) + ")")
            }
        }

        // The touch target is a FLOOR, and the box also has to contain its
        // content - the old flat height referenced the content nowhere.
        function test_height_is_a_floor_not_a_fixed_box() {
            var scales = [0.8, 1.0, 1.6]
            for (var i = 0; i < scales.length; i++) {
                _theme.textScale = scales[i]
                settle()
                verify(pill.implicitHeight >= _theme.touchSecondary,
                       "the touch floor holds at textScale " + scales[i])
                var row = pill.children[0]
                verify(pill.implicitHeight >= row.implicitHeight,
                       "the box contains its content at textScale " + scales[i]
                       + " (box=" + pill.implicitHeight + " content=" + row.implicitHeight + ")")
            }

            // The loop above CANNOT distinguish a derived height from the flat
            // theme.touchSecondary it replaced: textScale is clamped at 1.6, which
            // keeps the content ~40px - under the 60px floor - at every reachable
            // setting, so a hardcoded 60 satisfies it too. Drive the label token
            // past the floor directly to actually pin the binding down.
            _theme.textScale = 1.0
            _theme.fontLabel = 80
            settle()
            var big = pill.children[0]
            verify(big.implicitHeight > _theme.touchSecondary,
                   "content genuinely exceeds the touch floor now (content="
                   + big.implicitHeight + " floor=" + _theme.touchSecondary + ")")
            verify(pill.implicitHeight >= big.implicitHeight,
                   "the pill GROWS to contain content taller than the touch floor - "
                   + "the height is derived, not a fixed " + _theme.touchSecondary
                   + " (box=" + pill.implicitHeight + " content=" + big.implicitHeight + ")")
            // Restore the token's binding for the rest of the suite.
            _theme.fontLabel = Qt.binding(function () {
                return Math.round(15 * _theme.textScaleEff)
            })
            settle()
            compare(_theme.fontLabel, 15, "the fontLabel binding is restored")
        }

        // The whole point: an emoji is atomic and can only be CUT, so when the
        // pill is squeezed the label must be what gives way. Structural - it
        // compares the row against the pill, never ink against a font.
        function test_squeezed_pill_keeps_the_glyph_and_elides_the_label() {
            _theme.textScale = 1.6
            settle()
            verify(squeezed.width < squeezed.implicitWidth,
                   "the host really is squeezing the pill (w=" + squeezed.width
                   + " want=" + squeezed.implicitWidth + ")")
            var row = squeezed.children[0]
            verify(row.x >= 0,
                   "the content row does not overflow the pill's left edge - the "
                   + "leading glyph is what a symmetric overflow cuts first (x=" + row.x + ")")
            verify(row.x + row.width <= squeezed.width + 0.51,
                   "…nor its right edge (right=" + (row.x + row.width)
                   + " pill=" + squeezed.width + ")")
            var r = runs(squeezed)
            verify(r.glyph.width >= r.glyph.implicitWidth - 0.51,
                   "the glyph keeps its full advance - it is never the thing that shrinks ("
                   + r.glyph.width + " vs " + r.glyph.implicitWidth + ")")
            verify(r.label.width < r.label.implicitWidth,
                   "the LABEL is what gives way under the squeeze (" + r.label.width
                   + " < " + r.label.implicitWidth + ")")
            verify(r.label.elide === Text.ElideRight, "…by eliding")
        }

        // minWidth is a caller's FLOOR, not a fixed box - the distinction the
        // Hydration overlay's `implicitWidth: 170` got wrong. Two halves, and the
        // second is the one that bites: the floor holding is also true of a pill
        // pinned to exactly 170, so it proves nothing on its own.
        function test_min_width_is_a_floor_not_a_fixed_box() {
            var scales = [0.8, 1.0, 1.3, 1.6]
            for (var i = 0; i < scales.length; i++) {
                _theme.textScale = scales[i]
                settle()
                // The RENDERED width, not the implicit hint that feeds it.
                verify(floored.width >= floored.minWidth,
                       "the hero floor holds at textScale " + scales[i]
                       + " (w=" + floored.width + " floor=" + floored.minWidth + ")")
                var row = floored.children[0]
                verify(row.x + row.width <= floored.width + 0.51 && row.x >= 0,
                       "…and the content still sits inside it at textScale "
                       + scales[i] + " (row " + row.x.toFixed(1) + "→"
                       + (row.x + row.width).toFixed(1) + " in " + floored.width + ")")
            }

            // As with the touch floor above, the loop CANNOT tell a floor from a
            // fixed 170: textScale is clamped at 1.6, where "Remove" only wants
            // ~141px - under the floor at every reachable setting, so an
            // `implicitWidth: 170` passes it too. Drive the label token past the
            // floor directly to actually pin the binding down.
            _theme.textScale = 1.0
            _theme.fontLabel = 80
            settle()
            var big = floored.children[0]
            verify(big.implicitWidth > floored.minWidth,
                   "content genuinely exceeds the hero floor now (content="
                   + big.implicitWidth.toFixed(1) + " floor=" + floored.minWidth + ")")
            verify(floored.width >= big.implicitWidth,
                   "the pill GROWS to contain content wider than its floor - the "
                   + "width is derived, not a fixed " + floored.minWidth
                   + " (w=" + floored.width.toFixed(1) + " content="
                   + big.implicitWidth.toFixed(1) + ")")
            // …and because it grew, nothing had to give way: the label is not
            // eliding inside a button that had no reason to be narrow.
            var r = runs(floored)
            verify(r.label.width >= r.label.implicitWidth - 0.51,
                   "…so the label keeps its full width rather than eliding ("
                   + r.label.width.toFixed(1) + " vs "
                   + r.label.implicitWidth.toFixed(1) + ")")

            _theme.fontLabel = Qt.binding(function () {
                return Math.round(15 * _theme.textScaleEff)
            })
            settle()
            compare(_theme.fontLabel, 15, "the fontLabel binding is restored")
        }

        // A pill with no floor declared must be exactly its content - the floor is
        // opt-in, so the default cannot have quietly become 170-wide for everyone.
        function test_min_width_defaults_to_no_floor() {
            _theme.textScale = 1.0
            settle()
            compare(pill.minWidth, 0, "no floor by default")
            var row = pill.children[0]
            compare(pill.implicitWidth,
                    Math.max(_theme.touchSecondary,
                             Math.ceil(row.implicitWidth) + 2 * pill._padH),
                    "an unfloored pill is exactly content + padding over the touch floor")
        }

        // The mechanism behind the assertion above, pinned separately because the
        // squeeze case alone cannot see it: the glyph survives ONLY because the
        // label is the row's fillWidth item and absorbs the shortfall. Take that
        // away and there is no elastic item, so the row cannot honour the width it
        // is given and overflows the pill again - cutting the leading glyph.
        function test_label_is_the_rows_only_elastic_item() {
            var r = runs(pill)
            compare(r.label.Layout.fillWidth, true, "the label is elastic")
            compare(r.glyph.Layout.fillWidth, false, "the glyph is not")
        }
    }

    TestCase {
        name: "SegmentedControl"
        when: windowShown

        function init() { root.mode = "work"; root.lastSelected = undefined; root.selectCount = 0 }

        function test_options_rendered() {
            compare(segments().length, 3, "one delegate per option")
        }

        function test_current_value_marks_active_segment() {
            var segs = segments()
            var active = segs.filter(function (s) { return s.active })
            compare(active.length, 1, "exactly one active segment")
            compare(seg._val(active[0].modelData), "work", "the active segment matches currentValue")
        }

        function test_selected_signal_emits_value_without_clobbering_binding() {
            var target = null
            var segs = segments()
            for (var i = 0; i < segs.length; i++)
                if (seg._val(segs[i].modelData) === "short") target = segs[i]
            verify(target !== null, "found the 'short' segment")
            mouseClick(target)
            compare(root.selectCount, 1, "selected fired once")
            compare(root.lastSelected, "short", "selected carried the tapped value")
            // The control must NOT imperatively assign currentValue - the external
            // binding (root.mode) still governs it (S2 self-destruct guard).
            compare(seg.currentValue, "work", "currentValue still follows the external binding, not the tap")
        }

        function test_segment_keyboard_activation() {
            var target = segments()[1]
            target.forceActiveFocus()
            verify(target.activeFocus, "segment accepts keyboard focus")
            keyClick(Qt.Key_Return)
            compare(root.selectCount, 1, "Return activates the focused segment")
            compare(root.lastSelected, "short")
        }

        function test_external_state_change_moves_selection() {
            root.mode = "long"
            var segs = segments()
            var active = segs.filter(function (s) { return s.active })
            compare(active.length, 1, "still exactly one active segment")
            compare(seg._val(active[0].modelData), "long", "selection follows an external state change")
        }

        function test_string_options_supported() {
            seg.options = ["a", "b"]
            seg.currentValue = "b"
            var segs = segments()
            compare(segs.length, 2, "plain-string options render")
            var active = segs.filter(function (s) { return s.active })
            compare(seg._val(active[0].modelData), "b", "string option can be active")
            // restore
            seg.options = [ { label: "Work", value: "work" },
                            { label: "Short", value: "short" },
                            { label: "Long", value: "long" } ]
            seg.currentValue = Qt.binding(function () { return root.mode })
        }
    }

    Component { id: signalSpy; SignalSpy {} }
}
