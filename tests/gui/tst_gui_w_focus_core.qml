import QtQuick
import QtTest
import "../ui" as UI
import "GuiUtil.js" as G

// Visible, real-compositor GUI tests for the three "Focus" Hub widgets:
//   FocusWidget · RightNowWidget · TasksWidget
//
// Each widget is hosted in a real KWin-composited window via UI.WidgetHarness and
// driven with real mouse/keyboard events. Every case asserts an objective,
// GUI-observable outcome (on-screen text, item.visible, geometry, grabImage
// pixels, or a store setting reflected in the VISIBLE output) after a real
// interaction. Timer state is seeded through the store (endEpoch / pausedRemaining
// / running / phase / doneToday) rather than waiting real seconds.
//
// Data-driven throughout; every *_data() has a matching consumer.
Item {
    id: root
    width: 1400; height: 1360

    UI.WidgetHarness {
        id: wh
        x: 0; y: 0
        width: 700; height: 700
        widgetFile: ""
    }

    TestCase {
        id: tc
        name: "GuiWFocusCore"
        when: windowShown
        visible: true

        // ── helpers ──────────────────────────────────────────────────────────
        function snap(item, n) {
            var i = grabImage(item); i.save("gui-evidence/wfocus_" + n + ".png"); return i
        }
        function todayKey() { return Qt.formatDate(new Date(), "yyyy-MM-dd") }

        // Prepare a case: (re)load the widget file, wipe + seed its store bucket,
        // pin geometry + sizeClass + expanded, then settle.
        function prep(file, sc, w, h, exp, seedObj) {
            root.width = Math.max(1400, w)
            root.height = Math.max(1360, h)
            wh.expanded = (exp === true)
            if (wh.widgetFile !== file) {
                wh.widgetFile = file
                tryVerify(function () { return wh.ready }, 6000, "widget loaded: " + file)
            }
            wh.storeCtl.load("blank")                 // wipe all per-instance settings
            if (seedObj)
                for (var k in seedObj) wh.storeCtl.setSetting(wh.instanceId, k, seedObj[k])
            wh.width = w; wh.height = h
            wait(40)
            verify(wh.item !== null, "widget item present")
            if (wh.item.hasOwnProperty("sizeClass")) wh.item.sizeClass = sc
            // Reset appearance props (harness does not bind them; the Dashboard does)
            if (wh.item.hasOwnProperty("titleOverride")) wh.item.titleOverride = ""
            if (wh.item.hasOwnProperty("accentName")) wh.item.accentName = ""
            if (wh.item.hasOwnProperty("cardBackdrop")) wh.item.cardBackdrop = "none"
            // Clear any lingering celebration banner text from a prior case (the
            // item is reused across cases; a fresh Dashboard instance starts blank).
            if (wh.item.hasOwnProperty("celebrateMsg")) wh.item.celebrateMsg = ""
            if (wh.item.hasOwnProperty("foreground")) wh.item.foreground = true
            wait(140)
        }
        function stg() { return wh.storeCtl.settingsFor(wh.instanceId) }

        // Find the first live PillButton with a given label.
        function pill(label) {
            return G.findPred(wh.item, function (n) {
                try {
                    return n && n.label !== undefined && n.glyph !== undefined
                        && n.clicked !== undefined && n.label === label && G.isLive(n)
                } catch (e) { return false }
            })
        }
        function clickItem(it) {
            verify(it, "target present to click")
            mouseClick(it, Math.round(it.width / 2), Math.round(it.height / 2))
            wait(180)
        }
        // Click a SegmentedControl option by its visible label.
        function segClick(label) {
            var seg = G.findPred(wh.item, function (n) {
                try { return n && n.options !== undefined && n.selected !== undefined && n.currentValue !== undefined }
                catch (e) { return false }
            })
            verify(seg, "SegmentedControl present")
            var t = G.findPred(seg, function (n) {
                try { return n && n.text === label && n.visible } catch (e) { return false }
            })
            verify(t, "segment option present: " + label)
            mouseClick(t, Math.round(t.width / 2), Math.round(t.height / 2))
            wait(180)
        }
        // The mm:ss clock readout currently on screen (FocusWidget).
        function clockText() {
            var t = G.findPred(wh.item, function (n) {
                try { return n && n.text !== undefined && /^\d\d:\d\d$/.test("" + n.text) && n.visible }
                catch (e) { return false }
            })
            return t ? ("" + t.text) : ""
        }
        // Live TextField whose placeholder contains `sub`.
        function fieldByPlaceholder(sub) {
            var s = ("" + sub).toLowerCase()
            return G.findPred(wh.item, function (n) {
                try {
                    return n && n.placeholderText !== undefined
                        && ("" + n.placeholderText).toLowerCase().indexOf(s) >= 0 && G.isLive(n)
                } catch (e) { return false }
            })
        }
        function typeInto(field, str) {
            verify(field, "text field present")
            mouseClick(field, Math.round(field.width / 2), Math.round(field.height / 2))
            field.forceActiveFocus(); wait(80)
            for (var i = 0; i < str.length; i++) { keyClick(str.charAt(i)); }
            wait(80)
        }
        // A grid "signature" of a grab, for change detection.
        function gridSig(img) {
            var s = ""
            for (var y = 1; y < 5; y++)
                for (var x = 1; x < 5; x++)
                    s += "" + img.pixel(Math.floor(img.width * x / 5), Math.floor(img.height * y / 5))
            return s
        }
        function backdropLayer() {
            return G.findPred(wh.item, function (n) {
                try { return n && n.style !== undefined && n.accent !== undefined && n.running !== undefined }
                catch (e) { return false }
            })
        }

        // ══════════════════════════════════════════════════════════════════════
        // FOCUS - sizes
        // ══════════════════════════════════════════════════════════════════════
        function test_focus_sizes_data() {
            return [
                { tag: "landscape-1x1",   sc: "compact", w: 846,  h: 612 },
                { tag: "portrait-1x1",    sc: "compact", w: 696,  h: 818 },
                { tag: "portrait-1x1.5",  sc: "tall",    w: 696,  h: 1226 },
                { tag: "landscape-1x1.5", sc: "wide",    w: 1268, h: 612 }
            ]
        }
        function test_focus_sizes(d) {
            prep("FocusWidget.qml", d.sc, d.w, d.h, false,
                 { preset: "classic", phase: "work", running: false,
                   pausedRemaining: 1500, dailyGoal: 4, doneToday: 2,
                   day: todayKey(), points: 20 })
            compare(wh.item.width, d.w, "cell width")
            compare(wh.item.height, d.h, "cell height")
            var img = snap(wh, "focus_size_" + d.tag)
            verify(G.looksRendered(img), "focus rendered content")
            verify(clockText() !== "", "clock readout present (" + clockText() + ")")
            var phaseLabel = G.byText(wh.item, "Focus")
            verify(phaseLabel !== null, "phase label 'Focus' visible")
            verify(phaseLabel.font.pixelSize >= wh.theme.fontTitle,
                   "phase label meets the arm-length title floor")
            var runway = G.byObjName(wh.item, "focusRunway")
            verify(runway !== null, "focus session runway exists")
            compare(runway.visible, d.sc === "wide" || d.sc === "tall",
                    "1x1.5 earns now, next, cycle, goal and points context")
            var controls = G.byObjName(wh.item, "focusTileControls")
            verify(controls !== null && controls.visible,
                   "focus primary controls are visible at " + d.tag)
            var p = controls.mapToItem(wh.item, 0, 0)
            verify(p.x >= -0.5 && p.y >= -0.5
                   && p.x + controls.width <= wh.item.width + 0.5
                   && p.y + controls.height <= wh.item.height + 0.5,
                   "focus controls stay inside " + d.tag + " ("
                   + Math.round(p.x) + "," + Math.round(p.y) + " "
                   + Math.round(controls.width) + "x" + Math.round(controls.height)
                   + " in " + d.w + "x" + d.h + ")")
        }

        // FOCUS - config fields (drive store, assert visible output)
        function test_focus_config_data() {
            return [
                { tag: "workMin-26", sc: "tall", w: 696, h: 1229, seed: { preset: "custom", workMin: 26, phase: "work" }, want: "26:00" },
                { tag: "workMin-45", sc: "tall", w: 696, h: 1229, seed: { preset: "custom", workMin: 45, phase: "work" }, want: "45:00" },
                { tag: "breakMin-10", sc: "tall", w: 696, h: 1229, seed: { preset: "custom", breakMin: 10, phase: "short" }, want: "10:00" },
                { tag: "breakMin-02", sc: "tall", w: 696, h: 1229, seed: { preset: "custom", breakMin: 2, phase: "short" }, want: "02:00" }
            ]
        }
        function test_focus_config(d) {
            prep("FocusWidget.qml", d.sc, d.w, d.h, false, d.seed)
            wait(150)
            compare(clockText(), d.want, "idle clock reflects config")
        }

        function test_focus_momentum_config_data() {
            return [
                { tag: "dailyGoal-6", seed: { dailyGoal: 6 }, sub: "/ 6 today", present: true },
                { tag: "dailyGoal-3", seed: { dailyGoal: 3 }, sub: "/ 3 today", present: true },
                { tag: "rewardPoints-on", seed: { rewardPoints: true, points: 7 }, sub: "7 pts", present: true },
                { tag: "rewardPoints-off", seed: { rewardPoints: false, points: 7 }, sub: "pts", present: false },
                { tag: "nudges-on", seed: { showNudges: true, phase: "work" }, sub: "One small step", present: true },
                { tag: "nudges-off", seed: { showNudges: false, phase: "work" }, sub: "One small step", present: false },
                { tag: "breakSug-on", seed: { breakSuggestions: true, phase: "short" }, sub: "Break idea", present: true },
                { tag: "breakSug-off", seed: { breakSuggestions: false, phase: "short" }, sub: "Break idea", present: false }
            ]
        }
        function test_focus_momentum_config(d) {
            prep("FocusWidget.qml", "tall", 696, 1229, false, d.seed)
            wait(150)
            var found = G.byText(wh.item, d.sub)
            snap(wh, "focus_cfg_" + d.tag)
            if (d.present) verify(found !== null, "expected on-screen text: " + d.sub)
            else verify(found === null, "text should be absent: " + d.sub)
        }

        function test_focus_title_override() {
            prep("FocusWidget.qml", "full", 900, 680, true, { preset: "classic" })
            wh.item.titleOverride = "Deep Work"; wait(180)
            verify(G.byText(wh.item, "Deep Work") !== null, "header shows titleOverride")
            snap(wh, "focus_title")
        }

        // FOCUS - body interactions
        function test_focus_start() {
            prep("FocusWidget.qml", "compact", 846, 612, false, { preset: "classic", running: false, phase: "work" })
            var p = pill("Start"); verify(p, "Start pill present")
            clickItem(p)
            verify(stg().running === true, "running became true")
            verify(pill("Pause") !== null, "label flipped to Pause")
            snap(wh, "focus_start")
        }
        function test_focus_pause() {
            prep("FocusWidget.qml", "compact", 846, 612, false,
                 { preset: "classic", running: true, phase: "work", endEpoch: Date.now() + 600000 })
            var p = pill("Pause"); verify(p, "Pause pill present")
            clickItem(p)
            verify(stg().running === false, "running became false")
            verify(pill("Start") !== null, "label flipped to Start")
        }
        function test_focus_plus5_paused() {
            prep("FocusWidget.qml", "tall", 696, 1229, false,
                 { preset: "classic", running: false, phase: "work", pausedRemaining: 1500 })
            wait(120)
            compare(clockText(), "25:00", "starts at 25:00")
            var p = pill("+5"); verify(p, "+5 pill present (tall)")
            clickItem(p); wait(150)
            compare(clockText(), "30:00", "+5 added 5 minutes")
        }
        function test_focus_plus5_running() {
            prep("FocusWidget.qml", "tall", 696, 1229, false,
                 { preset: "classic", running: true, phase: "work", endEpoch: Date.now() + 600000 })
            wait(120)
            var before = clockText()
            var p = pill("+5"); verify(p, "+5 pill present")
            clickItem(p); wait(150)
            var after = clockText()
            verify(after !== before, "clock changed after +5 (" + before + "->" + after + ")")
            verify(parseInt(after) > parseInt(before), "minutes increased")
        }
        function test_focus_skip() {
            prep("FocusWidget.qml", "compact", 846, 612, false,
                 { preset: "classic", running: false, phase: "work", doneToday: 0, day: todayKey() })
            var p = pill("Skip"); verify(p, "Skip pill present")
            clickItem(p); wait(150)
            compare(stg().phase, "work", "first Skip tap does not advance")
            var confirm = pill("Confirm")
            verify(confirm !== null, "first tap changes the same control to Confirm")
            snap(wh, "focus_skip_armed")
            clickItem(confirm); wait(150)
            verify(G.byText(wh.item, "Short Break") !== null, "advanced to a break phase")
            verify((stg().doneToday || 0) === 0, "manual Skip did NOT count a session")
            snap(wh, "focus_skip")
        }
        function test_focus_preset_data() {
            return [
                { tag: "classic", seg: "Classic", want: "25:00", val: "classic", seed: {} },
                { tag: "deep",    seg: "Deep",    want: "50:00", val: "deep", seed: {} },
                { tag: "sprint",  seg: "Sprint",  want: "15:00", val: "sprint", seed: {} },
                { tag: "custom",  seg: "Custom",  want: "33:00", val: "custom", seed: { workMin: 33 } }
            ]
        }
        function test_focus_preset(d) {
            var seed = { preset: "classic", running: false, phase: "work" }
            for (var k in d.seed) seed[k] = d.seed[k]
            prep("FocusWidget.qml", "full", 900, 680, true, seed)
            segClick(d.seg); wait(200)
            compare(stg().preset, d.val, "preset store key updated")
            compare(clockText(), d.want, "clock reseeded to preset work length")
            snap(wh, "focus_preset_" + d.tag)
        }
        function test_focus_reset() {
            prep("FocusWidget.qml", "full", 900, 680, true,
                 { preset: "classic", phase: "short", running: true, doneToday: 3, points: 30,
                   day: todayKey(), pausedRemaining: 120, endEpoch: Date.now() + 120000 })
            var p = pill("Reset"); verify(p, "Reset pill present")
            clickItem(p); wait(200)
            verify(G.byText(wh.item, "FOCUS") !== null, "phase reset to work (FOCUS)")
            compare(stg().doneToday, 3, "session count preserved")
            compare(stg().points, 30, "points preserved")
            compare(clockText(), "25:00", "clock reset to work length")
        }

        // FOCUS - states
        function test_focus_states_data() {
            return [
                { tag: "idle-label", seed: { running: false, phase: "work" }, kind: "text", sub: "Start", present: true },
                { tag: "running-label", seed: { running: true, phase: "work", endEpoch: Date.now() + 600000 }, kind: "text", sub: "Pause", present: true },
                { tag: "phase-short", seed: { phase: "short", running: false }, kind: "text", sub: "Short Break", present: true },
                { tag: "phase-long", seed: { phase: "long", running: false }, kind: "text", sub: "Long Break", present: true },
                { tag: "phase-work", seed: { phase: "work", running: false }, kind: "text", sub: "Focus", present: true }
            ]
        }
        function test_focus_states(d) {
            prep("FocusWidget.qml", "compact", 846, 612, false, d.seed)
            wait(120)
            var f = G.byText(wh.item, d.sub)
            snap(wh, "focus_state_" + d.tag)
            if (d.present) verify(f !== null, "expected visible text: " + d.sub)
            else verify(f === null, "unexpected text: " + d.sub)
        }
        function test_focus_momentum_visibility_data() {
            return [
                { tag: "shown-tall", sc: "tall", w: 696, h: 1229, present: true },
                { tag: "hidden-compact", sc: "compact", w: 846, h: 612, present: false }
            ]
        }
        function test_focus_momentum_visibility(d) {
            prep("FocusWidget.qml", d.sc, d.w, d.h, false, { dailyGoal: 4, day: todayKey(), doneToday: 2 })
            wait(120)
            var f = G.byText(wh.item, "today")
            snap(wh, "focus_momentum_" + d.tag)
            if (d.present) verify(f !== null, "momentum readout visible at 1x1.5")
            else verify(f === null, "momentum hidden at 1x1")
        }
        function test_focus_dots_count() {
            prep("FocusWidget.qml", "tall", 696, 1229, false, { dailyGoal: 4, day: todayKey(), doneToday: 2 })
            wait(120)
            verify(G.byText(wh.item, "2 / 4 today") !== null, "momentum count reflects completedWork")
            snap(wh, "focus_dots")
        }

        // FOCUS - natural completion (driven by a past endEpoch + the 1s tick)
        function test_focus_natural_short() {
            prep("FocusWidget.qml", "compact", 846, 612, false,
                 { preset: "classic", phase: "work", running: true, doneToday: 0, day: todayKey(),
                   endEpoch: Date.now() - 3000 })
            tryVerify(function () { return G.byText(wh.item, "Short Break") !== null }, 3000,
                      "work completed -> Short Break")
            compare(stg().doneToday, 1, "natural completion counted one session")
            snap(wh, "focus_natural_short")
        }
        function test_focus_natural_goal() {
            prep("FocusWidget.qml", "tall", 696, 1229, false,
                 { preset: "classic", phase: "work", running: true, doneToday: 1, dailyGoal: 2,
                   celebrate: true, day: todayKey(), endEpoch: Date.now() - 3000 })
            // Wait for the STATE the completion produces, not for a frame.
            //
            // The expiry is noticed by the widget's own repeating 1s timer
            // (FocusWidget.qml: `Timer { interval: 1000; running: w.active }`),
            // so the thing being waited for is one tick of that timer - not a
            // render. This used to poll the scene for a visible "Goal" Text
            // within 3s, which conflated "the session completed" with "the
            // banner is on screen" and went red on a CI runner that was starved
            // by two hung compositor slots. `celebrateMsg` is set by
            // celebrateNow() and never cleared (prep() blanks it per case), so
            // it is the durable witness that the goal celebration fired; the
            // label it drives fades back to opacity 0 about a second later.
            tryVerify(function () { return ("" + wh.item.celebrateMsg).indexOf("Goal") >= 0 },
                      8000, "the session that crossed the goal celebrated")
            compare(stg().doneToday, 2, "session that crossed the goal counted")
            // The ONE-TIME goal bonus, not just any celebration: 10 for the
            // session plus 50 for crossing the goal. This is what distinguishes
            // this case from test_focus_natural_short, and it is durable state,
            // so asserting it here cannot race.
            compare(stg().points, 60, "crossing the goal awarded the one-time bonus")
            // And the banner really is wired to that message. Deterministic once
            // celebrateMsg is set: the Text keeps its text and stays `visible`
            // (only its opacity animates), so this is a binding check, not a
            // race against the fade-out.
            var banner = G.byText(wh.item, "Goal")
            verify(banner !== null, "the celebration banner carries the goal message")
            verify(banner.width > 0 && banner.height > 0,
                   "the celebration banner has a rendered box")
            snap(wh, "focus_natural_goal")
        }
        function test_focus_autostart_data() {
            return [
                { tag: "off", seed: { autoStartBreak: false }, wantRunning: false, wantPill: "Start" },
                { tag: "on", seed: { autoStartBreak: true }, wantRunning: true, wantPill: "Pause" }
            ]
        }
        function test_focus_autostart(d) {
            var seed = { preset: "classic", phase: "work", running: true, doneToday: 0,
                         day: todayKey(), endEpoch: Date.now() - 3000 }
            for (var k in d.seed) seed[k] = d.seed[k]
            prep("FocusWidget.qml", "compact", 846, 612, false, seed)
            tryVerify(function () { return G.byText(wh.item, "Short Break") !== null }, 3000, "reached break")
            wait(200)
            verify(pill(d.wantPill) !== null, "break running=" + d.wantRunning + " -> pill " + d.wantPill)
            snap(wh, "focus_autostart_" + d.tag)
        }
        function test_focus_celebrate_off() {
            prep("FocusWidget.qml", "compact", 846, 612, false,
                 { preset: "classic", phase: "work", running: true, doneToday: 0, celebrate: false,
                   day: todayKey(), endEpoch: Date.now() - 3000 })
            tryVerify(function () { return (stg().doneToday || 0) === 1 }, 3000, "session completed")
            wait(300)
            verify(G.byText(wh.item, "Nice") === null, "no celebration banner when celebrate off")
            verify(G.byText(wh.item, "Goal") === null, "no goal banner either")
        }

        // FOCUS - chrome (backdrop + accent)
        function test_focus_backdrop_data() {
            return [
                { tag: "none", style: "none", vis: false },
                { tag: "orbs", style: "orbs", vis: true },
                { tag: "mesh", style: "mesh", vis: true },
                { tag: "aurora", style: "aurora", vis: true },
                { tag: "waves", style: "waves", vis: true },
                { tag: "stars", style: "stars", vis: true },
                { tag: "bokeh", style: "bokeh", vis: true },
                { tag: "grid", style: "grid", vis: true }
            ]
        }
        function test_focus_backdrop(d) {
            prep("FocusWidget.qml", "compact", 846, 612, false, { preset: "classic" })
            wh.item.cardBackdrop = d.style; wait(200)
            var bl = backdropLayer(); verify(bl, "BackdropLayer present")
            compare(bl.visible, d.vis, "backdrop '" + d.style + "' visibility")
            snap(wh, "focus_backdrop_" + d.tag)
        }
        function test_focus_accent_override() {
            prep("FocusWidget.qml", "compact", 846, 612, false, { preset: "classic" })
            wh.item.accentName = ""; wait(150)
            var base = gridSig(grabImage(wh))
            wh.item.accentName = "green"; wait(250)
            var after = gridSig(grabImage(wh))
            snap(wh, "focus_accent")
            verify(after !== base, "accent override changed rendered pixels")
        }

        // ══════════════════════════════════════════════════════════════════════
        // RIGHT NOW - sizes
        // ══════════════════════════════════════════════════════════════════════
        function test_rightnow_sizes_data() {
            return [
                { tag: "portrait-0.5x0.5",  sc: "compact", w: 348,  h: 409 },
                { tag: "landscape-0.5x0.5", sc: "compact", w: 423,  h: 306 },
                { tag: "portrait-0.5x1",    sc: "tall",    w: 348,  h: 818 },
                { tag: "landscape-0.5x1",   sc: "wide",    w: 846,  h: 306 },
                { tag: "portrait-1x0.5",    sc: "wide",    w: 696,  h: 409 },
                { tag: "landscape-1x0.5",   sc: "tall",    w: 423,  h: 612 },
                { tag: "portrait-1x1",      sc: "compact", w: 696,  h: 818 },
                { tag: "landscape-1x1",     sc: "compact", w: 846,  h: 612 },
                { tag: "portrait-1x1.5",    sc: "tall",    w: 696,  h: 1226 },
                { tag: "landscape-1x1.5",   sc: "wide",    w: 1268, h: 612 }
            ]
        }
        function test_rightnow_sizes(d) {
            prep("RightNowWidget.qml", d.sc, d.w, d.h, false,
                 { text: "Finish the release notes", startedAt: Date.now() - 17 * 60000,
                   finishedToday: 2, day: todayKey() })
            compare(wh.item.width, d.w, "cell width")
            compare(wh.item.height, d.h, "cell height")
            var img = snap(wh, "rn_size_" + d.tag)
            verify(G.looksRendered(img), "right-now rendered content")
            verify(G.byText(wh.item, "Finish the release notes") !== null, "focus text hero visible")
            var hero = G.byObjName(wh.item, "rightNowHero")
            verify(hero !== null && hero.font.pixelSize >= wh.theme.fontTitle,
                   "focus remains at the title legibility floor")
            var context = G.byObjName(wh.item, "rightNowFocusContext")
            verify(context !== null, "focus context card exists")
            var rich = d.tag.indexOf("1x1.5") >= 0
            compare(context.visible, rich,
                    "1x1.5 earns started, elapsed and finished context")
            compare(pill("Done") !== null, d.tag.indexOf("0.5x0.5") < 0,
                    "every non-micro tile exposes the primary completion action")
            var elapsed = G.byObjName(wh.item, "rightNowElapsed")
            compare(elapsed !== null && elapsed.visible,
                    d.tag.indexOf("0.5x0.5") < 0 && !rich,
                    "non-micro tiles report elapsed context without duplicating the rich panel")
            if (elapsed && elapsed.visible)
                verify(elapsed.font.pixelSize >= wh.theme.fontLabel,
                       "elapsed context uses the readable label floor")
            if (rich)
                verify(G.byText(context, "17 min") !== null,
                       "the rich panel owns the elapsed context")
        }

        function test_rightnow_long_focus_wraps_before_eliding() {
            prep("RightNowWidget.qml", "compact", 696, 819, false, {
                text: "Prepare the release notes and verify every package checksum",
                startedAt: Date.now() - 8 * 60000
            })
            wait(150)
            var hero = G.byObjName(wh.item, "rightNowHero")
            verify(hero !== null)
            verify(hero.lineCount > 1, "long focus wraps onto multiple lines")
            verify(hero.lineCount <= hero.maximumLineCount)
            verify(hero.font.pixelSize >= wh.theme.fontTitle)
            snap(wh, "rn_long_wrapped")
        }

        // RIGHT NOW - config
        function test_rightnow_config_data() {
            return [
                { tag: "text-set", seed: { text: "finish report" }, sub: "finish report", present: true, placeholderGone: true },
                { tag: "text-clear", seed: { text: "" }, sub: "Tap to set your one focus", present: true, placeholderGone: false }
            ]
        }
        function test_rightnow_config(d) {
            prep("RightNowWidget.qml", "compact", 696, 819, false, d.seed)
            wait(120)
            verify(G.byText(wh.item, d.sub) !== null, "expected text: " + d.sub)
            snap(wh, "rn_cfg_" + d.tag)
        }
        function test_rightnow_title_override() {
            prep("RightNowWidget.qml", "full", 700, 680, true, { text: "x" })
            wh.item.titleOverride = "My Focus"; wait(180)
            verify(G.byText(wh.item, "My Focus") !== null, "expanded header shows titleOverride")
        }

        // RIGHT NOW - body interactions
        function test_rightnow_done_tile() {
            prep("RightNowWidget.qml", "compact", 696, 819, false, { text: "ship it", day: todayKey(), finishedToday: 0 })
            wait(120)
            var p = pill("Done"); verify(p, "Done pill present on tile with focus")
            clickItem(p); wait(200)
            compare(stg().text, "", "focus cleared after Done")
            verify(G.byText(wh.item, "1 today") !== null, "finished-today count shows")
            snap(wh, "rn_done_tile")
        }
        function test_rightnow_save_expanded() {
            prep("RightNowWidget.qml", "full", 700, 680, true, { text: "" })
            var f = fieldByPlaceholder("Finish the report"); verify(f, "editor field present")
            typeInto(f, "call bob")
            var p = pill("Save"); verify(p, "Save pill present")
            clickItem(p); wait(200)
            compare(stg().text, "call bob", "typed text persisted via Save")
            wh.expanded = false; wait(250)
            verify(G.byText(wh.item, "call bob") !== null, "tile hero shows saved focus")
            snap(wh, "rn_save")
        }
        function test_rightnow_done_expanded() {
            prep("RightNowWidget.qml", "full", 700, 680, true, { text: "", day: todayKey(), finishedToday: 0 })
            var f = fieldByPlaceholder("Finish the report"); verify(f, "editor field present")
            typeInto(f, "email jane")
            var p = pill("Done!"); verify(p, "Done! pill present")
            verify(p.enabledState === true, "Done! enabled with non-blank field")
            clickItem(p); wait(200)
            verify(G.byText(wh.item, "finished today") !== null, "finished-count line shows")
            verify((stg().finishedToday || 0) >= 1, "finishedToday incremented")
            snap(wh, "rn_done_expanded")
        }
        function test_rightnow_clear_requires_confirmation() {
            prep("RightNowWidget.qml", "full", 700, 680, true,
                 { text: "Keep this focus", startedAt: Date.now() })
            var p = pill("Clear"); verify(p, "Clear pill present")
            clickItem(p); wait(120)
            compare(stg().text, "Keep this focus",
                    "first Clear tap changes no data")
            var confirm = pill("Confirm")
            verify(confirm !== null && wh.item.clearArmed,
                   "Clear enters an explicit confirmation state")
            snap(wh, "rn_clear_armed")
            clickItem(confirm); wait(180)
            compare(stg().text, "", "confirmed Clear removes the focus")
        }

        // RIGHT NOW - states
        function test_rightnow_states_data() {
            return [
                { tag: "empty-placeholder", sc: "compact", w: 696, h: 819, exp: false, seed: { text: "" }, sub: "Tap to set your one focus", present: true },
                { tag: "hero-focus", sc: "compact", w: 696, h: 819, exp: false, seed: { text: "deep work" }, sub: "deep work", present: true },
                { tag: "count-today", sc: "compact", w: 696, h: 819, exp: false, seed: { text: "task", finishedToday: 2, day: "TODAY" }, sub: "2 today", present: true },
                { tag: "micro-text-only", sc: "compact", w: 348, h: 409, exp: false, seed: { text: "go" }, sub: "RIGHT NOW", present: false },
                { tag: "eyebrow-shown", sc: "compact", w: 696, h: 819, exp: false, seed: { text: "go" }, sub: "RIGHT NOW", present: true },
                { tag: "expanded-prompt", sc: "full", w: 700, h: 680, exp: true, seed: { text: "" }, sub: "What's the one thing right now?", present: true },
                { tag: "expanded-placeholder", sc: "full", w: 700, h: 680, exp: true, seed: { text: "" }, sub: "e.g. Finish the report", present: true, field: true },
                { tag: "no-done-when-empty", sc: "compact", w: 696, h: 819, exp: false, seed: { text: "" }, sub: "Done", present: false }
            ]
        }
        function test_rightnow_states(d) {
            var seed = {}
            for (var k in d.seed) seed[k] = d.seed[k]
            if (seed.day === "TODAY") seed.day = todayKey()
            prep("RightNowWidget.qml", d.sc, d.w, d.h, d.exp, seed)
            wait(140)
            var f = d.field ? fieldByPlaceholder(d.sub)
                    : (d.sub === "Done") ? pill("Done") : G.byText(wh.item, d.sub)
            snap(wh, "rn_state_" + d.tag)
            if (d.present) verify(f !== null, "expected: " + d.sub)
            else verify(f === null, "should be absent: " + d.sub)
        }

        // RIGHT NOW - chrome
        function test_rightnow_backdrop_data() {
            return [
                { tag: "none", style: "none", vis: false },
                { tag: "orbs", style: "orbs", vis: true },
                { tag: "mesh", style: "mesh", vis: true },
                { tag: "aurora", style: "aurora", vis: true },
                { tag: "waves", style: "waves", vis: true },
                { tag: "stars", style: "stars", vis: true }
            ]
        }
        function test_rightnow_backdrop(d) {
            prep("RightNowWidget.qml", "compact", 696, 819, false, { text: "hi" })
            wh.item.cardBackdrop = d.style; wait(200)
            var bl = backdropLayer(); verify(bl, "BackdropLayer present")
            compare(bl.visible, d.vis, "backdrop '" + d.style + "'")
            snap(wh, "rn_backdrop_" + d.tag)
        }
        function test_rightnow_accent_override() {
            prep("RightNowWidget.qml", "compact", 696, 819, false, { text: "deep work" })
            wh.item.accentName = ""; wait(150)
            var base = gridSig(grabImage(wh))
            wh.item.accentName = "green"; wait(250)
            var after = gridSig(grabImage(wh))
            snap(wh, "rn_accent")
            verify(after !== base, "accent override changed the hero pixels")
        }

        // ══════════════════════════════════════════════════════════════════════
        // TASKS - sizes
        // ══════════════════════════════════════════════════════════════════════
        function test_tasks_sizes_data() {
            return [
                { tag: "portrait-0.5x1",    sc: "tall",    w: 348,  h: 818 },
                { tag: "landscape-0.5x1",   sc: "wide",    w: 846,  h: 306 },
                { tag: "portrait-1x0.5",    sc: "wide",    w: 696,  h: 409 },
                { tag: "landscape-1x0.5",   sc: "tall",    w: 423,  h: 612 },
                { tag: "portrait-1x1",      sc: "compact", w: 696,  h: 818 },
                { tag: "landscape-1x1",     sc: "compact", w: 846,  h: 612 },
                { tag: "portrait-1x1.5",    sc: "tall",    w: 696,  h: 1226 },
                { tag: "landscape-1x1.5",   sc: "wide",    w: 1268, h: 612 },
                { tag: "portrait-1x2",      sc: "large",   w: 696,  h: 1635 },
                { tag: "landscape-1x2",     sc: "large",   w: 1691, h: 612 },
                { tag: "portrait-1x3",      sc: "large",   w: 696,  h: 2452 },
                { tag: "landscape-1x3",     sc: "large",   w: 2536, h: 612 }
            ]
        }
        function test_tasks_sizes(d) {
            var items = []
            for (var i = 1; i <= 48; i++)
                items.push({ id: "visual-" + i,
                             text: "Task " + (i < 10 ? "0" : "") + i,
                             done: i % 4 === 0 })
            prep("TasksWidget.qml", d.sc, d.w, d.h, false, { items: items })
            compare(wh.item.width, d.w, "cell width")
            compare(wh.item.height, d.h, "cell height")
            var img = snap(wh, "tasks_size_" + d.tag)
            verify(G.looksRendered(img), "tasks rendered content")
            verify(G.byText(wh.item, "Task 01") !== null, "first task row visible")
            var list = G.byObjName(wh.item, "tasksList")
            verify(list !== null && list.height >= wh.item.rowH, "at least one complete touch row fits")
            var overflow = G.byObjName(wh.item, "tasksOverflowFooter")
            verify(overflow !== null && overflow.visible,
                   "the tile reports tasks that do not fit")
            verify(String(overflow.Accessible.name).indexOf("more tasks") >= 0,
                   "overflow disclosure is accessible")
            var summary = G.byObjName(wh.item, "tasksProgressSummary")
            verify(summary !== null, "task progress summary exists")
            var largest = d.tag.indexOf("1x1.5") >= 0 || d.tag.indexOf("1x2") >= 0
                          || d.tag.indexOf("1x3") >= 0
            compare(summary.visible, largest,
                    "roomy task sizes earn open, completed and percent context")
            if (d.sc === "large")
                compare(wh.item.horiz, d.tag.indexOf("landscape") === 0,
                        "large task layouts follow their physical orientation")
        }

        // TASKS - config / display
        function test_tasks_config_data() {
            return [
                { tag: "hide-on", seed: { items: [{ text: "done one", done: true }, { text: "todo one", done: false }], hideCompleted: true }, hidden: "done one", shown: "todo one" },
                { tag: "hide-off", seed: { items: [{ text: "done one", done: true }, { text: "todo one", done: false }], hideCompleted: false }, hidden: "", shown: "done one" }
            ]
        }
        function test_tasks_config(d) {
            prep("TasksWidget.qml", "compact", 696, 819, false, d.seed)
            wait(150)
            verify(G.byText(wh.item, d.shown) !== null, "expected visible row: " + d.shown)
            if (d.hidden !== "")
                verify(G.byText(wh.item, d.hidden) === null, "hidden row absent: " + d.hidden)
            snap(wh, "tasks_cfg_" + d.tag)
        }
        function test_tasks_title_override() {
            prep("TasksWidget.qml", "compact", 696, 819, false, { items: [] })
            wh.item.titleOverride = "My Todo"; wait(180)
            verify(G.byText(wh.item, "My Todo") !== null, "header shows titleOverride")
        }
        function test_tasks_status_count() {
            prep("TasksWidget.qml", "compact", 696, 819, false,
                 { items: [{ text: "a", done: true }, { text: "b", done: false }, { text: "c", done: false }] })
            wait(150)
            verify(G.byText(wh.item, "1/3") !== null, "header status reflects done/total")
            snap(wh, "tasks_status")
        }

        // TASKS - body interactions
        function test_tasks_add_enter() {
            prep("TasksWidget.qml", "compact", 846, 612, false, { items: [] })
            var f = fieldByPlaceholder("Add"); verify(f, "add field present")
            typeInto(f, "buy milk")
            keyClick(Qt.Key_Return); wait(250)
            compare((stg().items || []).length, 1, "one task added")
            verify(G.byText(wh.item, "buy milk") !== null, "new row visible")
            compare(f.text, "", "field cleared after Enter")
            snap(wh, "tasks_add_enter")
        }
        function test_tasks_add_button() {
            prep("TasksWidget.qml", "compact", 846, 612, false, { items: [] })
            var f = fieldByPlaceholder("Add"); verify(f, "add field present")
            typeInto(f, "call mom")
            var p = pill(""); verify(p, "add (＋) pill present")   // tile add button has empty label
            clickItem(p); wait(250)
            compare((stg().items || []).length, 1, "one task added via button")
            verify(G.byText(wh.item, "call mom") !== null, "new row visible")
        }
        function test_tasks_add_expanded_button() {
            prep("TasksWidget.qml", "full", 800, 680, true, { items: [] })
            var f = fieldByPlaceholder("Add a task"); verify(f, "expanded add field present")
            typeInto(f, "water plants")
            var p = pill("Add"); verify(p, "Add pill present (expanded)")
            clickItem(p); wait(250)
            compare((stg().items || []).length, 1, "task added via Add button")
            verify(G.byText(wh.item, "water plants") !== null, "row visible")
        }
        function test_tasks_check_toggle() {
            prep("TasksWidget.qml", "compact", 846, 612, false, { items: [{ text: "read book", done: false }] })
            wait(120)
            verify(G.byText(wh.item, "read book"), "task row present")
            var toggle = G.byObjName(wh.item, "taskToggle-0"); verify(toggle, "explicit task toggle present")
            mouseClick(toggle, Math.round(toggle.width / 2), Math.round(toggle.height / 2)); wait(200)
            compare(stg().items[0].done, true, "task marked done")
            verify(G.findPred(wh.item, function (n) {
                try { return n && n.text === "✓" && n.visible } catch (e) { return false } }) !== null,
                "check glyph now visible")
            snap(wh, "tasks_check")
        }
        function test_tasks_check_expanded() {
            prep("TasksWidget.qml", "full", 800, 680, true, { items: [{ text: "task x", done: false }] })
            wait(120)
            var toggle = G.byObjName(wh.item, "taskToggle-0"); verify(toggle, "task toggle present")
            mouseClick(toggle, Math.round(toggle.width / 2), Math.round(toggle.height / 2)); wait(200)
            compare(stg().items[0].done, true, "toggled done in expanded view")
        }
        function test_tasks_uncheck() {
            prep("TasksWidget.qml", "compact", 846, 612, false, { items: [{ text: "old task", done: true }] })
            wait(120)
            verify(G.byText(wh.item, "old task"), "row present")
            var toggle = G.byObjName(wh.item, "taskToggle-0"); verify(toggle, "explicit task toggle present")
            mouseClick(toggle, Math.round(toggle.width / 2), Math.round(toggle.height / 2)); wait(200)
            compare(stg().items[0].done, false, "task un-checked")
        }
        function test_tasks_delete_expanded() {
            prep("TasksWidget.qml", "full", 800, 680, true,
                 { items: [{ text: "first", done: false }, { text: "second", done: false }] })
            wait(150)
            var x = G.findPred(wh.item, function (n) {
                try { return n && n.text === "✕" && n.visible } catch (e) { return false } })
            verify(x, "remove ✕ present (expanded)")
            mouseClick(x, Math.round(x.width / 2), Math.round(x.height / 2)); wait(250)
            compare((stg().items || []).length, 1, "one row removed")
            compare(stg().items[0].text, "second",
                    "the intended first row was removed")
            verify(G.byText(wh.item, "second") !== null, "second row remains")
            var undo = pill("Undo")
            verify(undo !== null, "removal offers immediate undo")
            snap(wh, "tasks_delete")
            clickItem(undo); wait(200)
            compare((stg().items || []).length, 2, "undo restores the removed task")
            verify(G.byText(wh.item, "first") !== null, "restored task is visible")
        }
        function test_tasks_remove_hidden_on_tile() {
            prep("TasksWidget.qml", "compact", 696, 819, false, { items: [{ text: "keepme", done: false }] })
            wait(120)
            var x = G.findPred(wh.item, function (n) {
                try { return n && n.text === "✕" && n.visible } catch (e) { return false } })
            verify(x === null, "remove ✕ hidden on non-expanded tile")
        }
        function test_tasks_clear_completed() {
            prep("TasksWidget.qml", "full", 800, 680, true,
                 { items: [{ text: "finished", done: true }, { text: "pending", done: false }] })
            wait(150)
            var p = pill("Clear 1 completed"); verify(p, "clear-completed pill present")
            clickItem(p); wait(250)
            verify(wh.item.clearArmed, "first tap arms the destructive clear")
            clickItem(p); wait(250)
            compare((stg().items || []).length, 1, "completed cleared")
            verify(G.byText(wh.item, "pending") !== null, "pending task remains")
            verify(G.byText(wh.item, "finished") === null, "finished task removed")
            snap(wh, "tasks_clear")
        }
        function test_tasks_celebrate_all_done() {
            prep("TasksWidget.qml", "compact", 846, 612, false,
                 { items: [{ text: "last one", done: false }], celebrate: true })
            wait(120)
            verify(G.byText(wh.item, "last one"), "row present")
            var toggle = G.byObjName(wh.item, "taskToggle-0"); verify(toggle, "explicit task toggle present")
            mouseClick(toggle, Math.round(toggle.width / 2), Math.round(toggle.height / 2))
            tryVerify(function () { return G.byText(wh.item, "All done") !== null }, 2000,
                      "all-done celebration banner shows")
            snap(wh, "tasks_celebrate")
        }
        function test_tasks_progress_bar() {
            prep("TasksWidget.qml", "compact", 696, 819, false,
                 { items: [{ text: "a", done: true }, { text: "b", done: false }] })
            wait(150)
            var outer = G.findPred(wh.item, function (n) {
                try { return n && ("" + n).indexOf("QQuickRectangle") >= 0 && n.radius === 3
                    && Math.round(n.height) === 6 && n.children && n.children.length > 0 && n.visible }
                catch (e) { return false } })
            verify(outer, "progress bar present")
            var fill = outer.children[0]
            var ratio = fill.width / outer.width
            verify(Math.abs(ratio - 0.5) < 0.12, "progress fill ≈ 50% (was " + ratio.toFixed(2) + ")")
            snap(wh, "tasks_progress")
        }
        function test_tasks_progress_full() {
            prep("TasksWidget.qml", "compact", 696, 819, false,
                 { items: [{ text: "a", done: true }, { text: "b", done: true }] })
            wait(150)
            var outer = G.findPred(wh.item, function (n) {
                try { return n && ("" + n).indexOf("QQuickRectangle") >= 0 && n.radius === 3
                    && Math.round(n.height) === 6 && n.children && n.children.length > 0 && n.visible }
                catch (e) { return false } })
            verify(outer, "progress bar present")
            var ratio = outer.children[0].width / outer.width
            verify(ratio > 0.9, "progress fill full when all done (" + ratio.toFixed(2) + ")")
        }

        // TASKS - states
        function test_tasks_states_data() {
            return [
                { tag: "empty-tile", sc: "compact", w: 696, h: 819, exp: false, seed: { items: [] }, sub: "No tasks", present: true },
                { tag: "empty-expanded", sc: "full", w: 800, h: 680, exp: true, seed: { items: [] }, sub: "Make the next move obvious", present: true },
                { tag: "completed-hidden", sc: "compact", w: 696, h: 819, exp: false,
                  seed: { items: [{ text: "done", done: true }], hideCompleted: true },
                  sub: "All 1 task completed", present: true },
                { tag: "populated", sc: "compact", w: 696, h: 819, exp: false, seed: { items: [{ text: "alpha", done: false }, { text: "beta", done: false }] }, sub: "alpha", present: true }
            ]
        }
        function test_tasks_states(d) {
            prep("TasksWidget.qml", d.sc, d.w, d.h, d.exp, d.seed)
            wait(150)
            var f = G.byText(wh.item, d.sub)
            snap(wh, "tasks_state_" + d.tag)
            if (d.present) verify(f !== null, "expected: " + d.sub)
            else verify(f === null, "should be absent: " + d.sub)
        }
        function test_tasks_hide_keeps_status() {
            prep("TasksWidget.qml", "compact", 696, 819, false,
                 { items: [{ text: "d1", done: true }, { text: "t1", done: false }], hideCompleted: true })
            wait(150)
            verify(G.byText(wh.item, "1/2") !== null, "status still counts hidden done items")
        }
        function test_tasks_wide_layout() {
            prep("TasksWidget.qml", "wide", 1269, 612, false,
                 { items: [{ text: "left row", done: false }] })
            wait(150)
            var f = fieldByPlaceholder("Add"); verify(f, "add field present in wide layout")
            var c = f.mapToItem(wh.item, f.width / 2, 0)
            verify(c.x > wh.item.width * 0.5, "add control sits in the right column (x=" + Math.round(c.x) + ")")
            snap(wh, "tasks_wide")
        }

        // TASKS - chrome
        function test_tasks_backdrop_data() {
            return [
                { tag: "none", style: "none", vis: false },
                { tag: "orbs", style: "orbs", vis: true },
                { tag: "mesh", style: "mesh", vis: true },
                { tag: "aurora", style: "aurora", vis: true }
            ]
        }
        function test_tasks_backdrop(d) {
            prep("TasksWidget.qml", "compact", 696, 819, false, { items: [{ text: "x", done: false }] })
            wh.item.cardBackdrop = d.style; wait(200)
            var bl = backdropLayer(); verify(bl, "BackdropLayer present")
            compare(bl.visible, d.vis, "backdrop '" + d.style + "'")
            snap(wh, "tasks_backdrop_" + d.tag)
        }
        function test_tasks_accent_override() {
            prep("TasksWidget.qml", "compact", 696, 819, false, { items: [{ text: "task", done: true }] })
            wh.item.accentName = ""; wait(150)
            var base = gridSig(grabImage(wh))
            wh.item.accentName = "green"; wait(250)
            var after = gridSig(grabImage(wh))
            snap(wh, "tasks_accent")
            verify(after !== base, "accent override recolours checkbox/icon pixels")
        }
    }
}
