import QtQuick

// Sparkline is the shared history chart for metric widgets. Despite the legacy
// name, roomy instances are full charts with a truthful value domain, time axis,
// raw peak marker, and optional comparison series.
Item {
    id: s

    property var values: []
    property var comparisonValues: []
    property color color: theme.accent
    property color comparisonColor: theme.success
    property string primaryLabel: ""
    property string comparisonLabel: ""
    // The chart can omit a long identity from its compact visual statistics
    // while retaining that identity in primaryLabel and accessibleSummary.
    // Other consumers keep the historical behavior by default.
    property string statisticsLabel: primaryLabel

    // fixed uses minimumValue..maximumValue. auto finds a padded "nice" range.
    // includeZero prevents tiny changes around a large value from filling the
    // entire chart unless the user explicitly selects a rolling range.
    property string scaleMode: "fixed"
    property real minimumValue: 0
    property real maximumValue: 1
    property bool includeZero: true

    // smooth draws a faint raw trace and an emphasized exponential trend. The
    // raw samples and their peak remain visible, so smoothing never hides a spike.
    // line draws only raw samples. bars makes individual samples easiest to count.
    property string chartStyle: "line"
    property int smoothingSamples: 6
    property bool fill: true

    property real sampleIntervalSeconds: 2
    property real displayScale: 1
    property string unit: ""
    property int decimals: 0
    property var valueFormatter: null
    property bool showAxes: true
    property bool showStatistics: true
    readonly property real axisFontPixelSize: Math.max(16, theme.fontLabel)

    readonly property bool axesVisible: showAxes && width >= 220
                                                 && height >= axisFontPixelSize * 5.5
    readonly property bool statisticsVisible: showStatistics && width >= 310
                                                               && height >= axisFontPixelSize * 7.5
    // Some metric producers mutate their retained array in place. QML cannot
    // observe that mutation by itself, so this revision also invalidates the
    // derived domain, statistics, labels, and accessibility summary.
    property int _seriesRevision: 0
    readonly property var domain: {
        var revision = _seriesRevision
        return _domain()
    }
    readonly property var primaryStats: {
        var revision = _seriesRevision
        return _statistics(values)
    }
    readonly property var comparisonStats: {
        var revision = _seriesRevision
        return _statistics(comparisonValues)
    }
    readonly property string accessibleSummary: {
        var revision = _seriesRevision
        return _accessibleSummary()
    }

    Accessible.role: Accessible.StaticText
    Accessible.name: accessibleSummary

    function _valid(value) {
        return typeof value === "number" && isFinite(value)
    }

    function _series(input) {
        var source = input && typeof input.length === "number" ? input : []
        var out = []
        for (var i = 0; i < source.length; i++)
            if (_valid(source[i])) out.push({ index: i, value: Number(source[i]) })
        return out
    }

    function _statistics(input) {
        var points = _series(input)
        if (!points.length) return null
        var minimum = Infinity
        var maximum = -Infinity
        var total = 0
        var peakIndex = 0
        for (var i = 0; i < points.length; i++) {
            var value = points[i].value
            minimum = Math.min(minimum, value)
            if (value > maximum) {
                maximum = value
                peakIndex = points[i].index
            }
            total += value
        }
        return {
            min: minimum,
            max: maximum,
            average: total / points.length,
            peakIndex: peakIndex,
            count: points.length
        }
    }

    function _niceStep(span) {
        if (!_valid(span) || span <= 0) return 1
        var rough = span / 4
        var power = Math.pow(10, Math.floor(Math.log(rough) / Math.LN10))
        var fraction = rough / power
        var niceFraction = fraction <= 1 ? 1 : fraction <= 2 ? 2
                                                : fraction <= 5 ? 5 : 10
        return niceFraction * power
    }

    function _domain() {
        if (scaleMode !== "auto") {
            var fixedMin = _valid(minimumValue) ? Number(minimumValue) : 0
            var fixedMax = _valid(maximumValue) ? Number(maximumValue) : fixedMin + 1
            if (fixedMax <= fixedMin) fixedMax = fixedMin + 1
            return { min: fixedMin, max: fixedMax }
        }

        var first = _series(values)
        var second = _series(comparisonValues)
        var lo = Infinity
        var hi = -Infinity
        var all = first.concat(second)
        for (var i = 0; i < all.length; i++) {
            lo = Math.min(lo, all[i].value)
            hi = Math.max(hi, all[i].value)
        }
        if (!all.length) return { min: 0, max: 1 }
        if (includeZero) {
            lo = Math.min(0, lo)
            hi = Math.max(0, hi)
        }
        if (hi === lo) {
            var pad = Math.max(Math.abs(hi) * 0.1, 1)
            lo -= includeZero && lo >= 0 ? 0 : pad
            hi += pad
        } else {
            var rawPad = (hi - lo) * 0.1
            if (!includeZero || lo < 0) lo -= rawPad
            if (!includeZero || hi > 0) hi += rawPad
        }
        var step = _niceStep(hi - lo)
        var niceMin = Math.floor(lo / step) * step
        var niceMax = Math.ceil(hi / step) * step
        if (includeZero) {
            niceMin = Math.min(0, niceMin)
            niceMax = Math.max(0, niceMax)
        }
        if (niceMax <= niceMin) niceMax = niceMin + step
        return { min: niceMin, max: niceMax }
    }

    function _smoothed(input) {
        var source = input && typeof input.length === "number" ? input : []
        var out = []
        var period = Math.max(1, Math.round(smoothingSamples))
        var alpha = 2 / (period + 1)
        var previous = undefined
        for (var i = 0; i < source.length; i++) {
            var value = source[i]
            if (!_valid(value)) {
                out.push(undefined)
                continue
            }
            previous = previous === undefined ? Number(value)
                                               : alpha * Number(value) + (1 - alpha) * previous
            out.push(previous)
        }
        return out
    }

    function _formatValue(value) {
        if (!_valid(value)) return "-"
        if (typeof valueFormatter === "function")
            return String(valueFormatter(value))
        var scaled = value * displayScale
        var precision = Math.max(0, Math.min(6, decimals))
        return scaled.toFixed(precision) + unit
    }

    function _formatDuration(seconds) {
        var total = Math.max(0, Math.round(Number(seconds) || 0))
        if (total < 60) return total + "s ago"
        if (total < 3600) {
            var minutes = Math.floor(total / 60)
            var remainder = total % 60
            return remainder ? minutes + "m " + remainder + "s ago" : minutes + "m ago"
        }
        var hours = Math.floor(total / 3600)
        var mins = Math.floor((total % 3600) / 60)
        return mins ? hours + "h " + mins + "m ago" : hours + "h ago"
    }

    function _spanSeconds() {
        var count = Math.max(values && values.length ? values.length : 0,
                             comparisonValues && comparisonValues.length
                                ? comparisonValues.length : 0)
        return Math.max(0, count - 1) * Math.max(0, sampleIntervalSeconds)
    }

    function _accessibleSummary() {
        if (!primaryStats) return "History chart, building history"
        var parts = ["History chart from " + _formatDuration(_spanSeconds()) + " to now"]
        if (primaryLabel.length) parts.push(primaryLabel)
        parts.push("current " + _formatValue(values[values.length - 1]))
        parts.push("average " + _formatValue(primaryStats.average))
        parts.push("peak " + _formatValue(primaryStats.max))
        if (comparisonStats) {
            if (comparisonLabel.length) parts.push(comparisonLabel)
            parts.push("current " + _formatValue(comparisonValues[comparisonValues.length - 1]))
            parts.push("peak " + _formatValue(comparisonStats.max))
        }
        parts.push(scaleMode === "auto" ? (includeZero ? "automatic scale from zero"
                                                       : "automatic rolling range")
                                        : "fixed scale")
        return parts.join(", ")
    }

    // Cheap signature for producers that mutate a bound array in place.
    property string _sig: ""
    function _signatureFor(input) {
        var series = input && typeof input.length === "number" ? input : null
        if (!series) return "0"
        var signature = series.length + ":"
        for (var i = 0; i < series.length; i++)
            signature += (_valid(series[i]) ? series[i] : "x") + ","
        return signature
    }
    function _signature() {
        return _signatureFor(values)
    }
    function _paintSignature() {
        var primary = _signature()
        var comparison = comparisonValues && comparisonValues.length
                         ? _signatureFor(comparisonValues) : ""
        return comparison.length ? primary + "|" + comparison : primary
    }

    // The data providers replace or mutate a rolling history every few seconds.
    // Painting that new array directly makes every retained point jump one slot
    // left in a single frame. Keep immutable render snapshots and interpolate
    // retained samples into their new positions. Raw values, statistics, axes,
    // and peak markers still describe the real samples; this is presentation
    // continuity only.
    property var _renderPrimary: []
    property var _renderComparison: []
    property var _previousPrimary: []
    property var _previousComparison: []
    property var _previousDomain: ({ min: 0, max: 1 })
    property var _targetDomain: ({ min: 0, max: 1 })
    property bool _transitionQueued: false
    property real transitionProgress: 1
    readonly property int transitionDuration: theme.motionValue
    readonly property bool transitionRunning: sampleAnimator.running
    readonly property real displayMinimum: _interpolate(
        Number(_previousDomain.min), Number(_targetDomain.min), transitionProgress)
    readonly property real displayMaximum: _interpolate(
        Number(_previousDomain.max), Number(_targetDomain.max), transitionProgress)
    // Bars and their zero baseline must use the same interpolated domain. Using
    // the final domain here made the baseline jump before the plot and axes had
    // finished transitioning.
    readonly property real barBaselineValue:
        Math.max(displayMinimum, Math.min(displayMaximum, 0))
    readonly property var displayPrimaryStats: _interpolatedStatistics(
        _statistics(_previousPrimary), _statistics(_renderPrimary), transitionProgress)
    readonly property var displayComparisonStats: _interpolatedStatistics(
        _statistics(_previousComparison), _statistics(_renderComparison),
        transitionProgress)

    function _interpolate(first, second, progress) {
        return first + (second - first) * progress
    }

    function _interpolatedStatistics(previous, current, progress) {
        if (!current) return null
        if (!previous) return current
        return {
            min: _interpolate(previous.min, current.min, progress),
            max: _interpolate(previous.max, current.max, progress),
            average: _interpolate(previous.average, current.average, progress),
            peakIndex: current.peakIndex,
            count: current.count
        }
    }

    function _pointX(index, count, rolling, progress, chartWidth) {
        var denominator = Math.max(1, count - 1)
        var target = index * chartWidth / denominator
        var prior = rolling && index < count - 1
                    ? (index + 1) * chartWidth / denominator : target
        return _interpolate(prior, target, progress)
    }

    function _barCenterForPoint(pointX, count, chartWidth) {
        var slot = chartWidth / Math.max(1, count)
        if (count <= 1 || chartWidth <= 0) return chartWidth / 2
        return slot / 2 + pointX * (chartWidth - slot) / chartWidth
    }

    function _cloneSeries(input) {
        var source = input && typeof input.length === "number" ? input : []
        var result = []
        for (var i = 0; i < source.length; i++)
            result.push(_valid(source[i]) ? Number(source[i]) : undefined)
        return result
    }

    function _sameSample(first, second) {
        if (!_valid(first) || !_valid(second))
            return !_valid(first) && !_valid(second)
        return Math.abs(Number(first) - Number(second)) < 0.000000000001
    }

    function _isRollingShift(previous, current) {
        if (!previous || !current || previous.length !== current.length
                || current.length < 2)
            return false
        for (var i = 0; i < current.length - 1; i++)
            if (!_sameSample(previous[i + 1], current[i])) return false
        return true
    }

    function _queueTransition() {
        if (_transitionQueued) return
        _transitionQueued = true
        transitionQueue.restart()
    }

    function _commitTransition() {
        _transitionQueued = false
        var nextPrimary = _cloneSeries(values)
        var nextComparison = _cloneSeries(comparisonValues)
        var nextDomain = _domain()
        var havePreviousFrame = _renderPrimary.length > 0
                                || _renderComparison.length > 0

        sampleAnimator.stop()
        _previousPrimary = _renderPrimary.slice()
        _previousComparison = _renderComparison.slice()
        _previousDomain = {
            min: Number(_targetDomain.min),
            max: Number(_targetDomain.max)
        }
        _renderPrimary = nextPrimary
        _renderComparison = nextComparison
        _targetDomain = { min: Number(nextDomain.min), max: Number(nextDomain.max) }

        if (!havePreviousFrame || transitionDuration <= 0 || !visible
                || (nextPrimary.length === 0 && nextComparison.length === 0)) {
            _previousPrimary = nextPrimary.slice()
            _previousComparison = nextComparison.slice()
            _previousDomain = {
                min: Number(nextDomain.min),
                max: Number(nextDomain.max)
            }
            transitionProgress = 1
            cv.requestPaint()
            return
        }

        transitionProgress = 0
        sampleAnimator.start()
    }

    Column {
        id: yAxis
        visible: s.axesVisible
        anchors.left: parent.left
        anchors.top: chartTop.bottom
        anchors.bottom: xAxis.top
        width: Math.max(72, Math.min(140, s.width * 0.25))

        Text {
            width: parent.width - theme.spacingXs
            text: s._formatValue(s.displayMaximum)
            color: theme.textPrimary
            font.pixelSize: s.axisFontPixelSize
            font.family: theme.fontMono
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideLeft
        }
        Item { width: 1; height: Math.max(0, (yAxis.height - 3 * s.axisFontPixelSize) / 2) }
        Text {
            width: parent.width - theme.spacingXs
            text: s._formatValue((s.displayMinimum + s.displayMaximum) / 2)
            color: theme.textTertiary
            font.pixelSize: s.axisFontPixelSize
            font.family: theme.fontMono
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideLeft
        }
        Item { width: 1; height: Math.max(0, (yAxis.height - 3 * s.axisFontPixelSize) / 2) }
        Text {
            width: parent.width - theme.spacingXs
            text: s._formatValue(s.displayMinimum)
            color: theme.textPrimary
            font.pixelSize: s.axisFontPixelSize
            font.family: theme.fontMono
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideLeft
        }
    }

    Column {
        id: chartTop
        visible: s.statisticsVisible
        anchors.left: s.axesVisible ? yAxis.right : parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: visible ? (s.comparisonStats ? 2 : 1) * s.axisFontPixelSize
                          + theme.spacingXs : 0
        spacing: 1

        Text {
            objectName: "sparklinePrimaryStatistics"
            width: parent.width
            text: (s.statisticsLabel.length ? s.statisticsLabel + "  " : "")
                  + "avg " + (s.displayPrimaryStats
                               ? s._formatValue(s.displayPrimaryStats.average) : "-")
                  + "   peak " + (s.displayPrimaryStats
                                   ? s._formatValue(s.displayPrimaryStats.max) : "-")
            color: s.color
            font.pixelSize: s.axisFontPixelSize
            font.family: theme.fontMono
            font.bold: true
            elide: Text.ElideRight
        }
        Text {
            visible: s.comparisonStats !== null
            width: parent.width
            text: (s.comparisonLabel.length ? s.comparisonLabel + "  " : "")
                  + "avg " + (s.displayComparisonStats
                              ? s._formatValue(s.displayComparisonStats.average) : "-")
                  + "   peak " + (s.displayComparisonStats
                                  ? s._formatValue(s.displayComparisonStats.max) : "-")
            color: s.comparisonColor
            font.pixelSize: s.axisFontPixelSize
            font.family: theme.fontMono
            font.bold: true
            elide: Text.ElideRight
        }
    }

    Item {
        id: xAxis
        visible: s.axesVisible
        anchors.left: yAxis.right
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: s.axisFontPixelSize + theme.spacingXs
        Text {
            anchors.left: parent.left
            anchors.leftMargin: theme.spacingSm
            anchors.bottom: parent.bottom
            text: s._formatDuration(s._spanSeconds())
            color: theme.textPrimary
            font.pixelSize: s.axisFontPixelSize
            font.family: theme.fontMono
        }
        Text {
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            text: "now"
            color: theme.textPrimary
            font.pixelSize: s.axisFontPixelSize
            font.family: theme.fontMono
        }
    }

    Canvas {
        id: cv
        anchors.left: s.axesVisible ? yAxis.right : parent.left
        anchors.right: parent.right
        anchors.top: chartTop.bottom
        anchors.bottom: s.axesVisible ? xAxis.top : parent.bottom

        function interpolate(first, second, progress) {
            return s._interpolate(first, second, progress)
        }

        function mapYForDomain(value, minimum, maximum) {
            var span = Math.max(0.0000001, maximum - minimum)
            var normalized = (value - minimum) / span
            return height - Math.max(0, Math.min(1, normalized)) * (height - 4) - 2
        }

        function mapY(value) {
            var progress = s.transitionProgress
            var minimum = interpolate(
                Number(s._previousDomain.min), Number(s._targetDomain.min), progress)
            var maximum = interpolate(
                Number(s._previousDomain.max), Number(s._targetDomain.max), progress)
            return mapYForDomain(value, minimum, maximum)
        }

        function pointsFor(input, previousInput) {
            var source = input && typeof input.length === "number" ? input : []
            var previous = previousInput && typeof previousInput.length === "number"
                           ? previousInput : []
            var out = []
            var denominator = Math.max(1, source.length - 1)
            var progress = s.transitionProgress
            var rolling = s._isRollingShift(previous, source)
            for (var i = 0; i < source.length; i++) {
                if (!s._valid(source[i])) continue
                var targetX = i * width / denominator
                var priorIndex = rolling ? Math.min(i + 1, previous.length - 1) : i
                var priorValue = priorIndex >= 0 && priorIndex < previous.length
                                 && s._valid(previous[priorIndex])
                                 ? Number(previous[priorIndex]) : Number(source[i])
                var pointX = s._pointX(
                    i, source.length, rolling, progress, width)
                var priorY = mapYForDomain(
                    priorValue,
                    Number(s._previousDomain.min),
                    Number(s._previousDomain.max))
                var targetY = mapYForDomain(
                    Number(source[i]),
                    Number(s._targetDomain.min),
                    Number(s._targetDomain.max))
                out.push({ x: pointX,
                           y: interpolate(priorY, targetY, progress),
                           value: Number(source[i]), index: i })
            }
            return out
        }

        function stroke(points, strokeColor, lineWidth, alpha) {
            if (points.length < 2) return
            var ctx = getContext("2d")
            ctx.save()
            ctx.globalAlpha = alpha
            ctx.beginPath()
            for (var i = 0; i < points.length; i++)
                i === 0 ? ctx.moveTo(points[i].x, points[i].y)
                        : ctx.lineTo(points[i].x, points[i].y)
            ctx.strokeStyle = strokeColor
            ctx.lineWidth = lineWidth
            ctx.lineJoin = "round"
            ctx.lineCap = "round"
            ctx.stroke()
            ctx.restore()
        }

        function curvedStroke(points, strokeColor, lineWidth, alpha) {
            if (points.length < 2) return
            var ctx = getContext("2d")
            ctx.save()
            ctx.globalAlpha = alpha
            ctx.beginPath()
            ctx.moveTo(points[0].x, points[0].y)
            for (var i = 1; i < points.length - 1; i++) {
                var midX = (points[i].x + points[i + 1].x) / 2
                var midY = (points[i].y + points[i + 1].y) / 2
                // The current sample is the quadratic control point and the
                // midpoint is the endpoint. This stays inside neighbouring
                // values, so the curve cannot invent an overshooting spike.
                ctx.quadraticCurveTo(points[i].x, points[i].y, midX, midY)
            }
            ctx.lineTo(points[points.length - 1].x, points[points.length - 1].y)
            ctx.strokeStyle = strokeColor
            ctx.lineWidth = lineWidth
            ctx.lineJoin = "round"
            ctx.lineCap = "round"
            ctx.stroke()
            ctx.restore()
        }

        function area(points, areaColor) {
            if (!s.fill || points.length < 2) return
            var ctx = getContext("2d")
            ctx.save()
            ctx.beginPath()
            ctx.moveTo(points[0].x, height)
            for (var i = 0; i < points.length; i++)
                ctx.lineTo(points[i].x, points[i].y)
            ctx.lineTo(points[points.length - 1].x, height)
            ctx.closePath()
            var gradient = ctx.createLinearGradient(0, 0, 0, height)
            gradient.addColorStop(0, Qt.rgba(areaColor.r, areaColor.g, areaColor.b, 0.28))
            gradient.addColorStop(1, Qt.rgba(areaColor.r, areaColor.g, areaColor.b, 0))
            ctx.fillStyle = gradient
            ctx.fill()
            ctx.restore()
        }

        function bars(input, previousInput, barColor, seriesOffset, seriesCount) {
            var points = pointsFor(input, previousInput)
            if (!points.length) return
            var sourceCount = Math.max(1, input.length)
            var slot = width / sourceCount
            var groupWidth = Math.max(1, slot * 0.72)
            var barWidth = Math.max(1, groupWidth / seriesCount)
            var zeroY = mapY(s.barBaselineValue)
            var ctx = getContext("2d")
            ctx.save()
            ctx.fillStyle = barColor
            ctx.globalAlpha = 0.82
            for (var i = 0; i < points.length; i++) {
                var center = s._barCenterForPoint(
                    points[i].x, sourceCount, width)
                var x = center - groupWidth / 2
                        + seriesOffset * barWidth
                var top = Math.min(points[i].y, zeroY)
                var barHeight = Math.max(1, Math.abs(zeroY - points[i].y))
                ctx.fillRect(x, top, barWidth, barHeight)
            }
            ctx.restore()
        }

        function peakMarker(input, previousInput, markerColor) {
            var stats = s._statistics(input)
            if (!stats || input.length < 2) return
            var points = pointsFor(input, previousInput)
            var peak = null
            for (var pointIndex = 0; pointIndex < points.length; pointIndex++)
                if (points[pointIndex].index === stats.peakIndex) {
                    peak = points[pointIndex]
                    break
                }
            if (!peak) return
            var ctx = getContext("2d")
            ctx.save()
            ctx.beginPath()
            ctx.arc(peak.x, peak.y, 4.5, 0, Math.PI * 2)
            ctx.fillStyle = theme.cardBackground
            ctx.fill()
            ctx.lineWidth = 2
            ctx.strokeStyle = markerColor
            ctx.stroke()
            ctx.restore()
        }

        onPaint: {
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            if (width <= 0 || height <= 0) return

            if (s.axesVisible) {
                ctx.save()
                ctx.strokeStyle = theme.cardBorder
                ctx.lineWidth = 1
                ctx.globalAlpha = 0.72
                for (var gridIndex = 0; gridIndex < 3; gridIndex++) {
                    var gridY = 1 + gridIndex * (height - 2) / 2
                    ctx.beginPath()
                    ctx.moveTo(0, gridY)
                    ctx.lineTo(width, gridY)
                    ctx.stroke()
                }
                ctx.restore()
            }

            var primaryRaw = pointsFor(s._renderPrimary, s._previousPrimary)
            var comparisonRaw = pointsFor(
                s._renderComparison, s._previousComparison)
            if (primaryRaw.length < 2 && comparisonRaw.length < 2) return

            if (s.chartStyle === "bars") {
                var count = comparisonRaw.length >= 1 ? 2 : 1
                bars(s._renderPrimary, s._previousPrimary, s.color, 0, count)
                if (count === 2)
                    bars(s._renderComparison, s._previousComparison,
                         s.comparisonColor, 1, count)
            } else if (s.chartStyle === "line") {
                area(primaryRaw, s.color)
                stroke(primaryRaw, s.color, 2.5, 1)
                stroke(comparisonRaw, s.comparisonColor, 2.5, 1)
            } else {
                var primarySmooth = pointsFor(
                    s._smoothed(s._renderPrimary),
                    s._smoothed(s._previousPrimary))
                var comparisonSmooth = pointsFor(
                    s._smoothed(s._renderComparison),
                    s._smoothed(s._previousComparison))
                area(primarySmooth, s.color)
                stroke(primaryRaw, s.color, 1.25, 0.34)
                stroke(comparisonRaw, s.comparisonColor, 1.25, 0.34)
                curvedStroke(primarySmooth, s.color, 2.75, 1)
                curvedStroke(comparisonSmooth, s.comparisonColor, 2.75, 1)
            }
            peakMarker(s._renderPrimary, s._previousPrimary, s.color)
            if (comparisonRaw.length >= 2)
                peakMarker(s._renderComparison, s._previousComparison,
                           s.comparisonColor)
        }
    }

    NumberAnimation {
        id: sampleAnimator
        target: s
        property: "transitionProgress"
        from: 0
        to: 1
        duration: s.transitionDuration
        easing.type: Easing.OutCubic
    }

    // Keep deferred transition work owned by this component. A Qt.callLater
    // closure can outlive a preset-preview Sparkline that has just been
    // destroyed, then call into an invalid QML object and emit a warning.
    Timer {
        id: transitionQueue
        objectName: "sparklineTransitionQueue"
        interval: 0
        repeat: false
        onTriggered: s._commitTransition()
    }

    Timer {
        objectName: "sparklinePollTimer"
        interval: 100
        running: s.visible
        repeat: true
        onTriggered: {
            var signature = s._paintSignature()
            if (signature !== s._sig) {
                s._sig = signature
                s._seriesRevision++
                s._queueTransition()
            }
        }
    }

    function _repaint() {
        s._sig = s._paintSignature()
        s._queueTransition()
    }
    function requestPaint() {
        cv.requestPaint()
    }
    onValuesChanged: _repaint()
    onComparisonValuesChanged: _repaint()
    onWidthChanged: cv.requestPaint()
    onHeightChanged: cv.requestPaint()
    onColorChanged: cv.requestPaint()
    onComparisonColorChanged: cv.requestPaint()
    onScaleModeChanged: _queueTransition()
    onMinimumValueChanged: _queueTransition()
    onMaximumValueChanged: _queueTransition()
    onIncludeZeroChanged: _queueTransition()
    onChartStyleChanged: cv.requestPaint()
    onSmoothingSamplesChanged: cv.requestPaint()
    onFillChanged: cv.requestPaint()
    onTransitionProgressChanged: cv.requestPaint()
    onTransitionDurationChanged: {
        if (transitionDuration <= 0 && transitionRunning) {
            sampleAnimator.stop()
            transitionProgress = 1
        }
    }
    Component.onCompleted: _repaint()
}
