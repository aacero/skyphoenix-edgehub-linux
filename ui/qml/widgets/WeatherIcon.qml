import QtQuick

// Deterministic weather artwork. It uses the app palette and Canvas primitives,
// so the same condition has the same shape on every distro and font stack.
Item {
    id: icon
    property int code: -1
    property color primaryColor: "#F6C85F"
    property color cloudColor: "#B8C4D8"
    property color detailColor: "#64B5F6"
    readonly property string kind: kindForCode(code)
    readonly property string description: descriptionForCode(code)

    Accessible.role: Accessible.Graphic
    Accessible.name: description

    function kindForCode(value) {
        if (value === 0) return "clear"
        if (value >= 1 && value <= 2) return "partly-cloudy"
        if (value === 3) return "cloudy"
        if (value === 45 || value === 48) return "fog"
        if ((value >= 51 && value <= 67) || (value >= 80 && value <= 82)) return "rain"
        if ((value >= 71 && value <= 77) || (value >= 85 && value <= 86)) return "snow"
        if (value >= 95) return "storm"
        return "unknown"
    }
    function descriptionForCode(value) {
        var names = {
            "clear": "Clear sky",
            "partly-cloudy": "Partly cloudy",
            "cloudy": "Cloudy",
            "fog": "Fog",
            "rain": "Rain",
            "snow": "Snow",
            "storm": "Thunderstorm",
            "unknown": "Weather unavailable"
        }
        return names[kindForCode(value)]
    }

    Canvas {
        id: canvas
        anchors.fill: parent
        antialiasing: true
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        Connections {
            target: icon
            function onCodeChanged() { canvas.requestPaint() }
            function onPrimaryColorChanged() { canvas.requestPaint() }
            function onCloudColorChanged() { canvas.requestPaint() }
            function onDetailColorChanged() { canvas.requestPaint() }
        }

        function circle(ctx, x, y, radius, fill) {
            ctx.beginPath()
            ctx.arc(x, y, radius, 0, Math.PI * 2)
            ctx.fillStyle = fill
            ctx.fill()
        }
        function cloud(ctx, scale) {
            var y = height * 0.56
            ctx.fillStyle = icon.cloudColor
            ctx.beginPath()
            ctx.arc(width * 0.34, y, width * 0.14 * scale, Math.PI, Math.PI * 2)
            ctx.arc(width * 0.50, y - height * 0.08, width * 0.20 * scale, Math.PI, Math.PI * 2)
            ctx.arc(width * 0.67, y, width * 0.14 * scale, Math.PI, Math.PI * 2)
            ctx.lineTo(width * 0.78, y + height * 0.12)
            ctx.lineTo(width * 0.22, y + height * 0.12)
            ctx.closePath()
            ctx.fill()
        }
        function sun(ctx, small) {
            var x = small ? width * 0.32 : width * 0.5
            var y = small ? height * 0.32 : height * 0.48
            var r = Math.min(width, height) * (small ? 0.13 : 0.20)
            ctx.strokeStyle = icon.primaryColor
            ctx.lineWidth = Math.max(2, Math.min(width, height) * 0.055)
            for (var i = 0; i < 8; i++) {
                var a = i * Math.PI / 4
                ctx.beginPath()
                ctx.moveTo(x + Math.cos(a) * r * 1.45, y + Math.sin(a) * r * 1.45)
                ctx.lineTo(x + Math.cos(a) * r * 1.9, y + Math.sin(a) * r * 1.9)
                ctx.stroke()
            }
            circle(ctx, x, y, r, icon.primaryColor)
        }
        onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            if (icon.kind === "clear") {
                sun(ctx, false)
                return
            }
            if (icon.kind === "partly-cloudy") sun(ctx, true)
            cloud(ctx, 1)
            ctx.strokeStyle = icon.detailColor
            ctx.fillStyle = icon.detailColor
            ctx.lineCap = "round"
            ctx.lineWidth = Math.max(2, Math.min(width, height) * 0.055)
            if (icon.kind === "fog") {
                for (var f = 0; f < 3; f++) {
                    ctx.beginPath()
                    ctx.moveTo(width * 0.24, height * (0.70 + f * 0.10))
                    ctx.lineTo(width * 0.76, height * (0.70 + f * 0.10))
                    ctx.stroke()
                }
            } else if (icon.kind === "rain" || icon.kind === "storm") {
                for (var r = 0; r < 3; r++) {
                    ctx.beginPath()
                    ctx.moveTo(width * (0.34 + r * 0.16), height * 0.72)
                    ctx.lineTo(width * (0.29 + r * 0.16), height * 0.88)
                    ctx.stroke()
                }
                if (icon.kind === "storm") {
                    ctx.fillStyle = icon.primaryColor
                    ctx.beginPath()
                    ctx.moveTo(width * 0.55, height * 0.66)
                    ctx.lineTo(width * 0.43, height * 0.83)
                    ctx.lineTo(width * 0.53, height * 0.83)
                    ctx.lineTo(width * 0.46, height * 0.98)
                    ctx.lineTo(width * 0.66, height * 0.76)
                    ctx.lineTo(width * 0.56, height * 0.76)
                    ctx.closePath()
                    ctx.fill()
                }
            } else if (icon.kind === "snow") {
                ctx.font = Math.max(12, Math.round(Math.min(width, height) * 0.26)) + "px sans-serif"
                ctx.textAlign = "center"
                ctx.fillText("*", width * 0.36, height * 0.91)
                ctx.fillText("*", width * 0.64, height * 0.91)
            } else if (icon.kind === "unknown") {
                ctx.fillStyle = icon.primaryColor
                ctx.font = "bold " + Math.max(14, Math.round(Math.min(width, height) * 0.42)) + "px sans-serif"
                ctx.textAlign = "center"
                ctx.fillText("?", width * 0.5, height * 0.92)
            }
        }
    }
}
