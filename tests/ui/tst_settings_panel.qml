import QtQuick
import QtTest
import "../../ui/qml" as App
import "../../ui/qml/widgets" as Wg

// SettingsPanel (ui/qml/widgets/SettingsPanel.qml) - the in-app appearance sheet.
// Each control row is bound to an appearance key on `root`/`theme`/`store`; we
// assert BOTH directions: the control REFLECTS external state (read) and a tap
// WRITES through the bound sink (write). The sheet height is capped, so the form
// scrolls - a helper brings each target into view before clicking it.
Item {
    id: root
    width: 720; height: 1000

    property alias theme: _theme
    App.Theme { id: _theme }
    App.DashboardStore { id: store }

    // Appearance knobs the panel reads/writes on `root` (in the app these alias
    // onto the persisted config). accentName mirrors theme so the accent swatch
    // highlight updates after applyAccent(), exactly as in the hub.
    property string themeMode: "dark"
    property string orientationMode: "auto"
    property real glassOpacity: 0.6
    property bool showWidgetGlow: true
    property bool animatedBackground: true
    property bool reduceMotion: false
    property string accentName: _theme.accentName

    Component.onCompleted: store.load("blank")

    property int presetsRequestedCount: 0
    Wg.SettingsPanel { id: panel; onPresetsRequested: root.presetsRequestedCount++ }

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
    function findFlick() {
        return findPred(panel, function (n) {
            return n.contentHeight !== undefined && n.contentY !== undefined && n.boundsBehavior !== undefined
        })
    }
    // Theme/orientation delegates carry an `active` bool + `modelData`.
    function delegateWhere(pred) {
        return findPred(panel, function (n) { return n.active !== undefined && n.modelData !== undefined && pred(n) })
    }

    TestCase {
        name: "SettingsPanel"
        when: windowShown

        function init() {
            root.themeMode = "dark"; root.glassOpacity = 0.6
            root.showWidgetGlow = true; root.animatedBackground = true; root.reduceMotion = false
            _theme.applyTheme("dark"); _theme.applyAccent("blue")
            root.presetsRequestedCount = 0
            panel.presetsLocked = false
            panel.shown = true
            tryVerify(function () { return panel.opacity > 0.99 }, 2000)
        }

        function bringIntoView(target) {
            var scroll = findFlick()
            verify(scroll !== null, "found the settings Flickable")
            var p = target.mapToItem(scroll.contentItem, 0, 0)
            var maxY = Math.max(0, scroll.contentHeight - scroll.height)
            scroll.contentY = Math.max(0, Math.min(maxY, p.y - 40))
            wait(60)
        }
        function clickTarget(target) { bringIntoView(target); mouseClick(target) }

        // ── Screens entry (post-setup preset library, W5 finding 3) ──────────
        function test_screens_entry_opens_the_preset_library() {
            var entry = findPred(panel, function (n) { return n.objectName === "screensEntry" })
            verify(entry !== null, "the Screens entry is present in Settings")
            verify(entry.visible, "…and visible when no policy lock holds")
            verify(entry.height >= _theme.touchSecondary,
                   "the entry is touch sized (" + entry.height + ")")
            clickTarget(entry)
            compare(root.presetsRequestedCount, 1, "tapping it emits presetsRequested")
        }

        function test_screens_entry_absent_under_policy_lock() {
            panel.presetsLocked = true
            var entry = findPred(panel, function (n) { return n.objectName === "screensEntry" })
            verify(entry !== null && !entry.visible,
                   "an org-forced preset removes the entry outright (absent, not greyed)")
            var caption = findText(panel, "Ready-made screens. Adding one appends a new screen and takes you to it; your look stays.")
            verify(caption === null || !caption.visible, "the caption disappears with it")
            panel.presetsLocked = false
            verify(entry.visible, "clearing the lock restores the entry")
        }

        // ── Theme mode (segmented) ───────────────────────────────────────────
        function test_theme_mode_reflects_external_state() {
            root.themeMode = "midnight"
            var d = delegateWhere(function (n) { return n.modelData.k === "midnight" })
            verify(d !== null, "midnight theme swatch exists")
            verify(d.active, "the swatch matching root.themeMode is active")
        }

        function test_theme_mode_click_writes_and_applies() {
            var d = delegateWhere(function (n) { return n.modelData.k === "midnight" })
            clickTarget(d)
            compare(root.themeMode, "midnight", "tapping a theme swatch writes root.themeMode")
            verify(Qt.colorEqual(_theme.backgroundColor, "#0B1026"),
                   "…and applies the theme (background is the midnight tone)")
        }

        // Pro-gating: without a licence (no `license` context in the harness → free),
        // a Pro theme is locked and tapping it must NOT apply - the on-device leak fix.
        function test_pro_theme_is_gated_without_a_licence() {
            root.themeMode = "dark"; _theme.applyTheme("dark")
            var d = delegateWhere(function (n) { return n.modelData.k === "synthwave" })
            verify(d !== null, "a Pro theme (synthwave) is listed")
            verify(d.locked, "…and it is locked without a licence")
            clickTarget(d)
            compare(root.themeMode, "dark", "tapping a locked Pro theme does NOT apply it")
        }

        // ── Accent color ─────────────────────────────────────────────────────
        function test_accent_swatch_click_applies_accent() {
            var d = findPred(panel, function (n) {
                return n.modelData === "green" && n.color !== undefined && n.radius === 26
            })
            verify(d !== null, "found the green accent swatch")
            clickTarget(d)
            compare(_theme.accentName, "green", "tapping a swatch calls applyAccent")
            verify(Qt.colorEqual(_theme.accent, _theme.accentPresets["green"].a), "accent recoloured")
            compare(root.accentName, "green", "the active-swatch source (accentName) tracks the applied accent")
        }

        // The Layout Columns picker is GONE - a size is a fraction of the screen,
        // so a per-page column count may not exist. Asserted, not merely deleted:
        // the picker was inert for a while before it was removed (nothing read it,
        // and _normaliseDoc stripped the key on reload), and a control that silently
        // does nothing is worse than no control.
        function test_no_layout_columns_picker() {
            var d = delegateWhere(function (n) {
                return typeof n.modelData.l === "string" && n.modelData.l.indexOf("Column") >= 0
            })
            compare(d, null, "no column-count delegate survives in the settings panel")
        }

        // ── Orientation (segmented) ──────────────────────────────────────────
        function test_orientation_click_writes() {
            var d = delegateWhere(function (n) { return n.modelData.v === "portrait" })
            verify(d !== null, "portrait orientation option exists")
            clickTarget(d)
            compare(root.orientationMode, "portrait", "tapping an orientation writes root.orientationMode")
        }

        // ── Glass / transparency ─────────────────────────────────────────────
        function test_glass_slider_and_label_reflect_value() {
            root.glassOpacity = 0.25
            var slider = findPred(panel, function (n) {
                return n.from !== undefined && n.to !== undefined && n.value !== undefined && n.stepSize !== undefined
            })
            verify(slider !== null, "glass slider present")
            fuzzyCompare(slider.value, 0.25, 0.001, "slider reflects root.glassOpacity")
            verify(findText(panel, "25%") !== null, "the percentage label reflects the value")
        }

        // The slider must actually DRAG (the class of bug the Manager glass slider
        // shipped with - no test anywhere dragged a slider). Real mouse input.
        function test_glass_slider_drags_commits_and_rebinds() {
            var slider = findPred(panel, function (n) {
                return n.from !== undefined && n.to !== undefined && n.value !== undefined && n.stepSize !== undefined
            })
            verify(slider !== null, "glass slider present")
            bringIntoView(slider)
            root.glassOpacity = 0.3
            tryVerify(function () { return Math.abs(slider.value - 0.3) < 0.02 }, 2000)
            var y = slider.height / 2
            mousePress(slider, slider.width * 0.3, y)
            mouseMove(slider, slider.width * 0.85, y)
            mouseRelease(slider, slider.width * 0.85, y)
            verify(slider.value > 0.45, "dragging the handle right raised the value to " + slider.value.toFixed(2))
            fuzzyCompare(root.glassOpacity, slider.value, 0.001, "onMoved committed the dragged value to the bound sink")
            // [S2] rebind: an external push still moves the handle after the drag.
            root.glassOpacity = 0.15
            tryVerify(function () { return Math.abs(slider.value - 0.15) < 0.02 }, 2000)
        }

        function test_update_check_switch_writes_store() {
            var sw = switchForLabel("Check for updates")
            verify(sw !== null, "found the update-check switch")
            compare(sw.checked, false, "off by default (zero-egress default)")
            clickTarget(sw)
            compare(store.appearance().updateCheck, true, "toggling writes updateCheck to the store")
            clickTarget(sw)
            compare(store.appearance().updateCheck === true, false, "…and back off")
        }

        function test_hub_navigation_switch_controls_immersive_mode() {
            store.setAppearance("hubControlsMode", "standard")
            var sw = switchForLabel("Show Hub navigation bar")
            verify(sw !== null, "the Hub exposes its immersive-mode control")
            compare(sw.checked, true, "the navigation bar is on by default")
            clickTarget(sw)
            compare(store.appearance().hubControlsMode, "immersive",
                    "turning it off persists immersive Hub mode")
            clickTarget(sw)
            compare(store.appearance().hubControlsMode, "standard", "the bar can be restored")
        }

        // ── Toggles: glow / animated background / reduce motion ──────────────
        function switchForLabel(labelText) {
            var t = findText(panel, labelText)
            if (!t) return null
            var rowKids = t.parent.children
            for (var i = 0; i < rowKids.length; i++)
                if (rowKids[i].checked !== undefined && rowKids[i].checkable !== undefined) return rowKids[i]
            return null
        }

        function test_reduce_motion_toggle_writes() {
            var sw = switchForLabel("Reduce motion")
            verify(sw !== null, "found the reduce-motion switch")
            compare(sw.checked, false, "reflects reduceMotion=false")
            clickTarget(sw)
            compare(root.reduceMotion, true, "toggling writes root.reduceMotion")
            compare(sw.checked, true, "the switch re-reflects the source after re-binding")
        }

        function test_glow_toggle_writes() {
            var sw = switchForLabel("Accent glow")
            verify(sw !== null, "found the accent-glow switch")
            compare(sw.checked, true, "reflects showWidgetGlow=true")
            clickTarget(sw)
            compare(root.showWidgetGlow, false, "toggling writes root.showWidgetGlow")
        }

        function test_animated_background_toggle_writes() {
            var sw = switchForLabel("Animated background")
            verify(sw !== null, "found the animated-background switch")
            clickTarget(sw)
            compare(root.animatedBackground, false, "toggling writes root.animatedBackground")
        }

        // The auto-cycle dwell. Unlike the switches above this writes straight to
        // the store (it is a persisted appearance key, not a `root` alias), so the
        // assertion is on what the document ends up holding.
        function findObjectName(node, name) {
            return findPred(panel, function (n) { return n.objectName === name })
        }

        function test_cycle_combo_offers_the_ladder_and_defaults_to_off() {
            var combo = findObjectName(panel, "pageCycleCombo")
            verify(combo !== null, "found the cycle dwell selector")
            compare(combo.count, 7, "off plus six dwell choices")
            compare(combo.currentIndex, 0, "a fresh document does not cycle")
            compare(store.appearance().pageCycleSec, 0,
                    "a normalised document carries the key explicitly set to off, "
                    + "the same way hubControlsMode does")
            var secs = []
            for (var i = 0; i < combo.count; i++) secs.push(combo.model[i].secs)
            compare(JSON.stringify(secs), JSON.stringify(store.pageCycleChoices),
                    "the control offers exactly the ladder the store accepts - a "
                    + "choice the store coerces to 0 would be a dead menu entry")
        }

        function test_cycle_combo_writes_the_selected_dwell() {
            var combo = findObjectName(panel, "pageCycleCombo")
            combo.currentIndex = 3
            combo.activated(3)
            compare(store.appearance().pageCycleSec, 60, "selecting writes through")
            compare(combo.currentIndex, 3, "and the control keeps showing it")

            // External change must still move the control: `onActivated` reasserts
            // the binding it severs, the same trap the glass slider documents.
            store.setAppearance("pageCycleSec", 300)
            compare(combo.currentIndex, 6,
                    "the selector still follows the store after being used")
        }
    }
}
