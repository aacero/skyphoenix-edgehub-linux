import QtQuick
import QtTest
import "../../ui/qml" as App
import "../ui" as UI
import "GuiUtil.js" as G

// Systemic viewing-distance gate. Every first-party widget is loaded at every
// size it declares in WidgetCatalog, projected into both physical panel
// orientations. The scan inspects the rendered scene tree, so calculated font
// expressions are judged at their final pixel size rather than by source text.
Item {
    id: root
    width: 2700
    height: 2500

    App.WidgetCatalog { id: catalog }
    App.WidgetSizes { id: sizes }

    readonly property var metricSets: ({
        nominal: '{"cpu_usage_percent":42.5,"cpu_temp_celsius":55,'
               + '"ram_usage_percent":63,"ram_total_bytes":34359738368,'
               + '"ram_used_bytes":21646635008,"cpu_core_count":16,'
               + '"gpu_usage_percent":30,"gpu_temp_celsius":48,'
               + '"net_rx_bytes_per_sec":1048576,"net_tx_bytes_per_sec":524288,'
               + '"disk_total_bytes":1099511627776,"disk_used_bytes":549755813888,'
               + '"disk_usage_percent":50}',
        zero: '{"cpu_usage_percent":0,"cpu_temp_celsius":0,'
            + '"ram_usage_percent":0,"ram_total_bytes":0,"ram_used_bytes":0,'
            + '"cpu_core_count":0,"gpu_usage_percent":0,'
            + '"net_rx_bytes_per_sec":0,"net_tx_bytes_per_sec":0,'
            + '"disk_total_bytes":0,"disk_used_bytes":0,"disk_usage_percent":0}',
        saturated: '{"cpu_usage_percent":100,"cpu_temp_celsius":110,'
                 + '"ram_usage_percent":100,"ram_total_bytes":137438953472,'
                 + '"ram_used_bytes":137438953472,'
                 + '"ram_available_bytes":274877906944,'
                 + '"ram_cached_bytes":173946175488,'
                 + '"ram_buffers_bytes":10737418240,'
                 + '"swap_total_bytes":274877906944,'
                 + '"swap_used_bytes":13636521164,'
                 + '"ram_pressure_some_avg10":100,'
                 + '"cpu_core_count":128,'
                 + '"gpu_usage_percent":100,"gpu_temp_celsius":95,'
                 + '"net_rx_bytes_per_sec":1250000000,'
                 + '"net_tx_bytes_per_sec":1250000000,'
                 + '"disk_total_bytes":8796093022208,'
                 + '"disk_used_bytes":8796093022208,"disk_usage_percent":100}',
        empty: '{}'
    })
    readonly property var metricStates: ["nominal", "zero", "saturated", "empty"]
    readonly property var textScales: [1.0, 1.15, 1.3, 1.45]
    readonly property var fontChoices: ["system", "hyperlegible", "lexend"]
    readonly property var contentProfiles: ["nominal", "maximum", "long", "error"]
    readonly property var outputScales: [1.0, 1.25]
    property int textInputScans: 0
    property int textEditScans: 0
    property var activeRow: null
    property var editorCoverage: ({ TextInput: ({}), TextEdit: ({}) })

    UI.WidgetHarness {
        id: harness
        anchors.left: parent.left
        anchors.top: parent.top
        widgetFile: ""
        expanded: false
        active: false
    }

    // Every measured Text's allocated box AND its content box, as one string.
    // This is the exact quantity the clipping contract compares, so "the
    // signature stopped changing" means "the re-flow this row triggered is
    // finished" - not merely "some time passed". See settleLayout() below.
    function textBoxSignature(node) {
        var parts = []
        G.eachItem(node, function (candidate) {
            if (!candidate || candidate.text === undefined
                    || candidate.font === undefined)
                return
            parts.push(Math.round(candidate.width) + "x"
                       + Math.round(candidate.height) + ":"
                       + Math.round(candidate.contentWidth) + "x"
                       + Math.round(candidate.contentHeight))
        })
        return parts.join("|")
    }

    function projected(size, landscape, outputScale) {
        var def = sizes.table[size]
        if (!def) return ({ width: 0, height: 0 })
        var scale = outputScale || 1
        return landscape
            ? ({ width: Math.round(846 * def.long / scale),
                 height: Math.round(612 * def.short / scale) })
            : ({ width: Math.round(696 * def.short / scale),
                 height: Math.round(818 * def.long / scale) })
    }

    function effectiveVisible(node) {
        var current = node
        while (current) {
            if (current.visible === false || current.opacity <= 0)
                return false
            current = current.parent
        }
        return true
    }

    function printable(text) {
        return ("" + text).replace(/\s/g, "")
    }

    function editorKind(candidate) {
        var className = String(candidate)
        if (className.indexOf("TextArea") >= 0
                || className.indexOf("TextEdit") >= 0
                || candidate.textDocument !== undefined)
            return "TextEdit"
        if (className.indexOf("TextField") >= 0
                || className.indexOf("TextInput") >= 0
                || (candidate.echoMode !== undefined
                    && candidate.cursorPosition !== undefined))
            return "TextInput"
        return ""
    }

    function displayedText(candidate) {
        var value = candidate.text === undefined ? "" : String(candidate.text)
        if (!printable(value).length && candidate.placeholderText !== undefined)
            value = String(candidate.placeholderText)
        return value
    }

    function recordEditorCoverage(kind) {
        if (!activeRow || !editorCoverage[kind])
            return
        var bucket = editorCoverage[kind]
        bucket["scale:" + activeRow.textScale] = true
        bucket["font:" + activeRow.fontChoice] = true
        bucket["profile:" + activeRow.profile] = true
        bucket["output:" + activeRow.outputScale] = true
        bucket["orientation:" + (activeRow.landscape ? "landscape" : "portrait")] = true
        bucket["projection:" + activeRow.type + ":" + activeRow.size + ":"
               + (activeRow.landscape ? "landscape" : "portrait")] = true
    }

    function typeViolations(node, minimum) {
        var violations = []
        G.eachItem(node, function (candidate) {
            try {
                if (candidate.text === undefined || candidate.font === undefined
                        || !effectiveVisible(candidate)
                        || candidate.width <= 0 || candidate.height <= 0
                        || printable(displayedText(candidate)).length === 0)
                    return
                var kind = editorKind(candidate)
                if (kind === "TextInput")
                    root.textInputScans++
                else if (kind === "TextEdit")
                    root.textEditScans++
                if (kind)
                    recordEditorCoverage(kind)
                var pixelSize = Number(candidate.font.pixelSize)
                if (isFinite(pixelSize) && pixelSize > 0 && pixelSize < minimum) {
                    violations.push({
                        text: displayedText(candidate).replace(/\n/g, " ").slice(0, 48),
                        pixelSize: pixelSize,
                        objectName: candidate.objectName || ""
                    })
                }
            } catch (error) {
                violations.push({
                    text: "scene-scan error: " + error,
                    pixelSize: -1,
                    objectName: ""
                })
            }
        })
        return violations
    }

    function clippingViolations(node) {
        var violations = []
        G.eachItem(node, function (candidate) {
            try {
                if (candidate.text === undefined || candidate.font === undefined
                        || !effectiveVisible(candidate)
                        || candidate.width <= 0 || candidate.height <= 0
                        || printable(displayedText(candidate)).length === 0)
                    return

                var reasons = []
                var kind = editorKind(candidate)

                if (!kind && candidate.truncated === true)
                    reasons.push("truncated")

                var contentWidth = Number(candidate.contentWidth)
                var contentHeight = Number(candidate.contentHeight)
                if (!kind && isFinite(contentWidth) && contentWidth > candidate.width + 1
                        && candidate.wrapMode === Text.NoWrap)
                    reasons.push("contentWidth " + Math.ceil(contentWidth)
                                 + " > width " + Math.floor(candidate.width))
                if (!kind && isFinite(contentHeight) && contentHeight > candidate.height + 1)
                    reasons.push("contentHeight " + Math.ceil(contentHeight)
                                 + " > height " + Math.floor(candidate.height))

                // TextInput and TextEdit intentionally scroll content inside a
                // viewport, so contentWidth/contentHeight may exceed the item.
                // Their contract is a usable viewport with at least one line,
                // not a requirement to display the entire document at once.
                if (kind) {
                    var horizontalPadding = Number(candidate.leftPadding || 0)
                                            + Number(candidate.rightPadding || 0)
                    var verticalPadding = Number(candidate.topPadding || 0)
                                          + Number(candidate.bottomPadding || 0)
                    var availableWidth = candidate.width - horizontalPadding
                    var availableHeight = candidate.height - verticalPadding
                    var editorPx = Number(candidate.font.pixelSize)
                    if (availableWidth < editorPx - 1)
                        reasons.push("editor viewport is narrower than one glyph")
                    if (availableHeight < editorPx * 1.15 - 1)
                        reasons.push("editor viewport is shorter than one line")
                }

                // A Text can fit its own item while an outer card, detail panel,
                // or row clips that item. Inspect the mapped rectangle against
                // every non-scrollable clipping ancestor. Flickable/ListView
                // viewports deliberately clip delegates while scrolling, so
                // those are not text-layout defects.
                var ancestor = candidate.parent
                while (ancestor && ancestor !== node.parent) {
                    var scrollingViewport = ancestor.contentX !== undefined
                                            && ancestor.contentY !== undefined
                                            && ancestor.contentWidth !== undefined
                                            && ancestor.contentHeight !== undefined
                    // A ListView/Flickable intentionally clips delegates at its
                    // viewport. Once that boundary is reached, do not continue
                    // outward and misreport an off-screen delegate against the
                    // widget card that contains the viewport.
                    if (scrollingViewport)
                        break
                    if (ancestor.clip === true
                            && ancestor.width > 0 && ancestor.height > 0) {
                        // Map the painted text bounds, not the Text item's
                        // allocation. A centered Text often fills a layout
                        // column whose box legitimately reaches a few pixels
                        // beyond an inner card, while its glyphs remain inside.
                        var paintedWidth = kind ? candidate.width
                                                : Math.min(candidate.width, contentWidth)
                        var paintedHeight = kind ? candidate.height
                                                 : Math.min(candidate.height, contentHeight)
                        var paintedX = candidate.horizontalAlignment === Text.AlignHCenter
                                       ? (candidate.width - paintedWidth) / 2
                                       : candidate.horizontalAlignment === Text.AlignRight
                                         ? candidate.width - paintedWidth : 0
                        var paintedY = candidate.verticalAlignment === Text.AlignVCenter
                                       ? (candidate.height - paintedHeight) / 2
                                       : candidate.verticalAlignment === Text.AlignBottom
                                         ? candidate.height - paintedHeight : 0
                        var topLeft = candidate.mapToItem(
                            ancestor, paintedX, paintedY)
                        var bottomRight = candidate.mapToItem(
                            ancestor, paintedX + paintedWidth,
                            paintedY + paintedHeight)
                        var left = Math.min(topLeft.x, bottomRight.x)
                        var top = Math.min(topLeft.y, bottomRight.y)
                        var right = Math.max(topLeft.x, bottomRight.x)
                        var bottom = Math.max(topLeft.y, bottomRight.y)
                        if (left < -1 || top < -1
                                || right > ancestor.width + 1
                                || bottom > ancestor.height + 1) {
                            reasons.push("mapped box " + Math.floor(left) + ","
                                         + Math.floor(top) + " to "
                                         + Math.ceil(right) + ","
                                         + Math.ceil(bottom)
                                         + " exceeds clipped ancestor "
                                         + Math.floor(ancestor.width) + "x"
                                         + Math.floor(ancestor.height))
                            break
                        }
                    }
                    ancestor = ancestor.parent
                }

                if (reasons.length > 0) {
                    violations.push({
                        text: displayedText(candidate).replace(/\n/g, " ").slice(0, 64),
                        reasons: reasons.join("; "),
                        objectName: candidate.objectName || ""
                    })
                }
            } catch (error) {
                violations.push({
                    text: "scene-scan error: " + error,
                    reasons: "scan failed",
                    objectName: ""
                })
            }
        })
        return violations
    }

    function checkinDays(count) {
        var result = []
        var last = new Date(2026, 6, 27)
        for (var i = count - 1; i >= 0; i--) {
            var day = new Date(last)
            day.setDate(last.getDate() - i)
            result.push(Qt.formatDate(day, "yyyy-MM-dd"))
        }
        return result
    }

    function taskList(count, longLabels) {
        var result = []
        for (var i = 0; i < count; i++) {
            result.push({
                id: "task-" + i,
                text: longLabels
                    ? "Review release checkpoint " + (i + 1)
                    : "Release check " + (i + 1),
                done: i % 3 === 0
            })
        }
        return result
    }

    function captureList(count, longLabels) {
        var result = []
        for (var i = 0; i < count; i++) {
            result.push({
                id: "capture-" + i,
                text: longLabels
                    ? "Follow up on customer feedback item " + (i + 1)
                    : "Follow up " + (i + 1),
                at: 1785000000000 - i * 60000
            })
        }
        return result
    }

    function routineList(count, longLabels) {
        var result = []
        for (var i = 0; i < count; i++) {
            result.push({
                id: "routine-" + i,
                text: longLabels
                    ? "Complete morning preparation step " + (i + 1)
                    : "Morning step " + (i + 1)
            })
        }
        return result
    }

    function doseList(count, longLabels) {
        var result = []
        for (var i = 0; i < count; i++) {
            result.push({
                id: "dose-" + i,
                time: (i < 10 ? "0" : "") + (i % 24) + ":30",
                name: longLabels
                    ? "Prescribed morning medicine " + (i + 1)
                    : "Medicine " + (i + 1),
                days: "0,1,2,3,4,5,6"
            })
        }
        return result
    }

    function calendarEvents(count, longLabels) {
        var result = []
        var start = new Date(1785000000000)
        for (var i = 0; i < count; i++) {
            var eventStart = new Date(start.getTime() + i * 3600000)
            result.push({
                title: longLabels
                    ? "Quarterly release readiness review " + (i + 1)
                    : "Release review " + (i + 1),
                location: longLabels ? "Conference room Vienna" : "Room " + (i + 1),
                start: eventStart,
                end: new Date(eventStart.getTime() + 2700000),
                allDay: false
            })
        }
        return result
    }

    function weatherDays(count) {
        var result = []
        var names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        for (var i = 0; i < count; i++)
            result.push({ day: names[i % names.length], code: i % 4,
                          min: -18 + i, max: 42 - i })
        return result
    }

    function contentSettings(type, profile) {
        var maximum = profile === "maximum"
        var longContent = profile === "long"
        var error = profile === "error"
        switch (type) {
        case "clock":
            return {
                format24: true, showSeconds: true, showDate: true,
                zoneLabel: longContent ? "Central European Summer Time" : "Vienna",
                secondaryZones: maximum
                    ? "America/Los_Angeles|Los Angeles\nAsia/Tokyo|Tokyo\nPacific/Auckland|Auckland"
                    : "America/New_York|New York"
            }
        case "moon":
            return { showAccuracyNote: true, showLocalEvents: true,
                     locationMode: "manual", lat: 48.2082, lon: 16.3738,
                     place: longContent ? "Vienna metropolitan observatory" : "Vienna" }
        case "focus":
            return { preset: "custom", phase: "work", running: false,
                     pausedRemaining: maximum ? 359999 : 1500,
                     doneToday: maximum ? 999 : 3, dailyGoal: maximum ? 99 : 4,
                     day: Qt.formatDate(new Date(), "yyyy-MM-dd") }
        case "tasks":
            return { items: taskList(maximum ? 100 : 6, longContent), nextId: 101 }
        case "rightnow":
            return {
                text: error ? "" : longContent
                    ? "Finish the release readiness review with the whole team"
                    : "Review the release",
                startedAt: 1785000000000
            }
        case "notes":
            return {
                text: maximum
                    ? Array(120).join("Release note content stays readable and scrollable. ")
                    : longContent
                      ? "Capture the release decisions, open questions, owners, and the next concrete action in one readable note."
                      : error ? "Recovery note: verify the last saved revision."
                              : "Release checklist ready."
            }
        case "habit":
            return {
                name: longContent ? "Complete the daily movement practice" : "Daily movement",
                checkins: maximum ? checkinDays(28) : ["2026-07-26"],
                streak: maximum ? 9999 : 7, bestStreak: maximum ? 99999 : 14,
                lastCheckinDay: "2026-07-26"
            }
        case "hydration":
            return { goal: maximum ? 50 : 8, count: maximum ? 49 : 6,
                     day: Qt.formatDate(new Date(), "yyyy-MM-dd"),
                     streak: maximum ? 9999 : 5, glassMl: 1250 }
        case "break":
            return {
                intervalMin: maximum ? 240 : 30, running: false,
                pausedRemaining: maximum ? 86399 : 900,
                due: profile === "error",
                message: longContent
                    ? "Stand, look away, breathe, and reset your posture"
                    : "Time to move"
            }
        case "meds":
            return {
                scheduleFormat: "structured",
                scheduleItems: doseList(maximum ? 24 : 5, longContent),
                dueWindowMin: 240, taken: [], takenDay: "2026-07-27"
            }
        case "braindump":
            return {
                entries: captureList(maximum ? 100 : 8, longContent),
                showTimes: true
            }
        case "routine":
            return {
                routineFormat: "structured",
                routineItems: routineList(maximum ? 24 : 7, longContent),
                done: ["routine-0", "routine-2"],
                day: Qt.formatDate(new Date(), "yyyy-MM-dd")
            }
        case "media":
            return { preferredPlayer: longContent
                ? "org.mpris.MediaPlayer2.production-player" : "MockPlayer" }
        case "httpjson":
            return {
                url: "https://status.example.test/data",
                jsonPath: longContent ? "production.regions.europe.latency" : "service.latency",
                mode: "value", unit: "milliseconds", pollSec: 3600,
                httpText: maximum ? "999999.999999" : "42.7",
                httpVal: maximum ? 999999.999999 : 42.7,
                httpErr: error ? "Endpoint returned an oversized response" : "",
                httpHelp: error ? "Reduce the response size or select a narrower JSON path." : "",
                histRaw: [31, 36, 29, 42, 55, 48, 61, 44]
            }
        case "kpi":
            return {
                source: "http", url: "https://status.example.test/kpi",
                jsonPath: "service.error_budget",
                label: longContent ? "Production service error budget remaining" : "Error budget",
                unit: "%", pollSec: 3600,
                httpText: maximum ? "999999.999999" : "58",
                httpVal: maximum ? 999999.999999 : 58,
                httpErr: error ? "The metric endpoint timed out" : "",
                httpHelp: error ? "Check the endpoint and retry from widget settings." : "",
                histRaw: [40, 55, 42, 61, 58]
            }
        case "calendar":
        case "nownext":
            return { url: "https://calendar.example.test/private.ics",
                     maxEvents: maximum ? 12 : 5 }
        case "weather":
            return {
                locationMode: "manual", lat: 48.2082, lon: 16.3738,
                place: longContent ? "Vienna International Weather Station" : "Vienna",
                forecastDays: maximum ? 7 : 4
            }
        case "countdown":
            return {
                label: longContent ? "Public production release and community launch" : "Production release",
                date: "2038-12-31", precision: "seconds"
            }
        case "eod":
            return { startHour: 0, startMinute: 0, endHour: 23,
                     endMinute: 45, showPercent: true, progressStyle: "detailed" }
        case "quote":
            return {
                category: "custom",
                customText: longContent
                    ? "Make the next decision clear enough to act on, then leave the system easier for the person who follows. | EdgeHub editorial"
                    : error ? " | Missing author" : "A useful release makes quality visible. | EdgeHub editorial",
                authorDisplay: "always"
            }
        default:
            return ({})
        }
    }

    function applyDirectContent(type, profile) {
        var item = harness.item
        var maximum = profile === "maximum"
        var longContent = profile === "long"
        var error = profile === "error"

        harness.mediaCtl.clearTrack()
        if (type === "media") {
            harness.mediaCtl.loadTrack(
                longContent
                    ? "A Carefully Produced Release for Every Linux Desktop"
                    : maximum ? "Track 999 of 999" : error ? "" : "Release Day",
                longContent ? "The EdgeHub Community Ensemble"
                            : maximum ? "An Artist With 999 Releases"
                                      : error ? "" : "SKYPhoenix")
            if (error) {
                harness.mediaCtl.clearTrack()
                harness.mediaCtl.busConnected = false
            }
        }

        if (type === "calendar") {
            item.events = error ? [] : calendarEvents(maximum ? 12 : 5, longContent)
            item.errorText = error ? "Calendar source could not be reached" : ""
            item.stateHelp = error
                ? "Check the private calendar reference and network permission." : ""
        } else if (type === "weather") {
            item.loaded = !error
            item.errorText = error ? "Weather provider did not answer" : ""
            item.stateHelp = error
                ? "Check the location and retry when the network is available." : ""
            item.curTemp = maximum ? -99.9 : 21.5
            item.feels = maximum ? 99.9 : 20.1
            item.humidity = maximum ? 100 : 67
            item.windSpeed = maximum ? 999.9 : 12.4
            item.precipitation = maximum ? 999.9 : 1.2
            item.days = error ? [] : weatherDays(maximum ? 8 : 5)
        }
    }

    function primeVisibleEditors(node, profile) {
        if (profile !== "maximum" && profile !== "long")
            return
        var singleLine = profile === "maximum"
            ? "Validate the longest supported field value before the production release"
            : "Review the release checklist with every owner"
        var multiLine = profile === "maximum"
            ? Array(18).join("Long editor content must remain readable and scrollable. ")
            : "Long editor content remains readable, wraps naturally, and can be scrolled without clipping."
        G.eachItem(node, function (candidate) {
            try {
                var kind = editorKind(candidate)
                if (!kind || !effectiveVisible(candidate) || candidate.readOnly === true)
                    return
                candidate.text = kind === "TextEdit" ? multiLine : singleLine
            } catch (error) {
                // The scene scan reports unusable editors; a read-only or
                // implementation-owned control is not a fixture failure.
            }
        })
    }

    TestCase {
        name: "WidgetLegibilityMatrix"
        when: windowShown
        visible: true

        property string loadedFile: ""

        // Wait until the row's re-flow is FINISHED, instead of guessing how
        // long it takes.
        //
        // The matrix drives 1152 rows through ONE harness: every row changes
        // the tile box, the text scale, the font family and the content, and
        // QQuickLayout re-flows on the polish pass, not synchronously. This
        // used to be a flat `wait(32)`, which is enough on an idle developer
        // machine and NOT enough on a CI runner hosting four nested
        // compositors - so hundreds of assertions measured half-reflowed
        // geometry. A Text still carrying the previous row's allocation while
        // already reporting the new row's contentHeight reads exactly like a
        // clipping defect, which is how this file reported ~310 "accessibility
        // failures" that were nothing of the sort.
        //
        // Proven by construction on 2026-08-02: shortening the settle to
        // `wait(0)` locally reproduces the CI signature (487 failures, the same
        // label strings, same 2-4px overflows); restoring it clears them; and
        // two CI runs of IDENTICAL product code disagreed on 321 of ~474
        // failing tags, which no font or layout rule can explain.
        //
        // Two exits, both meaning "nothing is still moving":
        //   * the signature is unchanged across a PRESENTED frame, or
        //   * no frame is presented at all within the quiet window - the scene
        //     graph is clean, so no polish can be pending.
        // Both are paced by the compositor rather than by the clock, so a
        // slower machine waits longer instead of measuring earlier. A genuinely
        // clipped label is stable and is still reported, so this cannot hide a
        // real defect; it can only stop the suite from inventing one.
        function settleLayout(node) {
            // The frame that carries this row's state. Generous, because it is
            // paid once and only while the scene is actually dirty.
            waitForRendering(node, 2000)
            var previous = root.textBoxSignature(node)
            for (var attempt = 0; attempt < 40; attempt++) {
                var framed = waitForRendering(node, 120)
                var current = root.textBoxSignature(node)
                if (!framed || current === previous)
                    return true
                previous = current
            }
            return false
        }

        function initTestCase() {
            var projections = 0
            for (var i = 0; i < catalog.items.length; i++)
                projections += catalog.items[i].sizes.length * 2
            root.textInputScans = 0
            root.textEditScans = 0
            root.editorCoverage = ({ TextInput: ({}), TextEdit: ({}) })
            verify(catalog.items.length === 30,
                   "matrix is tied to all 30 first-party widgets")
            compare(projections, 288,
                    "matrix contains every declared size in both orientations")
            compare(root.textScales.length, 4,
                    "matrix carries all four user-facing text scales")
            compare(root.fontChoices.length, 3,
                    "matrix carries every user-facing font choice")
            compare(root.contentProfiles.length, 4,
                    "matrix carries nominal, maximum, long, and error content")
            compare(root.outputScales.length, 2,
                    "matrix carries native and 125 percent output scaling")
            compare(root.metricStates.length, 4,
                    "matrix retains nominal, zero, saturated, and empty metrics")
            compare(projections * root.textScales.length, 1152,
                    "bounded pairwise matrix remains 1,152 rendered rows")
        }

        function test_minimum_rendered_type_data() {
            var rows = []
            var projection = 0
            for (var i = 0; i < catalog.items.length; i++) {
                var item = catalog.items[i]
                var file = item.source.toString().split("/").pop()
                for (var s = 0; s < item.sizes.length; s++) {
                    var size = item.sizes[s]
                    for (var orientation = 0; orientation < 2; orientation++) {
                        var landscape = orientation === 1
                        for (var variant = 0; variant < root.textScales.length; variant++) {
                            var fontChoice = root.fontChoices[(projection + variant)
                                                              % root.fontChoices.length]
                            var profile = root.contentProfiles[(projection + variant)
                                                               % root.contentProfiles.length]
                            var outputScale = root.outputScales[(projection + variant)
                                                               % root.outputScales.length]
                            var state = root.metricStates[variant]
                            rows.push({
                                tag: item.type + "-"
                                     + (landscape ? "landscape" : "portrait") + "-"
                                     + size + "-" + state + "-" + profile + "-"
                                     + fontChoice + "-text" + root.textScales[variant]
                                     + "-output" + outputScale,
                                type: item.type,
                                file: file,
                                size: size,
                                landscape: landscape,
                                metrics: state,
                                profile: profile,
                                fontChoice: fontChoice,
                                textScale: root.textScales[variant],
                                outputScale: outputScale
                            })
                        }
                        projection++
                    }
                }
            }
            compare(projection, 288, "data generator produced every projection")
            compare(rows.length, 1152, "data generator stayed within its bounded budget")
            return rows
        }

        function test_minimum_rendered_type(row) {
            harness.theme.textScale = row.textScale
            harness.theme.fontChoice = row.fontChoice
            harness.expanded = false
            harness.active = false
            harness.metricsJson = root.metricSets[row.metrics]

            var box = projected(row.size, row.landscape, row.outputScale)
            harness.width = box.width
            harness.height = box.height
            var fixtureId = "legibility-" + row.type + "-" + row.profile

            if (loadedFile !== row.file) {
                harness.widgetFile = ""
                tryVerify(function () { return !harness.ready }, 3000,
                          "previous widget unloads")
                harness.storeCtl.resetSettings(
                    fixtureId, contentSettings(row.type, row.profile))
                harness.instanceId = fixtureId
                harness.widgetFile = row.file
                loadedFile = row.file
                tryVerify(function () { return harness.ready && harness.item !== null },
                          5000, row.type + " loads")
            } else {
                harness.storeCtl.resetSettings(
                    fixtureId, contentSettings(row.type, row.profile))
                harness.instanceId = fixtureId
                harness.item.instanceId = fixtureId
            }

            if (harness.item.hasOwnProperty("sizeClass"))
                harness.item.sizeClass = sizes.classFor(row.size, row.landscape)
            applyDirectContent(row.type, row.profile)
            wait(0)
            primeVisibleEditors(harness.item, row.profile)
            verify(settleLayout(harness.item),
                   row.tag + " layout settles before it is measured")

            compare(harness.item.width, box.width, row.tag + " projected width")
            compare(harness.item.height, box.height, row.tag + " projected height")
            compare(harness.theme.textScale, row.textScale,
                    row.tag + " uses the requested text scale")
            compare(harness.theme.fontChoice, row.fontChoice,
                    row.tag + " uses the requested font choice")
            var minimum = harness.theme.fontMinimum
            compare(minimum, Math.round(13 * row.textScale),
                    row.tag + " uses the scale-derived type floor")
            root.activeRow = row
            var failures = typeViolations(harness.item, minimum)
            var typeDetails = failures.map(function (failure) {
                return "'" + failure.text + "'=" + failure.pixelSize + "px"
                       + (failure.objectName ? " [" + failure.objectName + "]" : "")
            }).join(", ")

            var clipping = clippingViolations(harness.item)
            root.activeRow = null
            if (clipping.length > 0)
                grabImage(harness.item).save("gui-evidence/clipping-" + row.tag + ".png")
            var clippingDetails = clipping.map(function (failure) {
                return "'" + failure.text + "' (" + failure.reasons + ")"
                       + (failure.objectName ? " [" + failure.objectName + "]" : "")
            }).join(", ")
            var details = []
            if (typeDetails.length)
                details.push("type below " + minimum + "px [" + typeDetails + "]")
            if (clippingDetails.length)
                details.push("clipping [" + clippingDetails + "]")
            compare(failures.length + clipping.length, 0,
                    row.tag + " meets rendered type and clipping contracts"
                    + (details.length ? ": " + details.join("; ") : ""))
        }

        function test_zz_editor_coverage_accounting() {
            verify(root.textInputScans > 0,
                   "the rendered matrix inspected visible TextInput/TextField controls")
            verify(root.textEditScans > 0,
                   "the rendered matrix inspected visible TextEdit/TextArea controls")
            var kinds = ["TextInput", "TextEdit"]
            for (var k = 0; k < kinds.length; k++) {
                var kind = kinds[k]
                var coverage = root.editorCoverage[kind]
                for (var s = 0; s < root.textScales.length; s++)
                    verify(coverage["scale:" + root.textScales[s]] === true,
                           kind + " was scanned at text scale " + root.textScales[s])
                for (var f = 0; f < root.fontChoices.length; f++)
                    verify(coverage["font:" + root.fontChoices[f]] === true,
                           kind + " was scanned with font " + root.fontChoices[f])
                for (var p = 0; p < root.contentProfiles.length; p++)
                    verify(coverage["profile:" + root.contentProfiles[p]] === true,
                           kind + " was scanned with profile " + root.contentProfiles[p])
                for (var o = 0; o < root.outputScales.length; o++)
                    verify(coverage["output:" + root.outputScales[o]] === true,
                           kind + " was scanned at output scale " + root.outputScales[o])
                verify(coverage["orientation:portrait"] === true,
                       kind + " was scanned in portrait")
                verify(coverage["orientation:landscape"] === true,
                       kind + " was scanned in landscape")
            }
        }
    }
}
