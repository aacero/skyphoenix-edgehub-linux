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
    width: 280
    height: 180

    property alias theme: scanTheme
    App.Theme {
        id: scanTheme
        reduceMotion: true
        reduceMotionPreference: "on"
        glassOpacity: 0.55
    }
    App.BackgroundCatalog { id: backgrounds }

    Rectangle {
        anchors.fill: parent
        color: scanTheme.backgroundColor
    }

    W.WidgetChrome {
        id: chrome
        x: 0
        y: 0
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

    function colorLuminance(colour) {
        return luminance(Math.round(colour.r * 255),
                         Math.round(colour.g * 255),
                         Math.round(colour.b * 255))
    }

    // Both foregrounds in ONE pass over the pixels.
    //
    // The previous shape walked the image once per foreground and, inside the
    // loop, recomputed the FOREGROUND's luminance for every single pixel: 12
    // pow() calls and 6 image reads per pixel where 3 and 3 suffice. Same
    // pixels, same arithmetic, same minima - about a quarter of the work.
    //
    // That is not a micro-optimisation here. This matrix is 9251 combinations x
    // ~11k sampled pixels, and it had never once run to completion: it always
    // aborted within seconds at the first orbs entry. The moment the ShapePath
    // hairline fix let it finish, the honest cost showed up as a 540s per-file
    // TIMEKILL on CI - and, because it then held a slot at full CPU for the
    // whole run on a four-core runner, it dragged tst_gui_w_cal_weather from
    // 62s to a timeout as well.
    function minimumPixelContrasts(firstLuminance, secondLuminance, image) {
        var lowestFirst = 21.0
        var lowestSecond = 21.0
        // Stay inside the rounded edge and sample densely enough to hit the
        // thin star, grid, wave, and ribbon features.
        for (var y = 14; y < image.height - 14; y += 2) {
            for (var x = 14; x < image.width - 14; x += 2) {
                var pixel = luminance(image.red(x, y), image.green(x, y),
                                      image.blue(x, y))
                var first = (Math.max(firstLuminance, pixel) + 0.05)
                          / (Math.min(firstLuminance, pixel) + 0.05)
                if (first < lowestFirst) lowestFirst = first
                var second = (Math.max(secondLuminance, pixel) + 0.05)
                           / (Math.min(secondLuminance, pixel) + 0.05)
                if (second < lowestSecond) lowestSecond = second
            }
        }
        return ({ primary: lowestFirst, secondary: lowestSecond })
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
                        // A grab can come back before the new style has been
                        // presented - seen once in 9251 combinations under
                        // llvmpipe, as an image that is not the card's size.
                        // Judging a frame that does not exist yet says nothing
                        // about the product, so wait for a real one and grab
                        // again. The assertion below is unchanged: a style that
                        // never renders at card size still fails.
                        if (image.width !== chrome.width
                                || image.height !== chrome.height) {
                            waitForRendering(chrome, 2000)
                            image = grabImage(chrome)
                        }
                        verify(image.width === chrome.width && image.height === chrome.height,
                               mode + "/" + accent + "/" + style + " rendered at card size")
                        var minima = minimumPixelContrasts(
                            colorLuminance(scanTheme.textPrimary),
                            colorLuminance(scanTheme.textSecondary), image)
                        var primary = minima.primary
                        var secondary = minima.secondary
                        // Keep the pixels that failed. This matrix measures a
                        // rendered surface, so a shortfall that appears only on
                        // one renderer (CI runs Mesa's CPU rasteriser) cannot be
                        // diagnosed from the number alone - the saved frame is
                        // the only way to tell "this combination really is that
                        // low" from "this backdrop drew something different
                        // here". Costs nothing on a passing run.
                        if (primary < 4.5 || secondary < 4.5)
                            image.save("gui-evidence/contrast-" + mode + "-"
                                       + accent + "-" + style + ".png")
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
