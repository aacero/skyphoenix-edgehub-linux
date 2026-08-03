import QtQuick
import QtTest
import "../../ui/qml" as App


// ─────────────────────────────────────────────────────────────────────────
// widget:analog - comprehensive coverage for AnalogClockWidget.qml plus its
// shared config surfaces (WidgetConfigSchema "analog" + DashboardStore).
//
// The face is drawn on a Canvas, so behaviour is verified two ways:
//   1. Derived properties/functions the widget exposes (cfg, showSeconds,
//      showNumerals, effAccent, title, big, showHeader).
//   2. Actual repaints, counted by connecting to the Canvas `painted()` signal
//      of the loaded widget instance. This lets us lock the "single-driver
//      rule" (the `active` flag) and the theme-reactivity contract.
//
// Assertions that FAIL do so because of a real bug in the widget (documented
// inline with BUG:) - those are intentionally left failing.
// ─────────────────────────────────────────────────────────────────────────
Item {
    id: root
    width: 480; height: 360

    // Normal, expanded host used by most tests.
    Item {
        id: box; anchors.fill: parent
        WidgetHarness { id: h; anchors.fill: parent; widgetFile: "AnalogClockWidget.qml"; expanded: true }
    }

    // A deliberately tiny host so Math.min(cx,cy)-6 <= 0 (rad<=0 branch).
    Item {
        width: 10; height: 10
        WidgetHarness { id: hTiny; anchors.fill: parent; widgetFile: "AnalogClockWidget.qml"; expanded: false }
    }

    // Shared config schema, instantiated directly (store/schema area).
    App.WidgetConfigSchema { id: sc }

    // ── Canvas paint probe ────────────────────────────────────────────────
    // We rebind `probe.target` to a widget's inner Canvas and count paints.
    property var probeCanvas: null
    property int paintCount: 0
    Connections {
        id: probe
        target: root.probeCanvas
        ignoreUnknownSignals: true
        function onPainted() { root.paintCount++ }
    }

    function findCanvas(node) {
        if (!node) return null
        var kids = node.children
        for (var i = 0; i < (kids ? kids.length : 0); i++) {
            var c = kids[i]
            if (c && typeof c.requestPaint === "function" && c.hasOwnProperty("canvasSize"))
                return c
            var found = findCanvas(c)
            if (found) return found
        }
        return null
    }

    // ─────────────────────────────────────────────────────────────────────
    TestCase {
        id: tc
        name: "AnalogClock"
        when: windowShown

        function initTestCase() {
            tryVerify(function () { return h.ready }, 3000)
            root.probeCanvas = root.findCanvas(h.item)
            verify(root.probeCanvas !== null, "found the widget's Canvas")
        }

        function init() {
            tryVerify(function () { return h.ready }, 3000)
            // Clear per-instance settings back to an empty document.
            var s = h.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            h.storeCtl._touchSettings()
            // Reset accent override + probe.
            h.item.accentName = ""
            h.theme.applyTheme("dark")
            root.paintCount = 0
        }
        function set(k, v) { h.storeCtl.setSetting("test-instance", k, v) }

        // Let any queued/async paints flush, then zero the counter so the next
        // measured action starts from a clean, deterministic baseline.
        function settle() { wait(150); root.paintCount = 0 }

        // Wait until at least one paint has happened since the baseline.
        function waitPaint(baseline, why) {
            tryVerify(function () { return root.paintCount > baseline }, 2000, why)
        }

        // ── Config plumbing ────────────────────────────────────────────────

        function test_defaults_when_settings_empty() {
            // BUG-free contract: with no settings the widget falls back to
            // showSeconds=true, showNumerals=false (matches the schema).
            var w = h.item
            compare(w.showSeconds, true, "default second hand on")
            compare(w.showNumerals, false, "default numerals off")
        }

        function test_schema_defaults_match_widget_fallback() {
            var s = sc.schemaFor("analog")
            var display = null
            for (var i = 0; i < s.sections.length; i++)
                if (s.sections[i].title === "Display") display = s.sections[i]
            verify(display !== null, "analog schema has a Display section")
            var seen = {}
            for (var j = 0; j < display.fields.length; j++)
                seen[display.fields[j].key] = display.fields[j].dflt
            compare(seen.showSeconds, true, "schema default showSeconds=true")
            compare(seen.showNumerals, false, "schema default showNumerals=false")
            compare(seen.faceStyle, "classic", "schema default faceStyle=classic")
            compare(seen.handStyle, "round", "schema default handStyle=round")
            var all = {}
            for (var si = 0; si < s.sections.length; si++)
                for (var fi = 0; fi < (s.sections[si].fields || []).length; fi++)
                    all[s.sections[si].fields[fi].key] = true
            verify(all.customZone && all.zoneId && all.zoneLabel && all.utcOffset,
                   "world-clock configuration is complete")
            var zoneIdField = null, offsetField = null
            for (var zi = 0; zi < s.sections.length; zi++)
                for (var zj = 0; zj < (s.sections[zi].fields || []).length; zj++) {
                    var field = s.sections[zi].fields[zj]
                    if (field.key === "zoneId") zoneIdField = field
                    if (field.key === "utcOffset") offsetField = field
                }
            verify(zoneIdField.visibleWhen !== undefined,
                   "IANA selection is hidden until world-clock mode is enabled")
            verify(Array.isArray(offsetField.visibleWhen)
                   || typeof offsetField.visibleWhen.length === "number",
                   "fixed offset has both world-clock and empty-IANA visibility rules")
        }

        function test_showSeconds_honored() {
            var w = h.item
            set("showSeconds", false)
            compare(w.showSeconds, false, "showSeconds=false honored")
            set("showSeconds", true)
            compare(w.showSeconds, true, "showSeconds=true honored")
        }

        function test_showNumerals_honored() {
            var w = h.item
            set("showNumerals", true)
            compare(w.showNumerals, true, "showNumerals=true honored")
            set("showNumerals", false)
            compare(w.showNumerals, false, "showNumerals=false honored")
        }

        function test_style_and_world_clock_settings() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { faceStyle: "minimal", handStyle: "slender",
                customZone: true, zoneId: "", utcOffset: 5.5, zoneLabel: "Mumbai" })
            compare(w.faceStyle, "minimal")
            compare(w.handStyle, "slender")
            compare(w.displayZoneLabel(), "Mumbai")
        }

        function test_named_zone_uses_timezone_bridge() {
            var w = h.item
            w.timeZones = ({ isValid: function (id) { return id === "Asia/Tokyo" },
                             offsetSecsAt: function () { return 9 * 3600 },
                             format: function (id, ms, fmt) { return "TOKYO-" + fmt } })
            h.storeCtl.patchSettings("test-instance", { customZone: true, zoneId: "Asia/Tokyo", zoneLabel: "" })
            compare(w.zoneResolvable(), true)
            compare(w.displayZoneLabel(), "Tokyo")
            compare(w.formatAt("HH:mm"), "TOKYO-HH:mm")
            w.timeZones = null
        }

        function test_named_zone_clock_parts_use_bridge_wall_time() {
            var w = h.item
            w.timeZones = ({
                isValid: function (id) { return id === "Asia/Tokyo" },
                offsetSecsAt: function () { return 9 * 3600 },
                format: function (id, ms, fmt) {
                    return fmt === "H|m|s|z" ? "21|34|56|789" : "TOKYO-" + fmt
                }
            })
            h.storeCtl.patchSettings("test-instance", {
                customZone: true, zoneId: "Asia/Tokyo"
            })
            var parts = w.clockPartsAt(new Date(Date.UTC(2026, 6, 15, 12)))
            compare(parts.hour, 21)
            compare(parts.minute, 34)
            compare(parts.second, 56)
            compare(parts.millisecond, 789)
            w.timeZones = null
        }

        function test_invalid_named_zone_is_disclosed() {
            var w = h.item
            w.timeZones = ({
                isValid: function () { return false },
                offsetSecsAt: function () { return 0 },
                format: function () { return "" }
            })
            h.storeCtl.patchSettings("test-instance", {
                customZone: true, zoneId: "Mars/Olympus_Mons",
                utcOffset: 2, zoneLabel: ""
            })
            compare(w.invalidZone, true)
            compare(w.status, "Invalid time zone")
            compare(w.displayZoneLabel(), "Invalid zone · UTC+2",
                    "the face discloses both the invalid zone and active fallback")
            w.timeZones = null
        }

        function test_fixed_offset_label_formats_fractional_offsets() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", {
                customZone: true, zoneId: "", utcOffset: 5.5, zoneLabel: ""
            })
            compare(w.displayZoneLabel(), "UTC+5:30")
            set("utcOffset", -3.5)
            compare(w.displayZoneLabel(), "UTC-3:30")
        }

        function test_reduce_motion_suppresses_second_hand() {
            var w = h.item
            set("showSeconds", true)
            settle()
            h.theme.reduceMotionPreference = "on"
            compare(w.effectiveShowSeconds, false)
            waitPaint(0, "turning Reduce Motion on repaints to remove the second hand")
            settle()
            h.theme.reduceMotionPreference = "off"
            compare(w.effectiveShowSeconds, true)
            waitPaint(0, "turning Reduce Motion off repaints to restore the second hand")
            h.theme.reduceMotionPreference = "auto"
        }

        function test_cfg_reacts_to_store_revision() {
            var w = h.item
            var r0 = h.storeCtl.revision
            set("showNumerals", true)
            verify(h.storeCtl.revision > r0, "setSetting bumps store.revision")
            compare(w.cfg.showNumerals, true, "cfg re-reads after revision bump")
        }

        function test_cfg_is_a_snapshot_copy() {
            // cfg is JSON.parse(JSON.stringify(...)) - a copy, not the live obj.
            var w = h.item
            set("showNumerals", true)
            var snap = w.cfg
            snap.showNumerals = false          // mutate the copy
            compare(w.showNumerals, true, "mutating the cfg copy doesn't affect the widget")
        }

        // ── Identity / chrome ──────────────────────────────────────────────

        function test_title_and_icon() {
            var w = h.item
            compare(w.title, "Analog", "widget title")
            compare(w.iconName, "analog", "widget icon name")
        }

        function test_expanded_drives_big_and_header() {
            // Harness is expanded:true → big + header shown.
            var w = h.item
            compare(w.big, true, "expanded ⇒ big")
            compare(w.showHeader, true, "expanded ⇒ header shown")
        }

        // ── Accent (effAccent) ─────────────────────────────────────────────

        function test_default_effAccent_is_catSystem() {
            var w = h.item
            compare(String(w.effAccent), String(h.theme.catSystem),
                    "with no per-widget accent, effAccent = catSystem")
        }

        function test_accent_recolors_and_repaints() {
            var w = h.item
            settle()
            w.accentName = "red"
            compare(String(w.effAccent).toLowerCase(),
                    String(h.theme.accentPresets["red"].a).toLowerCase(),
                    "accentName=red ⇒ effAccent tracks the red preset")
            // onEffAccentChanged ⇒ a repaint.
            waitPaint(0, "changing the accent repaints the face")
        }

        // ── Repaint contract (paint probe) ─────────────────────────────────

        function test_tick_triggers_repaint() {
            var w = h.item
            settle()
            w.tick++
            waitPaint(0, "a tick repaints the canvas")
        }

        function test_showSeconds_change_repaints() {
            settle()
            set("showSeconds", false)   // onShowSecondsChanged ⇒ requestPaint
            waitPaint(0, "toggling the second hand repaints")
        }

        function test_showNumerals_change_repaints() {
            settle()
            set("showNumerals", true)   // onShowNumeralsChanged ⇒ requestPaint
            waitPaint(0, "toggling numerals repaints")
        }

        function test_resize_repaints() {
            // Component.onCompleted + onWidthChanged/onHeightChanged ⇒ paint.
            // The face is square and sized by the LIMITING dimension (here the
            // height, on a 480x360 host), so resize that one - a width-only
            // change legitimately leaves the square face untouched.
            settle()
            root.height = 330
            waitPaint(0, "a size change repaints the canvas")
            root.height = 360
        }

        // ── Real-bug locks (intentionally failing) ─────────────────────────

        function test_inactive_does_not_repaint() {
            // FIXED, and this test pins it (audit medium). The defect was:
            // `active` is declared (line 8) but never read. The tile loader sets
            // active=false for off-screen / expanded / edit-mode tiles (single-
            // driver rule, Dashboard.qml:14) so those clocks should stop
            // repainting. They don't - the tick Connections (line 72) fires
            // unconditionally. Correct behaviour: no repaint.
            var w = h.item
            h.active = false            // ⇒ item.active = false via harness binding
            compare(w.active, false, "widget received active=false")
            settle()
            w.tick++                    // a background tick while inactive
            wait(300)
            compare(root.paintCount, 0,
                    "an inactive clock must NOT repaint on tick (single-driver rule)")
            h.active = true
        }

        function test_theme_switch_repaints_face() {
            // FIXED, and this test pins it (audit low). The defect was: onPaint
            // reads theme.cardBorder / textTertiary / textSecondary /
            // textPrimary at paint time, but nothing watches those roles - there
            // is no Connections on `theme`. A dark→light switch that leaves
            // effAccent unchanged does NOT repaint, so the
            // ring/ticks/hands/numerals keep the old palette until the next
            // tick. Correct behaviour: the switch repaints the face.
            settle()
            h.theme.applyTheme("light")
            wait(300)
            verify(root.paintCount > 0,
                   "switching app theme should repaint the face with new role colors")
        }
    }

    // ── Per-sizeClass structure (W1) ──────────────────────────────────────
    // Fixed-size hosts at real projected cell footprints; the Dashboard injects
    // sizeClass, so the tests assign it the same way and pin what each size
    // shows - a future edit can't silently collapse the sizes back into one
    // stretched face.
    Item { id: aMicroWrap; width: 344; height: 416
        WidgetHarness { id: hAMicro; anchors.fill: parent; widgetFile: "AnalogClockWidget.qml"; expanded: false } }
    Item { id: aBaseWrap; width: 696; height: 840
        WidgetHarness { id: hABase; anchors.fill: parent; widgetFile: "AnalogClockWidget.qml"; expanded: false } }
    Item { id: aWideWrap; width: 696; height: 416
        WidgetHarness { id: hAWide; anchors.fill: parent; widgetFile: "AnalogClockWidget.qml"; expanded: false } }
    Item { id: aTallWrap; width: 344; height: 840
        WidgetHarness { id: hATall; anchors.fill: parent; widgetFile: "AnalogClockWidget.qml"; expanded: false } }

    // Find a rendered Text whose content matches `re` (e.g. the digital time).
    function findTextMatch(node, re) {
        if (!node) return null
        if (typeof node.text === "string" && node.hasOwnProperty("elide") && re.test(node.text))
            return node
        var kids = node.children
        for (var i = 0; kids && i < kids.length; i++) {
            var r = findTextMatch(kids[i], re)
            if (r) return r
        }
        return null
    }

    TestCase {
        name: "AnalogClockSizes"
        when: windowShown

        // 0.5x0.5 - the face IS the widget: no header, no date, no digital time.
        function test_micro_face_only() {
            tryVerify(function () { return hAMicro.ready }, 3000)
            var w = hAMicro.item
            w.sizeClass = "compact"
            compare(w.micro, true, "a 344x416 compact box is the micro tile")
            compare(w.showDate, false, "micro shows no date line")
            compare(w.showDigital, false, "micro shows no digital time")
            compare(w.showHeader, false, "no header competes with the face on a tile")
        }

        // 1x1 - face + date beneath it, still no digital duplicate.
        function test_baseline_face_plus_date() {
            tryVerify(function () { return hABase.ready }, 3000)
            var w = hABase.item
            w.sizeClass = "compact"
            compare(w.micro, false, "696x840 compact is the baseline, not micro")
            compare(w.showDate, true, "the 1x1 earns the date line")
            compare(w.showDigital, false, "the 1x1 does NOT add a digital time")
            // Locale-tolerant: "Wed, 16 July" (en) or "Mi., 16. Juli" (de).
            var date = root.findTextMatch(w, /^[A-Za-zÄÖÜäöü]{2,4}\.?,? ?\d/)
            verify(date !== null && date.visible, "the date line is rendered")
        }

        // wide - face beside digital time + date, in BOTH projections of the
        // class (1x0.5 portrait 696x416, 0.5x1 landscape 840x344).
        function test_wide_face_beside_time_both_orientations() {
            tryVerify(function () { return hAWide.ready }, 3000)
            var w = hAWide.item
            w.sizeClass = "wide"
            compare(w.horiz, true, "wide puts the info column beside the face")
            compare(w.showDigital, true, "wide earns the digital time")
            var time = root.findTextMatch(w, /^\d{2}:\d{2}/)
            verify(time !== null && time.visible, "the digital time is rendered")
            aWideWrap.width = 840; aWideWrap.height = 344
            compare(w.showDigital, true, "the landscape projection keeps the info column")
            aWideWrap.width = 696; aWideWrap.height = 416
        }

        // tall - face above digital time + date.
        function test_tall_face_above_time() {
            tryVerify(function () { return hATall.ready }, 3000)
            var w = hATall.item
            w.sizeClass = "tall"
            compare(w.horiz, false, "tall stacks the info under the face")
            compare(w.showDigital, true, "tall earns the digital time")
            var time = root.findTextMatch(w, /^\d{2}:\d{2}/)
            verify(time !== null && time.visible, "the digital time is rendered")
        }

        // full (the overlay) - header + face + the full info block.
        function test_full_has_header_and_info() {
            tryVerify(function () { return h.ready }, 3000)
            var w = h.item
            var prev = w.sizeClass
            w.sizeClass = "full"
            compare(w.micro, false, "full is never micro")
            compare(w.showDigital, true, "the overlay shows the digital time")
            compare(w.showDate, true, "and the date")
            w.sizeClass = prev
        }
    }

    // ── Edge case: zero-radius tile ───────────────────────────────────────
    TestCase {
        name: "AnalogClockTiny"
        when: windowShown

        function initTestCase() { tryVerify(function () { return hTiny.ready }, 3000) }

        function test_tiny_tile_paints_without_error() {
            // rad = min(cx,cy)-6 <= 0 on a 10x10 host → onPaint clears and
            // returns early. It must not throw and the widget stays valid.
            var w = hTiny.item
            verify(w !== null, "tiny widget loaded")
            verify(w.width <= 12 || w.height <= 12, "host is small enough for rad<=0")
            w.tick++            // force a paint through the rad<=0 branch
            wait(150)
            verify(hTiny.ready, "widget survives painting a zero-radius face")
        }
    }
}
