import QtQuick
import QtTest
import "../../ui/qml" as App

//
// ui/qml/widgets/KpiWidget.qml network + file path, offline via xhrFactory. Covers
// the HTTP source, the LOCAL FILE source (file:// endpoint, works offline), JSON
// vs bare-number bodies, the inverted "lower is worse" thresholds, and no-match.
Item {
    id: root
    width: 640; height: 520

    function makeFake() {
        return {
            method: "", url: "", sent: false, aborted: false,
            readyState: 0, status: 0, responseText: "", headers: ({}),
            timeout: 0, ontimeout: null, onreadystatechange: null,
            open: function (m, u) { this.method = m; this.url = u; this.readyState = 1 },
            setRequestHeader: function (k, v) { this.headers[k] = v },
            send: function () { this.sent = true },
            abort: function () { this.aborted = true },
            resolveWith: function (status, body) {
                this.status = status; this.responseText = body; this.readyState = 4
                if (this.onreadystatechange) this.onreadystatechange()
            },
            fireTimeout: function () { if (this.ontimeout) this.ontimeout() }
        }
    }

    WidgetHarness {
        id: h; anchors.fill: parent
        widgetFile: "KpiWidget.qml"; expanded: true
    }
    App.WidgetConfigSchema { id: sc }
    QtObject {
        id: blockedHub
        function request(options) {
            options.onError("blocked")
            return null
        }
    }
    // Same idea, but the reason is chosen by the test: Test Connection maps each
    // egress refusal to its own message, and those messages ARE the feature.
    QtObject {
        id: reasonHub
        property string reason: "blocked"
        function request(options) {
            options.onError(reasonHub.reason)
            return null
        }
    }
    QtObject {
        id: metricReader
        property int calls: 0
        property string lastPath: ""
        property var nextResult: ({ ok: true, body: "7", error: "", message: "" })
        function readMetricFile(path) {
            calls++
            lastPath = String(path)
            return nextResult
        }
        function reset() {
            calls = 0
            lastPath = ""
            nextResult = { ok: true, body: "7", error: "", message: "" }
        }
    }
    function iid() { return h.instanceId }
    function clearSettings() {
        var s = h.storeCtl.settingsFor(iid()); for (var k in s) delete s[k]; h.storeCtl._touchSettings()
    }
    function effectivelyVisible(node, top) {
        var current = node
        while (current) {
            if (current.visible === false || current.opacity <= 0) return false
            if (current === top) break
            current = current.parent
        }
        return true
    }
    function clippedTextFailures(top) {
        var failures = []
        function walk(node) {
            if (!node) return
            if (node !== top && node.text !== undefined && node.font !== undefined
                    && node.width > 0 && node.height > 0
                    && effectivelyVisible(node, top)) {
                var contentWidth = Number(node.contentWidth)
                var contentHeight = Number(node.contentHeight)
                if (node.truncated === true || contentHeight > node.height + 1)
                    failures.push(String(node.text) + " does not fit its own box")
                if (isFinite(contentWidth) && contentWidth > node.width + 1
                        && node.wrapMode === Text.NoWrap)
                    failures.push(String(node.text)
                        + " exceeds its single-line width")
                var ancestor = node.parent
                while (ancestor && ancestor !== top.parent) {
                    var scrollingViewport = ancestor.contentX !== undefined
                                            && ancestor.contentY !== undefined
                                            && ancestor.contentWidth !== undefined
                                            && ancestor.contentHeight !== undefined
                    if (scrollingViewport) break
                    if (ancestor.clip === true
                            && ancestor.width > 0 && ancestor.height > 0) {
                        var paintedWidth = Math.min(node.width, contentWidth)
                        var paintedHeight = Math.min(node.height, contentHeight)
                        var paintedX = node.horizontalAlignment === Text.AlignHCenter
                            ? (node.width - paintedWidth) / 2
                            : node.horizontalAlignment === Text.AlignRight
                              ? node.width - paintedWidth : 0
                        var paintedY = node.verticalAlignment === Text.AlignVCenter
                            ? (node.height - paintedHeight) / 2
                            : node.verticalAlignment === Text.AlignBottom
                              ? node.height - paintedHeight : 0
                        var first = node.mapToItem(ancestor, paintedX, paintedY)
                        var last = node.mapToItem(
                            ancestor, paintedX + paintedWidth,
                            paintedY + paintedHeight)
                        var left = Math.min(first.x, last.x)
                        var topEdge = Math.min(first.y, last.y)
                        var right = Math.max(first.x, last.x)
                        var bottom = Math.max(first.y, last.y)
                        if (left < -1 || topEdge < -1
                                || right > ancestor.width + 1
                                || bottom > ancestor.height + 1) {
                            failures.push(String(node.text)
                                + " escapes a clipped ancestor")
                            break
                        }
                    }
                    ancestor = ancestor.parent
                }
            }
            var children = node.children
            for (var i = 0; children && i < children.length; i++)
                walk(children[i])
        }
        walk(top)
        return failures
    }
    function mappedRect(item, ancestor) {
        var first = item.mapToItem(ancestor, 0, 0)
        var last = item.mapToItem(ancestor, item.width, item.height)
        return {
            left: Math.min(first.x, last.x),
            top: Math.min(first.y, last.y),
            right: Math.max(first.x, last.x),
            bottom: Math.max(first.y, last.y)
        }
    }
    function rectInside(item, ancestor) {
        var rect = mappedRect(item, ancestor)
        return rect.left >= -1 && rect.top >= -1
            && rect.right <= ancestor.width + 1
            && rect.bottom <= ancestor.height + 1
    }
    function rectsOverlap(first, second) {
        return first.left < second.right - 1
            && first.right > second.left + 1
            && first.top < second.bottom - 1
            && first.bottom > second.top + 1
    }
    function nearestClippedAncestor(item, stop) {
        var ancestor = item ? item.parent : null
        while (ancestor && ancestor !== stop.parent) {
            if (ancestor.clip === true) return ancestor
            ancestor = ancestor.parent
        }
        return null
    }

    TestCase {
        name: "KpiNet"
        when: windowShown
        property var lastFake: null
        function init() {
            tryVerify(function () { return h.ready }, 3000)
            clearSettings(); h.active = false
            h.item.netHub = null
            metricReader.reset()
            h.item.fileReader = metricReader
            h.item.xhrFactory = function () { lastFake = root.makeFake(); return lastFake }
        }

        // ── HTTP source ──────────────────────────────────────────────────────
        function test_http_json_path_number() {
            h.storeCtl.patchSettings(iid(), { source: "http", url: "https://api/x", jsonPath: "stats.count" })
            h.item.refresh()
            compare(lastFake.url, "https://api/x")
            lastFake.resolveWith(200, '{"stats":{"count":128}}')
            compare(h.item.valNum, 128)
            compare(h.item.valText, "128")
            compare(h.item.providerState, "fresh")
            compare(h.item.status, "")
        }

        function test_pending_request_is_loading() {
            h.storeCtl.patchSettings(iid(), { source: "http", url: "https://api/loading" })
            h.item.refresh()
            compare(h.item.providerState, "loading")
            compare(h.item.status, "Loading")
        }

        function test_http_bare_number_body() {
            h.storeCtl.patchSettings(iid(), { source: "http", url: "https://api/x", jsonPath: "" })
            h.item.refresh()
            lastFake.resolveWith(200, "42")
            compare(h.item.valNum, 42, "a bare numeric body is taken as the value")
        }

        function test_raw_history_is_shared_and_wins_over_instance_local_state() {
            h.storeCtl.patchSettings(iid(), {
                source: "http", url: "https://api/x",
                histRaw: [10, 20], hist: [0, 1]
            })
            // Simulate a stale second host. The next sample must extend the
            // shared raw series, not normalize from this divergent local array.
            h.item.hist = [900]
            h.item._apply(30)
            compare(JSON.stringify(h.storeCtl.settingsFor(iid()).histRaw),
                    JSON.stringify([10, 20, 30]),
                    "the shared raw history is the source of truth")
            compare(JSON.stringify(h.item.chartHistory), JSON.stringify([10, 20, 30]),
                    "the chart receives raw values so its labelled scale stays truthful")
        }

        function test_poll_interval_honors_schema_minimum() {
            h.storeCtl.patchSettings(iid(), {
                source: "http", url: "https://api/x", pollSec: 2
            })
            compare(h.item.pollSec, 5,
                    "runtime clamp matches the schema's five-second minimum")
        }

        function test_number_format_prefix_target_and_freshness() {
            h.item.nowMsOverride = 500000
            h.storeCtl.patchSettings(iid(), { source: "http", url: "https://api/x",
                decimals: 2, prefix: "$", target: "40" })
            h.item.refresh(); lastFake.resolveWith(200, "42.125")
            compare(h.item.valText, "42.13")
            compare(h.item.prefix, "$")
            compare(h.item.deltaText, "+2.13 vs target")
            compare(h.item.lastSuccessAt, 500000)
            compare(h.item.stale, false)
            h.item.nowMsOverride = 500000 + h.item.staleAfterSec * 1000
            compare(h.item.stale, true)
            compare(h.item.providerState, "stale")
            compare(h.item.status, "Stale")
            h.item.nowMsOverride = -1
        }

        // ── local FILE source ────────────────────────────────────────────────
        function test_file_source_builds_file_url() {
            h.storeCtl.patchSettings(iid(), { source: "file", filePath: "/run/metrics/depth", jsonPath: "" })
            h.item.refresh()
            compare(metricReader.lastPath, "/run/metrics/depth")
            compare(metricReader.calls, 1)
            compare(h.item.valNum, 7)
        }

        function test_file_already_prefixed_is_left_alone() {
            h.storeCtl.patchSettings(iid(), { source: "file", filePath: "file:///run/x", jsonPath: "" })
            h.item.refresh()
            compare(metricReader.lastPath, "file:///run/x")
        }

        function test_file_outside_metric_directories_is_blocked() {
            var before = metricReader.calls
            h.storeCtl.patchSettings(iid(), {
                source: "file", filePath: "/home/user/.ssh/id_ed25519", jsonPath: ""
            })
            compare(h.item.localPathApproved, false)
            h.item.refresh()
            compare(metricReader.calls, before,
                    "an unapproved local path never reaches the native reader")
            verify(h.item.errText.indexOf("approved metric directories") >= 0)
        }

        // init() injects a fileReader into every test, so _fileReader() never
        // returned null and the "no native reader here" branch
        // (KpiWidget.qml:225-229) was unreachable by construction - the double
        // was too capable. That branch is not hypothetical: its own help text
        // says "Start this widget in the Hub", i.e. it is what a file-source KPI
        // shows in the Manager's preview, where there is no MetricFileReader.
        function test_without_a_native_reader_the_widget_says_so() {
            h.item.fileReader = null
            verify(h.item._fileReader() === null,
                   "precondition: neither an injected reader nor a configBridge "
                   + "that can read metric files")
            h.storeCtl.patchSettings(iid(), { source: "file", filePath: "/run/x", jsonPath: "" })
            compare(h.item.localPathApproved, true, "precondition: the path itself is fine")
            var before = metricReader.calls
            h.item.refresh()
            compare(metricReader.calls, before, "nothing was read")
            compare(h.item.errText, "Local reader unavailable")
            verify(h.item.errorHelp.indexOf("Hub") >= 0,
                   "and the help says where it WILL work, rather than blaming the file")
        }

        // The reader is selected by capability, not by presence: an object that
        // is not a metric reader must not be mistaken for one.
        function test_an_object_without_readMetricFile_is_not_a_reader() {
            h.item.fileReader = { somethingElse: function () { return 1 } }
            verify(h.item._fileReader() === null,
                   "a reader is anything WITH readMetricFile - not anything at all")
        }

        function test_native_file_reader_success_is_applied() {
            h.storeCtl.patchSettings(iid(), { source: "file", filePath: "/run/x", jsonPath: "" })
            metricReader.nextResult = { ok: true, body: "7", error: "", message: "" }
            h.item.refresh()
            compare(h.item.valNum, 7, "a bounded native file result is applied")
            compare(h.item.errText, "")
        }

        function test_non_numeric_file_shows_as_text() {
            h.storeCtl.patchSettings(iid(), { source: "file", filePath: "/run/x", jsonPath: "" })
            metricReader.nextResult = { ok: true, body: "degraded", error: "", message: "" }
            h.item.refresh()
            compare(h.item.valText, "degraded")
        }

        function test_native_file_rejection_is_actionable() {
            h.storeCtl.patchSettings(iid(), {
                source: "file", filePath: "/run/metrics/depth", jsonPath: ""
            })
            metricReader.nextResult = {
                ok: false, body: "", error: "symlink",
                message: "Symbolic-link metric files are not allowed."
            }
            h.item.refresh()
            compare(h.item.errText, "Symbolic-link metric files are not allowed.")
            verify(h.item.errorHelp.indexOf("symlink") >= 0)
        }

        function test_source_test_previews_without_replacing_live_value() {
            h.storeCtl.patchSettings(iid(), {
                source: "http", url: "https://api/x", jsonPath: "v",
                httpText: "17", httpVal: 17, warnAt: "20", critAt: "30"
            })
            h.item.testConnection()
            lastFake.resolveWith(200, '{"v":25}')
            verify(h.item.connectionStatus.indexOf("HTTP 200") >= 0)
            verify(h.item.connectionStatus.indexOf("Warning") >= 0)
            compare(h.item.valNum, 17)

            h.storeCtl.patchSettings(iid(), {
                source: "file", filePath: "/run/metrics/depth", jsonPath: ""
            })
            metricReader.nextResult = { ok: true, body: "31", error: "", message: "" }
            h.item.testConnection()
            verify(h.item.connectionStatus.indexOf("Local file ready") >= 0)
            verify(h.item.connectionStatus.indexOf("Critical") >= 0)
        }

        // Test Connection is the button a user presses when something is already
        // wrong, so its failure messages are the whole point of it. Only the two
        // SUCCESS paths were covered (HTTP 200, Local file ready); every refusal
        // branch was uncovered, and none of these strings appeared anywhere
        // under tests/.
        function test_test_connection_explains_each_refusal_data() {
            return [
                { tag: "offline", reason: "offline",
                  want: "Offline. Turn off Offline mode, then retry." },
                { tag: "blocked", reason: "blocked",
                  want: "Blocked by network policy." },
                { tag: "insecure-auth", reason: "insecure-auth",
                  want: "Bearer credentials require HTTPS." },
                { tag: "timeout", reason: "timeout",
                  want: "Timed out. Check the endpoint, then retry." },
                // Anything unrecognised is passed through rather than swallowed,
                // so a new gate reason is readable before anyone maps it.
                { tag: "unmapped", reason: "response-too-large",
                  want: "Connection failed: response-too-large" }
            ]
        }
        function test_test_connection_explains_each_refusal(data) {
            h.item.netHub = reasonHub
            reasonHub.reason = data.reason
            h.storeCtl.patchSettings(iid(), { source: "http", url: "https://api/x" })
            h.item.testConnection()
            compare(h.item.connectionStatus, data.want, data.reason + " has its own message")
            compare(h.item.testingConnection, false, "and the test is over, not left spinning")
            h.item.netHub = null
        }

        // A file-source KPI pointed outside the approved directories must say so
        // from the Test button too, not only on refresh.
        function test_test_connection_refuses_an_unapproved_file_path() {
            h.storeCtl.patchSettings(iid(), {
                source: "file", filePath: "/home/user/.ssh/id_ed25519", jsonPath: "" })
            compare(h.item.localPathApproved, false, "precondition: not an approved path")
            var before = metricReader.calls
            h.item.testConnection()
            compare(metricReader.calls, before, "the native reader is never reached")
            compare(h.item.connectionStatus,
                    "Blocked. Choose a metric file under an approved system directory.",
                    "and the message names the fix, not just the refusal")
        }

        function test_failed_refresh_preserves_last_successful_value() {
            h.storeCtl.patchSettings(iid(), { source: "http", url: "https://api/x" })
            h.item.refresh(); lastFake.resolveWith(200, "17")
            h.item.refresh(); lastFake.resolveWith(503, "")
            compare(h.item.errText, "Unavailable")
            compare(h.item.valText, "17")
            compare(h.item.providerState, "error")
            compare(h.item.status, "Error")
        }

        function test_timeout_is_disconnected() {
            h.storeCtl.patchSettings(iid(), { source: "http", url: "https://api/slow" })
            h.item.refresh(); lastFake.fireTimeout()
            compare(h.item.errText, "Timed out")
            compare(h.item.providerState, "disconnected")
            compare(h.item.status, "Offline")
        }

        function test_policy_block_has_its_own_state() {
            h.item.netHub = blockedHub
            h.storeCtl.patchSettings(iid(), { source: "http", url: "https://api/blocked" })
            h.item.refresh()
            compare(h.item.errText, "Blocked")
            compare(h.item.providerState, "blocked")
            compare(h.item.status, "Blocked")
        }

        // ── thresholds ───────────────────────────────────────────────────────
        function test_normal_thresholds() {
            h.storeCtl.patchSettings(iid(), { source: "http", url: "https://a/x", jsonPath: "", warnAt: "80", critAt: "95" })
            h.item.refresh(); lastFake.resolveWith(200, "50")
            compare(h.item.valColor, h.item.effAccent, "below warn → accent")
            compare(h.item.thresholdState, "Normal")
            h.item.refresh(); lastFake.resolveWith(200, "97")
            compare(h.item.valColor, h.theme.error, "≥ crit → red")
            compare(h.item.thresholdState, "Critical")
        }

        function test_inverted_thresholds_lower_is_worse() {
            h.storeCtl.patchSettings(iid(), { source: "http", url: "https://a/x", jsonPath: "",
                invert: true, warnAt: "90", critAt: "50" })
            h.item.refresh(); lastFake.resolveWith(200, "99")
            compare(h.item.valColor, h.item.effAccent, "well above → accent")
            h.item.refresh(); lastFake.resolveWith(200, "80")
            compare(h.item.valColor, h.theme.warning, "≤ warn → amber (lower is worse)")
            compare(h.item.thresholdState, "Warning")
            h.item.refresh(); lastFake.resolveWith(200, "40")
            compare(h.item.valColor, h.theme.error, "≤ crit → red")
            compare(h.item.thresholdState, "Critical")
        }

        function test_invalid_threshold_order_is_explained() {
            h.storeCtl.patchSettings(iid(), {
                source: "http", url: "https://a/x", warnAt: "90", critAt: "50",
                invert: false
            })
            verify(h.item.thresholdConfigError.indexOf("less than") >= 0)
            h.storeCtl.patchSettings(iid(), { invert: true, warnAt: "40", critAt: "80" })
            verify(h.item.thresholdConfigError.indexOf("Lower is worse") >= 0)
        }

        function test_unconfigured_does_not_fetch() {
            clearSettings()
            h.storeCtl.patchSettings(iid(), { source: "http", url: "" })
            lastFake = null
            h.item.refresh()
            verify(lastFake === null, "no request without an endpoint")
            compare(h.item.providerState, "unconfigured")
            compare(h.item.status, "Setup")
        }
    }

    // Schema ↔ widget key sync - the KPI-specific keys (the shared jsonPath/warnAt/
    // etc. are credited by tst_httpjson_net).
    TestCase {
        name: "KpiSchema"
        when: windowShown
        function keys() {
            var s = sc.schemaFor("kpi"); var k = {}
            for (var i = 0; i < s.sections.length; i++)
                for (var j = 0; j < (s.sections[i].fields || []).length; j++)
                    if (s.sections[i].fields[j].key) k[s.sections[i].fields[j].key] = true
            return k
        }
        function test_schema_exposes_kpi_keys() {
            var k = keys()
            verify(k["source"] === true, "kpi schema exposes source")
            verify(k["filePath"] === true, "kpi schema exposes filePath")
            verify(k["invert"] === true, "kpi schema exposes invert")
            verify(k["prefix"] === true, "kpi schema exposes prefix")
            verify(k["decimals"] === true, "kpi schema exposes decimals")
            verify(k["target"] === true, "kpi schema exposes target")
        }

        function test_schema_exposes_test_source_action() {
            var s = sc.schemaFor("kpi"), found = false
            for (var i = 0; i < s.sections.length; i++)
                for (var j = 0; j < (s.sections[i].fields || []).length; j++)
                    if (s.sections[i].fields[j].action === "testConnection") found = true
            verify(found, "KPI schema exposes Test source")
        }
    }

    // ── Per-sizeClass structure (W1 wave 2b) ────────────────────────────────
    // Fixed-size hosts at the real projected cell footprints (the panel's short
    // axis is 720, so a half-cell is ~348x409 portrait / ~423x306 landscape and
    // the baseline third is ~696x819 / ~846x612).
    Item { width: 348; height: 409
        WidgetHarness { id: kMicro; anchors.fill: parent; widgetFile: "KpiWidget.qml"; expanded: false } }
    Item { width: 696; height: 819
        WidgetHarness { id: kBase; anchors.fill: parent; widgetFile: "KpiWidget.qml"; expanded: false } }
    Item { id: kWideWrap; width: 1269; height: 612
        WidgetHarness { id: kWide; anchors.fill: parent; widgetFile: "KpiWidget.qml"; expanded: false } }
    // 1x3 portrait - the whole panel.
    Item { id: kBoardWrap; width: 696; height: 2459
        WidgetHarness { id: kBoard; anchors.fill: parent; widgetFile: "KpiWidget.qml"; expanded: false } }

    TestCase {
        name: "KpiSizes"
        when: windowShown

        function feedValues(host, values, overrides) {
            host.active = false
            var settings = {
                source: "http", url: "http://x/y",
                label: "Error budget", unit: "%",
                httpText: "", httpVal: undefined,
                httpErr: "", httpHelp: "", histRaw: []
            }
            var extra = overrides || ({})
            for (var key in extra) settings[key] = extra[key]
            host.storeCtl.resetSettings(host.instanceId, settings)
            host.item.hist = []
            host.item.xhrFactory = function () { return root.makeFake() }
            var series = values || []
            for (var i = 0; i < series.length; i++)
                host.item._apply(series[i])
        }
        // Feed a real, deterministic series so trend + stats have data.
        function feed(host) {
            feedValues(host, [40, 55, 42, 61, 58])
        }
        function cleanup() {
            h.theme.textScale = 1.15
            kWide.theme.textScale = 1.15
            kWide.theme.fontChoice = "system"
            kWide.theme.reduceMotion = false
            kBoard.theme.textScale = 1.15
            kBoard.theme.fontChoice = "system"
            kBoard.theme.reduceMotion = false
            kWideWrap.width = 1269
            kWideWrap.height = 612
            kBoardWrap.width = 696
            kBoardWrap.height = 2459
        }

        // 0.5x0.5 - a READOUT: the number, and nothing that needs a finger.
        function test_micro_is_the_number_alone() {
            tryVerify(function () { return kMicro.ready }, 3000)
            var k = kMicro.item
            k.sizeClass = "compact"
            feed(kMicro)
            compare(k.micro, true, "a 348x409 compact box is the micro tile")
            compare(k.showHeader, false, "micro drops the chrome header")
            compare(k.showLabel, false, "micro drops the label - the number IS the tile")
            compare(k.showSpark, false, "…and the trend")
            compare(k.showStats, false, "…and the stats strip")
            verify(k.valuePx >= 100, "the number still fills the box (" + k.valuePx.toFixed(0) + "px)")
        }

        // The number is sized off the BOX, not off `expanded` - the wave-2b bug.
        function test_number_scales_with_the_tile() {
            tryVerify(function () { return kBase.ready }, 3000)
            tryVerify(function () { return kMicro.ready }, 3000)
            kMicro.item.sizeClass = "compact"; feed(kMicro)
            var k = kBase.item
            k.sizeClass = "compact"
            feed(kBase)
            compare(k.micro, false, "a 696x819 baseline tile is not micro")
            compare(k.showLabel, true, "the baseline earns the label")
            compare(k.showSpark, true, "…and the trend")
            verify(k.valuePx > kMicro.item.valuePx,
                   "the baseline number is bigger than the micro one ("
                   + k.valuePx.toFixed(0) + " vs " + kMicro.item.valuePx.toFixed(0) + ")")
            verify(k.valuePx > 40, "…and far past the old flat 40px (" + k.valuePx.toFixed(0) + ")")
        }

        // A genuinely wide box puts the trend BESIDE the number.
        function test_wide_splits_number_and_trend() {
            tryVerify(function () { return kWide.ready }, 3000)
            var k = kWide.item
            k.sizeClass = "wide"
            feed(kWide)
            compare(k.split, true, "1269x612 (1x1.5 landscape) splits into two columns")
            compare(lay_of(kWide).columns, 2, "…which is the GridLayout flipping columns")
            // Portrait 1x1.5 is 696x1229 - the same size, the other shape.
            kWideWrap.width = 696; kWideWrap.height = 1229
            k.sizeClass = "tall"
            compare(k.split, false, "the portrait projection of the same size stacks")
            compare(lay_of(kWide).columns, 1, "…back to a single column")
            kWideWrap.width = 1269; kWideWrap.height = 612
        }

        function test_wide_composition_is_stable_from_zero_to_two_samples() {
            tryVerify(function () { return kWide.ready }, 3000)
            kWideWrap.width = 846
            kWideWrap.height = 306
            var k = kWide.item
            k.sizeClass = "wide"
            feedValues(kWide, [], {
                httpText: "40", httpVal: 40,
                label: "Production service error budget remaining"
            })
            wait(32)

            var block = findObject(k, "kpiValueBlock")
            verify(block !== null)
            compare(k.split, true)
            compare(k.contentSplit, true,
                    "a normal wide KPI reserves its two-column composition")
            compare(lay_of(kWide).columns, 2)
            compare(k.showSpark, false)
            var initialRect = root.mappedRect(block, k)
            var initialValuePx = k.valuePx

            k._apply(40)
            wait(32)
            compare(k.chartHistory.length, 1)
            compare(k.showSpark, false)
            compare(k.contentSplit, true)
            compare(lay_of(kWide).columns, 2)
            var oneRect = root.mappedRect(block, k)
            verify(Math.abs(oneRect.left - initialRect.left) <= 1
                   && Math.abs(oneRect.top - initialRect.top) <= 1
                   && Math.abs(oneRect.right - initialRect.right) <= 1
                   && Math.abs(oneRect.bottom - initialRect.bottom) <= 1,
                   "the first sample does not move the headline block")
            verify(Math.abs(k.valuePx - initialValuePx) <= 1,
                   "the first sample does not resize the same-width reading")

            k._apply(42)
            wait(32)
            compare(k.chartHistory.length, 2)
            compare(k.showSpark, true)
            compare(k.contentSplit, true)
            compare(lay_of(kWide).columns, 2)
            var twoRect = root.mappedRect(block, k)
            verify(Math.abs(twoRect.left - initialRect.left) <= 1
                   && Math.abs(twoRect.top - initialRect.top) <= 1
                   && Math.abs(twoRect.right - initialRect.right) <= 1
                   && Math.abs(twoRect.bottom - initialRect.bottom) <= 1,
                   "the second sample reveals the chart without moving the headline")
            verify(Math.abs(k.valuePx - initialValuePx) <= 1,
                   "the second sample does not resize the same-width reading")

            kWide.storeCtl.patchSettings(kWide.instanceId, {
                httpErr: "The metric endpoint timed out",
                httpHelp: "Check the endpoint and retry from widget settings."
            })
            wait(32)
            compare(k.contentSplit, false,
                    "an error still gives recovery guidance the full width")
            compare(lay_of(kWide).columns, 1)
        }

        function test_shallow_wide_keeps_long_label_and_compact_chart_inside() {
            tryVerify(function () { return kWide.ready }, 3000)
            kWideWrap.width = 846
            kWideWrap.height = 306
            var k = kWide.item
            k.sizeClass = "wide"
            feed(kWide)
            kWide.storeCtl.patchSettings(kWide.instanceId, {
                label: "Production service error budget remaining",
                unit: "%"
            })
            kWide.theme.textScale = 1.15
            kWide.theme.fontChoice = "hyperlegible"
            wait(32)

            var label = findObject(k, "kpiLabelOrError")
            var chart = findObject(k, "kpiTrendChart")
            verify(label !== null && chart !== null)
            verify(!label.truncated
                   && label.contentHeight <= label.height + 1,
                   "the complete KPI label wraps inside a shallow split tile")
            compare(k.contentSplit, true)
            compare(k.showInlineRefresh, true)
            compare(k.compactRefreshPlacement, true)
            var refresh = findObject(k, "kpiRefreshButton")
            verify(refresh !== null && refresh.visible)
            verify(refresh.width >= kWide.theme.touchTertiary
                   && refresh.height >= kWide.theme.touchTertiary,
                   "manual refresh remains a reachable touch target")
            compare(chart.axesVisible, false,
                    "the constrained chart drops axes it cannot fit safely")
            compare(chart.statisticsVisible, false,
                    "the compact chart does not duplicate label and statistics")
            verify(k.Accessible.name.indexOf(k.label) >= 0,
                   "the complete KPI identity remains accessible")
            compare(root.clippedTextFailures(k).length, 0,
                    "every shallow-wide text stays inside the clipped body: "
                    + root.clippedTextFailures(k).join("; "))

            var refreshClip = root.nearestClippedAncestor(refresh, k)
            verify(refreshClip !== null
                   && root.rectInside(refresh, refreshClip),
                   "the refresh target remains fully inside the clipped body")
            var refreshRect = root.mappedRect(refresh, k)
            verify(!root.rectsOverlap(refreshRect, root.mappedRect(chart, k)),
                   "the local refresh footprint does not cover the chart")
            verify(!root.rectsOverlap(
                       refreshRect,
                       root.mappedRect(findObject(k, "kpiValueBlock"), k)),
                   "the local refresh footprint does not cover the headline")
            compare(refresh.Accessible.role, Accessible.Button)
            compare(refresh.Accessible.name, "Refresh KPI")

            mouseClick(refresh, refresh.width / 2, refresh.height / 2)
            tryVerify(function () {
                return k._xhr !== null && k._xhr.sent === true
            }, 500, "the compact touch target starts a refresh")
            k._xhr.resolveWith(200, "58")
            tryVerify(function () { return k._xhr === null }, 500)

            refresh.forceActiveFocus()
            verify(refresh.activeFocus)
            keyClick(Qt.Key_Return)
            tryVerify(function () {
                return k._xhr !== null && k._xhr.sent === true
            }, 500, "the compact keyboard target starts a refresh")
            k._xhr.resolveWith(200, "58")
            tryVerify(function () { return k._xhr === null }, 500)

            refresh.Accessible.pressAction()
            tryVerify(function () {
                return k._xhr !== null && k._xhr.sent === true
            }, 500, "the compact accessibility action starts a refresh")
            k._xhr.resolveWith(200, "58")
            tryVerify(function () { return k._xhr === null }, 500)
        }

        function test_detailed_chart_separates_visual_and_accessible_statistics() {
            tryVerify(function () { return kWide.ready }, 3000)
            kWideWrap.width = 1269
            kWideWrap.height = 612
            var k = kWide.item
            k.sizeClass = "wide"
            kWide.theme.textScale = 1.15
            kWide.theme.fontChoice = "system"
            kWide.theme.reduceMotion = true
            feedValues(kWide, [40, 55, 42, 61, 58], {
                label: "Production service error budget remaining",
                unit: "%"
            })
            wait(32)

            var chart = findObject(k, "kpiTrendChart")
            var visualStats = findObject(k, "sparklinePrimaryStatistics")
            verify(chart !== null && visualStats !== null)
            compare(k.detailedChart, true)
            compare(k.showStats, false)
            compare(chart.statisticsVisible, true)
            compare(chart.statisticsLabel, "")
            verify(visualStats.visible
                   && visualStats.text.indexOf("avg") >= 0
                   && visualStats.text.indexOf("peak") >= 0,
                   "the detailed compact chart keeps visible average and peak")
            verify(visualStats.text.indexOf(k.label) < 0,
                   "the visual chart does not duplicate the long KPI identity")
            verify(!visualStats.truncated,
                   "the concise visual statistics fit their chart")
            verify(chart.accessibleSummary.indexOf(k.label) >= 0
                   && chart.accessibleSummary.indexOf("current 58 %") >= 0
                   && chart.accessibleSummary.indexOf("average 51.2 %") >= 0
                   && chart.accessibleSummary.indexOf("peak 61 %") >= 0
                   && chart.accessibleSummary.indexOf(
                       "automatic scale from zero") >= 0,
                   "accessibility retains identity, values, and range semantics")
            compare(root.clippedTextFailures(k).length, 0,
                    "detailed visual statistics stay contained: "
                    + root.clippedTextFailures(k).join("; "))
        }

        function test_constrained_error_uses_full_width_and_keeps_guidance() {
            tryVerify(function () { return kWide.ready }, 3000)
            kWideWrap.width = 677
            kWideWrap.height = 245
            var k = kWide.item
            k.sizeClass = "wide"
            feed(kWide)
            var historyBeforeError = JSON.stringify(k.chartHistory)
            var statsBeforeError = JSON.stringify(k.stats)
            kWide.storeCtl.patchSettings(kWide.instanceId, {
                prefix: "$",
                unit: "%",
                httpErr: "The metric endpoint timed out",
                httpHelp: "Check the endpoint and retry from widget settings."
            })
            kWide.theme.textScale = 1.3
            kWide.theme.fontChoice = "lexend"
            wait(32)

            compare(k.contentSplit, false,
                    "an error does not retain an empty trend column")
            compare(k.showSpark, false)
            compare(k.showStats, false)
            compare(k.showInlineRefresh, true)
            compare(k.compactRefreshPlacement, true)
            var error = findObject(k, "kpiLabelOrError")
            var help = findObject(k, "kpiErrorHelp")
            verify(error !== null && help !== null)
            verify(!error.truncated && error.contentHeight <= error.height + 1,
                   "the complete error fits the constrained tile")
            verify(!help.truncated && help.contentHeight <= help.height + 1,
                   "the complete recovery guidance fits the constrained tile")
            verify(k.Accessible.name.indexOf(k.errorHelp) >= 0,
                   "the recovery guidance remains in the accessible summary")
            verify(k.Accessible.name.indexOf("$58 %") >= 0,
                   "prefix, last value, and unit remain in the accessible summary")
            compare(JSON.stringify(k.chartHistory), historyBeforeError,
                    "entering an error does not mutate history")
            compare(JSON.stringify(k.stats), statsBeforeError,
                    "entering an error does not alter raw statistics")
            compare(root.clippedTextFailures(k).length, 0,
                    "every constrained-error text stays inside the clipped body: "
                    + root.clippedTextFailures(k).join("; "))

            kWide.storeCtl.patchSettings(kWide.instanceId,
                { httpErr: "", httpHelp: "" })
            wait(32)
            compare(JSON.stringify(k.chartHistory), historyBeforeError,
                    "clearing an error does not mutate history")
            compare(JSON.stringify(k.stats), statsBeforeError,
                    "clearing an error does not alter raw statistics")
            compare(k.showSpark, true,
                    "the same chart returns when the error clears")
            var chart = findObject(k, "kpiTrendChart")
            verify(chart !== null
                   && chart.accessibleSummary.indexOf("average") >= 0
                   && chart.accessibleSummary.indexOf("peak") >= 0,
                   "chart statistics remain available to accessibility")
        }

        function test_compact_error_fits_a_maximum_retained_reading() {
            tryVerify(function () { return kWide.ready }, 3000)
            kWideWrap.width = 677
            kWideWrap.height = 245
            var k = kWide.item
            k.sizeClass = "wide"
            feed(kWide)
            kWide.theme.textScale = 1.3
            kWide.theme.fontChoice = "lexend"
            kWide.storeCtl.patchSettings(kWide.instanceId, {
                prefix: "$",
                unit: "%",
                decimals: 6,
                httpText: "999999.999999",
                httpVal: 999999.999999,
                httpErr: "The metric endpoint timed out",
                httpHelp: "Check the endpoint and retry from widget settings."
            })
            wait(32)

            compare(k.contentSplit, false)
            compare(k.compactRefreshPlacement, true)
            verify(k._compactValueInset
                   >= kWide.theme.touchTertiary + kWide.theme.spacingSm)
            var value = findObject(k, "kpiValueText")
            var refresh = findObject(k, "kpiRefreshButton")
            var block = findObject(k, "kpiValueBlock")
            verify(value !== null && refresh !== null && block !== null)
            compare(value.text, "999999.999999")
            verify(!value.truncated
                   && value.contentWidth <= value.width + 1,
                   "the maximum retained reading fits beside its prefix and unit")
            verify(k.Accessible.name.indexOf("$999999.999999 %") >= 0,
                   "the maximum retained reading remains accessible")
            var refreshClip = root.nearestClippedAncestor(refresh, k)
            verify(refreshClip !== null
                   && root.rectInside(refresh, refreshClip))
            verify(!root.rectsOverlap(
                       root.mappedRect(refresh, k),
                       root.mappedRect(block, k)),
                   "the maximum error readout does not enter the refresh footprint")
            compare(root.clippedTextFailures(k).length, 0,
                    "maximum-reading error text stays contained: "
                    + root.clippedTextFailures(k).join("; "))
        }

        function test_roomy_error_recovery_restores_the_same_statistics() {
            tryVerify(function () { return kWide.ready }, 3000)
            kWideWrap.width = 1692
            kWideWrap.height = 612
            var k = kWide.item
            k.sizeClass = "large"
            feed(kWide)
            wait(32)
            var historyBeforeError = JSON.stringify(k.chartHistory)
            var statsBeforeError = JSON.stringify(k.stats)
            compare(statsBeforeError,
                    JSON.stringify({ min: 40, max: 61, avg: 51.2 }))
            compare(k.showSpark, true)
            compare(k.showStats, true)
            compare(k.contentSplit, true)

            kWide.storeCtl.patchSettings(kWide.instanceId, {
                httpErr: "The metric endpoint timed out",
                httpHelp: "Check the endpoint and retry from widget settings."
            })
            wait(32)
            compare(JSON.stringify(k.chartHistory), historyBeforeError)
            compare(JSON.stringify(k.stats), statsBeforeError)
            compare(k.showSpark, false)
            compare(k.showStats, false)
            compare(k.contentSplit, false,
                    "roomy errors also use the full-width recovery state")

            kWide.storeCtl.patchSettings(kWide.instanceId,
                { httpErr: "", httpHelp: "" })
            wait(32)
            compare(JSON.stringify(k.chartHistory), historyBeforeError)
            compare(JSON.stringify(k.stats), statsBeforeError)
            compare(k.showSpark, true)
            compare(k.showStats, true,
                    "the same dedicated statistics return after recovery")
            compare(k.contentSplit, true)
            verify(findText(k, "min") !== null
                   && findText(k, "40") !== null
                   && findText(k, "avg") !== null
                   && findText(k, "51.2") !== null
                   && findText(k, "max") !== null
                   && findText(k, "61") !== null,
                   "the restored statistics retain their exact raw values")
        }

        function test_narrow_tall_error_and_large_labels_stay_contained() {
            tryVerify(function () {
                return kWide.ready && kBoard.ready
            }, 3000)

            kWideWrap.width = 278
            kWideWrap.height = 654
            var narrow = kWide.item
            narrow.sizeClass = "tall"
            feed(kWide)
            kWide.storeCtl.patchSettings(kWide.instanceId, {
                label: "Production service error budget remaining",
                unit: "%",
                httpErr: "The metric endpoint timed out",
                httpHelp: "Check the endpoint and retry from widget settings."
            })
            kWide.theme.textScale = 1.45
            kWide.theme.fontChoice = "lexend"
            wait(32)
            compare(root.clippedTextFailures(narrow).length, 0,
                    "278x654 error state is contained: "
                    + root.clippedTextFailures(narrow).join("; "))

            var board = kBoard.item
            kBoardWrap.width = 696
            kBoardWrap.height = 1636
            board.sizeClass = "large"
            feed(kBoard)
            kBoard.storeCtl.patchSettings(kBoard.instanceId, {
                label: "Production service error budget remaining",
                unit: "%"
            })
            kBoard.theme.textScale = 1.3
            kBoard.theme.fontChoice = "system"
            wait(32)
            compare(board.showStats, true)
            compare(findObject(board, "kpiStatValue-min").text, "40")
            compare(findObject(board, "kpiStatValue-avg").text, "51.2")
            compare(findObject(board, "kpiStatValue-max").text, "61")
            compare(root.clippedTextFailures(board).length, 0,
                    "exact 696x1636 System 1.3 label and stats are contained: "
                    + root.clippedTextFailures(board).join("; "))

            kWideWrap.width = 1692
            kWideWrap.height = 612
            narrow.sizeClass = "large"
            feed(kWide)
            kWide.storeCtl.patchSettings(kWide.instanceId, {
                label: "Production service error budget remaining",
                unit: "%"
            })
            kWide.theme.textScale = 1.15
            kWide.theme.fontChoice = "system"
            wait(32)
            compare(narrow.showStats, true)
            compare(findObject(narrow, "kpiStatValue-min").text, "40")
            compare(findObject(narrow, "kpiStatValue-avg").text, "51.2")
            compare(findObject(narrow, "kpiStatValue-max").text, "61")
            compare(root.clippedTextFailures(narrow).length, 0,
                    "exact 1692x612 System 1.15 label and stats are contained: "
                    + root.clippedTextFailures(narrow).join("; "))
        }

        // 1x3 - the whole panel. A billboard: the stats strip is real extra
        // content, and the trend takes the slack instead of leaving air.
        function test_fullscreen_is_a_billboard() {
            tryVerify(function () { return kBoard.ready }, 3000)
            tryVerify(function () { return kBase.ready }, 3000)
            var k = kBoard.item
            k.sizeClass = "large"
            feed(kBoard)
            kBase.item.sizeClass = "compact"; feed(kBase)
            compare(k.roomy, true, "1x2/1x3 are the roomy class")
            compare(k.showStats, true, "the billboard earns a min/avg/max strip")
            compare(kBase.item.showStats, false, "…which the baseline tile does not")
            verify(k.valuePx >= kBase.item.valuePx,
                   "the number is at least as big as the baseline's")
            verify(k.labelPx > kBase.item.labelPx, "the label grows with the box")
            // The stats are values on STABLE cells, not a rebuilt model.
            var minCell = findText(k, "min")
            verify(minCell !== null, "the min cell exists")
            k.sizeClass = "full"
            verify(findText(k, "min") === minCell, "the same cell survives a class flip")
        }

        function test_expanded_chart_has_axes_without_displacing_the_kpi() {
            tryVerify(function () { return h.ready }, 3000)
            h.theme.textScale = 1.45
            h.item.sizeClass = "full"
            feed(h)
            wait(32)
            var chart = findObject(h.item, "kpiTrendChart")
            var valueBlock = findObject(h.item, "kpiValueBlock")
            verify(chart !== null && chart.visible, "expanded trend is rendered")
            verify(chart.height >= h.item.chartDetailHeight - 1,
                   "expanded trend receives its detailed allocation ("
                   + chart.height + "px)")
            compare(chart.axesVisible, true,
                    "the expanded trend identifies value and time domains")
            compare(chart.statisticsVisible, false,
                    "the KPI uses its dedicated min/avg/max cells, not duplicate chart stats")
            verify(findText(h.item, "min") !== null
                   && findText(h.item, "avg") !== null
                   && findText(h.item, "max") !== null,
                   "the dedicated statistics row is present")
            verify(valueBlock !== null && valueBlock.height > chart.height,
                   "the headline value remains visually dominant")
        }

        function test_roomy_chart_context_survives_both_orientations() {
            tryVerify(function () { return kBoard.ready }, 3000)
            tryVerify(function () { return kWide.ready }, 3000)
            var hosts = [kBoard, kWide]
            var widths = [696, 1692]
            var heights = [2459, 612]
            var labels = ["portrait", "landscape"]
            for (var i = 0; i < hosts.length; i++) {
                if (hosts[i] === kWide) {
                    kWideWrap.width = widths[i]
                    kWideWrap.height = heights[i]
                }
                hosts[i].item.sizeClass = "large"
                feed(hosts[i])
                wait(32)
                var chart = findObject(hosts[i].item, "kpiTrendChart")
                verify(chart !== null && chart.visible,
                       labels[i] + " roomy trend is rendered")
                compare(chart.axesVisible, true,
                        labels[i] + " roomy trend has value/time axes")
                compare(chart.statisticsVisible, false,
                        labels[i] + " roomy trend keeps stats in dedicated cells")
                compare(hosts[i].item.showStats, true,
                        labels[i] + " roomy KPI exposes min/avg/max")
            }
            kWideWrap.width = 1269
            kWideWrap.height = 612
        }

        // Helper: the content GridLayout that directly owns the value block.
        function lay_of(host) {
            var block = findObject(host.item, "kpiValueBlock")
            return block ? block.parent : null
        }
        function findText(node, s) {
            return findFirst(node, function (n) {
                return n.hasOwnProperty("text") && String(n.text) === s })
        }
        function findObject(node, objectName) {
            return findFirst(node, function (n) {
                return n.objectName === objectName
            })
        }
        // NOTE: no guard for the value-text `preferredWidth` pairing (added to
        // KpiWidget alongside MetricGauge's). It is deliberately absent, not
        // forgotten. `valuePx` is pre-computed from the character count, so the
        // reading already fits under a MONOSPACE font no matter what the Layout
        // does; the pairing only matters when `theme.fontMono` falls back to a
        // proportional face (missing/wider mono). The headless suite ships
        // DejaVu Sans Mono, so a guard here passes with OR without the fix - it
        // would be inert. Writing an inert guard is the exact anti-pattern this
        // codebase has been purging; the fix is verified manually under a
        // no-mono fontconfig and the blind spot is recorded in BACKLOG.md.
        function findFirst(node, pred) {
            if (!node) return null
            if (pred(node)) return node
            var kids = node.children
            for (var i = 0; kids && i < kids.length; i++) {
                var r = findFirst(kids[i], pred)
                if (r) return r
            }
            return null
        }
    }
}
