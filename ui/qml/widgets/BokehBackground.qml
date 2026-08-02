import QtQuick
import QtQuick.Shapes

// BokehBackground - soft depth-of-field bokeh: a scattering of circular soft dots
// (QtQuick.Shapes RadialGradient, bright centre → transparent edge) of varying
// diameter, deterministically placed, slowly rising and wrapping, each gently
// pulsing its opacity. GPU-rendered; no per-frame repaint. When `active` is false
// the dots stay painted but stop rising/pulsing - matching the other backdrops.
Item {
    id: root
    property bool active: true
    // Primary tint (S7). Defaults to theme.accent; overridable via BackdropLayer.
    property color accent: theme.accent
    clip: true

    Repeater {
        model: 14
        delegate: Shape {
            id: dot
            required property int index
            // Deterministic (index-based) pseudo-random parameters - no RNG.
            readonly property real diameter: 30 + (((index * 137 + 53) % 100) / 100) * 110   // 30..140
            readonly property real startFrac: ((index * 613 + 197) % 1000) / 1000
            readonly property real strength: 0.28 + ((index * 71) % 40) / 200                 // 0.28..0.48
            readonly property color tint: index % 5 === 0 ? root.accent
                                        : index % 5 === 1 ? theme.accent2
                                        : index % 5 === 2 ? theme.catEntertainment
                                        : index % 5 === 3 ? theme.catServices
                                        : theme.catInfo
            // Rising phase (0..1) drives a wrapping vertical position.
            property real phase: 0.0

            width: diameter; height: diameter
            antialiasing: true
            x: (((index * 263 + 71) % 1000) / 1000) * root.width - diameter / 2
            // Rise upward and wrap: as phase grows, y decreases; %1 wraps to the bottom.
            y: root.height - (((startFrac + phase) % 1.0) * (root.height + diameter))

            NumberAnimation on phase {
                running: root.active; loops: Animation.Infinite
                from: 0.0; to: 1.0
                duration: 22000 + (dot.index % 5) * 9000   // slower = further away (depth)
                easing.type: Easing.Linear
            }
            SequentialAnimation on opacity {
                running: root.active; loops: Animation.Infinite
                NumberAnimation { to: 0.4; duration: 2600 + (dot.index % 6) * 500; easing.type: Easing.InOutSine }
                NumberAnimation { to: 1.0; duration: 3200 + (dot.index % 4) * 600; easing.type: Easing.InOutSine }
            }

            ShapePath {
                // Same trap as AnimatedBackground: ShapePath's strokeColor
                // defaults to WHITE and Qt < 6.9 rasterises a hairline even at
                // zero width, so each dot gains a hard ring. Name the stroke
                // transparent.
                strokeColor: "transparent"
                strokeWidth: 0
                fillGradient: RadialGradient {
                    centerX: dot.diameter / 2; centerY: dot.diameter / 2
                    centerRadius: dot.diameter / 2
                    focalX: dot.diameter / 2; focalY: dot.diameter / 2
                    GradientStop { position: 0.0; color: Qt.rgba(dot.tint.r, dot.tint.g, dot.tint.b, dot.strength) }
                    GradientStop { position: 0.5; color: Qt.rgba(dot.tint.r, dot.tint.g, dot.tint.b, dot.strength * 0.5) }
                    GradientStop { position: 1.0; color: Qt.rgba(dot.tint.r, dot.tint.g, dot.tint.b, 0.0) }
                }
                startX: dot.diameter; startY: dot.diameter / 2
                PathArc { x: 0; y: dot.diameter / 2; radiusX: dot.diameter / 2; radiusY: dot.diameter / 2
                    useLargeArc: true; direction: PathArc.Clockwise }
                PathArc { x: dot.diameter; y: dot.diameter / 2; radiusX: dot.diameter / 2; radiusY: dot.diameter / 2
                    useLargeArc: true; direction: PathArc.Clockwise }
            }
        }
    }
}
