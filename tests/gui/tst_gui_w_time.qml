import QtQuick
import QtTest
import "../ui" as UI
import "GuiUtil.js" as G

// Visible GUI tests for the three time-family Hub widgets - Clock, Analog Clock,
// Moon Phase - each hosted in a real KWin-composited window via WidgetHarness and
// driven with real store mutations + geometry/pixel assertions.
//
// Seams used (inspected in source, NOT wall-clock sleeps):
//   • sizeClass  - plain writable property on WidgetChrome; pinned per size case.
//   • timeZones  - ClockWidget.property var timeZones (the C++ TimeZoneBridge is
//                  absent under qmltestrunner); a deterministic fake is injected so
//                  world-clock zone chips resolve.
//   • _cyclePos  - MoonWidget.property real _cyclePos; assigned directly to pin the
//                  phase to a known new/full moon without depending on today's date.
//   • tick stays 0 in the harness (no timer), so both Canvas faces render statically
//     - deterministic pixels for the analog second-hand / numeral cases.
//
// The harness does NOT wire titleOverride/accentName/cardBackdrop/timeZones the way
// Dashboard.injectWidget does, so wire() reproduces exactly those bindings on the
// loaded item - config edits via store.setSetting then drive the widget end-to-end.
Item {
    id: root
    width: 1400; height: 1400

    UI.WidgetHarness {
        id: wh
        anchors.left: parent.left; anchors.top: parent.top
        width: 600; height: 600
        widgetFile: "ClockWidget.qml"
    }

    TestCase {
        name: "GuiWTime"
        when: windowShown
        visible: true

        property var tz: null

        function snap(item, name) {
            var img = G.grabItem(this, item, root)
            img.save("gui-evidence/wtime_" + name + ".png")
            return img
        }

        // ── infra ────────────────────────────────────────────────────────────
        function initTestCase() { tz = mkTz() }

        // Deterministic stand-in for the C++ TimeZoneBridge. zoneCity() (the chip
        // text) derives from the id string, not these offsets; offsets only shift
        // the formatted time, asserted loosely.
        function mkTz() {
            var z = { "America/New_York": -14400, "Europe/London": 3600, "Europe/Berlin": 7200,
                      "Asia/Tokyo": 32400, "UTC": 0, "Australia/Sydney": 36000 }
            return {
                _z: z,
                isValid: function (id) { return this._z[id] !== undefined },
                offsetSecsAt: function (id, ms) { return this._z[id] || 0 },
                format: function (id, ms, fmt) {
                    var off = (this._z[id] || 0) * 1000
                    var lo = -new Date(ms).getTimezoneOffset() * 60000
                    var sh = new Date(ms - lo + off)
                    var lo2 = -sh.getTimezoneOffset() * 60000
                    return Qt.formatDateTime(new Date(ms - lo2 + off), fmt)
                }
            }
        }

        function useWidget(file) {
            if (wh.widgetFile !== file) wh.widgetFile = file
            tryVerify(function () { return wh.ready }, 5000, "widget " + file + " loaded")
            wire()
        }

        // Reproduce Dashboard.injectWidget's per-instance appearance bindings.
        function wire() {
            var it = wh.item
            if (!it) return
            if (it.hasOwnProperty("titleOverride"))
                it.titleOverride = Qt.binding(function () {
                    wh.storeCtl.revision
                    var s = wh.storeCtl.settingsFor(wh.instanceId)
                    return (s && s.title) ? s.title : ""
                })
            if (it.hasOwnProperty("accentName"))
                it.accentName = Qt.binding(function () {
                    wh.storeCtl.revision
                    var s = wh.storeCtl.settingsFor(wh.instanceId)
                    return (s && s.accent) ? s.accent : ""
                })
            if (it.hasOwnProperty("cardBackdrop"))
                it.cardBackdrop = Qt.binding(function () {
                    wh.storeCtl.revision
                    var s = wh.storeCtl.settingsFor(wh.instanceId)
                    return (s && s.cardBackdrop) ? s.cardBackdrop : "none"
                })
            if (it.hasOwnProperty("timeZones"))
                it.timeZones = tz
        }

        function setC(k, v) { wh.storeCtl.setSetting(wh.instanceId, k, v) }
        function cfg() { return wh.storeCtl.settingsFor(wh.instanceId) }

        // ── generic scene / pixel helpers ──────────────────────────────────────
        function effVisible(n) { while (n) { if (!n.visible) return false; n = n.parent } return true }

        function timeText() {
            return G.findPred(wh.item, function (n) {
                try { return n && n.text !== undefined && n.visible && /\d{1,2}:\d{2}/.test("" + n.text) }
                catch (e) { return false }
            })
        }

        function findCanvas() {
            return G.findPred(wh.item, function (n) {
                try { return n && n.requestPaint !== undefined && n.width > 0 } catch (e) { return false }
            })
        }

        function findBackdrop() {
            return G.findPred(wh.item, function (n) {
                try { return n && n.style !== undefined && n.running !== undefined
                             && n.accent !== undefined && n.source !== undefined }
                catch (e) { return false }
            })
        }

        function moonGlyph() {
            return G.byObjName(wh.item, "moonDisc")
        }

        function scanRegion(img, x0, y0, x1, y1, hex, tol, step) {
            for (var y = Math.max(0, Math.floor(y0)); y < Math.min(img.height, y1); y += step)
                for (var x = Math.max(0, Math.floor(x0)); x < Math.min(img.width, x1); x += step)
                    if (G.colorDist("" + img.pixel(x, y), hex) <= tol) return true
            return false
        }

        function annulusHasColor(img, cx, cy, rad, rinF, routF, hex, tol, step) {
            var rin = rad * rinF, rout = rad * routF
            for (var y = Math.max(0, Math.floor(cy - rout)); y < Math.min(img.height, cy + rout); y += step)
                for (var x = Math.max(0, Math.floor(cx - rout)); x < Math.min(img.width, cx + rout); x += step) {
                    var dx = x - cx, dy = y - cy, r = Math.sqrt(dx * dx + dy * dy)
                    if (r < rin || r > rout) continue
                    if (G.colorDist("" + img.pixel(Math.floor(x), Math.floor(y)), hex) <= tol) return true
                }
            return false
        }

        function annulusDiffCount(a, b, cx, cy, rad, rinF, routF, tol, step) {
            var rin = rad * rinF, rout = rad * routF, changed = 0
            for (var y = Math.max(0, Math.floor(cy - rout)); y < Math.min(a.height, cy + rout); y += step)
                for (var x = Math.max(0, Math.floor(cx - rout)); x < Math.min(a.width, cx + rout); x += step) {
                    var dx = x - cx, dy = y - cy, r = Math.sqrt(dx * dx + dy * dy)
                    if (r < rin || r > rout) continue
                    if (G.colorDist("" + a.pixel(Math.floor(x), Math.floor(y)),
                                    "" + b.pixel(Math.floor(x), Math.floor(y))) > tol)
                        changed++
                }
            return changed
        }

        function gridSig(img) {
            var a = []
            for (var y = 5; y < img.height; y += 10)
                for (var x = 5; x < img.width; x += 10) a.push("" + img.pixel(x, y))
            return a
        }
        function sigDiff(a, b) {
            var n = Math.min(a.length, b.length), d = 0
            for (var i = 0; i < n; i++) if (a[i] !== b[i]) d++
            return d
        }

        // Theme role colours (literal hexes so colorDist parses #rrggbb cleanly).
        readonly property string cSystem: "#58A6FF"   // theme.catSystem
        readonly property string cInfo:   "#3FB950"   // theme.catInfo
        readonly property string cRed:    "#F85149"   // accentPresets.red.a

        // ── per-group prep (reset to defaults so cases stay independent) ────────
        function clockPrep(w, h, cls) {
            useWidget("ClockWidget.qml")
            wh.expanded = false
            setC("format24", false); setC("showSeconds", false); setC("showDate", true)
            setC("dateStyle", "full"); setC("customZone", false); setC("zoneId", "")
            setC("zoneLabel", ""); setC("utcOffset", 0)
            setC("datePattern", "ddd, d MMM"); setC("localeName", "")
            setC("secondaryZones", "")
            setC("title", ""); setC("accent", ""); setC("cardBackdrop", "none")
            wh.width = w; wh.height = h; wh.item.sizeClass = cls; wait(160)
        }
        function analogPrep(w, h, cls) {
            useWidget("AnalogClockWidget.qml")
            wh.expanded = false
            setC("showSeconds", true); setC("showNumerals", false)
            setC("faceStyle", "classic"); setC("handStyle", "round")
            setC("customZone", false); setC("zoneId", "")
            setC("zoneLabel", ""); setC("utcOffset", 0)
            setC("title", ""); setC("accent", ""); setC("cardBackdrop", "none")
            wh.width = w; wh.height = h; wh.item.sizeClass = cls; wait(160)
        }
        function moonPrep(w, h, cls, cyclePos) {
            useWidget("MoonWidget.qml")
            wh.expanded = false
            setC("hemisphere", "north"); setC("showAccuracyNote", true)
            setC("showLocalEvents", false); setC("locationMode", "search")
            setC("place", ""); setC("lat", null); setC("lon", null)
            setC("title", ""); setC("accent", ""); setC("cardBackdrop", "none")
            wh.width = w; wh.height = h; wh.item.sizeClass = cls
            wh.item._cyclePos = (cyclePos === undefined) ? 0.35 : cyclePos
            wait(160)
        }

        // ════════════════════════════════════════════════════════════════════
        // ANALOG CLOCK
        // ════════════════════════════════════════════════════════════════════
        function test_analog_size_data() {
            return [
                { tag: "portrait-0.5x0.5",  w: 348,  h: 409,  cls: "compact" },
                { tag: "landscape-0.5x0.5", w: 423,  h: 306,  cls: "compact" },
                { tag: "portrait-0.5x1",    w: 348,  h: 818,  cls: "tall" },
                { tag: "landscape-0.5x1",   w: 846,  h: 306,  cls: "wide" },
                { tag: "portrait-1x0.5",    w: 696,  h: 409,  cls: "wide" },
                { tag: "landscape-1x0.5",   w: 423,  h: 612,  cls: "tall" },
                { tag: "portrait-1x1",      w: 696,  h: 818,  cls: "compact" },
                { tag: "landscape-1x1",     w: 846,  h: 612,  cls: "compact" },
                { tag: "portrait-1x1.5",    w: 696,  h: 1226, cls: "tall" },
                { tag: "landscape-1x1.5",   w: 1268, h: 612,  cls: "wide" }
            ]
        }
        function test_analog_size(row) {
            analogPrep(row.w, row.h, row.cls)
            var img = snap(wh, "anl_size_" + row.tag)
            compare(wh.item.width, row.w, "cell width matches request")
            compare(wh.item.height, row.h, "cell height matches request")
            verify(findCanvas() !== null, "face Canvas exists")
            verify(G.looksRendered(img), "face rendered non-blank")
            var info = G.byObjName(wh.item, "analogClockInfo")
            verify(info !== null, "analog date and digital-time region exists")
            compare(info.visible, row.tag.indexOf("0.5x0.5") < 0,
                    "only the true micro tile is a pure clock face")
            compare(wh.item.showDigital, row.cls === "wide" || row.cls === "tall",
                    "shaped tiles earn the synchronized digital readout")
        }

        function test_analog_cf_seconds() {
            analogPrep(600, 600, "compact")
            setC("showNumerals", false)
            setC("showSeconds", true)
            wait(300)
            var on = snap(wh, "anl_seconds_on")
            var cv = findCanvas()
            var c = cv.mapToItem(wh, cv.width / 2, cv.height / 2)
            var rad = cv.width / 2 - 6
            verify(annulusHasColor(on, c.x, c.y, rad, 0.30, 0.88, cSystem, 45, 2),
                   "second-hand accent present in face annulus")

            setC("showSeconds", false)
            wait(300)
            var off = snap(wh, "anl_seconds_off")
            compare(cfg().showSeconds, false, "store updated")
            var changed = annulusDiffCount(on, off, c.x, c.y, rad,
                                           0.30, 0.88, 24, 2)
            verify(changed >= 8,
                   "turning seconds off removes visible hand pixels (changed=" + changed + ")")
        }

        property var _numSigOff: null
        function test_analog_cf_numerals_data() {
            return [ { tag: "off", v: false }, { tag: "on", v: true } ]
        }
        function test_analog_cf_numerals(row) {
            analogPrep(600, 600, "compact")
            setC("showSeconds", false)   // freeze the accent hand so only numerals differ
            setC("showNumerals", row.v)
            wait(320)
            var img = snap(wh, "anl_numerals_" + row.tag)
            compare(cfg().showNumerals, row.v, "store updated")
            var sig = gridSig(img)
            if (row.tag === "off") { _numSigOff = sig; verify(G.looksRendered(img), "face rendered") }
            else {
                verify(_numSigOff !== null, "off baseline captured")
                var d = sigDiff(_numSigOff, sig)
                verify(d >= 4, "numerals changed face pixels vs off (" + d + " samples)")
            }
        }

        function test_analog_cf_face_style() {
            analogPrep(600, 600, "compact")
            setC("showSeconds", false)
            setC("faceStyle", "classic")
            wait(300)
            var classic = snap(wh, "anl_face_classic")

            setC("faceStyle", "minimal")
            wait(300)
            var minimal = snap(wh, "anl_face_minimal")
            compare(cfg().faceStyle, "minimal", "face style persisted")
            var d = sigDiff(gridSig(classic), gridSig(minimal))
            verify(d >= 8, "minimal face visibly removes the classic rim (" + d + " samples)")
        }

        function test_analog_cf_hand_style() {
            analogPrep(600, 600, "compact")
            setC("showSeconds", false)
            setC("handStyle", "round")
            wait(300)
            var round = snap(wh, "anl_hands_round")

            setC("handStyle", "slender")
            wait(300)
            var slender = snap(wh, "anl_hands_slender")
            compare(cfg().handStyle, "slender", "hand style persisted")
            var d = sigDiff(gridSig(round), gridSig(slender))
            verify(d >= 2, "slender hands visibly differ from round hands (" + d + " samples)")
        }

        function test_analog_cf_micro_world_zone_badge() {
            analogPrep(360, 420, "compact")
            setC("customZone", true)
            setC("utcOffset", 5.5)
            wait(220)
            var badge = G.byObjName(wh.item, "analogZoneBadge")
            verify(badge !== null && effVisible(badge), "micro world clock shows its zone badge")
            verify(G.byText(badge, "UTC+5:30") !== null, "fractional fixed offset is explicit")
            snap(wh, "anl_micro_world_zone")
        }

        function test_analog_cf_invalid_zone_fallback() {
            analogPrep(820, 300, "wide")
            setC("customZone", true)
            setC("zoneId", "Mars/Olympus")
            setC("utcOffset", 2)
            wait(220)
            verify(wh.item.invalidZone, "invalid IANA zone detected")
            var zone = G.byText(wh.item, "Invalid zone")
            verify(zone !== null && effVisible(zone), "invalid-zone label is visible")
            var fallback = G.byText(wh.item, "fixed offset")
            verify(fallback !== null && effVisible(fallback), "fallback behavior is disclosed")
            snap(wh, "anl_invalid_zone_fallback")
        }

        function test_analog_cf_title() {
            analogPrep(600, 600, "tall")
            wh.expanded = true            // analog header is expanded-only
            setC("title", "Wall")
            wait(220)
            compare(cfg().title, "Wall", "store updated")
            var t = G.byText(wh.item, "Wall")
            verify(t !== null && effVisible(t), "custom header title 'Wall' visible")
            snap(wh, "anl_title")
        }

        function test_analog_st_micro() {
            analogPrep(360, 420, "compact")   // micro: min<480
            verify(wh.item.micro === true, "micro derived")
            var cv = findCanvas()
            verify(cv !== null && effVisible(cv), "face-only Canvas visible")
            verify(timeText() === null, "no digital time block in micro")
            snap(wh, "anl_st_micro")
        }
        function test_analog_st_compact() {
            analogPrep(600, 600, "compact")
            verify(wh.item.micro === false, "not micro")
            verify(timeText() === null, "compact hides the digital time")
            var d = G.byText(wh.item, ",")   // "ddd, d MMMM"
            verify(d !== null && effVisible(d), "date line visible under face")
            snap(wh, "anl_st_compact")
        }
        function test_analog_st_wide() {
            analogPrep(820, 300, "wide")
            var dig = timeText()
            verify(dig !== null && effVisible(dig), "wide shows digital time")
            var cv = findCanvas()
            var digX = dig.mapToItem(wh, dig.width / 2, 0).x
            var faceR = cv.mapToItem(wh, cv.width, 0).x
            verify(digX > faceR, "digital time sits to the right of the face (" + digX.toFixed(0) + ">" + faceR.toFixed(0) + ")")
            snap(wh, "anl_st_wide")
        }
        function test_analog_st_tall() {
            analogPrep(600, 900, "tall")
            var dig = timeText()
            verify(dig !== null && effVisible(dig), "tall shows digital time")
            var cv = findCanvas()
            var digY = dig.mapToItem(wh, 0, 0).y
            var faceB = cv.mapToItem(wh, 0, cv.height).y
            verify(digY > faceB, "digital block below the face (" + digY.toFixed(0) + ">" + faceB.toFixed(0) + ")")
            snap(wh, "anl_st_tall")
        }
        function test_analog_st_accent() {
            analogPrep(600, 600, "compact")
            setC("showSeconds", true)
            setC("accent", "red")
            wait(300)
            var img = snap(wh, "anl_st_accent")
            var cv = findCanvas()
            var c = cv.mapToItem(wh, cv.width / 2, cv.height / 2)
            var rad = cv.width / 2 - 6
            verify(annulusHasColor(img, c.x, c.y, rad, 0.10, 0.78, cRed, 110, 2),
                   "accent recolours second-hand / centre dot")
        }

        function test_analog_ch_accent_data() {
            return [ { tag: "override", name: "red", hex: cRed }, { tag: "auto", name: "", hex: cSystem } ]
        }
        function test_analog_ch_accent(row) {
            analogPrep(600, 600, "compact")
            setC("showSeconds", true)
            setC("accent", row.name)
            wait(300)
            var img = snap(wh, "anl_ch_accent_" + row.tag)
            if (row.name !== "") compare(cfg().accent, row.name, "accent persisted")
            var cv = findCanvas()
            var c = cv.mapToItem(wh, cv.width / 2, cv.height / 2)
            var rad = cv.width / 2 - 6
            verify(annulusHasColor(img, c.x, c.y, rad, 0.10, 0.78, row.hex, 120, 2),
                   "face painted in effective accent (" + row.hex + ")")
        }

        function test_analog_ch_backdrop_data() {
            return [ { tag: "none" }, { tag: "orbs" }, { tag: "mesh" }, { tag: "aurora" },
                     { tag: "waves" }, { tag: "stars" }, { tag: "bokeh" }, { tag: "grid" } ]
        }
        function test_analog_ch_backdrop(row) {
            analogPrep(600, 600, "compact")
            setC("cardBackdrop", row.tag)
            wait(220)
            var bl = findBackdrop()
            verify(bl !== null, "BackdropLayer present")
            if (row.tag === "none") verify(!bl.visible, "none → backdrop hidden")
            else verify(bl.visible, row.tag + " → backdrop visible")
            verify(G.looksRendered(snap(wh, "anl_backdrop_" + row.tag)), "rendered")
        }

        // ════════════════════════════════════════════════════════════════════
        // CLOCK (digital)
        // ════════════════════════════════════════════════════════════════════
        function test_clock_size_data() {
            return [
                { tag: "portrait-0.5x0.5",  w: 348,  h: 409,  cls: "compact" },
                { tag: "landscape-0.5x0.5", w: 423,  h: 306,  cls: "compact" },
                { tag: "portrait-0.5x1",    w: 348,  h: 818,  cls: "tall" },
                { tag: "landscape-0.5x1",   w: 846,  h: 306,  cls: "wide" },
                { tag: "portrait-1x0.5",    w: 696,  h: 409,  cls: "wide" },
                { tag: "landscape-1x0.5",   w: 423,  h: 612,  cls: "tall" },
                { tag: "portrait-1x1",      w: 696,  h: 818,  cls: "compact" },
                { tag: "landscape-1x1",     w: 846,  h: 612,  cls: "compact" },
                { tag: "portrait-1x1.5",    w: 696,  h: 1226, cls: "tall" },
                { tag: "landscape-1x1.5",   w: 1268, h: 612,  cls: "wide" }
            ]
        }
        function test_clock_size(row) {
            clockPrep(row.w, row.h, row.cls)
            var img = snap(wh, "clk_size_" + row.tag)
            compare(wh.item.width, row.w, "cell width matches request")
            compare(wh.item.height, row.h, "cell height matches request")
            var t = timeText()
            verify(t !== null && effVisible(t), "time readout rendered & visible")
            verify(t.contentWidth <= t.width + 1 || !t.truncated, "primary time not clipped")
            verify(G.looksRendered(img), "content rendered")
            var context = G.byObjName(wh.item, "clockCalendarContext")
            verify(context !== null, "calendar context exists")
            compare(context.visible, row.cls === "wide" || row.cls === "tall",
                    "shaped clock tiles earn calendar context")
        }

        function test_clock_cf_format24_data() {
            return [ { tag: "24h", v: true }, { tag: "12h", v: false } ]
        }
        function test_clock_cf_format24(row) {
            clockPrep(600, 600, "compact")
            setC("showSeconds", false)
            setC("format24", row.v)
            wait(220)
            compare(cfg().format24, row.v, "store updated")
            var s = "" + timeText().text
            snap(wh, "clk_fmt_" + row.tag)
            if (row.v) verify(s.indexOf("AM") < 0 && s.indexOf("PM") < 0 && /^\d{1,2}:\d{2}/.test(s), "24h form: " + s)
            else verify(s.indexOf("AM") >= 0 || s.indexOf("PM") >= 0, "12h form has AM/PM: " + s)
        }

        function test_clock_cf_seconds_data() {
            return [ { tag: "on", v: true }, { tag: "off", v: false } ]
        }
        function test_clock_cf_seconds(row) {
            clockPrep(600, 600, "compact")
            setC("format24", true)
            setC("showSeconds", row.v)
            wait(220)
            compare(cfg().showSeconds, row.v, "store updated")
            var parts = ("" + timeText().text).split(":")
            snap(wh, "clk_seconds_" + row.tag)
            if (row.v) compare(parts.length, 3, "HH:mm:ss has seconds segment")
            else compare(parts.length, 2, "HH:mm has no seconds segment")
        }

        function test_clock_cf_showdate_data() {
            return [ { tag: "on", v: true }, { tag: "off", v: false } ]
        }
        function test_clock_cf_showdate(row) {
            clockPrep(600, 600, "compact")
            setC("showDate", row.v)
            wait(220)
            compare(cfg().showDate, row.v, "store updated")
            var d = G.byText(wh.item, ",")   // full date "ddd, d MMM" contains a comma
            snap(wh, "clk_showdate_" + row.tag)
            if (row.v) verify(d !== null && effVisible(d), "date row visible")
            else verify(d === null || !effVisible(d), "date row hidden")
        }

        function test_clock_cf_datestyle_data() {
            return [ { tag: "full", v: "full" }, { tag: "short", v: "short" } ]
        }
        function test_clock_cf_datestyle(row) {
            clockPrep(600, 600, "compact")
            setC("dateStyle", row.v)
            wait(220)
            compare(cfg().dateStyle, row.v, "store updated")
            snap(wh, "clk_datestyle_" + row.tag)
            if (row.v === "short") {
                var sl = G.byText(wh.item, wh.item.formatAt(wh.item.dateFmt))
                verify(sl !== null && effVisible(sl), "short date uses the active locale format")
            } else {
                var fl = G.byText(wh.item, ",")    // ddd, d MMM
                verify(fl !== null && effVisible(fl), "full date spells weekday form")
            }
        }

        function test_clock_cf_customzone_data() {
            return [ { tag: "on", v: true }, { tag: "off", v: false } ]
        }
        function test_clock_cf_customzone(row) {
            clockPrep(600, 600, "compact")
            setC("customZone", row.v)
            wait(220)
            compare(cfg().customZone, row.v, "store updated")
            var chip = G.byText(wh.item, "UTC")   // default fixed-offset chip "UTC+0"
            snap(wh, "clk_customzone_" + row.tag)
            if (row.v) verify(chip !== null && effVisible(chip), "world-clock chip visible")
            else verify(chip === null, "no zone chip in local mode")
        }

        function test_clock_cf_zoneid_data() {
            return [
                { tag: "fixed",   z: "",                  chip: "UTC+0" },
                { tag: "newyork", z: "America/New_York",  chip: "New York" },
                { tag: "london",  z: "Europe/London",     chip: "London" },
                { tag: "berlin",  z: "Europe/Berlin",     chip: "Berlin" },
                { tag: "tokyo",   z: "Asia/Tokyo",        chip: "Tokyo" },
                { tag: "utc",     z: "UTC",               chip: "UTC" },
                { tag: "sydney",  z: "Australia/Sydney",  chip: "Sydney" }
            ]
        }
        function test_clock_cf_zoneid(row) {
            clockPrep(600, 600, "compact")
            setC("customZone", true)
            setC("zoneId", row.z)
            wait(240)
            compare(cfg().zoneId, row.z, "store updated")
            var chip = G.byText(wh.item, row.chip)
            snap(wh, "clk_zoneid_" + row.tag)
            verify(chip !== null && effVisible(chip), "zone chip shows '" + row.chip + "'")
        }

        function test_clock_cf_zonelabel() {
            clockPrep(600, 600, "compact")
            setC("customZone", true)
            setC("zoneId", "America/New_York")
            setC("zoneLabel", "HQ")
            wait(240)
            compare(cfg().zoneLabel, "HQ", "store updated")
            var chip = G.byText(wh.item, "HQ")
            verify(chip !== null && effVisible(chip), "zoneLabel overrides city in chip")
            snap(wh, "clk_zonelabel")
        }

        function test_clock_cf_utcoffset_data() {
            return [ { tag: "p550", v: 5.5, lbl: "UTC+5:30" },
                     { tag: "m12",  v: -12, lbl: "UTC-12" },
                     { tag: "p14",  v: 14,  lbl: "UTC+14" } ]
        }
        function test_clock_cf_utcoffset(row) {
            clockPrep(600, 600, "compact")
            setC("customZone", true)
            setC("zoneId", "")            // fixed-offset mode
            setC("utcOffset", row.v)
            wait(240)
            compare(cfg().utcOffset, row.v, "store updated")
            var chip = G.byText(wh.item, row.lbl)
            snap(wh, "clk_utcoffset_" + row.tag)
            verify(chip !== null && effVisible(chip), "offset chip shows '" + row.lbl + "'")
        }

        function test_clock_cf_title() {
            clockPrep(600, 600, "compact")
            setC("title", "Home")
            wait(220)
            compare(cfg().title, "Home", "store updated")
            var t = G.byText(wh.item, "Home")
            verify(t !== null && effVisible(t), "custom header title visible")
            snap(wh, "clk_title")
        }

        function test_clock_st_micro() {
            clockPrep(360, 420, "compact")
            setC("showSeconds", true); setC("format24", true)
            wait(220)
            verify(wh.item.micro === true, "micro derived")
            var head = G.byText(wh.item, "Clock")
            verify(head === null || !effVisible(head), "micro is headerless")
            var parts = ("" + timeText().text).split(":")
            compare(parts.length, 2, "seconds dropped in micro even when configured")
            snap(wh, "clk_st_micro")
        }
        function test_clock_st_baseline() {
            clockPrep(600, 600, "compact")
            setC("dateStyle", "short")
            wait(220)
            var head = G.byText(wh.item, "Clock")
            verify(head !== null && effVisible(head), "header visible")
            verify(effVisible(timeText()), "time visible")
            var d = G.byText(wh.item, wh.item.formatAt(wh.item.dateFmt))
            verify(d !== null && effVisible(d), "date visible")
            snap(wh, "clk_st_baseline")
        }
        function test_clock_st_wide() {
            clockPrep(820, 300, "wide")
            var wideSz = timeText().font.pixelSize
            clockPrep(600, 600, "compact")
            var baseSz = timeText().font.pixelSize
            verify(wideSz >= 96, "wide time remains glance-readable (" + wideSz.toFixed(0) + "px)")
            verify(wideSz >= baseSz - 4,
                   "wide time uses nearly the full short-axis budget (" + wideSz.toFixed(0)
                   + " vs " + baseSz.toFixed(0) + ")")
            clockPrep(820, 300, "wide")
            snap(wh, "clk_st_wide")
        }
        function test_clock_st_tall() {
            clockPrep(640, 980, "tall")
            var info = G.byText(wh.item, "Week")
            verify(info !== null && effVisible(info), "tall shows 'Week N · Day M' info line")
            snap(wh, "clk_st_tall")
        }
        function test_clock_st_secondary_zones() {
            clockPrep(640, 980, "tall")
            setC("customZone", true)
            setC("secondaryZones", "Europe/London, Asia/Tokyo, America/New_York")
            wait(260)
            var board = G.byObjName(wh.item, "clockSecondaryZones")
            verify(board !== null && effVisible(board),
                   "structured secondary-zone board is visible in a tall tile")
            verify(G.byText(wh.item, "London") !== null)
            verify(G.byText(wh.item, "Tokyo") !== null)
            verify(G.byText(wh.item, "New York") !== null)
            snap(wh, "clk_st_secondary_zones")
        }
        function test_clock_st_worldchip() {
            clockPrep(600, 600, "compact")
            setC("customZone", true)
            wait(220)
            var chip = G.byText(wh.item, "UTC")
            verify(chip !== null && effVisible(chip), "world-clock chip present on a non-expanded tile")
            snap(wh, "clk_st_worldchip")
        }
        function test_clock_st_zonefallback() {
            clockPrep(600, 600, "compact")
            setC("customZone", true)
            setC("zoneId", "Mars/Nowhere")   // unresolvable
            setC("utcOffset", 3)
            wait(240)
            verify(wh.item.zoneResolvable() === false, "bogus zone is unresolvable")
            var chip = G.byText(wh.item, "UTC+3")
            verify(chip !== null && effVisible(chip), "falls back to stored offset label, not UTC/blank")
            snap(wh, "clk_st_zonefallback")
        }

        function test_clock_ch_accent_data() {
            return [ { tag: "override", name: "red", hex: cRed }, { tag: "auto", name: "", hex: cSystem } ]
        }
        function test_clock_ch_accent(row) {
            clockPrep(600, 600, "compact")
            setC("customZone", true)      // chip renders in effAccent
            setC("accent", row.name)
            wait(260)
            var img = snap(wh, "clk_ch_accent_" + row.tag)
            if (row.name !== "") compare(cfg().accent, row.name, "accent persisted")
            verify(scanRegion(img, 0, 0, img.width, img.height, row.hex, 120, 3),
                   "accent element rendered in " + (row.name || "Auto/catSystem") + " colour")
        }

        function test_clock_ch_backdrop_data() {
            return [ { tag: "none" }, { tag: "orbs" }, { tag: "mesh" }, { tag: "aurora" },
                     { tag: "waves" }, { tag: "stars" }, { tag: "bokeh" }, { tag: "grid" } ]
        }
        function test_clock_ch_backdrop(row) {
            clockPrep(600, 600, "compact")
            setC("cardBackdrop", row.tag)
            wait(220)
            var bl = findBackdrop()
            verify(bl !== null, "BackdropLayer present")
            if (row.tag === "none") verify(!bl.visible, "none → backdrop hidden")
            else verify(bl.visible, row.tag + " → backdrop visible")
            verify(G.looksRendered(snap(wh, "clk_backdrop_" + row.tag)), "rendered")
        }

        // ════════════════════════════════════════════════════════════════════
        // MOON PHASE
        // ════════════════════════════════════════════════════════════════════
        function test_moon_size_data() {
            return [
                { tag: "portrait-0.5x0.5",  w: 348, h: 409, cls: "compact" },
                { tag: "landscape-0.5x0.5", w: 423, h: 306, cls: "compact" },
                { tag: "portrait-0.5x1",    w: 348, h: 818, cls: "tall" },
                { tag: "landscape-0.5x1",   w: 846, h: 306, cls: "wide" },
                { tag: "portrait-1x0.5",    w: 696, h: 409, cls: "wide" },
                { tag: "landscape-1x0.5",   w: 423, h: 612, cls: "tall" },
                { tag: "portrait-1x1",      w: 696, h: 818, cls: "compact" },
                { tag: "landscape-1x1",     w: 846, h: 612, cls: "compact" },
                { tag: "portrait-1x1.5",    w: 696, h: 1226, cls: "tall" },
                { tag: "landscape-1x1.5",   w: 1268, h: 612, cls: "wide" }
            ]
        }
        function test_moon_size(row) {
            moonPrep(row.w, row.h, row.cls)
            var img = snap(wh, "moon_size_" + row.tag)
            compare(wh.item.width, row.w, "cell width matches request")
            compare(wh.item.height, row.h, "cell height matches request")
            var g = moonGlyph()
            verify(g !== null && effVisible(g), "deterministic moon disc rendered and visible")
            if (row.tag === "landscape-1x1.5")
                verify(g.width >= 250, "wide 1x1.5 uses the extra area for a larger disc")
            verify(G.looksRendered(img), "content rendered")
            var upcoming = G.byObjName(wh.item, "moonUpcomingDates")
            verify(upcoming !== null, "upcoming phase dates exist")
            var rich = row.cls === "tall" || row.w * row.h > 700000
            compare(upcoming.visible, rich,
                    "tall and 1x1.5 tiles earn next-new and next-full dates")
            var cycle = G.byObjName(wh.item, "moonCyclePosition")
            verify(cycle !== null, "lunar-cycle timeline exists")
            compare(cycle.visible, rich,
                    "tall and 1x1.5 tiles visualize position within the lunar cycle")
        }

        function test_moon_cf_hemisphere_data() {
            return [ { tag: "north", v: "north", xs: 1 }, { tag: "south", v: "south", xs: -1 } ]
        }
        function test_moon_cf_hemisphere(row) {
            moonPrep(600, 600, "compact", 0.35)
            setC("hemisphere", row.v)
            wait(220)
            compare(cfg().hemisphere, row.v, "store updated")
            var g = moonGlyph()
            verify(g !== null, "deterministic disc found")
            compare(g.mirrored, row.v === "south",
                    row.v + " hemisphere sets deterministic disc mirroring")
            snap(wh, "moon_hemi_" + row.tag)
        }

        function test_moon_cf_title() {
            moonPrep(600, 600, "compact", 0.35)
            wh.expanded = true            // moon header is expanded-only
            setC("title", "Luna")
            wait(220)
            compare(cfg().title, "Luna", "store updated")
            var t = G.byText(wh.item, "Luna")
            verify(t !== null && effVisible(t), "custom header title visible")
            snap(wh, "moon_title")
        }

        function test_moon_st_micro() {
            moonPrep(360, 420, "compact", 0.5)   // Full Moon
            verify(wh.item.micro === true, "micro derived")
            var g = moonGlyph()
            verify(g !== null && effVisible(g), "deterministic disc shown in micro")
            var name = G.byText(wh.item, "Full Moon")
            verify(name === null || !effVisible(name), "name/illum column hidden in micro")
            snap(wh, "moon_st_micro")
        }
        function test_moon_st_baseline() {
            moonPrep(600, 600, "compact", 0.5)   // Full Moon
            var name = G.byText(wh.item, "Full Moon")
            verify(name !== null && effVisible(name), "phase name visible")
            var il = G.byText(wh.item, "illuminated")
            verify(il !== null && effVisible(il), "illumination line visible")
            snap(wh, "moon_st_baseline")
        }
        function test_moon_st_wide() {
            moonPrep(820, 300, "wide", 0.5)
            var g = moonGlyph()
            var name = G.byText(wh.item, "Full Moon")
            verify(g !== null && name !== null && effVisible(name), "disc + name present")
            var gx = g.mapToItem(wh, g.width / 2, 0).x
            var nx = name.mapToItem(wh, name.width / 2, 0).x
            verify(gx < nx, "glyph left of the name column (" + gx.toFixed(0) + "<" + nx.toFixed(0) + ")")
            snap(wh, "moon_st_wide")
        }
        function test_moon_st_talldates() {
            moonPrep(600, 900, "tall", 0.5)   // roomy → next new/full rows
            verify(wh.item.roomy === true, "roomy derived")
            var nd = G.byText(wh.item, "NEXT NEW")
            verify(nd !== null && effVisible(nd), "next-new/next-full date rows shown on tall tile")
            snap(wh, "moon_st_talldates")
        }
        function test_moon_st_newmoon() {
            moonPrep(600, 600, "compact", 0.0)   // pinned new moon
            compare(wh.item.idx, 0, "phase index is New Moon")
            var g = moonGlyph()
            verify(g !== null && effVisible(g), "new moon uses the deterministic disc")
            var name = G.byText(wh.item, "New Moon")
            verify(name !== null && effVisible(name), "name reads 'New Moon'")
            snap(wh, "moon_st_newmoon")
        }
        function test_moon_st_illumfull() {
            moonPrep(600, 600, "compact", 0.5)   // pinned full moon
            compare(wh.item.illum, 100, "illumination computes 100%")
            var il = G.byText(wh.item, "100% illuminated")
            verify(il !== null && effVisible(il), "illumination line reflects the pinned full moon")
            snap(wh, "moon_st_illumfull")
        }

        function test_moon_st_local_events_unconfigured() {
            moonPrep(600, 900, "tall", 0.35)
            setC("showLocalEvents", true)
            wait(220)
            var panel = G.byObjName(wh.item, "moonLocalEvents")
            verify(panel !== null && effVisible(panel), "local-events panel shown")
            var reason = G.byText(panel, "Location needed for local sky events")
            verify(reason !== null && effVisible(reason), "missing location reason is visible")
            snap(wh, "moon_local_events_unconfigured")
        }

        function test_moon_st_local_events_configured() {
            moonPrep(600, 1000, "tall", 0.35)
            setC("showLocalEvents", true)
            setC("place", "Vienna, AT")
            setC("lat", 48.2082)
            setC("lon", 16.3738)
            wait(260)
            var panel = G.byObjName(wh.item, "moonLocalEvents")
            verify(panel !== null && effVisible(panel), "configured local-events panel shown")
            verify(G.byText(panel, "Vienna, AT") !== null, "location identity shown")
            verify(G.byText(panel, "NEXT RISE") !== null, "rise is labelled")
            verify(G.byText(panel, "NEXT SET") !== null, "set is labelled")
            snap(wh, "moon_local_events_configured")
        }

        function test_moon_ch_accent_data() {
            return [ { tag: "override", name: "red", hex: cRed }, { tag: "auto", name: "", hex: cInfo } ]
        }
        function test_moon_ch_accent(row) {
            moonPrep(600, 900, "tall", 0.5)   // roomy → name + accent date rows
            setC("accent", row.name)
            wait(260)
            var img = snap(wh, "moon_ch_accent_" + row.tag)
            if (row.name !== "") compare(cfg().accent, row.name, "accent persisted")
            // Scan the lower half where name and next-date rows use the accent.
            verify(scanRegion(img, 0, img.height * 0.45, img.width, img.height, row.hex, 130, 3),
                   "name/date text rendered in " + (row.name || "Auto/catInfo") + " colour")
        }

        function test_moon_ch_backdrop_data() {
            return [ { tag: "none" }, { tag: "orbs" }, { tag: "mesh" }, { tag: "aurora" },
                     { tag: "waves" }, { tag: "stars" }, { tag: "bokeh" }, { tag: "grid" } ]
        }
        function test_moon_ch_backdrop(row) {
            moonPrep(600, 600, "compact", 0.35)
            setC("cardBackdrop", row.tag)
            wait(220)
            var bl = findBackdrop()
            verify(bl !== null, "BackdropLayer present")
            if (row.tag === "none") verify(!bl.visible, "none → backdrop hidden")
            else verify(bl.visible, row.tag + " → backdrop visible")
            verify(G.looksRendered(snap(wh, "moon_backdrop_" + row.tag)), "rendered")
        }
    }
}
