import QtQuick
import QtTest
import "../../ui/qml" as App

// COVERAGE NOTE: the HUB's OWN on-panel configuration surfaces, end to end.
//
// The gap this closes. Two config surfaces exist in this product and only one
// of them was covered at value level:
//
//   • The Manager's WidgetConfigDialog - covered by tst_widget_config_values.qml
//     and tst_widget_config_more.qml.
//   • tests/ui/tst_settings_panel.qml drives SettingsPanel STANDALONE, against a
//     stub `root` whose appearance knobs are plain test properties. It proves the
//     control writes its bound sink - it CANNOT prove the hub persists that write
//     or repaints because of it: there is no store, no Dashboard, no backdrop.
//
// Nothing drove the surfaces a user actually touches ON THE DEVICE: the palette
// button in the hub's own bottom bar, the appearance sheet the Dashboard hosts
// (wired to the Dashboard's store, theme, NetHub and UpdateChecker), and the
// per-tile expanded overlay reached by tapping a tile - the ONLY way to configure
// a widget without a second machine.
//
// So this file loads the REAL Dashboard.qml (as main.qml's StackView does, with
// the same shell surface - appearance knobs ALIASED onto Theme exactly like
// main.qml) and drives those surfaces with real mouse input. Every assertion
// pairs the write with an observable the write is supposed to move:
//
//   sheet   → store.appearance() key  +  theme token / picker enabled / BackdropLayer
//   overlay → store.settingsFor(tile) +  the rendered preview widget's status/colour
//
// Deliberately NOT re-tested here (already covered, and duplicating it would just
// make this file slower to fail):
//   • control→sink writes on the standalone panel (theme chip, accent swatch,
//     orientation, glass slider drag + rebind, glow/reduce-motion/animated
//     toggles, Pro gating, Screens entry, update-check store write)
//       → tst_settings_panel.qml
//   • BackgroundPicker's style/wallpaper exclusivity + page-vs-global precedence,
//     driven through pickStyle()/pickWallpaper() on a standalone picker
//       → tst_background_picker.qml
//   • cfgAction / closeExpanded, WidgetHost lifecycle, and the overlay's
//     retained-content fade
//       → tst_dashboard.qml
//   • DashboardStore.resetSettings semantics (deep clone, stale-key drop)
//       → tst_gen_shared_DashboardStore.qml, tst_store_pages.qml
//
// NO EGRESS: the one test that opts into the update check flips the store's
// netOffline kill switch FIRST, so the checker's single GET is refused by the
// gate. That is also the assertion - the opt-in surface must honour the switch.
Item {
    id: root
    width: 900; height: 1400

    // ── Shell surface (main.qml's root), reproduced exactly ──────────────────
    // main.qml ALIASES accent/glass/glow/reduceMotion onto Theme and keeps
    // themeMode/animatedBackground/orientationMode as plain properties; the
    // Dashboard's Connections persist each change to the store. Using plain
    // properties here instead would quietly break that chain.
    property alias theme: _theme
    App.Theme { id: _theme }
    App.WidgetSizes { id: _sizes }
    App.WidgetCatalog { id: _catalog }
    property string themeMode: "dark"
    property alias accentName: _theme.accentName
    property alias glassOpacity: _theme.glassOpacity
    property alias showWidgetGlow: _theme.showWidgetGlow
    property alias reduceMotion: _theme.reduceMotion
    property bool animatedBackground: true
    property string orientationMode: "auto"
    // A hot CPU: 95 °C is above the schema's default warnTemp (85), so the
    // reading starts in the error colour and the warnTemp field has somewhere
    // to move it to.
    property string metricsJson: '{"cpu_usage_percent":42,"cpu_temp_celsius":95}'
    property string screensData: "[]"

    Loader { id: ld; anchors.fill: parent; source: "../../ui/qml/Dashboard.qml" }

    // ── tree helpers ─────────────────────────────────────────────────────────
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
    function findText(n, str) {
        return findPred(n, function (x) {
            return x.text !== undefined && typeof x.text === "string" && x.text === str
        })
    }
    function findObj(n, name) { return findPred(n, function (x) { return x.objectName === name }) }

    property var _store: null
    function store() {
        if (!_store)
            _store = findPred(ld.item, function (x) {
                return x && x.applyExternal !== undefined && x.structureRevision !== undefined
            })
        return _store
    }
    // The Dashboard's own SettingsPanel instance (not a fresh one): identified by
    // the pair of properties only that component declares.
    function sheet() {
        return findPred(ld.item, function (x) {
            return x && x.presetsLocked !== undefined && x.updateChecker !== undefined
        })
    }
    // The live animated backdrop behind the dashboard - style/running/accent is
    // BackdropLayer's signature. This is the rendered thing the background and
    // theme choices in the sheet have to move.
    function backdrop() {
        return findPred(ld.item, function (x) {
            return x && x.style !== undefined && x.running !== undefined && x.accent !== undefined
        })
    }
    function picker() {
        return findPred(sheet(), function (x) {
            return x && x.pickStyle !== undefined && x.selStyle !== undefined
        })
    }
    // Theme/orientation/background chips all carry a modelData; scope by shape.
    function chipWhere(scope, pred) {
        return findPred(scope, function (x) { return x.modelData !== undefined && pred(x) })
    }
    function switchForLabel(scope, labelText) {
        var t = findText(scope, labelText)
        if (!t) return null
        var kids = t.parent.children
        for (var i = 0; i < kids.length; i++)
            if (kids[i].checked !== undefined && kids[i].checkable !== undefined) return kids[i]
        return null
    }

    function tileCells() {
        var out = []
        eachItem(ld.item, function (x) {
            if (x && x._r !== undefined && x.tileId !== undefined
                  && x.tileSize !== undefined && x.ps !== undefined) out.push(x)
        })
        return out
    }
    function cellFor(id) {
        var cs = tileCells()
        for (var i = 0; i < cs.length; i++) if (cs[i].tileId === id) return cs[i]
        return null
    }
    // The tile's touch-sized expand affordance (z:20, square) - the ONLY tap that
    // opens a tile's config on the device (a body tap deliberately does not).
    function expandTargetIn(cell) {
        return findPred(cell, function (x) {
            return x.z === 20 && x.width !== undefined && x.width > 0 && x.width === x.height
        })
    }
    function makeDoc(tileList, appearance) {
        return JSON.stringify({ version: 1, appearance: appearance || ({}), settings: {},
            pages: [ { name: "P1", tiles: tileList } ] })
    }

    // ── A tile whose widget actually RENDERS offscreen ───────────────────────
    // The shipped catalog addresses its widgets as `qrc:/qml/CpuWidget.qml`, and
    // that resource only exists inside the built binary - offscreen, every
    // shipped tile's Loader fails, so there is no rendered widget to assert on.
    // (tst_dashboard.qml works around this by never rendering one.)
    //
    // The Tier-0 user-widget path is the documented seam that DOES address a
    // widget by file, so we register the REAL CpuWidget.qml through it: same
    // file, same tile pipeline, same expanded overlay, same WidgetConfigPanel -
    // the only difference is that the form's schema comes from the manifest
    // instead of WidgetConfigSchema. That gives the on-hub config assertions a
    // genuine rendered observable (the widget's own status text and colour).
    // The shipped-schema half of the path is asserted separately, on a real
    // `cpu` tile, in test_tapping_a_tile_opens_ITS_config_overlay().
    readonly property string widgetsDir:
        Qt.resolvedUrl("../../ui/qml/widgets").toString().replace(/^file:\/\//, "")
    function cpuScanEntry() {
        return JSON.stringify({
            dir: root.widgetsDir, dirName: "cpu",
            files: ["CpuWidget.qml", "manifest.json"],
            manifest: JSON.stringify({
                manifestVersion: 1, type: "user.cpu", title: "CPU",
                category: "User", description: "The shipped CPU widget, addressed by file.",
                entry: "CpuWidget.qml", sizes: ["1x1", "1x2"], dflt: "1x1",
                // No seeded defaults: "Reset configuration" must then CLEAR the
                // keys the user set here, which is what that button promises.
                defaults: {},
                // The two keys CpuWidget actually reads, with the shipped
                // schema's own defaults and range.
                config: [
                    { key: "showTemp", label: "Show temperature", type: "toggle", dflt: true },
                    { key: "warnTemp", label: "Warn above", type: "slider",
                      min: 60, max: 100, step: 1, dflt: 85 } ] })
        })
    }

    TestCase {
        name: "HubConfigSurfaces"
        when: windowShown

        function initTestCase() {
            tryVerify(function () { return ld.status === Loader.Ready && ld.item !== null }, 5000)
            verify(root.store() !== null, "found the Dashboard's private DashboardStore")
            verify(root.sheet() !== null, "the Dashboard hosts a SettingsPanel")
        }

        function init() {
            var d = ld.item
            d.closeExpanded()
            var p = root.sheet()
            p.shown = false
            // Wait out BOTH close fades. A modal that is still fading out keeps a
            // live input barrier (the sheet's scrim, the overlay's full-screen
            // MouseArea), which would swallow the next test's very first tap and
            // fail it for a reason that has nothing to do with what it asserts.
            var ovl = findPred(d, function (x) { return x.ovlWide !== undefined })
            tryVerify(function () { return p.opacity < 0.01 && ovl.opacity < 0.01 }, 3000)
            root.store().load("blank")
            root.themeMode = "dark"
            _theme.applyTheme("dark"); _theme.applyAccent("blue")
            root.animatedBackground = true
            root.reduceMotion = false
        }

        // Bring a target inside the given Flickable's viewport before clicking it:
        // the settings sheet is height-capped and clips, and a clipped-away control
        // receives no mouse events.
        function scrollTo(flick, target) {
            verify(flick !== null, "found the scroller")
            var p = target.mapToItem(flick.contentItem, 0, 0)
            var maxY = Math.max(0, flick.contentHeight - flick.height)
            flick.contentY = Math.max(0, Math.min(maxY, p.y - 40))
            wait(60)
        }
        function sheetFlick() {
            return findPred(root.sheet(), function (x) {
                return x.contentHeight !== undefined && x.contentY !== undefined
                       && x.boundsBehavior !== undefined
            })
        }
        function clickInSheet(target) { scrollTo(sheetFlick(), target); mouseClick(target) }
        function clickInForm(target) { scrollTo(findObj(ld.item, "cfgScroll"), target); mouseClick(target) }

        function openSheet() {
            var p = root.sheet()
            if (!p.shown) {
                var palette = findPred(ld.item, function (x) { return x.iconName === "ui-palette" })
                verify(palette !== null, "the hub's bottom bar carries the appearance button")
                mouseClick(palette)
            }
            tryVerify(function () { return p.opacity > 0.99 }, 3000, "the appearance sheet is fully shown")
            return p
        }

        // ─────────────────────────────────────────────────────────────────────
        // A. The hub's on-panel appearance sheet
        // ─────────────────────────────────────────────────────────────────────

        // The entry point itself: nothing tested that the hub's own bottom bar
        // can reach its settings - every settings test so far set `shown` by hand.
        function test_palette_button_opens_the_appearance_sheet() {
            var p = root.sheet()
            compare(p.shown, false, "precondition: the sheet is closed")
            compare(p.opacity, 0.0, "…and fully transparent")
            var palette = findPred(ld.item, function (x) { return x.iconName === "ui-palette" })
            verify(palette !== null, "found the palette button in the hub's bottom bar")
            mouseClick(palette)
            compare(p.shown, true, "tapping it opens the appearance sheet")
            tryVerify(function () { return p.opacity > 0.99 }, 3000, "…and it fades fully in")
            // And the close affordance takes it away again (the sheet's own signal
            // is wired by the Dashboard, not by the panel).
            var closeBtn = findPred(p, function (x) { return x.name === "ui-close" })
            verify(closeBtn !== null, "the sheet has a close button")
            mouseClick(closeBtn.parent)
            compare(p.shown, false, "tapping close closes it")
        }

        // A theme picked on the DEVICE must (a) repaint and (b) survive a restart:
        // the standalone panel test can only see (a), because there is no store
        // behind it. This asserts the Dashboard's persistence link too.
        function test_theme_chip_repaints_and_persists_to_the_store() {
            var p = openSheet()
            compare(root.store().appearance().themeMode === "midnight", false,
                    "precondition: midnight is not the persisted theme")
            var chip = chipWhere(p, function (x) { return x.modelData.k === "midnight" })
            verify(chip !== null, "the midnight theme chip is on the sheet")
            clickInSheet(chip)
            compare(root.themeMode, "midnight", "the shell's theme mode changed")
            verify(Qt.colorEqual(_theme.backgroundColor, "#0B1026"),
                   "…the theme repainted to the midnight tone (got " + _theme.backgroundColor + ")")
            compare(root.store().appearance().themeMode, "midnight",
                    "…and the hub PERSISTED it to appearance.themeMode")
            verify(chip.active, "the chip now reads as the active theme")
        }

        // High Contrast is not just a palette: it turns decoration OFF. Two things
        // must follow on the device - the backdrop stops rendering, and the
        // background picker DISABLES itself instead of accepting taps that no-op.
        function test_high_contrast_kills_the_backdrop_and_disables_the_background_picker() {
            var p = openSheet()
            var bd = root.backdrop()
            var bp = root.picker()
            verify(bd !== null, "found the live BackdropLayer")
            verify(bp !== null, "found the background picker inside the sheet")
            verify(bd.visible, "precondition: the backdrop renders under a decorative theme")
            compare(bp.enabled, true, "precondition: the picker accepts taps")

            var hc = chipWhere(p, function (x) { return x.modelData.k === "high_contrast"; })
            verify(hc !== null, "the accessibility theme is offered on the sheet")
            verify(!hc.locked, "…and it is NOT Pro-gated (accessibility must never be paywalled)")
            clickInSheet(hc)

            compare(_theme.decorative, false, "High Contrast turns decoration off")
            compare(bd.visible, false, "…so the animated backdrop stops rendering")
            compare(bp.enabled, false, "…and the background picker refuses taps")
            fuzzyCompare(bp.opacity, 0.4, 0.01, "…and reads as disabled")
            var warn = findText(p, "The High Contrast theme keeps backgrounds off for legibility - switch themes to see them.")
            verify(warn !== null && warn.visible, "…and the sheet explains why")
            compare(root.store().appearance().themeMode, "high_contrast", "persisted")

            // Reversible: going back to a decorative theme restores all three.
            var dark = chipWhere(p, function (x) { return x.modelData.k === "dark" })
            clickInSheet(dark)
            compare(_theme.decorative, true, "back to a decorative theme")
            compare(bp.enabled, true, "the picker is usable again")
            compare(bd.visible, true, "and the backdrop is back")
            verify(warn === null || !warn.visible, "the warning is gone")
        }

        // ═══════════════════════════════════════════════════════════════════
        // KNOWN BUG - the hub's on-panel Background picker is INERT.
        //
        // Tapping any style chip (or wallpaper thumbnail) in the hub's own
        // appearance sheet writes NOTHING and changes NOTHING. The runtime says
        // so out loud, once per tap:
        //
        //   BackgroundPicker.qml:55: TypeError: Cannot call method
        //   'setAppearance' of undefined
        //
        // Root cause - the self-binding trap WidgetConfigPanel.qml:14-19 documents
        // at length, in the one place it was not avoided. BackgroundPicker declares
        // `property var store`, and SettingsPanel.qml:298 binds `store: store`, so
        // the RHS resolves to the picker's OWN (undefined) property instead of the
        // hub's store. What is directly OBSERVED here, not inferred:
        //   • the picker's writes throw on an undefined `store` (the TypeError), so
        //     `store: store` did not deliver the hub's store; while
        //   • other `store.` uses in the SAME file work - the update-check switch
        //     (SettingsPanel.qml:428) writes the hub's appearance correctly, proving
        //     the name IS reachable from this file for objects that do not shadow it.
        //
        // Why nothing caught it: every other call site binds `store: store` in the
        // SAME document as the store's id (Manager.qml:937/1186, and
        // tst_background_picker.qml:18-19, which passes) - that shape resolves to
        // the id and works. SettingsPanel.qml is the only call site that inherits
        // `store` from the enclosing component, i.e. the only one that shadows.
        //
        // User impact: on the device, the Background section of Settings shows no
        // current selection and cannot change the background at all. The Manager
        // is the only way to set one.
        //
        // The fix is the one this repo already made for the config panel: rename
        // the property to `st` (and update the three call sites). This test is
        // written against the CORRECT behaviour and marked expectFail - when the
        // rename lands it will XPASS, which QtTest reports as a failure, forcing
        // the expectFail to be removed rather than letting it rot.
        // ═══════════════════════════════════════════════════════════════════
        function test_background_style_writes_global_appearance_and_restyles_the_live_backdrop() {
            var p = openSheet()
            var bd = root.backdrop()
            verify(bd !== null, "found the live BackdropLayer")
            compare(bd.style, "orbs", "precondition: the default backdrop style")

            var waves = chipWhere(root.picker(), function (x) { return x.modelData.v === "waves" })
            verify(waves !== null, "the Waves style chip is on the sheet")
            clickInSheet(waves)
            compare(root.store().appearance().bgStyle, "waves", "written to the GLOBAL appearance")
            compare(root.store().appearance().wallpaper, "", "…and it cleared any wallpaper")
            compare(bd.style, "waves", "the live backdrop re-styled")
            verify(waves.sel, "the chip reads as selected")

            // Live, not once: a second pick moves it again.
            var stars = chipWhere(root.picker(), function (x) { return x.modelData.v === "stars" })
            clickInSheet(stars)
            compare(root.store().appearance().bgStyle, "stars", "second pick persisted")
            compare(bd.style, "stars", "…and the backdrop followed")
            verify(!waves.sel, "the previous chip deselected")
        }

        // "Animated background" OFF must genuinely REMOVE the backdrop (plain
        // gradient), and persist as appearance.animatedBg. tst_settings_panel can
        // only see the property write; the removal is what the toggle promises.
        function test_animated_background_toggle_removes_the_backdrop_and_persists() {
            var p = openSheet()
            var bd = root.backdrop()
            verify(bd.visible, "precondition: the backdrop renders")
            var sw = switchForLabel(p, "Animated background")
            verify(sw !== null, "found the animated-background switch")
            compare(sw.checked, true, "reflects the shell's current state")

            clickInSheet(sw)
            compare(root.animatedBackground, false, "the shell flag went off")
            compare(root.store().appearance().animatedBg, false, "…and the hub persisted it")
            compare(bd.visible, false, "…and the backdrop is genuinely gone, not frozen")

            clickInSheet(sw)
            compare(root.animatedBackground, true, "back on")
            compare(root.store().appearance().animatedBg, true, "persisted on")
            compare(bd.visible, true, "…and the backdrop is rendering again")
        }

        // "Reduce motion" is the other half of that pair and must behave the
        // OPPOSITE way: the backdrop stays, its motion stops.
        function test_reduce_motion_keeps_the_backdrop_but_stops_it() {
            var p = openSheet()
            var bd = root.backdrop()
            compare(bd.running, true, "precondition: the backdrop is animating")
            var sw = switchForLabel(p, "Reduce motion")
            verify(sw !== null, "found the reduce-motion switch")
            clickInSheet(sw)
            compare(_theme.effectiveReduceMotion, true, "reduce motion is in effect")
            compare(bd.running, false, "the backdrop's motion stopped")
            compare(bd.visible, true, "…but the backdrop itself is STILL there (that's the other toggle)")
            compare(root.store().appearance().reduceMotion, true, "persisted")
            clickInSheet(sw)
            compare(bd.running, true, "motion resumes when the preference is cleared")
        }

        // The accent chosen on the device must recolour the chrome, not just the
        // token: the sheet's own glass percentage is accent-coloured, and the
        // backdrop takes its accent from the theme.
        function test_accent_swatch_recolours_the_sheet_and_the_backdrop() {
            var p = openSheet()
            var bd = root.backdrop()
            var pct = findPred(p, function (x) {
                return x.text !== undefined && typeof x.text === "string" && /^\d+%$/.test(x.text)
            })
            verify(pct !== null, "found the accent-coloured glass percentage label")
            verify(Qt.colorEqual(pct.color, _theme.accentPresets["blue"].a), "precondition: blue accent")

            var swatch = findPred(p, function (x) { return x.modelData === "green" && x.radius === 26 })
            verify(swatch !== null, "found the green accent swatch")
            clickInSheet(swatch)
            verify(Qt.colorEqual(_theme.accent, _theme.accentPresets["green"].a), "the theme accent changed")
            verify(Qt.colorEqual(pct.color, _theme.accentPresets["green"].a),
                   "…the sheet's own accent-coloured text followed (got " + pct.color + ")")
            verify(Qt.colorEqual(bd.accent, _theme.accentPresets["green"].a),
                   "…and so did the live backdrop")
            compare(root.store().appearance().accent, "green", "…and the hub persisted the choice")
        }

        // The opt-in update check, wired to the REAL UpdateChecker + NetHub the
        // Dashboard owns. The standalone panel has no checker, so its result line
        // could never appear there - this is the only place that surface renders.
        //
        // The kill switch is flipped FIRST so the single GET is refused: this test
        // performs no egress, and the refusal is itself the privacy assertion.
        function test_update_optin_reveals_the_result_line_and_obeys_the_kill_switch() {
            var p = openSheet()
            root.store().setAppearance("netOffline", true)
            var chk = p.updateChecker
            verify(chk !== null, "the Dashboard injected its UpdateChecker into the sheet")
            compare(chk.enabled, false, "precondition: opted out (zero-egress default)")

            var checkNow = findText(p, "Check now")
            verify(checkNow !== null, "the manual re-check button exists in the sheet")
            compare(checkNow.visible, false, "…but it is hidden while opted out")

            var sw = switchForLabel(p, "Check for updates")
            verify(sw !== null, "found the update-check switch")
            clickInSheet(sw)
            compare(root.store().appearance().updateCheck, true, "the opt-in persisted")
            compare(chk.enabled, true, "…and reached the real checker")
            compare(checkNow.visible, true, "…which reveals the result line + re-check button")
            compare(chk.message, "Blocked: the global offline switch is on.",
                    "the opt-in check was refused by the egress gate - no request left the device")
            var line = findText(p, "Blocked: the global offline switch is on.")
            verify(line !== null && line.visible, "…and the sheet renders that reason")

            clickInSheet(sw)
            compare(chk.enabled, false, "opting out again")
            compare(chk.message, "Off - EdgeHub never checks on its own.",
                    "…clears the stale result rather than letting it outlive consent")
            compare(checkNow.visible, false, "…and hides the line")
        }

        // ─────────────────────────────────────────────────────────────────────
        // B. The per-tile config the user reaches by TAPPING a tile
        // ─────────────────────────────────────────────────────────────────────

        // Tap a tile's expand affordance - the real gesture - and wait for the
        // overlay to be fully open. Returns the tile id.
        function tapTile(id) {
            var d = ld.item
            tryVerify(function () { return root.cellFor(id) !== null }, 5000, "the tile is laid out")
            var cell = root.cellFor(id)
            var target = root.expandTargetIn(cell)
            verify(target !== null, "the tile carries its touch-sized expand affordance")
            verify(target.width >= _theme.touchSecondary,
                   "…and it is touch sized (" + target.width + ")")
            mouseClick(target)
            var ovl = findPred(d, function (x) { return x.ovlWide !== undefined })
            tryCompare(ovl, "opacity", 1.0, 3000, "the expanded config overlay is fully open")
            return id
        }
        // Register the real CpuWidget as a file-addressed tile and open its config.
        function openRenderingTile() {
            var d = ld.item
            d.userWidgetProvider = function () { return [ root.cpuScanEntry() ] }
            root.store().applyExternal(root.makeDoc([], { enableUserWidgets: true }))
            compare(d._loadUserWidgets(), 1, "the file-addressed CPU widget registered")
            var id = root.store().addTile(0, "user.cpu")
            verify(id !== "", "the tile was added")
            tapTile(id)
            tryVerify(function () { return d.overlayLoaderItem !== null }, 5000,
                      "the overlay instantiated the widget")
            return id
        }
        function formPanel() {
            return findPred(ld.item, function (x) {
                return x.st !== undefined && x.instanceId !== undefined && x.schema !== undefined
            })
        }

        // The entry gesture + the wiring that decides WHICH tile gets edited,
        // on a real SHIPPED tile (its form comes from WidgetConfigSchema).
        function test_tapping_a_tile_opens_ITS_config_overlay() {
            var d = ld.item
            d.applyExternalState(root.makeDoc([ { id: "c1", type: "cpu" },
                                                { id: "c2", type: "clock" } ]))
            compare(d.hasExpanded, false, "precondition: nothing expanded")
            tapTile("c2")
            compare(d.expandedId, "c2", "the overlay opened on the tile that was tapped")
            compare(d.expandedType, "clock", "…with that tile's type")

            var form = formPanel()
            verify(form !== null, "the overlay carries the config form")
            compare(form.instanceId, "c2", "the form edits the tapped tile, not its neighbour")
            compare(form.st, root.store(), "…through the hub's own store")
            // The shipped schema reached the on-hub form (not the manifest path).
            verify(findObj(ld.item, "field-format24") !== null,
                   "the form is populated from WidgetConfigSchema (the clock's 24-hour field)")
            verify(findObj(ld.item, "field-showTemp") === null,
                   "…and shows the tapped tile's fields, not the other tile's")

            // The Done bar is the primary way out on a tall panel - tapped, not called.
            var done = findText(d, "Done")
            verify(done !== null && done.visible, "the overlay's Done bar is present")
            mouseClick(done.parent.parent)
            compare(d.expandedId, "", "tapping Done closed the overlay")
            compare(d.hasExpanded, false, "…and cleared the expanded state")
        }

        // A shipped tile's on-hub form writes to THAT tile's settings bucket.
        // (Its widget cannot render offscreen - see widgetsDir above - so the
        // rendered half of this chain is asserted on the file-addressed tile.)
        function test_shipped_tile_form_writes_to_that_tiles_settings() {
            var d = ld.item
            d.applyExternalState(root.makeDoc([ { id: "c1", type: "cpu" } ]))
            tapTile("c1")
            var field = findObj(ld.item, "field-showTemp")
            verify(field !== null, "the shipped CPU schema reached the on-hub form")
            var sw = findPred(field, function (x) { return x.checked !== undefined && x.checkable !== undefined })
            verify(sw !== null, "…as a switch")
            compare(sw.checked, true, "reflecting the shipped schema default")
            clickInForm(sw)
            compare(root.store().settingsFor("c1").showTemp, false,
                    "the tap landed in that tile's settings bucket")
            compare(sw.checked, false, "…and the control holds the new value")
        }

        // Toggle written on the hub's own form → the tile's settings bucket → the
        // rendered widget. The observable is the header status text, which is ""
        // exactly when showTemp is off.
        function test_toggle_on_the_hub_form_lands_in_the_tile_and_changes_the_render() {
            var id = openRenderingTile()
            var w = ld.item.overlayLoaderItem
            compare(w.instanceId, id, "the preview widget is bound to the tapped instance")
            compare(w.expanded, true, "…and rendered in its full interactive layout")
            compare(w.status, "95°C · Critical temperature",
                    "precondition: the preview renders the temperature and state")

            var field = findObj(ld.item, "field-showTemp")
            verify(field !== null, "the on-hub form offers the 'Show temperature' field")
            var sw = findPred(field, function (x) { return x.checked !== undefined && x.checkable !== undefined })
            verify(sw !== null, "…as a switch")
            compare(sw.checked, true, "reflecting the schema default")

            clickInForm(sw)
            compare(root.store().settingsFor(id).showTemp, false,
                    "the tap landed in THAT tile's settings bucket")
            compare(w.status, "Critical temperature",
                    "…and the rendered preview dropped the numeric temperature")

            clickInForm(sw)
            compare(root.store().settingsFor(id).showTemp, true, "…and back on")
            compare(w.status, "95°C · Critical temperature",
                    "…with the temperature and state rendered again")
        }

        // A slider on the hub's form, driven by a real drag (a touch panel has no
        // keyboard): warnTemp decides the colour of the reading, so the drag has a
        // colour observable, not just a number.
        function test_slider_drag_on_the_hub_form_recolours_the_reading() {
            var id = openRenderingTile()
            var w = ld.item.overlayLoaderItem
            compare(String(w.statusColor), String(_theme.error),
                    "precondition: 95 °C is above the default 85 °C warning, so the reading is red")

            var field = findObj(ld.item, "field-warnTemp")
            verify(field !== null, "the on-hub form offers the 'Warn above' field")
            var sld = findPred(field, function (x) {
                return x.from !== undefined && x.to !== undefined && x.stepSize !== undefined
            })
            verify(sld !== null, "…as a slider")
            compare(sld.value, 85, "reflecting the schema default")

            scrollTo(findObj(ld.item, "cfgScroll"), sld)
            var y = sld.height / 2
            mousePress(sld, sld.width * 0.5, y)
            mouseMove(sld, sld.width * 0.99, y)
            mouseRelease(sld, sld.width * 0.99, y)

            compare(root.store().settingsFor(id).warnTemp, 100,
                    "dragging to the end wrote the maximum into the tile's settings")
            compare(sld.value, 100, "…and the control holds it")
            compare(String(w.statusColor), String(_theme.warning),
                    "…and 95 °C is no longer an error, only a warning - the render followed")
        }

        // "Reset configuration" is on the hub's overlay and nowhere else. It must
        // clear the keys the user set here and put the render back.
        function test_reset_to_defaults_on_the_overlay_restores_the_rendered_widget() {
            var id = openRenderingTile()
            var w = ld.item.overlayLoaderItem
            root.store().setSetting(id, "showTemp", false)
            root.store().setSetting(id, "warnTemp", 61)
            compare(w.status, "Critical temperature",
                    "precondition: the configured widget hides the numeric temperature")

            var reset = findText(ld.item, "Reset configuration")
            verify(reset !== null && reset.visible, "the overlay offers Reset configuration")
            mouseClick(reset.parent)
            tryVerify(function () { return ld.item.widgetDataDialog.visible }, 2000,
                      "reset opens a scoped confirmation")
            ld.item.widgetDataConfirmButton.clicked()

            compare(root.store().settingsFor(id).showTemp, undefined,
                    "the reset dropped the key from the tile's settings")
            compare(root.store().settingsFor(id).warnTemp, undefined, "…and the other one")
            compare(w.status, "95°C · Critical temperature",
                    "…and the preview is back to the default rendering")
            compare(String(w.statusColor), String(_theme.error), "…including its default warning threshold")
        }

        // The overlay edits the SAME persisted state as the tile behind it - a
        // config that only moved the preview would be the worst kind of pass.
        function test_overlay_edit_reaches_the_TILE_behind_it() {
            var id = openRenderingTile()
            var w = ld.item.overlayLoaderItem
            var cell = root.cellFor(id)
            var tileWidget = findPred(cell, function (x) {
                return x.instanceId === id && x.status !== undefined && x !== w
            })
            verify(tileWidget !== null, "found the tile's own widget instance behind the overlay")
            compare(tileWidget.status, "95°C · Critical temperature",
                    "precondition: the tile renders the temperature and state too")

            var field = findObj(ld.item, "field-showTemp")
            var sw = findPred(field, function (x) { return x.checked !== undefined && x.checkable !== undefined })
            clickInForm(sw)
            compare(w.status, "Critical temperature", "the overlay preview updated")
            compare(tileWidget.status, "Critical temperature",
                    "…and so did the tile on the dashboard behind it")
        }
    }
}
