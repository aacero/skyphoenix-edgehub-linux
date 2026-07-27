import QtQuick
import QtTest
import "../ui" as UI
import "GuiUtil.js" as G

// Keep this resize matrix in its own process. Qt 6.11 can corrupt its QV4
// property cache when several large dynamic widget matrices share one runner.
Item {
    id: root
    width: 1400
    height: 1300

    UI.WidgetHarness {
        id: wh
        width: 696
        height: 612
        widgetFile: "NotesWidget.qml"
    }

    TestCase {
        name: "GuiWNotesSizes"
        when: windowShown
        visible: true

        function test_sizes_data() {
            return [
                { tag: "portrait-0.5x0.5",  cls: "compact", w: 348,  h: 409 },
                { tag: "landscape-0.5x0.5", cls: "compact", w: 423,  h: 306 },
                { tag: "portrait-0.5x1",    cls: "tall",    w: 348,  h: 818 },
                { tag: "landscape-0.5x1",   cls: "wide",    w: 846,  h: 306 },
                { tag: "portrait-1x0.5",    cls: "wide",    w: 696,  h: 409 },
                { tag: "landscape-1x0.5",   cls: "tall",    w: 423,  h: 612 },
                { tag: "portrait-1x1",      cls: "compact", w: 696,  h: 818 },
                { tag: "landscape-1x1",     cls: "compact", w: 846,  h: 612 },
                { tag: "portrait-1x1.5",    cls: "tall",    w: 696,  h: 1226 },
                { tag: "landscape-1x1.5",   cls: "wide",    w: 1268, h: 612 },
                { tag: "portrait-1x2",      cls: "large",   w: 696,  h: 1635 },
                { tag: "landscape-1x2",     cls: "large",   w: 1691, h: 612 },
                { tag: "portrait-1x3",      cls: "large",   w: 696,  h: 2452 },
                { tag: "landscape-1x3",     cls: "large",   w: 2536, h: 612 }
            ]
        }

        function test_sizes(row) {
            tryVerify(function () { return wh.ready }, 6000)
            wh.storeCtl.resetSettings(wh.instanceId, {})
            var paragraph = "Release checklist\n\nVerify the display rotation on the real Hub. "
                          + "Review each widget at every supported size. Confirm the Manager preview "
                          + "matches the Hub, then capture screenshots and document the result.\n\n"
            wh.storeCtl.patchSettings(wh.instanceId, {
                text: paragraph + paragraph + paragraph + paragraph + paragraph + paragraph
            })
            root.width = Math.max(1400, row.w)
            root.height = Math.max(1300, row.h)
            wh.width = row.w
            wh.height = row.h
            wh.item.sizeClass = row.cls
            wait(220)

            var img = grabImage(wh)
            img.save("gui-evidence/foc_notes_size_" + row.tag + ".png")
            verify(G.looksRendered(img), "notes " + row.tag + " renders content")
            compare(wh.item.width, row.w, "notes " + row.tag + " width")
            compare(wh.item.height, row.h, "notes " + row.tag + " height")
            var preview = G.byObjName(wh.item, "notesPreviewText")
            verify(preview !== null && preview.visible, "note body preview is visible")
            verify(preview.font.pixelSize >= wh.theme.fontTitle,
                   "note body uses the reading-size floor")
            var meta = G.byObjName(wh.item, "notesPreviewMeta")
            verify(meta !== null, "note metadata exists")
            compare(meta.visible, false,
                    "a long note spends every available line on content")
        }

        function test_short_note_shows_a_discoverable_edit_hint() {
            tryVerify(function () { return wh.ready }, 6000)
            wh.expanded = false
            wh.width = 696
            wh.height = 818
            wh.item.sizeClass = "compact"
            wh.storeCtl.patchSettings(wh.instanceId, {
                text: "Call Ana about the March invoice."
            })
            wait(180)
            var meta = G.byObjName(wh.item, "notesPreviewMeta")
            verify(meta !== null && meta.visible,
                   "short roomy note shows useful metadata")
            verify(G.byText(meta, "Tap anywhere to edit") !== null,
                   "edit mode is discoverable")
            grabImage(wh).save("gui-evidence/foc_notes_short_edit_hint.png")
        }

        function test_expanded_editor_has_a_non_overlapping_footer() {
            tryVerify(function () { return wh.ready }, 6000)
            wh.width = 800
            wh.height = 680
            wh.expanded = true
            wh.item.sizeClass = "full"
            wh.storeCtl.patchSettings(wh.instanceId, {
                text: "Review the release checklist and record the final findings."
            })
            wait(180)
            var footer = G.byObjName(wh.item, "notesEditorFooter")
            var editor = G.findPred(wh.item, function (n) {
                return n && n.persistentSelection !== undefined
            })
            var flick = G.byObjName(wh.item, "notesEditorViewport")
            verify(footer && footer.visible && editor && flick)
            verify(editor.font.pixelSize >= wh.theme.fontTitle,
                   "expanded editor keeps the reading-size floor")
            verify(flick.y + flick.height <= footer.y + 0.51,
                   "footer does not cover the note")
            grabImage(wh).save("gui-evidence/foc_notes_expanded_editor.png")
            wh.expanded = false
        }
    }
}
