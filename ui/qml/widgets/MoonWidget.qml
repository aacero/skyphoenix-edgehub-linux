import QtQuick
import QtQuick.Layouts

// Moon phase - computed locally from the current date (synodic month).
//
// Sizing (W1 wave 2a): layout keys off the injected `sizeClass`. The tile
// stays headerless (the glyph IS the header); each size earns its box:
//   • 0.5x0.5 (micro) - the glyph alone, scaled to the box.
//   • 1x1 (baseline)  - glyph + phase name + "% illuminated" (the old 58px
//                       emoji floated tiny in a third of the screen).
//   • wide            - glyph beside a name / illumination / age column.
//   • tall            - glyph + name + illumination/age + next new/full dates
//                       (the dates used to be locked behind the overlay).
//   • full (overlay)  - the full readout, header shown, sized by the pane it is
//                       actually given (see glyphPx). It is NOT a full screen:
//                       Dashboard hosts it in a live-preview pane beside the
//                       config form - ~941x456 landscape, ~656x980 portrait -
//                       so "full" is a class like any other and reads its own
//                       box rather than a set of literals.
//
// `showHeader: expanded` is the one thing here that is legitimately keyed off the
// MODE rather than the room, and it stays: it is chrome-header CONTENT, not a
// dimension. The tile is headerless AT EVERY SIZE by design (the glyph is the
// header - see above); only the overlay, which is a titled view of one widget,
// shows a header. That is a mode question and `expanded` answers it correctly.
WidgetChrome {
    id: w
    property var metrics: ({})
    property bool expanded: false
    property bool active: true
    property var store: null
    property string instanceId: ""
    property int tick: 0
    property var netHub: null
    property var xhrFactory: null
    NetHub { id: fallbackHub }
    function _hub() { return w.netHub ? w.netHub : fallbackHub }

    title: "Moon Phase"; iconName: "moon"; accentColor: theme.catInfo
    showHeader: expanded

    // Live per-instance config (see WidgetConfigSchema "moon").
    readonly property var cfg: {
        var _ = store ? store.revision : 0
        return (store && instanceId) ? JSON.parse(JSON.stringify(store.settingsFor(instanceId))) : ({})
    }
    readonly property string hemisphere: cfg.hemisphere === "south" ? "south" : "north"
    readonly property bool showAccuracyNote: cfg.showAccuracyNote !== undefined ? cfg.showAccuracyNote : true
    readonly property bool showLocalEvents: cfg.showLocalEvents !== undefined ? cfg.showLocalEvents : false
    readonly property string locationMode: cfg.locationMode === "manual" ? "manual" : "search"
    readonly property real lat: cfg.lat !== undefined && cfg.lat !== null
                                && ("" + cfg.lat).trim().length ? Number(cfg.lat) : NaN
    readonly property real lon: cfg.lon !== undefined && cfg.lon !== null
                                && ("" + cfg.lon).trim().length ? Number(cfg.lon) : NaN
    readonly property string place: cfg.place || ""
    readonly property bool locationConfigured: isFinite(w.lat) && isFinite(w.lon)
                                               && w.lat >= -90 && w.lat <= 90
                                               && w.lon >= -180 && w.lon <= 180

    readonly property var names: ["New Moon", "Waxing Crescent", "First Quarter", "Waxing Gibbous",
                                  "Full Moon", "Waning Gibbous", "Last Quarter", "Waning Crescent"]
    // Recompute daily via the tick (cheap; changes only across midnight).
    readonly property real _synodicSec: 2551443.0 // synodic month in seconds
    property real _cyclePos: {
        w.tick
        var now = new Date().getTime() / 1000
        // Canonical reference new moon: 2000-01-06 18:14 UTC (must be built in UTC,
        // else the viewer's timezone offset skews the phase).
        var newMoonRef = Date.UTC(2000, 0, 6, 18, 14) / 1000
        var frac = ((now - newMoonRef) % w._synodicSec) / w._synodicSec
        if (frac < 0) frac += 1
        return frac
    }
    property int idx: Math.floor(_cyclePos * 8 + 0.5) % 8
    // True illuminated fraction of a sphere: (1 - cos(phase angle)) / 2, where the
    // phase angle sweeps 0→2π across the synodic month (0 at new, π at full).
    property int illum: Math.round((1 - Math.cos(_cyclePos * 2 * Math.PI)) / 2 * 100)
    // Lunar age in days and the dates of the next new / full moon (all derived).
    property real ageDays: _cyclePos * (_synodicSec / 86400)
    readonly property string phaseDirection: _cyclePos < 0.5 ? "Waxing" : "Waning"
    readonly property string modelLabel: "Approximate geocentric phase"
    function _nextDate(targetPos) {
        var ahead = targetPos - _cyclePos
        if (ahead <= 0) ahead += 1
        return new Date(new Date().getTime() + ahead * _synodicSec * 1000)
    }
    property var nextNew: (w.tick, _nextDate(0))
    property var nextFull: (w.tick, _nextDate(0.5))

    function _rad(degrees) { return degrees * Math.PI / 180 }
    function _norm(degrees) {
        var out = degrees % 360
        return out < 0 ? out + 360 : out
    }
    function _moonAltitude(at, latitude, longitude) {
        var jd = at.getTime() / 86400000 + 2440587.5
        var days = jd - 2451545.0
        var meanLon = w._norm(218.316 + 13.176396 * days)
        var meanAnomaly = w._norm(134.963 + 13.064993 * days)
        var latitudeArg = w._norm(93.272 + 13.229350 * days)
        var eclipticLon = meanLon + 6.289 * Math.sin(w._rad(meanAnomaly))
        var eclipticLat = 5.128 * Math.sin(w._rad(latitudeArg))
        var obliquity = 23.439 - 0.0000004 * days
        var lonR = w._rad(eclipticLon)
        var latR = w._rad(eclipticLat)
        var oblR = w._rad(obliquity)
        var rightAscension = Math.atan2(Math.sin(lonR) * Math.cos(oblR)
                                        - Math.tan(latR) * Math.sin(oblR),
                                        Math.cos(lonR))
        var declination = Math.asin(Math.sin(latR) * Math.cos(oblR)
                                    + Math.cos(latR) * Math.sin(oblR) * Math.sin(lonR))
        var sidereal = w._norm(280.46061837 + 360.98564736629 * days + longitude)
        var hourAngle = w._rad(w._norm(sidereal - rightAscension * 180 / Math.PI + 180) - 180)
        var observerLat = w._rad(latitude)
        return Math.asin(Math.sin(observerLat) * Math.sin(declination)
                         + Math.cos(observerLat) * Math.cos(declination) * Math.cos(hourAngle))
               * 180 / Math.PI
    }
    function _crossingTime(a, b, altA, altB) {
        var threshold = 0.125
        var span = altB - altA
        var fraction = Math.abs(span) < 0.0001 ? 0.5 : (threshold - altA) / span
        fraction = Math.max(0, Math.min(1, fraction))
        return new Date(a.getTime() + (b.getTime() - a.getTime()) * fraction)
    }
    function calculateLocalEvents(startAt) {
        if (!w.locationConfigured) return { rise: null, set: null }
        var stepMs = 10 * 60 * 1000
        var endMs = startAt.getTime() + 36 * 60 * 60 * 1000
        var previousAt = startAt
        var previousAlt = w._moonAltitude(previousAt, w.lat, w.lon)
        var rise = null
        var set = null
        for (var ms = startAt.getTime() + stepMs; ms <= endMs && (!rise || !set); ms += stepMs) {
            var at = new Date(ms)
            var altitude = w._moonAltitude(at, w.lat, w.lon)
            if (!rise && previousAlt < 0.125 && altitude >= 0.125)
                rise = w._crossingTime(previousAt, at, previousAlt, altitude)
            if (!set && previousAlt >= 0.125 && altitude < 0.125)
                set = w._crossingTime(previousAt, at, previousAlt, altitude)
            previousAt = at
            previousAlt = altitude
        }
        return { rise: rise, set: set }
    }
    readonly property int astroHour: {
        w.tick
        return Math.floor(Date.now() / 3600000)
    }
    readonly property var localEvents: {
        var _ = w.astroHour
        return w.showLocalEvents && w.locationConfigured
               ? w.calculateLocalEvents(new Date()) : ({ rise: null, set: null })
    }
    function eventTime(value) {
        return value ? Qt.formatTime(value, "HH:mm") : "None in next 36h"
    }
    readonly property string locationLabel: w.place.length
        ? w.place : (w.locationConfigured ? w.lat.toFixed(2) + ", " + w.lon.toFixed(2) : "")

    property var _geocodeXhr: null
    property int _geocodeSequence: 0
    property bool geocoding: false
    property string geocodeError: ""
    property string geocodeStatus: ""
    function geocode(name) {
        if (!name || !name.trim().length) return
        if (w._geocodeXhr) {
            try { w._geocodeXhr.abort() } catch (e) {}
            w._geocodeXhr = null
        }
        w.geocoding = true
        w.geocodeError = ""
        w.geocodeStatus = "Searching for " + name.trim() + "..."
        var seq = ++w._geocodeSequence
        var request = w._hub().request({
            url: "https://geocoding-api.open-meteo.com/v1/search?count=1&name="
                 + encodeURIComponent(name.trim()),
            timeout: 8000,
            xhrFactory: w.xhrFactory,
            onDone: function(status, body) {
                if (seq !== w._geocodeSequence) return
                w._geocodeXhr = null
                w.geocoding = false
                try {
                    var data = JSON.parse(body)
                    if (data && data.results && data.results.length) {
                        var result = data.results[0]
                        var label = result.name + (result.country_code ? ", " + result.country_code : "")
                        if (w.store) w.store.patchSettings(w.instanceId, {
                            lat: result.latitude, lon: result.longitude, place: label
                        })
                        w.geocodeStatus = "Set to " + label
                    } else {
                        w.geocodeError = "City not found"
                        w.geocodeStatus = w.geocodeError
                    }
                } catch (e) {
                    w.geocodeError = "Lookup failed"
                    w.geocodeStatus = w.geocodeError
                }
            },
            onError: function(reason) {
                if (seq !== w._geocodeSequence) return
                w._geocodeXhr = null
                w.geocoding = false
                w.geocodeError = reason === "offline" ? "Offline"
                    : reason === "blocked" ? "Lookup blocked"
                    : reason === "timeout" ? "Lookup timed out" : "Lookup failed"
                w.geocodeStatus = w.geocodeError
            }
        })
        if (seq === w._geocodeSequence) w._geocodeXhr = request
    }
    Component.onDestruction: {
        w._geocodeSequence++
        if (w._geocodeXhr) w._geocodeXhr.abort()
    }

    // ── Per-size layout (sizeClass injected by Dashboard) ────────────────────
    readonly property bool horiz: sizeClass === "wide"
    readonly property bool tallish: sizeClass === "tall" || sizeClass === "large"
    // Has this instance got room to spare? The overlay is a size CLASS ("full",
    // injected by Dashboard alongside expanded), not a mode - so it belongs in
    // this predicate rather than in a `w.expanded ?` branch scattered across the
    // file. `large` is unreachable for the sizes this type declares (0.5x0.5,
    // 0.5x1, 1x0.5, 1x1) but is kept so a forced class degrades sanely.
    readonly property bool roomy: tallish || sizeClass === "full"
                                 || width * height > 700000
    // The glyph scales to its box (line box ≈ pixelSize * 1.3), clamped per
    // class so it reads as a moon, not a wall.
    //
    // The `expanded ? 150` this used to lead with was frozen twice over: it
    // ignored the box it was actually handed, and it never noticed when W5 shrank
    // the overlay's live-preview pane to 38% of the width in landscape. That pane
    // is ~941x456 landscape / ~656x980 portrait, not a 2560x720 screen - fed
    // through the general term below they ask for 173 and 190, and 150 was
    // neither. Dropping the branch entirely lets "full" fall through to the same
    // two-axis term every other non-wide class uses; no tile class changes.
    readonly property real glyphPx: micro ? Math.min(width * 0.64, height * 0.68, 220)
        : horiz ? Math.min(width * (roomy ? 0.24 : 0.30),
                           height * (roomy ? 0.60 : 0.55), roomy ? 260 : 170)
        : tallish ? Math.min(width * 0.68, height * 0.45, 260)
        : Math.min(width * 0.50, height * 0.44, 300)
    // Illumination context: the sizes that have room add the lunar age. (`|| expanded`
    // dropped - `roomy` already covers sizeClass "full", which is what the overlay
    // is injected as, so the mode term was dead weight.)
    readonly property string illumLine: (horiz || roomy)
        ? w.illum + "% illuminated  ·  " + w.ageDays.toFixed(1) + " days old"
        : w.illum + "% illuminated"
    // The phase name and the illumination line are sized by the BOX, with the
    // ceiling - not the mode - widening where there is room for it. The old
    // `expanded ? 26` / `expanded ? 16` pinned the overlay to one number for two
    // very differently-shaped panes; a height term separates them AND, being the
    // right question, gives the taller pane the bigger name (656x980 -> 29.5 >
    // 941x456 -> 27.4). Portrait tiles are unchanged (their width term binds well
    // below both the height term and the cap); the one deliberate shift is the
    // wide LANDSCAPE half-cell (846x306 / 423x306), whose name eases from 24 to
    // ~18 because a 306px-tall box genuinely has less vertical room - the same
    // room-driven logic, not a regression.
    readonly property real namePx: Math.max(roomy ? 18 : 14,
                                             Math.min(width * (roomy ? 0.065 : 0.045), height * 0.06,
                                                         roomy ? 34 : 24))
    readonly property real illumPx: Math.max(theme.fontMinimum,
                                              Math.min(width * 0.032, height * 0.042,
                                                          roomy ? 22 : 16))

    GridLayout {
        id: moonLay
        anchors.centerIn: parent
        width: parent.width
        columns: w.horiz ? 2 : 1
        // Air is room, not mode: 14 was "the overlay" and 2 "not the overlay",
        // so a 0.5x1 tall tile carrying the same glyph + name + illumination +
        // dates stack as the overlay got the cramped 2.
        rowSpacing: w.roomy ? 14 : 2
        columnSpacing: theme.spacingLg

        Canvas {
            id: moonDisc
            objectName: "moonDisc"
            readonly property bool mirrored: w.hemisphere === "south"
            readonly property real phase: w._cyclePos
            Layout.alignment: Qt.AlignHCenter | Qt.AlignVCenter
            Layout.preferredWidth: Math.max(theme.fontMinimum * 3, w.glyphPx)
            Layout.preferredHeight: Layout.preferredWidth
            Accessible.role: Accessible.StaticText
            Accessible.name: w.names[w.idx] + ", " + w.illum + " percent illuminated, "
                             + w.phaseDirection + ". Approximate geocentric phase."
            onPaint: {
                var ctx = getContext("2d")
                var cx = width / 2
                var cy = height / 2
                var radius = Math.max(0, Math.min(width, height) / 2 - 5)
                ctx.clearRect(0, 0, width, height)
                if (radius <= 0) return
                ctx.save()
                if (w.hemisphere === "south") {
                    ctx.translate(width, 0)
                    ctx.scale(-1, 1)
                    cx = width - cx
                }
                ctx.fillStyle = theme.cardBackgroundAlt
                ctx.beginPath()
                ctx.arc(cx, cy, radius, 0, Math.PI * 2)
                ctx.fill()

                var phase = Math.max(0, Math.min(1, w._cyclePos))
                var k = 1.333333
                if (phase > 0.001 && phase < 0.999) {
                    ctx.fillStyle = theme.textPrimary
                    ctx.beginPath()
                    ctx.moveTo(cx, cy - radius)
                    if (phase <= 0.5) {
                        ctx.bezierCurveTo(cx + k * radius, cy - radius,
                                          cx + k * radius, cy + radius,
                                          cx, cy + radius)
                        var waxingTerminator = cx + k * radius * Math.cos(2 * Math.PI * phase)
                        ctx.bezierCurveTo(waxingTerminator, cy + radius,
                                          waxingTerminator, cy - radius,
                                          cx, cy - radius)
                    } else {
                        ctx.bezierCurveTo(cx - k * radius, cy - radius,
                                          cx - k * radius, cy + radius,
                                          cx, cy + radius)
                        var waningTerminator = cx - k * radius * Math.cos(2 * Math.PI * phase)
                        ctx.bezierCurveTo(waningTerminator, cy + radius,
                                          waningTerminator, cy - radius,
                                          cx, cy - radius)
                    }
                    ctx.closePath()
                    ctx.fill()
                } else if (phase >= 0.999) {
                    ctx.fillStyle = theme.cardBackgroundAlt
                }
                ctx.strokeStyle = w.effAccent
                ctx.lineWidth = Math.max(3, radius * 0.035)
                ctx.beginPath()
                ctx.arc(cx, cy, radius, 0, Math.PI * 2)
                ctx.stroke()
                ctx.restore()
            }
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            onPhaseChanged: requestPaint()
            onMirroredChanged: requestPaint()
            Connections {
                target: w
                function onEffAccentChanged() { moonDisc.requestPaint() }
            }
            Connections {
                target: theme
                function onTextPrimaryChanged() { moonDisc.requestPaint() }
                function onCardBackgroundAltChanged() { moonDisc.requestPaint() }
            }
            Component.onCompleted: requestPaint()
        }

        ColumnLayout {
            visible: !w.micro
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: w.roomy ? 14 : 4          // room, not mode - see rowSpacing above

            // fillWidth (not maximumWidth): a non-fill Text caps the nested
            // column's own stretch, which pinned the whole block to the left.
            Text { Layout.fillWidth: true; text: w.names[w.idx]
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight; fontSizeMode: Text.HorizontalFit
                font.pixelSize: Math.round(w.namePx)
                font.family: theme.fontDisplay
                color: w.effAccent }
            Text { Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight; fontSizeMode: Text.HorizontalFit; minimumPixelSize: theme.fontMinimum
                text: w.illumLine
                font.pixelSize: Math.round(w.illumPx)
                color: theme.textTertiary }
            // Next new/full dates - the overlay's readout, now also earned by
            // tall tiles (genuinely more information, not a stretched glyph).
            // `roomy` is exactly the old `w.expanded || w.tallish`: Dashboard
            // injects "full" for the overlay, so the mode term said nothing the
            // class did not already say.
            RowLayout {
                objectName: "moonUpcomingDates"
                Layout.alignment: Qt.AlignHCenter
                visible: w.roomy
                spacing: theme.spacingXl
                Layout.topMargin: theme.spacingSm
                ColumnLayout {
                    spacing: 1
                    Text { Layout.alignment: Qt.AlignHCenter; text: "NEXT NEW"; font.pixelSize: theme.fontLabel; color: theme.textSecondary; font.bold: true }
                    Text { Layout.alignment: Qt.AlignHCenter; text: Qt.formatDate(w.nextNew, "ddd, d MMM")
                        font.pixelSize: theme.fontTitle; font.bold: true; color: w.effAccent }
                }
                ColumnLayout {
                    spacing: 1
                    Text { Layout.alignment: Qt.AlignHCenter; text: "NEXT FULL"; font.pixelSize: theme.fontLabel; color: theme.textSecondary; font.bold: true }
                    Text { Layout.alignment: Qt.AlignHCenter; text: Qt.formatDate(w.nextFull, "ddd, d MMM")
                        font.pixelSize: theme.fontTitle; font.bold: true; color: w.effAccent }
                }
            }
            ColumnLayout {
                objectName: "moonCyclePosition"
                visible: w.roomy
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: Math.min(moonLay.width * 0.76, 420)
                spacing: theme.spacingXs
                Text {
                    Layout.fillWidth: true
                    text: "LUNAR CYCLE"
                    horizontalAlignment: Text.AlignHCenter
                    color: theme.textTertiary
                    font.pixelSize: theme.fontMinimum
                    font.bold: true
                    font.letterSpacing: 0.8
                }
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 10
                    radius: height / 2
                    color: theme.cardBorder
                    Rectangle {
                        width: parent.width * Math.max(0, Math.min(1, w._cyclePos))
                        height: parent.height
                        radius: height / 2
                        color: w.effAccent
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    Text { text: "NEW"; color: theme.textTertiary; font.pixelSize: theme.fontMinimum; font.bold: true }
                    Item { Layout.fillWidth: true }
                    Text { text: "FULL"; color: theme.textTertiary; font.pixelSize: theme.fontMinimum; font.bold: true }
                    Item { Layout.fillWidth: true }
                    Text { text: "NEW"; color: theme.textTertiary; font.pixelSize: theme.fontMinimum; font.bold: true }
                }
            }
            Rectangle {
                objectName: "moonLocalEvents"
                visible: w.roomy && w.showLocalEvents
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: Math.min(moonLay.width * 0.86, 520)
                Layout.preferredHeight: localEventColumn.implicitHeight + theme.spacingMd * 2
                radius: theme.radiusMd
                color: theme.cardBackgroundAlt
                border.width: 1
                border.color: w.locationConfigured ? w.effAccent : theme.warning
                ColumnLayout {
                    id: localEventColumn
                    anchors.fill: parent
                    anchors.margins: theme.spacingMd
                    spacing: theme.spacingXs
                    Text {
                        Layout.fillWidth: true
                        text: w.locationConfigured
                              ? (w.locationLabel.length ? w.locationLabel : "Configured location")
                              : "Location needed for local sky events"
                        horizontalAlignment: Text.AlignHCenter
                        color: w.locationConfigured ? w.effAccent : theme.warning
                        font.pixelSize: theme.fontLabel
                        font.bold: true
                        elide: Text.ElideRight
                    }
                    GridLayout {
                        visible: w.locationConfigured
                        Layout.fillWidth: true
                        columns: 2
                        columnSpacing: theme.spacingLg
                        rowSpacing: theme.spacingXs
                        Text {
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            text: "NEXT RISE"
                            color: theme.textSecondary
                            font.pixelSize: theme.fontLabel
                            font.bold: true
                        }
                        Text {
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            text: "NEXT SET"
                            color: theme.textSecondary
                            font.pixelSize: theme.fontLabel
                            font.bold: true
                        }
                        Text {
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            text: w.eventTime(w.localEvents.rise)
                            color: theme.textPrimary
                            font.pixelSize: theme.fontTitle
                            font.bold: true
                        }
                        Text {
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            text: w.eventTime(w.localEvents.set)
                            color: theme.textPrimary
                            font.pixelSize: theme.fontTitle
                            font.bold: true
                        }
                    }
                    Text {
                        visible: w.locationConfigured
                        Layout.fillWidth: true
                        text: "Approximate times in this device's local time"
                        horizontalAlignment: Text.AlignHCenter
                        color: theme.textSecondary
                        font.pixelSize: theme.fontLabel
                    }
                }
            }
            Text {
                Layout.fillWidth: true
                visible: w.roomy && w.showAccuracyNote
                text: w.phaseDirection + " · " + w.modelLabel
                horizontalAlignment: Text.AlignHCenter
                font.pixelSize: theme.fontLabel; color: theme.textSecondary
                wrapMode: Text.WordWrap
            }
        }
    }
}
