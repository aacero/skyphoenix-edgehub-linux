import QtQuick
import QtQuick.Layouts

// ─────────────────────────────────────────────────────────────────────────
// WidgetChrome - the shared, uniform frame for EVERY widget.
//
// This is the "common thread" of the design language: a glass card with a
// subtle gradient, an accent glow, and a consistent header (icon + title +
// optional trailing status). Individual widgets place their content inside
// via the default `content` alias and only need to worry about their data.
//
//   WidgetChrome {
//       title: "Focus"; iconName: "focus"; accentColor: theme.catProductivity
//       // ...your content here...
//   }
//
// SIZE vs EXPANDED - they are not the same thing, and conflating them is why no
// widget currently adapts to its tile:
//   • `sizeClass` = how much ROOM this instance has. Injected by Dashboard from the
//     tile's span (or "full" for the overlay). This is what layout should key off.
//   • `expanded`  = the widget is hosted in the full-screen overlay. A MODE, not a
//     size.
// Every widget used to declare `big: expanded`, which made "big" mean "is the
// overlay" - so a 2-row tile rendered the compact layout STRETCHED, and the
// geometric intent below was dead code. `big` is now derived from sizeClass and is
// READONLY: a widget cannot re-tie it to expanded, which is the whole point.
// ─────────────────────────────────────────────────────────────────────────
Item {
    id: chrome

    // --- Public API ---
    property string title: ""
    property string titleOverride: ""   // user-set custom title (from config), wins if set
    property string iconName: ""        // professional SVG icon (qrc:/icons/<name>.svg)
    property color accentColor: theme.accentReadable
    // Per-widget appearance (set per-instance via config; applies to ANY widget):
    //   accentName  - a theme accent preset name that overrides accentColor.
    //   cardBackdrop - an animated backdrop rendered INSIDE this card so the widget
    //                  stands out ("none" | orbs | mesh | aurora | waves | stars | bokeh | grid).
    property string accentName: ""
    property string cardBackdrop: "none"
    // Resolve the effective accent. A named preset (accentName) wins; otherwise
    // fall back to accentColor. Guard against a self-referential binding loop
    // (a widget setting `accentColor: someChrome.effAccent`), which resolves to
    // an invalid/transparent colour - use theme.accent so content never renders
    // black/invisible.
    readonly property color effAccent: (accentName !== "" && theme.accentPresets[accentName])
                                       ? theme.readableAccentFor(accentName)
                                       : theme.ensureNonTextContrast(
                                             accentColor.a > 0 ? accentColor : theme.accent)
    property string status: ""          // small trailing status text (top-right)
    property color statusColor: theme.textPrimary
    // How much room this instance has. WidgetHost sets it from the
    // tile's span, or "full" for the overlay:
    //   "compact" 1 col × 1 row · "wide" 2×1 · "tall" 1×2 · "large" 2×2 · "full" overlay
    // The default derives from actual geometry so a standalone host (tests, the
    // Manager preview) still gets a sane value instead of always-compact - it
    // restores the intent of the original `big: height > 240`.
    property string sizeClass: height > 240 ? "tall" : "compact"

    // Does this instance have vertical room for the richer chrome? DERIVED from
    // sizeClass, and readonly ON PURPOSE - the old `big: expanded` override is what
    // this change exists to make impossible.
    readonly property bool big: sizeClass === "tall" || sizeClass === "large"
                                || sizeClass === "full"

    // Is this the MICRO footprint - a half-cell (`0.5x0.5`), as opposed to the
    // baseline third (`1x1`)? Both project to sizeClass "compact" (they are the
    // same SHAPE, just different areas), so the wave-1 widgets each re-derived
    // this locally as `min(width,height) < 480`. Centralised here so later waves
    // key off chrome instead of copy-pasting a magic number: the half-cell is
    // ~348x409 portrait / ~423x306 landscape and the baseline is ~696x819 /
    // ~846x612, so 480 cleanly separates the two on every orientation. DERIVED
    // and readonly, like `big`.
    readonly property bool micro: sizeClass === "compact"
                                  && Math.min(width, height) < 480
    property bool showHeader: true
    property bool interactive: false     // retained for API compat; hover ring is a no-op on the touchscreen
    // When hosted inside the expanded overlay (which supplies its own card),
    // drop this widget's own card surface + padding to avoid a card-in-a-card.
    property bool chromeless: false
    property real contentMargins: chromeless ? 0 : (big ? theme.spacingLg : theme.spacingSm)
    property alias headerRightItem: headerRight.data

    default property alias content: body.data

    // Convenience: header height scales with size.
    readonly property int headerHeight: Math.max(big ? 46 : 42, theme.fontTitle + 20)

    // --- Card surface ---
    Rectangle {
        id: surface
        visible: !chrome.chromeless
        anchors.fill: parent
        radius: theme.radiusLg
        color: theme.cardFillColor
        border.width: theme.cardBorderWidth
        // Glass-driven rim light: the border brightens with the Glassiness slider
        // (theme.cardBorderGlass), so the control has a clear, contrast-safe
        // effect even on a flat dark page.
        border.color: theme.cardBorderGlass
        Behavior on border.color { ColorAnimation { duration: theme.motionFast } }
        clip: true

        // Per-widget animated backdrop, inset from the rounded corners so it never
        // pokes past them. Sits behind the glass overlays + the widget content.
        BackdropLayer {
            anchors.fill: parent
            anchors.margins: parent.radius
            visible: chrome.cardBackdrop !== "none" && chrome.cardBackdrop !== "" && theme.decorative
            style: chrome.cardBackdrop
            accent: chrome.effAccent
            // effectiveReduceMotion (not the raw persisted flag) so the OS
            // reduce-motion signal / explicit preference stops card backdrops too.
            running: !theme.effectiveReduceMotion
        }

        // Diagonal glass gradient. The top frosted highlight scales with the
        // Glassiness slider (theme.cardSheen) so more glass reads as a stronger
        // sheen - the second visible cue alongside the brightened border.
        Rectangle {
            visible: theme.decorative
            anchors.fill: parent
            radius: parent.radius
            gradient: Gradient {
                orientation: Gradient.Vertical
                GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, theme.cardSheen) }
                GradientStop { position: 0.5; color: Qt.rgba(1, 1, 1, 0.0) }
                GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.10) }
            }
        }

        // Accent wash in the top-left corner - ties each widget to its category.
        Rectangle {
            visible: theme.decorative
            anchors.fill: parent
            radius: parent.radius
            opacity: 0.06
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: chrome.effAccent }
                GradientStop { position: 0.55; color: "transparent" }
            }
        }

        // Top accent hairline (glow)
        Rectangle {
            visible: theme.glow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.leftMargin: parent.radius
            anchors.rightMargin: parent.radius
            height: 2
            radius: 1
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "transparent" }
                GradientStop { position: 0.5; color: chrome.effAccent }
                GradientStop { position: 1.0; color: "transparent" }
            }
            opacity: 0.7
        }
    }

    // --- Content column: header + body ---
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: chrome.contentMargins
        spacing: chrome.big ? theme.spacingSm : theme.spacingXs

        // Header
        RowLayout {
            visible: chrome.showHeader && (chrome.title !== "" || chrome.iconName !== "")
            Layout.fillWidth: true
            Layout.preferredHeight: chrome.headerHeight
            spacing: theme.spacingSm

            AppIcon {
                visible: chrome.iconName !== ""
                name: chrome.iconName
                color: chrome.effAccent
                size: chrome.big ? 30 : 26
                Layout.alignment: Qt.AlignVCenter
            }
            Text {
                text: chrome.titleOverride.length ? chrome.titleOverride : chrome.title
                font.pixelSize: theme.fontTitle
                font.weight: Font.DemiBold
                font.family: theme.fontDisplay
                color: theme.textPrimary
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
            // Optional custom trailing items (buttons etc.)
            RowLayout {
                id: headerRight
                spacing: theme.spacingXs
                Layout.alignment: Qt.AlignVCenter
            }
            Text {
                visible: chrome.status !== ""
                text: chrome.status
                font.pixelSize: theme.fontMinimum
                font.family: theme.fontMono
                color: chrome.statusColor
                elide: Text.ElideRight
                Layout.maximumWidth: Math.max(72, chrome.width * 0.30)
            }
        }

        // Body - the widget's own content lives here.
        Item {
            id: body
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
        }
    }
}
