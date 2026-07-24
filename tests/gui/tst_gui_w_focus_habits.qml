import QtQuick
import QtTest
import "../ui" as UI
import "GuiUtil.js" as G

// Visible GUI suite - Focus/habit widgets: Quick Note, Habit Streak and Break
// Reminder. Each is hosted in a real KWin-composited window via
// UI.WidgetHarness, sized to a concrete cell, driven with real mouse/keyboard
// events, and asserted via item.visible / geometry / on-screen text / grabImage
// pixels / a store setting reflected in the visible output. Deterministic day &
// timer seams are seeded through store settings (checkins[], break
// endEpoch/running/due/intervalMin) - never by sleeping real time.
Item {
    id: root
    width: 1400; height: 760

    UI.WidgetHarness {
        id: wh
        x: 0; y: 0
        width: 696; height: 612
        widgetFile: ""
    }

    TestCase {
        id: tc
        name: "GuiWFocusHabits"
        when: windowShown
        visible: true

        // Unicode MINUS SIGN (U+2212) - the exact glyph the widgets use for their
        // "−" / "−5m" pill labels (not ASCII hyphen).
        readonly property string minusSign: "−"

        function snap(item, n) {
            var img = grabImage(item)
            img.save("gui-evidence/foc_" + n + ".png")
            return img
        }

        // ── Harness plumbing ────────────────────────────────────────────────
        function loadWidget(file, marker) {
            wh.expanded = false
            wh.widgetFile = file
            tryVerify(function () {
                return wh.ready && wh.item && wh.item[marker] !== undefined
            }, 6000, "loaded " + file)
        }
        function resetInst() { wh.storeCtl.resetSettings(wh.instanceId, {}); wait(60) }
        function seed(obj) { wh.storeCtl.patchSettings(wh.instanceId, obj); wait(120) }
        function settings() { return wh.storeCtl.settingsFor(wh.instanceId) }
        function setSize(cls, w, h) {
            root.width = Math.max(1400, w)
            root.height = Math.max(760, h)
            wh.width = w; wh.height = h
            wh.item.sizeClass = cls
            wait(220)
        }

        // ── Scene-graph seams ───────────────────────────────────────────────
        function isPill(n) {
            try { return n && n.label !== undefined && n.glyph !== undefined
                         && n.clicked !== undefined } catch (e) { return false }
        }
        function pills(sub, exact) {
            return G.collectPred(wh.item, function (n) {
                if (!isPill(n) || !G.isLive(n)) return false
                var l = "" + n.label
                return exact ? (l === sub) : (l.indexOf(sub) >= 0)
            })
        }
        function pill(sub, exact) { var a = pills(sub, exact); return a.length ? a[0] : null }
        function clickPill(sub, exact) {
            var p = pill(sub, exact)
            verify(p !== null, "found live pill '" + sub + "'")
            mouseClick(p, p.width / 2, p.height / 2)
            wait(220)
            return p
        }
        // First VISIBLE Text containing sub (case-insensitive).
        function vtext(sub) { return G.byText(wh.item, sub) }
        function editorEdit() {
            return G.findPred(wh.item, function (n) {
                try { return ("" + n).indexOf("TextEdit") >= 0 && G.isLive(n) }
                catch (e) { return false }
            })
        }
        function backdrop() {
            return G.findPred(wh.item, function (n) {
                try { return n && n.style !== undefined && n.accent !== undefined
                             && n.running !== undefined } catch (e) { return false }
            })
        }
        function ringProgress() {
            return G.findPred(wh.item, function (n) {
                try { return n && n.progressColor !== undefined && n.value !== undefined
                             && G.isLive(n) } catch (e) { return false }
            })
        }
        // The mono countdown readout (mm:ss / mmm:ss), visible only.
        function timerText() {
            return G.findPred(wh.item, function (n) {
                try { return n && n.text !== undefined && n.visible
                             && /^\d{1,3}:\d\d$/.test("" + n.text) } catch (e) { return false }
            })
        }
        // Live heatmap cells (Rectangles carrying a `dk` date key). GuiUtil's
        // walker visits an Item via both `children` and `data`, so a delegate can
        // be reported more than once - dedupe by object identity.
        function heatCells() {
            var raw = G.collectPred(wh.item, function (n) {
                try { return n && n.dk !== undefined && G.isLive(n) } catch (e) { return false }
            })
            var out = []
            for (var i = 0; i < raw.length; i++)
                if (out.indexOf(raw[i]) < 0) out.push(raw[i])
            return out
        }
        function cornerPix(img) { return "" + img.pixel(20, Math.floor(img.height / 2)) }

        // Shared accent-corner check: the card's top-left accent wash is tinted by
        // effAccent, so a preset override visibly changes a mid-left-edge pixel and
        // Auto returns it to the category colour. `mode` = "override" | "auto".
        function accentCheck(prefix, mode) {
            wh.item.cardBackdrop = "none"
            wh.item.accentName = ""
            wait(160)
            var base = cornerPix(snap(wh, prefix + "_accent_base"))
            wh.item.accentName = "red"
            wait(160)
            var red = cornerPix(snap(wh, prefix + "_accent_red"))
            if (mode === "override") {
                var d = G.colorDist(base, red)
                verify(d > 6, prefix + ": accent override tints card (dist " + d.toFixed(1) + ")")
                wh.item.accentName = ""
                return
            }
            // auto
            wh.item.accentName = ""
            wait(160)
            var auto = cornerPix(snap(wh, prefix + "_accent_auto"))
            var dAway = G.colorDist(auto, red)
            var dBack = G.colorDist(auto, base)
            verify(dAway > 6 && dBack < 6,
                   prefix + ": accent Auto restores category colour (from red "
                   + dAway.toFixed(1) + ", to base " + dBack.toFixed(1) + ")")
        }

        // Shared per-widget backdrop check (S0-11 shape): none hides the layer,
        // every style shows it.
        function backdropCheck(prefix, style) {
            wh.item.accentName = ""
            wh.item.cardBackdrop = style
            wait(200)
            var bl = backdrop()
            verify(bl !== null, prefix + ": BackdropLayer present")
            compare(bl.visible, style !== "none",
                    prefix + ": backdrop '" + style + "' visible == " + (style !== "none"))
            var img = snap(wh, prefix + "_backdrop_" + style)
            verify(G.looksRendered(img), prefix + ": renders with backdrop " + style)
            wh.item.cardBackdrop = "none"
        }
        readonly property var backdropStyles: ["none", "orbs", "mesh", "aurora",
                                               "waves", "stars", "bokeh", "grid"]

        // ═══════════════════════════════════════════════════════════════════
        // BREAK REMINDER
        // ═══════════════════════════════════════════════════════════════════
        function test_break_config_interval_data() {
            return [ { tag: "5", v: 5, txt: "05:00" },
                     { tag: "30", v: 30, txt: "30:00" },
                     { tag: "120", v: 120, txt: "120:00" } ]
        }
        function test_break_config_interval(r) {
            loadWidget("BreakWidget.qml", "ringFrac")
            resetInst()
            seed({ intervalMin: 30, running: false, endEpoch: 0, pausedRemaining: 1800, due: false })
            setSize("compact", 696, 612)
            wh.storeCtl.setSetting(wh.instanceId, "intervalMin", r.v)
            wait(350)   // outlast onIntervalMinChanged -> Qt.callLater(_applyInterval)
            compare(settings().intervalMin, r.v, "intervalMin persisted " + r.v)
            var t = timerText()
            verify(t !== null, "break timer readout present")
            compare("" + t.text, r.txt, "break interval " + r.v + " reseeds countdown")
            snap(wh, "break_interval_" + r.tag)
        }

        function test_break_config_message_data() {
            return [ { tag: "custom", msg: "Stretch!", expect: "Stretch!" },
                     { tag: "default", msg: "", expect: "Take a break!" } ]
        }
        function test_break_config_message(r) {
            loadWidget("BreakWidget.qml", "ringFrac")
            resetInst()
            seed({ intervalMin: 30, due: true, message: r.msg })
            setSize("compact", 696, 612)
            var t = vtext(r.expect)
            verify(t !== null, "break due message shows '" + r.expect + "'")
            snap(wh, "break_msg_" + r.tag)
        }

        function test_break_config_suggestion_data() {
            return [ { tag: "on", v: true, present: true },
                     { tag: "off", v: false, present: false } ]
        }
        function test_break_config_suggestion(r) {
            loadWidget("BreakWidget.qml", "ringFrac")
            resetInst()
            seed({ intervalMin: 30, due: true, showSuggestion: r.v })
            setSize("compact", 696, 612)
            var t = vtext("Try:")
            compare(t !== null, r.present, "break suggestion visible == " + r.present)
            snap(wh, "break_suggest_" + r.tag)
        }

        function test_break_body_pause() {
            loadWidget("BreakWidget.qml", "ringFrac")
            resetInst()
            seed({ intervalMin: 30, running: true, due: false, endEpoch: Date.now() + 1500000 })
            setSize("compact", 696, 612)
            verify(vtext("paused") === null, "not paused before")
            snap(wh, "break_pause_before")
            clickPill("Pause")
            compare(settings().running, false, "Pause set running=false")
            verify(vtext("paused") !== null, "'paused' caption appears")
            snap(wh, "break_pause_after")
        }
        function test_break_body_reset() {
            loadWidget("BreakWidget.qml", "ringFrac")
            resetInst()
            // Paused, not due: the tile shows the Pause/Reset controls (Reset is
            // relabelled "Took it" in the due state, so it must not be due here).
            seed({ intervalMin: 30, running: false, endEpoch: 0, pausedRemaining: 120, due: false })
            setSize("compact", 696, 612)
            snap(wh, "break_reset_before")
            clickPill("Reset")
            compare(settings().due, false, "Reset clears due")
            compare(settings().running, true, "Reset resumes running")
            var t = timerText()
            verify(t !== null && "" + t.text === "30:00", "Reset restores the full interval")
            snap(wh, "break_reset_after")
        }
        function test_break_body_due_done() {
            loadWidget("BreakWidget.qml", "ringFrac")
            resetInst()
            seed({ intervalMin: 30, due: true, breaksToday: 0, day: wh.item.todayKey })
            setSize("compact", 696, 612)
            snap(wh, "break_due_before")
            clickPill("Done")
            compare(settings().breaksToday, 1, "Done increments breaksToday")
            compare(settings().due, false, "Done clears due")
            snap(wh, "break_due_after")
        }
        function test_break_body_overlay_minus5() {
            loadWidget("BreakWidget.qml", "ringFrac")
            resetInst()
            seed({ intervalMin: 30, running: true, due: false, endEpoch: Date.now() + 1500000 })
            setSize("compact", 696, 612)
            wh.expanded = true; wait(220)
            clickPill("−5m")
            wait(200)
            compare(settings().intervalMin, 25, "−5m lowers interval to 25")
            snap(wh, "break_minus5")
        }
        function test_break_body_overlay_plus5() {
            loadWidget("BreakWidget.qml", "ringFrac")
            resetInst()
            seed({ intervalMin: 30, running: true, due: false, endEpoch: Date.now() + 1500000 })
            setSize("compact", 696, 612)
            wh.expanded = true; wait(220)
            clickPill("+5m")
            wait(200)
            compare(settings().intervalMin, 35, "+5m raises interval to 35")
            snap(wh, "break_plus5")
        }

        function test_break_state_running_ring() {
            loadWidget("BreakWidget.qml", "ringFrac")
            resetInst()
            seed({ intervalMin: 30, running: true, due: false, endEpoch: Date.now() + 30 * 60 * 1000 })
            setSize("compact", 696, 612)
            var rp = ringProgress()
            verify(rp !== null, "RingProgress present")
            verify(rp.value > 0.5, "running ring mostly full (" + rp.value.toFixed(2) + ")")
            verify(timerText() !== null, "running countdown renders")
            verify(vtext("paused") === null, "running is not captioned paused")
            snap(wh, "break_st_running")
        }
        function test_break_state_paused() {
            loadWidget("BreakWidget.qml", "ringFrac")
            resetInst()
            seed({ intervalMin: 30, running: false, endEpoch: 0, pausedRemaining: 600, due: false })
            setSize("compact", 696, 612)
            verify(vtext("paused") !== null, "'paused' caption visible")
            var t = timerText()
            verify(t !== null && "" + t.text === "10:00", "paused holds 10:00")
            snap(wh, "break_st_paused")
        }
        function test_break_state_due() {
            loadWidget("BreakWidget.qml", "ringFrac")
            resetInst()
            seed({ intervalMin: 30, due: true, message: "" })
            setSize("compact", 696, 612)
            verify(vtext("Take a break!") !== null, "due hero message shown")
            snap(wh, "break_st_due")
        }
        function test_break_state_due_suggestion() {
            loadWidget("BreakWidget.qml", "ringFrac")
            resetInst()
            seed({ intervalMin: 30, due: true, showSuggestion: true })
            setSize("compact", 696, 612)
            verify(vtext("Try:") !== null, "due suggestion line shown")
            snap(wh, "break_st_due_suggest")
        }
        function test_break_state_micro() {
            loadWidget("BreakWidget.qml", "ringFrac")
            resetInst()
            seed({ intervalMin: 30, running: false, endEpoch: 0, pausedRemaining: 900, due: false })
            setSize("compact", 348, 306)
            verify(wh.item.micro === true, "micro derived at 0.5x0.5")
            verify(vtext("Break Reminder") === null, "micro is headerless")
            verify(vtext("until next break") === null, "micro drops tile controls caption")
            verify(timerText() !== null, "micro still shows the ring countdown")
            snap(wh, "break_st_micro")
        }
        function test_break_state_breaks_today() {
            loadWidget("BreakWidget.qml", "ringFrac")
            resetInst()
            seed({ intervalMin: 30, running: true, due: false, endEpoch: Date.now() + 1500000,
                   breaksToday: 2, day: wh.item.todayKey })
            setSize("compact", 696, 612)
            verify(vtext("2 breaks today") !== null, "momentum shows 2 breaks today")
            snap(wh, "break_st_breaks")
        }

        function test_break_chrome_accent_override() {
            loadWidget("BreakWidget.qml", "ringFrac"); resetInst()
            seed({ intervalMin: 30, running: false, endEpoch: 0, pausedRemaining: 900 })
            setSize("compact", 696, 612); accentCheck("break", "override")
        }
        function test_break_chrome_accent_auto() {
            loadWidget("BreakWidget.qml", "ringFrac"); resetInst()
            seed({ intervalMin: 30, running: false, endEpoch: 0, pausedRemaining: 900 })
            setSize("compact", 696, 612); accentCheck("break", "auto")
        }
        function test_break_chrome_backdrop_data() {
            return backdropStyles.map(function (s) { return { tag: s, style: s } })
        }
        function test_break_chrome_backdrop(r) {
            loadWidget("BreakWidget.qml", "ringFrac"); resetInst()
            seed({ intervalMin: 30, running: false, endEpoch: 0, pausedRemaining: 900 })
            setSize("compact", 696, 612); backdropCheck("break", r.style)
        }

        // ═══════════════════════════════════════════════════════════════════
        // HABIT STREAK
        // ═══════════════════════════════════════════════════════════════════
        function test_habit_config_name_data() {
            return [ { tag: "set", name: "Meditate", expect: "Meditate" },
                     { tag: "clear", name: "", expect: "Habit" } ]
        }
        function test_habit_config_name(r) {
            loadWidget("HabitWidget.qml", "heatCols")
            resetInst()
            seed({ name: r.name, streak: 1, lastCheckinDay: wh.item.todayKey, checkins: [wh.item.todayKey] })
            setSize("compact", 696, 612)
            verify(vtext(r.expect) !== null, "habit header shows '" + r.expect + "'")
            snap(wh, "habit_name_" + r.tag)
        }

        function test_habit_body_checkin() {
            loadWidget("HabitWidget.qml", "heatCols")
            resetInst()
            setSize("compact", 696, 612)
            verify(wh.item.doneToday === false, "not done before check-in")
            snap(wh, "habit_checkin_before")
            clickPill("Check in")
            var s = settings()
            verify(s.checkins.indexOf(wh.item.todayKey) >= 0, "today added to checkins")
            compare(s.streak, 1, "streak becomes 1")
            verify(wh.item.doneToday === true, "doneToday now true")
            verify(pill("today", false) !== null, "button flips to done-today label")
            snap(wh, "habit_checkin_after")
        }
        function test_habit_body_uncheck() {
            loadWidget("HabitWidget.qml", "heatCols")
            resetInst()
            seed({ streak: 1, lastCheckinDay: wh.item.todayKey, checkins: [wh.item.todayKey], bestStreak: 1 })
            setSize("compact", 696, 612)
            verify(wh.item.doneToday === true, "done before uncheck")
            clickPill("today", false)   // "✓ today"
            var s = settings()
            verify(s.checkins.indexOf(wh.item.todayKey) < 0, "today removed from checkins")
            compare(s.streak, 0, "streak recomputes to 0")
            verify(pill("Check in") !== null, "button returns to Check in")
            snap(wh, "habit_uncheck_after")
        }

        function test_habit_state_streak_number() {
            loadWidget("HabitWidget.qml", "heatCols")
            resetInst()
            seed({ streak: 5, lastCheckinDay: wh.item.todayKey, checkins: [wh.item.todayKey] })
            setSize("compact", 696, 612)
            verify(vtext("5 days") !== null, "streak readout shows 5 days")
            snap(wh, "habit_st_streak")
        }
        function test_habit_state_heatmap_square() {
            loadWidget("HabitWidget.qml", "heatCols")
            resetInst()
            seed({ checkins: [wh.item.todayKey] })
            setSize("compact", 696, 612)
            compare(wh.item.heatCols, 7, "square box uses 7 columns")
            compare(heatCells().length, 28, "28 heatmap cells rendered")
            snap(wh, "habit_st_heat7")
        }
        function test_habit_state_heatmap_tall() {
            loadWidget("HabitWidget.qml", "heatCols")
            resetInst()
            seed({ checkins: [wh.item.todayKey] })
            setSize("tall", 348, 700)
            compare(wh.item.heatCols, 4, "tall box transposes to 4 columns")
            compare(heatCells().length, 28, "28 heatmap cells rendered (tall)")
            snap(wh, "habit_st_heat4")
        }
        function test_habit_state_best_line() {
            loadWidget("HabitWidget.qml", "heatCols")
            resetInst()
            seed({ streak: 5, lastCheckinDay: wh.item.todayKey, checkins: [wh.item.todayKey], bestStreak: 10 })
            setSize("tall", 696, 700)   // roomy (min side >= 480)
            verify(wh.item.roomy === true, "1x1.5 is roomy")
            verify(vtext("Best:") !== null, "best-ever record line shown on roomy box")
            snap(wh, "habit_st_best")
        }
        function test_habit_state_micro_no_heatmap() {
            loadWidget("HabitWidget.qml", "heatCols")
            resetInst()
            seed({ streak: 3, lastCheckinDay: wh.item.todayKey, checkins: [wh.item.todayKey] })
            setSize("compact", 348, 306)
            verify(wh.item.micro === true, "micro at 0.5x0.5")
            compare(heatCells().length, 0, "no heatmap cells on micro")
            verify(vtext("3 days") !== null, "micro still shows streak")
            snap(wh, "habit_st_micro")
        }
        function test_habit_state_done_label() {
            loadWidget("HabitWidget.qml", "heatCols")
            resetInst()
            seed({ streak: 1, lastCheckinDay: wh.item.todayKey, checkins: [wh.item.todayKey] })
            setSize("compact", 696, 612)
            verify(pill("today", false) !== null, "done-today label present when checked in")
            snap(wh, "habit_st_done")
        }
        function test_habit_state_milestone() {
            loadWidget("HabitWidget.qml", "heatCols")
            resetInst()
            var yk = wh.item.prevDayKey(wh.item.todayKey)
            seed({ streak: 6, lastCheckinDay: yk, checkins: [yk], bestStreak: 6 })
            setSize("compact", 696, 612)
            clickPill("Check in")
            wait(200)
            compare(settings().streak, 7, "7th consecutive day")
            verify(vtext("milestone") !== null, "milestone celebration on reaching 7")
            snap(wh, "habit_st_milestone")
        }
        function test_habit_state_today_border() {
            loadWidget("HabitWidget.qml", "heatCols")
            resetInst()
            seed({ checkins: [wh.item.todayKey] })
            setSize("compact", 696, 612)
            var cells = heatCells()
            var todayCell = null
            for (var i = 0; i < cells.length; i++)
                if (cells[i].dk === wh.item.todayKey) todayCell = cells[i]
            verify(todayCell !== null, "found today's heatmap cell")
            compare(todayCell.border.width, 2, "today cell has a 2px border")
            snap(wh, "habit_st_today_border")
        }

        function test_habit_chrome_accent_override() {
            loadWidget("HabitWidget.qml", "heatCols"); resetInst()
            seed({ streak: 3, lastCheckinDay: wh.item.todayKey, checkins: [wh.item.todayKey] })
            setSize("compact", 696, 612); accentCheck("habit", "override")
        }
        function test_habit_chrome_accent_auto() {
            loadWidget("HabitWidget.qml", "heatCols"); resetInst()
            seed({ streak: 3, lastCheckinDay: wh.item.todayKey, checkins: [wh.item.todayKey] })
            setSize("compact", 696, 612); accentCheck("habit", "auto")
        }
        function test_habit_chrome_backdrop_data() {
            return backdropStyles.map(function (s) { return { tag: s, style: s } })
        }
        function test_habit_chrome_backdrop(r) {
            loadWidget("HabitWidget.qml", "heatCols"); resetInst()
            seed({ checkins: [wh.item.todayKey] })
            setSize("compact", 696, 612); backdropCheck("habit", r.style)
        }

        // ═══════════════════════════════════════════════════════════════════
        // QUICK NOTE
        // ═══════════════════════════════════════════════════════════════════
        function test_notes_config_text_data() {
            return [ { tag: "set", text: "Buy milk", expect: "Buy milk", placeholder: false },
                     { tag: "clear", text: "", expect: "Tap to jot a note", placeholder: true } ]
        }
        function test_notes_config_text(r) {
            loadWidget("NotesWidget.qml", "previewPx")
            resetInst()
            if (r.text.length) seed({ text: r.text })
            setSize("compact", 696, 612)
            verify(vtext(r.expect) !== null,
                   "notes preview shows " + (r.placeholder ? "placeholder" : "'" + r.expect + "'"))
            snap(wh, "notes_cfg_text_" + r.tag)
        }

        function test_notes_body_autosave() {
            loadWidget("NotesWidget.qml", "previewPx")
            resetInst()
            setSize("compact", 696, 612)
            wh.expanded = true; wait(250)
            var ed = editorEdit()
            verify(ed !== null, "expanded editor present")
            snap(wh, "notes_autosave_before")
            mouseClick(ed, 20, 20)
            ed.forceActiveFocus()
            keyClick("n"); keyClick("o"); keyClick("t"); keyClick("e")
            wait(700)   // outlast the 400ms autosave debounce
            compare(settings().text, "note", "typed text autosaved to store")
            snap(wh, "notes_autosave_after")
        }
        function test_notes_body_charcount() {
            loadWidget("NotesWidget.qml", "previewPx")
            resetInst()
            setSize("compact", 696, 612)
            wh.expanded = true; wait(250)
            var ed = editorEdit()
            verify(ed !== null, "expanded editor present")
            mouseClick(ed, 20, 20)
            ed.forceActiveFocus()
            keyClick("h"); keyClick("e"); keyClick("l"); keyClick("l"); keyClick("o")
            wait(250)
            verify(vtext("5 chars") !== null, "char/word count updates as typed")
            snap(wh, "notes_charcount")
        }

        function test_notes_state_empty_placeholder() {
            loadWidget("NotesWidget.qml", "previewPx")
            resetInst()
            setSize("compact", 696, 612)
            verify(vtext("Tap to jot a note") !== null, "empty preview placeholder shown")
            snap(wh, "notes_st_empty")
        }
        function test_notes_state_preview_text() {
            loadWidget("NotesWidget.qml", "previewPx")
            resetInst()
            seed({ text: "Remember the milk" })
            setSize("compact", 696, 612)
            verify(vtext("Remember the milk") !== null, "stored text shown in preview")
            snap(wh, "notes_st_preview")
        }
        function test_notes_state_micro_headerless() {
            loadWidget("NotesWidget.qml", "previewPx")
            resetInst()
            setSize("compact", 348, 306)
            verify(wh.item.micro === true, "micro at 0.5x0.5")
            verify(vtext("Quick Note") === null, "micro hides the header")
            verify(vtext("Jot a note") !== null, "micro placeholder shown")
            snap(wh, "notes_st_micro")
        }
        function test_notes_state_previewpx_scales() {
            loadWidget("NotesWidget.qml", "previewPx")
            resetInst()
            seed({ text: "SCALECHECK" })
            setSize("tall", 348, 700)          // narrow column
            var narrow = vtext("SCALECHECK")
            verify(narrow !== null, "narrow preview present")
            var narrowPx = narrow.font.pixelSize
            setSize("wide", 760, 409)          // wide column
            var wide = vtext("SCALECHECK")
            verify(wide !== null, "wide preview present")
            var widePx = wide.font.pixelSize
            verify(widePx > narrowPx, "preview font scales up with the column ("
                   + narrowPx + " -> " + widePx + ")")
            snap(wh, "notes_st_previewpx")
        }
        function test_notes_state_expanded_placeholder() {
            loadWidget("NotesWidget.qml", "previewPx")
            resetInst()
            setSize("compact", 696, 612)
            wh.expanded = true; wait(250)
            verify(vtext("saves automatically") !== null, "expanded editor placeholder shown")
            snap(wh, "notes_st_expanded")
        }

        function test_notes_chrome_accent_override() {
            loadWidget("NotesWidget.qml", "previewPx"); resetInst()
            seed({ text: "Accent note" }); setSize("compact", 696, 612)
            accentCheck("notes", "override")
        }
        function test_notes_chrome_accent_auto() {
            loadWidget("NotesWidget.qml", "previewPx"); resetInst()
            seed({ text: "Accent note" }); setSize("compact", 696, 612)
            accentCheck("notes", "auto")
        }
        function test_notes_chrome_backdrop_data() {
            return backdropStyles.map(function (s) { return { tag: s, style: s } })
        }
        function test_notes_chrome_backdrop(r) {
            loadWidget("NotesWidget.qml", "previewPx"); resetInst()
            seed({ text: "Backdrop note" }); setSize("compact", 696, 612)
            backdropCheck("notes", r.style)
        }
    }
}
