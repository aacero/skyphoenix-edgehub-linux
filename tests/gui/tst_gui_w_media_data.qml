import QtQuick
import QtTest
import "../ui" as UI
import "GuiUtil.js" as G

// Visible GUI tests for the three "connect-a-source" Hub widgets:
//   • media    (Now Playing)  - real transport via MockMedia (playPause/next/prev)
//   • httpjson (HTTP / JSON)  - value/gauge/list + every error state
//   • kpi      (KPI)          - number + trend + stats, http & file sources
//
// Each widget is hosted single via UI.WidgetHarness in a REAL KWin-composited
// window and driven with real store mutations, a real XHR stub (item.xhrFactory,
// the same seam the existing tst_httpjson_net / tst_kpi_net use), MockMedia
// transport calls, and real mouse clicks on the tile controls. sizeClass /
// accentName / cardBackdrop / titleOverride are set directly - the harness has no
// Dashboard, but that is exactly the public API Dashboard.injectWidget binds, so
// the visible pixels are identical.
//
// Assertions are GUI-observable: item geometry, effective visibility of Text /
// controls, on-screen text content, live store setting reflected in the readout,
// and grabImage() pixel colour scanned over the accent-tinted element. snap()
// writes evidence PNGs per case.
//
// The three harnesses live in non-overlapping x-columns so a real mouseClick on
// one widget's control can never land on another.
Item {
    id: root
    // Wide enough to keep the KPI column fully on-screen at a landscape 1x3
    // projection (1600 + 2536px), rather than silently clipping the test image.
    width: 4300; height: 2600

    // Media column: x [0, 800)
    Item { id: mediaWrap; x: 0; y: 0; width: 696; height: 819
        UI.WidgetHarness { id: mh; anchors.fill: parent; widgetFile: "MediaWidget.qml" } }
    // HTTP/JSON column: x [800, 1500)
    Item { id: httpWrap; x: 800; y: 0; width: 696; height: 819
        UI.WidgetHarness { id: hh; anchors.fill: parent; widgetFile: "HttpJsonWidget.qml" } }
    // KPI column: x [1600, …)
    Item { id: kpiWrap; x: 1600; y: 0; width: 696; height: 819
        UI.WidgetHarness { id: kh; anchors.fill: parent; widgetFile: "KpiWidget.qml" } }

    // ── shared scene-graph helpers (walk the live tree incl. non-visual data) ──
    // A DE-DUPLICATING walk: GuiUtil.collectPred re-visits nodes reachable via both
    // `children` and `data` (diamonds), which multiplied list-row counts ~32×. A
    // visited set keeps every node counted exactly once.
    function collect(node, pred) {
        var out = [], seen = []
        function rec(n) {
            if (!n || seen.indexOf(n) >= 0) return
            seen.push(n)
            try { if (pred(n)) out.push(n) } catch (e) {}
            var k = n.children
            for (var i = 0; k && i < k.length; i++) rec(k[i])
            var d = n.data
            if (d && d !== k) for (var j = 0; j < d.length; j++) rec(d[j])
        }
        rec(node)
        return out
    }
    function first(node, pred) { var a = collect(node, pred); return a.length ? a[0] : null }
    function named(node, objectName) {
        return collect(node, function (n) { return n && n.objectName === objectName })
    }

    function effVisible(n) {
        var c = n
        while (c) { if (c.visible === false) return false; c = c.parent }
        return true
    }
    // Colour compare tolerant of case / alpha (a color object vs a stored hex).
    property color _probe
    function colorsClose(a, b) {
        return Math.abs(a.r - b.r) < 0.04 && Math.abs(a.g - b.g) < 0.04 && Math.abs(a.b - b.b) < 0.04
    }
    function vtexts(node, sub) {
        var s = ("" + sub).toLowerCase()
        return collect(node, function (n) {
            try { return n && n.text !== undefined
                         && ("" + n.text).toLowerCase().indexOf(s) >= 0 && root.effVisible(n) }
            catch (e) { return false }
        })
    }
    function vexact(node, t) {
        return collect(node, function (n) {
            try { return n && n.text !== undefined && ("" + n.text) === t && root.effVisible(n) }
            catch (e) { return false }
        })
    }
    function iconByName(node, nm) {
        return collect(node, function (n) {
            try { return n && n.name !== undefined && n.name === nm && root.effVisible(n) }
            catch (e) { return false }
        })
    }
    function gaugeNodes(node) {
        return collect(node, function (n) {
            try { return n && n.showSpark !== undefined && n.bigMax !== undefined && root.effVisible(n) }
            catch (e) { return false }
        })
    }
    function sparkNodes(node) {
        return collect(node, function (n) {
            try { return n && n.values !== undefined && n.fill !== undefined
                         && n.color !== undefined && root.effVisible(n) }
            catch (e) { return false }
        })
    }
    function backdropNode(node) {
        return first(node, function (n) {
            try { return n && n.style !== undefined && n.accent !== undefined && n.running !== undefined }
            catch (e) { return false }
        })
    }
    // All repeat timers in a subtree (a widget's poll Timer + any backdrop-animation
    // Timers), so a caller can pick the one whose interval matches.
    function repeatTimers(node) {
        return collect(node, function (n) {
            try { return n && n.interval !== undefined && n.repeat === true } catch (e) { return false }
        })
    }
    function hasTimerInterval(node, ms) {
        var ts = repeatTimers(node)
        for (var i = 0; i < ts.length; i++) if (ts[i].interval === ms) return true
        return false
    }
    function listRows(node) {
        return collect(node, function (n) {
            try { return n && n.text !== undefined && /^•/.test("" + n.text) && root.effVisible(n) }
            catch (e) { return false }
        })
    }

    // A fresh XHR stub (same shape as tst_httpjson_net / tst_kpi_net).
    function makeFake() {
        return {
            method: "", url: "", sent: false, aborted: false,
            readyState: 0, status: 0, responseText: "", headers: ({}),
            timeout: 0, ontimeout: null, onreadystatechange: null,
            open: function (m, u) { this.method = m; this.url = u; this.readyState = 1 },
            setRequestHeader: function (k, v) { this.headers[k] = v },
            send: function () { this.sent = true },
            abort: function () { this.aborted = true },
            resolveWith: function (status, body) {
                this.status = status; this.responseText = body; this.readyState = 4
                if (this.onreadystatechange) this.onreadystatechange()
            },
            fireTimeout: function () { if (this.ontimeout) this.ontimeout() }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 1) MEDIA - 25 cases
    // ─────────────────────────────────────────────────────────────────────────
    TestCase {
        id: tcMedia
        name: "GuiWMedia"
        when: windowShown
        visible: true

        function snap(item, n) { var i = G.grabItem(this, item, root); i.save("gui-evidence/wmedia_" + n + ".png"); return i }

        function initTestCase() { tryVerify(function () { return mh.ready }, 5000) }

        property int mseq: 0
        function mFresh(w, h, cls) {
            mediaWrap.width = w; mediaWrap.height = h
            var id = "m-" + (++mseq)
            mh.storeCtl.ensureSettings(id, {})
            mh.item.instanceId = id
            mh.item.accentName = ""; mh.item.cardBackdrop = "none"; mh.item.titleOverride = ""
            mh.item.sizeClass = cls
            wait(50)
            return mh.item
        }
        // Min RGB distance to `col` scanned over a node's grabbed pixels.
        function nodeMinDist(node, col) {
            var img = G.grabItem(this, node, root)
            var er = Math.round(col.r * 255), eg = Math.round(col.g * 255), eb = Math.round(col.b * 255)
            var best = 99999, W = img.width, H = img.height
            // Dense enough to land inside a thin glyph stroke, not just its box.
            var sx = Math.max(1, Math.floor(W / 160)), sy = Math.max(1, Math.floor(H / 160))
            for (var y = 0; y < H; y += sy) for (var x = 0; x < W; x += sx) {
                var dr = img.red(x, y) - er, dg = img.green(x, y) - eg, db = img.blue(x, y) - eb
                var d = Math.sqrt(dr * dr + dg * dg + db * db); if (d < best) best = d
            }
            return best
        }

        // ---- Sizes (5): every declared media size renders art + title. ----
        function test_size_data() {
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
        function test_size(row) {
            var it = mFresh(row.w, row.h, row.cls)
            mh.mediaCtl.loadTrack("SongZed", "BandY")
            wait(120)
            compare(it.width, row.w, row.tag + ": tile width")
            compare(it.height, row.h, row.tag + ": tile height")
            var img = snap(mh, "size_" + row.tag)
            verify(G.looksRendered(img), row.tag + ": rendered non-blank pixels")
            verify(root.vexact(it, "SongZed").length >= 1, row.tag + ": title visible")
            var artwork = G.byObjName(it, "mediaArtwork")
            verify(artwork !== null && root.effVisible(artwork), row.tag + ": artwork visible")
            var progress = G.byObjName(it, "mediaProgress")
            verify(progress !== null, row.tag + ": progress track exists")
            var micro = row.tag.indexOf("0.5x0.5") >= 0
            compare(progress.visible, !micro, row.tag + ": progress only where it fits")
            compare(root.iconByName(it, "ui-skip-back").length > 0, !micro,
                    row.tag + ": full transport only where it fits")
            verify(root.iconByName(it, "ui-pause").length > 0,
                   row.tag + ": play/pause remains a full touch target")
        }

        // ---- Transport (3): counts change on a REAL click. ----
        function test_transport_data() {
            return [
                { tag: "playpause", icon: "ui-pause", counter: "playPauseCount" },
                { tag: "previous",  icon: "ui-skip-back", counter: "previousCount" },
                { tag: "next",      icon: "ui-skip-fwd",  counter: "nextCount" }
            ]
        }
        function test_transport(row) {
            var it = mFresh(696, 819, "compact")   // baseline: rich → prev/play/next
            mh.mediaCtl.loadTrack("SongZed", "BandY")
            wait(120)
            var icons = root.iconByName(it, row.icon)
            verify(icons.length >= 1, row.tag + ": found the " + row.icon + " glyph")
            var rect = icons[0].parent          // AppIcon is centred in the button Rectangle
            var before = mh.mediaCtl[row.counter]
            snap(mh, "transport_" + row.tag + "_before")
            mouseClick(rect, rect.width / 2, rect.height / 2)
            wait(150)
            var after = mh.mediaCtl[row.counter]
            snap(mh, "transport_" + row.tag + "_after")
            compare(after, before + 1, row.tag + ": " + row.counter + " incremented")
        }

        // ---- Glyph swap (1): play→pause glyph flips with playing state. ----
        function test_glyph_swaps() {
            var it = mFresh(696, 819, "compact")
            mh.mediaCtl.loadTrack("SongZed", "BandY")   // status Playing → glyph "ui-pause"
            wait(120)
            verify(root.iconByName(it, "ui-pause").length >= 1, "playing shows the pause glyph")
            verify(root.iconByName(it, "ui-play").length === 0, "…and not the play glyph")
            var rect = root.iconByName(it, "ui-pause")[0].parent
            snap(mh, "glyph_playing")
            mouseClick(rect, rect.width / 2, rect.height / 2)  // toggles to Paused
            wait(150)
            verify(root.iconByName(it, "ui-play").length >= 1, "paused now shows the play glyph")
            verify(root.iconByName(it, "ui-pause").length === 0, "…and the pause glyph is gone")
            snap(mh, "glyph_paused")
        }

        // ---- States (6) ----
        function test_state_nothing_playing() {
            var it = mFresh(696, 819, "compact")
            mh.mediaCtl.clearTrack()
            wait(120)
            snap(mh, "state_nothing")
            verify(root.vtexts(it, "No track loaded").length >= 1,
                   "idle-player placeholder shown")
        }
        function test_state_playing_meta() {
            var it = mFresh(696, 819, "compact")
            mh.mediaCtl.loadTrack("SongZed", "BandY")
            wait(120)
            snap(mh, "state_playing")
            verify(root.vexact(it, "SongZed").length >= 1, "title visible")
            verify(root.vexact(it, "BandY").length >= 1, "artist visible")
        }
        function test_state_progress_fill() {
            var it = mFresh(696, 819, "compact")
            mh.mediaCtl.loadTrack("SongZed", "BandY")   // position 0.3
            wait(200)
            // The progress track is an 8px Rectangle with a single inner fill child.
            var tracks = G.collectPred(it, function (n) {
                try { return n && n.radius !== undefined && Math.abs(n.height - 8) < 1.5
                             && n.width > 60 && root.effVisible(n)
                             && n.children && n.children.length >= 1 } catch (e) { return false }
            })
            verify(tracks.length >= 1, "found the progress track")
            var track = tracks[0]
            var fill = track.children[0]
            var ratio = fill.width / track.width
            snap(mh, "state_progress")
            verify(ratio > 0.18 && ratio < 0.45, "fill ≈ 30% of the bar (was " + ratio.toFixed(2) + ")")
        }
        function test_state_micro_play_only() {
            var it = mFresh(348, 409, "compact")   // micro
            mh.mediaCtl.loadTrack("SongZed", "BandY")
            wait(120)
            compare(it.micro, true, "half-cell is micro")
            compare(it.showHeader, false, "micro drops the header")
            verify(root.iconByName(it, "ui-skip-back").length === 0, "no prev on micro")
            verify(root.iconByName(it, "ui-skip-fwd").length === 0, "no next on micro")
            verify(root.iconByName(it, "ui-play").length + root.iconByName(it, "ui-pause").length >= 1,
                   "play target still present")
            snap(mh, "state_micro")
        }
        function test_state_wide_art_beside_meta() {
            var it = mFresh(846, 306, "wide")
            mh.mediaCtl.loadTrack("SongZed", "BandY")
            wait(120)
            compare(it.horiz, true, "wide is the horizontal variant")
            var art = root.vexact(it, "♪")          // art fallback glyph, centred in the cover
            var title = root.vexact(it, "SongZed")
            verify(art.length >= 1 && title.length >= 1, "art glyph + title present")
            var artX = it.mapFromItem(art[0], art[0].width / 2, 0).x
            var titleX = it.mapFromItem(title[0], title[0].width / 2, 0).x
            snap(mh, "state_wide")
            verify(artX < titleX, "art sits left of the metadata (" + artX.toFixed(0) + " < " + titleX.toFixed(0) + ")")
        }
        function test_state_art_fallback_glyph() {
            var it = mFresh(696, 819, "compact")
            mh.mediaCtl.loadTrack("SongZed", "BandY")   // loadTrack sets no artUrl → fallback ♪
            wait(120)
            snap(mh, "state_artfallback")
            verify(root.vexact(it, "♪").length >= 1, "♪ art fallback shown when no cover loads")
        }

        // ---- Chrome (10): accent override, accent auto, cardBackdrop ×8 ----
        function test_chrome_accent_override() {
            var it = mFresh(696, 819, "compact")
            mh.mediaCtl.loadTrack("SongZed", "BandY")
            it.accentName = "red"
            wait(120)
            root._probe = mh.theme.accentPresets["red"].a
            verify(root.colorsClose(it.effAccent, root._probe), "accent preset resolved")
            var play = root.iconByName(it, "ui-pause")[0].parent   // solid effAccent fill
            var d = nodeMinDist(play, it.effAccent)
            snap(mh, "chrome_accent_red")
            console.warn("DBG media accent red dist=" + d.toFixed(0) + " eff=" + it.effAccent)
            verify(d < 60, "play button is tinted the accent (dist " + d.toFixed(0) + ")")
        }
        function test_chrome_accent_auto() {
            var it = mFresh(696, 819, "compact")
            mh.mediaCtl.loadTrack("SongZed", "BandY")
            it.accentName = ""
            wait(120)
            compare("" + it.effAccent, "" + mh.theme.catEntertainment, "Auto → category colour")
            var play = root.iconByName(it, "ui-pause")[0].parent
            var d = nodeMinDist(play, it.effAccent)
            snap(mh, "chrome_accent_auto")
            var dimg = G.grabItem(this, play, root)
            console.warn("DBG media accent auto dist=" + d.toFixed(0) + " eff=" + it.effAccent
                         + " c=" + dimg.pixel(30,30) + " q=" + dimg.pixel(15,15) + " r=" + dimg.pixel(45,30)
                         + " rgb(30,30)=" + dimg.red(30,30) + "," + dimg.green(30,30) + "," + dimg.blue(30,30))
            verify(d < 60, "play button uses the category accent (dist " + d.toFixed(0) + ")")
        }
        function test_chrome_backdrop_data() {
            return [ { tag: "none" }, { tag: "orbs" }, { tag: "mesh" }, { tag: "aurora" },
                     { tag: "waves" }, { tag: "stars" }, { tag: "bokeh" }, { tag: "grid" } ]
        }
        function test_chrome_backdrop(row) {
            var it = mFresh(696, 819, "compact")
            mh.mediaCtl.loadTrack("SongZed", "BandY")
            it.cardBackdrop = row.tag
            wait(120)
            var bd = root.backdropNode(it)
            verify(bd !== null, row.tag + ": BackdropLayer exists")
            compare(bd.style, row.tag, row.tag + ": style applied")
            compare(bd.visible, row.tag !== "none", row.tag + ": visible iff a style is chosen")
            snap(mh, "chrome_backdrop_" + row.tag)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2) HTTP / JSON - 46 cases
    // ─────────────────────────────────────────────────────────────────────────
    TestCase {
        id: tcHttp
        name: "GuiWHttpJson"
        when: windowShown
        visible: true

        function snap(item, n) { var i = G.grabItem(this, item, root); i.save("gui-evidence/whttp_" + n + ".png"); return i }

        property var lastFake: null
        function initTestCase() {
            tryVerify(function () { return hh.ready }, 5000)
            hh.active = false   // no live polling; we drive the stub / seed explicitly
            hh.item.xhrFactory = function () { tcHttp.lastFake = root.makeFake(); return tcHttp.lastFake }
        }

        property int hseq: 0
        function hFresh(w, h, cls, settings) {
            httpWrap.width = w; httpWrap.height = h
            var id = "h-" + (++hseq)
            hh.storeCtl.ensureSettings(id, {})
            if (settings) hh.storeCtl.patchSettings(id, settings)
            hh.item.instanceId = id
            hh.item.hist = []
            hh.item.accentName = ""; hh.item.cardBackdrop = "none"; hh.item.titleOverride = ""
            hh.item.sizeClass = cls
            wait(50)
            return hh.item
        }
        function seedVal(v) { hh.storeCtl.patchSettings(hh.item.instanceId,
            { httpText: "" + v, httpVal: v, httpErr: "", httpList: [] }) }
        function seedList(n) {
            var items = []
            for (var i = 0; i < n; i++) items.push("row-" + i)
            hh.storeCtl.patchSettings(hh.item.instanceId,
                { httpList: items, httpText: n + " items", httpVal: undefined, httpErr: "" })
        }
        function nodeMinDist(node, col) {
            var img = G.grabItem(this, node, root)
            var er = Math.round(col.r * 255), eg = Math.round(col.g * 255), eb = Math.round(col.b * 255)
            var best = 99999, W = img.width, H = img.height
            // Dense enough to land inside a thin glyph stroke, not just its box.
            var sx = Math.max(1, Math.floor(W / 160)), sy = Math.max(1, Math.floor(H / 160))
            for (var y = 0; y < H; y += sy) for (var x = 0; x < W; x += sx) {
                var dr = img.red(x, y) - er, dg = img.green(x, y) - eg, db = img.blue(x, y) - eb
                var d = Math.sqrt(dr * dr + dg * dg + db * db); if (d < best) best = d
            }
            return best
        }

        // ---- Physical size projections (6 allocations x 2 orientations) ----
        function test_size_data() {
            return [
                { tag: "p_0.5x0.5", w: 348,  h: 409,  cls: "compact", roomy: false },
                { tag: "l_0.5x0.5", w: 423,  h: 306,  cls: "compact", roomy: false },
                { tag: "p_0.5x1",   w: 348,  h: 818,  cls: "tall",    roomy: false },
                { tag: "l_0.5x1",   w: 846,  h: 306,  cls: "wide",    roomy: false },
                { tag: "p_1x0.5",   w: 696,  h: 409,  cls: "wide",    roomy: false },
                { tag: "l_1x0.5",   w: 423,  h: 612,  cls: "tall",    roomy: false },
                { tag: "p_1x1",     w: 696,  h: 818,  cls: "compact", roomy: false },
                { tag: "l_1x1",     w: 846,  h: 612,  cls: "compact", roomy: false },
                { tag: "p_1x1.5",   w: 696,  h: 1226, cls: "tall",    roomy: false },
                { tag: "l_1x1.5",   w: 1268, h: 612,  cls: "wide",    roomy: false },
                { tag: "p_1x2",     w: 696,  h: 1635, cls: "large",   roomy: true },
                { tag: "l_1x2",     w: 1691, h: 612,  cls: "large",   roomy: true }
            ]
        }
        function test_size(row) {
            var it = hFresh(row.w, row.h, row.cls,
                            { url: "http://status.lan/api", jsonPath: "system.load",
                              pollSec: 30, mode: "value" })
            it.hist = [0.25, 0.42, 0.38, 0.61, 0.57, 0.72]
            seedVal(128); wait(80)
            compare(it.width, row.w, row.tag + ": width")
            compare(it.height, row.h, row.tag + ": height")
            var img = snap(hh, "size_" + row.tag)
            verify(G.looksRendered(img), row.tag + ": rendered")
            verify(root.vexact(it, "128").length >= 1, row.tag + ": the reading is shown")
            compare(root.named(it, "httpSourceContext").length > 0
                    && root.effVisible(root.named(it, "httpSourceContext")[0]),
                    row.roomy, row.tag + ": source context is reserved for roomy sizes")
        }

        // ---- Config fields (17) ----
        function test_config_data() {
            return [
                { tag: "url-set",   kind: "urlset" },
                { tag: "url-clear", kind: "urlclear" },
                { tag: "jsonPath",  kind: "path" },
                { tag: "jsonPath-clear", kind: "pathclear" },
                { tag: "authToken", kind: "auth" },
                { tag: "mode-value", kind: "modeval" },
                { tag: "mode-gauge", kind: "modegauge" },
                { tag: "mode-list",  kind: "modelist" },
                { tag: "unit",      kind: "unit" },
                { tag: "gaugeMax",  kind: "gaugemax" },
                { tag: "listMax-3", kind: "listmax", max: 3 },
                { tag: "listMax-5", kind: "listmax", max: 5 },
                { tag: "warnAt",    kind: "warn" },
                { tag: "critAt",    kind: "crit" },
                { tag: "pollSec-5",    kind: "poll", sec: 5 },
                { tag: "pollSec-3600", kind: "poll", sec: 3600 },
                { tag: "title",     kind: "title" }
            ]
        }
        function test_config(row) {
            var it
            switch (row.kind) {
            case "urlset":
                it = hFresh(696, 819, "compact", { url: "http://x/y", mode: "value" }); seedVal(5); wait(80)
                verify(root.vtexts(it, "Add a URL").length === 0, "hint gone once a URL is set")
                verify(root.vexact(it, "5").length >= 1, "the reading renders")
                break
            case "urlclear":
                it = hFresh(696, 819, "compact", { url: "" }); wait(80)
                verify(root.vtexts(it, "Add a URL").length >= 1, "hint returns when URL is blank")
                break
            case "path":
                it = hFresh(696, 819, "compact", { url: "http://x/y", jsonPath: "data.value", mode: "value" })
                it.refresh(); tcHttp.lastFake.resolveWith(200, '{"data":{"value":42}}'); wait(80)
                compare(it.valText, "42", "dotted path extracted the value")
                verify(root.vexact(it, "42").length >= 1, "…and it is on screen")
                break
            case "pathclear":
                it = hFresh(696, 819, "compact", { url: "http://x/y", jsonPath: "", mode: "value" })
                it.refresh(); tcHttp.lastFake.resolveWith(200, '99'); wait(80)
                compare(it.valNum, 99, "blank path takes the whole body")
                verify(root.vexact(it, "99").length >= 1, "…shown")
                break
            case "auth":
                it = hFresh(696, 819, "compact", { url: "http://x/y", authToken: "${env:X}", mode: "value" })
                seedVal(7); wait(80)
                compare(it.authToken, "${env:X}", "token stored verbatim")
                verify(root.vtexts(it, "${env:X}").length === 0, "…and never leaks into the readout")
                break
            case "modeval":
                it = hFresh(696, 819, "compact", { url: "http://x/y", mode: "value" }); seedVal(64); wait(80)
                verify(root.vexact(it, "64").length >= 1, "value mode shows the number")
                break
            case "modegauge":
                it = hFresh(696, 819, "compact", { url: "http://x/y", mode: "gauge" }); seedVal(64); wait(80)
                verify(root.gaugeNodes(it).length >= 1, "gauge mode renders the MetricGauge ring")
                break
            case "modelist":
                it = hFresh(696, 1637, "large", { url: "http://x/y", mode: "list", listMax: 5 }); seedList(4); wait(80)
                verify(root.listRows(it).length >= 1, "list mode renders bulleted rows")
                break
            case "unit":
                it = hFresh(696, 819, "compact", { url: "http://x/y", mode: "value", unit: "ms" }); seedVal(128); wait(80)
                verify(root.vexact(it, "ms").length >= 1, "unit label rendered")
                break
            case "gaugemax":
                it = hFresh(696, 819, "compact", { url: "http://x/y", mode: "gauge", gaugeMax: 200 }); seedVal(50); wait(80)
                var g = root.gaugeNodes(it)[0]
                verify(Math.abs(g.value - 0.25) < 0.03, "ring fill = value/gaugeMax (" + g.value.toFixed(2) + ")")
                break
            case "listmax":
                it = hFresh(696, 1637, "large", { url: "http://x/y", mode: "list", listMax: row.max }); seedList(10); wait(80)
                verify(root.listRows(it).length <= row.max, "at most listMax rows (" + root.listRows(it).length + "<=" + row.max + ")")
                verify(root.listRows(it).length >= 1, "…and at least one")
                break
            case "warn":
                it = hFresh(696, 819, "compact", { url: "http://x/y", mode: "value", warnAt: "80" }); seedVal(85); wait(80)
                compare("" + it.valColor, "" + hh.theme.warning, "≥ warnAt → amber")
                break
            case "crit":
                it = hFresh(696, 819, "compact", { url: "http://x/y", mode: "value", critAt: "95" }); seedVal(96); wait(80)
                compare("" + it.valColor, "" + hh.theme.error, "≥ critAt → red")
                break
            case "poll":
                it = hFresh(696, 819, "compact", { url: "http://x/y", mode: "value", pollSec: row.sec }); seedVal(5); wait(80)
                verify(root.hasTimerInterval(it, row.sec * 1000), "a poll timer runs at pollSec=" + row.sec + " (" + row.sec * 1000 + "ms)")
                break
            case "title":
                it = hFresh(696, 819, "compact", { url: "http://x/y", mode: "value" }); seedVal(5)
                it.titleOverride = "API"; wait(80)
                verify(root.vexact(it, "API").length >= 1, "custom title shown in header")
                break
            }
            snap(hh, "config_" + row.tag)
        }

        // ---- Body (1): refresh button drives a real re-fetch. ----
        function test_body_refresh() {
            var it = hFresh(696, 819, "compact", { url: "http://x/y", mode: "value", jsonPath: "" })
            seedVal(1); wait(80)
            var rect = G.byObjName(it, "httpRefreshButton")
            verify(rect !== null, "refresh control present on the tile")
            snap(hh, "refresh_before")
            mouseClick(rect, rect.width / 2, rect.height / 2)   // → w.refresh() via the stub
            verify(tcHttp.lastFake !== null, "a request was made through the gate")
            tcHttp.lastFake.resolveWith(200, "55"); wait(80)
            compare(it.valText, "55", "the readout re-rendered from the new response")
            verify(root.vexact(it, "55").length >= 1, "…and it is on screen")
            snap(hh, "refresh_after")
        }

        // ---- States (11) ----
        function test_state_data() {
            return [
                { tag: "unconfigured", kind: "unconf" },
                { tag: "value",   kind: "value" },
                { tag: "gauge",   kind: "gauge" },
                { tag: "list",    kind: "list" },
                { tag: "offline", kind: "err", err: "Offline" },
                { tag: "blocked", kind: "err", err: "Blocked" },
                { tag: "parse",   kind: "err", err: "Parse error" },
                { tag: "nomatch", kind: "err", err: "No match" },
                { tag: "warn",    kind: "warn" },
                { tag: "crit",    kind: "crit" },
                { tag: "micro",   kind: "micro" }
            ]
        }
        function test_state(row) {
            var it
            switch (row.kind) {
            case "unconf":
                it = hFresh(696, 819, "compact", { url: "", mode: "value" }); wait(80)
                var hint = root.vtexts(it, "Add a URL")
                verify(hint.length >= 1, "unconfigured hint shown")
                verify(hint[0].font.pixelSize >= 11, "hint legible (" + hint[0].font.pixelSize + "px)")
                break
            case "value":
                it = hFresh(696, 819, "compact", { url: "http://x/y", mode: "value" }); seedVal(128); wait(80)
                verify(root.vexact(it, "128").length >= 1, "value number rendered")
                break
            case "gauge":
                it = hFresh(696, 819, "compact", { url: "http://x/y", mode: "gauge" }); seedVal(42); wait(80)
                var g = root.gaugeNodes(it)
                verify(g.length >= 1 && g[0].ok, "gauge ring present and ok")
                break
            case "list":
                it = hFresh(696, 1637, "large", { url: "http://x/y", mode: "list", listMax: 5 }); seedList(4); wait(80)
                verify(root.listRows(it).length >= 1, "list rows rendered")
                break
            case "err":
                it = hFresh(696, 819, "compact", { url: "http://x/y", mode: "value" })
                hh.storeCtl.patchSettings(it.instanceId, { httpErr: row.err, httpText: "-", httpVal: undefined })
                wait(80)
                compare(it.errText, row.err, "errText = " + row.err)
                verify(root.vexact(it, row.err).length >= 1, "error text '" + row.err + "' is on screen")
                break
            case "warn":
                it = hFresh(696, 819, "compact", { url: "http://x/y", mode: "value", warnAt: "80" }); seedVal(85); wait(80)
                compare("" + it.valColor, "" + hh.theme.warning, "warn colour")
                var wn = root.vexact(it, "85")
                verify(wn.length >= 1 && nodeMinDist(wn[0], hh.theme.warning) < 60, "number painted amber")
                break
            case "crit":
                it = hFresh(696, 819, "compact", { url: "http://x/y", mode: "value", critAt: "95" }); seedVal(96); wait(80)
                compare("" + it.valColor, "" + hh.theme.error, "crit colour")
                var cn = root.vexact(it, "96")
                verify(cn.length >= 1 && nodeMinDist(cn[0], hh.theme.error) < 70, "number painted red")
                break
            case "micro":
                it = hFresh(348, 409, "compact", { url: "http://x/y", mode: "value" }); seedVal(42); wait(80)
                compare(it.micro, true, "half-cell is micro")
                compare(it.showHeader, false, "micro drops the header")
                verify(root.vexact(it, "42").length >= 1, "…but still shows the number")
                break
            }
            snap(hh, "state_" + row.tag)
        }

        // ---- Gauge-fill (+1) ----
        function test_gauge_fill_sweep() {
            var it = hFresh(696, 819, "compact", { url: "http://x/y", mode: "gauge", gaugeMax: 100 })
            seedVal(42); wait(80)
            var g = root.gaugeNodes(it)[0]
            verify(g !== undefined, "gauge present")
            verify(Math.abs(g.value - 0.42) < 0.03, "ring sweep ≈ 0.42 (" + g.value.toFixed(2) + ")")
            snap(hh, "gauge_fill")
        }

        // ---- Chrome (10) ----
        function test_chrome_accent_override() {
            var it = hFresh(696, 819, "compact", { url: "http://x/y", mode: "value" })
            seedVal(128); it.accentName = "red"; wait(80)
            root._probe = hh.theme.accentPresets["red"].a
            verify(root.colorsClose(it.effAccent, root._probe), "accent preset resolved")
            var n = root.vexact(it, "128")[0]
            var d = nodeMinDist(n, it.effAccent)
            snap(hh, "chrome_accent_red")
            verify(d < 60, "the number is painted the accent (dist " + d.toFixed(0) + ")")
        }
        function test_chrome_accent_auto() {
            var it = hFresh(696, 819, "compact", { url: "http://x/y", mode: "value" })
            seedVal(128); it.accentName = ""; wait(80)
            compare("" + it.effAccent, "" + hh.theme.catInfo, "Auto → catInfo")
            var n = root.vexact(it, "128")[0]
            var d = nodeMinDist(n, it.effAccent)
            snap(hh, "chrome_accent_auto")
            verify(d < 60, "the number uses the category accent (dist " + d.toFixed(0) + ")")
        }
        function test_chrome_backdrop_data() {
            return [ { tag: "none" }, { tag: "orbs" }, { tag: "mesh" }, { tag: "aurora" },
                     { tag: "waves" }, { tag: "stars" }, { tag: "bokeh" }, { tag: "grid" } ]
        }
        function test_chrome_backdrop(row) {
            var it = hFresh(696, 819, "compact", { url: "http://x/y", mode: "value" })
            seedVal(128); it.cardBackdrop = row.tag; wait(80)
            var bd = root.backdropNode(it)
            verify(bd !== null, row.tag + ": BackdropLayer exists")
            compare(bd.style, row.tag, row.tag + ": style applied")
            compare(bd.visible, row.tag !== "none", row.tag + ": visible iff a style is chosen")
            snap(hh, "chrome_backdrop_" + row.tag)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3) KPI - 46 cases
    // ─────────────────────────────────────────────────────────────────────────
    TestCase {
        id: tcKpi
        name: "GuiWKpi"
        when: windowShown
        visible: true

        function snap(item, n) { var i = G.grabItem(this, item, root); i.save("gui-evidence/wkpi_" + n + ".png"); return i }

        property var lastFake: null
        function initTestCase() {
            tryVerify(function () { return kh.ready }, 5000)
            kh.active = false
            kh.item.xhrFactory = function () { tcKpi.lastFake = root.makeFake(); return tcKpi.lastFake }
        }

        property int kseq: 0
        function kFresh(w, h, cls, settings) {
            kpiWrap.width = w; kpiWrap.height = h
            var id = "k-" + (++kseq)
            kh.storeCtl.ensureSettings(id, {})
            if (settings) kh.storeCtl.patchSettings(id, settings)
            kh.item.instanceId = id
            kh.item.hist = []
            kh.item.accentName = ""; kh.item.cardBackdrop = "none"; kh.item.titleOverride = ""
            kh.item.sizeClass = cls
            wait(50)
            return kh.item
        }
        function seedVal(v) { kh.storeCtl.patchSettings(kh.item.instanceId,
            { httpText: "" + v, httpVal: v, httpErr: "" }) }
        // Feed a real numeric series through the widget's own apply path so hist +
        // the persisted normalised sparkline both populate.
        function feed(vals) {
            kh.item.hist = []
            for (var i = 0; i < vals.length; i++) kh.item._apply(vals[i])
        }
        function nodeMinDist(node, col) {
            var img = G.grabItem(this, node, root)
            var er = Math.round(col.r * 255), eg = Math.round(col.g * 255), eb = Math.round(col.b * 255)
            var best = 99999, W = img.width, H = img.height
            // Dense enough to land inside a thin glyph stroke, not just its box.
            var sx = Math.max(1, Math.floor(W / 160)), sy = Math.max(1, Math.floor(H / 160))
            for (var y = 0; y < H; y += sy) for (var x = 0; x < W; x += sx) {
                var dr = img.red(x, y) - er, dg = img.green(x, y) - eg, db = img.blue(x, y) - eb
                var d = Math.sqrt(dr * dr + dg * dg + db * db); if (d < best) best = d
            }
            return best
        }

        // ---- Physical size projections (7 allocations x 2 orientations) ----
        function test_size_data() {
            return [
                { tag: "p_0.5x0.5", w: 348,  h: 409,  cls: "compact", roomy: false, split: false },
                { tag: "l_0.5x0.5", w: 423,  h: 306,  cls: "compact", roomy: false, split: false },
                { tag: "p_0.5x1",   w: 348,  h: 818,  cls: "tall",    roomy: false, split: false },
                { tag: "l_0.5x1",   w: 846,  h: 306,  cls: "wide",    roomy: false, split: true  },
                { tag: "p_1x0.5",   w: 696,  h: 409,  cls: "wide",    roomy: false, split: true  },
                { tag: "l_1x0.5",   w: 423,  h: 612,  cls: "tall",    roomy: false, split: false },
                { tag: "p_1x1",     w: 696,  h: 818,  cls: "compact", roomy: false, split: false },
                { tag: "l_1x1",     w: 846,  h: 612,  cls: "compact", roomy: false, split: false },
                { tag: "p_1x1.5",   w: 696,  h: 1226, cls: "tall",    roomy: false, split: false },
                { tag: "l_1x1.5",   w: 1268, h: 612,  cls: "wide",    roomy: false, split: true  },
                { tag: "p_1x2",     w: 696,  h: 1635, cls: "large",   roomy: true,  split: false },
                { tag: "l_1x2",     w: 1691, h: 612,  cls: "large",   roomy: true,  split: true  },
                { tag: "p_1x3",     w: 696,  h: 2452, cls: "large",   roomy: true,  split: false },
                { tag: "l_1x3",     w: 2536, h: 612,  cls: "large",   roomy: true,  split: true  }
            ]
        }
        function test_size(row) {
            var it = kFresh(row.w, row.h, row.cls, { source: "http", url: "http://x/y", label: "Lat", unit: "ms" })
            feed([31, 36, 33, 40, 38, 42]); wait(80)
            compare(it.width, row.w, row.tag + ": width")
            compare(it.height, row.h, row.tag + ": height")
            compare(it.split, row.split, row.tag + ": physical composition")
            var img = snap(kh, "size_" + row.tag)
            verify(G.looksRendered(img), row.tag + ": rendered")
            verify(root.vexact(it, "42").length >= 1, row.tag + ": number rendered")
            compare(root.vexact(it, "min").length > 0, row.roomy,
                    row.tag + ": min/avg/max belongs only to roomy sizes")
        }

        // ---- Config fields (16) ----
        function test_config_data() {
            return [
                { tag: "source-http", kind: "srchttp" },
                { tag: "source-file", kind: "srcfile" },
                { tag: "url",         kind: "url" },
                { tag: "filePath",    kind: "filepath" },
                { tag: "jsonPath",    kind: "path" },
                { tag: "authToken",   kind: "auth" },
                { tag: "label-Queue", kind: "label" },
                { tag: "label-blank", kind: "labelblank" },
                { tag: "unit",        kind: "unit" },
                { tag: "invert-on",   kind: "inverton" },
                { tag: "invert-off",  kind: "invertoff" },
                { tag: "warnAt",      kind: "warn" },
                { tag: "critAt",      kind: "crit" },
                { tag: "pollSec-5",    kind: "poll", sec: 5 },
                { tag: "pollSec-3600", kind: "poll", sec: 3600 },
                { tag: "title",       kind: "title" }
            ]
        }
        function test_config(row) {
            var it
            switch (row.kind) {
            case "srchttp":
                it = kFresh(696, 819, "compact", { source: "http", url: "http://x/y" }); seedVal(5); wait(80)
                compare(it.configured, true, "http source with a URL is configured")
                verify(root.vtexts(it, "Connect a URL").length === 0, "unconfigured hint gone")
                break
            case "srcfile":
                it = kFresh(696, 819, "compact", { source: "file", filePath: "/run/m" }); seedVal(5); wait(80)
                compare(it.endpoint, "file:///run/m", "file source builds a file:// endpoint")
                verify(root.vtexts(it, "Connect a URL").length === 0, "hint gone for file source")
                break
            case "url":
                it = kFresh(696, 819, "compact", { source: "http", url: "http://api/x" }); wait(80)
                compare(it.configured, true, "url makes an http source configured")
                break
            case "filepath":
                it = kFresh(696, 819, "compact", { source: "file", filePath: "/run/x" }); wait(80)
                compare(it.configured, true, "filePath makes a file source configured")
                compare(it.endpoint, "file:///run/x", "endpoint reflects the path")
                break
            case "path":
                it = kFresh(696, 819, "compact", { source: "http", url: "http://x/y", jsonPath: "stats.count" })
                it.refresh(); tcKpi.lastFake.resolveWith(200, '{"stats":{"count":128}}'); wait(80)
                compare(it.valText, "128", "jsonPath extracted the value")
                verify(root.vexact(it, "128").length >= 1, "…and it renders")
                break
            case "auth":
                it = kFresh(696, 819, "compact", { source: "http", url: "http://x/y", authToken: "tok" }); seedVal(7); wait(80)
                compare(it.authToken, "tok", "token stored")
                verify(root.vtexts(it, "tok").length === 0, "…and never leaks into the readout")
                break
            case "label":
                it = kFresh(696, 819, "compact", { source: "http", url: "http://x/y", label: "Queue" }); seedVal(5); wait(80)
                verify(root.vexact(it, "Queue").length >= 1, "label line shows the custom label")
                break
            case "labelblank":
                it = kFresh(696, 819, "compact", { source: "http", url: "http://x/y", label: "" }); seedVal(5); wait(80)
                verify(root.vexact(it, "KPI").length >= 1, "blank label falls back to the title")
                break
            case "unit":
                it = kFresh(696, 819, "compact", { source: "http", url: "http://x/y", unit: "ms" }); seedVal(128); wait(80)
                verify(root.vexact(it, "ms").length >= 1, "unit rendered beside the number")
                break
            case "inverton":
                it = kFresh(696, 819, "compact", { source: "http", url: "http://x/y", invert: true, warnAt: "90" })
                seedVal(80); wait(80)
                compare("" + it.valColor, "" + kh.theme.warning, "invert: low value ≤ warnAt → amber")
                break
            case "invertoff":
                it = kFresh(696, 819, "compact", { source: "http", url: "http://x/y", invert: false, warnAt: "80" })
                seedVal(85); wait(80)
                compare("" + it.valColor, "" + kh.theme.warning, "non-invert: high value ≥ warnAt → amber")
                break
            case "warn":
                it = kFresh(696, 819, "compact", { source: "http", url: "http://x/y", warnAt: "80" }); seedVal(85); wait(80)
                compare("" + it.valColor, "" + kh.theme.warning, "≥ warnAt → amber")
                break
            case "crit":
                it = kFresh(696, 819, "compact", { source: "http", url: "http://x/y", critAt: "95" }); seedVal(97); wait(80)
                compare("" + it.valColor, "" + kh.theme.error, "≥ critAt → red")
                break
            case "poll":
                it = kFresh(696, 819, "compact", { source: "http", url: "http://x/y", pollSec: row.sec }); seedVal(5); wait(80)
                verify(root.hasTimerInterval(it, row.sec * 1000), "a poll timer runs at pollSec=" + row.sec + " (" + row.sec * 1000 + "ms)")
                break
            case "title":
                it = kFresh(696, 819, "compact", { source: "http", url: "http://x/y" }); seedVal(5)
                it.titleOverride = "SLA"; wait(80)
                verify(root.vexact(it, "SLA").length >= 1, "custom title shown in header")
                break
            }
            snap(kh, "config_" + row.tag)
        }

        // ---- Body (1): refresh drives a real re-fetch. ----
        function test_body_refresh() {
            var it = kFresh(696, 819, "compact", { source: "http", url: "http://x/y", jsonPath: "" })
            seedVal(1); wait(80)
            var rect = G.byObjName(it, "kpiRefreshButton")
            verify(rect !== null, "refresh control present")
            snap(kh, "refresh_before")
            mouseClick(rect, rect.width / 2, rect.height / 2)
            verify(tcKpi.lastFake !== null, "a request was made")
            tcKpi.lastFake.resolveWith(200, "77"); wait(80)
            compare(it.valText, "77", "readout re-rendered from the response")
            verify(root.vexact(it, "77").length >= 1, "…shown")
            snap(kh, "refresh_after")
        }

        // ---- States (11) ----
        function test_state_data() {
            return [
                { tag: "unconfigured", kind: "unconf" },
                { tag: "micro-nosrc",  kind: "micronosrc" },
                { tag: "number",       kind: "number" },
                { tag: "sparkline",    kind: "spark" },
                { tag: "stats",        kind: "stats" },
                { tag: "warn",         kind: "warn" },
                { tag: "crit",         kind: "crit" },
                { tag: "invert-warn",  kind: "invwarn" },
                { tag: "invert-crit",  kind: "invcrit" },
                { tag: "error-label",  kind: "errlabel" },
                { tag: "error-dash",   kind: "errdash" }
            ]
        }
        function test_state(row) {
            var it
            switch (row.kind) {
            case "unconf":
                it = kFresh(696, 819, "compact", { source: "http", url: "" }); wait(80)
                verify(root.vtexts(it, "Connect a URL").length >= 1, "unconfigured prompt shown")
                break
            case "micronosrc":
                it = kFresh(348, 409, "compact", { source: "http", url: "" }); wait(80)
                compare(it.micro, true, "half-cell micro")
                verify(root.vtexts(it, "No source").length >= 1, "micro unconfigured says 'No source'")
                break
            case "number":
                it = kFresh(696, 819, "compact", { source: "http", url: "http://x/y" }); seedVal(42); wait(80)
                verify(root.vexact(it, "42").length >= 1, "number rendered")
                break
            case "spark":
                it = kFresh(696, 819, "compact", { source: "http", url: "http://x/y" })
                feed([40, 55, 42, 61, 58]); wait(80)
                verify(it.showSpark, "sparkline earned once a series exists")
                verify(root.sparkNodes(it).length >= 1, "…and it is rendered")
                break
            case "stats":
                it = kFresh(696, 1637, "large", { source: "http", url: "http://x/y" })
                feed([40, 55, 42, 61, 58]); wait(80)
                verify(it.showStats, "roomy tile earns the stats strip")
                verify(root.vexact(it, "min").length >= 1 && root.vexact(it, "avg").length >= 1
                       && root.vexact(it, "max").length >= 1, "min/avg/max cells shown")
                break
            case "warn":
                it = kFresh(696, 819, "compact", { source: "http", url: "http://x/y", warnAt: "80" }); seedVal(85); wait(80)
                compare("" + it.valColor, "" + kh.theme.warning, "warn colour")
                var wn = root.vexact(it, "85")
                verify(wn.length >= 1 && nodeMinDist(wn[0], kh.theme.warning) < 60, "number painted amber")
                break
            case "crit":
                it = kFresh(696, 819, "compact", { source: "http", url: "http://x/y", critAt: "95" }); seedVal(97); wait(80)
                compare("" + it.valColor, "" + kh.theme.error, "crit colour")
                break
            case "invwarn":
                it = kFresh(696, 819, "compact", { source: "http", url: "http://x/y", invert: true, warnAt: "90", critAt: "50" })
                seedVal(80); wait(80)
                compare("" + it.valColor, "" + kh.theme.warning, "invert warn: ≤ warnAt → amber")
                break
            case "invcrit":
                it = kFresh(696, 819, "compact", { source: "http", url: "http://x/y", invert: true, warnAt: "90", critAt: "50" })
                seedVal(40); wait(80)
                compare("" + it.valColor, "" + kh.theme.error, "invert crit: ≤ critAt → red")
                break
            case "errlabel":
                it = kFresh(696, 819, "compact", { source: "http", url: "http://x/y" })
                kh.storeCtl.patchSettings(it.instanceId, { httpErr: "Offline", httpText: "-", httpVal: undefined }); wait(80)
                compare(it.errText, "Offline", "errText set")
                verify(root.vexact(it, "Offline").length >= 1, "error shown in the label line")
                break
            case "errdash":
                it = kFresh(696, 819, "compact", { source: "http", url: "http://x/y" })
                kh.storeCtl.patchSettings(it.instanceId, { httpErr: "Offline", httpText: "-", httpVal: undefined }); wait(80)
                verify(root.vexact(it, "-").length >= 1, "value shows '-' while an error holds")
                break
            }
            snap(kh, "state_" + row.tag)
        }

        // ---- Split billboard (+1) ----
        function test_split_billboard() {
            var it = kFresh(1269, 612, "wide", { source: "http", url: "http://x/y", label: "Err budget", unit: "%" })
            feed([40, 55, 42, 61, 58]); wait(80)
            compare(it.split, true, "1269x612 splits into two columns")
            var num = root.vexact(it, "58")
            var sp = root.sparkNodes(it)
            verify(num.length >= 1 && sp.length >= 1, "number + trend both present")
            var numX = it.mapFromItem(num[0], num[0].width / 2, 0).x
            var spX = it.mapFromItem(sp[0], sp[0].width / 2, 0).x
            snap(kh, "split")
            verify(numX < spX, "the number sits left of the trend (" + numX.toFixed(0) + " < " + spX.toFixed(0) + ")")
        }

        // ---- Chrome (10) ----
        function test_chrome_accent_override() {
            var it = kFresh(696, 819, "compact", { source: "http", url: "http://x/y" })
            seedVal(128); it.accentName = "red"; wait(80)
            root._probe = kh.theme.accentPresets["red"].a
            verify(root.colorsClose(it.effAccent, root._probe), "accent preset resolved")
            var n = root.vexact(it, "128")[0]
            var d = nodeMinDist(n, it.effAccent)
            snap(kh, "chrome_accent_red")
            verify(d < 60, "the number is painted the accent (dist " + d.toFixed(0) + ")")
        }
        function test_chrome_accent_auto() {
            var it = kFresh(696, 819, "compact", { source: "http", url: "http://x/y" })
            seedVal(128); it.accentName = ""; wait(80)
            compare("" + it.effAccent, "" + kh.theme.catInfo, "Auto → catInfo")
            var n = root.vexact(it, "128")[0]
            var d = nodeMinDist(n, it.effAccent)
            snap(kh, "chrome_accent_auto")
            verify(d < 60, "the number uses the category accent (dist " + d.toFixed(0) + ")")
        }
        function test_chrome_backdrop_data() {
            return [ { tag: "none" }, { tag: "orbs" }, { tag: "mesh" }, { tag: "aurora" },
                     { tag: "waves" }, { tag: "stars" }, { tag: "bokeh" }, { tag: "grid" } ]
        }
        function test_chrome_backdrop(row) {
            var it = kFresh(696, 819, "compact", { source: "http", url: "http://x/y" })
            seedVal(128); it.cardBackdrop = row.tag; wait(80)
            var bd = root.backdropNode(it)
            verify(bd !== null, row.tag + ": BackdropLayer exists")
            compare(bd.style, row.tag, row.tag + ": style applied")
            compare(bd.visible, row.tag !== "none", row.tag + ": visible iff a style is chosen")
            snap(kh, "chrome_backdrop_" + row.tag)
        }
    }
}
