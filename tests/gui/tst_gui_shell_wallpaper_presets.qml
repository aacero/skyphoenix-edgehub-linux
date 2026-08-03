import QtQuick
import QtQuick.Controls
import QtTest
import "../../ui/qml" as App
import "../../ui/qml/widgets" as W
import "GuiUtil.js" as G

// ─────────────────────────────────────────────────────────────────────────
// VISIBLE GUI tests for the Hub SHELL - wallpaper/background, presets (append
// screens), the first-run wizard, and empty/error/diagnostics states.
//
// Recipes (see scratchpad/specs/04_instantiation_cookbook.md):
//   • The REAL Hub shell is main.qml → Dashboard.qml. Each TestCase replaces
//     the resolved initial page immediately so it owns one deterministic tree.
//   • Wallpaper selection is driven by a REAL BackgroundPicker hosted in THIS
//     (the test) window, bound to the shell's OWN store - clicking a thumbnail
//     mutates the shell store, and the shell's page background re-renders. The
//     picker and the shell are separate KWin surfaces, so grabbing the dashboard
//     samples the live background without the picker bleeding into the frame.
//   • The repository QuickTest runner embeds the shipped asset QRCs, so wallpaper
//     and backdrop assertions exercise the same qrc:/ pixels as the products.
// ─────────────────────────────────────────────────────────────────────────
Item {
    id: root
    width: 1280; height: 720

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

    // ── FirstRunWizard context (it resolves theme/_screens/root/wizardBridge) ──
    property alias theme: _theme
    App.Theme { id: _theme }
    property string themeMode: "midnight"
    property string accentName: "blue"
    QtObject {
        id: wizardBridge
        property bool nextResult: true
        property int calls: 0
        property var lastArgs: null
        function completeWizard(edid, name, model, layout, themeM, accent, autostart, reconnect, notify) {
            calls++
            lastArgs = { edid: edid, name: name, model: model, layout: layout, themeMode: themeM,
                         accent: accent, autostart: autostart, reconnect: reconnect, notify: notify }
            return nextResult
        }
    }

    // Catalogs (source of truth for the data-driven rows).
    App.WallpaperCatalog { id: wpc }
    App.BackgroundCatalog { id: bgc }
    App.PresetCatalog { id: presetCat }

    // A REAL BackgroundPicker in the test window, wired to the shell store at
    // runtime. Clicking its thumbnails/chips is the real interaction under test.
    property var col: ({ textPrimary: "#fff", textSecondary: "#aaa", panel: "#161B22",
        panelAlt: "#1C222B", border: "#333", accent: "#58A6FF", radius: 10 })
    W.BackgroundPicker {
        id: bpick
        x: 20; y: 20; width: 1180
        st: null; pageIndex: -1
        col: root.col; bgCatalog: bgc; wpCatalog: wpc
    }

    // ── Tree helpers ─────────────────────────────────────────────────────────
    function scopeRoot(scope) {
        try { return scope && scope.contentItem ? scope.contentItem : scope }
        catch (e) { return scope }
    }
    function findSwipe(scope) { return G.byObjName(scopeRoot(scope), "pageSwipe") }
    function findDash(scope) {
        return G.findPred(scopeRoot(scope), function (n) {
            return n && n.appendPreset !== undefined && n.netGate !== undefined })
    }
    function findStore(scope) {
        return G.findPred(scopeRoot(scope), function (n) {
            return n && n.applyExternal !== undefined && n.structureRevision !== undefined })
    }
    function findPresetPicker(win) {
        return G.findPred(win.contentItem, function (n) {
            return n && n.pendingId !== undefined && n.shown !== undefined && n.locked !== undefined })
    }
    // The PAGE backdrop, not a widget's card backdrop.
    //
    // The old predicate (style + running + sourceComponent) matches EIGHT objects
    // in a populated dashboard: the page's BackdropLayer and one per widget tile
    // (measured 2026-07-20: FocusWidget, TasksWidget, CpuWidget, GpuWidget,
    // RamWidget, ClockWidget, WeatherWidget). It returned whichever the tree walk
    // reached first, so which object the whole TestCase asserted on depended on
    // walk order - i.e. on how many tiles the page happened to have.
    //
    // The page backdrop is the one parented directly into the Dashboard rather
    // than inside a widget: the card backdrops sit under a Loader inside their
    // widget, so requiring a Dashboard-ish ancestor within one hop separates them.
    function findBackdrop(dash) {
        var cands = G.collectPred(dash, function (n) {
            try { return n && typeof n.style === "string" && n.running !== undefined
                         && n.sourceComponent !== undefined } catch (e) { return false }
        })
        for (var i = 0; i < cands.length; i++) {
            var p = cands[i].parent
            if (p && ("" + p).indexOf("Dashboard") === 0) return cands[i]
        }
        return cands.length ? cands[0] : null
    }
    function findBarButton(win, icon) {
        return G.findPred(win.contentItem, function (n) {
            try { return n && n.iconName === icon && n.clicked !== undefined } catch (e) { return false }
        })
    }
    // The wallpaper thumbnail delegate whose Image carries this source.
    function thumbFor(src) {
        var img = G.findPred(bpick, function (n) {
            try { return n && n.source !== undefined && ("" + n.source) === src
                         && n.fillMode !== undefined } catch (e) { return false }
        })
        return img ? img.parent : null
    }
    // A style chip Rectangle whose child Text is this label.
    function chipFor(label) {
        var t = G.findPred(bpick, function (n) {
            try { return n && n.text === label } catch (e) { return false }
        })
        return t ? t.parent : null
    }

    // ── Pixel diff over an interior grid (background change proof) ─────────────
    function pxDiff(a, b, steps) {
        if (!a || !b) return 0
        steps = steps || 32
        var Wm = Math.min(a.width, b.width), Hm = Math.min(a.height, b.height), n = 0
        // Sparse styles such as Starfield legitimately leave most of the
        // background untouched. A 9x9 grid can miss every star; the denser fixed
        // grid is still cheap but makes the rendered-pixel proof deterministic.
        for (var i = 1; i < steps; i++)
            for (var j = 1; j < steps; j++) {
                var x = Math.floor(Wm * i / steps), y = Math.floor(Hm * j / steps)
                if (G.colorDist("" + a.pixel(x, y), "" + b.pixel(x, y)) > 12) n++
            }
        return n
    }

    // =========================================================================
    // AREA 5 - Wallpaper / background (real shell + real BackgroundPicker)
    // =========================================================================
    TestCase {
        id: tcWall
        name: "GuiShellWallpaper"
        when: windowShown
        visible: true

        property var win: null
        property var dash: null
        property var store: null
        property var bd: null
        property var shellTheme: null

        function grabSurface() {
            // Dashboard can rotate its content inside a landscape window. Capture
            // the actual window surface at its stable origin; mapping the rotated
            // Dashboard rectangle itself can legitimately produce an offset beyond
            // the surface even though its rendered pixels fill that surface.
            return G.grabItem(this, win.contentItem, win.contentItem)
        }
        function snap(item, n) {
            var i = grabSurface()
            i.save("gui-evidence/shellbg_" + n + ".png")
            return i
        }

        function initTestCase() {
            var c = Qt.createComponent("../../ui/qml/main.qml")
            tryVerify(function () { return c.status !== Component.Loading }, 6000)
            compare(c.status, Component.Ready, "main.qml compiles: " + c.errorString())
            win = c.createObject(root)
            verify(win !== null, "shell instantiated")
            // Use `visibility`, NOT `visible`. ui/qml/main.qml:11 declares
            // `visibility: Window.Hidden` (C++ positions the window before showing
            // it). Setting `visible` alongside it yields QQC2 "Conflicting properties
            // 'visible' and 'visibility'" and the window is NEVER exposed: measured
            // 2026-07-20 this file ran with win=0x0 visibility=0, so the Dashboard,
            // its BackdropLayer and every tile were zero-sized and nothing rendered.
            // Every pixel assertion here was therefore comparing blank to blank.
            // tst_gui_shell_nav_edit and _orient_settings got this fix on 2026-07-19;
            // this file was missed.
            // The Edge is 2560x720. Without an explicit size the windowed shell
            // came up 500x500, so every tile, the BackdropLayer and the page
            // gradient rendered at a shape the product never has - and the orb
            // tint became subtle enough to fall under pxDiff's threshold, which
            // is why the wallpaper rows failed their pixel proof with diff=0.
            win.width = 2560; win.height = 720
            win.visibility = Window.Windowed
            win.orientationMode = "landscape"
            win.reduceMotion = true            // static backdrop → deterministic grabs
            win.animatedBackground = true      // so the backdrop can render at all
            var sv = G.findPred(win.contentItem, function (n) {
                return n && typeof n.push === "function" && n.currentItem !== undefined })
            verify(sv, "found StackView")
            // Exactly ONE Dashboard on the stack. This used to be guaranteed by a BUG:
            // main.qml's initialItem was "qrc:/qml/Dashboard.qml", which cannot resolve
            // under qmltestrunner, so the stack was empty and this push produced the only
            // instance. Now that initialItem resolves from the source tree, pushing
            // without clearing leaves TWO stacked Dashboards - the test then drives the
            // one underneath, so every "is it hidden?" assertion passes and every click
            // silently lands on the wrong instance.
            sv.clear(StackView.Immediate)
            sv.push(Qt.resolvedUrl("../../ui/qml/Dashboard.qml"))
            tryVerify(function () { return sv.depth === 1 && sv.currentItem !== null }, 5000,
                      "exactly one current Dashboard page")
            tryVerify(function () {
                dash = sv.currentItem; store = root.findStore(dash)
                return dash !== null && store !== null
            }, 6000, "Dashboard + store loaded")
            // Dashboard.applyAppearance() restores the persisted orientation as
            // it loads, so the pre-push assignment above is intentionally
            // repeated after creation. Otherwise the shipped portrait default
            // rotates this landscape test surface and every item-relative pixel
            // sample lands outside the grabbed frame.
            win.orientationMode = "landscape"
            wait(100)
            bd = root.findBackdrop(dash)
            verify(bd !== null, "found the BackdropLayer")
            // `st`, not `store`: c02c40f renamed BackgroundPicker's store property
            // to escape the QML self-binding trap (`store: store` resolving to the
            // component's own undefined property). The DECLARATION above was
            // updated then; this runtime assignment was missed, so every test in
            // this TestCase died in initTestCase on "Cannot assign to non-existent
            // property". tests/ui was fixed in a3f94ca; tests/gui was not.
            shellTheme = G.findPred(win.contentItem, function (n) {
                try { return n && n.themeCatalog !== undefined
                             && typeof n.applyTheme === "function" } catch (e) { return false } })
            verify(shellTheme !== null, "found the SHELL's Theme (not this file's)")
            bpick.st = store                   // wire the picker to the shell store
        }
        function cleanupTestCase() { if (win) win.destroy() }

        // Reset the SHARED picker before every test. This TestCase had no init()
        // and paid for it: several tests set `bpick.pageIndex = 1` and restore it
        // to -1 on their LAST line, so a test that fails part-way never restores
        // it. `BackgroundPicker.pickStyle()` branches on exactly that property -
        // pageIndex < 0 writes the GLOBAL appearance, >= 0 writes a per-page
        // override - so one failure silently redirected every later write to
        // page 1's background.
        //
        // Measured 2026-07-20: test_perpage_style_overrides_global fails and
        // leaks pageIndex=1; QtTest runs alphabetically, so the 6 rows of
        // test_style_changes_backdrop and the 18 of
        // test_wallpaper_changes_background all then asserted a global key that
        // nothing was writing. 24 of this file's 39 failures were that cascade,
        // not 24 defects. Per-test isolation is not tidiness here; without it the
        // failure count is meaningless.
        // A PER-PAGE background override also leaks, and it OUTRANKS the global
        // style - EdgeClone/Dashboard read `page.bg` first and only fall back to
        // appearance.bgStyle. So after test_perpage_style_overrides_global left
        // page 0 pinned to "waves", every later test could set the global style
        // successfully and still render "waves": the store assertion passed and
        // the BackdropLayer assertion failed, which reads exactly like a product
        // bug in the style→backdrop binding. It is not; it is stale test state.
        // THE THEME LEAK - this is what made Group B unsolvable for three rounds.
        //
        // `BackdropLayer.visible` (Dashboard.qml:165) requires theme.decorative,
        // and `high_contrast` is deliberately NOT decorative. test_highcontrast_*
        // sets it and never restores it; QtTest runs alphabetically, so
        // "highcontrast" lands before "wallpaper" and all 18 rows of
        // test_wallpaper_changes_background then failed their
        // `verify(bd.visible)` precondition with the backdrop correctly hidden.
        //
        // Every earlier hypothesis (animatedBg not applied, the store→root sync,
        // findBackdrop returning the wrong object) was chasing the two terms that
        // were already true. The reason nobody caught the third: this file has a
        // Theme of its own for the wizard, so instrumenting `_theme.decorative`
        // reads the TEST's theme and reports true, while the binding reads the
        // SHELL's theme. Assert against the object the product actually binds to.
        function init() {
            bpick.pageIndex = -1
            // Drive the SHELL's Theme directly. Setting win.themeMode does NOT
            // reach it: the store->root->theme sync only runs inside
            // applyAppearance() at load (see baselineBackdrop below), so the
            // window property changed while theme.decorative stayed false and
            // the backdrop stayed correctly hidden.
            win.themeMode = "midnight"
            store.setAppearance("themeMode", "midnight")
            if (shellTheme) shellTheme.applyTheme("midnight")
            for (var i = 0; i < store.pageCount(); i++) {
                store.setPageBackground(i, "style", "")
                store.setPageBackground(i, "wallpaper", "")
            }
        }

        // Return the page to a KNOWN animated-backdrop baseline (orbs, no wallpaper).
        function baselineBackdrop() {
            store.setAppearance("wallpaper", "")
            store.setAppearance("bgStyle", "orbs")
            // Re-assert animatedBackground HERE, after the Dashboard has loaded.
            // initTestCase sets it before sv.push(), and applyAppearance()
            // (ui/qml/Dashboard.qml:530) then writes the persisted `animatedBg`
            // straight back over it - the shipped default is false (calm by
            // default), so the precondition was silently reverted on every load.
            //
            // It has to be the WINDOW property, not store.setAppearance(): the
            // store->root direction only runs inside applyAppearance() at load
            // time, while the Connections block at Dashboard.qml:536-546 is
            // root->store only. Writing the store key alone therefore never
            // reaches dashboard.animatedBg, which is what BackdropLayer binds to.
            // Setting the root property is also what the SettingsPanel switch does.
            win.animatedBackground = true
            bpick.pageIndex = -1
            wait(200)
            verify(bd.visible, "baseline: the animated backdrop is showing")
        }

        // ── 5a. Each of the 18 wallpapers changes the page background ──────────
        function test_wallpaper_changes_background_data() {
            var rows = []
            for (var i = 0; i < wpc.items.length; i++)
                rows.push({ tag: wpc.items[i].name, source: wpc.items[i].source })
            return rows
        }
        function test_wallpaper_changes_background(d) {
            baselineBackdrop()
            var before = snap(dash, "before_" + d.tag)
            // REAL click on the wallpaper's thumbnail in the picker.
            var thumb = root.thumbFor(d.source)
            verify(thumb !== null, "thumbnail present for " + d.tag)
            mouseClick(thumb, thumb.width / 2, thumb.height / 2)
            wait(200)
            // Store fact: the wallpaper is selected.
            compare(store.appearance().wallpaper, d.source, "store records wallpaper " + d.tag)
            // GUI-observable: the resolved source fed to the page + backdrop suppressed.
            compare("" + dash.wallpaperSource, d.source, "dashboard wallpaperSource resolves")
            verify(!bd.visible, "the animated backdrop is suppressed by the wallpaper")
            // Pixel proof: the empty-page background visibly changed.
            var after = snap(dash, "after_" + d.tag)
            verify(root.pxDiff(before, after) >= 1,
                   "background pixels changed selecting " + d.tag + " (diff="
                   + root.pxDiff(before, after) + ")")
        }

        // ── 5b. Animated styles change the backdrop ───────────────────────────
        function test_style_changes_backdrop_data() {
            return [ { tag: "none", label: "Gradient", v: "none", animated: false },
                     { tag: "orbs", label: "Aurora Orbs", v: "orbs", animated: true },
                     { tag: "waves", label: "Waves", v: "waves", animated: true },
                     { tag: "stars", label: "Starfield", v: "stars", animated: true },
                     { tag: "grid", label: "Neon Grid", v: "grid", animated: true },
                     { tag: "arch", label: "Arch Peaks", v: "arch", animated: true } ]
        }
        function test_style_changes_backdrop(d) {
            // Clear any wallpaper first so a style can take effect, then set a
            // known DIFFERENT baseline to measure the change against.
            store.setAppearance("wallpaper", "")
            store.setAppearance("bgStyle", d.animated ? "none" : "orbs")
            wait(200)
            var before = grabSurface()
            var chip = root.chipFor(d.label)
            verify(chip !== null, "style chip present: " + d.label)
            mouseClick(chip, chip.width / 2, chip.height / 2)
            wait(200)
            compare(store.appearance().bgStyle, d.v, "store records style " + d.tag)
            compare("" + bd.style, d.v, "BackdropLayer.style === " + d.tag)
            var after = snap(dash, "style_" + d.tag)
            // Starfield's motif is deliberately sparse (small points over the
            // unchanged gradient), so sample it more densely than broad styles.
            verify(root.pxDiff(before, after, d.v === "stars" ? 128 : 32) >= 1,
                   "backdrop pixels changed for style " + d.tag)
        }

        // ── 5c. Wallpaper vs style mutual exclusivity ─────────────────────────
        function test_style_then_wallpaper_suppresses_backdrop() {
            store.setAppearance("wallpaper", ""); store.setAppearance("bgStyle", "orbs")
            wait(150); verify(bd.visible, "orbs backdrop up")
            var thumb = root.thumbFor("qrc:/wallpapers/ocean.png")
            mouseClick(thumb, thumb.width / 2, thumb.height / 2); wait(150)
            compare(store.appearance().wallpaper, "qrc:/wallpapers/ocean.png")
            verify(!bd.visible, "picking a wallpaper hides the animated backdrop")
        }
        function test_wallpaper_then_style_restores_backdrop() {
            store.setAppearance("wallpaper", "qrc:/wallpapers/ocean.png"); wait(150)
            verify(!bd.visible, "wallpaper set → backdrop hidden")
            var chip = root.chipFor("Waves")
            mouseClick(chip, chip.width / 2, chip.height / 2); wait(150)
            compare(store.appearance().wallpaper, "", "picking a style clears the wallpaper")
            verify(bd.visible, "the animated backdrop returns")
        }
        function test_wallpaper_selected_shows_check_badge() {
            store.setAppearance("wallpaper", ""); store.setAppearance("bgStyle", "orbs"); wait(120)
            var thumb = root.thumbFor("qrc:/wallpapers/teal.png")
            mouseClick(thumb, thumb.width / 2, thumb.height / 2); wait(150)
            verify(thumb.sel === true, "the selected thumbnail reports sel")
            // The check badge Rectangle is the delegate child that is visible only when sel.
            var badge = G.byObjName(thumb, "wallpaperCheckBadge")
            verify(badge !== null && badge.visible, "the check badge is shown on the selection")
        }
        function test_style_chip_selected_state() {
            store.setAppearance("wallpaper", ""); wait(80)
            var chip = root.chipFor("Starfield")
            mouseClick(chip, chip.width / 2, chip.height / 2); wait(120)
            verify(chip.sel === true, "the chosen style chip reports sel")
        }

        // ── 5d. Per-page vs global scope ──────────────────────────────────────
        function test_perpage_style_overrides_global() {
            store.load("blank"); store.addPage("")
            store.setAppearance("wallpaper", ""); store.setAppearance("bgStyle", "orbs")
            var sw = root.findSwipe(win)
            sw.goToPage(1); tryVerify(function () { return sw.currentIndex === 1 }, 3000)
            bpick.pageIndex = 1
            var g0
            sw.goToPage(0); tryVerify(function () { return sw.currentIndex === 0 }, 3000); wait(150)
            g0 = grabSurface()
            var chip = root.chipFor("Waves")   // per-page override on page 1
            bpick.pageIndex = 1
            // apply the override via the per-page picker method (page 1) then verify store
            bpick.pickStyle("waves")
            wait(120)
            compare(store.pageBackground(1).style, "waves", "page 1 has its own style")
            sw.goToPage(1); tryVerify(function () { return sw.currentIndex === 1 }, 3000); wait(150)
            var g1 = snap(dash, "perpage_page1_waves")
            verify(root.pxDiff(g0, g1) >= 1, "page 1 renders a different backdrop than page 0")
            bpick.pageIndex = -1
        }
        function test_other_pages_keep_global() {
            // After the previous case page 0 still inherits the global orbs.
            compare(store.pageBackground(0).style, undefined, "page 0 has no per-page style override")
            compare(store.appearance().bgStyle, "orbs", "global style is still orbs")
        }
        function test_use_global_clears_override() {
            store.load("blank"); store.addPage("")
            bpick.pageIndex = 1
            bpick.pickStyle("stars")
            compare(store.pageBackground(1).style, "stars")
            bpick.useGlobal()
            wait(80)
            verify(!store.pageBackground(1).style && !store.pageBackground(1).wallpaper,
                   "Use global dropped the per-page override")
            bpick.pageIndex = -1
        }
        function test_global_chip_only_for_pages() {
            bpick.pageIndex = -1; wait(60)
            var gGlobal = G.findPred(bpick, function (n) {
                try { return n && n.text === "Use global" } catch (e) { return false } })
            // For the global picker the "Use global" chip is collapsed (visible false).
            verify(gGlobal === null || !gGlobal.parent.visible, "no Use-global chip in the global picker")
            bpick.pageIndex = 1; wait(60)
            gGlobal = G.findPred(bpick, function (n) {
                try { return n && n.text === "Use global" } catch (e) { return false } })
            verify(gGlobal !== null && gGlobal.parent.visible, "Use-global chip present for a page")
            bpick.pageIndex = -1
        }
        function test_fresh_page_selGlobal() {
            store.load("blank"); store.addPage("")
            bpick.pageIndex = 1; wait(60)
            verify(bpick.selGlobal(), "a fresh page inherits the global default")
            bpick.pageIndex = -1
        }
        function test_switching_page_updates_background() {
            store.load("blank"); store.addPage("")
            store.setAppearance("bgStyle", "orbs"); store.setAppearance("wallpaper", "")
            store.setPageBackground(1, "style", "grid")
            var sw = root.findSwipe(win)
            sw.goToPage(0); tryVerify(function () { return sw.currentIndex === 0 }, 3000); wait(150)
            var g0 = grabSurface()
            sw.goToPage(1); tryVerify(function () { return sw.currentIndex === 1 }, 3000); wait(150)
            var g1 = snap(dash, "switch_page1_grid")
            verify(root.pxDiff(g0, g1) >= 1, "the background follows the current page")
        }

        // ── 5e. High-contrast suppresses the decorative backdrop ──────────────
        function test_highcontrast_suppresses_backdrop() {
            store.load("blank")
            store.setAppearance("wallpaper", ""); store.setAppearance("bgStyle", "orbs")
            wait(120); verify(bd.visible, "decorative theme shows the backdrop")
            store.setAppearance("themeMode", "high_contrast"); dash.applyAppearance()
            wait(150)
            verify(!theme.decorative || !bd.visible, "high-contrast hides the decorative backdrop")
            verify(!bd.visible, "backdrop suppressed under high-contrast")
        }
        // QuickTest runs a TestCase's functions in ALPHABETICAL order, so this
        // one runs BEFORE test_highcontrast_suppresses_backdrop, not after it.
        // The high-contrast grab therefore never captured a high-contrast
        // dashboard at all - it captured whatever the previous test happened to
        // leave on screen, and the comparison below was between two frames of
        // the SAME decorative theme. It passed locally only because the
        // animated backdrop had moved between the two grabs, and it failed on
        // CI when it had not. Enter high-contrast here instead of inheriting a
        // neighbour's state, and wait for the backdrop to actually respond
        // rather than for a fixed 150 ms.
        function test_highcontrast_plain_gradient_grab() {
            store.load("blank")
            store.setAppearance("wallpaper", ""); store.setAppearance("bgStyle", "orbs")
            store.setAppearance("themeMode", "high_contrast"); dash.applyAppearance()
            tryVerify(function () { return !bd.visible }, 3000,
                      "high-contrast suppressed the decorative backdrop")
            var hc = snap(dash, "highcontrast")
            // restore a normal theme for cleanliness
            store.setAppearance("themeMode", "midnight"); dash.applyAppearance()
            tryVerify(function () { return bd.visible }, 3000,
                      "midnight restored the decorative backdrop")
            var normal = grabSurface()
            verify(root.pxDiff(hc, normal) >= 1, "the themed background differs from high-contrast")
        }
    }

    // =========================================================================
    // AREA 6 - Presets: append each screen as a NEW page
    // =========================================================================
    TestCase {
        id: tcPre
        name: "GuiShellPresets"
        when: windowShown
        visible: true

        property var win: null
        property var dash: null
        property var store: null
        property var swipe: null
        property var sv: null

        function snap(item, n) { var i = G.grabItem(this, item, win.contentItem); i.save("gui-evidence/shellpreset_" + n + ".png"); return i }

        function initTestCase() {
            var c = Qt.createComponent("../../ui/qml/main.qml")
            tryVerify(function () { return c.status !== Component.Loading }, 6000)
            compare(c.status, Component.Ready, "main.qml compiles: " + c.errorString())
            win = c.createObject(root)
            verify(win !== null, "shell instantiated")
            // Use `visibility`, NOT `visible`. ui/qml/main.qml:11 declares
            // `visibility: Window.Hidden` (C++ positions the window before showing
            // it). Setting `visible` alongside it yields QQC2 "Conflicting properties
            // 'visible' and 'visibility'" and the window is NEVER exposed: measured
            // 2026-07-20 this file ran with win=0x0 visibility=0, so the Dashboard,
            // its BackdropLayer and every tile were zero-sized and nothing rendered.
            // Every pixel assertion here was therefore comparing blank to blank.
            // tst_gui_shell_nav_edit and _orient_settings got this fix on 2026-07-19;
            // this file was missed.
            // The Edge is 2560x720. Without an explicit size the windowed shell
            // came up 500x500, so every tile, the BackdropLayer and the page
            // gradient rendered at a shape the product never has - and the orb
            // tint became subtle enough to fall under pxDiff's threshold, which
            // is why the wallpaper rows failed their pixel proof with diff=0.
            win.width = 2560; win.height = 720
            win.visibility = Window.Windowed
            win.orientationMode = "portrait"
            sv = G.findPred(win.contentItem, function (n) {
                return n && typeof n.push === "function" && n.currentItem !== undefined })
            sv.clear(StackView.Immediate)
            sv.push(Qt.resolvedUrl("../../ui/qml/Dashboard.qml"))
            tryVerify(function () { return sv.depth === 1 && sv.currentItem !== null }, 5000,
                      "exactly one current Dashboard page")
            tryVerify(function () {
                dash = sv.currentItem; store = root.findStore(dash); swipe = root.findSwipe(dash)
                return dash !== null && store !== null && swipe !== null
            }, 6000, "Dashboard + store + SwipeView loaded")
        }
        function cleanupTestCase() { if (win) win.destroy() }

        // ── 6a. Each preset appends + lands + STAYS on the new page ────────────
        function test_append_preset_lands_and_stays_data() {
            var rows = []
            var l = presetCat.list()
            for (var i = 0; i < l.length; i++) rows.push({ tag: l[i].id, id: l[i].id })
            return rows
        }
        function test_append_preset_lands_and_stays(d) {
            store.load("blank")
            tryVerify(function () { return swipe.count === store.pageCount() }, 3000)
            var count = store.pageCount()          // 1 (blank)
            verify(dash.appendPreset(d.id), "appended preset " + d.tag)
            compare(store.pageCount(), count + 1, "page count grew by one")
            tryVerify(function () { return swipe.currentIndex === count }, 4000,
                      "landed on the new page for " + d.tag)
            wait(900)                              // outlast the deferred relayout (snap-back)
            compare(swipe.currentIndex, count, "STAYED on the appended screen for " + d.tag)
            // Enterprise and Remote Work contain End of Day. Without using its
            // existing test clock seam, the reviewed image changes between
            // "Starts later", active progress, and "Complete" according to the
            // developer's wall clock. Pin it after the configured workday so a
            // midnight audit compares the same UI state as an evening audit.
            var eods = G.collectPred(dash, function (n) {
                try {
                    return n && n.nowOverride !== undefined
                           && n.startHour !== undefined && n.endHour !== undefined
                           && typeof n.windowBounds === "function"
                } catch (e) { return false }
            })
            var expectedEods = d.id === "enterprise" || d.id === "remote-work" ? 1 : 0
            compare(eods.length, expectedEods,
                    "found every End of Day clock seam for " + d.tag)
            for (var i = 0; i < eods.length; i++)
                eods[i].nowOverride = new Date(2026, 6, 20, 18, 0, 0, 0)
            // Ambient and Minimal contain Moon widgets whose live phase changes
            // every day. Pin the existing widget test seam before taking a
            // reviewed image so the baseline measures layout and rendering,
            // not the wall-clock date on the machine running the suite.
            var moons = G.collectPred(dash, function (n) {
                try {
                    return n && n._cyclePos !== undefined
                           && n.illum !== undefined && n.names !== undefined
                } catch (e) { return false }
            })
            var expectedMoons = d.id === "ambient" || d.id === "minimal" ? 1 : 0
            compare(moons.length, expectedMoons,
                    "found every Moon phase seam for " + d.tag)
            for (var m = 0; m < moons.length; m++)
                moons[m]._cyclePos = 0.35
            // Break reminders are clock-dependent twice over: `remaining` counts
            // down from Date.now(), and stateLabel flips to "Outside active
            // hours" whenever the run happens outside the 09:00-17:00 schedule.
            // That is why preset-health's reviewed baseline failed at exactly
            // rms=10.031 on two CI runs in the same time band while passing in
            // another - a break tile rendering "30:00 / Paused" in one band and a
            // live countdown or "off hours" in the next. Park the reminder: with
            // running=false, `remaining` reads the fixed pausedRemaining instead
            // of the wall clock, and stateLabel resolves to "Paused" before it
            // ever consults the schedule. Same intent as the EOD and Moon seams
            // above - pin the clock so the baseline measures layout, not the hour
            // the suite happened to run.
            var breaks = G.collectPred(dash, function (n) {
                try {
                    return n && n.stateLabel !== undefined && n.intervalMin !== undefined
                           && n.snoozed !== undefined && n.instanceId !== undefined
                } catch (e) { return false }
            })
            for (var b = 0; b < breaks.length; b++)
                if (breaks[b].store)
                    breaks[b].store.patchSettings(breaks[b].instanceId,
                        { running: false, due: false, snoozed: false,
                          scheduleSuspended: false, pausedRemaining: 1800 })
            if (eods.length || moons.length || breaks.length) wait(60)
            snap(dash, "append_" + d.tag)
        }

        // ── 6b. Global appearance untouched by an append ──────────────────────
        function test_append_keeps_thememode() {
            store.load("blank"); store.setAppearance("themeMode", "midnight")
            dash.appendPreset("gaming")
            compare(store.appearance().themeMode, "midnight", "themeMode survives an append")
        }
        function test_append_keeps_accent() {
            store.load("blank"); win.accentName = "green"; wait(60)
            dash.appendPreset("system-monitor")
            compare(win.accentName, "green", "accent survives an append")
        }
        function test_append_keeps_glass() {
            store.load("blank"); win.glassOpacity = 0.2; wait(60)
            dash.appendPreset("creator")
            fuzzyCompare(win.glassOpacity, 0.2, 0.001, "glass survives an append")
        }
        function test_append_keeps_reducemotion() {
            store.load("blank"); win.reduceMotion = true; wait(60)
            dash.appendPreset("ambient")
            compare(win.reduceMotion, true, "reduce-motion survives an append")
            win.reduceMotion = false
        }
        function test_append_keeps_orientation() {
            store.load("blank"); win.orientationMode = "landscape"
            compare(win.contentRotation, 90)
            dash.appendPreset("developer")
            compare(win.orientationMode, "landscape", "orientation survives an append")
            win.orientationMode = "portrait"
        }
        function test_append_keeps_other_pages() {
            store.load("blank")
            dash.appendPreset("gaming")
            var p0 = JSON.stringify(store.pages()[0])
            var p1 = JSON.stringify(store.pages()[1])
            dash.appendPreset("system-monitor")
            compare(JSON.stringify(store.pages()[0]), p0, "page 0 untouched by a second append")
            compare(JSON.stringify(store.pages()[1]), p1, "page 1 untouched by a second append")
        }

        // ── 6c. Append mechanics ──────────────────────────────────────────────
        function test_append_twice_unique_ids() {
            store.load("blank")
            dash.appendPreset("gaming"); dash.appendPreset("gaming")
            var seen = ({}), pages = store.pages(), dup = false
            for (var p = 0; p < pages.length; p++) {
                var ts = pages[p].tiles || []
                for (var t = 0; t < ts.length; t++) {
                    if (seen[ts[t].id]) dup = true
                    seen[ts[t].id] = true
                }
            }
            verify(!dup, "appending the same preset twice re-keys tile ids (no collision)")
        }
        function test_append_merges_tile_settings() {
            store.load("blank")
            dash.appendPreset("developer")
            var page = store.pages()[1], hj = null
            for (var t = 0; t < page.tiles.length; t++)
                if (page.tiles[t].type === "httpjson") hj = page.tiles[t].id
            verify(hj !== null, "developer preset carries an httpjson tile")
            compare(store.settingsFor(hj).title, "CI status", "the preset's per-tile settings merged")
        }
        function test_append_carries_perpage_bg() {
            store.load("blank")
            dash.appendPreset("gaming")     // _tech character → bgStyle grid
            compare(store.pageBackground(1).style, "grid",
                    "the preset's character rides as a per-page background")
        }
        function test_append_dedup_page_name() {
            store.load("blank")
            dash.appendPreset("system-monitor")     // "Core"
            dash.appendPreset("system-monitor")     // "Core 2"
            var pages = store.pages()
            compare(pages[pages.length - 1].name, "Core 2", "the duplicate page name is de-duplicated")
        }
        function test_append_unknown_refused() {
            store.load("blank")
            var count = store.pageCount()
            compare(dash.appendPreset("does-not-exist"), false, "unknown preset id is refused")
            compare(store.pageCount(), count, "page count unchanged after a refused append")
        }
        function test_append_landscape_lands_and_stays() {
            store.load("blank"); win.orientationMode = "landscape"
            compare(win.contentRotation, 90)
            var count = store.pageCount()
            verify(dash.appendPreset("home-ambient"))
            tryVerify(function () { return swipe.currentIndex === count }, 4000)
            wait(900)
            compare(swipe.currentIndex, count, "landscape append lands+stays")
            snap(dash, "append_landscape")
            win.orientationMode = "portrait"
        }

        // ── 6d. PresetPicker surface - REAL clicks ────────────────────────────
        // Cards live in a clipped Flickable; bring a target into view before clicking.
        function clickCard(pp, name) {
            var target = G.byObjName(pp, name)
            verify(target !== null, "card present: " + name)
            var scroll = G.byObjName(pp, "presetListScroll")
            if (scroll) {
                var p = target.mapToItem(scroll.contentItem, 0, 0)
                var maxY = Math.max(0, scroll.contentHeight - scroll.height)
                scroll.contentY = Math.max(0, Math.min(maxY, p.y - 40))
                wait(150)
            }
            var id = name.slice("presetCard-".length)
            var tap = G.byObjName(target, "presetCardTap-" + id)
            verify(tap !== null && G.isLive(tap), "card tap target is live: " + id)
            // Dispatch through the stable viewport after scrolling. Qt 6.11 can
            // otherwise retain the delegate's pre-scroll scene coordinate and
            // send the synthetic click outside the clipped list.
            var hit = tap.mapToItem(scroll, tap.width / 2, tap.height / 2)
            verify(hit.x >= 0 && hit.x <= scroll.width
                   && hit.y >= 0 && hit.y <= scroll.height,
                   "card centre is inside the visible preset viewport: " + id)
            mouseClick(scroll, hit.x, hit.y)
            tryCompare(pp, "pendingId", id, 2000)
        }

        function test_picker_opens_and_lists_all_presets() {
            store.load("blank")
            var pp = root.findPresetPicker(win)
            verify(pp !== null, "found the PresetPicker")
            pp.shown = true
            tryVerify(function () { return pp.opacity > 0.99 }, 2000, "picker faded in")
            var n = G.collectPred(pp, function (x) {
                return x && x.objectName !== undefined && ("" + x.objectName).indexOf("presetCard-") === 0 }).length
            compare(n, presetCat.items.length + 1, "one card per preset + the blank slate")
            pp.shown = false
        }
        function test_picker_tap_arms_confirm() {
            store.load("blank")
            var pp = root.findPresetPicker(win)
            pp.pendingId = ""; pp.shown = true
            tryVerify(function () { return pp.opacity > 0.99 }, 2000)
            clickCard(pp, "presetCard-gaming")
            compare(pp.pendingId, "gaming", "tapping a card arms it")
            var bar = G.byObjName(pp, "presetConfirmBar")
            verify(bar !== null && bar.visible, "the confirm bar appears")
            pp.shown = false
        }
        function test_picker_confirm_appends_and_closes() {
            store.load("blank")
            var count = store.pageCount()
            var pp = root.findPresetPicker(win)
            pp.pendingId = ""; pp.shown = true
            tryVerify(function () { return pp.opacity > 0.99 }, 2000)
            clickCard(pp, "presetCard-developer")
            tryVerify(function () {
                var a = G.byObjName(pp, "presetConfirmApply"); return a && a.visible && a.height > 0
            }, 2000, "confirm bar laid out")
            mouseClick(G.byObjName(pp, "presetConfirmApply"))
            tryVerify(function () { return store.pageCount() === count + 1 }, 3000,
                      "confirming appends the screen")
            tryVerify(function () { return !pp.shown }, 2000, "the picker closes after applying")
            snap(dash, "picker_appended")
        }
        function test_picker_cancel_disarms() {
            store.load("blank")
            var pp = root.findPresetPicker(win)
            pp.pendingId = ""; pp.shown = true
            tryVerify(function () { return pp.opacity > 0.99 }, 2000)
            clickCard(pp, "presetCard-health")
            tryVerify(function () {
                var cc = G.byObjName(pp, "presetConfirmCancel"); return cc && cc.visible && cc.height > 0
            }, 2000)
            mouseClick(G.byObjName(pp, "presetConfirmCancel"))
            compare(pp.pendingId, "", "Cancel disarms the selection")
            pp.shown = false
        }
        function test_picker_close_button_closes() {
            var pp = root.findPresetPicker(win)
            pp.shown = true
            tryVerify(function () { return pp.opacity > 0.99 }, 2000)
            mouseClick(G.byObjName(pp, "presetPickerClose"))
            tryVerify(function () { return !pp.shown }, 2000, "the close button dismisses the picker")
        }
    }

    // =========================================================================
    // AREA 7 - FirstRunWizard (hosted directly, real clicks)
    // =========================================================================
    TestCase {
        id: tcWiz
        name: "GuiShellWizard"
        when: windowShown
        visible: true

        property var wiz: null
        property var flick: null

        // This TestCase hosts the wizard directly on `root`, not in its own
        // Window - so `root` is the origin item the grab must be relative to.
        function snap(item, n) { var i = G.grabItem(this, item, root); i.save("gui-evidence/shellwiz_" + n + ".png"); return i }

        function findButton(str) {
            return G.findPred(wiz, function (n) {
                try { return n && n.text === str && n.checkable !== undefined } catch (e) { return false } })
        }

        function clickableForText(str) {
            var textItem = G.byText(wiz, str)
            if (!textItem) return null
            var node = textItem.parent
            while (node && node !== wiz) {
                var kids = node.children || []
                for (var i = 0; i < kids.length; i++)
                    if (G.isClickable(kids[i]) && kids[i].width > 0 && kids[i].height > 0)
                        return kids[i]
                node = node.parent
            }
            return null
        }

        function reveal(item) {
            verify(item !== null, "click target exists")
            var p = item.mapToItem(flick.contentItem, 0, 0)
            var centred = p.y + item.height / 2 - flick.height / 2
            flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, centred))
            wait(80)
        }

        function tap(item) {
            reveal(item)
            mouseClick(item, item.width / 2, item.height / 2)
        }

        function initTestCase() {
            var c = Qt.createComponent("../../ui/qml/FirstRunWizard.qml")
            tryVerify(function () { return c.status !== Component.Loading }, 6000)
            compare(c.status, Component.Ready, "FirstRunWizard compiles: " + c.errorString())
            wiz = c.createObject(root)
            verify(wiz !== null, "wizard instantiated")
            // FirstRunWizard is a StackView PAGE in the product, so it no longer
            // anchors itself (that conflicted with StackView's own sizing). This
            // direct host must size it explicitly, and it must use the host's
            // dimensions: a 2560-wide child inside this 1280-wide QuickTest
            // window puts the right-hand controls outside the input surface.
            wiz.width = root.width; wiz.height = root.height
            flick = G.findPred(wiz, function (n) {
                return n && n.contentY !== undefined && n.contentHeight !== undefined
                       && n.flickableDirection !== undefined
            })
            verify(flick !== null, "wizard Flickable found")
        }
        function cleanupTestCase() { if (wiz) wiz.destroy() }

        function init() {
            wiz.currentStep = 0
            wiz.selectedScreen = null
            wiz.selectedLayout = "starter"
            wiz.finishError = ""
            root._screens = "[]"
            root.themeMode = "midnight"; root.accentName = "blue"
            wizardBridge.calls = 0
            wizardBridge.nextResult = true
            if (flick) flick.contentY = 0
        }

        // ── 7a. Step advance / back ───────────────────────────────────────────
        function test_welcome_shows_get_started() {
            var b = findButton("Get Started →")
            verify(b !== null && b.visible, "step 0 shows Get Started")
            snap(wiz, "welcome")
        }
        function test_get_started_advances() {
            tap(findButton("Get Started →"))
            compare(wiz.currentStep, 1, "Get Started advances to step 1")
        }
        function test_step1_to_2_with_display() {
            root._screens = JSON.stringify([ { name: "DP-1", model: "Generic",
                size: { width: 1920, height: 1080 } } ])
            wiz.currentStep = 1; wait(80)
            tap(findButton("Select")); wait(60)
            verify(wiz.selectedScreen !== null, "a display is picked")
            tap(findButton("Next →"))
            compare(wiz.currentStep, 2, "advances to the layout step")
        }
        function test_step2_to_3() {
            wiz.currentStep = 2; wait(60)
            tap(findButton("Next →"))
            compare(wiz.currentStep, 3, "advances to the options step")
        }
        function test_back_decrements() {
            wiz.currentStep = 2; wait(40)
            tap(findButton("← Back"))
            compare(wiz.currentStep, 1, "Back returns to the previous step")
        }
        function test_back_hidden_on_step0() {
            wiz.currentStep = 0; wait(40)
            var b = findButton("← Back")
            verify(b === null || !b.visible, "Back is hidden on the welcome step")
        }
        function test_last_step_shows_finish_not_next() {
            wiz.currentStep = 3; wait(40)
            verify(findButton("Finish Setup") !== null, "last step shows Finish Setup")
            verify(findButton("Next →") === null, "no Next on the last step")
        }
        function test_prelast_shows_next_not_finish() {
            wiz.currentStep = 2; wait(40)
            verify(findButton("Next →") !== null, "step 2 shows Next")
            verify(findButton("Finish Setup") === null, "no Finish before the last step")
        }

        // ── 7b. Step indicators ───────────────────────────────────────────────
        function test_four_step_dots() {
            var rep = G.findPred(wiz, function (n) {
                return n && typeof n.itemAt === "function" && n.count === 4 && n.model === 4 })
            verify(rep !== null, "four step-indicator dots")
            compare(rep.count, 4)
        }
        function test_active_dot_reflects_step() {
            wiz.currentStep = 2; wait(60)
            var dots = G.collectPred(wiz, function (n) {
                return n && n.width === 10 && n.height === 10 && n.radius === 5 })
            compare(dots.length, 4, "collected the four dots")
            verify(Qt.colorEqual(dots[2].color, theme.accent), "the active (index 2) dot is accent-coloured")
            verify(!Qt.colorEqual(dots[0].color, theme.accent), "an inactive dot is not accent")
        }

        // ── 7c. Display-selection required-field guard ────────────────────────
        function test_cannot_advance_without_display() {
            root._screens = JSON.stringify([ { name: "DP-1", model: "Generic",
                size: { width: 1920, height: 1080 } } ])
            wiz.currentStep = 1; wiz.selectedScreen = null; wait(60)
            compare(wiz.canAdvance, false, "cannot advance without a display")
            var next = findButton("Next →")
            verify(next !== null && !next.enabled, "Next is disabled until a display is picked")
        }
        function test_selecting_display_enables_next() {
            root._screens = JSON.stringify([ { name: "DP-1", model: "Generic",
                size: { width: 1920, height: 1080 } } ])
            wiz.currentStep = 1; wait(80)
            tap(findButton("Select")); wait(60)
            verify(wiz.selectedScreen !== null, "Select picks the display")
            compare(wiz.canAdvance, true, "Next becomes enabled")
        }
        function test_selected_row_highlights() {
            root._screens = JSON.stringify([ { name: "DP-1", model: "Generic",
                size: { width: 1920, height: 1080 } } ])
            wiz.currentStep = 1; wait(80)
            tap(findButton("Select")); wait(60)
            verify(findButton("✓ Selected") !== null, "the selected row's button reads ✓ Selected")
        }
        function test_detected_edge_highlighted() {
            root._screens = JSON.stringify([ { name: "DP-3", model: "XENEON EDGE",
                manufacturer: "Corsair", likelyXeneonEdge: true,
                size: { width: 720, height: 2560 } } ])
            wiz.currentStep = 1; wait(80)
            var badge = G.byText(wiz, "Detected")
            verify(badge !== null && badge.visible, "the detected Xeneon Edge shows a Detected badge")
        }

        // ── 7d. Skip path (no displays) ───────────────────────────────────────
        function test_no_displays_can_continue() {
            root._screens = "[]"
            wiz.currentStep = 1; wiz.selectedScreen = null; wait(60)
            compare(wiz.canAdvance, true, "no displays → the user can still continue")
            verify(G.byText(wiz, "No displays detected") !== null, "the no-displays notice is shown")
        }
        function test_no_displays_next_enabled() {
            root._screens = "[]"
            wiz.currentStep = 1; wait(60)
            var next = findButton("Next →")
            verify(next !== null && next.enabled, "Next is enabled with no displays")
        }

        // ── 7e. Layout choice + finish ────────────────────────────────────────
        function test_recommended_starter_default() {
            wiz.currentStep = 2; wait(60)
            compare(wiz.selectedLayout, "starter", "the recommended starter is selected by default")
            verify(G.byText(wiz, "Recommended starter") !== null, "the recommended card is shown")
        }
        function test_pick_single_screen_layout() {
            wiz.currentStep = 2; wait(80)
            var card = G.byText(wiz, "Gaming Cockpit")
            verify(card !== null, "a preset card is present")
            tap(clickableForText("Gaming Cockpit")); wait(60)
            compare(wiz.selectedLayout, "gaming", "picking a preset card selects it")
        }
        function test_pick_blank() {
            wiz.currentStep = 2; wait(80)
            var card = G.byText(wiz, "blank dashboard")
            verify(card !== null, "the blank option is present")
            tap(clickableForText("blank dashboard")); wait(60)
            compare(wiz.selectedLayout, "blank", "picking blank selects it")
        }
        function test_finish_calls_bridge_with_choices() {
            wiz.currentStep = 3; wiz.selectedLayout = "gaming"; wait(60)
            tap(findButton("Finish Setup"))
            compare(wizardBridge.calls, 1, "completeWizard is called once")
            compare(wizardBridge.lastArgs.layout, "gaming", "the chosen layout is passed")
            compare(wizardBridge.lastArgs.autostart, true, "the autostart default is passed")
        }
        function test_finish_success_seeds_reports_navigation() {
            wiz.currentStep = 3; wiz.selectedLayout = "starter"
            wizardBridge.nextResult = true; wiz.finishError = ""
            tap(findButton("Finish Setup"))
            compare(wizardBridge.lastArgs.layout, "starter", "the starter bundle is chosen")
            // Saved OK, but there is no StackView host in this test → the wizard
            // surfaces the open error rather than hanging silently.
            verify(wiz.finishError.toLowerCase().indexOf("couldn't open") >= 0,
                   "a saved-but-unnavigable finish surfaces the open error")
        }
        function test_finish_failure_surfaces_error() {
            wiz.currentStep = 3; wizardBridge.nextResult = false; wiz.finishError = ""
            tap(findButton("Finish Setup"))
            verify(wiz.finishError.indexOf("Couldn't save") >= 0, "a failed save surfaces an error")
            verify(G.byText(wiz, "Couldn't save") !== null, "the error text is visible on screen")
        }
    }

    // =========================================================================
    // AREA 8 - Empty / error / diagnostics states
    // =========================================================================
    TestCase {
        id: tcEmpty
        name: "GuiShellEmpty"
        when: windowShown
        visible: true

        property var win: null
        property var dash: null
        property var store: null
        property var swipe: null
        property var sv: null

        function snap(item, n) { var i = G.grabItem(this, item, win.contentItem); i.save("gui-evidence/shellempty_" + n + ".png"); return i }

        function initTestCase() {
            var c = Qt.createComponent("../../ui/qml/main.qml")
            tryVerify(function () { return c.status !== Component.Loading }, 6000)
            compare(c.status, Component.Ready, "main.qml compiles: " + c.errorString())
            win = c.createObject(root)
            // See the note in tcWall.initTestCase: `visibility`, not `visible`,
            // or the window is never exposed and everything inside is 0x0.
            // The Edge is 2560x720. Without an explicit size the windowed shell
            // came up 500x500, so every tile, the BackdropLayer and the page
            // gradient rendered at a shape the product never has - and the orb
            // tint became subtle enough to fall under pxDiff's threshold, which
            // is why the wallpaper rows failed their pixel proof with diff=0.
            win.width = 2560; win.height = 720
            win.visibility = Window.Windowed
            win.orientationMode = "portrait"
            sv = G.findPred(win.contentItem, function (n) {
                return n && typeof n.push === "function" && n.currentItem !== undefined })
            sv.clear(StackView.Immediate)
            sv.push(Qt.resolvedUrl("../../ui/qml/Dashboard.qml"))
            tryVerify(function () { return sv.depth === 1 && sv.currentItem !== null }, 5000,
                      "exactly one current Dashboard page")
            tryVerify(function () {
                dash = sv.currentItem; store = root.findStore(dash); swipe = root.findSwipe(dash)
                return dash !== null && store !== null && swipe !== null
            }, 6000, "Dashboard loaded")
        }
        function cleanupTestCase() { if (win) win.destroy() }

        // The Diagnostics test pushes a real page onto this shared shell. Every
        // following test must start back on the Dashboard; otherwise its Text
        // nodes exist but are effectively invisible under Diagnostics, which
        // made all empty/fallback assertions report zero visible content.
        function init() {
            if (sv && dash && sv.currentItem !== dash)
                sv.pop(dash, StackView.Immediate)
            if (dash) dash.editMode = false
            wait(0)
        }

        function emptyHints() {
            return G.collectPred(dash, function (n) {
                try { return n && n.text !== undefined
                             && ("" + n.text).indexOf("This page is empty") >= 0 } catch (e) { return false }
            })
        }

        // ── 8a. Empty states ──────────────────────────────────────────────────
        function test_blank_doc_one_page() {
            store.load("blank")
            compare(store.pageCount(), 1, "blank doc loads with a single page")
        }
        function test_empty_page_hint_shown() {
            store.load("blank"); dash.editMode = false; wait(150)
            var visibleHints = 0, hs = emptyHints()
            for (var i = 0; i < hs.length; i++) if (hs[i].visible) visibleHints++
            compare(visibleHints, 1, "the empty-page hint is shown on the current page")
            snap(dash, "empty_hint")
        }
        function test_empty_hint_hidden_in_edit() {
            store.load("blank"); dash.editMode = true; wait(150)
            var anyVisible = false, hs = emptyHints()
            for (var i = 0; i < hs.length; i++) if (hs[i].visible) anyVisible = true
            verify(!anyVisible, "the empty-page hint is hidden in edit mode")
            dash.editMode = false
        }
        function test_empty_hint_only_current_page() {
            store.load("blank"); store.addPage(""); dash.editMode = false
            swipe.goToPage(0); tryVerify(function () { return swipe.currentIndex === 0 }, 3000); wait(150)
            var visibleHints = 0, hs = emptyHints()
            for (var i = 0; i < hs.length; i++) if (hs[i].visible) visibleHints++
            compare(visibleHints, 1, "only the current page's hint is visible (not both empty pages')")
        }
        function test_add_widget_ghost_in_edit() {
            store.load("blank"); dash.editMode = true; wait(200)
            var ghost = G.byText(dash, "Add widget")
            verify(ghost !== null && ghost.visible, "the Add-widget ghost is the empty-page affordance in edit")
            dash.editMode = false
        }
        function test_new_page_shows_empty_hint() {
            store.load("blank"); dash.editMode = false
            store.addPage(""); swipe.goToPage(1)
            tryVerify(function () { return swipe.currentIndex === 1 }, 3000); wait(150)
            var visibleHints = 0, hs = emptyHints()
            for (var i = 0; i < hs.length; i++) if (hs[i].visible) visibleHints++
            compare(visibleHints, 1, "a freshly-added empty page shows its hint")
        }

        // ── 8b. Error boundary (fallback tile) ────────────────────────────────
        function test_unknown_type_fallback() {
            var doc = { version: 1, appearance: {}, settings: {},
                pages: [ { name: "Home", tiles: [ { id: "bogus-1", type: "bogus", size: "1x1" } ] } ] }
            dash.applyExternalState(JSON.stringify(doc))
            tryVerify(function () { return G.byText(dash, "isn't available") !== null }, 3000,
                      "an unknown widget type renders the Unavailable fallback card")
            snap(dash, "fallback_unknown")
        }
        function test_typeless_tile_fallback() {
            var doc = { version: 1, appearance: {}, settings: {},
                pages: [ { name: "Home", tiles: [ { id: "typeless-1", type: "", size: "1x1" } ] } ] }
            dash.applyExternalState(JSON.stringify(doc))
            tryVerify(function () { return G.byText(dash, "isn't available") !== null }, 3000,
                      "a typeless (but id-bearing) tile renders the fallback, not a silent blank")
        }
        function test_corrupt_doc_healed_renders() {
            var doc = { version: 1, appearance: {}, settings: {},
                pages: [ { name: "Home", tiles: [ { id: "clock-1", type: "clock", size: "1x1" } ] },
                         { name: "Home", tiles: "not-an-array" } ] }
            dash.applyExternalState(JSON.stringify(doc)); wait(200)
            verify(store.pageCount() >= 1, "a corrupt document is healed to at least one page")
            var img = snap(dash, "healed")
            verify(G.looksRendered(img), "the healed dashboard renders (no blank/crash)")
        }
        function test_idless_tile_dropped() {
            var doc = { version: 1, appearance: {}, settings: {},
                pages: [ { name: "Home", tiles: [ { type: "clock", size: "1x1" },
                                                   { id: "cpu-9", type: "cpu", size: "1x1" } ] } ] }
            dash.applyExternalState(JSON.stringify(doc)); wait(200)
            verify(store.pageCount() >= 1, "hostile doc still yields a valid dashboard")
            // The valid sibling survives.
            var tiles = store.pages()[0].tiles, hasCpu = false
            for (var t = 0; t < tiles.length; t++) if (tiles[t].id === "cpu-9") hasCpu = true
            verify(hasCpu, "the id-bearing sibling tile is kept")
        }
        function test_overlay_closes_when_expanded_tile_removed() {
            var doc = { version: 1, appearance: {}, settings: {},
                pages: [ { name: "Home", tiles: [ { id: "clock-x", type: "clock", size: "1x1" } ] } ] }
            dash.applyExternalState(JSON.stringify(doc)); wait(150)
            dash.expandedId = "clock-x"; dash.expandedType = "clock"; wait(150)
            verify(dash.hasExpanded, "the overlay is open")
            var doc2 = { version: 1, appearance: {}, settings: {}, pages: [ { name: "Home", tiles: [] } ] }
            dash.applyExternalState(JSON.stringify(doc2)); wait(200)
            verify(!dash.hasExpanded, "removing the expanded tile live closes the overlay")
        }

        // ── 8c. Diagnostics navigation ────────────────────────────────────────
        // The source-loaded shell must resolve Diagnostics relative to Dashboard,
        // just as the bundled shell resolves it inside qrc:/qml. This used to
        // produce a missing-resource warning while the shallow button test passed.
        function test_diagnostics_button_present_touch_sized() {
            store.load("blank")
            var b = root.findBarButton(win, "ui-settings")
            verify(b !== null, "the diagnostics BarButton exists")
            verify(b.visible, "the diagnostics button is visible in any mode")
            verify(b.width >= theme.touchPrimary - 1, "the diagnostics button is touch sized")
        }
        function test_diagnostics_repeat_taps_guarded() {
            store.load("blank")
            var b = root.findBarButton(win, "ui-settings")
            var depth0 = dash.host ? dash.host.depth : 1
            mouseClick(b); wait(200)
            verify(dash.host.currentItem !== null, "Diagnostics push produced a page")
            compare(dash.host.currentItem.objectName, "diagnosticsPage",
                    "the real Diagnostics page materialised")
            mouseClick(b); wait(200)
            var depth1 = dash.host ? dash.host.depth : 1
            verify(depth1 <= depth0 + 1, "repeat diagnostics taps never stack more than one page")
        }
    }
}
