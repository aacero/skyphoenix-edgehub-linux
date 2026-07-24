import QtQuick
import QtTest
import "../ui" as UI
import "GuiUtil.js" as G

// Habit size rendering has its own process because Qt 6.11's QV4 engine crashes
// when this resize matrix follows the much larger Break interaction matrix in
// the same qmltestrunner process. Each matrix passes independently, so keeping
// the process boundary preserves all rendered-pixel checks without blacklisting.
Item {
    id: root
    width: 1400
    height: 1300

    UI.WidgetHarness {
        id: wh
        width: 696
        height: 612
        widgetFile: "HabitWidget.qml"
    }

    function heatCells() {
        var raw = G.collectPred(wh.item, function (n) {
            try { return n && n.dk !== undefined && G.isLive(n) }
            catch (e) { return false }
        })
        var out = []
        for (var i = 0; i < raw.length; i++)
            if (out.indexOf(raw[i]) < 0) out.push(raw[i])
        return out
    }

    TestCase {
        name: "GuiWHabitSizes"
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
                { tag: "landscape-1x1.5",   cls: "wide",    w: 1268, h: 612 }
            ]
        }

        function test_sizes(row) {
            tryVerify(function () { return wh.ready }, 6000)
            wh.storeCtl.resetSettings(wh.instanceId, {})
            var checkins = []
            var day = new Date(); day.setHours(12, 0, 0, 0)
            for (var i = 0; i < 28; i++) {
                if (i < 7 || i % 3 !== 0) checkins.push(Qt.formatDate(day, "yyyy-MM-dd"))
                day.setDate(day.getDate() - 1)
            }
            wh.storeCtl.patchSettings(wh.instanceId, {
                name: "Daily walk", streak: 7, lastCheckinDay: wh.item.todayKey,
                checkins: checkins, bestStreak: 21
            })
            wh.width = row.w
            wh.height = row.h
            wh.item.sizeClass = row.cls
            wait(220)
            var img = grabImage(wh)
            img.save("gui-evidence/foc_habit_size_" + row.tag + ".png")
            verify(G.looksRendered(img), "habit " + row.tag + " renders content")
            compare(wh.item.width, row.w, "habit " + row.tag + " width")
            compare(wh.item.height, row.h, "habit " + row.tag + " height")
            compare(root.heatCells().length, row.tag.indexOf("0.5x0.5") >= 0 ? 0 : 28,
                    "every non-micro size renders the complete 28-day history")
            var insight = G.byObjName(wh.item, "habitInsightPanel")
            verify(insight !== null, "habit insight panel exists")
            compare(insight.visible, row.tag.indexOf("1x1.5") >= 0,
                    "1x1.5 earns consistency and next-goal insights")
        }
    }
}
