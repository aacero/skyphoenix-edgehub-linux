import QtQuick
import QtTest
import "../ui" as UI
import "GuiUtil.js" as G

// Visible GUI tests for three "Info" Hub widgets - Countdown, End of Day, Daily
// Quote - hosted one at a time in a REAL KWin-composited window via
// UI.WidgetHarness and driven with real mouse/keyboard events. Every case
// asserts an OBJECTIVE, GUI-observable outcome (item visibility/geometry,
// on-screen text, grabImage pixel colour, store-setting → visible output) and
// saves a PNG to gui-evidence/ as morning-video evidence.
//
// Deterministic seams (seed, never sleep on the wall clock):
//   • countdown/quote - bump item.tick and set store `date`/`customText`.
//   • eod             - set item.nowOverride (a Date) so window math is fixed.
//
// Data-driven throughout to reach volume; every test_*_data() has its consumer.
Item {
    id: root
    width: 1800; height: 1700

    UI.WidgetHarness {
        id: wh
        anchors.left: parent.left; anchors.top: parent.top
        width: 600; height: 600
        widgetFile: "CountdownWidget.qml"
    }

    TestCase {
        id: tc
        name: "GuiWMisc"
        when: windowShown
        visible: true

        // ── evidence ────────────────────────────────────────────────────────
        function snap(item, name) {
            var i = grabImage(item)
            i.save("gui-evidence/wmisc_" + name + ".png")
            return i
        }

        // Physical projections are widget-specific. The catalog deliberately
        // gives these widgets different allocations, so sharing one list hid
        // unsupported cases and skipped real orientations.
        function countdownRows() {
            return [
                { tag: "p_0.5x0.5", w: 348, h: 409, cls: "compact", micro: true  },
                { tag: "l_0.5x0.5", w: 423, h: 306, cls: "compact", micro: true  },
                { tag: "p_0.5x1",   w: 348, h: 818, cls: "tall",    micro: false },
                { tag: "l_0.5x1",   w: 846, h: 306, cls: "wide",    micro: false },
                { tag: "p_1x0.5",   w: 696, h: 409, cls: "wide",    micro: false },
                { tag: "l_1x0.5",   w: 423, h: 612, cls: "tall",    micro: false },
                { tag: "p_1x1",     w: 696, h: 818, cls: "compact", micro: false },
                { tag: "l_1x1",     w: 846, h: 612, cls: "compact", micro: false }
            ]
        }
        function eodRows() {
            return countdownRows().concat([
                { tag: "p_1x1.5", w: 696,  h: 1226, cls: "tall", micro: false, roomy: true },
                { tag: "l_1x1.5", w: 1268, h: 612,  cls: "wide", micro: false, roomy: true }
            ])
        }
        function quoteRows() {
            return countdownRows()
        }
        function withRoomy(rows) {
            for (var i = 0; i < rows.length; i++)
                if (rows[i].roomy === undefined) rows[i].roomy = rows[i].cls === "tall"
            return rows
        }
        // The 8 cardBackdrop options asserted in every widget's chrome sweep.
        function backdropRows() {
            return [
                { tag: "none",   s: "none",   vis: false },
                { tag: "orbs",   s: "orbs",   vis: true },
                { tag: "mesh",   s: "mesh",   vis: true },
                { tag: "aurora", s: "aurora", vis: true },
                { tag: "waves",  s: "waves",  vis: true },
                { tag: "stars",  s: "stars",  vis: true },
                { tag: "bokeh",  s: "bokeh",  vis: true },
                { tag: "grid",   s: "grid",   vis: true }
            ]
        }
        function accentRows() {
            return [
                { tag: "override-red", name: "red", hue: "r" },
                { tag: "auto-green",   name: "",    hue: "g" }
            ]
        }

        // ── harness driving helpers ─────────────────────────────────────────
        function prep(file, opts) {
            if (wh.widgetFile !== file) {
                wh.widgetFile = file
                tryVerify(function () { return wh.ready }, 5000, "widget loaded: " + file)
            }
            verify(wh.ready, "harness ready")
            wh.expanded = false
            wh.storeCtl.resetSettings(wh.instanceId, opts || {})
            var it = wh.item
            it.accentName = ""
            it.cardBackdrop = "none"
            if (it.hasOwnProperty("nowOverride")) it.nowOverride = null
            wait(80)
        }
        function setSize(w0, h0, cls) {
            wh.width = w0; wh.height = h0
            wh.item.sizeClass = cls
            wait(120)
        }
        function bumpTick() { if (wh.item.hasOwnProperty("tick")) wh.item.tick++ }

        // ── scene-graph finders (effective visibility, walking parents) ──────
        function effVis(n) {
            var x = n
            while (x) { if (x.visible === false) return false; x = x.parent }
            return true
        }
        function txtNode(match) {
            return G.findPred(wh.item, function (n) {
                try {
                    if (!n || n.text === undefined || n.font === undefined) return false
                    if (!effVis(n)) return false
                    return match("" + n.text)
                } catch (e) { return false }
            })
        }
        function txtExact(s) { return txtNode(function (t) { return t === s }) }
        function txtHas(s)   { return txtNode(function (t) { return t.indexOf(s) >= 0 }) }
        function ringNode() {
            return G.findPred(wh.item, function (n) {
                try { return n && n.value !== undefined && n.progressColor !== undefined
                             && n.thickness !== undefined } catch (e) { return false }
            })
        }
        function ringVisible() { var r = ringNode(); return r !== null && effVis(r) }
        function backdropNode() {
            return G.findPred(wh.item, function (n) {
                try { return n && n.style !== undefined && n.running !== undefined
                             && n.accent !== undefined } catch (e) { return false }
            })
        }
        function pill(label) {
            return G.findPred(wh.item, function (n) {
                try { return n && n.label !== undefined && n.glyph !== undefined
                             && n.clicked !== undefined && ("" + n.label) === label
                             && effVis(n) } catch (e) { return false }
            })
        }
        function fieldByPlaceholder(ph) {
            return G.findPred(wh.item, function (n) {
                try { return n && n.placeholderText !== undefined
                             && ("" + n.placeholderText).indexOf(ph) >= 0
                             && effVis(n) } catch (e) { return false }
            })
        }
        // Track rectangle used by the countdown progress bar (height 6, radius 3).
        function trackNode() {
            return G.findPred(wh.item, function (n) {
                try { return n && n.height === 6 && n.radius === 3 && effVis(n) }
                catch (e) { return false }
            })
        }

        // ── pixel-hue scan over a grabImage ─────────────────────────────────
        function hasHue(img, hue) {
            var w0 = img.width, h0 = img.height
            for (var y = 8; y < h0 - 8; y += 10)
                for (var x = 8; x < w0 - 8; x += 10) {
                    var r = img.red(x, y), g = img.green(x, y), b = img.blue(x, y)
                    if (hue === "r" && r > 120 && r > g + 40 && r > b + 40) return true
                    if (hue === "g" && g > 120 && g > r + 40 && g > b + 40) return true
                }
            return false
        }

        // ── date helpers (local calendar strings) ───────────────────────────
        function ymd(dt) {
            var m = dt.getMonth() + 1, d = dt.getDate()
            return dt.getFullYear() + "-" + (m < 10 ? "0" + m : m) + "-" + (d < 10 ? "0" + d : d)
        }
        function futureDate(days) { var d = new Date(); d.setDate(d.getDate() + days); return ymd(d) }
        function today() { return ymd(new Date()) }
        // A Date for a fixed time-of-day today (deterministic eod window math).
        function todayAt(h, mi) {
            var n = new Date(); return new Date(n.getFullYear(), n.getMonth(), n.getDate(), h, mi, 0, 0)
        }

        function inPool(pool, txt) {
            for (var i = 0; i < pool.length; i++) if (pool[i].t === txt) return true
            return false
        }

        // ════════════════════════════════════════════════════════════════════
        //  COUNTDOWN  (30 cases)
        // ════════════════════════════════════════════════════════════════════
        function test_cd_1_size_data() { return countdownRows() }
        function test_cd_1_size(d) {
            prep("CountdownWidget.qml", { label: "Trip", date: futureDate(40), repeatYearly: false })
            setSize(d.w, d.h, d.cls)
            var img = snap(wh, "cd_size_" + d.tag)
            verify(G.looksRendered(img), "countdown rendered content @ " + d.tag)
            compare(wh.width, d.w, "cell width " + d.tag)
            compare(wh.height, d.h, "cell height " + d.tag)
            var num = txtExact("" + wh.item.days)
            verify(num !== null, "day-count readout visible @ " + d.tag)
            verify(num.truncated === false || num.contentWidth <= num.width + 1,
                   "day count not clipped @ " + d.tag)
        }

        function test_cd_2_config_data() {
            return [
                { tag: "label-set",   label: "Vacation", date: futureDate(30), rep: false,
                  want: "Vacation", nowant: "" },
                { tag: "label-clear", label: "",         date: futureDate(30), rep: false,
                  want: "the day",  nowant: "" },
                { tag: "date-valid",  label: "",         date: futureDate(12), rep: false,
                  want: "days until", nowant: "" },
                { tag: "date-invalid",label: "",         date: "2026-13-45",   rep: false,
                  want: "Set a date", nowant: "" },
                { tag: "repeat-on",   label: "",         date: "2000-06-15",   rep: true,
                  want: "until",    nowant: "passed" },
                { tag: "repeat-off",  label: "",         date: "2000-06-15",   rep: false,
                  want: "passed",   nowant: "" }
            ]
        }
        function test_cd_2_config(d) {
            prep("CountdownWidget.qml", { label: d.label, date: d.date, repeatYearly: d.rep })
            setSize(600, 600, "compact")
            compare(wh.storeCtl.settingsFor(wh.instanceId).date, d.date, "date persisted " + d.tag)
            compare(wh.storeCtl.settingsFor(wh.instanceId).repeatYearly, d.rep, "repeat persisted " + d.tag)
            snap(wh, "cd_cfg_" + d.tag)
            verify(txtHas(d.want) !== null, "caption shows '" + d.want + "' @ " + d.tag)
            if (d.nowant.length)
                verify(txtHas(d.nowant) === null, "caption must NOT show '" + d.nowant + "' @ " + d.tag)
        }

        function test_cd_3_state_data() {
            return [
                { tag: "ST1-unset",     date: "",             rep: false, cls: "compact", w: 600, h: 600 },
                { tag: "ST2-future",    date: "future30",     rep: false, cls: "compact", w: 600, h: 600 },
                { tag: "ST3-today",     date: "today",        rep: false, cls: "compact", w: 600, h: 600 },
                { tag: "ST4-passed",    date: "2000-01-01",   rep: false, cls: "compact", w: 600, h: 600 },
                { tag: "ST5-progress",  date: "future30",     rep: false, cls: "tall",    w: 600, h: 820 },
                { tag: "ST6-anniv",     date: "2000-06-15",   rep: true,  cls: "compact", w: 600, h: 600 },
                { tag: "ST7-micro",     date: "future30",     rep: false, cls: "compact", w: 340, h: 400 },
                { tag: "ST8-baseline",  date: "future55",     rep: false, cls: "tall",    w: 600, h: 820 }
            ]
        }
        function test_cd_3_state(d) {
            var date = d.date === "future30" ? futureDate(30)
                     : d.date === "future55" ? futureDate(55)
                     : d.date === "today" ? today() : d.date
            prep("CountdownWidget.qml", { label: "", date: date, repeatYearly: d.rep })
            setSize(d.w, d.h, d.cls)
            wait(150)   // allow deferred dateSetEpoch stamp
            var img = snap(wh, "cd_" + d.tag)
            if (d.tag === "ST1-unset") {
                verify(txtExact("-") !== null, "unset shows '-'")
                verify(txtHas("Set a date") !== null, "unset prompt visible")
            } else if (d.tag === "ST2-future") {
                verify(txtExact("" + wh.item.days) !== null, "day number visible")
                verify(txtHas("days until") !== null, "future caption")
            } else if (d.tag === "ST3-today") {
                verify(txtExact("NOW") !== null, "today has a deterministic hero state")
                verify(txtHas("Today") !== null, "today caption")
            } else if (d.tag === "ST4-passed") {
                verify(txtHas("passed") !== null, "passed caption")
                verify(txtExact("" + Math.abs(wh.item.days)) !== null, "abs day count visible")
            } else if (d.tag === "ST5-progress") {
                verify(trackNode() !== null, "progress track visible on tall")
            } else if (d.tag === "ST6-anniv") {
                verify(txtHas("until") !== null, "anniversary counts down (until)")
                verify(txtHas("passed") === null, "anniversary never shows passed")
                verify(wh.item.days >= 0, "anniversary day count non-negative")
            } else if (d.tag === "ST7-micro") {
                verify(wh.item.micro === true, "micro derivation active")
                verify(txtExact("" + wh.item.days) !== null, "micro still shows number")
                verify(txtExact("Countdown") === null, "micro has no header")
            } else if (d.tag === "ST8-baseline") {
                verify(wh.storeCtl.settingsFor(wh.instanceId).dateSetEpoch > 0,
                       "one-time progress baseline stamped")
                verify(wh.item.progress >= 0 && wh.item.progress <= 1, "progress in [0,1]")
                verify(trackNode() !== null, "progress track rendered")
            }
        }

        // The expanded preview does not duplicate the structured configuration
        // panel. It reflects the same store changes immediately.
        function test_cd_4_body_save() {
            prep("CountdownWidget.qml", { label: "", date: "", repeatYearly: false })
            wh.expanded = true
            setSize(700, 620, "full")
            wait(150)
            var lab = fieldByPlaceholder("Label")
            var dat = fieldByPlaceholder("YYYY-MM-DD")
            compare(lab, null, "preview does not duplicate the label editor")
            compare(dat, null, "preview does not duplicate the date editor")
            var future = futureDate(21)
            wh.storeCtl.patchSettings(wh.instanceId, {
                label: "Launch", date: future, targetHour: 14, targetMinute: 30
            })
            wait(250)
            snap(wh, "cd_body_save")
            compare(wh.storeCtl.settingsFor(wh.instanceId).label, "Launch", "label saved")
            compare(wh.storeCtl.settingsFor(wh.instanceId).date, future, "date saved")
            compare(wh.item.timeStr, "14:30", "structured time reflected")
            verify(txtHas("Launch") !== null, "tile caption reflects saved label")
            verify(txtHas("Target:") !== null, "preview explains the exact occurrence")
        }

        function test_cd_5_chrome_accent_data() { return accentRows() }
        function test_cd_5_chrome_accent(d) {
            prep("CountdownWidget.qml", { label: "", date: futureDate(30), repeatYearly: false })
            setSize(600, 600, "compact")
            wh.item.accentName = d.name
            wait(150)
            var img = snap(wh, "cd_accent_" + d.tag)
            verify(hasHue(img, d.hue), "countdown number shows " + d.hue + " accent @ " + d.tag)
        }

        function test_cd_6_chrome_backdrop_data() { return backdropRows() }
        function test_cd_6_chrome_backdrop(d) {
            prep("CountdownWidget.qml", { label: "", date: futureDate(30), repeatYearly: false })
            setSize(600, 600, "compact")
            wh.item.cardBackdrop = d.s
            wait(150)
            var bl = backdropNode()
            verify(bl !== null, "BackdropLayer present")
            snap(wh, "cd_backdrop_" + d.tag)
            compare(bl.visible, d.vis, "backdrop '" + d.tag + "' visibility")
        }

        // ════════════════════════════════════════════════════════════════════
        //  END OF DAY  (37 cases)
        // ════════════════════════════════════════════════════════════════════
        function test_eod_1_size_data() { return withRoomy(eodRows()) }
        function test_eod_1_size(d) {
            prep("EndOfDayWidget.qml", { startHour: 9, endHour: 17, progressStyle: "bar", showPercent: true })
            wh.item.nowOverride = todayAt(13, 0)
            setSize(d.w, d.h, d.cls)
            bumpTick()
            var img = snap(wh, "eod_size_" + d.tag)
            verify(G.looksRendered(img), "eod rendered content @ " + d.tag)
            compare(wh.width, d.w, "cell width " + d.tag)
            compare(wh.height, d.h, "cell height " + d.tag)
            var rem = txtExact(wh.item.remaining)
            verify(rem !== null, "remaining readout visible @ " + d.tag)
            compare(wh.item.roomy, d.roomy, "detail density @ " + d.tag)
        }

        function test_eod_2_config_data() {
            return [
                { tag: "startHour-8",  key: "startHour", val: 8,  cls: "tall", w: 600, h: 820, want: "08:00" },
                { tag: "startHour-10", key: "startHour", val: 10, cls: "tall", w: 600, h: 820, want: "10:00" },
                { tag: "endHour-16",   key: "endHour",   val: 16, cls: "tall", w: 600, h: 820, want: "16:00" },
                { tag: "endHour-18",   key: "endHour",   val: 18, cls: "tall", w: 600, h: 820, want: "18:00" },
                { tag: "style-bar",    key: "progressStyle", val: "bar",  cls: "tall", w: 600, h: 820, ring: false },
                { tag: "style-ring",   key: "progressStyle", val: "ring", cls: "tall", w: 600, h: 820, ring: true },
                { tag: "percent-on",   key: "showPercent", val: true,  cls: "compact", w: 600, h: 600, pct: true },
                { tag: "percent-off",  key: "showPercent", val: false, cls: "compact", w: 600, h: 600, pct: false }
            ]
        }
        function test_eod_2_config(d) {
            prep("EndOfDayWidget.qml", { startHour: 9, endHour: 17, progressStyle: "bar", showPercent: true })
            wh.item.nowOverride = todayAt(13, 0)
            wh.storeCtl.setSetting(wh.instanceId, d.key, d.val)
            setSize(d.w, d.h, d.cls)
            bumpTick(); wait(150)
            compare(wh.storeCtl.settingsFor(wh.instanceId)[d.key], d.val, "setting persisted " + d.tag)
            snap(wh, "eod_cfg_" + d.tag)
            if (d.hasOwnProperty("want"))
                verify(txtHas(d.want) !== null, "detail shows '" + d.want + "' @ " + d.tag)
            else if (d.hasOwnProperty("ring"))
                compare(ringVisible(), d.ring, "ring visibility @ " + d.tag)
            else if (d.hasOwnProperty("pct"))
                compare(txtHas("% elapsed") !== null, d.pct, "percent caption visibility @ " + d.tag)
        }

        function test_eod_3_state_data() {
            return [
                { tag: "ST1-bar",     style: "bar",  sh: 9,  eh: 17, at: [13, 0], cls: "compact", w: 600, h: 600 },
                { tag: "ST2-ring",    style: "ring", sh: 9,  eh: 17, at: [13, 0], cls: "tall",    w: 600, h: 820 },
                { tag: "ST3-remain",  style: "bar",  sh: 9,  eh: 17, at: [13, 40],cls: "compact", w: 600, h: 600 },
                { tag: "ST4-percent", style: "bar",  sh: 9,  eh: 17, at: [13, 0], cls: "compact", w: 600, h: 600 },
                { tag: "ST5-before",  style: "bar",  sh: 9,  eh: 17, at: [7, 0],  cls: "compact", w: 600, h: 600 },
                { tag: "ST6-done",    style: "bar",  sh: 9,  eh: 17, at: [18, 0], cls: "compact", w: 600, h: 600 },
                { tag: "ST7-invalid", style: "bar",  sh: 9,  eh: 8,  at: [13, 0], cls: "compact", w: 600, h: 600 },
                { tag: "ST8-detail",  style: "bar",  sh: 9,  eh: 17, at: [13, 0], cls: "tall",    w: 600, h: 820 },
                { tag: "ST9-micro",   style: "bar",  sh: 9,  eh: 17, at: [13, 0], cls: "compact", w: 340, h: 400 },
                { tag: "ST10-night",  style: "bar",  sh: 22, eh: 6,  at: [3, 0],  cls: "compact", w: 600, h: 600 }
            ]
        }
        function test_eod_3_state(d) {
            prep("EndOfDayWidget.qml", {
                startHour: d.sh, endHour: d.eh, progressStyle: d.style,
                showPercent: true, allowOvernight: d.tag === "ST10-night"
            })
            wh.item.nowOverride = todayAt(d.at[0], d.at[1])
            setSize(d.w, d.h, d.cls)
            bumpTick(); wait(150)
            var img = snap(wh, "eod_" + d.tag)
            if (d.tag === "ST1-bar") {
                verify(!ringVisible(), "bar style shows no ring")
                verify(hasHue(img, "g"), "bar fill/text is accent green")
            } else if (d.tag === "ST2-ring") {
                verify(ringVisible(), "ring style shows RingProgress")
                verify(hasHue(img, "g"), "ring is accent green")
            } else if (d.tag === "ST3-remain") {
                verify(txtExact("3h 20m") !== null, "remaining time 3h 20m at 13:40 of 9-17")
            } else if (d.tag === "ST4-percent") {
                verify(txtHas("% elapsed") !== null && txtHas("remaining") !== null,
                       "elapsed and remaining caption")
            } else if (d.tag === "ST5-before") {
                verify(txtHas("Starts in") !== null, "before-start label")
            } else if (d.tag === "ST6-done") {
                verify(txtHas("Complete") !== null, "completion label after end")
            } else if (d.tag === "ST7-invalid") {
                verify(txtHas("Enable overnight mode") !== null, "invalid window prompt")
            } else if (d.tag === "ST8-detail") {
                verify(txtExact("Start") !== null && txtExact("Elapsed") !== null
                       && txtExact("Remaining") !== null, "tall detail rows")
                verify(txtExact("09:00") !== null, "detail shows start hour")
            } else if (d.tag === "ST9-micro") {
                verify(wh.item.micro === true, "micro derivation active")
                verify(txtExact("End of Day") === null, "micro is headerless")
                verify(txtExact(wh.item.remaining) !== null, "micro shows remaining")
            } else if (d.tag === "ST10-night") {
                verify(txtExact("3h 0m") !== null, "overnight 22-06 at 03:00 has 3h left")
            }
        }

        function test_eod_4_body_data() {
            return [
                { tag: "start-plus",  label: "Start +", key: "startHour", exp: 10, want: "10:00" },
                { tag: "start-minus", label: "Start −", key: "startHour", exp: 8,  want: "08:00" },
                { tag: "end-plus",    label: "End +",   key: "endHour",   exp: 18, want: "18:00" },
                { tag: "end-minus",   label: "End −",   key: "endHour",   exp: 16, want: "16:00" }
            ]
        }
        function test_eod_4_body(d) {
            prep("EndOfDayWidget.qml", { startHour: 9, endHour: 17, progressStyle: "bar", showPercent: true })
            wh.item.nowOverride = todayAt(13, 0)
            wh.expanded = true
            setSize(600, 600, "compact")
            bumpTick(); wait(150)
            var btn = pill(d.label)
            verify(btn !== null, "pill '" + d.label + "' present")
            mouseClick(btn, btn.width / 2, btn.height / 2)
            wait(200)
            snap(wh, "eod_body_" + d.tag)
            compare(wh.storeCtl.settingsFor(wh.instanceId)[d.key], d.exp, d.label + " updated " + d.key)
            verify(txtHas(d.want) !== null, "caption reflects '" + d.want + "' after " + d.label)
        }

        function test_eod_5_chrome_accent_data() { return accentRows() }
        function test_eod_5_chrome_accent(d) {
            prep("EndOfDayWidget.qml", { startHour: 9, endHour: 17, progressStyle: "bar", showPercent: true })
            wh.item.nowOverride = todayAt(13, 0)
            setSize(600, 600, "compact")
            wh.item.accentName = d.name
            bumpTick(); wait(150)
            var img = snap(wh, "eod_accent_" + d.tag)
            verify(hasHue(img, d.hue), "eod fill shows " + d.hue + " accent @ " + d.tag)
        }

        function test_eod_6_chrome_backdrop_data() { return backdropRows() }
        function test_eod_6_chrome_backdrop(d) {
            prep("EndOfDayWidget.qml", { startHour: 9, endHour: 17, progressStyle: "bar", showPercent: true })
            wh.item.nowOverride = todayAt(13, 0)
            setSize(600, 600, "compact")
            wh.item.cardBackdrop = d.s
            bumpTick(); wait(150)
            var bl = backdropNode()
            verify(bl !== null, "BackdropLayer present")
            snap(wh, "eod_backdrop_" + d.tag)
            compare(bl.visible, d.vis, "backdrop '" + d.tag + "' visibility")
        }

        // ════════════════════════════════════════════════════════════════════
        //  DAILY QUOTE  (34 cases)
        // ════════════════════════════════════════════════════════════════════
        function test_qt_1_size_data() { return quoteRows() }
        function test_qt_1_size(d) {
            prep("QuoteWidget.qml", { category: "focus", customText: "" })
            setSize(d.w, d.h, d.cls)
            var img = snap(wh, "qt_size_" + d.tag)
            verify(G.looksRendered(img), "quote rendered content @ " + d.tag)
            compare(wh.width, d.w, "cell width " + d.tag)
            compare(wh.height, d.h, "cell height " + d.tag)
            verify(txtExact(wh.item.q.t) !== null, "quote text visible @ " + d.tag)
            if (d.micro)
                verify(txtExact("“") === null, "micro drops the decorative glyph")
            else
                verify(txtExact("“") !== null, "decorative glyph shown @ " + d.tag)
        }

        function test_qt_2_config_category_data() {
            return [
                { tag: "focus",    cat: "focus",    pool: "focus" },
                { tag: "stoic",    cat: "stoic",    pool: "stoic" },
                { tag: "humor",    cat: "humor",    pool: "humor" },
                { tag: "kindness", cat: "kindness", pool: "kindness" },
                { tag: "custom-empty", cat: "custom", pool: "" }
            ]
        }
        function test_qt_2_config_category(d) {
            prep("QuoteWidget.qml", { category: d.cat, customText: "" })
            setSize(600, 600, "compact")
            wait(150)
            compare(wh.storeCtl.settingsFor(wh.instanceId).category, d.cat, "category persisted " + d.tag)
            snap(wh, "qt_cat_" + d.tag)
            if (d.pool === "") {
                compare(wh.item.pool.length, 0, "empty custom mode has no bundled fallback")
                verify(txtExact("Add at least one custom quote in settings") !== null,
                       "empty custom guidance is visible")
            } else {
                var pool = wh.item.library[d.pool]
                verify(inPool(pool, wh.item.q.t), "quote belongs to '" + d.pool + "' pool @ " + d.tag)
                verify(txtExact(wh.item.q.t) !== null, "quote text visible @ " + d.tag)
            }
        }

        function test_qt_3_config_custom_data() {
            return [
                { tag: "custom-parse", text: "Ship it | Team", author: "Team", body: "Ship it" },
                { tag: "custom-clear", text: "",              author: null,   body: null }
            ]
        }
        function test_qt_3_config_custom(d) {
            prep("QuoteWidget.qml", { category: "custom", customText: d.text })
            setSize(600, 600, "compact")
            wait(150)
            snap(wh, "qt_" + d.tag)
            if (d.body !== null) {
                verify(txtExact(d.body) !== null, "custom quote body '" + d.body + "'")
                verify(txtExact("- " + d.author) !== null, "custom author '" + d.author + "'")
            } else {
                compare(wh.item.pool.length, 0, "empty custom mode remains empty")
                verify(txtExact("Add at least one custom quote in settings") !== null,
                       "empty custom guidance is rendered")
            }
        }

        // QT-ST4 + task requirement: every custom-text separator variant, parsed
        // author/body asserted on screen for every supported separator.
        function test_qt_4_separators_data() {
            var typographic = " " + String.fromCharCode(0x2014) + " "
            return [
                { tag: "typographic",  text: "Make it" + typographic + "Me", author: "Me" },
                { tag: "double-hyphen",text: "Make it -- You", author: "You" },
                { tag: "pipe",         text: "Make it | Her",  author: "Her" },
                { tag: "ascii-hyphen", text: "Make it - Him",  author: "Him" }
            ]
        }
        function test_qt_4_separators(d) {
            prep("QuoteWidget.qml", { category: "custom", customText: d.text })
            setSize(600, 600, "compact")
            wait(150)
            snap(wh, "qt_sep_" + d.tag)
            compare(wh.item.q.t, "Make it", "parsed body @ " + d.tag)
            compare(wh.item.q.a, d.author, "parsed author @ " + d.tag)
            verify(txtExact("Make it") !== null, "body text on screen @ " + d.tag)
            verify(txtExact("- " + d.author) !== null, "author text on screen @ " + d.tag)
        }

        function test_qt_5_state_data() {
            return [
                { tag: "ST1-text",   step: "text" },
                { tag: "ST2-author", step: "author" },
                { tag: "ST3-glyph",  step: "glyph" },
                { tag: "ST5-micro",  step: "micro" },
                { tag: "ST6-swap",   step: "swap" },
                { tag: "ST7-pin",    step: "pin" }
            ]
        }
        function test_qt_5_state(d) {
            if (d.step === "micro") {
                prep("QuoteWidget.qml", { category: "focus", customText: "" })
                setSize(340, 400, "compact")
                wait(150)
                snap(wh, "qt_" + d.tag)
                verify(wh.item.micro === true, "micro derivation active")
                verify(txtExact("“") === null, "micro has no glyph")
                verify(txtExact(wh.item.q.t) !== null, "micro still shows the quote")
                return
            }
            prep("QuoteWidget.qml", { category: "focus", customText: "" })
            setSize(600, 600, "compact")
            wait(150)
            snap(wh, "qt_" + d.tag)
            if (d.step === "text") {
                verify(txtExact(wh.item.q.t) !== null, "quote text renders")
            } else if (d.step === "author") {
                verify(wh.item.q.a.length > 0, "focus quote has an author")
                verify(txtExact("- " + wh.item.q.a) !== null, "author line renders")
            } else if (d.step === "glyph") {
                var g = txtExact("“")
                verify(g !== null, "decorative glyph renders")
            } else if (d.step === "swap") {
                var before = wh.item.q.t
                wh.storeCtl.setSetting(wh.instanceId, "category", "stoic")
                wait(150)
                verify(inPool(wh.item.library["stoic"], wh.item.q.t), "swapped to stoic pool")
                verify(txtExact(wh.item.q.t) !== null, "swapped quote visible")
            } else if (d.step === "pin") {
                wh.item.shuffle()
                wait(150)
                var pinned = wh.item.q.t
                verify(pinned.length > 0, "a quote is pinned")
                bumpTick(); wait(150)   // same-day tick must NOT release the pin
                compare(wh.item.q.t, pinned, "manual shuffle survives an intra-day tick")
                verify(txtExact(pinned) !== null, "pinned quote still on screen")
            }
        }

        function test_qt_6_body_data() {
            return [
                { tag: "tile-shuffle", expanded: false },
                { tag: "overlay-shuffle", expanded: true }
            ]
        }
        function test_qt_6_body(d) {
            prep("QuoteWidget.qml", { category: "focus", customText: "" })
            wh.expanded = d.expanded
            setSize(d.expanded ? 700 : 600, d.expanded ? 620 : 600, d.expanded ? "full" : "compact")
            wait(150)
            var before = wh.item.q.t
            if (d.expanded) {
                var p = pill("Another quote")
                verify(p !== null, "expanded quote action present")
                mouseClick(p, p.width / 2, p.height / 2)
            } else {
                var action = G.findPred(wh.item, function (n) {
                    try { return n && n.objectName === "quoteTileShuffle" && effVis(n) }
                    catch (e) { return false }
                })
                verify(action !== null, "tile quote action present")
                mouseClick(action, action.width / 2, action.height / 2)
            }
            wait(250)
            snap(wh, "qt_body_" + d.tag)
            verify(wh.item.q.t !== before, "shuffle changed the quote (" + d.tag + ")")
            verify(txtExact(wh.item.q.t) !== null, "new quote is on screen")
        }

        function test_qt_7_chrome_accent_data() { return accentRows() }
        function test_qt_7_chrome_accent(d) {
            prep("QuoteWidget.qml", { category: "focus", customText: "" })
            setSize(600, 600, "compact")
            wh.item.accentName = d.name
            wait(150)
            var img = snap(wh, "qt_accent_" + d.tag)
            verify(hasHue(img, d.hue), "quote glyph shows " + d.hue + " accent @ " + d.tag)
        }

        function test_qt_8_chrome_backdrop_data() { return backdropRows() }
        function test_qt_8_chrome_backdrop(d) {
            prep("QuoteWidget.qml", { category: "focus", customText: "" })
            setSize(600, 600, "compact")
            wh.item.cardBackdrop = d.s
            wait(150)
            var bl = backdropNode()
            verify(bl !== null, "BackdropLayer present")
            snap(wh, "qt_backdrop_" + d.tag)
            compare(bl.visible, d.vis, "backdrop '" + d.tag + "' visibility")
        }
    }
}
