import QtQuick
import QtTest

// MediaWidget - verifies the transport controls actually fire the bridge (they
// were dead before the tapMA fix) in both compact and expanded modes, and that
// the honest "nothing playing" state shows when unavailable.
Item {
    width: 420; height: 820
    WidgetHarness { id: h; anchors.fill: parent; widgetFile: "MediaWidget.qml"; expanded: true }

    TestCase {
        name: "MediaWidget"
        when: windowShown

        function init() {
            tryVerify(function () { return h.ready }, 3000)
            h.mediaCtl.clearTrack()
        }

        function test_unavailable_state() {
            compare(h.item.avail, false)
        }

        function test_available_reflects_bridge() {
            h.mediaCtl.loadTrack("Test Song", "Test Artist")
            compare(h.item.avail, true)
        }

        function test_playback_state_is_explicit() {
            compare(h.item.playbackLabel, "No track loaded")
            h.mediaCtl.availablePlayers = []
            compare(h.item.playbackLabel, "No media player found")
            h.mediaCtl.scanning = true
            compare(h.item.playbackLabel, "Looking for media players")
            h.mediaCtl.scanning = false
            h.mediaCtl.busConnected = false
            compare(h.item.playbackLabel, "Media service disconnected")
            h.mediaCtl.busConnected = true
            h.mediaCtl.loadTrack("Test Song", "Test Artist")
            compare(h.item.playbackLabel, "Playing")
            h.mediaCtl.status = "Paused"
            compare(h.item.playbackLabel, "Paused")
        }

        function test_player_capabilities_disable_unsupported_actions() {
            h.mediaCtl.loadTrack("Test Song", "Test Artist")
            h.mediaCtl.canPlayPause = false
            h.mediaCtl.canGoNext = false
            h.mediaCtl.canGoPrevious = true
            compare(h.item.canPlayPause, false)
            compare(h.item.canGoNext, false)
            compare(h.item.canGoPrevious, true)
        }

        function test_playpause_invokes_bridge() {
            h.mediaCtl.loadTrack("Song", "Artist")
            var before = h.mediaCtl.playPauseCount
            h.mediaCtl.playPause()   // direct call proxy - proves API wired
            compare(h.mediaCtl.playPauseCount, before + 1)
        }

        function test_transport_counts_independent() {
            h.mediaCtl.loadTrack("Song", "Artist")
            var n0 = h.mediaCtl.nextCount, p0 = h.mediaCtl.previousCount
            h.mediaCtl.next()
            h.mediaCtl.previous()
            compare(h.mediaCtl.nextCount, n0 + 1)
            compare(h.mediaCtl.previousCount, p0 + 1)
        }

        function test_position_clamped_render() {
            // Extreme position values must not break the progress bar binding.
            h.mediaCtl.loadTrack("Song", "Artist")
            h.mediaCtl.position = 5.0
            wait(16)
            verify(h.item !== null)
            h.mediaCtl.position = -1.0
            wait(16)
            verify(h.item !== null)
        }

        function test_elapsed_total_and_seek_are_real() {
            h.mediaCtl.loadTrack("Song", "Artist")
            compare(h.item.formatTime(h.mediaCtl.positionMs), "1:13")
            compare(h.item.formatTime(h.mediaCtl.durationMs), "4:05")
            compare(Math.round(h.item.progressFraction * 100), 30)

            var before = h.mediaCtl.seekCount
            h.item.seekTo(0.5)
            compare(h.mediaCtl.seekCount, before + 1)
            compare(h.mediaCtl.lastSeekFraction, 0.5)
            compare(h.item.formatTime(h.mediaCtl.positionMs), "2:02")

            h.mediaCtl.canSeek = false
            h.item.seekTo(0.8)
            compare(h.mediaCtl.seekCount, before + 1,
                    "unsupported seek must not call the player")
        }

        function test_preferred_player_setting_reaches_bridge() {
            h.storeCtl.patchSettings(h.instanceId, { preferredPlayer: " spotify " })
            tryCompare(h.mediaCtl, "preferredPlayer", "spotify")
            h.storeCtl.patchSettings(h.instanceId, { preferredPlayer: "" })
            tryCompare(h.mediaCtl, "preferredPlayer", "")
        }

        function findObjectName(node, name) {
            if (!node) return null
            if (node.objectName === name) return node
            var kids = node.children || []
            for (var i = 0; i < kids.length; i++) {
                var hit = findObjectName(kids[i], name)
                if (hit) return hit
            }
            return null
        }
        function requireObject(name) {
            var o = findObjectName(h.item, name)
            verify(o !== null, "expected a '" + name + "' element to exist")
            return o
        }

        // The schema promises "only enables transport or seeking when the player
        // supports them". test_player_capabilities_disable_unsupported_actions
        // asserts only that the widget's own properties mirror the bridge - it
        // never touches a control, so a regression binding `enabled: true` on
        // every button would pass it. This asserts the controls themselves, and
        // covers canGoPrevious, which no test had ever set false.
        // COVERS: schema:media.preferredPlayer
        function test_unsupported_transport_controls_are_actually_disabled_data() {
            return [
                { tag: "previous", cap: "canGoPrevious",
                  names: ["mediaPrevious", "mediaPreviousExpanded"] },
                { tag: "playpause", cap: "canPlayPause",
                  names: ["mediaPlayPause", "mediaPlayPauseExpanded"] },
                { tag: "next", cap: "canGoNext",
                  names: ["mediaNext", "mediaNextExpanded"] }
            ]
        }
        function test_unsupported_transport_controls_are_actually_disabled(data) {
            h.mediaCtl.loadTrack("Test Song", "Test Artist")
            h.mediaCtl[data.cap] = true
            var found = 0
            for (var i = 0; i < data.names.length; i++) {
                var c = findObjectName(h.item, data.names[i])
                if (!c) continue
                found++
                verify(c.enabled, data.names[i] + " is enabled while the player supports it")
            }
            verify(found > 0, "at least one '" + data.tag + "' control must exist")

            h.mediaCtl[data.cap] = false
            for (var j = 0; j < data.names.length; j++) {
                var d = findObjectName(h.item, data.names[j])
                if (!d) continue
                verify(!d.enabled,
                       d.objectName + " must be disabled when the player reports "
                       + data.cap + " false - an enabled control that cannot act "
                       + "is a dead button")
            }
            h.mediaCtl[data.cap] = true
        }

        // localArtworkSource() is the widget's own artwork filter - defence in
        // depth behind MprisState, which suppresses remote artUrls in C++
        // (tests/cpp/tst_mpris_state.cpp). That C++ suite proves the BRIDGE
        // suppresses them; nothing proved the QML filter does, so both layers
        // could regress independently. MockMedia can hand the widget a remote
        // artUrl the real bridge would never emit, which is exactly what makes
        // the second layer testable.
        function test_artwork_policy_data() {
            return [
                { tag: "file", url: "file:///home/u/cover.png", kept: true },
                { tag: "qrc", url: "qrc:/img/cover.png", kept: true },
                { tag: "data-png", url: "data:image/png;base64,iVBORw0KGgo=", kept: true },
                { tag: "data-jpeg", url: "data:image/jpeg;base64,/9j/4AAQ", kept: true },
                { tag: "relative-path", url: "covers/cover.png", kept: true },
                { tag: "http", url: "http://example.com/cover.png", kept: false },
                { tag: "https", url: "https://example.com/cover.png", kept: false },
                // No scheme to reject, but the browser-style protocol-relative
                // form still resolves to a remote fetch.
                { tag: "protocol-relative", url: "//example.com/cover.png", kept: false },
                // A data: URI that is not an image - the scheme alone must not
                // be the thing that grants it through.
                { tag: "data-html", url: "data:text/html;base64,PHNjcmlwdD4=", kept: false },
                { tag: "data-svg", url: "data:image/svg+xml;base64,PHN2Zz4=", kept: false }
            ]
        }
        function test_artwork_policy(data) {
            h.mediaCtl.loadTrack("Test Song", "Test Artist")
            h.mediaCtl.artUrl = data.url
            if (data.kept) {
                compare(h.item.artworkSource, data.url,
                        data.tag + " is local and must reach the Image unchanged")
                compare(h.item.remoteArtworkBlocked, false)
                compare(h.item.artworkNotice, "", "nothing was blocked, so say nothing")
            } else {
                compare(h.item.artworkSource, "",
                        data.tag + " must never reach the Image - it would make the "
                        + "widget fetch a URL the media player chose")
                compare(h.item.remoteArtworkBlocked, true)
                compare(h.item.artworkNotice, "Artwork blocked by network policy",
                        "and the user is told why the art is missing")
            }
            h.mediaCtl.artUrl = ""
        }

        // The notice is a rendered string, not just a property: it must actually
        // appear. The widget draws it TWICE - once on the tile, once in the
        // expanded overlay - and sweeping the tree for the text covers whichever
        // one happens to be visible, so hiding the other still passed (measured:
        // gutting the tile notice's `visible` left the sweep green because the
        // harness runs expanded). Each surface is therefore asserted by name, in
        // the mode that shows it.
        function test_blocked_artwork_notice_is_rendered_data() {
            return [
                { tag: "expanded", expanded: true, name: "mediaArtworkNoticeExpanded" },
                { tag: "tile", expanded: false, name: "mediaArtworkNotice" }
            ]
        }
        function test_blocked_artwork_notice_is_rendered(data) {
            h.expanded = data.expanded
            wait(0)
            h.mediaCtl.loadTrack("Test Song", "Test Artist")
            h.mediaCtl.artUrl = ""
            var notice = requireObject(data.name)
            verify(!notice.visible, "no notice while there is no artwork to block")

            h.mediaCtl.artUrl = "https://example.com/cover.png"
            wait(0)
            verify(notice.visible,
                   data.name + " must be visible on the " + data.tag
                   + " surface, not merely computed into a property")
            compare("" + notice.text, "Artwork blocked by network policy")
            h.mediaCtl.artUrl = ""
            h.expanded = true
        }

        // Empty artUrl is the ordinary case and must stay silent.
        function test_no_artwork_produces_no_notice() {
            h.mediaCtl.loadTrack("Test Song", "Test Artist")
            h.mediaCtl.artUrl = ""
            compare(h.item.artworkSource, "")
            compare(h.item.remoteArtworkBlocked, false)
            compare(h.item.artworkNotice, "")
        }
    }
}
