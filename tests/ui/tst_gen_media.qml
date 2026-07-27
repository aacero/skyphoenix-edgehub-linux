import QtQuick
import QtTest
import "../../ui/qml" as App

// ─────────────────────────────────────────────────────────────────────────
// tst_gen_media - COMPREHENSIVE coverage for area "widget:media"
// (ui/qml/widgets/MediaWidget.qml, driven by the MPRIS `media` bridge -
// mocked here by MockMedia).
//
// Covers: the effAccent binding-loop bug (MediaWidget is the only widget that
// sets accentColor: w.effAccent, creating a 2-node cycle so the DEFAULT card
// renders a black accent), per-widget accent recolouring, real mouse clicks on
// the compact + expanded transport, the leading " · " subtitle bug, progress
// clamping/reactivity, the honest "nothing playing" placeholder, album-art
// fallback, header status, touch-target sizing, the reduce-motion progress
// animation bug, and the shared config-schema area.
//
// Regression assertions encode the corrected behaviour for the accent,
// subtitle, reduce-motion, responsive metadata, and minimum type-size defects.
//
// NOT covered here (C++-only, needs the real MprisBridge - MockMedia cannot
// model them): GetAll-timeout debounce, Identity→friendly-name mapping, the
// Seeked-while-paused signal, and tile-level tap-to-expand propagation.
// ─────────────────────────────────────────────────────────────────────────
// Every harness below is laid out so it stays INSIDE the test window: the
// clicking TestCases map item coordinates to window coordinates, and an item
// parked past the window edge silently misses.
Item {
    id: root
    width: 1300; height: 2400

    // Main expanded harness - accent, subtitle, progress, transport, placeholder.
    WidgetHarness {
        id: h; x: 0; y: 0; width: 420; height: 760
        widgetFile: "MediaWidget.qml"; expanded: true
    }
    // Compact tile harness - compact play/pause click + compact touch target.
    // 423x306 is the REAL 0.5x0.5 landscape half-cell (see WidgetSizes). It was
    // 360x120, a box the size model cannot produce: the smallest footprint any
    // tile ever gets is the half-cell (348x409 portrait / 423x306 landscape).
    // A 120px-tall host cannot hold art + a title + a 52px play target, so it
    // was asserting the click behaviour of a shape that never ships.
    WidgetHarness {
        id: hC; x: 700; y: 0; width: 423; height: 306
        widgetFile: "MediaWidget.qml"; expanded: false
    }

    // Resizable host for the per-sizeClass structure tests (W1 wave 3) - the
    // REAL projected footprints of media's five declared sizes:
    //   0.5x0.5 → 348x409 portrait · 423x306 landscape   (compact, micro)
    //   0.5x1   → 348x819 portrait (tall) · 846x306 landscape (wide)
    //   1x0.5   → 696x409 portrait (wide) · 423x612 landscape (tall)
    //   1x1     → 696x819 portrait · 846x612 landscape   (compact)
    //   1x1.5   → 696x1228 portrait (tall) · 1269x612 landscape (wide)
    Item { id: sizeWrap; x: 0; y: 800; width: 696; height: 819
        WidgetHarness { id: hS; anchors.fill: parent
            widgetFile: "MediaWidget.qml"; expanded: false } }

    // Shared config-schema area, instantiated directly.
    App.WidgetConfigSchema { id: sc }

    // ── tree helpers ─────────────────────────────────────────────────────────
    function colEq(a, b) { return Qt.colorEqual(a, b) }
    function lum(c) { return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }
    function isRect(n) { return n && n.hasOwnProperty("radius") && n.hasOwnProperty("gradient") && n.hasOwnProperty("color") }
    function isText(n) { return n && typeof n.paintedWidth === "number" && typeof n.text === "string" }
    function isMouseArea(n) { return n && n.hasOwnProperty("pressed") && n.hasOwnProperty("containsMouse") }
    function isImage(n) { return n && n.hasOwnProperty("fillMode") && n.hasOwnProperty("sourceSize") && n.hasOwnProperty("status") }

    function effVisible(n) {
        while (n) { if (n.visible === false) return false; n = n.parent }
        return true
    }
    function findAll(node, pred, acc) {
        if (!node) return acc
        if (pred(node)) acc.push(node)
        var kids = node.children
        for (var i = 0; kids && i < kids.length; i++) findAll(kids[i], pred, acc)
        return acc
    }
    function findByProp(node, prop, val) {
        if (!node) return null
        if (node[prop] !== undefined && node[prop] === val) return node
        var kids = node.children
        for (var i = 0; kids && i < kids.length; i++) {
            var r = findByProp(kids[i], prop, val); if (r) return r
        }
        return null
    }
    function texts(harness) { return findAll(harness.item, isText, []) }
    function textContaining(harness, sub) {
        var t = texts(harness)
        for (var i = 0; i < t.length; i++) if (t[i].text.indexOf(sub) >= 0) return t[i]
        return null
    }
    // The AppIcon component exposes `name`/`color`/`size`.
    function appIcon(harness, nm) { return findByProp(harness.item, "name", nm) }
    // Rectangle with a laid-out width (transport buttons are sized by width===target).
    function rectByWidth(harness, wpx) {
        var rs = findAll(harness.item, isRect, [])
        for (var i = 0; i < rs.length; i++) if (Math.round(rs[i].width) === wpx) return rs[i]
        return null
    }
    // The progress track is the ONLY Rectangle whose FILL colour is cardBorder.
    function progressTrack(harness) {
        var rs = findAll(harness.item, isRect, [])
        for (var i = 0; i < rs.length; i++)
            if (colEq(rs[i].color, harness.theme.cardBorder)) return rs[i]
        return null
    }
    function progressFill(harness) {
        var tr = progressTrack(harness); if (!tr) return null
        var kids = tr.children
        for (var i = 0; kids && i < kids.length; i++) if (isRect(kids[i])) return kids[i]
        return null
    }
    // Effectively-visible transport MouseAreas. The seek surface is also a
    // MouseArea now, so require the parent button's semantic control property.
    function transport(harness) {
        var all = findAll(harness.item, isMouseArea, [])
        var out = []
        for (var i = 0; i < all.length; i++) {
            var ma = all[i]
            if (ma.acceptedButtons === Qt.NoButton) continue
            if (!effVisible(ma)) continue
            if (!ma.parent || ma.parent.accessibleName === undefined) continue
            out.push(ma)
        }
        return out
    }
    function globalX(item) { var p = item.mapToItem(root, 0, 0); return p.x }

    function seed(harness, title, artist, album) {
        var m = harness.mediaCtl
        m.available = true; m.title = title; m.artist = artist
        m.album = (album === undefined ? "" : album)
        m.artUrl = ""; m.playerName = "MockPlayer"; m.status = "Playing"; m.position = 0.3
    }

    // ── effAccent binding-loop (HIGH-severity bug) ───────────────────────────
    TestCase {
        name: "MediaAccent"
        when: windowShown
        function init() {
            tryVerify(function () { return h.ready }, 3000)
            h.item.accentName = ""            // default: no per-widget accent
            h.mediaCtl.clearTrack()
        }

        // MediaWidget sets `accentColor: w.effAccent`, and WidgetChrome's
        // effAccent falls back to accentColor when accentName=="" → a direct
        // binding cycle. The correct behaviour is a visible accent colour; the
        // loop resolves it to black/transparent.
        function test_default_accent_is_visible_not_black() {
            var w = h.item
            verify(!colEq(w.effAccent, "#000000"),
                   "default effAccent must not resolve to black (binding loop): got " + w.effAccent)
            verify(w.effAccent.a > 0.5,
                   "default effAccent must be opaque/visible, got alpha " + w.effAccent.a)
        }

        // The expanded play button fills with effAccent and paints a near-black
        // (#0D1117) glyph on top - under the loop both are ~black, so the glyph
        // is invisible. Assert real contrast between button fill and glyph.
        function test_play_button_glyph_has_contrast() {
            seed(h, "Song", "Artist", "Album")
            var play = rectByWidth(h, h.theme.touchPrimary)   // 76px primary button
            verify(play !== null, "found the expanded play button")
            verify(colEq(play.color, h.item.effAccent), "play button fill == effAccent")
            var glyph = Qt.color("#0D1117")
            verify(lum(play.color) - lum(glyph) > 0.15,
                   "play glyph (#0D1117) must contrast against the button fill; "
                   + "fill lum=" + lum(play.color).toFixed(3))
        }

        // Choosing a per-widget accent breaks the loop and recolours everything.
        function test_per_widget_accent_recolours_live() {
            seed(h, "Song", "Artist", "Album")
            h.item.accentName = "green"
            var green = Qt.color(h.theme.accentPresets["green"].a)
            compare(String(h.item.effAccent), String(green), "effAccent = green preset")

            var icon = appIcon(h, "media")
            verify(icon !== null, "found the header 'media' icon")
            verify(colEq(icon.color, green), "header icon recoloured to accent")

            var play = rectByWidth(h, h.theme.touchPrimary)
            verify(colEq(play.color, green), "play button recoloured to accent")

            var fill = progressFill(h)
            verify(fill !== null, "found the progress fill")
            verify(colEq(fill.color, green), "progress fill recoloured to accent")
        }
    }

    // ── expanded subtitle: leading " · " bug ─────────────────────────────────
    TestCase {
        name: "MediaSubtitle"
        when: windowShown
        function init() {
            tryVerify(function () { return h.ready }, 3000)
            h.item.accentName = "green"       // avoid black-render noise
            h.mediaCtl.clearTrack()
        }

        // Artist empty, album set (podcasts / some streams) → subtitle should be
        // just the album, NOT "  ·  Album" with a stray leading separator.
        function test_empty_artist_omits_leading_separator() {
            seed(h, "Podcast Ep 12", "", "Abbey Road")
            var node = textContaining(h, "Abbey Road")
            verify(node !== null, "found the subtitle showing the album")
            compare(node.text, "Abbey Road",
                    "subtitle must omit the leading ' · ' when artist is empty")
        }
        function test_both_present_joins_with_middot() {
            seed(h, "Come Together", "The Beatles", "Abbey Road")
            var node = textContaining(h, "Abbey Road")
            verify(node !== null, "found the subtitle")
            verify(node.text.indexOf("The Beatles") === 0, "starts with the artist")
            verify(node.text.indexOf("·") > 0, "joins artist and album with a middot")
        }
        function test_artist_only_no_trailing_separator() {
            seed(h, "Track", "Solo Artist", "")
            var node = textContaining(h, "Solo Artist")
            verify(node !== null, "found the subtitle")
            compare(node.text, "Solo Artist", "no separator when only the artist is set")
        }
    }

    // ── progress bar: clamping + reactivity ──────────────────────────────────
    TestCase {
        name: "MediaProgress"
        when: windowShown
        function init() {
            tryVerify(function () { return h.ready }, 3000)
            h.item.accentName = "green"
            h.theme.reduceMotion = false
            h.mediaCtl.clearTrack()
            seed(h, "Song", "Artist", "Album")
        }

        function test_position_half_fills_half() {
            var fill = progressFill(h), track = progressTrack(h)
            verify(fill !== null && track !== null, "found the progress bar")
            h.mediaCtl.position = 0.5
            tryVerify(function () { return Math.abs(fill.width - track.width * 0.5) < 3 }, 1500,
                      "0.5 → half width")
        }
        function test_position_clamps_above_one() {
            var fill = progressFill(h), track = progressTrack(h)
            h.mediaCtl.position = 5.0
            tryVerify(function () { return Math.abs(fill.width - track.width) < 3 }, 1500,
                      "position 5.0 clamps to full width (not overflow)")
        }
        function test_position_clamps_below_zero() {
            var fill = progressFill(h), track = progressTrack(h)
            h.mediaCtl.position = -1.0
            tryVerify(function () { return fill.width < 2 }, 1500,
                      "position -1.0 clamps to zero width")
        }
        function test_position_reactive() {
            var fill = progressFill(h), track = progressTrack(h)
            h.mediaCtl.position = 0.2
            tryVerify(function () { return Math.abs(fill.width - track.width * 0.2) < 3 }, 1500)
            h.mediaCtl.position = 0.8
            tryVerify(function () { return Math.abs(fill.width - track.width * 0.8) < 3 }, 1500,
                      "progress updates reactively when position changes")
        }
    }

    // ── progress animation must honour reduceMotion (LOW-severity bug) ────────
    TestCase {
        name: "MediaProgressMotion"
        when: windowShown
        function init() {
            tryVerify(function () { return h.ready }, 3000)
            h.item.accentName = "green"
            h.mediaCtl.clearTrack()
            seed(h, "Song", "Artist", "Album")
        }
        function cleanup() { h.theme.reduceMotion = false }

        // The fill's `Behavior on width` is hardcoded to 400ms and ignores
        // theme.reduceMotion; with reduce-motion on the bar should SNAP, so a
        // frame after a jump the width is already at target.
        function test_reduce_motion_snaps_progress() {
            var fill = progressFill(h), track = progressTrack(h)
            h.theme.reduceMotion = true
            h.mediaCtl.position = 0.0
            tryVerify(function () { return fill.width < 2 }, 1500, "settled at zero")
            h.mediaCtl.position = 1.0
            wait(16)                          // one frame
            verify(Math.abs(fill.width - track.width) < 3,
                   "reduce-motion should snap the progress fill (no 400ms sweep); "
                   + "width=" + Math.round(fill.width) + " target=" + Math.round(track.width))
        }
    }

    // ── "nothing playing" placeholder + no stale content ─────────────────────
    TestCase {
        name: "MediaPlaceholder"
        when: windowShown
        function init() {
            tryVerify(function () { return h.ready }, 3000)
            h.item.accentName = "green"
            h.mediaCtl.clearTrack()
        }

        function test_placeholder_visible_when_unavailable() {
            compare(h.item.avail, false)
            var node = textContaining(h, "No track loaded")
            verify(node !== null, "placeholder text present")
            verify(effVisible(node), "placeholder shows when nothing is playing")
        }
        function test_placeholder_hidden_when_available() {
            seed(h, "Song", "Artist", "Album")
            compare(h.item.avail, true)
            var node = textContaining(h, "No track loaded")
            verify(node !== null, "placeholder node still exists")
            verify(!effVisible(node), "placeholder hides once a track is available")
        }
        function test_no_stale_title_after_clear() {
            seed(h, "Old Song", "Old Artist", "Old Album")
            compare(h.item.avail, true)
            h.mediaCtl.clearTrack()
            compare(h.item.avail, false)
            verify(textContaining(h, "Old Song") === null, "no stale title retained after clear")
            verify(textContaining(h, "Old Album") === null, "no stale album retained after clear")
        }
    }

    // ── album art fallback glyph ─────────────────────────────────────────────
    TestCase {
        name: "MediaArt"
        when: windowShown
        function init() {
            tryVerify(function () { return h.ready }, 3000)
            h.item.accentName = "green"
            h.mediaCtl.clearTrack()
        }

        function test_glyph_fallback_when_no_art() {
            seed(h, "Song", "Artist", "Album")
            h.mediaCtl.artUrl = ""
            // Two ♪ glyphs exist (compact + expanded); the compact one is hidden
            // in expanded mode, so require an EFFECTIVELY-visible fallback.
            var all = findAll(h.item, isText, [])
            var shown = false
            for (var i = 0; i < all.length; i++)
                if (all[i].text.indexOf("♪") >= 0 && effVisible(all[i])) shown = true
            verify(shown, "album-art ♪ fallback visible when the art image is not Ready")
        }
        function test_art_image_source_tracks_arturl() {
            // A local art source may be rendered directly. Remote URLs must not be
            // assigned to QML Image because that would bypass the shared NetHub
            // offline and host-allowlist policy.
            seed(h, "Song", "Artist", "Album")
            var url = "qrc:/icons/media.svg"
            h.mediaCtl.artUrl = url
            var imgs = findAll(h.item, isImage, [])
            var art = null
            for (var i = 0; i < imgs.length; i++)
                if (String(imgs[i].source) === url) art = imgs[i]
            verify(art !== null, "album-art Image source tracks a local media.artUrl")
            // Its ♪ sibling is gated on status (not shown when the image is Ready).
            var sib = art.parent
            verify(sib !== null && sib.hasOwnProperty("radius"), "art sits in the art tile")
        }
        function test_remote_art_never_bypasses_network_gate() {
            seed(h, "Song", "Artist", "Album")
            var remote = "https://example.com/cover-abc.png"
            h.mediaCtl.artUrl = remote
            compare(h.item.artworkSource, "",
                    "remote artwork is withheld from the raw QML Image loader")
            compare(h.item.remoteArtworkBlocked, true,
                    "the widget exposes the blocked-art state")
            var imgs = findAll(h.item, isImage, [])
            for (var i = 0; i < imgs.length; i++)
                verify(String(imgs[i].source) !== remote,
                       "no album-art Image receives the remote URL")
        }
    }

    // ── header status ────────────────────────────────────────────────────────
    // NOTE: the C++ bridge exposes the raw D-Bus service suffix as playerName
    // (a real medium bug) - not reproducible via MockMedia, which supplies a
    // friendly name. Here we pin the avail-gating of the header status.
    TestCase {
        name: "MediaHeaderStatus"
        when: windowShown
        function init() {
            tryVerify(function () { return h.ready }, 3000)
            h.mediaCtl.clearTrack()
        }
        function test_status_empty_when_unavailable() {
            compare(h.item.status, "No track loaded",
                    "the header distinguishes an idle player from a disconnected bus")
        }
        function test_status_shows_player_when_available() {
            seed(h, "Song", "Artist", "Album")
            compare(h.item.status, "MockPlayer · Playing",
                    "the header shows both the player and playback state")
        }
    }

    // ── real mouse clicks: compact play/pause ────────────────────────────────
    TestCase {
        name: "MediaCompactClick"
        when: windowShown
        function init() {
            tryVerify(function () { return hC.ready }, 3000)
            // Inject sizeClass the way Dashboard does for a 0.5x0.5 tile. Without
            // it WidgetChrome falls back to its geometric default (height > 240 →
            // "tall"), which for a half-cell is simply the wrong class: the widget
            // then renders the header + full transport of a tall tile into a
            // 306px box, and the overflow is clipped by the chrome body - so the
            // click landed on nothing.
            hC.item.sizeClass = "compact"
            hC.mediaCtl.clearTrack()
        }
        function test_compact_playpause_fires_once() {
            seed(hC, "Song", "Artist", "Album")
            wait(32)
            var tps = transport(hC)
            verify(tps.length >= 1, "found the compact play/pause target (" + tps.length + ")")
            var before = hC.mediaCtl.playPauseCount
            mouseClick(tps[0])
            compare(hC.mediaCtl.playPauseCount, before + 1, "compact play/pause fired exactly once")
        }
        function test_compact_target_is_touch_sized() {
            seed(hC, "Song", "Artist", "Album")
            wait(32)
            var tps = transport(hC)
            verify(tps.length >= 1)
            var btn = tps[0].parent
            verify(btn.width >= 44 && btn.height >= 44,
                   "compact play/pause is a >=44px touch target (" + btn.width + "x" + btn.height + ")")
        }
    }

    // ── real mouse clicks: expanded prev / play / next ───────────────────────
    TestCase {
        name: "MediaExpandedClicks"
        when: windowShown
        function init() {
            tryVerify(function () { return h.ready }, 3000)
            h.item.accentName = "green"
            h.mediaCtl.clearTrack()
        }

        function transportSorted() {
            var tps = transport(h)
            // Expect prev(60) / play(76) / next(60); sort left-to-right.
            tps.sort(function (a, b) { return globalX(a) - globalX(b) })
            return tps
        }

        function test_three_transport_buttons_present() {
            seed(h, "Song", "Artist", "Album")
            wait(32)
            var tps = transportSorted()
            compare(tps.length, 3, "prev / play / next are all present and visible")
        }
        function test_prev_play_next_fire_independently() {
            seed(h, "Song", "Artist", "Album")
            wait(32)
            var tps = transportSorted()
            verify(tps.length === 3, "need three transport controls")
            var prevBtn = tps[0], playBtn = tps[1], nextBtn = tps[2]

            var p0 = h.mediaCtl.previousCount, pp0 = h.mediaCtl.playPauseCount, n0 = h.mediaCtl.nextCount
            mouseClick(prevBtn)
            compare(h.mediaCtl.previousCount, p0 + 1, "prev fired previous()")
            compare(h.mediaCtl.playPauseCount, pp0, "prev did not fire play/pause")
            compare(h.mediaCtl.nextCount, n0, "prev did not fire next")

            mouseClick(playBtn)
            compare(h.mediaCtl.playPauseCount, pp0 + 1, "middle button fired play/pause")
            compare(h.mediaCtl.previousCount, p0 + 1, "play did not fire prev again")

            mouseClick(nextBtn)
            compare(h.mediaCtl.nextCount, n0 + 1, "next fired next()")
            compare(h.mediaCtl.playPauseCount, pp0 + 1, "next did not fire play/pause")
        }
        function test_expanded_transport_are_touch_sized() {
            seed(h, "Song", "Artist", "Album")
            wait(32)
            var tps = transportSorted()
            for (var i = 0; i < tps.length; i++) {
                var b = tps[i].parent
                verify(b.width >= 44 && b.height >= 44,
                       "transport button " + i + " is >=44px (" + b.width + "x" + b.height + ")")
            }
        }
    }

    // ── shared config-schema area ────────────────────────────────────────────
    TestCase {
        name: "MediaSchema"
        when: windowShown

        function test_media_schema_has_title_and_appearance() {
            var s = sc.schemaFor("media")
            verify(s && s.sections && s.sections.length > 0, "media has a schema")
            var keys = {}
            for (var i = 0; i < s.sections.length; i++)
                for (var j = 0; j < (s.sections[i].fields || []).length; j++)
                    if (s.sections[i].fields[j].key) keys[s.sections[i].fields[j].key] = true
            verify(keys["title"] === true, "schema exposes a custom title")
            verify(keys["accent"] === true, "schema exposes a per-widget accent")
            verify(keys["cardBackdrop"] === true, "schema exposes a per-widget card backdrop")
            verify(keys["preferredPlayer"] === true, "schema exposes preferred player selection")
        }
        function test_accent_default_is_empty() {
            var s = sc.schemaFor("media")
            var f = null
            for (var i = 0; i < s.sections.length; i++)
                for (var j = 0; j < (s.sections[i].fields || []).length; j++)
                    if (s.sections[i].fields[j].key === "accent") f = s.sections[i].fields[j]
            verify(f !== null, "accent field present")
            compare(f.dflt, "", "default accent is empty (this triggers the effAccent loop)")
        }
    }

    // ── Per-sizeClass structure (W1 wave 3) ──────────────────────────────────
    // Dashboard injects sizeClass; the widget must key layout off it. The old
    // tile was one 46px-thumbnail row at EVERY size.
    TestCase {
        name: "MediaSizes"
        when: windowShown

        function initTestCase() { tryVerify(function () { return hS.ready }, 3000) }
        function init() {
            hS.theme.textScale = 1.15
            hS.theme.fontChoice = "system"
            hS.mediaCtl.busConnected = true
        }
        function cleanup() {
            hS.theme.textScale = 1.15
            hS.theme.fontChoice = "system"
            hS.mediaCtl.busConnected = true
        }

        function shape(width, height, cls, title, artist) {
            sizeWrap.width = width; sizeWrap.height = height
            hS.item.sizeClass = cls
            hS.mediaCtl.busConnected = true
            hS.mediaCtl.loadTrack(
                title === undefined ? "Everything In Its Right Place" : title,
                artist === undefined ? "Radiohead" : artist)
            wait(32)
            return hS.item
        }
        function named(item, objectName) {
            return findByProp(item, "objectName", objectName)
        }
        function verifyReadableText(item, node, label) {
            verify(node !== null, label + " exists")
            verify(effVisible(node), label + " is visible")
            verify(node.font.pixelSize >= hS.theme.fontMinimum,
                   label + " uses " + node.font.pixelSize + "px, floor is "
                   + hS.theme.fontMinimum + "px")
            verify(node.truncated !== true, label + " is not truncated")
            verify(node.contentHeight <= node.height + 1,
                   label + " content height fits its allocation")
            var topLeft = item.mapFromItem(node, 0, 0)
            var bottomRight = item.mapFromItem(node, node.width, node.height)
            verify(topLeft.x >= -1 && topLeft.y >= -1
                   && bottomRight.x <= item.width + 1
                   && bottomRight.y <= item.height + 1,
                   label + " remains inside " + item.width + "x" + item.height)
        }
        function projectionCases() {
            return [
                [348, 409, "compact", "portrait 0.5x0.5"],
                [423, 306, "compact", "landscape 0.5x0.5"],
                [348, 818, "tall", "portrait 0.5x1"],
                [846, 306, "wide", "landscape 0.5x1"],
                [696, 409, "wide", "portrait 1x0.5"],
                [423, 612, "tall", "landscape 1x0.5"],
                [696, 818, "compact", "portrait 1x1"],
                [846, 612, "compact", "landscape 1x1"],
                [696, 1227, "tall", "portrait 1x1.5"],
                [1269, 612, "wide", "landscape 1x1.5"]
            ]
        }
        // Every visible circular transport button (a Rectangle holding one MouseArea).
        function transport(item) {
            var mas = findAll(item, function (n) { return isMouseArea(n) && effVisible(n) }, [])
            var out = []
            for (var i = 0; i < mas.length; i++) {
                var p = mas[i].parent
                if (p && p.width > 0 && effVisible(p)) out.push(p)
            }
            return out
        }
        function art(item) {
            // The art tile: a clipped Rectangle with a gradient, holding an Image.
            var rs = findAll(item, function (n) {
                return isRect(n) && n.clip && effVisible(n) && n.width > 20
                       && findAll(n, function (c) { return isImage(c) }, []).length > 0
            }, [])
            return rs.length ? rs[0] : null
        }

        // The whole point of going wide: art BESIDE the metadata. The vertical
        // stack is ~420px of content and 0.5x1 landscape is 306px tall.
        function test_wide_puts_art_beside_the_metadata_in_both_projections() {
            var cases = [[696, 409], [846, 306]]   // 1x0.5 portrait · 0.5x1 landscape
            for (var i = 0; i < cases.length; i++) {
                var w = shape(cases[i][0], cases[i][1], "wide")
                compare(w.horiz, true, cases[i][0] + "x" + cases[i][1] + " is the horizontal variant")
                var a = art(w)
                var btns = transport(w)
                verify(a !== null, "art is rendered")
                verify(btns.length >= 3, "wide keeps the full transport (" + btns.length + ")")
                // Beside: the transport starts to the RIGHT of the art, not below.
                var artRight = w.mapFromItem(a, a.width, 0).x
                var artBottom = w.mapFromItem(a, 0, a.height).y
                var bx = w.mapFromItem(btns[0], 0, 0).x
                verify(bx >= artRight - 1,
                       "transport sits right of the art (art ends " + artRight + ", controls " + bx + ")")
                // And the whole stack fits the box - the audit's actual failure.
                verify(artBottom <= w.height,
                       "art fits inside the " + cases[i][1] + "px box (ends " + artBottom + ")")
            }
        }

        // Art is derived from the BOX, not a flat min(width*0.5, 260) cap.
        function test_art_is_size_derived() {
            var base = shape(696, 819, "compact")
            var aBase = art(base).width
            var tall = shape(696, 1228, "tall")
            var aTall = art(tall).width
            var micro = shape(423, 306, "compact")
            var aMicro = art(micro).width
            verify(aTall > aBase, "a taller box earns bigger art (" + aBase + " → " + aTall + ")")
            verify(aMicro < aBase, "the half-cell shrinks it (" + aMicro + ")")
            // The old cap: 696*0.5 = 348, capped to 260 - identical for both.
            verify(aTall > 260, "the tall tile is no longer pinned at the old 260px cap")
        }

        // 0.5x0.5 - art, title, ONE play target. No shrunken hit areas.
        function test_micro_keeps_one_full_size_play_target_only() {
            var w = shape(423, 306, "compact")
            compare(w.micro, true, "a 423x306 compact box is the half-cell")
            compare(w.showHeader, false, "micro drops the header")
            compare(w.rich, false, "micro carries the readout, not the full transport")
            compare(w.sideBySide, true,
                    "the short landscape micro tile places metadata beside the art")
            var btns = transport(w)
            compare(btns.length, 1, "exactly one control survives - play")
            verify(btns[0].height >= hS.theme.touchTertiary,
                   "and it is a REAL hit area (" + btns[0].height + "px), not a shrunken one")
            // Everything stays inside the 306px box.
            var b = w.mapFromItem(btns[0], 0, btns[0].height).y
            verify(b <= w.height, "the play target fits the box (ends " + b + ")")
        }

        // 1x1 - the baseline earns the full transport + progress, and type that
        // is not 13px dust in a 696x819 box.
        function test_baseline_earns_transport_progress_and_real_type() {
            var w = shape(696, 819, "compact")
            compare(w.micro, false, "696x819 is the baseline third")
            compare(w.rich, true)
            compare(w.horiz, false, "stacked")
            verify(transport(w).length >= 3, "prev/play/next")
            verify(w.titlePx > 13, "the title scales with the box (" + w.titlePx + "px), it is not the old 13px")
            var t = findByProp(w.item ? w.item : w, "text", "Everything In Its Right Place")
            verify(t !== null, "the track title is rendered")
        }

        function test_long_metadata_is_readable_in_all_supported_projections_and_scales() {
            var cases = projectionCases()
            var scales = [1.0, 1.15, 1.3, 1.45]
            var outputScales = [1.0, 1.25]
            var fullTitle = "A Carefully Produced Release for Every Linux Desktop"
            var fullArtist = "The EdgeHub Community Ensemble"

            for (var c = 0; c < cases.length; c++) {
                for (var o = 0; o < outputScales.length; o++) {
                    for (var s = 0; s < scales.length; s++) {
                        hS.theme.textScale = scales[s]
                        var outputScale = outputScales[o]
                        var width = Math.round(cases[c][0] / outputScale)
                        var height = Math.round(cases[c][1] / outputScale)
                        var tag = cases[c][3] + ", output " + outputScale
                                  + ", text " + scales[s]
                        var w = shape(width, height, cases[c][2],
                                      fullTitle, fullArtist)
                        var titleNode = named(w, "mediaTrackTitle")
                        verifyReadableText(w, titleNode, tag + " title")
                        compare(titleNode.text, fullTitle,
                                tag + " retains the complete visual title")

                        if (w.rich) {
                            var artistNode = named(w, "mediaTrackArtist")
                            verifyReadableText(w, artistNode, tag + " artist")
                            compare(artistNode.text, fullArtist,
                                    tag + " retains the complete visual artist")
                            verifyReadableText(w, named(w, "mediaElapsed"),
                                               tag + " elapsed time")
                            verifyReadableText(w, named(w, "mediaDuration"),
                                               tag + " duration")
                        }

                        var header = findByProp(w, "text", "Now Playing")
                        if (w.showHeader)
                            verifyReadableText(w, header, tag + " header")
                        if (w.showHeaderStatus) {
                            var statusNode = findByProp(w, "text",
                                                       "MockPlayer · Playing")
                            verifyReadableText(w, statusNode, tag + " status")
                        } else {
                            compare(w.status, "",
                                    tag + " removes redundant narrow header status")
                        }

                        verify(w.accessibleTrackSummary.indexOf(fullTitle) >= 0,
                               tag + " accessible summary retains the title")
                        verify(w.accessibleTrackSummary.indexOf(fullArtist) >= 0,
                               tag + " accessible summary retains the artist")
                        verify(w.accessibleTrackSummary.indexOf("MockPlayer · Playing") >= 0,
                               tag + " accessible summary retains player state")
                    }
                }
            }
        }

        function test_disconnected_state_is_readable_at_every_projection_and_scale() {
            var cases = projectionCases()
            var scales = [1.0, 1.15, 1.3, 1.45]
            for (var c = 0; c < cases.length; c++) {
                for (var s = 0; s < scales.length; s++) {
                    hS.theme.textScale = scales[s]
                    sizeWrap.width = Math.round(cases[c][0] / 1.25)
                    sizeWrap.height = Math.round(cases[c][1] / 1.25)
                    hS.item.sizeClass = cases[c][2]
                    hS.mediaCtl.clearTrack()
                    hS.mediaCtl.busConnected = false
                    wait(32)
                    var tag = cases[c][3] + ", output 1.25, text " + scales[s]
                    var emptyNode = named(hS.item, "mediaEmptyState")
                    verifyReadableText(hS.item, emptyNode,
                                       tag + " disconnected message")
                    compare(emptyNode.text, "Media service disconnected",
                            tag + " keeps the full recovery state")
                    verify(hS.item.accessibleTrackSummary.indexOf(
                               "Media service disconnected") >= 0,
                           tag + " exposes the recovery state accessibly")
                }
            }
        }

        // Tile controls stay real touch targets at every declared size.
        function test_every_declared_size_keeps_touch_sized_controls() {
            var cases = [
                [348, 409, "compact"], [423, 306, "compact"],     // 0.5x0.5
                [348, 819, "tall"],    [846, 306, "wide"],        // 0.5x1
                [696, 409, "wide"],    [423, 612, "tall"],        // 1x0.5
                [696, 819, "compact"], [846, 612, "compact"],     // 1x1
                [696, 1228, "tall"],   [1269, 612, "wide"]        // 1x1.5
            ]
            for (var i = 0; i < cases.length; i++) {
                var w = shape(cases[i][0], cases[i][1], cases[i][2])
                var tag = cases[i][0] + "x" + cases[i][1] + " (" + cases[i][2] + ")"
                var btns = transport(w)
                verify(btns.length >= 1, tag + " has a control")
                for (var j = 0; j < btns.length; j++)
                    verify(btns[j].height >= hS.theme.touchTertiary,
                           tag + ": control " + j + " is " + btns[j].height
                           + "px >= " + hS.theme.touchTertiary)
            }
        }
    }
}
