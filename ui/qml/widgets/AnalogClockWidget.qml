import QtQuick

// Analog clock face on a Canvas - repainted each second by the shared tick.
//
// Sizing (W1): layout keys off `sizeClass` (injected by Dashboard), never off
// `expanded`. What the leftover space earns:
//   • 0.5x0.5 (micro) - the face IS the widget; nothing competes with it.
//   • 1x1 (compact)   - face + today's date beneath it.
//   • wide            - face on the left, digital time + date beside it.
//   • tall / full     - face on top, digital time + date beneath it.
// The same class has a different aspect per orientation (0.5x1 is tall-narrow in
// portrait, wide-short in landscape) - the face/info split derives from the box,
// so both projections of a class lay out honestly.
WidgetChrome {
    id: w
    property var metrics: ({})
    property bool expanded: false
    property bool active: true
    property var store: null
    property string instanceId: ""
    property int tick: 0

    title: "Analog"; iconName: "analog"; accentColor: theme.catSystem
    showHeader: expanded

    // Live per-instance config (see WidgetConfigSchema "analogClock").
    readonly property var cfg: {
        var _ = store ? store.revision : 0
        return (store && instanceId) ? JSON.parse(JSON.stringify(store.settingsFor(instanceId))) : ({})
    }
    readonly property bool showSeconds: cfg.showSeconds !== undefined ? cfg.showSeconds : true
    readonly property bool showNumerals: cfg.showNumerals !== undefined ? cfg.showNumerals : false
    readonly property string faceStyle: cfg.faceStyle || "classic"
    readonly property string handStyle: cfg.handStyle || "round"
    readonly property bool customZone: cfg.customZone !== undefined ? cfg.customZone : false
    readonly property string zoneId: cfg.zoneId || ""
    readonly property real utcOffset: cfg.utcOffset !== undefined ? cfg.utcOffset : 0
    readonly property string zoneLabel: cfg.zoneLabel || ""
    property var timeZones: null
    readonly property bool effectiveShowSeconds: w.showSeconds && !theme.effectiveReduceMotion

    function _tz() { return w.timeZones ? w.timeZones : (typeof timeZones !== "undefined" ? timeZones : null) }
    function zoneResolvable() { var tz = w._tz(); return !!(tz && w.zoneId.length && tz.isValid(w.zoneId)) }
    readonly property bool invalidZone: w.customZone && w.zoneId.length > 0
                                        && !w.zoneResolvable()
    status: w.invalidZone ? "Invalid time zone" : ""
    statusColor: w.invalidZone ? theme.warning : theme.textSecondary
    function _localOffsetMs(ms) { return -new Date(ms).getTimezoneOffset() * 60000 }
    function zonedAt(at) {
        if (!w.customZone) return at
        var offset = w.utcOffset
        var tz = w._tz()
        if (w.zoneResolvable()) offset = tz.offsetSecsAt(w.zoneId, at.getTime()) / 3600
        var instant = at.getTime()
        var target = offset * 3600000
        var shifted = instant - w._localOffsetMs(instant) + target
        return new Date(instant - w._localOffsetMs(shifted) + target)
    }
    function zonedNow() { return w.zonedAt(new Date()) }
    function formatAt(fmt, at) {
        at = at || new Date()
        var tz = w._tz()
        if (w.customZone && w.zoneResolvable()) return tz.format(w.zoneId, at.getTime(), fmt)
        return Qt.formatDateTime(w.zonedAt(at), fmt)
    }
    function clockPartsAt(at) {
        at = at || new Date()
        var tz = w._tz()
        if (w.customZone && w.zoneResolvable()) {
            var raw = tz.format(w.zoneId, at.getTime(), "H|m|s|z").split("|")
            if (raw.length === 4) {
                var parsed = {
                    hour: Number(raw[0]), minute: Number(raw[1]),
                    second: Number(raw[2]), millisecond: Number(raw[3])
                }
                if (isFinite(parsed.hour) && isFinite(parsed.minute)
                        && isFinite(parsed.second) && isFinite(parsed.millisecond))
                    return parsed
            }
        }
        var shifted = w.zonedAt(at)
        return {
            hour: shifted.getHours(), minute: shifted.getMinutes(),
            second: shifted.getSeconds(), millisecond: shifted.getMilliseconds()
        }
    }
    function fixedOffsetLabel() {
        var sign = w.utcOffset < 0 ? "-" : "+"
        var absolute = Math.abs(w.utcOffset)
        var hours = Math.floor(absolute)
        var minutes = Math.round((absolute - hours) * 60)
        return "UTC" + sign + hours
               + (minutes ? ":" + (minutes < 10 ? "0" : "") + minutes : "")
    }
    function displayZoneLabel() {
        if (!w.customZone) return ""
        if (w.zoneLabel.length) return w.zoneLabel
        if (w.zoneResolvable()) {
            var p = w.zoneId.split("/"); return p[p.length - 1].replace(/_/g, " ")
        }
        if (w.invalidZone) return "Invalid zone · " + w.fixedOffsetLabel()
        return w.fixedOffsetLabel()
    }

    // ── Per-size layout flags ────────────────────────────────────────────────
    // 0.5x0.5 and 1x1 are both "compact" (shape, not footprint); the micro
    // half-cell is told apart by the box (~344-416px short side vs ~690px+).
    readonly property bool micro: sizeClass === "compact" && Math.min(width, height) < 480
    readonly property bool horiz: sizeClass === "wide"
    readonly property bool showDate: !micro
    readonly property bool showDigital: !micro && sizeClass !== "compact"

    onShowSecondsChanged: cv.requestPaint()
    onShowNumeralsChanged: cv.requestPaint()
    onFaceStyleChanged: cv.requestPaint()
    onHandStyleChanged: cv.requestPaint()
    onCustomZoneChanged: cv.requestPaint()
    onZoneIdChanged: cv.requestPaint()
    onUtcOffsetChanged: cv.requestPaint()
    onEffAccentChanged: cv.requestPaint()
    // Reactivated tile (edit-mode/off-page → live) refreshes with current time+palette.
    onActiveChanged: if (active) cv.requestPaint()

    Item {
        id: box
        anchors.fill: parent
        anchors.margins: theme.spacingSm

        // Space carved out for the info block: a side column in wide, a bottom
        // band otherwise - all derived from the box, no one-class pixel values.
        readonly property real infoW: w.horiz ? Math.max(150, width * 0.40) : 0
        readonly property real infoH: !w.horiz && w.showDate
                                      ? Math.max(36, Math.min(height * 0.20, w.showDigital ? 120 : 56))
                                      : 0
        readonly property real faceRegionW: Math.max(0, width - infoW - (infoW > 0 ? theme.spacingMd : 0))
        readonly property real faceRegionH: Math.max(0, height - infoH - (infoH > 0 ? theme.spacingSm : 0))

        // In vertical modes the face + info stack is centered as ONE group, so a
        // narrow tall tile doesn't strand the face high above a bottom band.
        readonly property real groupH: Math.min(faceRegionW, faceRegionH)
                                       + (infoH > 0 ? infoH + theme.spacingSm : 0)
        readonly property real groupY: Math.max(0, (height - groupH) / 2)

        Canvas {
            id: cv
            Accessible.role: Accessible.StaticText
            Accessible.name: {
                w.tick
                return "Analog clock, " + w.formatAt("hh:mm")
                       + (w.displayZoneLabel().length ? ", " + w.displayZoneLabel() : "")
            }
            width: Math.max(0, Math.min(box.faceRegionW, box.faceRegionH))
            height: width
            x: (box.faceRegionW - width) / 2
            y: w.horiz ? (box.faceRegionH - height) / 2 : box.groupY
            onPaint: {
                var ctx = getContext('2d')
                var cx = width / 2, cy = height / 2, rad = Math.min(cx, cy) - 6
                ctx.clearRect(0, 0, width, height)
                if (rad <= 0) return

                if (w.faceStyle === "classic") {
                    ctx.strokeStyle = theme.cardBorder; ctx.lineWidth = Math.max(3, rad * 0.04)
                    ctx.beginPath(); ctx.arc(cx, cy, rad, 0, 2 * Math.PI); ctx.stroke()
                }
                for (var t = 0; t < 12; t++) {
                    var ta = t * Math.PI / 6
                    ctx.strokeStyle = t % 3 === 0 ? w.effAccent : theme.textTertiary
                    ctx.lineWidth = t % 3 === 0 ? 3 : 2
                    ctx.beginPath()
                    ctx.moveTo(cx + Math.cos(ta) * rad * 0.88, cy + Math.sin(ta) * rad * 0.88)
                    ctx.lineTo(cx + Math.cos(ta) * rad * 0.96, cy + Math.sin(ta) * rad * 0.96)
                    ctx.stroke()
                }
                if (w.showNumerals) {
                    ctx.fillStyle = theme.textSecondary
                    ctx.font = Math.max(theme.fontMinimum, rad * 0.16) + "px sans-serif"
                    ctx.textAlign = "center"; ctx.textBaseline = "middle"
                    for (var n = 1; n <= 12; n++) {
                        var na = n * Math.PI / 6 - Math.PI / 2
                        ctx.fillText(n, cx + Math.cos(na) * rad * 0.72, cy + Math.sin(na) * rad * 0.72)
                    }
                }
                var now = w.clockPartsAt(new Date())
                var h = now.hour % 12, m = now.minute, s = now.second
                var ha = (h + m / 60) * Math.PI / 6 - Math.PI / 2
                var ma = (m + s / 60) * Math.PI / 30 - Math.PI / 2
                var sa = (s + now.millisecond / 1000) * Math.PI / 30 - Math.PI / 2
                ctx.lineCap = w.handStyle === "slender" ? "butt" : "round"
                ctx.strokeStyle = theme.textPrimary
                ctx.lineWidth = w.handStyle === "slender"
                                ? Math.max(3, rad * 0.032)
                                : Math.max(4, rad * 0.055)
                ctx.beginPath(); ctx.moveTo(cx, cy); ctx.lineTo(cx + Math.cos(ha) * rad * 0.5, cy + Math.sin(ha) * rad * 0.5); ctx.stroke()
                ctx.lineWidth = w.handStyle === "slender"
                                ? Math.max(2.5, rad * 0.022)
                                : Math.max(3, rad * 0.038)
                ctx.beginPath(); ctx.moveTo(cx, cy); ctx.lineTo(cx + Math.cos(ma) * rad * 0.72, cy + Math.sin(ma) * rad * 0.72); ctx.stroke()
                if (w.effectiveShowSeconds) {
                    ctx.strokeStyle = w.effAccent; ctx.lineWidth = Math.max(1, rad * 0.02)
                    ctx.beginPath(); ctx.moveTo(cx, cy); ctx.lineTo(cx + Math.cos(sa) * rad * 0.82, cy + Math.sin(sa) * rad * 0.82); ctx.stroke()
                }
                ctx.fillStyle = w.effAccent; ctx.beginPath(); ctx.arc(cx, cy, Math.max(2, rad * 0.05), 0, 2 * Math.PI); ctx.fill()
            }
            // Single-driver rule (S3): only the active tile repaints on the shared tick.
            // Off-screen / expanded / edit-mode clocks are set active=false and stay idle.
            Connections { target: w; function onTickChanged() { if (w.active) cv.requestPaint() } }
            // Theme role colors (ring/ticks/numerals/hands) are read at paint time; repaint
            // when the palette changes so a theme switch doesn't leave a stale face.
            Connections {
                target: theme
                function onCardBorderChanged() { if (w.active) cv.requestPaint() }
                function onTextPrimaryChanged() { if (w.active) cv.requestPaint() }
                function onTextSecondaryChanged() { if (w.active) cv.requestPaint() }
                function onTextTertiaryChanged() { if (w.active) cv.requestPaint() }
                function onEffectiveReduceMotionChanged() { cv.requestPaint() }
            }
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            Component.onCompleted: requestPaint()
        }

        Rectangle {
            objectName: "analogZoneBadge"
            visible: w.micro && w.customZone
            anchors.top: parent.top
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(parent.width * 0.86, badgeText.implicitWidth + 24)
            height: Math.max(34, badgeText.implicitHeight + 12)
            radius: height / 2
            color: Qt.rgba(theme.cardBackgroundAlt.r, theme.cardBackgroundAlt.g,
                           theme.cardBackgroundAlt.b, 0.9)
            border.width: 1
            border.color: w.invalidZone ? theme.warning : w.effAccent
            Text {
                id: badgeText
                anchors.centerIn: parent
                width: parent.width - 18
                horizontalAlignment: Text.AlignHCenter
                text: w.displayZoneLabel()
                color: w.invalidZone ? theme.warning : w.effAccent
                font.pixelSize: theme.fontLabel
                font.bold: true
                elide: Text.ElideRight
            }
        }

        // Digital time + date - beside the face in wide, beneath it otherwise.
        Column {
            id: info
            objectName: "analogClockInfo"
            visible: w.showDate
            spacing: Math.round(theme.spacingXs / 2)
            x: w.horiz ? box.width - box.infoW : 0
            y: w.horiz ? Math.round((box.height - height) / 2)
                       : Math.round(cv.y + cv.height + theme.spacingSm + Math.max(0, (box.infoH - height) / 2))
            width: w.horiz ? box.infoW : box.width

            Text {
                visible: w.customZone
                width: parent.width; horizontalAlignment: Text.AlignHCenter
                text: w.displayZoneLabel(); color: w.effAccent; font.bold: true
                font.pixelSize: Math.max(theme.fontMinimum,
                                         Math.min(parent.width * 0.06, theme.fontTitle)); elide: Text.ElideRight
            }
            Text {
                objectName: "analogZoneAccuracyNotice"
                visible: w.customZone && !w.zoneResolvable()
                         && (w.showDigital || w.expanded)
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: w.invalidZone
                      ? "Unknown IANA zone. Using the fixed offset without daylight saving."
                      : (!w.zoneResolvable()
                         ? "Fixed offset. Daylight-saving changes are not applied." : "")
                color: w.invalidZone ? theme.warning : theme.textSecondary
                font.pixelSize: theme.fontLabel
                wrapMode: Text.WordWrap
            }
            Text {
                visible: w.showDigital
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: {
                    w.tick
                    return w.formatAt(w.effectiveShowSeconds ? "hh:mm:ss" : "hh:mm")
                }
                font.pixelSize: w.horiz ? Math.max(18, Math.min(box.infoW * 0.20, 64))
                                        : Math.max(18, Math.min(box.infoH * 0.52, 64))
                fontSizeMode: Text.HorizontalFit; minimumPixelSize: theme.fontMinimum; elide: Text.ElideRight
                font.bold: true; font.family: theme.fontMono
                color: theme.textPrimary
            }
            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: {
                    w.tick
                    return w.formatAt("ddd, d MMMM")
                }
                font.pixelSize: Math.max(theme.fontMinimum,
                                         Math.min((w.horiz ? box.infoW : box.width) * 0.075,
                                                  theme.fontTitle))
                fontSizeMode: Text.HorizontalFit; minimumPixelSize: theme.fontMinimum; elide: Text.ElideRight
                font.family: theme.fontDisplay
                color: theme.textSecondary
            }
        }
    }
}
