import QtQuick
import QtQuick.Controls
import QtTest
import "GuiUtil.js" as G

// ─────────────────────────────────────────────────────────────────────────
// VISIBLE GUI tests for the Hub SHELL - Orientation + SettingsPanel.
//
// Hosts the REAL shell (ui/qml/main.qml → Dashboard.qml) ONCE in initTestCase,
// replacing its resolved initial page with one deterministic source-tree
// Dashboard. Every case
// asserts an OBJECTIVE, GUI-observable outcome after a real interaction:
//   • Orientation - win.contentRotation ∈ {0,90,180,270}, the contentRoot
//     aspect swap, grabImage aspect, current-page PRESERVED across a rotation
//     (the rotation analogue of the add-page snap-back), the reorient fx dip,
//     and reduce-motion collapsing both the fx and the rotation.
//   • SettingsPanel - every control, driven by REAL mouse input under KWin;
//     CRUCIALLY a REAL DRAG of the glass slider (mousePress/Move/Release) that
//     must NOT snap back after a wait AND after a churny store revision (the
//     glass-slider regression, S2).
//
// Pure ORIENTATION transform cases run with the shell window HIDDEN (grabImage
// works on the hidden window per tst_gui_sample.qml, and a hidden toplevel can
// be resized freely so aspect grabs are deterministic). The rendered grid case
// maps the window so Qt polishes nested layouts. SETTINGS cases show the window
// (ensureShown) so real mouse events deliver to the separate ApplicationWindow,
// and force portrait (contentRotation 0) so the sheet is upright under the
// cursor. Tests run alphabetically: every test_ori_* precedes every test_set_*.
// ─────────────────────────────────────────────────────────────────────────
Item {
    id: root
    width: 1280; height: 720

    // ---- Shell context props (main.qml reads these as `property x: _x`) ----
    property bool _isFirstRun: false
    property string _screens: "[]"
    property string _metricsJson: "{}"
    property string _themeMode: "midnight"
    property string _targetEdidHash: ""
    property string _targetConnector: ""
    property string _targetModel: ""
    property string _configDir: "/tmp"
    property bool _safeMode: false
    property bool _startInDiagnostics: false
    property bool _windowedMode: true
    property int _targetScreenX: 0
    property int _targetScreenY: 0
    property int _targetScreenWidth: 1280
    property int _targetScreenHeight: 720

    property var win: null

    TestCase {
        id: tc
        name: "GuiShellOrientSettings"
        when: windowShown
        visible: true

        // Cached live shell objects (resolved once in initTestCase).
        property var swipe: null
        property var dash: null
        property var store: null
        property var panel: null
        property var cr: null           // the rotating contentRoot (has `swapped`)
        property var theme: null
        property var checker: null
        property bool _shown: false
        readonly property int baseW: 1200
        readonly property int baseH: 700
        readonly property var rotSet: [0, 90, 180, 270]

        function snap(item, name) {
            var img = G.grabItem(this, item, win.contentItem)
            img.save("gui-evidence/sos_" + name + ".png")
            return img
        }

        // ── generic helpers over the live scene ──────────────────────────────
        function findExactText(node, str) {
            return G.findPred(node, function (n) {
                return n && n.text !== undefined && typeof n.text === "string" && n.text === str })
        }
        function effVisible(item) {
            var n = item
            while (n) { if (n.visible === false) return false; n = n.parent }
            return true
        }
        function findSlider() {
            return G.findPred(panel, function (n) {
                return n && n.from !== undefined && n.to !== undefined
                        && n.value !== undefined && n.stepSize !== undefined })
        }
        function findFlick() {
            return G.findPred(panel, function (n) {
                return n && n.contentHeight !== undefined && n.contentY !== undefined
                        && n.boundsBehavior !== undefined })
        }
        function bringIntoView(target) {
            var scroll = findFlick()
            verify(scroll !== null, "found the settings Flickable")
            var p = target.mapToItem(scroll.contentItem, 0, 0)
            var maxY = Math.max(0, scroll.contentHeight - scroll.height)
            scroll.contentY = Math.max(0, Math.min(maxY, p.y - 40))
            wait(80)
        }
        function delegateWhere(pred) {
            return G.findPred(panel, function (n) {
                return n && n.active !== undefined && n.modelData !== undefined && pred(n) })
        }
        function accentSwatchFor(name) {
            return G.findPred(panel, function (n) {
                return n && n.modelData === name && n.color !== undefined && n.radius === 26 })
        }
        function switchForLabel(labelText) {
            var t = findExactText(panel, labelText)
            if (!t) return null
            var rowKids = t.parent.children
            for (var i = 0; i < rowKids.length; i++)
                if (rowKids[i].checked !== undefined && rowKids[i].checkable !== undefined) return rowKids[i]
            return null
        }

        // Map an orientation mode to its expected rotation.
        function rotFor(mode) {
            switch (mode) {
            case "portrait": return 0
            case "landscape": return 90
            case "inverted-portrait": return 180
            case "inverted-landscape": return 270
            }
            return -1
        }
        // Wait until the visible rotation transform has settled at the mode's target.
        function settleRotation(mode) {
            var target = rotFor(mode)
            tryVerify(function () { return Math.abs(((cr.rotation % 360) + 360) % 360 - target) < 0.75 }, 3000,
                      "contentRoot.rotation settled at " + target + "°")
            tryVerify(function () { return cr.opacity > 0.99 && cr.scale > 0.99 }, 3000,
                      "reorient fx settled")
        }

        // Show the shell window so real mouse events deliver (settings cases).
        function ensureShown() {
            if (_shown) return
            win.width = baseW; win.height = baseH
            // Use `visibility`, NOT `visible`. ui/qml/main.qml:11 declares
            // `visibility: Window.Hidden` (deliberate - C++ positions the window on
            // the target screen and only then calls showFullScreen(); critical on
            // Wayland). Assigning `visible` as well makes QQC2 emit "Conflicting
            // properties 'visible' and 'visibility'" and the window is never
            // properly mapped/exposed, so NO synthetic pointer input is delivered -
            // every mouseClick/drag test then fails while programmatic tests pass.
            win.visibility = Window.Windowed
            wait(500)
            _shown = true
        }
        // Open the appearance sheet, upright (portrait), ready for real input.
        function openSettings() {
            ensureShown()
            if (win.orientationMode !== "portrait") {
                win.orientationMode = "portrait"
                wait(120)
                settleRotation("portrait")
            }
            panel.shown = true
            tryVerify(function () { return panel.opacity > 0.99 }, 2000)
            wait(80)
        }
        // Seed N blank pages (one blank page + n-1 added). Returns nothing.
        function seedPages(n) {
            store.load("blank")
            tryVerify(function () { return swipe.count === store.pageCount() }, 3000)
            for (var i = store.pageCount(); i < n; i++) store.addPage("")
            tryVerify(function () { return swipe.count === n && store.pageCount() === n }, 4000,
                      "seeded " + n + " pages")
        }

        // ── host the REAL shell ONCE ─────────────────────────────────────────
        function initTestCase() {
            var c = Qt.createComponent("../../ui/qml/main.qml")
            tryVerify(function () { return c.status !== Component.Loading }, 8000)
            compare(c.status, Component.Ready, "main.qml compiles: " + c.errorString())
            win = c.createObject(root)
            verify(win !== null, "main.qml instantiated")
            win.width = baseW; win.height = baseH
            win.orientationMode = "landscape"

            var sv0 = G.findPred(win.contentItem, function (n) {
                return n && typeof n.push === "function" && n.currentItem !== undefined })
            verify(sv0, "found StackView")
            // main.qml already resolves an initial Dashboard. Remove it immediately
            // before pushing the deterministic source-tree page; an animated clear
            // leaves the outgoing tree alive long enough for finders to mix instances.
            sv0.clear(StackView.Immediate)
            sv0.push(Qt.resolvedUrl("../../ui/qml/Dashboard.qml"))
            tryVerify(function () { return sv0.depth === 1 && sv0.currentItem !== null }, 5000,
                      "exactly one current Dashboard page")
            dash = sv0.currentItem

            tryVerify(function () {
                swipe = G.byObjName(dash, "pageSwipe")
                store = G.findPred(dash, function (n) {
                    return n && n.applyExternal !== undefined && n.structureRevision !== undefined })
                panel = G.findPred(dash, function (n) {
                    return n && n.pickerCol !== undefined && n.presetsLocked !== undefined })
                cr    = G.findPred(win.contentItem, function (n) {
                    return n && typeof n.swapped === "boolean" })
                return swipe !== null && dash !== null && store !== null
                        && panel !== null && cr !== null
            }, 8000, "real Dashboard + SwipeView + SettingsPanel + contentRoot resolved")

            theme = win.theme
            checker = G.findPred(win.contentItem, function (n) {
                return n && n.releasesUrl !== undefined && typeof n.check === "function" })
            verify(checker !== null, "found the app-global UpdateChecker")

            // Zero-egress guarantee for the whole file: the update check can never
            // reach the network - it fails closed at the gate instead.
            if (dash.netGate) dash.netGate.offline = true

            store.load("blank")
            tryVerify(function () { return swipe.count === store.pageCount() }, 3000)
        }
        function cleanupTestCase() { if (win) win.destroy() }

        // Reset shared knobs before each case (no orientation churn: each test
        // sets the orientation it needs).
        function init() {
            if (!win) return
            win.reduceMotion = false
            if (panel) panel.shown = false
        }

        // ══════════════════════════════════════════════════════════════════════
        // AREA 3 - ORIENTATION (34)
        // ══════════════════════════════════════════════════════════════════════

        // 3a - each fixed mode sets the right rotation (4). ORI-01/03/05/07.
        function test_ori_a_fixed_rotation_data() {
            return [
                { tag: "portrait",           mode: "portrait",           rot: 0 },
                { tag: "landscape",          mode: "landscape",          rot: 90 },
                { tag: "inverted-portrait",  mode: "inverted-portrait",  rot: 180 },
                { tag: "inverted-landscape", mode: "inverted-landscape", rot: 270 },
            ]
        }
        function test_ori_a_fixed_rotation(d) {
            win.orientationMode = d.mode
            compare(win.contentRotation, d.rot, d.mode + " → " + d.rot + "°")
        }

        // 3a - each mode swaps (or not) the contentRoot aspect (4). ORI-02/04/06/08.
        function test_ori_a_fixed_swap_data() {
            return [
                { tag: "portrait",           mode: "portrait",           swapped: false },
                { tag: "landscape",          mode: "landscape",          swapped: true },
                { tag: "inverted-portrait",  mode: "inverted-portrait",  swapped: false },
                { tag: "inverted-landscape", mode: "inverted-landscape", swapped: true },
            ]
        }
        function test_ori_a_fixed_swap(d) {
            win.width = 300; win.height = 500          // distinct dims so a swap is observable
            win.orientationMode = d.mode
            compare(cr.swapped, d.swapped, d.mode + " swapped=" + d.swapped)
            if (d.swapped) {
                compare(cr.width, win.height, d.mode + ": contentRoot width takes the window HEIGHT")
                compare(cr.height, win.width, d.mode + ": contentRoot height takes the window WIDTH")
            } else {
                compare(cr.width, win.width, d.mode + ": contentRoot width tracks the window width")
                compare(cr.height, win.height, d.mode + ": contentRoot height tracks the window height")
            }
        }

        // ORI-09 - auto follows the sensor reading.
        function test_ori_a_auto_follows_sensor() {
            win.orientationMode = "auto"
            win.sensorRotation = -1; win._stableSensorRotation = -1
            win.sensorRotation = 90                    // first reading applies promptly
            compare(win._stableSensorRotation, 90, "first sensor reading applied promptly")
            compare(win.contentRotation, 90, "auto follows the sensor to 90°")
        }

        // ORI-10 - auto default (no reading) derives landscape from the window aspect.
        function test_ori_a_auto_default_aspect() {
            win.orientationMode = "auto"
            win.sensorRotation = -1; win._stableSensorRotation = -1
            win.width = 300; win.height = 500          // portrait window → rotate 90 to landscape
            compare(win.contentRotation, 90, "auto, no reading, portrait window → landscape (90°)")
            win.width = 500; win.height = 300          // landscape window → already landscape
            compare(win.contentRotation, 0, "auto, no reading, landscape window → landscape (0°)")
        }

        // 3b - grabImage aspect reflects the swap (4).
        // ORI-11 landscape grab wider-than-tall.
        function test_ori_b_landscape_grab_wider() {
            win.reduceMotion = true                    // collapse fx: only dims matter
            win.width = 720; win.height = 1280         // tall panel (hidden → free resize)
            win.orientationMode = "landscape"
            // A resize is a compositor round-trip, so `wait(120)` is a guess
            // about how long that takes on this machine. On a CI runner hosting
            // four nested compositors it is too short: the grab then captures
            // the pre-rotation geometry and the rotation assertion below fails
            // for a reason that has nothing to do with the product. Poll the
            // geometry itself - a rotation that never happens still fails, it
            // just is not decided by a stopwatch.
            // 10s, not 3s: this is a compositor round-trip, and a poll costs
            // nothing on a healthy run - it returns the moment the geometry
            // lands. The 3s bound failed on a CI runner that was starved by two
            // hung slots; a bound tight enough to fail under load is a bound
            // that measures the runner, not the product.
            tryVerify(function () { return cr.width === win.height }, 10000,
                      "contentRoot width takes window height in landscape")
            var img = snap(cr, "landscape")
            verify(img.width > img.height,
                   "landscape grab is wider than tall (" + img.width + "x" + img.height + ")")
        }
        // ORI-12 portrait grab taller-than-wide.
        function test_ori_b_portrait_grab_taller() {
            win.reduceMotion = true
            win.width = 720; win.height = 1280
            win.orientationMode = "portrait"
            wait(120)
            var img = snap(cr, "portrait")
            verify(img.height > img.width,
                   "portrait grab is taller than wide (" + img.width + "x" + img.height + ")")
            compare(cr.width, win.width, "contentRoot width tracks window width in portrait")
        }
        // ORI-13 rotation inverts the rendered aspect.
        function test_ori_b_rotation_inverts_aspect() {
            win.reduceMotion = true
            win.width = 720; win.height = 1280
            win.orientationMode = "portrait";  wait(120)
            var p = G.grabItem(this, cr, win.contentItem); var pRatio = p.height / p.width
            win.orientationMode = "landscape"; wait(120)
            var l = G.grabItem(this, cr, win.contentItem); var lRatio = l.height / l.width
            verify(pRatio > 1.0, "portrait aspect is tall (" + pRatio.toFixed(2) + ")")
            verify(lRatio < 1.0, "landscape aspect is wide (" + lRatio.toFixed(2) + ")")
            verify(pRatio > lRatio, "the aspect inverted between the two orientations")
        }
        // ORI-14 dashboard page re-projects (page delegate `landscape` bool flips).
        function test_ori_b_grid_reprojects() {
            win.reduceMotion = true
            // A hidden QQuickWindow does not run layout polish for the nested
            // ColumnLayout when only the rotated container's geometry changes.
            // Map this rendered-layout case under the real nested compositor;
            // the pure transform/aspect cases above deliberately stay hidden.
            win.visibility = Window.Windowed
            wait(400)
            win.width = 720; win.height = 1280
            seedPages(1)
            win.orientationMode = "portrait"; wait(120)
            var pageP = swipe.currentItem
            verify(pageP && pageP.landscape !== undefined, "current page delegate exposes `landscape`")
            compare(pageP.landscape, false, "portrait: page is not in landscape projection")
            win.orientationMode = "landscape"; wait(120)
            var pageL = swipe.currentItem
            tryVerify(function () { return pageL && pageL.landscape === true }, 3000,
                      "landscape page delegate completed its asynchronous re-layout")
            compare(pageL.landscape, true, "landscape: page re-projects to landscape (more columns)")
            win.visibility = Window.Hidden
            wait(120)
        }

        // 3c - current page PRESERVED across a rotation (8). The rotation analogue
        // of the add-page snap-back: reach a page, rotate, wait past the settle,
        // assert it STAYED.
        // ORI-15..18.
        function test_ori_c_page_survives_rotation_data() {
            return [
                { tag: "portrait→landscape",          start: "portrait",  end: "landscape",          page: 2 },
                { tag: "landscape→portrait",          start: "landscape", end: "portrait",           page: 2 },
                { tag: "portrait→inverted-portrait",  start: "portrait",  end: "inverted-portrait",  page: 1 },
                { tag: "landscape→inverted-landscape",start: "landscape", end: "inverted-landscape", page: 1 },
            ]
        }
        function test_ori_c_page_survives_rotation(d) {
            win.reduceMotion = false
            seedPages(d.page + 1)
            win.orientationMode = d.start
            settleRotation(d.start)
            swipe.goToPage(d.page)
            tryVerify(function () { return swipe.currentIndex === d.page }, 4000, "reached page " + d.page)
            win.orientationMode = d.end
            wait(900)                                  // outlast the 560ms rotate + deferred relayout
            compare(swipe.currentIndex, d.page, d.tag + ": STAYED on page " + d.page + " across the rotation")
        }

        // ORI-19 round-trip P→L→P preserves the page each turn.
        function test_ori_c_roundtrip_preserves_page() {
            win.reduceMotion = false
            seedPages(3)
            win.orientationMode = "portrait"; settleRotation("portrait")
            swipe.goToPage(2)
            tryVerify(function () { return swipe.currentIndex === 2 }, 4000)
            win.orientationMode = "landscape"; wait(900)
            compare(swipe.currentIndex, 2, "still on page 2 after P→L")
            win.orientationMode = "portrait";  wait(900)
            compare(swipe.currentIndex, 2, "still on page 2 after L→P (round-trip)")
        }

        // ORI-20 rotation on a JUST-ADDED page keeps it (not snapped to 0).
        function test_ori_c_rotation_on_added_page() {
            win.reduceMotion = false
            seedPages(2)
            win.orientationMode = "portrait"; settleRotation("portrait")
            var target = store.pageCount()             // index of the page we are about to add
            store.addPage("")
            swipe.goToPage(target)
            tryVerify(function () { return swipe.currentIndex === target }, 4000, "landed on the new page")
            win.orientationMode = "landscape"
            wait(900)
            compare(swipe.currentIndex, target, "the just-added page survived the rotation (no snap to 0)")
        }

        // ORI-21 auto sensor rotation preserves the page.
        function test_ori_c_auto_sensor_preserves_page() {
            win.reduceMotion = false
            seedPages(3)
            win.orientationMode = "portrait"; settleRotation("portrait")
            swipe.goToPage(2)
            tryVerify(function () { return swipe.currentIndex === 2 }, 4000)
            win.orientationMode = "auto"
            win.sensorRotation = -1; win._stableSensorRotation = -1
            win.sensorRotation = 180                   // sensor drives the rotation
            compare(win.contentRotation, 180, "auto took the sensor rotation")
            wait(900)
            compare(swipe.currentIndex, 2, "page preserved across an auto/sensor rotation")
        }

        // ORI-22 tiles are re-projected, not re-packed: the store layout is identical
        // across a rotation (same ids, same order) - only the projected geometry differs.
        function test_ori_c_tiles_not_repacked() {
            win.reduceMotion = true
            store.load("blank")
            tryVerify(function () { return swipe.count === store.pageCount() }, 3000)
            store.addTile(0, "clock")
            store.addTile(0, "cpu")
            var before = JSON.stringify(store.pages()[0].tiles.map(function (t) { return t.id + ":" + t.type }))
            win.orientationMode = "portrait";  wait(120)
            win.orientationMode = "landscape"; wait(120)
            var after = JSON.stringify(store.pages()[0].tiles.map(function (t) { return t.id + ":" + t.type }))
            compare(after, before, "the same tiles in the same order survive the rotation (re-projected, not re-packed)")
            verify(cr.swapped, "…and the contentRoot did actually swap to the landscape aspect")
        }

        // 3d - reorient fx (6).
        // ORI-23 fx dips opacity mid-rotation.
        function test_ori_d_fx_dips_opacity() {
            win.reduceMotion = false
            win.orientationMode = "portrait"
            tryVerify(function () { return cr.scale > 0.99 && cr.opacity > 0.99 }, 3000, "resting at full")
            win.orientationMode = "landscape"
            tryVerify(function () { return cr.opacity < 0.5 }, 2000, "reorient fx dipped contentRoot opacity")
        }
        // ORI-24 fx restores opacity.
        function test_ori_d_fx_restores_opacity() {
            win.reduceMotion = false
            win.orientationMode = "portrait"
            tryVerify(function () { return cr.opacity > 0.99 }, 3000, "resting opacity")
            win.orientationMode = "landscape"
            tryVerify(function () { return cr.opacity < 0.5 }, 2000)
            tryVerify(function () { return cr.opacity > 0.99 }, 3000, "reorient fx eased opacity back to full")
        }
        // ORI-25 fx restores scale.
        function test_ori_d_fx_restores_scale() {
            win.reduceMotion = false
            win.orientationMode = "portrait"
            tryVerify(function () { return cr.scale > 0.99 }, 3000, "resting scale")
            win.orientationMode = "landscape"
            tryVerify(function () { return cr.scale < 0.99 }, 2000, "reorient fx dipped the scale")
            tryVerify(function () { return cr.scale > 0.99 }, 3000, "reorient fx eased scale back to full")
        }
        // ORI-26 reduce-motion skips the reorient fx (no dip at all).
        function test_ori_d_reduce_motion_skips_fx() {
            win.orientationMode = "portrait"
            wait(60)
            win.reduceMotion = true
            tryVerify(function () { return cr.scale > 0.99 && cr.opacity > 0.99 }, 2000, "settled at full")
            win.orientationMode = "landscape"
            var dipped = false
            for (var i = 0; i < 8; i++) { if (cr.opacity < 0.9 || cr.scale < 0.97) dipped = true; wait(40) }
            verify(!dipped, "under reduce-motion the reorient fx never dips opacity/scale")
        }
        // ORI-27 reduce-motion collapses the rotation to a cut (lands within a frame).
        function test_ori_d_reduce_motion_collapses_rotation() {
            win.orientationMode = "portrait"
            settleRotation("portrait")
            win.reduceMotion = true
            win.orientationMode = "landscape"
            wait(50)                                   // one-frame budget; a 560ms tween would be far off
            fuzzyCompare(((cr.rotation % 360) + 360) % 360, 90, 0.75,
                         "reduce-motion collapsed the 560ms rotation to an immediate cut")
        }
        // ORI-28 no on-screen keyboard flashes during a reorient (input method hidden).
        function test_ori_d_inputmethod_hidden_on_reorient() {
            win.reduceMotion = false
            win.orientationMode = "portrait"; wait(60)
            win.orientationMode = "landscape"
            for (var i = 0; i < 6; i++) { verify(!Qt.inputMethod.visible, "no VK visible during the reorient"); wait(60) }
        }

        // 3e - orientation persisted + restored (6).
        // ORI-29 setting the mode persists to the store.
        function test_ori_e_write_persists() {
            win.orientationMode = "landscape"
            compare(store.appearance().orientation, "landscape", "orientation write reached the store")
        }
        // ORI-30 a persisted orientation is applied on load.
        function test_ori_e_persisted_applied_on_load() {
            win.orientationMode = "landscape"
            var doc = '{"pages":[{"name":"P1","tiles":[]}],"appearance":{"orientation":"portrait"},"settings":{}}'
            dash.applyExternalState(doc)
            compare(win.orientationMode, "portrait", "loaded orientation applied")
            compare(win.contentRotation, 0, "…and the shell rotated to match (0°)")
        }
        // ORI-31 every mode round-trips through the store (5 checks, one case).
        function test_ori_e_modes_roundtrip_through_store() {
            var modes = ["auto", "portrait", "landscape", "inverted-portrait", "inverted-landscape"]
            for (var i = 0; i < modes.length; i++) {
                win.orientationMode = modes[i]
                wait(20)
                compare(store.appearance().orientation, modes[i], "store round-trips " + modes[i])
            }
        }
        // ORI-32 an invalid orientation in a loaded doc degrades gracefully (no crash;
        // the shell still resolves a legal rotation).
        function test_ori_e_invalid_orientation_graceful() {
            var doc = '{"pages":[{"name":"P1","tiles":[]}],"appearance":{"orientation":"sideways"},"settings":{}}'
            dash.applyExternalState(doc)
            verify(win !== null && win.contentItem !== null, "shell survived the invalid orientation (no crash)")
            verify(rotSet.indexOf(win.contentRotation) >= 0,
                   "contentRotation is still a legal value (" + win.contentRotation + ")")
        }
        // ORI-33 the settings orientation chip reflects the active mode.
        function test_ori_e_settings_chip_reflects_mode() {
            openSettings()
            win.orientationMode = "landscape"
            wait(80)
            var chip = delegateWhere(function (n) { return n.modelData.v === "landscape" })
            verify(chip !== null, "landscape orientation chip exists")
            verify(chip.active, "the chip matching the active orientation is highlighted")
        }
        // ORI-34 applying appearance does not leave the echo-guard stuck.
        function test_ori_e_apply_does_not_echo_save() {
            var doc = '{"pages":[{"name":"P1","tiles":[]}],"appearance":{"orientation":"inverted-portrait"},"settings":{}}'
            dash.applyExternalState(doc)
            compare(win.orientationMode, "inverted-portrait", "orientation applied from the doc")
            compare(dash._applyingAppearance, false, "the _applyingAppearance echo-guard was cleared (no stuck state)")
            compare(store.appearance().orientation, "inverted-portrait", "store value is consistent with the doc")
        }

        // ══════════════════════════════════════════════════════════════════════
        // AREA 4 - SETTINGS PANEL (44)
        // ══════════════════════════════════════════════════════════════════════

        // 4a - Screens entry (3).
        // SET-01 visible + touch sized.
        function test_set_a_screens_entry_visible() {
            openSettings()
            var entry = G.byObjName(panel, "screensEntry")
            verify(entry !== null && entry.visible, "the Screens entry is present and visible")
            verify(entry.height >= theme.touchSecondary, "…and touch sized (" + entry.height + ")")
        }
        // SET-02 tapping it opens the preset library (Dashboard wires it that way).
        function test_set_a_screens_entry_opens_picker() {
            var pp = G.findPred(win.contentItem, function (n) {
                return n && n.catalog !== undefined && n.locked !== undefined && n.shown !== undefined
                        && n.pickerCol === undefined })
            openSettings()
            var entry = G.byObjName(panel, "screensEntry")
            verify(entry !== null, "screens entry present")
            bringIntoView(entry)
            mouseClick(entry, entry.width / 2, entry.height / 2)
            verify(pp !== null, "found the PresetPicker")
            tryVerify(function () { return pp.shown === true }, 2000, "tapping Screens opened the preset picker")
            pp.shown = false
        }
        // SET-03 absent under an org-forced preset lock.
        function test_set_a_screens_entry_locked() {
            openSettings()
            store.policyLockedPreset = "gaming"
            var entry = G.byObjName(panel, "screensEntry")
            verify(entry !== null && !entry.visible, "a policy lock removes the entry outright (absent, not greyed)")
            store.policyLockedPreset = ""
            verify(entry.visible, "clearing the lock restores the entry")
        }

        // 4b - Theme selection (8).
        // SET-04 the theme groups render.
        function test_set_b_theme_groups_render() {
            openSettings()
            verify(G.byText(panel, "Standard") !== null, "Standard group header present")
            verify(G.byText(panel, "Premium") !== null, "Premium group header present")
            verify(G.byText(panel, "Accessibility") !== null, "Accessibility group header present")
        }
        // SET-05 active theme chip reflects themeMode.
        function test_set_b_active_theme_chip() {
            openSettings()
            win.themeMode = "midnight"
            wait(60)
            var d = delegateWhere(function (n) { return n.modelData.k === "midnight" })
            verify(d !== null, "midnight theme chip exists")
            verify(d.active, "the chip matching root.themeMode is active")
        }
        // SET-06 tapping a free theme writes themeMode.
        function test_set_b_free_theme_writes() {
            openSettings()
            win.themeMode = "dark"; theme.applyTheme("dark"); wait(60)
            var d = delegateWhere(function (n) { return n.modelData.k === "midnight" })
            bringIntoView(d); mouseClick(d, d.width / 2, d.height / 2)
            compare(win.themeMode, "midnight", "tapping a free theme chip wrote root.themeMode")
        }
        // SET-07 tapping a free theme applies it (colours change).
        function test_set_b_free_theme_applies() {
            openSettings()
            win.themeMode = "dark"; theme.applyTheme("dark"); wait(60)
            var d = delegateWhere(function (n) { return n.modelData.k === "midnight" })
            bringIntoView(d); mouseClick(d, d.width / 2, d.height / 2)
            verify(Qt.colorEqual(theme.backgroundColor, "#0B1026"),
                   "…and applied the theme (background is the midnight tone)")
        }
        // SET-08 a Pro theme is locked without a licence.
        function test_set_b_pro_theme_locked() {
            openSettings()
            var d = delegateWhere(function (n) { return n.modelData.k === "synthwave" })
            verify(d !== null, "a Pro theme (synthwave) is listed")
            verify(d.locked, "…and it is locked without a licence")
        }
        // SET-09 tapping a locked Pro theme does NOT apply it.
        function test_set_b_pro_theme_no_apply() {
            openSettings()
            win.themeMode = "dark"; theme.applyTheme("dark"); wait(60)
            var d = delegateWhere(function (n) { return n.modelData.k === "synthwave" })
            bringIntoView(d); mouseClick(d, d.width / 2, d.height / 2)
            compare(win.themeMode, "dark", "tapping a locked Pro theme left the theme unchanged")
        }
        // SET-10 the lock hint explains where to unlock.
        function test_set_b_lock_hint_mentions_pro() {
            openSettings()
            win.themeMode = "dark"; theme.applyTheme("dark"); wait(60)
            var d = delegateWhere(function (n) { return n.modelData.k === "synthwave" })
            bringIntoView(d); mouseClick(d, d.width / 2, d.height / 2)
            var hint = G.byText(panel, "Pro theme")
            verify(hint !== null && hint.visible, "a lock hint mentioning the Pro theme appeared")
        }
        // SET-11 switching a valid theme changes the dashboard background pixel.
        function test_set_b_theme_changes_dashboard() {
            ensureShown()
            win.orientationMode = "portrait"; settleRotation("portrait")
            store.load("blank"); tryVerify(function () { return swipe.count === store.pageCount() }, 3000)
            panel.shown = false
            win.themeMode = "dark"; theme.applyTheme("dark"); wait(200)
            var before = "" + snap(win.contentItem, "theme_before").pixel(20, 20)
            openSettings()
            var d = delegateWhere(function (n) { return n.modelData.k === "light" })
            bringIntoView(d); mouseClick(d, d.width / 2, d.height / 2)
            panel.shown = false; wait(250)
            var after = "" + snap(win.contentItem, "theme_after").pixel(20, 20)
            verify(G.colorDist(before, after) > 40,
                   "the dashboard background pixel changed with the theme (" + before + " → " + after + ")")
        }

        // 4c - Accent colour (8).
        // SET-12..15 house accents.
        function test_set_c_house_accent_data() {
            return [ { tag: "blue", name: "blue" }, { tag: "green", name: "green" },
                     { tag: "pink", name: "pink" }, { tag: "gold", name: "gold" } ]
        }
        function test_set_c_house_accent(d) {
            openSettings()
            var sw = accentSwatchFor(d.name)
            verify(sw !== null, "found the " + d.name + " accent swatch")
            bringIntoView(sw); mouseClick(sw, sw.width / 2, sw.height / 2)
            compare(theme.accentName, d.name, "tapping the swatch applied accent " + d.name)
            verify(Qt.colorEqual(theme.accent, theme.accentPresets[d.name].a), "accent recoloured to " + d.name)
        }
        // SET-16..18 Okabe–Ito accents.
        function test_set_c_oi_accent_data() {
            return [ { tag: "oi_blue", name: "oi_blue" }, { tag: "oi_orange", name: "oi_orange" },
                     { tag: "oi_black", name: "oi_black" } ]
        }
        function test_set_c_oi_accent(d) {
            openSettings()
            var sw = accentSwatchFor(d.name)
            verify(sw !== null, "found the " + d.name + " accent swatch")
            bringIntoView(sw); mouseClick(sw, sw.width / 2, sw.height / 2)
            compare(theme.accentName, d.name, "tapping the swatch applied accent " + d.name)
            verify(Qt.colorEqual(theme.accent, theme.accentPresets[d.name].a), "accent recoloured to " + d.name)
        }
        // SET-19 the active swatch shows the check + scales up.
        function test_set_c_active_swatch() {
            openSettings()
            var sw = accentSwatchFor("green")
            bringIntoView(sw); mouseClick(sw, sw.width / 2, sw.height / 2)
            verify(sw.active, "the picked swatch is active")
            tryVerify(function () { return sw.scale > 1.05 }, 2000, "…and scales up (≈1.08)")
            var chk = G.findPred(sw, function (n) { return n && n.name === "ui-check" })
            verify(chk !== null && chk.visible, "the check icon is shown on the active swatch")
        }

        // 4d - Orientation picker chips (5). SET-20..24.
        function test_set_d_orientation_chip_data() {
            return [ { tag: "auto", v: "auto" }, { tag: "portrait", v: "portrait" },
                     { tag: "landscape", v: "landscape" }, { tag: "inverted-portrait", v: "inverted-portrait" },
                     { tag: "inverted-landscape", v: "inverted-landscape" } ]
        }
        function test_set_d_orientation_chip(d) {
            openSettings()
            var chip = delegateWhere(function (n) { return n.modelData.v === d.v })
            verify(chip !== null, "orientation chip " + d.v + " exists")
            bringIntoView(chip); mouseClick(chip, chip.width / 2, chip.height / 2)
            compare(win.orientationMode, d.v, "tapping the chip wrote orientationMode=" + d.v)
        }

        // 4e - GLASS SLIDER, real drag + the snap-back regression (5).
        // SET-25 the slider reflects an external glassOpacity.
        function test_set_e_slider_reflects_external() {
            openSettings()
            win.glassOpacity = 0.25
            var s = findSlider()
            verify(s !== null, "glass slider present")
            tryVerify(function () { return Math.abs(s.value - 0.25) < 0.02 }, 2000, "slider reflects 0.25")
            verify(findExactText(panel, "25%") !== null, "the % label reflects the value")
        }
        // SET-26 dragging the handle right RAISES the value (real mouse drag).
        function test_set_e_slider_drag_raises() {
            openSettings()
            var s = findSlider(); bringIntoView(s)
            win.glassOpacity = 0.3
            tryVerify(function () { return Math.abs(s.value - 0.3) < 0.02 }, 2000)
            snap(s, "slider_before")
            var y = s.height / 2
            mousePress(s, s.width * 0.3, y)
            mouseMove(s, s.width * 0.6, y)
            mouseMove(s, s.width * 0.85, y)
            mouseRelease(s, s.width * 0.85, y)
            snap(s, "slider_after")
            verify(s.value > 0.45, "the drag raised the handle value to " + s.value.toFixed(2))
        }
        // SET-27 the dragged value COMMITS to the bound source.
        function test_set_e_slider_drag_commits() {
            openSettings()
            var s = findSlider(); bringIntoView(s)
            win.glassOpacity = 0.3
            tryVerify(function () { return Math.abs(s.value - 0.3) < 0.02 }, 2000)
            var y = s.height / 2
            mousePress(s, s.width * 0.3, y); mouseMove(s, s.width * 0.85, y); mouseRelease(s, s.width * 0.85, y)
            verify(s.value > 0.45, "handle moved")
            fuzzyCompare(win.glassOpacity, s.value, 0.001, "onMoved committed the dragged value to root.glassOpacity")
        }
        // SET-28 the handle does NOT snap back - after a wait AND after a churny
        // store revision (the glass-slider regression, S2).
        function test_set_e_slider_no_snapback() {
            openSettings()
            var s = findSlider(); bringIntoView(s)
            win.glassOpacity = 0.2
            tryVerify(function () { return Math.abs(s.value - 0.2) < 0.02 }, 2000)
            var y = s.height / 2
            mousePress(s, s.width * 0.3, y); mouseMove(s, s.width * 0.85, y); mouseRelease(s, s.width * 0.85, y)
            var dragged = s.value
            verify(dragged > 0.45, "handle moved to " + dragged.toFixed(2))
            wait(400)
            verify(s.value > 0.45, "no snap-back after settle (" + s.value.toFixed(2) + ")")
            // Bump a churny store revision several times - the handle must not snap.
            for (var i = 0; i < 6; i++) store.setAppearance("glow", win.showWidgetGlow)
            wait(400)
            verify(s.value > 0.45, "no snap-back after a churny store revision (" + s.value.toFixed(2) + ")")
            fuzzyCompare(win.glassOpacity, s.value, 0.01, "value and source still agree after the churn")
        }
        // SET-29 an external push still moves the handle after the drag (rebind).
        function test_set_e_slider_rebinds() {
            openSettings()
            var s = findSlider(); bringIntoView(s)
            win.glassOpacity = 0.3
            tryVerify(function () { return Math.abs(s.value - 0.3) < 0.02 }, 2000)
            var y = s.height / 2
            mousePress(s, s.width * 0.3, y); mouseMove(s, s.width * 0.85, y); mouseRelease(s, s.width * 0.85, y)
            verify(s.value > 0.45, "handle moved by the drag")
            win.glassOpacity = 0.15                     // external push
            tryVerify(function () { return Math.abs(s.value - 0.15) < 0.02 }, 2000,
                      "the binding survived the drag - an external push still moves the handle")
        }

        // 4f - Toggles: glow / animated bg / reduce motion (6).
        // SET-30 glow switch reflects state.
        function test_set_f_glow_reflects() {
            openSettings()
            win.showWidgetGlow = true; wait(60)
            var sw = switchForLabel("Accent glow")
            verify(sw !== null, "found the accent-glow switch")
            compare(sw.checked, true, "reflects showWidgetGlow=true")
        }
        // SET-31 toggling glow writes the source.
        function test_set_f_glow_toggle() {
            openSettings()
            win.showWidgetGlow = true; wait(60)
            var sw = switchForLabel("Accent glow"); bringIntoView(sw)
            mouseClick(sw, sw.width / 2, sw.height / 2)
            compare(win.showWidgetGlow, false, "toggling wrote showWidgetGlow=false")
            compare(sw.checked, false, "the switch re-reflects the source after the rebind")
        }
        // SET-32 animated-bg switch reflects state.
        function test_set_f_animbg_reflects() {
            openSettings()
            win.animatedBackground = true; wait(60)
            var sw = switchForLabel("Animated background")
            verify(sw !== null, "found the animated-background switch")
            compare(sw.checked, true, "reflects animatedBackground=true")
        }
        // SET-33 toggling animated-bg writes the source.
        function test_set_f_animbg_toggle() {
            openSettings()
            win.animatedBackground = true; wait(60)
            var sw = switchForLabel("Animated background"); bringIntoView(sw)
            mouseClick(sw, sw.width / 2, sw.height / 2)
            compare(win.animatedBackground, false, "toggling wrote animatedBackground=false")
        }
        // SET-34 reduce-motion switch reflects state.
        function test_set_f_reduce_motion_reflects() {
            openSettings()                              // init() already set reduceMotion=false
            var sw = switchForLabel("Reduce motion")
            verify(sw !== null, "found the reduce-motion switch")
            compare(sw.checked, false, "reflects reduceMotion=false")
        }
        // SET-35 toggling reduce-motion writes + rebinds.
        function test_set_f_reduce_motion_toggle() {
            openSettings()
            var sw = switchForLabel("Reduce motion"); bringIntoView(sw)
            mouseClick(sw, sw.width / 2, sw.height / 2)
            compare(win.reduceMotion, true, "toggling wrote reduceMotion=true")
            compare(sw.checked, true, "the switch re-reflects the source after the rebind")
        }

        // 4g - Software updates toggle + Check now (6).
        // SET-36 update switch off by default.
        function test_set_g_update_off_default() {
            store.load("blank"); wait(60)
            openSettings()
            var sw = switchForLabel("Check for updates")
            verify(sw !== null, "found the update-check switch")
            compare(sw.checked, false, "off by default (zero-egress default)")
        }
        // SET-37 toggling writes updateCheck to the store.
        function test_set_g_update_toggle_writes() {
            store.load("blank"); wait(60)
            openSettings()
            var sw = switchForLabel("Check for updates"); bringIntoView(sw)
            mouseClick(sw, sw.width / 2, sw.height / 2)
            compare(store.appearance().updateCheck, true, "toggling wrote updateCheck=true")
        }
        // SET-38 toggling back off.
        function test_set_g_update_toggle_back() {
            store.load("blank"); wait(60)
            openSettings()
            var sw = switchForLabel("Check for updates"); bringIntoView(sw)
            mouseClick(sw, sw.width / 2, sw.height / 2)
            compare(store.appearance().updateCheck, true, "on")
            mouseClick(sw, sw.width / 2, sw.height / 2)
            compare(store.appearance().updateCheck === true, false, "…and back off")
        }
        // SET-39 result line + Check now hidden when off.
        function test_set_g_result_hidden_when_off() {
            store.load("blank"); wait(60)
            openSettings()
            var checkNow = findExactText(panel, "Check now")
            verify(checkNow === null || !effVisible(checkNow),
                   "the result line / Check now is hidden while updates are off")
        }
        // SET-40 result line + Check now shown when enabled.
        function test_set_g_result_shown_when_on() {
            store.load("blank"); wait(60)
            openSettings()
            var sw = switchForLabel("Check for updates"); bringIntoView(sw)
            mouseClick(sw, sw.width / 2, sw.height / 2)
            wait(120)
            var checkNow = findExactText(panel, "Check now")
            verify(checkNow !== null, "Check now text is present")
            tryVerify(function () { return effVisible(checkNow) }, 2000, "the result line / Check now shows when enabled")
        }
        // SET-41 Check now triggers the checker (status leaves idle) - no egress (offline gate).
        function test_set_g_check_now() {
            store.load("blank"); wait(60)
            openSettings()
            var sw = switchForLabel("Check for updates"); bringIntoView(sw)
            mouseClick(sw, sw.width / 2, sw.height / 2)
            wait(120)
            checker.status = "idle"                     // reset so the click's effect is unambiguous
            var checkNow = findExactText(panel, "Check now")
            verify(checkNow !== null, "found the Check now control")
            bringIntoView(checkNow)
            mouseClick(checkNow, checkNow.width / 2, checkNow.height / 2)
            tryVerify(function () { return checker.status !== "idle" }, 2000,
                      "Check now invoked the checker (status left idle → '" + checker.status + "')")
        }

        // 4h - Panel chrome (3).
        // SET-42 scrim tap closes the panel.
        function test_set_h_scrim_closes() {
            openSettings()
            verify(panel.shown, "panel open")
            mouseClick(panel, 8, 8)                     // outside the centred sheet → scrim
            tryVerify(function () { return panel.shown === false }, 2000, "scrim tap closed the panel")
        }
        // SET-43 close button closes the panel.
        function test_set_h_close_button() {
            openSettings()
            var closeIcon = G.findPred(panel, function (n) { return n && n.name === "ui-close" })
            verify(closeIcon !== null && closeIcon.parent !== null, "found the close button")
            var btn = closeIcon.parent
            mouseClick(btn, btn.width / 2, btn.height / 2)
            tryVerify(function () { return panel.shown === false }, 2000, "close button closed the panel")
        }
        // SET-44 the Layout-Columns picker is GONE.
        function test_set_h_no_columns_picker() {
            openSettings()
            var d = delegateWhere(function (n) {
                return n.modelData && typeof n.modelData.l === "string" && n.modelData.l.indexOf("Column") >= 0 })
            compare(d, null, "no column-count delegate survives in the settings panel")
        }
    }
}
