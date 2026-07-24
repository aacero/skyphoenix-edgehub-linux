import QtQuick
import QtTest
import "../../ui/qml" as App

// FirstRunWizard (ui/qml/FirstRunWizard.qml) - the setup flow. It resolves
// `theme`, `_screens`, `root` (themeMode/accentName) and `wizardBridge` by name,
// so we provide them here. Assert: next/back stepping, the display-selection
// required-field guard, the skip path (no displays), and the completion path
// through wizardBridge.completeWizard (success + failure messaging).
Item {
    id: root
    width: 800; height: 1000

    property alias theme: _theme
    App.Theme { id: _theme }

    // Globals the wizard reads unqualified.
    property string themeMode: "dark"
    property string accentName: "blue"
    property string _screens: "[]"

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

    // Anchored HERE, at the use site: the component no longer anchors itself
    // (it is a StackView page in the product, and self-anchoring conflicted
    // with StackView's own sizing). This root is a plain Item, so it must
    // give the item a size or every click lands on a 0x0 target.
    App.FirstRunWizard { id: wiz; anchors.fill: parent }

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
    function findButton(str) {
        return findPred(wiz, function (n) { return n.text === str && n.checkable !== undefined })
    }

    TestCase {
        name: "FirstRunWizard"
        when: windowShown

        function init() {
            wiz.currentStep = 0
            wiz.selectedScreen = null
            wiz.selectedLayout = "productivity"
            wiz.finishError = ""
            root._screens = "[]"
            wizardBridge.calls = 0
            wizardBridge.nextResult = true
            // Layout visibility changes are polished on the next event-loop
            // turn. Wait before hit-testing the newly visible step controls.
            wait(16)
        }

        // ── Screens parsing ──────────────────────────────────────────────────
        function test_screens_parse_from_context() {
            root._screens = JSON.stringify([ { name: "DP-3", model: "XENEON EDGE", likelyXeneonEdge: true,
                manufacturer: "Corsair", size: { width: 720, height: 2560 } } ])
            compare(wiz.screensList.length, 1, "the wizard parses the detected screens")
            root._screens = "[bad json"
            compare(wiz.screensList.length, 0, "malformed _screens is guarded to an empty list")
        }

        // ── Next / Back stepping ─────────────────────────────────────────────
        function test_next_advances_step() {
            var next = findButton("Get Started →")
            verify(next !== null, "step-0 primary button present")
            mouseClick(next)
            compare(wiz.currentStep, 1, "Get Started advances to step 1")
        }

        function test_back_decrements_step() {
            wiz.currentStep = 2
            var back = findButton("← Back")
            verify(back !== null, "Back button visible past step 0")
            mouseClick(back)
            compare(wiz.currentStep, 1, "Back returns to the previous step")
        }

        function test_back_hidden_on_first_step() {
            wiz.currentStep = 0
            var back = findButton("← Back")
            verify(back === null || !back.visible, "Back is hidden on the welcome step")
        }

        // ── Required-field guard (display selection) ─────────────────────────
        function test_display_selection_required_when_screens_present() {
            root._screens = JSON.stringify([ { name: "DP-1", model: "Generic",
                size: { width: 1920, height: 1080 } } ])
            wiz.currentStep = 1
            wiz.selectedScreen = null
            compare(wiz.canAdvance, false, "cannot advance step 1 without picking a display")
            var next = findButton("Next →")
            verify(next !== null, "Next button present on step 1")
            verify(!next.enabled, "the Next button is disabled until a display is chosen")
        }

        function test_selecting_display_enables_advance() {
            root._screens = JSON.stringify([ { name: "DP-1", model: "Generic",
                size: { width: 1920, height: 1080 } } ])
            wiz.currentStep = 1
            wait(80)                       // let the ListView delegate lay out before hit-testing
            var selectBtn = findButton("Select")
            verify(selectBtn !== null, "a Select button is rendered for the display")
            mouseClick(selectBtn)
            verify(wiz.selectedScreen !== null, "tapping Select picks the display")
            compare(wiz.canAdvance, true, "advancing is enabled once a display is picked")
        }

        // ── Skip path (no displays detected) ─────────────────────────────────
        function test_skip_path_with_no_displays() {
            root._screens = "[]"
            wiz.currentStep = 1
            wiz.selectedScreen = null
            compare(wiz.canAdvance, true,
                    "with no displays detected the user can continue (no hard dead-end)")
        }

        function test_layout_selection_previews_purpose_setup_and_tiles() {
            wiz.currentStep = 2
            wiz.selectedLayout = "gaming"
            wait(30)
            var preview = findPred(wiz, function (n) {
                return n && n.objectName === "wizardPresetPreview"
            })
            verify(preview !== null, "the starter-layout step contains the shared preview")
            compare(preview.titleItem.text, "Gaming Cockpit")
            verify(preview.purposeItem.text.indexOf("graphics card") >= 0)
            verify(preview.setupItem.text.indexOf("Linux telemetry") >= 0)
            compare(preview.previewTileCount, 3)
            compare(preview.passive, true)
        }

        // ── Completion path ──────────────────────────────────────────────────
        function test_finish_calls_bridge_with_choices() {
            wiz.currentStep = 3
            wiz.selectedLayout = "gaming"
            wizardBridge.nextResult = true
            var finish = findButton("Finish Setup")
            verify(finish !== null, "Finish button present on the last step")
            mouseClick(finish)
            compare(wizardBridge.calls, 1, "completeWizard is called once")
            compare(wizardBridge.lastArgs.layout, "gaming", "the chosen layout is passed through")
            compare(wizardBridge.lastArgs.autostart, true, "the autostart choice (default on) is passed")
        }

        function test_finish_success_without_stackview_reports_open_error() {
            wiz.currentStep = 3
            wizardBridge.nextResult = true
            mouseClick(findButton("Finish Setup"))
            // Saved OK, but there is no StackView in the test host to navigate.
            verify(wiz.finishError.indexOf("couldn't open") >= 0,
                   "a saved-but-unnavigable finish surfaces the open error, not a silent hang")
        }

        function test_finish_failure_surfaces_error() {
            wiz.currentStep = 3
            wizardBridge.nextResult = false
            wiz.finishError = ""
            mouseClick(findButton("Finish Setup"))
            verify(wiz.finishError.indexOf("Couldn't save") >= 0,
                   "a failed save surfaces an error to the user (not just a console log)")
        }

        // ── Step indicators reflect the current step ─────────────────────────
        function test_step_count_is_four() {
            // The step-indicator Repeater renders one dot per step (model: 4).
            // Read the REAL Repeater's count - this fails if the flow ever becomes
            // a 3- or 7-step wizard, unlike a self-referential currentStep round-trip.
            var dots = findPred(wiz, function (n) {
                return n && typeof n.itemAt === "function"
                       && n.count === 4 && n.model === 4 })
            verify(dots !== null, "found the step-indicator Repeater")
            compare(dots.count, 4, "four step-indicator dots (welcome, display, layout, options)")

            // The primary button reads the finish label ONLY on the final step
            // (index 3) and "Next →" before it - pinning the last-step index at 3.
            wiz.currentStep = 2
            verify(findButton("Next →") !== null, "step 2 shows 'Next →'")
            verify(findButton("Finish Setup") === null, "finish label absent before the last step")
            wiz.currentStep = 3
            verify(findButton("Finish Setup") !== null, "the last step (index 3) shows 'Finish Setup'")
            verify(findButton("Next →") === null, "no 'Next →' on the last step")
        }
    }
}
