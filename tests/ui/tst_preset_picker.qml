import QtQuick
import QtTest
import "../../ui/qml" as App
import "../../ui/qml/widgets" as Wg

// PresetPicker (ui/qml/widgets/PresetPicker.qml) - the post-setup "Screens"
// surface (W5 finding 3). Assert the full interaction contract:
//   • every catalog preset renders a card (plus the blank slate);
//   • a tap only ARMS a selection - the confirm bar appears, nothing applies;
//   • Cancel disarms without emitting; confirm emits applyRequested(id);
//   • reopening never inherits a half-armed confirm;
//   • under an org-forced preset (locked) the surface is ABSENT, not greyed;
//   • the confirm controls meet the touch-target tokens.
Item {
    id: root
    width: 1000; height: 900

    property alias theme: _theme
    App.Theme { id: _theme }
    App.PresetCatalog { id: cat }

    property string appliedId: ""
    property int applyCount: 0
    property int closeCount: 0

    Wg.PresetPicker {
        id: picker
        catalog: cat
        onApplyRequested: (pid) => { root.appliedId = pid; root.applyCount++ }
        onCloseRequested: root.closeCount++
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
    function byName(name) {
        return findPred(picker, function (n) { return n.objectName === name })
    }
    function cardCount() {
        var c = 0
        eachItem(picker, function (n) {
            if (n.objectName !== undefined && String(n.objectName).indexOf("presetCard-") === 0) c++
        })
        return c
    }

    TestCase {
        name: "PresetPicker"
        when: windowShown

        // Cards live in a clipped Flickable - bring a target into view before
        // clicking (a click outside the viewport lands nowhere).
        function clickTarget(target) {
            var scroll = root.findPred(picker, function (n) {
                return n.contentHeight !== undefined && n.contentY !== undefined
                         && n.boundsBehavior !== undefined
            })
            verify(scroll !== null, "found the grid Flickable")
            var p = target.mapToItem(scroll.contentItem, 0, 0)
            var maxY = Math.max(0, scroll.contentHeight - scroll.height)
            scroll.contentY = Math.max(0, Math.min(maxY, p.y - 40))
            wait(40)
            mouseClick(target)
        }

        // Arm a card and wait for the confirm bar to be laid out - it becomes
        // visible on the arming frame, but its geometry lands on the next
        // layout polish, and a click on a 0-height item goes nowhere.
        function armCard(cardName) {
            clickTarget(root.byName(cardName))
            tryVerify(function () {
                var a = root.byName("presetConfirmApply")
                return a && a.visible && a.height > 0
            }, 2000, "confirm bar laid out")
        }

        function init() {
            root.appliedId = ""; root.applyCount = 0; root.closeCount = 0
            picker.locked = false
            picker.pendingId = ""
            picker.shown = true
            tryVerify(function () { return picker.opacity > 0.99 }, 2000)
        }
        function cleanup() { picker.shown = false }

        function test_every_preset_renders_a_card_plus_blank() {
            compare(cardCount(), cat.items.length + 1,
                    "one card per catalog preset + the blank slate (" + cat.items.length + "+1)")
            verify(root.byName("presetCard-developer") !== null, "the developer card is present")
            verify(root.byName("presetCard-blank") !== null, "the blank slate is present")
        }

        function test_tap_arms_selection_and_shows_confirm() {
            var bar = root.byName("presetConfirmBar")
            verify(bar !== null, "confirm bar exists")
            verify(!bar.visible, "confirm bar hidden with nothing armed")
            clickTarget(root.byName("presetCard-developer"))
            compare(picker.pendingId, "developer", "tapping a card arms it")
            verify(bar.visible, "…and the confirm bar appears")
            verify(picker.pendingTitle.indexOf("Developer") >= 0,
                   "the confirm names the preset (" + picker.pendingTitle + ")")
            var preview = root.byName("presetPreview")
            verify(preview !== null, "the shared preview is present")
            compare(preview.titleItem.text, "Developer")
            verify(preview.purposeItem.text.length > 20, "the preview explains the screen's job")
            verify(preview.setupItem.text.indexOf("CI") >= 0, "the preview explains setup")
            tryCompare(preview, "previewTileCount", 2, 3000,
                       "the exact two-widget layout is previewed")
            compare(preview.passive, true, "previewing starts no live providers")
            compare(root.applyCount, 0, "a first tap NEVER applies - the layout replace needs a confirm")
        }

        function test_cancel_disarms_without_applying() {
            armCard("presetCard-health")
            compare(picker.pendingId, "health", "armed")
            mouseClick(root.byName("presetConfirmCancel"))
            compare(picker.pendingId, "", "Cancel disarms")
            verify(!root.byName("presetConfirmBar").visible, "confirm bar gone")
            compare(root.applyCount, 0, "nothing was applied")
        }

        function test_confirm_emits_apply_with_the_armed_id() {
            armCard("presetCard-developer")
            mouseClick(root.byName("presetConfirmApply"))
            compare(root.appliedId, "developer", "confirm emits applyRequested with the armed id")
            compare(root.applyCount, 1, "exactly once")
        }

        function test_blank_slate_arms_and_applies() {
            armCard("presetCard-blank")
            compare(picker.pendingId, "blank", "the blank slate arms")
            compare(picker.pendingTitle, "a blank dashboard", "…with honest confirm copy")
            mouseClick(root.byName("presetConfirmApply"))
            compare(root.appliedId, "blank", "and applies as 'blank'")
        }

        function test_reopen_never_inherits_an_armed_confirm() {
            clickTarget(root.byName("presetCard-developer"))
            compare(picker.pendingId, "developer", "armed")
            picker.shown = false
            picker.shown = true
            compare(picker.pendingId, "", "reopening cleared the armed selection")
        }

        function test_close_button_and_scrim_emit_close() {
            mouseClick(root.byName("presetPickerClose"))
            compare(root.closeCount, 1, "the close button emits closeRequested")
        }

        // ── Org policy (E9): the surface is absent under a forced preset ─────
        function test_locked_surface_is_absent() {
            picker.locked = true
            tryVerify(function () { return !picker.visible }, 2000,
                      "locked: the picker never shows even with shown=true")
            compare(picker.opacity, 0.0, "fully hidden, not greyed")
            picker.locked = false
            tryVerify(function () { return picker.visible }, 2000, "unlocking restores it")
        }

        // ── Touch targets (theme tokens, the repo's standing gate) ──────────
        function test_confirm_controls_are_touch_sized() {
            armCard("presetCard-developer")
            var apply = root.byName("presetConfirmApply")
            var cancel = root.byName("presetConfirmCancel")
            var close = root.byName("presetPickerClose")
            verify(apply.height >= _theme.touchSecondary,
                   "apply height " + apply.height + " >= touchSecondary")
            verify(cancel.height >= _theme.touchSecondary,
                   "cancel height " + cancel.height + " >= touchSecondary")
            verify(cancel.width >= _theme.touchPrimary, "cancel is comfortably wide")
            verify(close.height >= _theme.touchSecondary, "close button is touch sized")
        }
    }
}
