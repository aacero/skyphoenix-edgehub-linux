import QtQuick
import QtTest
import "../ui" as UI
import "GuiUtil.js" as G

// ─────────────────────────────────────────────────────────────────────────
// Visible GUI tests for the three "focus/health" Hub widgets: Meds, Braindump,
// Routine. Each is hosted in a REAL KWin-composited window via UI.WidgetHarness
// and driven with real mouse/keyboard events. Every case asserts an OBJECTIVE,
// GUI-observable outcome: item.visible, geometry (mapped x/y ordering), on-screen
// text, a store setting reflected in the visible output, or grabImage() pixels.
//
// Deterministic seams used (never wall-clock):
//   • meds  - nowMinsOverride (minutes since midnight) pins due/later/open.
//   • all   - schedule/steps/entries/taken/done seeded via storeCtl before assert.
//   • sizeClass is PINNED per case (the Dashboard injects it from the tile span).
//
// Case count: 32 meds + 26 routine + 27 braindump = 85.
// ─────────────────────────────────────────────────────────────────────────
Item {
    id: root
    width: 1300; height: 720

    UI.WidgetHarness {
        id: wh
        anchors.left: parent.left; anchors.top: parent.top
        width: 680; height: 640
        widgetFile: ""
    }

    TestCase {
        name: "GuiWFocusHealth"
        when: windowShown
        visible: true

        // ── evidence ──────────────────────────────────────────────────────
        function snap(item, n) {
            var img = grabImage(item)
            img.save("gui-evidence/fh_" + n + ".png")
            return img
        }

        // ── shared helpers ────────────────────────────────────────────────
        property string iid: "test-instance"

        // Load a widget file + pin geometry/size-class + reset per-instance seams.
        function prep(file, w, h, sc) {
            root.width = Math.max(1300, w)
            root.height = Math.max(720, h)
            wh.expanded = false
            if (wh.widgetFile !== file) {
                wh.widgetFile = file
                tryVerify(function () { return wh.ready }, 6000, "widget " + file + " loaded")
            }
            wh.width = w; wh.height = h
            wh.item.sizeClass = sc
            wh.item.accentName = ""
            wh.item.cardBackdrop = "none"
            if (wh.item.hasOwnProperty("nowMinsOverride")) wh.item.nowMinsOverride = -1
            if (file === "RoutineWidget.qml")
                wh.storeCtl.patchSettings(iid,
                    { routineFormat: "legacy", routineItems: [] })
            wait(80)
        }

        function today() { return Qt.formatDate(new Date(), "yyyy-MM-dd") }
        function set(k, v) { wh.storeCtl.setSetting(iid, k, v) }
        function cfg() { return wh.storeCtl.settingsFor(iid) }

        // A visible Text whose text CONTAINS sub (case-insensitive).
        function seeText(sub) {
            var t = G.byText(wh.item, sub)
            return t !== null && t.visible
        }
        // Collect all visible on-screen text strings.
        function visTexts() {
            return G.collectPred(wh.item, function (n) {
                try { return n.text !== undefined && ("" + n.text).length > 0 && n.visible }
                catch (e) { return false }
            }).map(function (n) { return "" + n.text })
        }

        // Scan a grabbed image on a grid for any pixel within `tol` of `hex`.
        function hasColorNear(img, hex, tol, step) {
            step = step || 4
            var w = img.width, h = img.height
            for (var y = 1; y < h; y += step)
                for (var x = 1; x < w; x += step)
                    if (G.colorDist("" + img.pixel(x, y), hex) <= tol) return true
            return false
        }

        // Meds dose-row delegate by its key.
        function medRows() {
            return G.collectPred(wh.item, function (n) {
                try { return typeof n.st === "string" && n.modelData && n.modelData.key !== undefined }
                catch (e) { return false }
            })
        }
        function medRow(key) {
            var r = medRows()
            for (var i = 0; i < r.length; i++) if (r[i].modelData.key === key) return r[i]
            return null
        }
        // Routine step-row delegate by its step text.
        function stepRows() {
            return G.collectPred(wh.item, function (n) {
                try { return typeof n.done === "boolean" && n.modelData
                             && typeof n.modelData.text === "string" }
                catch (e) { return false }
            })
        }
        function stepRow(step) {
            var r = stepRows()
            for (var i = 0; i < r.length; i++) if (r[i].modelData.text === step) return r[i]
            return null
        }
        // Braindump entry-row delegates.
        function entryRows() {
            return G.collectPred(wh.item, function (n) {
                try { return n.index !== undefined && n.modelData && n.modelData.text !== undefined }
                catch (e) { return false }
            })
        }
        function entryRow(idx) {
            var r = entryRows()
            for (var i = 0; i < r.length; i++) if (r[i].index === idx) return r[i]
            return null
        }
        function pillByLabel(sub) {
            return G.findPred(wh.item, function (n) {
                try { return n.label !== undefined && n.primary !== undefined && n.clicked !== undefined
                             && ("" + n.label).indexOf(sub) >= 0 }
                catch (e) { return false }
            })
        }
        function pillByGlyph(g) {
            return G.findPred(wh.item, function (n) {
                try { return n.glyph !== undefined && n.clicked !== undefined && n.glyph === g }
                catch (e) { return false }
            })
        }
        function backdrop() {
            return G.findPred(wh.item, function (n) {
                try { return n.style !== undefined && n.accent !== undefined && n.running !== undefined }
                catch (e) { return false }
            })
        }
        function mapX(item) { return item.mapToItem(wh.item, 0, 0).x }
        function mapY(item) { return item.mapToItem(wh.item, 0, 0).y }

        function typeWord(field, word) {
            field.forceActiveFocus(); wait(40)
            for (var i = 0; i < word.length; i++) keyClick(word[i])
        }

        // ============================================================ MEDS ==

        function test_meds_01_sizes_data() {
            return [
                { tag: "portrait-0.5x1",   w: 348,  h: 818,  sc: "tall" },
                { tag: "landscape-0.5x1",  w: 846,  h: 306,  sc: "wide" },
                { tag: "portrait-1x0.5",   w: 696,  h: 409,  sc: "wide" },
                { tag: "landscape-1x0.5",  w: 423,  h: 612,  sc: "tall" },
                { tag: "portrait-1x1",     w: 696,  h: 818,  sc: "compact" },
                { tag: "landscape-1x1",    w: 846,  h: 612,  sc: "compact" },
                { tag: "portrait-1x1.5",   w: 696,  h: 1226, sc: "tall" },
                { tag: "landscape-1x1.5",  w: 1268, h: 612,  sc: "wide" },
                { tag: "portrait-1x2",     w: 696,  h: 1635, sc: "large" },
                { tag: "landscape-1x2",    w: 1691, h: 612,  sc: "large" }
            ]
        }
        function test_meds_01_sizes(r) {
            prep("MedsWidget.qml", r.w, r.h, r.sc)
            var doses = []
            for (var i = 0; i < 20; i++)
                doses.push((i < 10 ? "0" : "") + i + ":00 Dose " + (i + 1))
            var schedule = doses.join("\n")
            set("schedule", schedule)
            set("taken", [doses[8], doses[12]])
            set("takenDay", today())
            wh.item.nowMinsOverride = 12 * 60 + 15
            wait(120)
            var img = snap(wh.item, "meds_sz_" + r.tag)
            compare(wh.item.width, r.w, "meds cell width " + r.tag)
            compare(wh.item.height, r.h, "meds cell height " + r.tag)
            verify(G.looksRendered(img), "meds rendered content at " + r.tag)
            var list = G.byObjName(wh.item, "medsDoseList")
            verify(list !== null && list.height >= wh.item.rowH,
                   "at least one complete medication touch row fits")
            if (r.sc === "large")
                compare(wh.item.horiz, r.tag.indexOf("landscape") === 0,
                        "large medication layouts follow physical orientation")
            compare(wh.item.showFocus, r.tag.indexOf("landscape-0.5x1") === 0
                                      || r.tag.indexOf("portrait-1x0.5") === 0
                                      || r.tag.indexOf("landscape-1x1.5") === 0
                                      || r.tag.indexOf("landscape-1x2") === 0,
                    "wide projections expose a one-tap focused dose beside the schedule")
        }

        function test_meds_02_config_schedule_data() {
            return [ { tag: "two-doses" }, { tag: "cleared" } ]
        }
        function test_meds_02_config_schedule(r) {
            prep("MedsWidget.qml", 680, 640, "compact")
            set("taken", []); set("takenDay", "")
            if (r.tag === "two-doses") {
                set("schedule", "08:00 Vitamin D\n13:00 Ritalin"); wait(120)
                snap(wh.item, "meds_cf_schedule_two")
                compare(wh.item.doses.length, 2, "two dose rows parsed")
                verify(seeText("Vitamin D"), "first dose name shown")
                verify(seeText("Ritalin"), "second dose name shown")
            } else {
                set("schedule", ""); wait(120)
                snap(wh.item, "meds_cf_schedule_clear")
                compare(wh.item.doses.length, 0, "no dose rows when cleared")
                verify(seeText("Add"), "empty-state prompt shown when cleared")
            }
        }

        function test_meds_03_config_window_data() {
            // Dose 08:00 (480), now 08:30 (510) → 30 min past its time.
            return [
                { tag: "w15",  win: 15,  st: "open", label: "Not marked" },
                { tag: "w60",  win: 60,  st: "due",  label: "Due now" },
                { tag: "w240", win: 240, st: "due",  label: "Due now" }
            ]
        }
        function test_meds_03_config_window(r) {
            prep("MedsWidget.qml", 680, 640, "compact")
            set("schedule", "08:00 A"); set("taken", []); set("takenDay", "")
            set("dueWindowMin", r.win)
            wh.item.nowMinsOverride = 510
            wait(120)
            snap(wh.item, "meds_cf_window_" + r.tag)
            var row = medRow("08:00 A")
            verify(row !== null, "dose row present")
            compare(row.st, r.st, "state for window " + r.win)
            verify(seeText(r.label), "label '" + r.label + "' visible for window " + r.win)
        }

        function test_meds_04_states_data() {
            return [
                { tag: "empty" }, { tag: "list" }, { tag: "wide" }, { tag: "taken" },
                { tag: "due" }, { tag: "later" }, { tag: "open" }, { tag: "untimed" }
            ]
        }
        function test_meds_04_states(r) {
            if (r.tag === "empty") {
                prep("MedsWidget.qml", 680, 640, "compact")
                set("schedule", ""); set("taken", []); set("takenDay", ""); wait(120)
                snap(wh.item, "meds_st_empty")
                verify(seeText("Add"), "empty prompt")
                compare(wh.item.doses.length, 0, "no rows")
            } else if (r.tag === "list") {
                prep("MedsWidget.qml", 680, 640, "compact")
                set("schedule", "08:00 A\n13:00 B"); set("taken", []); set("takenDay", ""); wait(120)
                snap(wh.item, "meds_st_list")
                compare(wh.item.doses.length, 2, "two rows in the list")
            } else if (r.tag === "wide") {
                prep("MedsWidget.qml", 840, 400, "wide")
                set("schedule", "08:00 A\n13:00 B"); set("taken", []); set("takenDay", "")
                wh.item.nowMinsOverride = 490; wait(120)
                snap(wh.item, "meds_st_wide")
                var mark = pillByLabel("Mark taken")
                var row = medRow("13:00 B")
                verify(mark !== null, "focus 'Mark taken' pill shown in wide")
                verify(row !== null, "schedule still shown beside focus in wide")
                verify(mapX(mark) < mapX(row), "focus block sits left of schedule (beside)")
            } else if (r.tag === "taken") {
                prep("MedsWidget.qml", 680, 640, "compact")
                set("schedule", "08:00 A"); set("takenDay", today()); set("taken", ["08:00 A"]); wait(120)
                snap(wh.item, "meds_st_taken")
                compare(medRow("08:00 A").st, "taken", "row reads taken")
                verify(seeText("Taken"), "'Taken' label visible")
            } else if (r.tag === "due") {
                prep("MedsWidget.qml", 680, 640, "compact")
                set("schedule", "08:00 A"); set("taken", []); set("takenDay", ""); set("dueWindowMin", 60)
                wh.item.nowMinsOverride = 490; wait(120)
                snap(wh.item, "meds_st_due")
                compare(medRow("08:00 A").st, "due", "row reads due inside window")
                verify(seeText("Due now"), "'Due now' label visible")
            } else if (r.tag === "later") {
                prep("MedsWidget.qml", 680, 640, "compact")
                set("schedule", "08:00 A"); set("taken", []); set("takenDay", "")
                wh.item.nowMinsOverride = 400; wait(120)
                snap(wh.item, "meds_st_later")
                compare(medRow("08:00 A").st, "later", "row reads later before its time")
                verify(seeText("Later"), "'Later' label visible")
            } else if (r.tag === "open") {
                prep("MedsWidget.qml", 680, 640, "compact")
                set("schedule", "08:00 A"); set("taken", []); set("takenDay", ""); set("dueWindowMin", 60)
                wh.item.nowMinsOverride = 700; wait(120)
                var img = snap(wh.item, "meds_st_open")
                compare(medRow("08:00 A").st, "open", "row reads open past window")
                verify(seeText("Not marked"), "'Not marked' label visible")
                verify(!hasColorNear(img, "" + wh.theme.error, 60), "an un-marked dose is NEVER red")
            } else { // untimed
                prep("MedsWidget.qml", 680, 640, "compact")
                set("schedule", "Vitamins"); set("taken", []); set("takenDay", "")
                wh.item.nowMinsOverride = 700; wait(120)
                snap(wh.item, "meds_st_untimed")
                var ur = medRow("Vitamins")
                verify(ur !== null, "untimed dose still appears")
                verify(ur.st !== "due", "untimed dose is never 'due'")
                verify(seeText("-"), "untimed time renders as '-'")
            }
        }

        function test_meds_05_status() {
            prep("MedsWidget.qml", 680, 640, "compact")
            set("schedule", "08:00 A\n13:00 B"); set("takenDay", today()); set("taken", ["08:00 A"]); wait(120)
            snap(wh.item, "meds_status")
            compare(wh.item.status, "1/2", "taken-count status reflects 1 of 2")
            verify(seeText("1/2"), "status '1/2' rendered in header")
        }

        function test_meds_06_body_data() {
            return [ { tag: "explicit-action" }, { tag: "mark-pill" }, { tag: "undo-action" } ]
        }
        function test_meds_06_body(r) {
            if (r.tag === "explicit-action") {
                prep("MedsWidget.qml", 680, 640, "compact")
                set("schedule", "08:00 A\n13:00 B"); set("taken", []); set("takenDay", ""); wait(120)
                snap(wh.item, "meds_b_action_before")
                var action = G.byObjName(wh.item, "medsDoseAction-0")
                verify(action !== null, "explicit dose action present")
                mouseClick(action, action.width / 2, action.height / 2)
                wait(200)
                snap(wh.item, "meds_b_action_after")
                verify(cfg().taken.indexOf("08:00 A") >= 0, "action marked the dose taken in store")
                compare(medRow("08:00 A").st, "taken", "row visibly reads taken after action")
            } else if (r.tag === "mark-pill") {
                prep("MedsWidget.qml", 840, 400, "wide")
                set("schedule", "08:00 A\n13:00 B"); set("taken", []); set("takenDay", "")
                wh.item.nowMinsOverride = 490; wait(120)
                snap(wh.item, "meds_b_markpill_before")
                var pill = pillByLabel("Mark taken")
                verify(pill !== null, "Mark taken pill present")
                mouseClick(pill, pill.width / 2, pill.height / 2)
                wait(200)
                snap(wh.item, "meds_b_markpill_after")
                verify(cfg().taken.indexOf("08:00 A") >= 0, "pill marked the focus dose taken")
                // Focus advances to the next un-taken dose; the marked dose's
                // schedule row (shown beside the focus in wide) now reads taken.
                compare(medRow("08:00 A").st, "taken", "marked dose visibly reads taken")
            } else { // undo-action
                prep("MedsWidget.qml", 680, 640, "compact")
                set("schedule", "08:00 A"); set("takenDay", today()); set("taken", ["08:00 A"]); wait(120)
                compare(medRow("08:00 A").st, "taken", "row starts taken")
                var undoAction = G.byObjName(wh.item, "medsDoseAction-0")
                verify(undoAction !== null, "explicit undo action present")
                mouseClick(undoAction, undoAction.width / 2, undoAction.height / 2)
                wait(200)
                snap(wh.item, "meds_b_undo_after")
                compare(cfg().taken.length, 0, "undo action removed the taken mark")
                verify(medRow("08:00 A").st !== "taken", "row no longer reads taken")
            }
        }

        function test_meds_07_chrome_accent_data() {
            return [
                { tag: "override", accent: "red",  hex: "#F85149" },
                { tag: "auto",     accent: "",     hex: "" }        // hex filled at runtime
            ]
        }
        function test_meds_07_chrome_accent(r) {
            prep("MedsWidget.qml", 840, 400, "wide")
            set("schedule", "08:00 A\n13:00 B"); set("taken", []); set("takenDay", ""); set("dueWindowMin", 60)
            wh.item.nowMinsOverride = 490
            wh.item.accentName = r.accent
            wait(150)
            var img = snap(wh.item, "meds_chrome_" + r.tag)
            var target = r.tag === "auto" ? ("" + wh.theme.catServices) : r.hex
            if (r.tag === "auto")
                compare("" + wh.item.effAccent, "" + wh.theme.catServices, "Auto accent resolves to catServices")
            verify(hasColorNear(img, target, 70), "due dose renders in accent " + target)
        }

        function test_meds_08_backdrop_data() {
            return [ { s: "none" }, { s: "orbs" }, { s: "mesh" }, { s: "aurora" },
                     { s: "waves" }, { s: "stars" }, { s: "bokeh" }, { s: "grid" } ]
        }
        function test_meds_08_backdrop(r) {
            prep("MedsWidget.qml", 680, 640, "compact")
            set("schedule", "08:00 A\n13:00 B"); set("taken", []); set("takenDay", "")
            wh.item.cardBackdrop = r.s
            wait(140)
            var img = snap(wh.item, "meds_backdrop_" + r.s)
            var bl = backdrop()
            verify(bl !== null, "BackdropLayer present")
            compare(bl.visible, r.s !== "none", "backdrop '" + r.s + "' visibility")
            verify(G.looksRendered(img), "card still renders with backdrop " + r.s)
        }

        function test_meds_09_structured_recurrence_data() {
            return [
                { tag: "monday", day: 1, expected: "Monday dose" },
                { tag: "rest-day", day: 4, expected: "No doses scheduled today" }
            ]
        }
        function test_meds_09_structured_recurrence(r) {
            prep("MedsWidget.qml", 680, 640, "compact")
            set("scheduleFormat", "structured")
            set("scheduleItems", [
                { id: "mon", time: "08:00", name: "Monday dose", days: "1" },
                { id: "tue", time: "09:00", name: "Tuesday dose", days: "2" }
            ])
            wh.item.todayWeekdayOverride = r.day
            wh.item.nowMinsOverride = 8 * 60 + 10
            wait(140)
            var img = snap(wh.item, "meds_recurrence_" + r.tag)
            verify(seeText(r.expected), "recurrence renders " + r.expected)
            verify(G.looksRendered(img), "structured recurrence state renders")
        }

        // ========================================================== ROUTINE ==

        function test_routine_01_sizes_data() {
            return [
                { tag: "portrait-0.5x1",   w: 348,  h: 818,  sc: "tall" },
                { tag: "landscape-0.5x1",  w: 846,  h: 306,  sc: "wide" },
                { tag: "portrait-1x0.5",   w: 696,  h: 409,  sc: "wide" },
                { tag: "landscape-1x0.5",  w: 423,  h: 612,  sc: "tall" },
                { tag: "portrait-1x1",     w: 696,  h: 818,  sc: "compact" },
                { tag: "landscape-1x1",    w: 846,  h: 612,  sc: "compact" },
                { tag: "portrait-1x1.5",   w: 696,  h: 1226, sc: "tall" },
                { tag: "landscape-1x1.5",  w: 1268, h: 612,  sc: "wide" },
                { tag: "portrait-1x2",     w: 696,  h: 1635, sc: "large" },
                { tag: "landscape-1x2",    w: 1691, h: 612,  sc: "large" }
            ]
        }
        function test_routine_01_sizes(r) {
            prep("RoutineWidget.qml", r.w, r.h, r.sc)
            var steps = []
            for (var i = 1; i <= 20; i++) steps.push("Routine step " + (i < 10 ? "0" : "") + i)
            set("steps", steps.join("\n"))
            set("done", [steps[0], steps[1], steps[2], steps[3], steps[4]])
            set("day", today())
            wait(120)
            var img = snap(wh.item, "routine_sz_" + r.tag)
            compare(wh.item.width, r.w, "routine cell width " + r.tag)
            compare(wh.item.height, r.h, "routine cell height " + r.tag)
            verify(G.looksRendered(img), "routine rendered content at " + r.tag)
            verify(seeText("Routine step 01"), "first routine step is visible")
            var list = G.byObjName(wh.item, "routineStepList")
            verify(list !== null && list.height >= wh.item.rowH,
                   "at least one complete routine touch row fits")
            if (r.sc === "large")
                compare(wh.item.horiz, r.tag.indexOf("landscape") === 0,
                        "large routines follow physical orientation")
        }

        function test_routine_02_config_steps_data() {
            return [ { tag: "two-steps" }, { tag: "cleared" } ]
        }
        function test_routine_02_config_steps(r) {
            prep("RoutineWidget.qml", 680, 640, "compact")
            set("done", []); set("day", "")
            if (r.tag === "two-steps") {
                set("steps", "Meds\nBrush teeth"); wait(120)
                snap(wh.item, "routine_cf_steps_two")
                compare(wh.item.stepList.length, 2, "two step rows parsed")
                verify(seeText("Meds"), "first step shown")
                verify(seeText("Brush teeth"), "second step shown")
            } else {
                set("steps", ""); wait(120)
                snap(wh.item, "routine_cf_steps_clear")
                compare(wh.item.stepList.length, 0, "no step rows when cleared")
                verify(seeText("Add"), "empty-state prompt shown when cleared")
            }
        }

        function test_routine_03_body_data() {
            return [ { tag: "tick" }, { tag: "untick" } ]
        }
        function test_routine_03_body(r) {
            if (r.tag === "tick") {
                prep("RoutineWidget.qml", 680, 640, "compact")
                set("steps", "Meds\nBrush teeth"); set("done", []); set("day", ""); wait(120)
                snap(wh.item, "routine_b_tick_before")
                verify(stepRow("Meds") !== null, "step row present")
                var action = G.byObjName(wh.item, "routineStepAction-Meds")
                verify(action !== null, "explicit completion action present")
                mouseClick(action, action.width / 2, action.height / 2)
                wait(200)
                snap(wh.item, "routine_b_tick_after")
                verify(cfg().done.indexOf("Meds") >= 0, "tap marked the step done in store")
                compare(stepRow("Meds").done, true, "step visibly reads done after tap")
            } else {
                prep("RoutineWidget.qml", 680, 640, "compact")
                set("steps", "Meds\nBrush teeth"); set("day", today()); set("done", ["Meds"]); wait(120)
                compare(stepRow("Meds").done, true, "step starts done")
                var undoAction = G.byObjName(wh.item, "routineStepAction-Meds")
                verify(undoAction !== null, "explicit incomplete action present")
                mouseClick(undoAction, undoAction.width / 2, undoAction.height / 2)
                wait(200)
                snap(wh.item, "routine_b_untick_after")
                compare(cfg().done.length, 0, "second tap un-did the step")
                compare(stepRow("Meds").done, false, "step no longer reads done")
            }
        }

        function test_routine_04_states_data() {
            return [ { tag: "empty" }, { tag: "list" }, { tag: "progress" },
                     { tag: "alldone" }, { tag: "wide" }, { tag: "micro-footer" },
                     { tag: "overflow" }, { tag: "structured" } ]
        }
        function test_routine_04_states(r) {
            if (r.tag === "empty") {
                prep("RoutineWidget.qml", 680, 640, "compact")
                set("steps", ""); set("done", []); set("day", ""); wait(120)
                snap(wh.item, "routine_st_empty")
                verify(seeText("Add"), "empty prompt")
                compare(wh.item.stepList.length, 0, "no rows")
            } else if (r.tag === "list") {
                prep("RoutineWidget.qml", 680, 640, "compact")
                set("steps", "Meds\nBrush teeth\nPack bag"); set("done", []); set("day", ""); wait(120)
                snap(wh.item, "routine_st_list")
                compare(wh.item.stepList.length, 3, "three step rows")
            } else if (r.tag === "progress") {
                prep("RoutineWidget.qml", 680, 640, "compact")
                set("steps", "Meds\nBrush teeth"); set("day", today()); set("done", ["Meds"]); wait(120)
                snap(wh.item, "routine_st_progress")
                compare(wh.item.doneCount, 1, "doneCount reflects one ticked step")
                verify(seeText("1 of 2 done"), "summary reflects doneCount/total")
            } else if (r.tag === "alldone") {
                prep("RoutineWidget.qml", 680, 640, "compact")
                set("steps", "Meds\nBrush teeth"); set("day", today()); set("done", ["Meds", "Brush teeth"]); wait(120)
                var img = snap(wh.item, "routine_st_alldone")
                verify(wh.item.allDone, "allDone true when every step ticked")
                verify(seeText("All done for today"), "'All done for today ✓' shown")
                verify(hasColorNear(img, "" + wh.theme.success, 60), "all-done summary is success-coloured")
            } else if (r.tag === "wide") {
                prep("RoutineWidget.qml", 840, 400, "wide")
                set("steps", "Meds\nBrush teeth"); set("done", []); set("day", ""); wait(120)
                snap(wh.item, "routine_st_wide")
                var summ = G.byText(wh.item, "done")
                var row = stepRow("Brush teeth")
                verify(summ !== null && summ.visible, "summary shown in wide")
                verify(row !== null, "list shown in wide")
                verify(mapX(summ) < mapX(row), "summary sits left of the list (beside)")
            } else if (r.tag === "micro-footer") {
                prep("RoutineWidget.qml", 340, 400, "compact")   // min<480 → micro
                set("steps", "Meds\nBrush teeth\nPack bag"); set("day", today()); set("done", ["Meds"]); wait(120)
                snap(wh.item, "routine_st_microfooter")
                verify(wh.item.micro, "micro footprint derived")
                verify(!wh.item.showSummary, "summary hidden at micro")
                verify(seeText("1 of 3"), "footer count fallback shown")
                verify(G.byText(wh.item, "done") === null, "no summary 'done' line at micro")
            } else if (r.tag === "overflow") {
                prep("RoutineWidget.qml", 680, 360, "compact")
                var many = []
                for (var i = 0; i < 30; i++) many.push("Routine step " + i)
                set("steps", many.join("\n")); set("done", []); set("day", "")
                wait(120)
                snap(wh.item, "routine_st_overflow")
                var overflow = G.byObjName(wh.item, "routineOverflow")
                verify(overflow !== null && overflow.visible)
                verify(overflow.Accessible.name.indexOf("more routine steps") >= 0)
            } else { // structured
                prep("RoutineWidget.qml", 680, 640, "compact")
                set("routineFormat", "structured")
                set("routineItems", [
                    { id: "water", text: "Water plants" },
                    { id: "pack", text: "Pack work bag" }
                ])
                set("done", ["pack"]); set("day", today())
                wait(120)
                snap(wh.item, "routine_st_structured")
                compare(wh.item.stepItems[1].key, "pack")
                compare(stepRow("Pack work bag").done, true,
                        "completion follows structured immutable ID")
            }
        }

        function test_routine_05_status() {
            prep("RoutineWidget.qml", 680, 640, "compact")
            set("steps", "Meds\nBrush teeth\nPack bag"); set("day", today()); set("done", ["Meds"]); wait(120)
            snap(wh.item, "routine_status")
            compare(wh.item.status, "1/3", "header status reflects doneCount/total")
            verify(seeText("1/3"), "status '1/3' rendered in header")
        }

        function test_routine_06_chrome_accent_data() {
            return [ { tag: "override", accent: "red", hex: "#F85149" },
                     { tag: "auto",     accent: "",    hex: "" } ]
        }
        function test_routine_06_chrome_accent(r) {
            prep("RoutineWidget.qml", 680, 640, "compact")
            set("steps", "Meds\nBrush teeth"); set("done", []); set("day", ""); wait(100)
            var row = stepRow("Meds")
            var completion = G.byObjName(wh.item, "routineStepAction-Meds")
            verify(row !== null && completion !== null)
            mouseClick(completion, completion.width / 2, completion.height / 2)
            wh.item.accentName = r.accent
            wait(150)
            var img = snap(wh.item, "routine_chrome_" + r.tag)
            var target = r.tag === "auto" ? ("" + wh.theme.catProductivity) : r.hex
            if (r.tag === "auto")
                compare("" + wh.item.effAccent, "" + wh.theme.catProductivity, "Auto accent resolves to catProductivity")
            verify(hasColorNear(img, target, 70), "ticked checkbox renders in accent " + target)
        }

        function test_routine_07_backdrop_data() {
            return [ { s: "none" }, { s: "orbs" }, { s: "mesh" }, { s: "aurora" },
                     { s: "waves" }, { s: "stars" }, { s: "bokeh" }, { s: "grid" } ]
        }
        function test_routine_07_backdrop(r) {
            prep("RoutineWidget.qml", 680, 640, "compact")
            set("steps", "Meds\nBrush teeth"); set("done", []); set("day", "")
            wh.item.cardBackdrop = r.s
            wait(140)
            var img = snap(wh.item, "routine_backdrop_" + r.s)
            var bl = backdrop()
            verify(bl !== null, "BackdropLayer present")
            compare(bl.visible, r.s !== "none", "backdrop '" + r.s + "' visibility")
            verify(G.looksRendered(img), "card still renders with backdrop " + r.s)
        }

        // ======================================================== BRAINDUMP ==

        function test_braindump_01_sizes_data() {
            return [
                { tag: "portrait-0.5x1",   w: 348,  h: 818,  sc: "tall" },
                { tag: "landscape-0.5x1",  w: 846,  h: 306,  sc: "wide" },
                { tag: "portrait-1x0.5",   w: 696,  h: 409,  sc: "wide" },
                { tag: "landscape-1x0.5",  w: 423,  h: 612,  sc: "tall" },
                { tag: "portrait-1x1",     w: 696,  h: 818,  sc: "compact" },
                { tag: "landscape-1x1",    w: 846,  h: 612,  sc: "compact" },
                { tag: "portrait-1x1.5",   w: 696,  h: 1226, sc: "tall" },
                { tag: "landscape-1x1.5",  w: 1268, h: 612,  sc: "wide" },
                { tag: "portrait-1x2",     w: 696,  h: 1635, sc: "large" },
                { tag: "landscape-1x2",    w: 1691, h: 612,  sc: "large" }
            ]
        }
        function test_braindump_01_sizes(r) {
            prep("BraindumpWidget.qml", r.w, r.h, r.sc)
            var entries = []
            for (var i = 1; i <= 40; i++)
                entries.push({ id: "thought-" + i,
                               text: "Captured thought " + (i < 10 ? "0" : "") + i,
                               at: Date.now() - i * 60000 })
            set("entries", entries)
            set("showTimes", true)
            wait(120)
            var img = snap(wh.item, "braindump_sz_" + r.tag)
            compare(wh.item.width, r.w, "braindump cell width " + r.tag)
            compare(wh.item.height, r.h, "braindump cell height " + r.tag)
            verify(G.looksRendered(img), "braindump rendered content at " + r.tag)
            verify(seeText("Captured thought 01"), "newest captured thought is visible")
            var list = G.byObjName(wh.item, "braindumpList")
            verify(list !== null && list.height >= wh.item.rowH,
                   "at least one complete queue row fits")
            if (r.sc === "large")
                compare(wh.item.horiz, r.tag.indexOf("landscape") === 0,
                        "large capture queues follow physical orientation")
        }

        function test_braindump_02_config_showtimes_data() {
            return [ { tag: "on", on: true }, { tag: "off", on: false } ]
        }
        function test_braindump_02_config_showtimes(r) {
            prep("BraindumpWidget.qml", 680, 640, "compact")
            set("entries", [ { text: "buy milk", at: Date.now() } ])
            set("showTimes", r.on)
            wait(140)
            snap(wh.item, "braindump_cf_showtimes_" + r.tag)
            // A stamp is an HH:mm string; the entry text has no colon.
            var hasStamp = false
            var t = visTexts()
            for (var i = 0; i < t.length; i++) if (/^\d{1,2}:\d{2}$/.test(t[i])) hasStamp = true
            compare(hasStamp, r.on, "timestamp column present === showTimes " + r.on)
        }

        function test_braindump_03_body_data() {
            return [ { tag: "enter" }, { tag: "field-clears" }, { tag: "plus" },
                     { tag: "remove" }, { tag: "edit" }, { tag: "undo" },
                     { tag: "clearall" } ]
        }
        function test_braindump_03_body(r) {
            if (r.tag === "enter") {
                prep("BraindumpWidget.qml", 680, 640, "compact")
                set("entries", []); wait(100)
                snap(wh.item, "braindump_b_enter_before")
                var f = G.byObjName(wh.item, "braindumpCaptureField")
                verify(f !== null, "capture field present")
                typeWord(f, "idea one")
                keyClick(Qt.Key_Return, Qt.ControlModifier)
                wait(200)
                snap(wh.item, "braindump_b_enter_after")
                compare(cfg().entries.length, 1, "Enter added one entry")
                compare(cfg().entries[0].text, "idea one", "entry text captured")
            } else if (r.tag === "field-clears") {
                prep("BraindumpWidget.qml", 680, 640, "compact")
                set("entries", []); wait(100)
                var ff = G.byObjName(wh.item, "braindumpCaptureField")
                verify(ff !== null, "capture field present")
                typeWord(ff, "quick thought")
                verify(ff.text.length > 0, "field holds typed text before commit")
                keyClick(Qt.Key_Return, Qt.ControlModifier)
                wait(200)
                snap(wh.item, "braindump_b_fieldclears")
                compare(ff.text, "", "capture field clears after Enter commits the thought")
                compare(cfg().entries.length, 1, "the thought was committed")
            } else if (r.tag === "plus") {
                prep("BraindumpWidget.qml", 680, 640, "compact")
                set("entries", []); wait(100)
                var f2 = G.byObjName(wh.item, "braindumpCaptureField")
                typeWord(f2, "idea two")
                var plus = pillByGlyph("＋")
                verify(plus !== null, "＋ add button present")
                mouseClick(plus, plus.width / 2, plus.height / 2)
                wait(200)
                snap(wh.item, "braindump_b_plus_after")
                compare(cfg().entries.length, 1, "＋ added one entry")
                compare(cfg().entries[0].text, "idea two", "entry text captured via ＋")
            } else if (r.tag === "remove") {
                prep("BraindumpWidget.qml", 680, 640, "compact")
                wh.expanded = true
                set("entries", [ { text: "aaa", at: Date.now() }, { text: "bbb", at: Date.now() - 1000 } ])
                wait(140)
                snap(wh.item, "braindump_b_remove_before")
                var removeAction = G.findPred(wh.item, function(n) {
                    return String(n.objectName).indexOf("braindumpRemove-") === 0
                })
                verify(removeAction !== null && removeAction.visible,
                       "explicit remove action is visible when expanded")
                mouseClick(removeAction, removeAction.width / 2, removeAction.height / 2)
                wait(200)
                snap(wh.item, "braindump_b_remove_after")
                compare(cfg().entries.length, 1, "remove action removed one entry")
            } else if (r.tag === "edit") {
                prep("BraindumpWidget.qml", 680, 640, "compact")
                wh.expanded = true
                set("entries", [ { id: "edit-me", text: "draft", at: Date.now() } ])
                wait(140)
                var editAction = G.byObjName(wh.item, "braindumpEdit-edit-me")
                verify(editAction !== null && editAction.visible)
                mouseClick(editAction, editAction.width / 2, editAction.height / 2)
                wait(100)
                var editor = G.byObjName(wh.item, "braindumpEditor-edit-me")
                verify(editor !== null && editor.visible)
                editor.forceActiveFocus()
                keyClick(Qt.Key_A, Qt.ControlModifier)
                typeWord(editor, "finished")
                keyClick(Qt.Key_Return)
                wait(180)
                snap(wh.item, "braindump_b_edit_after")
                compare(cfg().entries[0].text, "finished")
                compare(cfg().entries[0].id, "edit-me")
            } else if (r.tag === "undo") {
                prep("BraindumpWidget.qml", 680, 640, "compact")
                wh.expanded = true
                set("entries", [ { id: "restore-me", text: "restore me", at: Date.now() } ])
                wait(100)
                wh.item.remove(0)
                wait(100)
                var undo = pillByLabel("Restore removed thought")
                verify(undo !== null && undo.visible, "shared undo action is visible")
                mouseClick(undo, undo.width / 2, undo.height / 2)
                wait(180)
                snap(wh.item, "braindump_b_undo_after")
                compare(cfg().entries.length, 1)
                compare(cfg().entries[0].text, "restore me")
            } else { // clearall
                prep("BraindumpWidget.qml", 680, 640, "compact")
                wh.expanded = true
                set("entries", [ { text: "aaa", at: Date.now() }, { text: "bbb", at: Date.now() - 1000 } ])
                wait(140)
                snap(wh.item, "braindump_b_clearall_before")
                var clr = pillByLabel("Clear all")
                verify(clr !== null, "'Clear all' button present")
                mouseClick(clr, clr.width / 2, clr.height / 2)
                wait(200)
                verify(wh.item.clearArmed, "first tap arms the destructive clear")
                mouseClick(clr, clr.width / 2, clr.height / 2)
                wait(200)
                snap(wh.item, "braindump_b_clearall_after")
                compare(cfg().entries.length, 0, "list emptied by Clear all")
            }
        }

        function test_braindump_04_emptyadd() {
            prep("BraindumpWidget.qml", 680, 640, "compact")
            set("entries", []); wait(100)
            var plus = pillByGlyph("＋")
            verify(plus !== null, "＋ button present")
            mouseClick(plus, plus.width / 2, plus.height / 2)
            wait(150)
            snap(wh.item, "braindump_emptyadd")
            compare(cfg().entries.length, 0, "adding a blank thought is a no-op")
        }

        function test_braindump_05_states_data() {
            return [ { tag: "empty" }, { tag: "order" }, { tag: "wide" },
                     { tag: "count" }, { tag: "overflow" } ]
        }
        function test_braindump_05_states(r) {
            if (r.tag === "empty") {
                prep("BraindumpWidget.qml", 680, 640, "compact")
                set("entries", []); wait(120)
                snap(wh.item, "braindump_st_empty")
                verify(seeText("Ready for a thought"), "useful empty-state guidance shown")
                compare(entryRows().length, 0, "no entry rows")
            } else if (r.tag === "order") {
                prep("BraindumpWidget.qml", 680, 640, "compact")
                set("entries", []); wait(100)
                var f = G.byObjName(wh.item, "braindumpCaptureField")
                verify(f !== null, "multiline capture field present")
                typeWord(f, "older"); keyClick(Qt.Key_Return, Qt.ControlModifier); wait(150)
                typeWord(f, "newer"); keyClick(Qt.Key_Return, Qt.ControlModifier); wait(200)
                snap(wh.item, "braindump_st_order")
                compare(cfg().entries[0].text, "newer", "newest entry is first in store")
                var top = entryRow(0), second = entryRow(1)
                verify(top !== null && second !== null, "two entry rows realised")
                compare(top.modelData.text, "newer", "top row shows newest")
                verify(mapY(top) < mapY(second), "newest row sits above older row")
            } else if (r.tag === "wide") {
                prep("BraindumpWidget.qml", 840, 400, "wide")
                set("entries", [ { text: "one thing", at: Date.now() } ]); wait(120)
                snap(wh.item, "braindump_st_wide")
                var capture = G.byObjName(wh.item, "braindumpCaptureColumn")
                var queue = G.byObjName(wh.item, "braindumpQueueColumn")
                verify(capture !== null && queue !== null, "capture and queue columns are present in wide")
                verify(mapX(capture) > mapX(queue), "capture column sits right of the queue (beside)")
            } else if (r.tag === "count") {
                prep("BraindumpWidget.qml", 680, 640, "compact")
                set("entries", [ { text: "a", at: Date.now() }, { text: "b", at: Date.now() },
                                 { text: "c", at: Date.now() } ]); wait(120)
                snap(wh.item, "braindump_st_count")
                compare(wh.item.status, "3", "header status shows entry count")
                verify(seeText("3"), "count '3' rendered in header")
            } else { // overflow
                prep("BraindumpWidget.qml", 680, 360, "compact")
                var many = []
                for (var i = 0; i < 30; i++)
                    many.push({ id: "overflow-" + i, text: "thought " + i,
                                  at: Date.now() - i * 1000 })
                set("entries", many)
                wait(140)
                snap(wh.item, "braindump_st_overflow")
                var overflow = G.byObjName(wh.item, "braindumpOverflow")
                verify(overflow !== null && overflow.visible)
                verify(overflow.Accessible.name.indexOf("more thoughts") >= 0)
            }
        }

        function test_braindump_06_chrome_accent_data() {
            return [ { tag: "override", accent: "red", hex: "#F85149" },
                     { tag: "auto",     accent: "",    hex: "" } ]
        }
        function test_braindump_06_chrome_accent(r) {
            prep("BraindumpWidget.qml", 680, 640, "compact")
            set("entries", [ { text: "note", at: Date.now() } ])
            wh.item.accentName = r.accent
            wait(150)
            var plus = pillByGlyph("＋")
            verify(plus !== null, "＋ button present")
            var img = snap(wh.item, "braindump_chrome_" + r.tag)
            var target = r.tag === "auto" ? ("" + wh.theme.catProductivity) : r.hex
            if (r.tag === "auto")
                compare("" + wh.item.effAccent, "" + wh.theme.catProductivity, "Auto accent resolves to catProductivity")
            // The primary ＋ button is filled with effAccent; scan the card for it.
            verify(hasColorNear(img, target, 70), "accent surfaces on the widget (＋ button/header) " + target)
        }

        function test_braindump_07_backdrop_data() {
            return [ { s: "none" }, { s: "orbs" }, { s: "mesh" }, { s: "aurora" },
                     { s: "waves" }, { s: "stars" }, { s: "bokeh" }, { s: "grid" } ]
        }
        function test_braindump_07_backdrop(r) {
            prep("BraindumpWidget.qml", 680, 640, "compact")
            set("entries", [ { text: "note", at: Date.now() } ])
            wh.item.cardBackdrop = r.s
            wait(140)
            var img = snap(wh.item, "braindump_backdrop_" + r.s)
            var bl = backdrop()
            verify(bl !== null, "BackdropLayer present")
            compare(bl.visible, r.s !== "none", "backdrop '" + r.s + "' visibility")
            verify(G.looksRendered(img), "card still renders with backdrop " + r.s)
        }
    }
}
