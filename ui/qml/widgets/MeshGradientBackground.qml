import QtQuick
import QtQuick.Shapes

// MeshGradientBackground - a modern "mesh gradient" wash: a few very large, very
// soft, overlapping colour blobs that cover the whole screen so their colours
// blend edge-to-edge, each drifting slowly to new positions on long InOutSine
// loops. GPU-rendered (QtQuick.Shapes RadialGradient), so no per-frame repaint.
// When `active` is false the blobs stay painted but stop drifting - matching the
// static-canvas behaviour of the waves/stars backdrops.
Item {
    id: root
    property bool active: true
    // Primary tint (S7). Defaults to theme.accent; overridable via BackdropLayer.
    property color accent: theme.accent
    clip: true

    // A very soft, very large radial colour blob.
    component Blob: Shape {
        id: blob
        property color tint: "#ffffff"
        property real diameter: 900
        property real strength: 0.5
        width: diameter; height: diameter
        antialiasing: true
        // Stays painted even when inactive; only the drift animations gate on `active`.
        ShapePath {
            // Same trap as AnimatedBackground: ShapePath's strokeColor defaults
            // to WHITE and Qt < 6.9 rasterises a hairline even at zero width,
            // so each blob gains a hard ring. Name the stroke transparent.
            strokeColor: "transparent"
            strokeWidth: 0
            fillGradient: RadialGradient {
                centerX: blob.diameter / 2; centerY: blob.diameter / 2
                centerRadius: blob.diameter / 2
                focalX: blob.diameter / 2; focalY: blob.diameter / 2
                GradientStop { position: 0.0; color: Qt.rgba(blob.tint.r, blob.tint.g, blob.tint.b, blob.strength) }
                GradientStop { position: 0.55; color: Qt.rgba(blob.tint.r, blob.tint.g, blob.tint.b, blob.strength * 0.4) }
                GradientStop { position: 1.0; color: Qt.rgba(blob.tint.r, blob.tint.g, blob.tint.b, 0.0) }
            }
            startX: blob.diameter; startY: blob.diameter / 2
            PathArc { x: 0; y: blob.diameter / 2; radiusX: blob.diameter / 2; radiusY: blob.diameter / 2
                useLargeArc: true; direction: PathArc.Clockwise }
            PathArc { x: blob.diameter; y: blob.diameter / 2; radiusX: blob.diameter / 2; radiusY: blob.diameter / 2
                useLargeArc: true; direction: PathArc.Clockwise }
        }
    }

    Blob {
        id: b1
        tint: root.accent; diameter: root.width * 1.2; strength: 0.55
        SequentialAnimation on x {
            running: root.active; loops: Animation.Infinite
            NumberAnimation { to: -b1.diameter * 0.4; duration: 22000; easing.type: Easing.InOutSine }
            NumberAnimation { to: root.width - b1.diameter * 0.45; duration: 26000; easing.type: Easing.InOutSine }
        }
        SequentialAnimation on y {
            running: root.active; loops: Animation.Infinite
            NumberAnimation { to: -b1.diameter * 0.2; duration: 24000; easing.type: Easing.InOutSine }
            NumberAnimation { to: root.height * 0.2; duration: 30000; easing.type: Easing.InOutSine }
        }
    }

    Blob {
        id: b2
        tint: theme.accent2; diameter: root.width * 1.15; strength: 0.55
        x: root.width - diameter * 0.4
        y: root.height * 0.25
        SequentialAnimation on x {
            running: root.active; loops: Animation.Infinite
            NumberAnimation { to: root.width - b2.diameter * 0.35; duration: 27000; easing.type: Easing.InOutSine }
            NumberAnimation { to: root.width * 0.1 - b2.diameter * 0.4; duration: 21000; easing.type: Easing.InOutSine }
        }
        SequentialAnimation on y {
            running: root.active; loops: Animation.Infinite
            NumberAnimation { to: root.height * 0.45; duration: 25000; easing.type: Easing.InOutSine }
            NumberAnimation { to: root.height * 0.05; duration: 29000; easing.type: Easing.InOutSine }
        }
    }

    Blob {
        id: b3
        tint: theme.catEntertainment; diameter: root.width * 1.25; strength: 0.55
        y: root.height * 0.5
        SequentialAnimation on x {
            running: root.active; loops: Animation.Infinite
            NumberAnimation { to: root.width * 0.5 - b3.diameter * 0.5; duration: 28000; easing.type: Easing.InOutSine }
            NumberAnimation { to: -b3.diameter * 0.35; duration: 23000; easing.type: Easing.InOutSine }
        }
        SequentialAnimation on y {
            running: root.active; loops: Animation.Infinite
            NumberAnimation { to: root.height * 0.7; duration: 26000; easing.type: Easing.InOutSine }
            NumberAnimation { to: root.height * 0.4; duration: 30000; easing.type: Easing.InOutSine }
        }
    }

    Blob {
        id: b4
        tint: theme.catServices; diameter: root.width * 1.15; strength: 0.55
        x: root.width * 0.2
        y: root.height * 0.75
        SequentialAnimation on x {
            running: root.active; loops: Animation.Infinite
            NumberAnimation { to: root.width - b4.diameter * 0.5; duration: 24000; easing.type: Easing.InOutSine }
            NumberAnimation { to: -b4.diameter * 0.25; duration: 29000; easing.type: Easing.InOutSine }
        }
        SequentialAnimation on y {
            running: root.active; loops: Animation.Infinite
            NumberAnimation { to: root.height - b4.diameter * 0.5; duration: 27000; easing.type: Easing.InOutSine }
            NumberAnimation { to: root.height * 0.6; duration: 22000; easing.type: Easing.InOutSine }
        }
    }

    Blob {
        id: b5
        tint: root.accent; diameter: root.width * 1.1; strength: 0.5
        x: root.width * 0.4
        y: root.height * 0.95
        SequentialAnimation on x {
            running: root.active; loops: Animation.Infinite
            NumberAnimation { to: -b5.diameter * 0.3; duration: 30000; easing.type: Easing.InOutSine }
            NumberAnimation { to: root.width - b5.diameter * 0.4; duration: 25000; easing.type: Easing.InOutSine }
        }
        SequentialAnimation on y {
            running: root.active; loops: Animation.Infinite
            NumberAnimation { to: root.height - b5.diameter * 0.35; duration: 28000; easing.type: Easing.InOutSine }
            NumberAnimation { to: root.height * 0.8; duration: 20000; easing.type: Easing.InOutSine }
        }
    }
}
