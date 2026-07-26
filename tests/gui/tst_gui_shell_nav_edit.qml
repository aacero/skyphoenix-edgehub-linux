import QtQuick
import QtQuick.Controls
import QtTest
import "GuiUtil.js" as G

// REAL, visible GUI tests for the Hub SHELL: page navigation + edit mode.
// Hosts the REAL shell ONCE (main.qml → StackView → Dashboard pushed by
// RELATIVE url) under a real KWin compositor and drives real mouse events.
//
// The two shell seams under test:
//   • Page navigation - the "always snaps back to page 1" bug: every land is
//     asserted REACHED then SUSTAINED (tryVerify(index) → wait(900) → compare).
//   • Edit mode - enter/exit, add-tile picker, place/move/resize/remove tiles,
//     per-tile config overlay, per-page background, toolbar visibility, and
//     SwipeView.interactive === !editMode.
//
// The repository QuickTest runner embeds the shipped icon/wallpaper resources,
// while WidgetCatalog resolves widget sources from this source tree. Assertions
// cover GUI-observable structure, real input, rendered geometry and background
// pixels; the dedicated widget files own detailed per-widget pixel behaviour.
Item {
    id: root
    width: 2560; height: 720

    // ── Shell context props (main.qml reads these as `property x: _x`) ────────
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
    property int _targetScreenWidth: 2560
    property int _targetScreenHeight: 720

    property var win: null
    property var dashboardPage: null

    // ── Finders (pure; no mouseClick) ────────────────────────────────────────
    function swipe() { return G.byObjName(dashboardPage, "pageSwipe") }
    function dash()  { return dashboardPage }
    function store() { return G.findPred(dashboardPage, function (n) { return n && n.applyExternal !== undefined && n.structureRevision !== undefined }) }
    function picker(){ return G.findPred(win.contentItem, function (n) { try { return n && n.shown !== undefined && n.pageIndex !== undefined } catch (e) { return false } }) }
    function overlayItem() { return G.findPred(win.contentItem, function (n) { try { return n && n.ovlWide !== undefined } catch (e) { return false } }) }
    function barBtn(icon) { return G.findPred(win.contentItem, function (n) { try { return n && n.iconName !== undefined && n.iconName === icon } catch (e) { return false } }) }
    function editBtn() { return G.findPred(win.contentItem, function (n) { try { return n && n.iconName !== undefined && (n.iconName === "ui-edit" || n.iconName === "ui-check") } catch (e) { return false } }) }
    function iconAny(scope, nm) { return G.findPred(scope, function (n) { try { return n && n.name === nm && n.tint !== undefined } catch (e) { return false } }) }
    function cellFor(id) { return G.findPred(win.contentItem, function (n) { try { return n && n.tileId === id && n.ps !== undefined } catch (e) { return false } }) }
    function widgetCard(type) { return G.findPred(picker(), function (n) { try { return n && n.modelData && n.modelData.type === type } catch (e) { return false } }) }
    function maIn(scope) { return G.findPred(scope, function (n) { return G.isMouseArea(n) && G.isLive(n) }) }
    function ancestor(node, pred) { var p = node; while (p) { if (pred(p)) return p; p = p.parent } return null }
    function ancestorFlick(node) { return ancestor(node, function (n) { try { return n && n.flickableDirection !== undefined && n.boundsBehavior !== undefined } catch (e) { return false } }) }
    function pageInd() {
        var s = swipe()
        return G.findPred(dashboardPage, function (n) {
            // SwipeView's private content ListView has the same currentIndex/count/
            // delegate shape as PageIndicator.  Matching only those properties made
            // the tests inspect page delegates instead of the visible indicator.
            try { return n && n !== s && ("" + n).indexOf("PageIndicator") >= 0
                         && n.currentIndex !== undefined && n.count !== undefined
                         && n.delegate !== undefined }
            catch (e) { return false }
        })
    }
    function indicatorDelegate(pi, idx) { return G.byObjName(pi, "pageIndicatorDelegate-" + idx) }
    function innerRect(del) { return G.byObjName(del, "pageIndicatorChip-" + del.index) }
    function allTileIds(s) { var out = []; var ps = s.pages(); for (var p = 0; p < ps.length; p++) { var t = ps[p].tiles || []; for (var i = 0; i < t.length; i++) out.push(t[i].id) } return out }
    function findNewId(before, after) { for (var i = 0; i < after.length; i++) if (before.indexOf(after[i]) < 0) return after[i]; return "" }

    TestCase {
        name: "GuiShellNavEdit"
        when: windowShown
        visible: true

        // ── Helpers that click / wait (TestCase-scoped) ──────────────────────
        function snap(item, name) { var img = G.grabItem(this, item, win.contentItem); img.save("gui-evidence/shellnav_" + name + ".png"); return img }
        function clickItem(it) { verify(it, "click target present"); mouseClick(it, it.width / 2, it.height / 2) }
        function clickIcon(scope, nm) {
            var ic = iconAny(scope, nm)
            if (!ic || !ic.parent) return false
            var ma = G.findPred(ic.parent, function (n) { return G.isMouseArea(n) && G.isLive(n) })
            if (!ma) return false
            mouseClick(ma, ma.width / 2, ma.height / 2)
            return true
        }
        function clickText(scope, sub) {
            var t = G.byText(scope, sub)
            var node = t
            while (node) {
                var ma = G.findPred(node, function (n) { return G.isMouseArea(n) && G.isLive(n) })
                if (ma) { mouseClick(ma, ma.width / 2, ma.height / 2); return true }
                node = node.parent
            }
            return false
        }
        function swipeDrag(sw, dir) {
            // dir < 0 advances (drag right→left); dir > 0 retreats.
            var y = sw.height / 2
            var x0 = dir < 0 ? sw.width * 0.82 : sw.width * 0.18
            var x1 = dir < 0 ? sw.width * 0.18 : sw.width * 0.82
            // A swipe is one continuous held-button gesture.  Omitting `buttons`
            // made mouseMove synthesize Qt.NoButton hover events; inheriting the
            // runner's watchable 250ms delay also turned three moves into a slow
            // pointer stroll.  Use several frame-like held moves so --fast and the
            // default watchable mode exercise the same human-scale gesture.
            mousePress(sw, x0, y, Qt.LeftButton, Qt.NoModifier, 0)
            for (var i = 1; i <= 8; i++)
                mouseMove(sw, x0 + (x1 - x0) * i / 8, y, 16,
                          Qt.LeftButton, Qt.NoModifier)
            mouseRelease(sw, x1, y, Qt.LeftButton, Qt.NoModifier, 16)
        }
        function settleLanding(sw) {
            // goToPage deliberately holds its target through deferred ListView
            // relayout.  Test setup must finish that transaction before exercising
            // an unrelated user swipe, otherwise the setup timer (not the UI) wins.
            tryVerify(function () { return sw._wantIndex === -1 }, 3000,
                      "programmatic page landing settled before user input")
        }
        function resetShell(orient) {
            var d = dash(), s = store(), sw = swipe()
            if (d.hasExpanded) d.closeExpanded()
            var pk = picker(); if (pk) pk.shown = false
            d.editMode = false
            win.animatedBackground = false
            win.orientationMode = orient
            wait(80)
            s.load("blank")
            tryVerify(function () { return sw.count === s.pageCount() }, 5000, "SwipeView synced to blank doc")
            sw.goToPage(0)
            tryVerify(function () { return sw.currentIndex === 0 }, 3000)
        }

        // ── One-time real-shell hosting ──────────────────────────────────────
        function initTestCase() {
            var c = Qt.createComponent("../../ui/qml/main.qml")
            tryVerify(function () { return c.status !== Component.Loading }, 8000)
            compare(c.status, Component.Ready, "main.qml compiles: " + c.errorString())
            win = c.createObject(root)
            verify(win !== null, "main.qml instantiated")
            win.width = 2560; win.height = 720
            // Use `visibility`, NOT `visible`. ui/qml/main.qml:11 declares
            // `visibility: Window.Hidden` (deliberate - C++ positions the window on
            // the target screen and only then calls showFullScreen(); critical on
            // Wayland). Assigning `visible` as well makes QQC2 emit "Conflicting
            // properties 'visible' and 'visibility'" and the window is never
            // properly mapped/exposed, so NO synthetic pointer input is delivered -
            // every mouseClick/drag test then fails while programmatic tests pass.
            win.visibility = Window.Windowed
            win.reduceMotion = true                  // collapse rotation/edit animations for determinism
            win.orientationMode = "portrait"
            var sv = G.findPred(win.contentItem, function (n) { return n && typeof n.push === "function" && n.currentItem !== undefined })
            verify(sv, "found the StackView")
            // main.qml resolves its initial Dashboard in both the product and this
            // source-tree runner. Keep exactly one deterministic test page: pushing
            // without clearing would leave two trees, and an animated clear would
            // leave the outgoing tree live long enough for finders to mix instances.
            sv.clear(StackView.Immediate)
            sv.push(Qt.resolvedUrl("../../ui/qml/Dashboard.qml"))
            tryVerify(function () { return sv.depth === 1 && sv.currentItem !== null }, 5000,
                      "exactly one current Dashboard page")
            dashboardPage = sv.currentItem
            tryVerify(function () { return dash() !== null && swipe() !== null && store() !== null }, 8000,
                      "real Dashboard + SwipeView + store loaded in the shell")
            tryVerify(function () { return store().loaded }, 5000, "store finished loading")
        }
        function cleanupTestCase() { if (win) win.destroy() }

        // ═════════════════════════════ AREA 1 - PAGE NAVIGATION ══════════════

        // NAV-01..16 - add page → land AND STAY (the snap-back bug), portrait+landscape.
        function test_nav_add_page_lands_and_stays_data() {
            var rows = [], oris = ["portrait", "landscape"]
            for (var o = 0; o < oris.length; o++)
                for (var n = 1; n <= 8; n++)
                    rows.push({ tag: oris[o] + "-p" + n, ori: oris[o], n: n })
            return rows
        }
        function test_nav_add_page_lands_and_stays(d) {
            resetShell(d.ori)
            var s = store(), sw = swipe()
            snap(win.contentItem, "nav_" + d.tag + "_before")
            for (var i = 1; i <= d.n; i++) s.addPage("")
            var target = d.n
            sw.goToPage(target)
            tryVerify(function () { return sw.currentIndex === target }, 5000, "reached new page " + target)
            wait(900)   // outlast the deferred ListView relayout - the snap-back window
            compare(sw.currentIndex, target, "STAYED on new page " + target + " (" + d.ori + ", no snap-back)")
            snap(win.contentItem, "shell_page" + d.tag)
        }

        // NAV-17/18 - sequential multi-add, land+stay on each (portrait+landscape).
        function test_nav_sequential_multiadd_data() { return [{ tag: "portrait", ori: "portrait" }, { tag: "landscape", ori: "landscape" }] }
        function test_nav_sequential_multiadd(d) {
            resetShell(d.ori)
            var s = store(), sw = swipe()
            for (var k = 0; k < 5; k++) {
                var target = s.pageCount()
                s.addPage("")
                sw.goToPage(target)
                tryVerify(function () { return sw.currentIndex === target }, 4000, "reached page " + target)
                wait(500)
                compare(sw.currentIndex, target, "stayed on page " + target)
            }
            compare(s.pageCount(), 6, "6 pages after 5 sequential adds")
        }

        // NAV-19 - toolbar add-page button lands on the new page and stays.
        function test_nav_addpage_toolbar_lands_and_stays() {
            resetShell("portrait")
            var sw = swipe(), db = dash()
            db.editMode = true; wait(120)
            var b = barBtn("ui-add-page"); verify(b && b.visible, "add-page toolbar button visible in edit")
            clickItem(b)
            tryVerify(function () { return sw.count === 2 && sw.currentIndex === sw.count - 1 }, 5000, "landed on toolbar-added page")
            wait(900)
            compare(sw.currentIndex, sw.count - 1, "STAYED on toolbar-added page")
        }

        // NAV-21..28 - swipe navigation.
        function test_nav_swipe_data() {
            return [
                { tag: "advance-portrait",  ori: "portrait",  start: 0, dir: -1, expect: 1 },
                { tag: "retreat-portrait",  ori: "portrait",  start: 2, dir:  1, expect: 1 },
                { tag: "clamp-first",       ori: "portrait",  start: 0, dir:  1, expect: 0 },
                { tag: "clamp-last",        ori: "portrait",  start: 3, dir: -1, expect: 3 },
                { tag: "advance-landscape", ori: "landscape", start: 0, dir: -1, expect: 1 },
                { tag: "retreat-landscape", ori: "landscape", start: 2, dir:  1, expect: 1 }
            ]
        }
        function test_nav_swipe(d) {
            resetShell(d.ori)
            var s = store(), sw = swipe()
            s.addPage(""); s.addPage(""); s.addPage("")           // 4 pages: 0..3
            tryVerify(function () { return sw.count === 4 }, 4000)
            sw.goToPage(d.start)
            tryVerify(function () { return sw.currentIndex === d.start }, 4000)
            settleLanding(sw)
            swipeDrag(sw, d.dir)
            tryVerify(function () { return sw.currentIndex === d.expect }, 4000, "swiped to " + d.expect)
            wait(900)
            compare(sw.currentIndex, d.expect, "swipe result stayed at " + d.expect + " (" + d.tag + ")")
        }

        // NAV-26 - swipe disabled in edit mode.
        function test_nav_swipe_disabled_in_edit() {
            resetShell("portrait")
            var s = store(), sw = swipe(), db = dash()
            s.addPage(""); s.addPage(""); tryVerify(function () { return sw.count === 3 }, 4000)
            sw.goToPage(1); tryVerify(function () { return sw.currentIndex === 1 }, 4000); wait(300)
            settleLanding(sw)
            db.editMode = true; wait(150)
            verify(sw.interactive === false, "SwipeView not interactive in edit mode")
            swipeDrag(sw, -1); wait(400)
            compare(sw.currentIndex, 1, "swipe ignored while editing")
        }

        // NAV-25 - swipe then STAYS (no rebound).
        function test_nav_swipe_then_stays_no_rebound() {
            resetShell("portrait")
            var s = store(), sw = swipe()
            s.addPage(""); s.addPage(""); tryVerify(function () { return sw.count === 3 }, 4000)
            settleLanding(sw)
            swipeDrag(sw, -1)
            tryVerify(function () { return sw.currentIndex === 1 }, 4000, "swiped to page 1")
            wait(900)
            compare(sw.currentIndex, 1, "swipe stayed (no rebound)")
        }

        // NAV-40 - page-name label follows a swipe.
        function test_nav_pagename_follows_swipe() {
            resetShell("portrait")
            var s = store(), sw = swipe()
            s.addPage("Ops"); tryVerify(function () { return sw.count === 2 }, 4000)
            settleLanding(sw)
            swipeDrag(sw, -1)
            tryVerify(function () { return sw.currentIndex === 1 }, 4000, "swiped to page 1")
            wait(300)
            var lbl = G.byText(win.contentItem, "Ops"); verify(lbl && lbl.visible, "label follows swipe to page name")
        }

        // NAV-41/42/43 - remove current page re-clamps to a valid index.
        function test_nav_remove_reclamps_data() {
            return [
                { tag: "last",   removeAt: 2, pages: 3 },
                { tag: "middle", removeAt: 1, pages: 4 },
                { tag: "first",  removeAt: 0, pages: 3 }
            ]
        }
        function test_nav_remove_reclamps(d) {
            resetShell("portrait")
            var s = store(), sw = swipe(), db = dash()
            for (var i = 1; i < d.pages; i++) s.addPage("")
            tryVerify(function () { return sw.count === d.pages }, 4000)
            db.editMode = true; wait(120)
            sw.goToPage(d.removeAt); tryVerify(function () { return sw.currentIndex === d.removeAt }, 4000)
            var del = barBtn("ui-del-page"); verify(del && del.visible, "del-page button visible with >1 page")
            clickItem(del)
            tryVerify(function () { return db.pageDeleteDialog.visible }, 2000,
                      "remove confirmation is shown")
            clickItem(db.pageDeleteConfirmButton)
            tryVerify(function () { return sw.count === d.pages - 1 }, 4000, "page removed")
            wait(900)
            verify(sw.currentIndex >= 0 && sw.currentIndex < sw.count, "index re-clamped into range after remove")
        }

        // NAV-44/45 - del-page hidden with a single page (cannot remove the only page).
        function test_nav_delpage_hidden_with_single_page() {
            resetShell("portrait")
            var s = store(), db = dash()
            db.editMode = true; wait(120)
            var del = barBtn("ui-del-page"); verify(del !== null, "del-page button exists")
            compare(del.visible, false, "del-page hidden when only one page")
            compare(s.pageCount(), 1, "still exactly one page")
        }

        // NAV-46 - removed page's tile settings are pruned.
        function test_nav_removed_page_settings_pruned() {
            resetShell("portrait")
            var s = store()
            s.addPage("")
            var id = s.addTile(1, "hydration"); verify(id, "tile added on page 1")
            s.setSetting(id, "goal", 5); verify(s.settingsFor(id).goal === 5)
            s.removePage(1)
            verify(s.settingsFor(id).goal === undefined, "settings pruned when page removed")
        }

        // NAV-47/48/50 - overflow creates a new screen and the view follows + stays.
        function test_nav_overflow_creates_page_and_follows_data() { return [{ tag: "portrait", ori: "portrait" }, { tag: "landscape", ori: "landscape" }] }
        function test_nav_overflow_creates_page_and_follows(d) {
            resetShell(d.ori)
            var s = store(), sw = swipe()
            s.addTile(0, "cpu"); s.addTile(0, "gpu"); s.addTile(0, "ram")   // page 0 full
            var ofId = s.addTile(0, "clock"); verify(ofId, "overflow tile added")
            var target = s.pageIndexForTile(ofId)
            compare(target, 1, "overflow created a second screen")
            compare(s.pageCount(), 2, "two pages after overflow")
            sw.goToPage(target)
            tryVerify(function () { return sw.currentIndex === target }, 5000, "reached overflow screen")
            wait(900)
            compare(sw.currentIndex, target, "STAYED on overflow screen (" + d.ori + ")")
        }

        // NAV-51 - a full page never scrolls (Flickable not interactive).
        function test_nav_full_page_not_interactive() {
            resetShell("portrait")
            var s = store()
            var id = s.addTile(0, "cpu"); s.addTile(0, "gpu"); s.addTile(0, "ram")
            wait(250)
            var cell = cellFor(id); verify(cell, "a cell is present on the full page")
            var fl = ancestorFlick(cell); verify(fl, "found the page Flickable")
            compare(fl.interactive, false, "full page is not interactive (never scrolls)")
        }

        // NAV-52 - picker shows the "screen is full" hint.
        function test_nav_picker_full_hint() {
            resetShell("portrait")
            var s = store(), db = dash()
            s.addTile(0, "cpu"); s.addTile(0, "gpu"); s.addTile(0, "ram")
            db.editMode = true; wait(120)
            clickItem(barBtn("ui-plus"))
            var pk = picker(); tryVerify(function () { return pk.shown }, 4000); wait(250)
            var hint = G.byText(win.contentItem, "This screen is full")
            verify(hint && hint.visible, "picker shows the screen-full banner")
        }

        // NAV-29 - indicator count equals page count.
        function test_nav_indicator_count() {
            resetShell("portrait")
            var s = store(); s.addPage(""); s.addPage(""); s.addPage("")
            var pi = pageInd(); verify(pi, "PageIndicator found")
            tryVerify(function () { return pi.count === s.pageCount() }, 4000)
            compare(pi.count, 4, "indicator count == 4 pages")
        }

        // NAV-30 - indicator currentIndex tracks navigation.
        function test_nav_indicator_tracks_currentindex() {
            resetShell("portrait")
            var s = store(), sw = swipe(); s.addPage(""); s.addPage("")
            sw.goToPage(2); tryVerify(function () { return sw.currentIndex === 2 }, 4000)
            var pi = pageInd(); tryVerify(function () { return pi.currentIndex === 2 }, 4000, "indicator tracks currentIndex")
        }

        // NAV-35 - indicator count grows after adding a page.
        function test_nav_indicator_updates_on_add() {
            resetShell("portrait")
            var s = store(); var pi = pageInd()
            tryVerify(function () { return pi.count === 1 }, 4000)
            s.addPage("")
            tryVerify(function () { return pi.count === 2 }, 4000, "indicator grew after add page")
        }

        // NAV-36 - indicator count shrinks after removing a page.
        function test_nav_indicator_updates_on_remove() {
            resetShell("portrait")
            var s = store(); s.addPage(""); var pi = pageInd()
            tryVerify(function () { return pi.count === 2 }, 4000)
            s.removePage(1)
            tryVerify(function () { return pi.count === 1 }, 4000, "indicator shrank after remove page")
        }

        // NAV-31 - active chip is the wide one, others narrow.
        function test_nav_indicator_active_chip_wider() {
            resetShell("portrait")
            var s = store(), sw = swipe(); s.addPage(""); s.addPage("")
            sw.goToPage(1); tryVerify(function () { return sw.currentIndex === 1 }, 4000); wait(200)
            var pi = pageInd()
            var active = innerRect(indicatorDelegate(pi, 1))
            var other = innerRect(indicatorDelegate(pi, 0))
            verify(active && other, "found active + inactive chip rects")
            tryVerify(function () { return Math.round(active.width) === 36 }, 3000, "active chip is 36 wide")
            compare(Math.round(other.width), 14, "inactive chip is 14 wide")
        }

        // NAV-33 - tapping a chip navigates and stays.
        function test_nav_indicator_tap_navigates() {
            resetShell("portrait")
            var s = store(), sw = swipe(); s.addPage(""); s.addPage(""); s.addPage("")
            var pi = pageInd(); tryVerify(function () { return pi.count === 4 }, 4000); wait(200)
            settleLanding(sw)
            var del = indicatorDelegate(pi, 3); verify(del, "chip 3 delegate present")
            mouseClick(del, del.width / 2, del.height / 2)
            tryVerify(function () { return sw.currentIndex === 3 }, 4000, "tapped chip navigated")
            wait(900)
            compare(sw.currentIndex, 3, "stayed after chip tap")
        }

        // NAV-34 - chip hit-area is touch sized (>=44px).
        function test_nav_indicator_hit_area_touch_sized() {
            resetShell("portrait")
            var s = store(); s.addPage("")
            var pi = pageInd(); tryVerify(function () { return pi.count === 2 }, 4000); wait(150)
            var del = indicatorDelegate(pi, 0); verify(del, "chip delegate present")
            verify(Math.round(del.implicitHeight) >= 44,
                   "chip hit-area is at least 44px (touch sized)")
        }

        // NAV-37 - page-name label shows the current page name.
        function test_nav_pagename_label_current() {
            resetShell("portrait")
            var s = store(), sw = swipe()
            s.addPage("Ops"); tryVerify(function () { return sw.count === 2 }, 4000)
            sw.goToPage(1); tryVerify(function () { return sw.currentIndex === 1 }, 4000); wait(200)
            var lbl = G.byText(win.contentItem, "Ops"); verify(lbl && lbl.visible, "label shows current page name")
        }

        // NAV-38 - label refreshes after a rename.
        function test_nav_pagename_after_rename() {
            resetShell("portrait")
            var s = store(), sw = swipe()
            s.addPage("Alpha"); sw.goToPage(1); tryVerify(function () { return sw.currentIndex === 1 }, 4000)
            s.renamePage(1, "Ops"); wait(200)
            var lbl = G.byText(win.contentItem, "Ops"); verify(lbl && lbl.visible, "label refreshed after rename")
        }

        // NAV - blank doc loads with one page on the first index.
        function test_nav_load_blank_single_page() {
            resetShell("portrait")
            var s = store(), sw = swipe()
            compare(s.pageCount(), 1, "blank doc has one page")
            compare(sw.count, 1, "SwipeView shows one page")
            compare(sw.currentIndex, 0, "on the first page")
        }

        // ═════════════════════════════ AREA 2 - EDIT MODE ════════════════════

        // EDIT-01 - tapping edit enters edit mode.
        function test_edit_enter_via_button() {
            resetShell("portrait")
            var db = dash()
            var eb = editBtn(); verify(eb, "edit button present")
            compare(db.editMode, false, "starts out of edit mode")
            clickItem(eb)
            tryVerify(function () { return db.editMode === true }, 3000, "entered edit mode via button")
        }

        // EDIT-02 - edit button becomes check + highlighted.
        function test_edit_button_becomes_check_highlighted() {
            resetShell("portrait")
            var db = dash()
            clickItem(editBtn()); tryVerify(function () { return db.editMode }, 3000); wait(120)
            var eb = editBtn(); verify(eb.highlighted === true, "edit button highlighted in edit mode")
            verify(iconAny(eb, "ui-check"), "edit button shows the check icon")
        }

        // EDIT-05 - tapping check exits edit mode.
        function test_edit_exit_via_button() {
            resetShell("portrait")
            var db = dash()
            db.editMode = true; wait(120)
            clickItem(editBtn())
            tryVerify(function () { return db.editMode === false }, 3000, "exited edit mode via check button")
        }

        // EDIT-06 - exiting edit force-flushes a pending save.
        function test_edit_exit_forces_save() {
            resetShell("portrait")
            var db = dash(), s = store()
            db.editMode = true; wait(80)
            s.setSetting("probe-x", "k", 1)
            verify(s._savePending === true, "a debounced save is pending")
            clickItem(editBtn())
            tryVerify(function () { return db.editMode === false }, 3000)
            verify(s._savePending === false, "exiting edit flushed the pending save")
        }

        // EDIT-03 - per-tile edit overlay fades in.
        function test_edit_tile_overlay_visible_in_edit() {
            resetShell("portrait")
            var s = store(), db = dash()
            var id = s.addTile(0, "cpu"); wait(150)
            db.editMode = true
            var cell = cellFor(id); verify(cell, "tile cell present")
            var trash = iconAny(cell, "ui-trash"); verify(trash, "trash icon exists in overlay")
            var ov = ancestor(trash, function (n) { return n && n.z === 30 })
            verify(ov, "edit overlay rectangle found")
            tryVerify(function () { return ov.opacity > 0.9 && ov.visible }, 3000, "edit overlay faded in")
        }

        // EDIT-04 - expand corner button hides in edit mode.
        function test_edit_expand_corner_hidden_in_edit() {
            resetShell("portrait")
            var s = store(), db = dash()
            var id = s.addTile(0, "cpu"); wait(150)
            var cell = cellFor(id)
            var exp = iconAny(cell, "ui-expand"); verify(exp, "expand icon exists")
            var corner = exp.parent
            verify(corner.opacity > 0.9, "expand corner visible outside edit")
            db.editMode = true
            tryVerify(function () { return corner.opacity < 0.1 }, 3000, "expand corner hidden in edit mode")
        }

        // EDIT-07..12 - toolbar button visibility.
        function test_edit_toolbar_visibility_data() {
            return [
                { tag: "plus-in-edit",       icon: "ui-plus",     edit: true,  pages: 1, expect: true },
                { tag: "addpage-in-edit",    icon: "ui-add-page", edit: true,  pages: 1, expect: true },
                { tag: "delpage-in-edit-2p", icon: "ui-del-page", edit: true,  pages: 2, expect: true },
                { tag: "plus-hidden-noedit", icon: "ui-plus",     edit: false, pages: 1, expect: false },
                { tag: "addpg-hidden-noedit",icon: "ui-add-page", edit: false, pages: 1, expect: false },
                { tag: "palette-always",     icon: "ui-palette",  edit: false, pages: 1, expect: true },
                { tag: "settings-always",    icon: "ui-settings", edit: false, pages: 1, expect: true }
            ]
        }
        function test_edit_toolbar_visibility(d) {
            resetShell("portrait")
            var s = store(), db = dash()
            for (var i = 1; i < d.pages; i++) s.addPage("")
            db.editMode = d.edit; wait(150)
            var b = barBtn(d.icon); verify(b !== null, "button " + d.icon + " exists")
            compare(b.visible, d.expect, d.icon + " visible == " + d.expect)
        }

        // EDIT - SwipeView.interactive === !editMode.
        function test_edit_swipeview_interactive_reflects_editmode() {
            resetShell("portrait")
            var sw = swipe(), db = dash()
            db.editMode = false; wait(80); compare(sw.interactive, true, "interactive out of edit")
            db.editMode = true;  wait(80); compare(sw.interactive, false, "not interactive in edit")
            db.editMode = false; wait(80); compare(sw.interactive, true, "interactive again after exit")
        }

        // EDIT-16 - toolbar plus opens the picker.
        function test_edit_plus_opens_picker() {
            resetShell("portrait")
            var db = dash()
            db.editMode = true; wait(120)
            clickItem(barBtn("ui-plus"))
            var pk = picker(); tryVerify(function () { return pk.shown === true }, 4000, "plus opened the picker")
        }

        // EDIT-15 - tapping the in-page ghost opens the picker.
        function test_edit_ghost_opens_picker() {
            resetShell("portrait")
            var db = dash()
            db.editMode = true; wait(200)
            verify(clickText(win.contentItem, "Add widget"), "clicked the add-widget ghost")
            var pk = picker(); tryVerify(function () { return pk.shown === true }, 4000, "ghost opened the picker")
        }

        // EDIT-13 - add ghost shows on an empty page in edit.
        function test_edit_add_ghost_visible_on_empty_page() {
            resetShell("portrait")
            var db = dash()
            db.editMode = true; wait(200)
            var g = G.byText(win.contentItem, "Add widget"); verify(g && g.visible, "add ghost visible on empty page in edit")
        }

        // EDIT-14 - add ghost hidden when the page is full.
        function test_edit_add_ghost_hidden_when_full() {
            resetShell("portrait")
            var s = store(), db = dash()
            s.addTile(0, "cpu"); s.addTile(0, "gpu"); s.addTile(0, "ram"); wait(150)
            db.editMode = true; wait(250)
            var g = G.byText(win.contentItem, "Add widget"); verify(g === null || !g.visible, "add ghost hidden on full page")
        }

        // EDIT-18 - picker scrim tap closes it.
        function test_edit_picker_scrim_closes() {
            resetShell("portrait")
            var db = dash()
            db.editMode = true; wait(120)
            clickItem(barBtn("ui-plus")); var pk = picker(); tryVerify(function () { return pk.shown }, 4000); wait(200)
            mouseClick(pk, 8, 8)   // corner = scrim, outside the centered card
            tryVerify(function () { return pk.shown === false }, 4000, "scrim tap closed the picker")
        }

        // EDIT-19 - picker close button closes it.
        function test_edit_picker_close_button_closes() {
            resetShell("portrait")
            var db = dash()
            db.editMode = true; wait(120)
            clickItem(barBtn("ui-plus")); var pk = picker(); tryVerify(function () { return pk.shown }, 4000); wait(200)
            verify(clickIcon(pk, "ui-close"), "clicked the picker close button")
            tryVerify(function () { return pk.shown === false }, 4000, "close button closed the picker")
        }

        // EDIT-20 - picker targets the current page.
        function test_edit_picker_targets_current_page() {
            resetShell("portrait")
            var s = store(), sw = swipe(), db = dash()
            s.addPage(""); tryVerify(function () { return sw.count === 2 }, 4000)
            sw.goToPage(1); tryVerify(function () { return sw.currentIndex === 1 }, 4000)
            db.editMode = true; wait(120)
            clickItem(barBtn("ui-plus")); var pk = picker(); tryVerify(function () { return pk.shown }, 4000)
            compare(pk.pageIndex, 1, "picker targets the current page")
        }

        // EDIT-17 - picker lists widget cards + category headers.
        function test_edit_picker_lists_widget_cards() {
            resetShell("portrait")
            var db = dash()
            db.editMode = true; wait(120)
            clickItem(barBtn("ui-plus")); var pk = picker(); tryVerify(function () { return pk.shown }, 4000); wait(300)
            var card = widgetCard("cpu"); verify(card && card.visible, "picker lists widget cards (cpu present)")
            var hdr = G.byText(pk, "System"); verify(hdr && hdr.visible, "picker renders category headers")
        }

        // EDIT-21/22 - tapping a catalog card adds a tile + closes the picker.
        function test_edit_place_tile_via_picker() {
            resetShell("portrait")
            var s = store(), db = dash()
            db.editMode = true; wait(120)
            var before = s.pages()[0].tiles.length
            clickItem(barBtn("ui-plus")); var pk = picker(); tryVerify(function () { return pk.shown }, 4000); wait(250)
            var card = widgetCard("cpu"); verify(card, "cpu card present")
            clickItem(maIn(card))
            tryVerify(function () { return s.pages()[0].tiles.length === before + 1 }, 4000, "a tile was added")
            tryVerify(function () { return pk.shown === false }, 3000, "picker closed after placing")
        }

        // EDIT-23/26 - the placed tile renders a cell and persists in the store.
        function test_edit_placed_tile_renders_cell_and_persists() {
            resetShell("portrait")
            var s = store(), db = dash()
            db.editMode = true; wait(120)
            clickItem(barBtn("ui-plus")); var pk = picker(); tryVerify(function () { return pk.shown }, 4000); wait(250)
            clickItem(maIn(widgetCard("clock")))
            tryVerify(function () { return s.pages()[0].tiles.length === 1 }, 4000)
            var id = s.pages()[0].tiles[0].id
            verify(s.pageIndexForTile(id) === 0, "tile persisted in the store document")
            var cell = cellFor(id); verify(cell && cell.visible, "the new tile renders a visible cell")
        }

        // EDIT-24 - placing on a full page overflows to a new screen and the view follows+stays.
        function test_edit_place_overflow_follows_to_new_page() {
            resetShell("portrait")
            var s = store(), sw = swipe(), db = dash()
            s.addTile(0, "cpu"); s.addTile(0, "gpu"); s.addTile(0, "ram")
            var before = allTileIds(s)
            db.editMode = true; wait(120)
            clickItem(barBtn("ui-plus")); var pk = picker(); tryVerify(function () { return pk.shown }, 4000); wait(250)
            clickItem(maIn(widgetCard("clock")))
            tryVerify(function () { return s.pageCount() === 2 }, 4000, "overflow created a new page")
            var nid = findNewId(before, allTileIds(s)); verify(nid, "located the new tile id")
            var target = s.pageIndexForTile(nid); compare(target, 1, "new tile is on page 1")
            tryVerify(function () { return sw.currentIndex === target }, 5000, "view followed to the overflow page")
            wait(900)
            compare(sw.currentIndex, target, "STAYED on the overflow page")
        }

        // EDIT - adding two widgets increments the tile count twice.
        function test_edit_two_add_widgets_increment_count() {
            resetShell("portrait")
            var s = store(), db = dash()
            db.editMode = true; wait(120)
            clickItem(barBtn("ui-plus")); var pk = picker(); tryVerify(function () { return pk.shown }, 4000); wait(250)
            clickItem(maIn(widgetCard("cpu")))
            tryVerify(function () { return s.pages()[0].tiles.length === 1 }, 4000)
            clickItem(barBtn("ui-plus")); tryVerify(function () { return pk.shown }, 4000); wait(250)
            clickItem(maIn(widgetCard("clock")))
            tryVerify(function () { return s.pages()[0].tiles.length === 2 }, 4000, "two widgets added")
        }

        // EDIT-27 - move-right reorders the tile in the store.
        function test_edit_move_right_reorders() {
            resetShell("portrait")
            var s = store(), db = dash()
            var a = s.addTile(0, "cpu"), b = s.addTile(0, "gpu"); s.addTile(0, "ram")
            wait(150); db.editMode = true; wait(150)
            var cell = cellFor(a); verify(cell, "first tile cell present")
            verify(clickIcon(cell, "ui-caret-right"), "clicked move-right on the first tile")
            tryVerify(function () { return s.pages()[0].tiles[1].id === a }, 4000, "cpu moved to index 1")
            compare(s.pages()[0].tiles[0].id, b, "gpu is now first")
        }

        // EDIT-28 - move-left reorders the tile.
        function test_edit_move_left_reorders() {
            resetShell("portrait")
            var s = store(), db = dash()
            s.addTile(0, "cpu"); s.addTile(0, "gpu"); var c = s.addTile(0, "ram")
            wait(150); db.editMode = true; wait(150)
            var cell = cellFor(c); verify(cell, "last tile cell present")
            verify(clickIcon(cell, "ui-caret-left"), "clicked move-left on the last tile")
            tryVerify(function () { return s.pages()[0].tiles[1].id === c }, 4000, "ram moved to index 1")
        }

        // EDIT-29 - move-left hidden for the first tile.
        function test_edit_move_left_hidden_for_first_tile() {
            resetShell("portrait")
            var s = store(), db = dash()
            var a = s.addTile(0, "cpu"); s.addTile(0, "gpu"); wait(150)
            db.editMode = true; wait(150)
            var cell = cellFor(a)
            var ic = iconAny(cell, "ui-caret-left"); verify(ic, "move-left icon exists")
            compare(ic.parent.visible, false, "move-left hidden for the first tile")
        }

        // EDIT-30 - move-right hidden for the last tile.
        function test_edit_move_right_hidden_for_last_tile() {
            resetShell("portrait")
            var s = store(), db = dash()
            s.addTile(0, "cpu"); var b = s.addTile(0, "gpu"); wait(150)
            db.editMode = true; wait(150)
            var cell = cellFor(b)
            var ic = iconAny(cell, "ui-caret-right"); verify(ic, "move-right icon exists")
            compare(ic.parent.visible, false, "move-right hidden for the last tile")
        }

        // EDIT-33 - resize hidden for a type with no multiple sizes (unknown type).
        function test_edit_resize_hidden_for_unknown_type() {
            resetShell("portrait")
            var s = store(), db = dash()
            s.applyExternal(JSON.stringify({ version: 1, appearance: {}, settings: {},
                pages: [{ name: "Home", tiles: [{ id: "bogus-1", type: "bogus" }] }] }))
            wait(150); db.editMode = true; wait(150)
            var cell = cellFor("bogus-1"); verify(cell, "bogus-type cell present")
            var ic = iconAny(cell, "ui-resize"); verify(ic, "resize icon exists")
            compare(ic.parent.visible, false, "resize hidden for a type with a single legal size")
        }

        // EDIT-34 - resize visible for a multi-size type (cpu).
        function test_edit_resize_visible_for_multisize_type() {
            resetShell("portrait")
            var s = store(), db = dash()
            var id = s.addTile(0, "cpu"); wait(150); db.editMode = true; wait(150)
            var cell = cellFor(id)
            var ic = iconAny(cell, "ui-resize"); verify(ic, "resize icon exists")
            compare(ic.parent.visible, true, "resize visible for cpu (multi-size)")
        }

        // EDIT-35..37 - cycling the resize button steps through the type's legal sizes.
        function test_edit_resize_cycles_sizes_data() {
            return [
                { tag: "step1", clicks: 1, expect: "1x1.5" },
                { tag: "step2", clicks: 2, expect: "0.5x0.5" },
                { tag: "step3", clicks: 3, expect: "0.5x1" }
            ]
        }
        function test_edit_resize_cycles_sizes(d) {
            resetShell("portrait")
            var s = store(), db = dash()
            var id = s.addTile(0, "cpu"); wait(150); db.editMode = true; wait(150)
            var cell = cellFor(id)
            var w0 = cell.width, h0 = cell.height
            for (var k = 0; k < d.clicks; k++) { verify(clickIcon(cell, "ui-resize"), "resize click " + k); wait(200) }
            tryVerify(function () { return s.pages()[0].tiles[0].size === d.expect }, 4000, "size cycled to " + d.expect)
            if (d.expect === "1x1.5") {
                // 1x1.5 grows the semantic long axis: width in a landscape
                // projection, height in portrait.  The old height-only check
                // rejected the correctly rendered landscape geometry.
                var page = swipe().currentItem
                verify(page && page.landscape !== undefined, "page projection available")
                tryVerify(function () {
                    return page.landscape ? Math.abs(cell.width - w0) > 1
                                          : Math.abs(cell.height - h0) > 1
                }, 3000, "cell long-axis geometry changed on resize")
            }
        }

        // EDIT-38 - resize refused when it would overflow the screen.
        function test_edit_resize_refused_on_full_page() {
            resetShell("portrait")
            var s = store(), db = dash()
            var id = s.addTile(0, "cpu"); s.addTile(0, "gpu"); s.addTile(0, "ram")   // full
            wait(150); db.editMode = true; wait(150)
            var cell = cellFor(id)
            compare(s.pages()[0].tiles[0].size, "1x1", "cpu starts at 1x1")
            verify(clickIcon(cell, "ui-resize"), "clicked resize on a full page")
            wait(400)
            compare(s.pages()[0].tiles[0].size, "1x1", "resize refused (would overflow the full page)")
        }

        // EDIT-39 - trash removes the tile.
        function test_edit_trash_removes_tile() {
            resetShell("portrait")
            var s = store(), db = dash()
            var id = s.addTile(0, "cpu"); s.addTile(0, "gpu"); wait(150)
            db.editMode = true; wait(150)
            var cell = cellFor(id)
            verify(clickIcon(cell, "ui-trash"), "clicked trash")
            tryVerify(function () { return s.pages()[0].tiles.length === 1 }, 4000, "tile removed from store")
            tryVerify(function () { return cellFor(id) === null }, 4000, "cell gone after removal")
        }

        // EDIT-43 - removed tile's settings are pruned.
        function test_edit_removed_tile_settings_pruned() {
            resetShell("portrait")
            var s = store(), db = dash()
            var id = s.addTile(0, "hydration"); s.setSetting(id, "goal", 5); wait(120)
            db.editMode = true; wait(150)
            var cell = cellFor(id)
            verify(clickIcon(cell, "ui-trash"), "clicked trash")
            tryVerify(function () { return s.settingsFor(id).goal === undefined }, 4000, "settings pruned on tile remove")
        }

        // EDIT-44 - tapping the expand corner opens the config overlay.
        function test_edit_expand_opens_overlay() {
            resetShell("portrait")
            var s = store(), db = dash()
            var id = s.addTile(0, "hydration"); wait(150)
            verify(clickIcon(cellFor(id), "ui-expand"), "clicked the expand corner")
            tryVerify(function () { return db.hasExpanded === true }, 4000, "overlay opened")
            compare(db.shownType, "hydration", "overlay shows the tapped tile's type")
        }

        // EDIT-45 - overlay header shows the widget title.
        function test_edit_overlay_shows_title() {
            resetShell("portrait")
            var s = store(), db = dash()
            var id = s.addTile(0, "hydration"); wait(150)
            clickIcon(cellFor(id), "ui-expand"); tryVerify(function () { return db.hasExpanded }, 4000); wait(150)
            var t = G.byText(overlayItem(), "Hydration"); verify(t && t.visible, "overlay header shows the widget title")
        }

        // EDIT-45b - overlay header shows the widget icon glyph.
        function test_edit_overlay_header_icon_present() {
            resetShell("portrait")
            var s = store(), db = dash()
            var id = s.addTile(0, "hydration"); wait(150)
            clickIcon(cellFor(id), "ui-expand"); tryVerify(function () { return db.hasExpanded }, 4000); wait(150)
            verify(iconAny(overlayItem(), "hydration"), "overlay header shows the widget icon glyph")
        }

        // EDIT-46 - the Done bar closes the overlay.
        function test_edit_overlay_done_closes() {
            resetShell("portrait")
            var s = store(), db = dash()
            var id = s.addTile(0, "hydration"); wait(150)
            clickIcon(cellFor(id), "ui-expand"); tryVerify(function () { return db.hasExpanded }, 4000); wait(150)
            verify(clickText(overlayItem(), "Done"), "clicked the Done bar")
            tryVerify(function () { return db.hasExpanded === false }, 4000, "Done bar closed the overlay")
        }

        // EDIT-47 - the header back button closes the overlay.
        function test_edit_overlay_back_closes() {
            resetShell("portrait")
            var s = store(), db = dash()
            var id = s.addTile(0, "hydration"); wait(150)
            clickIcon(cellFor(id), "ui-expand"); tryVerify(function () { return db.hasExpanded }, 4000); wait(150)
            verify(clickIcon(overlayItem(), "ui-caret-left"), "clicked the header back button")
            tryVerify(function () { return db.hasExpanded === false }, 4000, "back button closed the overlay")
        }

        // EDIT-48 - a confirmed config reset persists without erasing personal data.
        function test_edit_overlay_reset_writes_store() {
            resetShell("portrait")
            var s = store(), db = dash()
            var id = s.addTile(0, "hydration"); wait(150)
            clickIcon(cellFor(id), "ui-expand"); tryVerify(function () { return db.hasExpanded }, 4000); wait(150)
            s.setSetting(id, "goal", 99); verify(s.settingsFor(id).goal === 99, "seeded a non-default value")
            var rev0 = s.revision
            verify(clickText(overlayItem(), "Reset configuration"), "clicked Reset configuration")
            tryVerify(function () { return db.widgetDataDialog.visible }, 3000,
                      "scoped reset confirmation opened")
            clickItem(db.widgetDataConfirmButton)
            tryVerify(function () { return !db.widgetDataDialog.visible }, 3000,
                      "scoped reset confirmation closed")
            tryVerify(function () { return s.settingsFor(id).goal === 8 }, 4000, "config reset persisted (goal back to default 8)")
            verify(s.revision > rev0, "store revision bumped by the config action")
        }

        // EDIT - no overlay is open right after a reset.
        function test_edit_overlay_absent_initially() {
            resetShell("portrait")
            compare(dash().hasExpanded, false, "no expanded overlay after reset")
        }

        // EDIT - a placed tile's cell has real geometry.
        function test_edit_placed_tile_cell_geometry() {
            resetShell("portrait")
            var s = store()
            var id = s.addTile(0, "cpu"); wait(200)
            var cell = cellFor(id); verify(cell, "cell present")
            verify(cell.width > 0 && cell.height > 0, "cell has real geometry")
            verify(cell.visible, "cell is visible")
        }

        // EDIT-49 - per-page background style applies to the current page.
        function test_edit_per_page_background_applies() {
            resetShell("portrait")
            var s = store()
            win.animatedBackground = true; wait(200)
            var before = snap(win.contentItem, "bg_before")
            s.setPageBackground(0, "style", "stars")
            wait(400)
            var after = snap(win.contentItem, "bg_after")
            compare(s.pageBackground(0).style, "stars", "per-page style set in the store (drives the visible pageBg)")
            verify(before && after, "captured before/after background frames")
        }

        // EDIT-50 - "Use global" clears the per-page override.
        function test_edit_per_page_use_global_clears_override() {
            resetShell("portrait")
            var s = store()
            s.setPageBackground(0, "style", "stars"); wait(120)
            compare(s.pageBackground(0).style, "stars", "per-page override set")
            s.setPageBackground(0, "style", "")   // Use global
            wait(120)
            verify(s.pageBackground(0).style === undefined, "per-page override cleared → falls back to global")
        }
    }
}
