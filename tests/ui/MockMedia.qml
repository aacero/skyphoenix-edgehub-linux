import QtQuick

// MockMedia - stands in for the C++ MprisBridge (`media` context property) so
// MediaWidget can be tested without a real MPRIS player on the session bus.
// Mirrors the bridge's Q_PROPERTY / Q_INVOKABLE surface.
QtObject {
    id: m
    property bool available: false
    property string title: ""
    property string artist: ""
    property string album: ""
    property string artUrl: ""
    property string status: "Stopped"          // Playing/Paused/Stopped
    property bool playing: status === "Playing"
    property string playerName: ""
    property real position: 0.0                 // 0..1
    property real positionMs: 0
    property real durationMs: 0
    property bool canPlayPause: true
    property bool canGoNext: true
    property bool canGoPrevious: true
    property bool canSeek: true
    property bool busConnected: true
    property bool scanning: false
    property var availablePlayers: ["MockPlayer", "SecondPlayer"]
    property string preferredPlayer: ""

    // Call log so tests can assert transport actions fired.
    property int playPauseCount: 0
    property int nextCount: 0
    property int previousCount: 0
    property int seekCount: 0
    property real lastSeekFraction: -1

    function playPause() { playPauseCount++; status = playing ? "Paused" : "Playing" }
    function next() { nextCount++ }
    function previous() { previousCount++ }
    function seekFraction(fraction) {
        seekCount++
        lastSeekFraction = Math.max(0, Math.min(1, Number(fraction)))
        position = lastSeekFraction
        positionMs = durationMs * lastSeekFraction
    }
    function setPreferredPlayer(player) { preferredPlayer = String(player || "").trim() }

    // Test convenience: populate a fake now-playing track.
    function loadTrack(t, a) {
        title = t; artist = a; album = "Test Album"; playerName = "MockPlayer"
        status = "Playing"; position = 0.3; durationMs = 245000
        positionMs = 73500; available = true
    }
    function clearTrack() {
        available = false; title = ""; artist = ""; album = ""; artUrl = ""
        status = "Stopped"; position = 0; positionMs = 0; durationMs = 0
        canPlayPause = true; canGoNext = true; canGoPrevious = true; canSeek = true
        busConnected = true; scanning = false; availablePlayers = ["MockPlayer", "SecondPlayer"]
        preferredPlayer = ""; lastSeekFraction = -1
    }
}
