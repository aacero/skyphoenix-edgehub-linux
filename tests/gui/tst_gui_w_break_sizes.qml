import QtQuick
import QtTest
import "../ui" as UI
import "GuiUtil.js" as G

// Keep this resize matrix in its own process. Qt 6.11 can corrupt its QV4
// property cache when several large dynamic widget matrices share one runner.
Item {
    id: root
    width: 1400
    height: 900

    UI.WidgetHarness {
        id: wh
        width: 696
        height: 612
        widgetFile: "BreakWidget.qml"
    }

    function livePill(label) {
        return G.findPred(wh.item, function (n) {
            try {
                return n && n.label !== undefined && n.glyph !== undefined
                       && n.clicked !== undefined && G.isLive(n)
                       && ("" + n.label) === label
            } catch (e) {
                return false
            }
        })
    }

    function ringProgress() {
        return G.findPred(wh.item, function (n) {
            try {
                return n && n.progressColor !== undefined && n.value !== undefined
                       && G.isLive(n)
            } catch (e) {
                return false
            }
        })
    }

    TestCase {
        name: "GuiWBreakSizes"
        when: windowShown
        visible: true

        function test_sizes_data() {
            return [
                { tag: "portrait-0.5x0.5",  cls: "compact", w: 348, h: 409 },
                { tag: "landscape-0.5x0.5", cls: "compact", w: 423, h: 306 },
                { tag: "portrait-0.5x1",    cls: "tall",    w: 348, h: 818 },
                { tag: "landscape-0.5x1",   cls: "wide",    w: 846, h: 306 },
                { tag: "portrait-1x0.5",    cls: "wide",    w: 696, h: 409 },
                { tag: "landscape-1x0.5",   cls: "tall",    w: 423, h: 612 },
                { tag: "portrait-1x1",      cls: "compact", w: 696, h: 818 },
                { tag: "landscape-1x1",     cls: "compact", w: 846, h: 612 }
            ]
        }

        function test_sizes(row) {
            tryVerify(function () { return wh.ready }, 6000)
            wh.storeCtl.resetSettings(wh.instanceId, {})
            wh.storeCtl.patchSettings(wh.instanceId, {
                intervalMin: 30, running: false, endEpoch: 0,
                pausedRemaining: 1500, due: false, breaksToday: 3,
                day: Qt.formatDate(new Date(), "yyyy-MM-dd"),
                workStartHour: 9, workEndHour: 17
            })
            root.width = Math.max(1400, row.w)
            root.height = Math.max(900, row.h)
            wh.width = row.w
            wh.height = row.h
            wh.item.sizeClass = row.cls
            wait(220)

            var img = grabImage(wh)
            img.save("gui-evidence/foc_break_size_" + row.tag + ".png")
            verify(G.looksRendered(img), "break " + row.tag + " renders content")
            compare(wh.item.width, row.w, "break " + row.tag + " width")
            compare(wh.item.height, row.h, "break " + row.tag + " height")
            verify(root.ringProgress() !== null, "break interval ring is visible")
            var details = G.byObjName(wh.item, "breakDetails")
            verify(details !== null, "break context card exists")
            compare(details.visible, row.tag.indexOf("1x1") >= 0,
                    "1x1 earns rhythm, schedule and today context")
            compare(root.livePill("Resume") !== null,
                    row.tag.indexOf("0.5x0.5") < 0,
                    "non-micro break tiles expose timer controls")
            if (row.tag.indexOf("0.5x0.5") < 0) {
                var controls = G.byObjName(wh.item, "breakTileControls")
                verify(controls !== null && controls.visible,
                       "break controls are visible at " + row.tag)
                var p = controls.mapToItem(wh.item, 0, 0)
                verify(p.x >= -0.5 && p.y >= -0.5
                       && p.x + controls.width <= wh.item.width + 0.5
                       && p.y + controls.height <= wh.item.height + 0.5,
                       "break controls stay inside " + row.tag + " ("
                       + Math.round(p.x) + "," + Math.round(p.y) + " "
                       + Math.round(controls.width) + "x" + Math.round(controls.height)
                       + " in " + row.w + "x" + row.h + ")")
            }
        }

        // Every weekday EXCEPT today. Used by the "outside" row so the widget is
        // genuinely outside its active hours instead of merely being seeded that
        // way - see the row itself.
        function daysExceptToday() {
            var today = new Date().getDay()
            var days = []
            for (var i = 0; i < 7; i++) if (i !== today) days.push(i)
            return days.join(",")
        }

        function test_states_data() {
            return [
                { tag: "running", state: "Running",
                  patch: { running: true, due: false, snoozed: false,
                           scheduleSuspended: false, endEpoch: Date.now() + 900000 } },
                { tag: "paused", state: "Paused",
                  patch: { running: false, due: false, snoozed: false,
                           scheduleSuspended: false, pausedRemaining: 900 } },
                { tag: "snoozed", state: "Snoozed",
                  patch: { running: true, due: false, snoozed: true,
                           scheduleSuspended: false, endEpoch: Date.now() + 300000 } },
                // The schedule must genuinely EXCLUDE today, not merely be seeded
                // suspended. The default patch below opens every weekday, so a
                // row that only set `scheduleSuspended: true` was asserting a
                // state the product actively contradicts: BreakWidget's own 1s
                // timer calls applyScheduleState(), sees that we ARE inside
                // active hours, and correctly clears the flag. The assertion
                // then passed or failed purely on whether it beat that timer -
                // and it lost on a CI runner (run 30761207111). Excluding today
                // makes withinSchedule() false, so the product KEEPS the flag
                // and the state is stable by construction.
                { tag: "outside", state: "Outside active hours",
                  patch: { running: true, due: false, snoozed: false,
                           workDays: daysExceptToday(),
                           scheduleSuspended: true, endEpoch: 0, pausedRemaining: 900 } },
                { tag: "disabled", state: "Schedule disabled",
                  patch: { running: true, due: false, workDays: "",
                           scheduleSuspended: true, endEpoch: 0, pausedRemaining: 900 } },
                { tag: "due", state: "Break due",
                  patch: { running: true, due: true, snoozed: false,
                           scheduleSuspended: false, pausedRemaining: 900 } }
            ]
        }

        function test_states(row) {
            tryVerify(function () { return wh.ready }, 6000)
            wh.storeCtl.resetSettings(wh.instanceId, {})
            var patch = {
                intervalMin: 30,
                workStartHour: 0,
                workEndHour: 0,
                workDays: "0,1,2,3,4,5,6"
            }
            for (var key in row.patch) patch[key] = row.patch[key]
            wh.storeCtl.patchSettings(wh.instanceId, patch)
            wh.width = 696
            wh.height = 612
            wh.item.sizeClass = "compact"
            wait(220)
            compare(wh.item.stateLabel, row.state,
                    row.tag + " has an explicit state")
            var img = grabImage(wh)
            img.save("gui-evidence/foc_break_state_" + row.tag + ".png")
            verify(G.looksRendered(img), row.tag + " state renders")
            if (row.tag === "due")
                verify(root.livePill("Done") !== null,
                       "due state retains a reachable acknowledgement")
            else {
                var description = G.byObjName(wh.item, "breakStateDescription")
                verify(description !== null && description.visible,
                       row.tag + " description is visible")
                verify(description.font.pixelSize >= 18,
                       row.tag + " description remains readable")
            }
        }
    }
}
