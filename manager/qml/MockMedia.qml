import QtQuick

// MockMedia - stands in for the hub's MprisBridge inside the Manager clone, so
// MediaWidget renders. The Manager isn't a media controller; this just shows a
// representative playing state in layout previews. It never controls the
// Manager host, and live Hub data remains owned by the Hub process.
QtObject {
    property bool available: true
    property string title: "Midnight Drive"
    property string artist: "Local Player"
    property string album: "EdgeHub Preview"
    property string artUrl: ""
    property string status: "Playing"
    property bool playing: true
    property string playerName: "Preview"
    property real position: 0.37
    property real positionMs: 91000
    property real durationMs: 246000
    property bool canPlayPause: true
    property bool canGoNext: true
    property bool canGoPrevious: true
    property bool canSeek: true
    property bool busConnected: true
    property bool scanning: false
    property var availablePlayers: ["Preview"]
    property string preferredPlayer: ""
    function playPause() {}
    function next() {}
    function previous() {}
    function seekFraction(fraction) {}
    function setPreferredPlayer(player) { preferredPlayer = String(player || "").trim() }
}
