import QtQuick
import QtQuick.Shapes

// AnimatedBackground - a subtle, living backdrop: a few large, soft, slowly
// drifting colour orbs (aurora / lava-lamp feel). GPU-rendered (QtQuick.Shapes),
// low opacity, very slow easing so it reads as ambient, not busy. When `active`
// is false (reduce-motion / animation off) the orbs stay painted but stop
// drifting - matching the static-canvas behaviour of the waves/stars backdrops.
Item {
    id: ab
    property bool active: true
    // Primary tint (S7). Defaults to theme.accent; overridable via BackdropLayer.
    property color accent: theme.accent
    clip: true

    // A soft radial colour orb.
    component Orb: Shape {
        id: orb
        property color tint: "#ffffff"
        property real diameter: 600
        property real strength: 0.5
        width: diameter; height: diameter
        antialiasing: true
        // Stay painted even when inactive; only the drift animations gate on `active`.
        ShapePath {
            // strokeWidth 0 is not enough on its own: ShapePath's strokeColor
            // defaults to WHITE, and Qt < 6.9 still rasterises a hairline for a
            // zero-width stroke. The orb then reads as a hard white RING over
            // the wallpaper instead of a soft glow - measured at 3.81:1 against
            // textSecondary for dark/amber/orbs (needs 4.5:1) on Qt 6.7.3, on a
            // GPU and under llvmpipe alike, while the same file measures 5.66:1
            // on 6.11. Naming the stroke transparent removes it on every
            // version, so the backdrop no longer depends on which Qt happens to
            // honour a zero width. Gated by tests/gui/tst_gui_backdrop_contrast.
            strokeColor: "transparent"
            strokeWidth: 0
            fillGradient: RadialGradient {
                centerX: orb.diameter / 2; centerY: orb.diameter / 2
                centerRadius: orb.diameter / 2
                focalX: orb.diameter / 2; focalY: orb.diameter / 2
                GradientStop { position: 0.0; color: Qt.rgba(orb.tint.r, orb.tint.g, orb.tint.b, orb.strength) }
                GradientStop { position: 0.5; color: Qt.rgba(orb.tint.r, orb.tint.g, orb.tint.b, orb.strength * 0.35) }
                GradientStop { position: 1.0; color: Qt.rgba(orb.tint.r, orb.tint.g, orb.tint.b, 0.0) }
            }
            startX: orb.diameter; startY: orb.diameter / 2
            PathArc { x: 0; y: orb.diameter / 2; radiusX: orb.diameter / 2; radiusY: orb.diameter / 2
                useLargeArc: true; direction: PathArc.Clockwise }
            PathArc { x: orb.diameter; y: orb.diameter / 2; radiusX: orb.diameter / 2; radiusY: orb.diameter / 2
                useLargeArc: true; direction: PathArc.Clockwise }
        }
    }

    Orb {
        id: o1
        tint: ab.accent; diameter: Math.min(ab.width, ab.height) * 0.9; strength: 0.7
        SequentialAnimation on x {
            running: ab.active; loops: Animation.Infinite
            NumberAnimation { to: -o1.diameter * 0.25; duration: 19000; easing.type: Easing.InOutSine }
            NumberAnimation { to: ab.width - o1.diameter * 0.6; duration: 23000; easing.type: Easing.InOutSine }
        }
        SequentialAnimation on y {
            running: ab.active; loops: Animation.Infinite
            NumberAnimation { to: ab.height * 0.05; duration: 27000; easing.type: Easing.InOutSine }
            NumberAnimation { to: ab.height * 0.35; duration: 21000; easing.type: Easing.InOutSine }
        }
    }

    Orb {
        id: o2
        tint: theme.accent2; diameter: Math.min(ab.width, ab.height) * 0.85; strength: 0.6
        x: ab.width - diameter * 0.5
        SequentialAnimation on x {
            running: ab.active; loops: Animation.Infinite
            NumberAnimation { to: ab.width - o2.diameter * 0.5; duration: 25000; easing.type: Easing.InOutSine }
            NumberAnimation { to: ab.width * 0.1; duration: 29000; easing.type: Easing.InOutSine }
        }
        SequentialAnimation on y {
            running: ab.active; loops: Animation.Infinite
            NumberAnimation { to: ab.height * 0.55; duration: 24000; easing.type: Easing.InOutSine }
            NumberAnimation { to: ab.height * 0.8; duration: 31000; easing.type: Easing.InOutSine }
        }
    }

    Orb {
        id: o3
        tint: theme.catEntertainment; diameter: Math.min(ab.width, ab.height) * 0.8; strength: 0.52
        y: ab.height * 0.6
        SequentialAnimation on x {
            running: ab.active; loops: Animation.Infinite
            NumberAnimation { to: ab.width * 0.5 - o3.diameter * 0.5; duration: 33000; easing.type: Easing.InOutSine }
            NumberAnimation { to: -o3.diameter * 0.2; duration: 26000; easing.type: Easing.InOutSine }
        }
        SequentialAnimation on y {
            running: ab.active; loops: Animation.Infinite
            NumberAnimation { to: ab.height - o3.diameter * 0.7; duration: 22000; easing.type: Easing.InOutSine }
            NumberAnimation { to: ab.height * 0.45; duration: 28000; easing.type: Easing.InOutSine }
        }
    }
}
