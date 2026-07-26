import QtQuick
import QtTest
import "../../ui/qml" as App
import "GuiUtil.js" as G

// Render the persistent reminder surface in a real compositor. The fast QML
// suite owns queue and action behavior; this file proves that the alert is
// visibly distinct, readable, unclipped, and deliberately dismissible in both
// Edge aspect ratios.
Item {
    id: root
    width: 2560
    height: 720

    property alias theme: appTheme
    App.Theme { id: appTheme }
    property string accentName: "blue"
    property real glassOpacity: 0.5
    property bool showWidgetGlow: true
    property bool reduceMotion: false
    property string themeMode: "midnight"
    property bool animatedBackground: false
    property string orientationMode: "landscape"
    property real textScale: 1.15
    property string fontChoice: "hyperlegible"
    property string metricsJson: "{}"
    property string screensData: "[]"

    App.Dashboard {
        id: dashboard
        anchors.fill: parent
    }

    function find(name) {
        return G.byObjName(dashboard, name)
    }

    TestCase {
        name: "GuiPriorityAlert"
        when: windowShown
        visible: true

        function clearAlerts() {
            while (dashboard.dismissPriorityAlert()) {}
        }

        function showBreakAlert(tag) {
            verify(dashboard.showPriorityAlert({
                key: "gui-break-" + tag,
                eyebrow: "BREAK REMINDER",
                title: "Time to take a real break",
                body: "Step away for a moment. This reminder stays here until you choose.",
                detail: "Try: stand up, stretch your shoulders, and look away from the screen.",
                iconName: "break",
                accent: theme.warning,
                primaryLabel: "I took a break",
                secondaryLabel: "Snooze 5 min"
            }))
            tryVerify(function() {
                return dashboard.priorityAlertSurface.shown
                       && dashboard.priorityAlertSurface.opacity > 0.99
            }, 2000, "priority surface reached its final visible state")
        }

        function assertVisibleContent(tag) {
            var card = find("priorityAlertCard")
            var title = find("priorityAlertTitle")
            var body = find("priorityAlertBody")
            verify(card && title && body, tag + ": alert card and copy exist")
            verify(card.x >= 0 && card.y >= 0, tag + ": card starts on screen")
            verify(card.x + card.width <= dashboard.width + 1,
                   tag + ": card stays inside the right edge")
            verify(card.y + card.height <= dashboard.height + 1,
                   tag + ": card stays inside the bottom edge")
            verify(title.visible && title.paintedWidth <= title.width + 1,
                   tag + ": title is visible and not horizontally clipped")
            verify(title.paintedHeight <= title.height + 1,
                   tag + ": title is not vertically clipped")
            verify(body.visible && body.paintedWidth <= body.width + 1,
                   tag + ": body is visible and not horizontally clipped")
            verify(body.paintedHeight <= body.height + 1,
                   tag + ": body is not vertically clipped")
            verify(dashboard.priorityAlertPrimaryButton.height >= 52,
                   tag + ": primary action is touch sized")
            verify(dashboard.priorityAlertDismissButton.height >= 52,
                   tag + ": dismiss action is touch sized")

            var image = grabImage(root)
            image.save("gui-evidence/priority-alert-" + tag + ".png")
            verify(G.looksRendered(image), tag + ": screenshot contains rendered detail")
        }

        function init() {
            clearAlerts()
            root.reduceMotion = false
        }

        function cleanup() {
            clearAlerts()
        }

        function test_landscape_alert_is_prominent_and_persistent() {
            root.width = 2560
            root.height = 720
            wait(80)
            showBreakAlert("landscape")
            assertVisibleContent("landscape")

            mouseClick(dashboard.priorityAlertSurface, 8, 8)
            wait(650)
            compare(dashboard.priorityAlertSurface.shown, true,
                    "a stray scrim tap does not discard the reminder")
            verify(dashboard.dismissPriorityAlert(),
                   "the explicit dismiss action closes the reminder")
        }

        function test_portrait_alert_is_prominent_and_unclipped() {
            root.width = 720
            root.height = 1500
            wait(80)
            showBreakAlert("portrait")
            assertVisibleContent("portrait")
            verify(dashboard.dismissPriorityAlert())
        }
    }
}
