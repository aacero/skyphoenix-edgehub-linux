import QtQuick
import QtTest
import "../../ui/qml" as App
import "../../ui/qml/widgets" as W

// Composed-pixel contrast scan for the real WidgetChrome backdrop stack. The
// pure token matrix cannot see animated style pixels. This test freezes motion,
// renders every theme, accent, and background-style combination, then measures
// the final card pixels that text can sit on.
Item {
    id: root
    width: 320
    height: 220

    property alias theme: scanTheme
    App.Theme {
        id: scanTheme
        reduceMotion: true
        reduceMotionPreference: "on"
        glassOpacity: 0.55
    }
    App.BackgroundCatalog { id: backgrounds }

    W.WidgetChrome {
        id: chrome
        x: 20
        y: 20
        width: 280
        height: 180
        title: ""
        iconName: ""
        showHeader: false
        sizeClass: "wide"
        accentName: "blue"
        cardBackdrop: "none"
    }

    function luminance(red, green, blue) {
        function linear(value) {
            value /= 255
            return value <= 0.03928
                    ? value / 12.92
                    : Math.pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red)
             + 0.7152 * linear(green)
             + 0.0722 * linear(blue)
    }

    function contrastWithPixel(foreground, image, x, y) {
        var first = luminance(Math.round(foreground.r * 255),
                              Math.round(foreground.g * 255),
                              Math.round(foreground.b * 255))
        var second = luminance(image.red(x, y), image.green(x, y), image.blue(x, y))
        return (Math.max(first, second) + 0.05)
             / (Math.min(first, second) + 0.05)
    }

    function minimumPixelContrast(foreground, image) {
        var minimum = 21.0
        // Stay inside the rounded edge and sample densely enough to hit the
        // thin star, grid, wave, and ribbon features.
        for (var y = 14; y < image.height - 14; y += 2) {
            for (var x = 14; x < image.width - 14; x += 2)
                minimum = Math.min(minimum, contrastWithPixel(foreground, image, x, y))
        }
        return minimum
    }

    TestCase {
        name: "WidgetBackdropContrast"
        when: windowShown
        visible: true

        function test_composed_matrix() {
            var modes = scanTheme.themeCatalog.map(function (entry) { return entry.k })
            var accents = Object.keys(scanTheme.accentPresets).sort()
            var styles = backgrounds.styles.map(function (entry) { return entry.v })
            compare(modes.length, 29, "all themes are in the pixel matrix")
            compare(accents.length, 29, "all accents are in the pixel matrix")
            compare(styles.length, 11, "all background styles are in the pixel matrix")

            var combinations = 0
            for (var m = 0; m < modes.length; m++) {
                var mode = modes[m]
                scanTheme.applyTheme(mode)
                for (var a = 0; a < accents.length; a++) {
                    var accent = accents[a]
                    chrome.accentName = accent
                    for (var s = 0; s < styles.length; s++) {
                        var style = styles[s]
                        chrome.cardBackdrop = style
                        wait(0)
                        var image = grabImage(chrome)
                        verify(image.width === chrome.width && image.height === chrome.height,
                               mode + "/" + accent + "/" + style + " rendered at card size")
                        var primary = minimumPixelContrast(scanTheme.textPrimary, image)
                        var secondary = minimumPixelContrast(scanTheme.textSecondary, image)
                        verify(primary >= 4.5,
                               mode + "/" + accent + "/" + style
                               + " primary pixel minimum=" + primary.toFixed(2)
                               + ":1, needs 4.5:1")
                        verify(secondary >= 4.5,
                               mode + "/" + accent + "/" + style
                               + " secondary pixel minimum=" + secondary.toFixed(2)
                               + ":1, needs 4.5:1")
                        combinations++
                    }
                }
            }
            compare(combinations, 9251,
                    "29 themes x 29 accents x 11 backgrounds were measured")
        }
    }
}
