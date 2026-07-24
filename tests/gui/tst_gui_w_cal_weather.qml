import QtQuick
import QtTest
import "../ui" as UI
import "GuiUtil.js" as G
import "../ui/fixtures.js" as Fx
import "../../ui/qml/widgets" as W

// ─────────────────────────────────────────────────────────────────────────
// tst_gui_w_cal_weather - REAL, visible GUI tests (real KWin compositor, real
// mouse events) for three Hub widgets: Calendar, Now/Next and Weather. Each is
// hosted in a real rendered window via UI.WidgetHarness (the ONLY way widget
// tiles render under qmltestrunner - the real Dashboard loads them by qrc: which
// does not resolve here). Every network path is driven OFFLINE through the
// `xhrFactory` seam + a FakeXHR (fixtures.js): weather ships live (Open-Meteo)
// but is NEVER allowed a real socket in tests.
//
// Coverage per widget: every declared size, every config field (via the store,
// asserting the widget's live visible output - the same contract a real
// ConfigField would drive), the unconfigured / "connect a source" state, the
// configured state (events / forecast fed through the stub), the error states
// (offline / blocked / timeout / non-JSON / empty), plus the shared chrome
// (accent override/Auto + cardBackdrop ×8). Assertions are GUI-observable:
// item.visible, geometry, on-screen text, live properties reflected in output,
// and grabImage() pixels. snap() writes evidence for every case.
// ─────────────────────────────────────────────────────────────────────────
Item {
    id: root
    // Contains the largest declared projection in this suite without clipping.
    width: 2700; height: 1700

    // The app-global egress gate, injected only for the offline / blocked cases
    // (a widget's local fallback hub cannot be driven offline). Everything else
    // routes through the widget's own fallback hub, which still honours the
    // per-request xhrFactory seam.
    W.NetHub { id: gate }

    UI.WidgetHarness { id: calH; x: 0;    y: 0; width: 696; height: 819; widgetFile: "CalendarWidget.qml" }
    UI.WidgetHarness { id: wxH;  x: 880;  y: 0; width: 696; height: 819; widgetFile: "WeatherWidget.qml"  }
    UI.WidgetHarness { id: nnH;  x: 1760; y: 0; width: 696; height: 819; widgetFile: "NowNextWidget.qml"  }

    TestCase {
        id: tc
        name: "GuiWCalWeather"
        when: windowShown
        visible: true

        property var lastFake: null

        function snap(item, name) {
            var img = grabImage(item)
            img.save("gui-evidence/wcalwx_" + name + ".png")
            return img
        }

        // ── shared helpers ────────────────────────────────────────────────
        function clearSettings(h) {
            var s = h.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            h.storeCtl._touchSettings()
        }
        function installFactory(h) {
            h.item.xhrFactory = function () { tc.lastFake = Fx.makeFakeXHR(); return tc.lastFake }
        }
        function resetGate() {
            gate.offline = false; gate.allowHosts = []
            gate.requests = 0; gate.blocked = 0
            gate._sharedProviders = ({})
            gate.sharedRevision = 0
        }
        function size(h, w, hh, cls) { h.width = w; h.height = hh; h.item.sizeClass = cls }

        // ── ICS builders (a "now" event must span the wall clock, so build
        //    relative to Date.now() - a fixed date would be pruned). ─────────
        function pad2(n) { return (n < 10 ? "0" : "") + n }
        function stampLocal(d) {
            return "" + d.getFullYear() + pad2(d.getMonth() + 1) + pad2(d.getDate())
                 + "T" + pad2(d.getHours()) + pad2(d.getMinutes()) + pad2(d.getSeconds())
        }
        function vevent(sum, s, e) {
            var out = "BEGIN:VEVENT\nSUMMARY:" + sum + "\nDTSTART;VALUE=DATE-TIME:" + stampLocal(s)
            if (e) out += "\nDTEND;VALUE=DATE-TIME:" + stampLocal(e)
            return out + "\nEND:VEVENT\n"
        }
        function ics(evts) { return "BEGIN:VCALENDAR\n" + evts.join("") + "END:VCALENDAR\n" }
        function nowIcs() {   // one happening NOW (±30 min) + one later
            var n = Date.now()
            return ics([ vevent("Standup", new Date(n - 1800000), new Date(n + 1800000)),
                         vevent("Review",  new Date(n + 7200000), new Date(n + 9000000)) ])
        }
        function nextOnlyIcs() {
            var n = Date.now()
            return ics([ vevent("Review", new Date(n + 3600000), new Date(n + 7200000)) ])
        }
        function bigIcs(cnt) {
            var n = Date.now(), evs = []
            for (var i = 0; i < cnt; i++)
                evs.push(vevent("Event " + i, new Date(n + (i + 1) * 3 * 3600000),
                                              new Date(n + (i + 1) * 3 * 3600000 + 3600000)))
            return ics(evs)
        }

        function findByPlaceholder(item, sub) {
            // Must be the VISIBLE field: Now/Next embeds a headless CalendarWidget
            // whose own (invisible, zero-width) URL field also carries this
            // placeholder and precedes ours in tree order.
            return G.findPred(item, function (n) {
                try { return n && n.placeholderText !== undefined && G.isLive(n)
                       && ("" + n.placeholderText).toLowerCase().indexOf(sub.toLowerCase()) >= 0 }
                catch (e) { return false } })
        }
        // A visible Text whose content is EXACTLY `str` (the widget title
        // "Now / Next" contains both "now" and "next" as substrings, so a loose
        // match cannot tell the NOW block label from the NEXT one).
        function findExactText(item, str) {
            return G.findPred(item, function (n) {
                try { return n && n.text !== undefined && n.visible && ("" + n.text).trim() === str }
                catch (e) { return false } })
        }
        function findPill(item, sub) {
            return G.findPred(item, function (n) {
                try { return n && n.label !== undefined && n.clicked !== undefined
                       && ("" + n.label).toLowerCase().indexOf(sub.toLowerCase()) >= 0 && G.isLive(n) }
                catch (e) { return false } })
        }
        function findBackdrop(item) {
            return G.findPred(item, function (n) {
                try { return n && n.style !== undefined && n.accent !== undefined && n.running !== undefined }
                catch (e) { return false } })
        }
        function firstMouseArea(item) {
            var all = G.collectPred(item, function (n) { return G.isMouseArea(n) && G.isLive(n) })
            return all.length ? all[0] : null
        }

        // Runs before EVERY test row: prove the three widgets rendered, then reset
        // each to a known blank, offline-stubbed state.
        function init() {
            tryVerify(function () { return calH.ready && wxH.ready && nnH.ready }, 6000, "all three widgets loaded")
            resetGate(); tc.lastFake = null
            var hs = [calH, wxH, nnH]
            for (var i = 0; i < hs.length; i++) {
                var h = hs[i]
                h.active = false; h.expanded = false
                clearSettings(h)
                h.item.accentName = ""; h.item.cardBackdrop = "none"; h.item.titleOverride = ""
                h.item.netHub = null
                if (h.item._hub && h.item._hub()._sharedProviders !== undefined) {
                    h.item._hub()._sharedProviders = ({})
                    h.item._hub().sharedRevision = 0
                }
                installFactory(h)
            }
            calH.item.events = []; calH.item.errorText = ""; calH.item.loading = false
            calH.item.sizeClass = "compact"
            wxH.item.loaded = false; wxH.item.errorText = ""
            wxH.storeCtl.patchSettings("test-instance", { lat: 48.2, lon: 16.37, place: "Vienna" })
            wxH.item.sizeClass = "compact"
            nnH.item.sizeClass = "compact"
            nnH.item.refresh()   // empty url → resets the embedded agenda model
            wait(50)
        }

        // ═══════════════════════════════════════════════════════════════════
        //  CALENDAR
        // ═══════════════════════════════════════════════════════════════════

        // Every declared allocation is rendered in both physical orientations.
        function test_cal_size_data() {
            return [
                { tag: "p_0.5x1", w: 348,  h: 818,  cls: "tall"    },
                { tag: "l_0.5x1", w: 846,  h: 306,  cls: "wide"    },
                { tag: "p_1x0.5", w: 696,  h: 409,  cls: "wide"    },
                { tag: "l_1x0.5", w: 423,  h: 612,  cls: "tall"    },
                { tag: "p_1x1",   w: 696,  h: 818,  cls: "compact" },
                { tag: "l_1x1",   w: 846,  h: 612,  cls: "compact" },
                { tag: "p_1x1.5", w: 696,  h: 1226, cls: "tall"    },
                { tag: "l_1x1.5", w: 1268, h: 612,  cls: "wide"    },
                { tag: "p_1x2",   w: 696,  h: 1635, cls: "large"   },
                { tag: "l_1x2",   w: 1691, h: 612,  cls: "large"   }
            ]
        }
        function test_cal_size(d) {
            size(calH, d.w, d.h, d.cls)
            calH.storeCtl.setSetting("test-instance", "url", "https://ex.com/c.ics")
            calH.storeCtl.setSetting("test-instance", "maxEvents", 12)
            wait(400)                         // flush the url-change debounce
            calH.item.refresh(); tc.lastFake.resolveWith(200, bigIcs(20))
            wait(150)
            compare(calH.item.width, d.w, "cell width honoured")
            compare(calH.item.height, d.h, "cell height honoured")
            compare(calH.item.events.length, 20, "full agenda parsed for " + d.tag)
            verify(calH.item.shownCount > 0 && calH.item.shownCount <= 12,
                   "visible agenda is bounded for " + d.tag)
            verify(calH.item.eventCols >= 1 && calH.item.eventCols <= 4,
                   "agenda columns fit the physical shape for " + d.tag)
            var img = snap(calH, "cal_size_" + d.tag)
            verify(G.looksRendered(img), "calendar rendered content at " + d.tag)
        }

        // Config: url set → agenda; url cleared → the unconfigured prompt.
        function test_cal_url_data() {
            return [ { tag: "set" }, { tag: "clear" } ]
        }
        function test_cal_url(d) {
            size(calH, 696, 819, "compact")
            if (d.tag === "set") {
                calH.storeCtl.setSetting("test-instance", "url", "https://ex.com/c.ics")
                wait(400); calH.item.refresh(); tc.lastFake.resolveWith(200, Fx.icsValid()); wait(120)
                compare(calH.storeCtl.settingsFor("test-instance").url, "https://ex.com/c.ics")
                verify(G.byText(calH.item, "Standup") !== null, "a set URL shows the agenda")
            } else {
                calH.storeCtl.setSetting("test-instance", "url", ""); wait(400); calH.item.refresh(); wait(120)
                verify(G.byText(calH.item, "Add a calendar") !== null, "a cleared URL shows the prompt")
            }
            snap(calH, "cal_url_" + d.tag)
        }

        // Config: maxEvents is a MAXIMUM - the visible row count is capped to it.
        function test_cal_maxevents_data() {
            return [ { tag: "1", cap: 1 }, { tag: "2", cap: 2 } ]
        }
        function test_cal_maxevents(d) {
            size(calH, 696, 1229, "tall")
            calH.storeCtl.setSetting("test-instance", "url", "https://ex.com/c.ics")
            calH.storeCtl.setSetting("test-instance", "maxEvents", d.cap)
            wait(400); calH.item.refresh(); tc.lastFake.resolveWith(200, Fx.icsValid()); wait(120)
            compare(calH.item.events.length, 3, "three parsed regardless of the cap")
            compare(calH.item.shownCount, d.cap, "shown rows capped to maxEvents=" + d.cap)
            snap(calH, "cal_maxevents_" + d.tag)
        }

        // Body: connection editing is consolidated into WidgetConfigPanel. The
        // expanded live preview owns only the agenda and a manual refresh action.
        function test_cal_body_save() {
            calH.expanded = true; size(calH, 700, 600, "full"); wait(150)
            var field = findByPlaceholder(calH.item, "ICS")
            compare(field, null, "the widget does not duplicate the shared config editor")
            calH.storeCtl.setSetting("test-instance", "url", "https://saved.example.com/c.ics")
            wait(400)
            var save = findPill(calH.item, "Refresh")
            verify(save !== null, "Refresh now button present")
            tc.lastFake = null
            mouseClick(save, save.width / 2, save.height / 2)
            wait(120)
            compare(calH.storeCtl.settingsFor("test-instance").url, "https://saved.example.com/c.ics",
                    "refresh does not rewrite the private setting")
            verify(tc.lastFake !== null, "a real click fired a fetch through the gate")
            snap(calH, "cal_body_save")
        }

        // States - configured, unconfigured and every error.
        function test_cal_states_data() {
            return [
                { tag: "unconfigured" }, { tag: "agenda" }, { tag: "offline" },
                { tag: "blocked" }, { tag: "timeout" }, { tag: "empty" },
                { tag: "loading" }, { tag: "multicol" }
            ]
        }
        function test_cal_states(d) {
            var w = calH.item
            if (d.tag === "unconfigured") {
                size(calH, 696, 819, "compact"); wait(120)
                verify(G.byText(w, "Add a calendar") !== null, "unconfigured prompt visible")
            } else if (d.tag === "agenda") {
                size(calH, 696, 819, "compact")
                calH.storeCtl.setSetting("test-instance", "url", "https://ex.com/c.ics")
                wait(400); w.refresh(); tc.lastFake.resolveWith(200, Fx.icsValid()); wait(120)
                compare(w.errorText, "", "a good feed clears the error")
                verify(G.byText(w, "Standup") !== null, "an event title is on screen")
            } else if (d.tag === "offline") {
                size(calH, 696, 819, "compact")
                calH.storeCtl.setSetting("test-instance", "url", "https://ex.com/c.ics"); wait(400)
                calH.item.netHub = gate; gate.offline = true
                tc.lastFake = null              // discard the debounce's (superseded) fake
                w.refresh(); wait(120)
                compare(tc.lastFake, null, "offline refuses before any socket")
                compare(w.errorText, "Calendar is offline")
                verify(G.byText(w, "offline") !== null, "the tile says it is offline")
            } else if (d.tag === "blocked") {
                size(calH, 696, 819, "compact")
                calH.storeCtl.setSetting("test-instance", "url", "https://ex.com/c.ics"); wait(400)
                calH.item.netHub = gate; gate.allowHosts = ["intranet.example.com"]
                w.refresh(); wait(120)
                compare(w.errorText, "Calendar host not allowed")
                verify(G.byText(w, "not allowed") !== null, "the tile distinguishes policy from failure")
            } else if (d.tag === "timeout") {
                size(calH, 696, 819, "compact")
                calH.storeCtl.setSetting("test-instance", "url", "https://ex.com/c.ics"); wait(400)
                w.refresh(); tc.lastFake.fireTimeout(); wait(120)
                compare(w.errorText, "Calendar timed out")
                verify(G.byText(w, "timed out") !== null, "the tile reports the timeout")
            } else if (d.tag === "empty") {
                size(calH, 696, 819, "compact")
                calH.storeCtl.setSetting("test-instance", "url", "https://ex.com/c.ics"); wait(400)
                w.refresh(); tc.lastFake.resolveWith(200, Fx.ICS_EMPTY); wait(120)
                compare(w.events.length, 0)
                verify(G.byText(w, "No upcoming") !== null, "empty feed → No upcoming events")
            } else if (d.tag === "loading") {
                size(calH, 696, 819, "compact")
                calH.storeCtl.setSetting("test-instance", "url", "https://ex.com/c.ics"); wait(400)
                w.refresh(); wait(80)   // in flight, unresolved
                compare(w.loading, true, "request in flight")
                verify(G.byText(w, "Loading") !== null, "the tile shows Loading…")
            } else if (d.tag === "multicol") {
                size(calH, 900, 180, "wide")
                calH.storeCtl.setSetting("test-instance", "url", "https://ex.com/c.ics")
                calH.storeCtl.setSetting("test-instance", "maxEvents", 12)
                wait(400); w.refresh(); tc.lastFake.resolveWith(200, bigIcs(10)); wait(120)
                verify(w.events.length >= 8, "many events parsed")
                verify(w.eventCols > 1, "a wide short box flows events into >1 column (cols=" + w.eventCols + ")")
            }
            snap(calH, "cal_state_" + d.tag)
        }

        // Chrome: accent override applies a preset; Auto falls back to the widget's
        // category colour. Both are reflected in the rendered card.
        function test_cal_chrome_accent_data() {
            return [ { tag: "override", name: "purple" }, { tag: "auto", name: "" } ]
        }
        function test_cal_chrome_accent(d) {
            size(calH, 696, 819, "compact")
            calH.storeCtl.setSetting("test-instance", "url", "https://ex.com/c.ics")
            wait(400); calH.item.refresh(); tc.lastFake.resolveWith(200, Fx.icsValid()); wait(120)
            calH.item.accentName = d.name; wait(120)
            if (d.name === "purple") {
                var want = "" + calH.theme.accentPresets["purple"].a
                verify(G.colorDist("" + calH.item.effAccent, want) < 8, "accent resolves to the purple preset")
            } else {
                verify(G.colorDist("" + calH.item.effAccent, "" + calH.item.accentColor) < 4,
                       "Auto falls back to the widget's category accent")
            }
            var img = snap(calH, "cal_accent_" + d.tag)
            verify(G.looksRendered(img), "card rendered with accent " + d.tag)
        }

        // Chrome: each cardBackdrop option - "none" hides the layer, every other
        // shows it (theme.decorative is on by default).
        function test_cal_backdrop_data() {
            return [ { tag: "none" }, { tag: "orbs" }, { tag: "mesh" }, { tag: "aurora" },
                     { tag: "waves" }, { tag: "stars" }, { tag: "bokeh" }, { tag: "grid" } ]
        }
        function test_cal_backdrop(d) {
            size(calH, 696, 819, "compact")
            calH.item.cardBackdrop = d.tag; wait(120)
            var bl = findBackdrop(calH.item)
            verify(bl !== null, "backdrop layer present")
            compare(bl.visible, d.tag !== "none", "backdrop '" + d.tag + "' visibility")
            snap(calH, "cal_backdrop_" + d.tag)
        }

        // ═══════════════════════════════════════════════════════════════════
        //  NOW / NEXT
        // ═══════════════════════════════════════════════════════════════════

        function nnFeed(icsBody) {
            nnH.storeCtl.setSetting("test-instance", "url", "https://ex.com/c.ics")
            wait(400); nnH.item.refresh(); tc.lastFake.resolveWith(200, icsBody); wait(150)
        }

        function test_nn_size_data() {
            return [
                { tag: "p_0.5x1", w: 348, h: 818, cls: "tall",    horiz: false },
                { tag: "l_0.5x1", w: 846, h: 306, cls: "wide",    horiz: true  },
                { tag: "p_1x0.5", w: 696, h: 409, cls: "wide",    horiz: true  },
                { tag: "l_1x0.5", w: 423, h: 612, cls: "tall",    horiz: false },
                { tag: "p_1x1",   w: 696, h: 818, cls: "compact", horiz: false },
                { tag: "l_1x1",   w: 846, h: 612, cls: "compact", horiz: false }
            ]
        }
        function test_nn_size(d) {
            size(nnH, d.w, d.h, d.cls)
            nnFeed(nowIcs())
            compare(nnH.item.width, d.w, "cell width honoured")
            compare(nnH.item.height, d.h, "cell height honoured")
            compare(nnH.item.horiz, d.horiz, "NOW/NEXT composition follows physical shape")
            verify(nnH.item.nowEvent !== null || nnH.item.nextEvent !== null, "a block is populated")
            verify(findExactText(nnH.item, "NOW") !== null, "NOW block visible")
            verify(findExactText(nnH.item, "NEXT") !== null, "NEXT block visible")
            var img = snap(nnH, "nn_size_" + d.tag)
            verify(G.looksRendered(img), "now/next rendered content at " + d.tag)
        }

        function test_nn_url_data() { return [ { tag: "set" }, { tag: "clear" } ] }
        function test_nn_url(d) {
            size(nnH, 696, 819, "compact")
            if (d.tag === "set") {
                nnFeed(nowIcs())
                compare(nnH.storeCtl.settingsFor("test-instance").url, "https://ex.com/c.ics")
                verify(G.byText(nnH.item, "Standup") !== null, "the nested agenda populated the blocks")
            } else {
                nnH.storeCtl.setSetting("test-instance", "url", ""); wait(400); nnH.item.refresh(); wait(120)
                verify(G.byText(nnH.item, "Add a calendar") !== null, "cleared URL → unconfigured prompt")
            }
            snap(nnH, "nn_url_" + d.tag)
        }

        // Body: source editing is consolidated into WidgetConfigPanel. The live
        // preview keeps the agenda presentation free of a second secret editor.
        function test_nn_body_save() {
            nnH.expanded = true; size(nnH, 700, 600, "full"); wait(150)
            var field = findByPlaceholder(nnH.item, "ICS")
            compare(field, null, "the widget does not duplicate the shared config editor")
            nnH.storeCtl.setSetting("test-instance", "url", "https://saved.example.com/n.ics")
            wait(400); nnH.item.refresh(); wait(120)
            verify(tc.lastFake !== null, "the nested agenda fetches the shared setting")
            snap(nnH, "nn_body_save")
        }

        function test_nn_states_data() {
            return [
                { tag: "unconfigured" }, { tag: "now" }, { tag: "next" }, { tag: "both" },
                { tag: "wide" }, { tag: "nothing" }, { tag: "status" }
            ]
        }
        function test_nn_states(d) {
            var w = nnH.item
            if (d.tag === "unconfigured") {
                size(nnH, 696, 819, "compact"); wait(120)
                verify(G.byText(w, "Add a calendar") !== null, "unconfigured prompt visible")
            } else if (d.tag === "now") {
                size(nnH, 696, 819, "compact"); nnFeed(nowIcs())
                verify(w.nowEvent !== null, "a current event fills the NOW block")
                verify(findExactText(w, "NOW") !== null, "the accent NOW label is on screen")
                verify(G.byText(w, "Standup") !== null, "the current event's title is shown")
            } else if (d.tag === "next") {
                size(nnH, 696, 819, "compact"); nnFeed(nextOnlyIcs())
                verify(w.nowEvent === null, "no current event")
                verify(w.nextEvent !== null, "a future event fills the NEXT block")
                verify(findExactText(w, "NEXT") !== null, "the NEXT label is on screen")
            } else if (d.tag === "both") {
                size(nnH, 696, 819, "compact"); nnFeed(nowIcs())
                verify(w.nowEvent !== null && w.nextEvent !== null, "both blocks populated")
                var nowT = findExactText(w, "NOW"), nextT = findExactText(w, "NEXT")
                verify(nowT && nextT, "both labels present")
                var ny = nowT.mapToItem(w, 0, 0).y, xy = nextT.mapToItem(w, 0, 0).y
                verify(ny < xy, "stacked: NOW sits above NEXT (" + ny + " < " + xy + ")")
            } else if (d.tag === "wide") {
                size(nnH, 900, 300, "wide"); nnFeed(nowIcs())
                verify(w.horiz === true, "wide box lays NOW and NEXT side by side")
                var a = findExactText(w, "NOW"), b = findExactText(w, "NEXT")
                verify(a && b, "both labels present")
                var ax = a.mapToItem(w, 0, 0).x, bx = b.mapToItem(w, 0, 0).x
                verify(ax < bx, "side-by-side: NOW is left of NEXT (" + ax + " < " + bx + ")")
            } else if (d.tag === "nothing") {
                size(nnH, 696, 819, "compact")
                nnH.storeCtl.setSetting("test-instance", "url", "https://ex.com/c.ics")
                wait(400); nnH.item.refresh(); tc.lastFake.resolveWith(200, Fx.ICS_EMPTY); wait(120)
                verify(w.nowEvent === null && w.nextEvent === null, "no now/next event")
                var empty = G.byText(w, "No upcoming") || G.byText(w, "Nothing")
                verify(empty !== null, "the empty state message is visible")
            } else if (d.tag === "status") {
                size(nnH, 696, 819, "compact"); nnFeed(nowIcs())
                compare(w.status, "now", "the header status badge reads 'now' when something is on")
            }
            snap(nnH, "nn_state_" + d.tag)
        }

        function test_nn_chrome_accent_data() {
            return [ { tag: "override", name: "purple" }, { tag: "auto", name: "" } ]
        }
        function test_nn_chrome_accent(d) {
            size(nnH, 696, 819, "compact"); nnFeed(nowIcs())
            nnH.item.accentName = d.name; wait(120)
            if (d.name === "purple") {
                var want = "" + nnH.theme.accentPresets["purple"].a
                verify(G.colorDist("" + nnH.item.effAccent, want) < 8, "accent resolves to purple")
            } else {
                verify(G.colorDist("" + nnH.item.effAccent, "" + nnH.item.accentColor) < 4, "Auto → category accent")
            }
            var img = snap(nnH, "nn_accent_" + d.tag)
            verify(G.looksRendered(img), "rendered with accent " + d.tag)
        }

        function test_nn_backdrop_data() {
            return [ { tag: "none" }, { tag: "orbs" }, { tag: "mesh" }, { tag: "aurora" },
                     { tag: "waves" }, { tag: "stars" }, { tag: "bokeh" }, { tag: "grid" } ]
        }
        function test_nn_backdrop(d) {
            size(nnH, 696, 819, "compact")
            nnH.item.cardBackdrop = d.tag; wait(120)
            var bl = findBackdrop(nnH.item)
            verify(bl !== null, "backdrop layer present")
            compare(bl.visible, d.tag !== "none", "backdrop '" + d.tag + "' visibility")
            snap(nnH, "nn_backdrop_" + d.tag)
        }

        // ═══════════════════════════════════════════════════════════════════
        //  WEATHER  (live Open-Meteo in production - fully stubbed here)
        // ═══════════════════════════════════════════════════════════════════

        function wxLoad(body) { wxH.item.refresh(); tc.lastFake.resolveWith(200, body); wait(150) }

        function test_wx_size_data() {
            return [
                { tag: "p_0.5x0.5", w: 348,  h: 409,  cls: "compact", micro: true,  roomy: false },
                { tag: "l_0.5x0.5", w: 423,  h: 306,  cls: "compact", micro: true,  roomy: false },
                { tag: "p_0.5x1",   w: 348,  h: 818,  cls: "tall",    micro: false, roomy: false },
                { tag: "l_0.5x1",   w: 846,  h: 306,  cls: "wide",    micro: false, roomy: false },
                { tag: "p_1x0.5",   w: 696,  h: 409,  cls: "wide",    micro: false, roomy: false },
                { tag: "l_1x0.5",   w: 423,  h: 612,  cls: "tall",    micro: false, roomy: false },
                { tag: "p_1x1",     w: 696,  h: 818,  cls: "compact", micro: false, roomy: false },
                { tag: "l_1x1",     w: 846,  h: 612,  cls: "compact", micro: false, roomy: false },
                { tag: "p_1x1.5",   w: 696,  h: 1226, cls: "tall",    micro: false, roomy: true  },
                { tag: "l_1x1.5",   w: 1268, h: 612,  cls: "wide",    micro: false, roomy: true  }
            ]
        }
        function test_wx_size(d) {
            size(wxH, d.w, d.h, d.cls)
            wxLoad(Fx.FORECAST_VALID)
            compare(wxH.item.width, d.w, "cell width honoured")
            compare(wxH.item.height, d.h, "cell height honoured")
            compare(wxH.item.micro, d.micro, "micro derivation for " + d.tag)
            compare(wxH.item.loaded, true, "forecast loaded")
            compare(wxH.item.roomy, d.roomy, "detail density for " + d.tag)
            var details = G.findPred(wxH.item, function (n) {
                return n && n.objectName === "weatherConditionSummary" && G.isLive(n)
            })
            compare(details !== null, d.roomy, "condition summary for " + d.tag)
            var img = snap(wxH, "wx_size_" + d.tag)
            verify(G.looksRendered(img), "weather rendered content at " + d.tag)
        }

        // Config: place label reflects the typed name, and clears to coordinates.
        function test_wx_place_data() {
            return [ { tag: "vienna", val: "Vienna, AT", find: "Vienna" },
                     { tag: "cleared", val: "", find: "48.20" } ]
        }
        function test_wx_place(d) {
            size(wxH, 696, 819, "compact")
            wxH.storeCtl.setSetting("test-instance", "place", d.val); wait(120)
            compare(wxH.item.place.indexOf(d.find) >= 0, true, "place resolves to " + d.find)
            verify(G.byText(wxH.item, d.find) !== null, "the place label shows " + d.find)
            snap(wxH, "wx_place_" + d.tag)
        }

        // Config action: geocode looks up a city and persists lat/lon/place.
        function test_wx_geocode() {
            size(wxH, 696, 819, "compact")
            wxH.item.geocode("Tokyo")
            compare(wxH.item.geocoding, true, "a valid name starts a lookup")
            verify(tc.lastFake !== null && tc.lastFake.url.indexOf("geocoding-api.open-meteo.com") >= 0,
                   "the geocode hits the geocoding API")
            tc.lastFake.resolveWith(200, Fx.GEOCODE_VALID); wait(120)
            var s = wxH.storeCtl.settingsFor("test-instance")
            fuzzyCompare(s.lat, 35.6895, 0.0001, "latitude persisted")
            fuzzyCompare(s.lon, 139.6917, 0.0001, "longitude persisted")
            compare(s.place, "Tokyo, Tokyo, JP", "labelled place persisted")
            verify(G.byText(wxH.item, "Tokyo") !== null, "the resolved city labels the tile")
            snap(wxH, "wx_geocode")
        }

        // Config: lat / lon flow into the forecast request AND the store.
        function test_wx_latlon_data() {
            return [ { tag: "lat+", key: "lat", val: 35.68,   q: "latitude=35.68"   },
                     { tag: "lat-", key: "lat", val: -33.87,  q: "latitude=-33.87"  },
                     { tag: "lon+", key: "lon", val: 139.69,  q: "longitude=139.69" },
                     { tag: "lon-", key: "lon", val: -70.66,  q: "longitude=-70.66" } ]
        }
        function test_wx_latlon(d) {
            size(wxH, 696, 819, "compact")
            wxH.storeCtl.setSetting("test-instance", d.key, d.val); wait(80)
            wxH.item.refresh()
            compare(wxH.storeCtl.settingsFor("test-instance")[d.key], d.val, d.key + " persisted")
            verify(tc.lastFake.url.indexOf(d.q) >= 0, d.key + " flows into the request (" + tc.lastFake.url + ")")
            snap(wxH, "wx_latlon_" + d.tag)
        }

        // Config: units flips the degree symbol shown on the reading.
        function test_wx_units_data() {
            return [ { tag: "celsius", val: "celsius", sym: "°C" },
                     { tag: "fahrenheit", val: "fahrenheit", sym: "°F" } ]
        }
        function test_wx_units(d) {
            size(wxH, 696, 819, "compact")
            wxH.storeCtl.setSetting("test-instance", "units", d.val); wait(80)
            wxLoad(Fx.FORECAST_VALID)
            compare(wxH.item.degSym, d.sym, "degree symbol for " + d.tag)
            verify(G.byText(wxH.item, d.sym) !== null, "the reading shows " + d.sym)
            snap(wxH, "wx_units_" + d.tag)
        }

        // Config: forecastDays sets how many days are FETCHED (value + 1).
        function test_wx_forecastdays_data() {
            return [ { tag: "3", val: 3, q: "forecast_days=4" },
                     { tag: "4", val: 4, q: "forecast_days=5" },
                     { tag: "7", val: 7, q: "forecast_days=8" } ]
        }
        function test_wx_forecastdays(d) {
            size(wxH, 696, 819, "compact")
            wxH.storeCtl.setSetting("test-instance", "forecastDays", d.val); wait(80)
            wxH.item.refresh()
            compare(wxH.storeCtl.settingsFor("test-instance").forecastDays, d.val, "forecastDays persisted")
            verify(tc.lastFake.url.indexOf(d.q) >= 0, "requests " + d.q + " (" + tc.lastFake.url + ")")
            snap(wxH, "wx_fdays_" + d.tag)
        }

        // Config: a custom title overrides the header text.
        function test_wx_title() {
            size(wxH, 696, 819, "compact")
            wxH.item.titleOverride = "My Sky"; wait(120)
            verify(G.byText(wxH.item, "My Sky") !== null, "the custom title shows in the header")
            snap(wxH, "wx_title")
        }

        // Body: real clicks - the refresh glyph and the expanded "Set location".
        function test_wx_body_data() { return [ { tag: "refresh" }, { tag: "setlocation" } ] }
        function test_wx_body(d) {
            if (d.tag === "refresh") {
                size(wxH, 696, 819, "compact"); wxLoad(Fx.FORECAST_VALID)
                tc.lastFake = null
                var ma = firstMouseArea(wxH.item)
                verify(ma !== null, "the refresh touch target is present")
                mouseClick(ma, ma.width / 2, ma.height / 2); wait(120)
                verify(tc.lastFake !== null, "a real click on ⟳ fired a fetch")
            } else {
                wxH.expanded = true; size(wxH, 700, 600, "full"); wait(150)
                var field = findByPlaceholder(wxH.item, "city")
                verify(field !== null, "expanded city field present")
                field.text = "Tokyo"
                var pill = findPill(wxH.item, "Set location")
                verify(pill !== null, "Set location button present")
                tc.lastFake = null
                mouseClick(pill, pill.width / 2, pill.height / 2); wait(120)
                verify(tc.lastFake !== null && tc.lastFake.url.indexOf("geocoding-api") >= 0,
                       "clicking Set location fired the geocode")
                tc.lastFake.resolveWith(200, Fx.GEOCODE_VALID); wait(120)
                compare(wxH.storeCtl.settingsFor("test-instance").place, "Tokyo, Tokyo, JP",
                        "the looked-up city was persisted")
            }
            snap(wxH, "wx_body_" + d.tag)
        }

        // States - loading, loaded, feels-like, forecast reflows, and every error.
        function test_wx_states_data() {
            return [
                { tag: "loading" }, { tag: "loaded" }, { tag: "feels" },
                { tag: "rows_tall" }, { tag: "cols_wide" }, { tag: "offline" },
                { tag: "blocked" }, { tag: "timeout_holds" }, { tag: "micro" }
            ]
        }
        function test_wx_states(d) {
            var w = wxH.item
            if (d.tag === "loading") {
                size(wxH, 696, 819, "compact")
                w.refresh(); wait(80)   // in flight, unresolved
                compare(w.loaded, false, "not loaded yet")
                verify(G.byText(w, "…") !== null, "the loading ellipsis shows")
            } else if (d.tag === "loaded") {
                size(wxH, 696, 819, "compact"); wxLoad(Fx.FORECAST_VALID)
                compare(w.loaded, true, "loaded")
                verify(G.byText(w, "21°") !== null, "the current temperature is on screen")
            } else if (d.tag === "feels") {
                size(wxH, 696, 819, "compact"); wxLoad(Fx.FORECAST_VALID)
                verify(w.rich === true, "baseline is rich (not micro)")
                verify(G.byText(w, "Feels") !== null, "the feels-like line is shown")
            } else if (d.tag === "rows_tall") {
                size(wxH, 696, 1229, "tall"); wxLoad(Fx.FORECAST_VALID)
                verify(w.horiz === false, "tall stacks the forecast as rows")
                verify(w.shownDays > 0, "day rows are shown (" + w.shownDays + ")")
            } else if (d.tag === "cols_wide") {
                size(wxH, 900, 360, "wide"); wxLoad(Fx.FORECAST_VALID)
                verify(w.horiz === true, "wide lays the forecast out as columns")
                verify(w.shownDays > 0, "day columns are shown (" + w.shownDays + ")")
            } else if (d.tag === "offline") {
                size(wxH, 696, 819, "compact")
                wxH.item.netHub = gate; gate.offline = true
                w.refresh(); wait(120)
                compare(tc.lastFake, null, "offline refuses before any socket")
                compare(w.errorText, "Offline")
                verify(G.byText(w, "Offline") !== null, "the tile says Offline")
            } else if (d.tag === "blocked") {
                size(wxH, 696, 819, "compact")
                wxH.item.netHub = gate; gate.allowHosts = ["intranet.example.com"]
                w.refresh(); wait(120)
                compare(w.errorText, "Blocked")
                verify(G.byText(w, "Blocked") !== null, "the tile distinguishes policy from failure")
            } else if (d.tag === "timeout_holds") {
                size(wxH, 696, 819, "compact")
                wxLoad(Fx.FORECAST_VALID)                 // a good reading first
                w.refresh(); tc.lastFake.fireTimeout(); wait(120)
                compare(w.loaded, true, "a timeout after a good reading HOLDS it (no stale wipe)")
                compare(w.errorText, "Timed out", "the held reading still discloses the timeout")
                verify(G.byText(w, "Timed out") !== null, "the provider failure is visible")
                verify(G.byText(w, "21°") !== null, "the last reading is still on screen")
            } else if (d.tag === "micro") {
                size(wxH, 348, 409, "compact"); wxLoad(Fx.FORECAST_VALID)
                compare(w.micro, true, "half-cell is micro")
                verify(G.byText(w, "Feels") === null, "micro drops the feels-like line")
                verify(G.byText(w, "21°") !== null, "micro still shows glyph + temperature")
            }
            snap(wxH, "wx_state_" + d.tag)
        }

        function test_wx_chrome_accent_data() {
            return [ { tag: "override", name: "purple" }, { tag: "auto", name: "" } ]
        }
        function test_wx_chrome_accent(d) {
            size(wxH, 696, 819, "compact"); wxLoad(Fx.FORECAST_VALID)
            wxH.item.accentName = d.name; wait(120)
            if (d.name === "purple") {
                var want = "" + wxH.theme.accentPresets["purple"].a
                verify(G.colorDist("" + wxH.item.effAccent, want) < 8, "accent resolves to purple")
            } else {
                verify(G.colorDist("" + wxH.item.effAccent, "" + wxH.item.accentColor) < 4, "Auto → catInfo")
            }
            var img = snap(wxH, "wx_accent_" + d.tag)
            verify(G.looksRendered(img), "rendered with accent " + d.tag)
        }

        function test_wx_backdrop_data() {
            return [ { tag: "none" }, { tag: "orbs" }, { tag: "mesh" }, { tag: "aurora" },
                     { tag: "waves" }, { tag: "stars" }, { tag: "bokeh" }, { tag: "grid" } ]
        }
        function test_wx_backdrop(d) {
            size(wxH, 696, 819, "compact")
            wxH.item.cardBackdrop = d.tag; wait(120)
            var bl = findBackdrop(wxH.item)
            verify(bl !== null, "backdrop layer present")
            compare(bl.visible, d.tag !== "none", "backdrop '" + d.tag + "' visibility")
            snap(wxH, "wx_backdrop_" + d.tag)
        }
    }
}
