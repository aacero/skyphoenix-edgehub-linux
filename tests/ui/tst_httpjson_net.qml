import QtQuick
import QtTest
import "../../ui/qml" as App

//
// Network + parsing path of ui/qml/widgets/HttpJsonWidget.qml, driven offline via
// the xhrFactory seam (passed through NetHub inside the widget). Asserts URL +
// auth-header construction, JSON-path extraction, value/list/number mapping,
// threshold colouring, every error state, and that live results are EPHEMERAL
// (never written to the persisted document - no config.toml churn per poll).
Item {
    id: root
    width: 1700; height: 2600

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
        id: h; x: 0; y: 0; width: 760; height: 620
        widgetFile: "HttpJsonWidget.qml"; expanded: true
    }

    // Resizable host for the per-sizeClass x per-MODE structure tests (W1 wave
    // 3) - the REAL projected footprints of httpjson's six declared sizes:
    //   0.5x0.5 → 348x409 portrait · 423x306 landscape  (compact, micro)
    //   0.5x1   → 348x819 portrait (tall) · 846x306 landscape (wide)
    //   1x0.5   → 696x409 portrait (wide) · 423x612 landscape (tall)
    //   1x1     → 696x819 portrait · 846x612 landscape  (compact)
    //   1x1.5   → 696x1228 portrait (tall) · 1269x612 landscape (wide)
    //   1x2     → 696x1637 portrait · 1692x612 landscape (BOTH "large")
    Item { id: sizeWrap; x: 0; y: 700; width: 696; height: 819
        WidgetHarness { id: hS; anchors.fill: parent
            widgetFile: "HttpJsonWidget.qml"; expanded: false; active: false } }

    App.WidgetConfigSchema { id: sc }

    QtObject {
        id: blockedHub
        function request(options) {
            options.onError("blocked")
            return null
        }
    }

    function findAllNodes(node, pred, acc) {
        if (!node) return acc
        if (pred(node)) acc.push(node)
        var kids = node.children
        for (var i = 0; kids && i < kids.length; i++) findAllNodes(kids[i], pred, acc)
        return acc
    }
    function effVisible(n) {
        while (n) { if (n.visible === false) return false; n = n.parent }
        return true
    }
    function iid() { return h.instanceId }
    function clearSettings() {
        // Replace the test bucket instead of repeatedly deleting and re-adding
        // properties on the same QV4 object. Qt 6.11 can crash in
        // QV4::Object::insertMember after enough shape mutations, which made
        // this offline test process fail before reporting its totals.
        if (!h.storeCtl.document.settings) h.storeCtl.document.settings = {}
        h.storeCtl.document.settings[iid()] = {}
        h.storeCtl._touchSettings()
    }

    TestCase {
        name: "HttpJsonNet"
        when: windowShown
        property var lastFake: null
        function init() {
            tryVerify(function () { return h.ready }, 3000)
            clearSettings(); h.active = false
            h.item.netHub = null
            h.item.xhrFactory = function () { lastFake = root.makeFake(); return lastFake }
        }
        function drive(url, path, status, body) {
            h.storeCtl.patchSettings(iid(), { url: url, jsonPath: path })
            h.item.refresh()
            if (status !== undefined) lastFake.resolveWith(status, body)
        }

        // ── request construction ─────────────────────────────────────────────
        function test_get_url_and_no_auth_by_default() {
            h.storeCtl.patchSettings(iid(), { url: "https://api.example.com/status", jsonPath: "" })
            h.item.refresh()
            verify(lastFake !== null && lastFake.sent, "sent through the gate")
            compare(lastFake.method, "GET")
            compare(lastFake.url, "https://api.example.com/status")
            verify(lastFake.headers["Authorization"] === undefined, "no auth header when no token")
        }

        function test_pending_request_is_loading() {
            h.storeCtl.patchSettings(iid(), { url: "https://api.example.com/loading", jsonPath: "v" })
            h.item.refresh()
            compare(h.item.providerState, "loading")
            compare(h.item.status, "Loading")
        }

        function test_bearer_token_becomes_auth_header() {
            h.storeCtl.patchSettings(iid(), { url: "https://api.example.com/s", authToken: "SECRET" })
            h.item.refresh()
            compare(lastFake.headers["Authorization"], "Bearer SECRET")
        }

        function test_empty_url_does_not_fetch() {
            h.storeCtl.patchSettings(iid(), { url: "", jsonPath: "x" })
            lastFake = null
            h.item.refresh()
            verify(lastFake === null, "no request without a URL")
            compare(h.item.providerState, "unconfigured")
            compare(h.item.status, "Setup")
        }

        // ── JSON path extraction → value ─────────────────────────────────────
        function test_dotted_path_extracts_number() {
            drive("https://x/y", "data.value", 200, '{"data":{"value":42}}')
            compare(h.item.valNum, 42, "numeric value extracted")
            compare(h.item.valText, "42", "formatted as an integer")
            compare(h.item.errText, "", "no error on success")
            compare(h.item.providerState, "fresh")
            compare(h.item.status, "")
        }

        function test_bracket_index_path() {
            drive("https://x/y", "items[1].name", 200, '{"items":[{"name":"a"},{"name":"b"}]}')
            compare(h.item.valText, "b", "items[1].name resolved")
        }

        function test_float_is_rounded_to_one_decimal() {
            drive("https://x/y", "v", 200, '{"v":3.14159}')
            compare(h.item.valText, "3.1", "small float shown to one decimal")
        }

        function test_decimal_formatting_is_configurable() {
            h.storeCtl.patchSettings(iid(), { decimals: 3 })
            drive("https://x/y", "v", 200, '{"v":3.14159}')
            compare(h.item.valText, "3.142")
            h.storeCtl.patchSettings(iid(), { decimals: 0 })
            drive("https://x/y", "v", 200, '{"v":3.8}')
            compare(h.item.valText, "4")
        }

        function test_success_records_real_freshness_and_stale_age() {
            h.item.nowMsOverride = 1000000
            drive("https://status.example.com/y", "v", 200, '{"v":7}')
            compare(h.item.lastSuccessAt, 1000000)
            compare(h.item.sourceHost(), "status.example.com")
            compare(h.item.stale, false)
            h.item.nowMsOverride = 1000000 + h.item.staleAfterSec * 1000
            compare(h.item.stale, true)
            compare(h.item.providerState, "stale")
            compare(h.item.status, "Stale")
            h.item.nowMsOverride = -1
        }

        function test_blank_path_uses_whole_body_scalar() {
            drive("https://x/y", "", 200, '99')
            compare(h.item.valNum, 99, "a bare JSON number is taken whole")
        }

        function test_missing_path_is_no_match() {
            drive("https://x/y", "nope.here", 200, '{"data":1}')
            compare(h.item.errText, "No match", "an unresolved path is a clear error")
            verify(h.item.errorHelp.indexOf("JSON path") >= 0,
                   "the error explains what to correct")
        }

        function test_connection_preview() {
            h.storeCtl.patchSettings(iid(), {
                url: "https://x/y", jsonPath: "data.value",
                httpText: "17", httpVal: 17, httpErr: ""
            })
            h.item.testConnection()
            verify(h.item.testingConnection)
            lastFake.resolveWith(200, '{"data":{"value":42}}')
            compare(h.item.testingConnection, false)
            verify(h.item.connectionStatus.indexOf("HTTP 200") >= 0)
            verify(h.item.connectionStatus.indexOf("42") >= 0,
                   "test result includes a representative value")
            compare(h.item.valNum, 17,
                    "a connection test does not replace the last live reading")
        }

        function test_connection_reports_path_and_policy_corrections() {
            h.storeCtl.patchSettings(iid(), { url: "https://x/y", jsonPath: "missing" })
            h.item.testConnection()
            lastFake.resolveWith(200, '{"value":42}')
            verify(h.item.connectionStatus.indexOf("did not match") >= 0)

            h.item.netHub = blockedHub
            h.item.testConnection()
            verify(h.item.connectionStatus.indexOf("not allowed") >= 0)
            h.item.netHub = null
        }

        // ── list mode ────────────────────────────────────────────────────────
        function test_array_value_becomes_list() {
            drive("https://x/y", "rows", 200, '{"rows":["one","two","three"]}')
            compare(h.item.listItems.length, 3, "array mapped to list items")
            compare(h.item.listItems[0], "one")
            compare(h.item.valText, "3 items", "count summarised as text")
        }

        function test_expanded_list_respects_user_maximum() {
            h.storeCtl.patchSettings(iid(), {
                url: "https://x/y", mode: "list", listMax: 3
            })
            h.item._apply(["one", "two", "three", "four", "five"])
            compare(h.item.expanded, true, "precondition: overlay host")
            compare(h.item.listShown, 3,
                    "the overlay does not override the configured list maximum")
        }

        function test_runtime_clamps_poll_and_list_to_schema_bounds() {
            h.storeCtl.patchSettings(iid(), {
                url: "https://x/y", pollSec: 2, listMax: 99
            })
            compare(h.item.pollSec, 5,
                    "runtime polling matches the schema minimum")
            compare(h.item.listMax, 12,
                    "crafted list limits cannot exceed the schema maximum")
        }

        function test_bearer_token_is_refused_on_plain_http() {
            h.storeCtl.patchSettings(iid(), {
                url: "http://api.example.com/private", authToken: "SECRET"
            })
            lastFake = null
            h.item.refresh()
            compare(lastFake, null, "no XHR is created for insecure bearer auth")
            compare(h.item.errText, "Blocked")
        }

        // errorDetails() is the widget's whole "what went wrong, and what do I
        // do about it" surface: nine reasons, each mapping to a label AND an
        // actionable help line. Not one of the help strings was asserted
        // anywhere, and two DIFFERENT reasons share the label "Blocked" - so the
        // existing label-only assertions cannot tell "this host is not allowed"
        // from "your credentials need HTTPS", which need opposite user actions
        // (change the policy vs change the URL). A regression collapsing every
        // branch into the catch-all would have been invisible.
        function test_every_failure_reason_gets_its_own_label_and_help_data() {
            return [
                { tag: "offline", reason: "offline", label: "Offline",
                  help: "Turn off Offline mode, then retry." },
                { tag: "blocked", reason: "blocked", label: "Blocked",
                  help: "This host is not allowed by the network policy." },
                { tag: "insecure-auth", reason: "insecure-auth", label: "Blocked",
                  help: "Bearer credentials require an HTTPS URL." },
                { tag: "too-large", reason: "response-too-large", label: "Response too large",
                  help: "Use an endpoint whose JSON response is at most 1 MiB." },
                { tag: "timeout", reason: "timeout", label: "Timed out",
                  help: "Check the endpoint and network, then retry." },
                { tag: "bad-scheme", reason: "unsupported-scheme", label: "Invalid URL",
                  help: "Use a complete HTTP or HTTPS URL." },
                // The secret resolver's own reason is passed through verbatim, so
                // the user reads WHICH credential failed, not a generic message.
                { tag: "secret", reason: "secret: CI_TOKEN is not set",
                  label: "Credential unavailable", help: "CI_TOKEN is not set" },
                // The status code is carried into the label rather than dropped.
                { tag: "http-status", reason: "http 503", label: "HTTP 503",
                  help: "The server rejected the request. Check the URL and credentials." },
                { tag: "unknown", reason: "something new", label: "Unavailable",
                  help: "Check the URL, network, and endpoint response." }
            ]
        }
        function test_every_failure_reason_gets_its_own_label_and_help(data) {
            var d = h.item.errorDetails(data.reason)
            compare(d.label, data.label, data.reason + " is labelled " + data.label)
            compare(d.help, data.help, data.reason + " tells the user what to do about it")
        }

        // Two reasons share a label, so the HELP is the only thing that
        // distinguishes them. Pinned explicitly - it is the pair most likely to
        // be "simplified" into one branch.
        function test_the_two_blocked_reasons_are_told_apart_by_their_help() {
            var policy = h.item.errorDetails("blocked")
            var auth = h.item.errorDetails("insecure-auth")
            compare(policy.label, auth.label, "precondition: the labels really are the same")
            verify(policy.help !== auth.help,
                   "a host refused by policy and a token refused for plain HTTP are "
                   + "different problems and must not read identically")
        }

        // The end-to-end join: a real refusal reaches the same help the mapping
        // above defines, rather than the widget composing its own message.
        function test_a_real_insecure_auth_refusal_shows_that_help() {
            h.storeCtl.patchSettings(iid(), {
                url: "http://api.example.com/private", authToken: "SECRET"
            })
            h.item.refresh()
            compare(h.item.errText, "Blocked")
            compare(h.item.errorHelp, "Bearer credentials require an HTTPS URL.",
                    "the refusal the user actually hits carries the actionable line")
        }

        // ── thresholds → colour ──────────────────────────────────────────────
        function test_threshold_colours() {
            h.storeCtl.patchSettings(iid(), { warnAt: "80", critAt: "95" })
            drive("https://x/y", "v", 200, '{"v":50}')
            compare(h.item.valColor, h.item.effAccent, "below warn → accent")
            compare(h.item.thresholdState, "Normal")
            drive("https://x/y", "v", 200, '{"v":85}')
            compare(h.item.valColor, h.theme.warning, "≥ warn → amber")
            compare(h.item.thresholdState, "Warning")
            drive("https://x/y", "v", 200, '{"v":99}')
            compare(h.item.valColor, h.theme.error, "≥ crit → red")
            compare(h.item.thresholdState, "Critical")
        }

        // ── error states ─────────────────────────────────────────────────────
        function test_non_200_is_unavailable() {
            drive("https://x/y", "v", 200, '{"v":12}')
            drive("https://x/y", "v", 500, "")
            compare(h.item.errText, "HTTP 500", "HTTP status remains actionable")
            verify(h.item.errorHelp.indexOf("server rejected") >= 0)
            compare(h.item.valText, "12", "the last successful value remains visible")
            compare(h.item.providerState, "error", "failed refresh keeps data and reports its state")
        }
        function test_malformed_json_is_parse_error() {
            drive("https://x/y", "v", 200, "not json{")
            compare(h.item.errText, "Parse error")
            verify(h.item.errorHelp.indexOf("valid JSON") >= 0)
            compare(h.item.providerState, "error")
        }
        function test_timeout_state() {
            h.storeCtl.patchSettings(iid(), { url: "https://x/y", jsonPath: "v" })
            h.item.refresh()
            lastFake.fireTimeout()
            compare(h.item.errText, "Timed out")
            compare(h.item.providerState, "disconnected")
            compare(h.item.status, "Offline")
        }

        function test_policy_block_has_its_own_state() {
            h.item.netHub = blockedHub
            h.storeCtl.patchSettings(iid(), { url: "http://blocked.example/x", jsonPath: "v" })
            h.item.refresh()
            compare(h.item.errText, "Blocked")
            compare(h.item.providerState, "blocked")
            compare(h.item.status, "Blocked")
        }

        // ── ephemeral persistence (the flash-wear guarantee) ─────────────────
        function test_live_results_are_not_persisted() {
            drive("https://x/y", "v", 200, '{"v":7}')
            compare(h.item.valNum, 7, "value is live in memory")
            var disk = h.storeCtl._persistableData().settings[iid()] || ({})
            verify(disk.httpVal === undefined, "httpVal not written to config")
            verify(disk.httpText === undefined, "httpText not written to config")
            verify(disk.hist === undefined, "poll history not written to config")
            compare(disk.url, "https://x/y", "the configured URL is persisted")
        }
    }

    // Schema ↔ widget key sync - each keyed assertion names its schema key so the
    // behaviour matrix credits every HTTP/JSON config field.
    TestCase {
        name: "HttpJsonSchema"
        when: windowShown
        function keys() {
            var s = sc.schemaFor("httpjson"); var k = {}
            for (var i = 0; i < s.sections.length; i++)
                for (var j = 0; j < (s.sections[i].fields || []).length; j++)
                    if (s.sections[i].fields[j].key) k[s.sections[i].fields[j].key] = true
            return k
        }
        function test_schema_exposes_every_widget_key() {
            var k = keys()
            verify(k["jsonPath"] === true, "httpjson schema exposes jsonPath")
            verify(k["pollSec"] === true, "httpjson schema exposes pollSec")
            verify(k["mode"] === true, "httpjson schema exposes mode")
            verify(k["gaugeMax"] === true, "httpjson schema exposes gaugeMax")
            verify(k["listMax"] === true, "httpjson schema exposes listMax")
            verify(k["authToken"] === true, "httpjson schema exposes authToken")
            verify(k["decimals"] === true, "httpjson schema exposes decimals")
            verify(k["warnAt"] === true, "httpjson schema exposes warnAt")
            verify(k["critAt"] === true, "httpjson schema exposes critAt")
        }

        function test_schema_exposes_connection_action_and_conditional_fields() {
            var s = sc.schemaFor("httpjson")
            var action = null, unit = null, warn = null
            for (var i = 0; i < s.sections.length; i++) {
                for (var j = 0; j < (s.sections[i].fields || []).length; j++) {
                    var field = s.sections[i].fields[j]
                    if (field.action === "testConnection") action = field
                    if (field.key === "unit") unit = field
                    if (field.key === "warnAt") warn = field
                }
            }
            verify(action !== null, "schema offers Test connection")
            compare(unit.visibleWhen.notEquals, "list")
            compare(warn.visibleWhen.notEquals, "list")
        }
    }

    // ── Per-sizeClass x per-MODE structure (W1 wave 3) ───────────────────────
    // 3 modes x 6 declared sizes, so the layout is asserted per MODE, not once.
    TestCase {
        name: "HttpJsonSizes"
        when: windowShown

        function initTestCase() { tryVerify(function () { return hS.ready }, 3000) }

        // Every declared size, in both projections, with its injected class.
        readonly property var allSizes: [
            [348, 409, "compact"], [423, 306, "compact"],     // 0.5x0.5 (micro)
            [348, 819, "tall"],    [846, 306, "wide"],        // 0.5x1
            [696, 409, "wide"],    [423, 612, "tall"],        // 1x0.5
            [696, 819, "compact"], [846, 612, "compact"],     // 1x1
            [696, 1228, "tall"],   [1269, 612, "wide"],       // 1x1.5
            [696, 1637, "large"],  [1692, 612, "large"]       // 1x2
        ]

        // Each shape() gets a FRESH instance id, so every case starts from a
        // clean settings bucket. Emptying one shared bucket in place
        // (`for (k in settingsFor(id)) delete …`) does not survive this many
        // iterations: the widget re-reads `cfg` off store.revision, and a bucket
        // mutated out from under a live binding leaked values between cases
        // (a later case read the previous one's `mode` as its `url`). A new id
        // per case is also just closer to what the dashboard does.
        property int _iid: 0
        property string curId: "size-instance-0"
        function shape(width, height, cls, settings) {
            sizeWrap.width = width; sizeWrap.height = height
            curId = "size-instance-" + (++_iid)
            hS.storeCtl.ensureSettings(curId, {})
            hS.storeCtl.patchSettings(curId, settings)
            hS.item.instanceId = curId
            hS.item.sizeClass = cls
            wait(32)
            return hS.item
        }
        function seedValue(v) {
            hS.storeCtl.patchSettings(curId,
                { httpText: "" + v, httpVal: v, httpErr: "", httpList: [] })
        }
        function seedList(n) {
            var items = []
            for (var i = 0; i < n; i++) items.push("service-" + i + ": ok")
            hS.storeCtl.patchSettings(curId,
                { httpList: items, httpText: n + " items", httpVal: undefined, httpErr: "" })
        }
        function gaugeOf(item) {
            var g = findAllNodes(item, function (n) {
                return n.hasOwnProperty("showSpark") && n.hasOwnProperty("bigMax")
            }, [])
            return g.length ? g[0] : null
        }
        function sparkOf(item) {
            var charts = findAllNodes(item, function (n) {
                return n.objectName === "httpTrendChart"
            }, [])
            return charts.length ? charts[0] : null
        }
        function named(item, objectName) {
            var matches = findAllNodes(item, function (n) {
                return n.objectName === objectName
            }, [])
            return matches.length ? matches[0] : null
        }
        function cleanup() {
            hS.expanded = false
            hS.theme.textScale = 1.15
            hS.theme.fontChoice = "hyperlegible"
        }
        function visibleListRows(item) {
            return findAllNodes(item, function (n) {
                return n.hasOwnProperty("text") && /^• service-/.test(String(n.text))
                       && root.effVisible(n)
            }, []).length
        }

        // ── mode: gauge - drives MetricGauge's wave-2a knobs per size ────────
        function test_gauge_micro_is_a_bare_ring_and_one_number() {
            var w = shape(423, 306, "compact", { url: "http://x/y", mode: "gauge" })
            seedValue(42); wait(32)
            compare(w.micro, true)
            compare(w.showHeader, false, "micro drops the header")
            var g = gaugeOf(w)
            verify(g !== null, "gauge mode renders the shared MetricGauge")
            compare(g.showSpark, false, "micro reserves no sparkline slot")
            verify(g.bigMax > 60, "the headerless number may fill its box")
            compare(g.sub, "", "no path caption on a half-cell")
        }
        function test_gauge_wide_puts_the_spark_beside_the_ring() {
            var w = shape(846, 306, "wide", { url: "http://x/y", mode: "gauge" })
            seedValue(42); wait(32)
            var g = gaugeOf(w)
            compare(g.horizontal, true, "wide lays ring and sparkline side by side")
            compare(g.showSpark, true)
            compare(g.sparkFills, false)
        }
        function test_gauge_tall_squares_the_ring_and_earns_the_path() {
            var w = shape(696, 1228, "tall", { url: "http://x/y", mode: "gauge", jsonPath: "data.cpu" })
            seedValue(42); wait(32)
            var g = gaugeOf(w)
            compare(g.sparkFills, true, "a tall TILE hands the trend the height below the ring")
            compare(g.horizontal, false)
            compare(g.sub, "data.cpu", "and the tall tile earns the path caption")
        }
        function test_gauge_baseline_is_the_classic_stacked_strip() {
            var w = shape(696, 819, "compact", { url: "http://x/y", mode: "gauge", jsonPath: "data.cpu" })
            seedValue(42); wait(32)
            var g = gaugeOf(w)
            compare(g.showSpark, true); compare(g.horizontal, false)
            compare(g.sparkFills, false, "the baseline keeps the classic strip")
            compare(g.sub, "", "no room to earn the caption at the baseline")
        }

        // ── mode: value - the number scales with the box ─────────────────────
        function test_value_scales_with_the_box_not_a_flat_32px() {
            var micro = shape(423, 306, "compact", { url: "http://x/y", mode: "value" })
            seedValue(128); wait(32)
            var microPx = micro.valuePx
            var big = shape(696, 1637, "large", { url: "http://x/y", mode: "value" })
            seedValue(128); wait(32)
            verify(big.valuePx > 32,
                   "a 1637px box prints more than the old flat 32px (" + big.valuePx + ")")
            verify(big.valuePx > microPx,
                   "and more than the half-cell (" + microPx + " → " + big.valuePx + ")")
        }
        // The unit is part of the reading: "128" and "128 ms" are different
        // facts. The number used to claim the whole slot, which squeezed the unit
        // to zero width at every STACKED size - only the wide projection, at 0.42
        // of the width, happened to leave room. Caught on the real panel.
        function test_the_unit_is_rendered_at_every_size() {
            for (var i = 0; i < allSizes.length; i++) {
                var c = allSizes[i]
                var w = shape(c[0], c[1], c[2],
                              { url: "http://x/y", mode: "value", unit: "ms" })
                seedValue(128); wait(32)
                var tag = c[0] + "x" + c[1] + " (" + c[2] + ")"
                var units = findAllNodes(w, function (n) {
                    return n.hasOwnProperty("text") && String(n.text) === "ms"
                           && root.effVisible(n)
                }, [])
                compare(units.length, 1, tag + ": the unit is rendered")
                var u = units[0]
                // Not truncated: the glyphs actually fit ("ms", never "m").
                verify(u.width >= u.implicitWidth - 0.5,
                       tag + ": the unit is not squeezed (" + u.width + " < "
                       + u.implicitWidth + ")")
                // And it belongs to the NUMBER - not parked at the tile's edge.
                var nums = findAllNodes(w, function (n) {
                    return n.hasOwnProperty("text") && String(n.text) === "128"
                           && root.effVisible(n)
                }, [])
                compare(nums.length, 1, tag + ": the reading is rendered")
                var numRight = w.mapFromItem(nums[0], (nums[0].width + nums[0].paintedWidth) / 2, 0).x
                var unitLeft = w.mapFromItem(u, 0, 0).x
                verify(unitLeft - numRight < 24,
                       tag + ": the unit hugs the number (gap " + (unitLeft - numRight) + "px)")
            }
        }

        // The trend must actually GET the height a tall tile hands it. Two
        // fillHeight siblings in one column compete, and the nested Layout wins:
        // the sparkline collapsed to ~6px - a flat line pretending to be a chart.
        function test_the_trend_gets_real_height_when_it_is_the_point() {
            var hist = [0.31, 0.36, 0.29, 0.42, 0.55, 0.48, 0.61, 0.44]
            var base = shape(696, 819, "compact", { url: "http://x/y", mode: "value" })
            seedValue(128); base.hist = hist; wait(32)
            var baseSpark = sparkOf(base)
            verify(baseSpark !== null, "the baseline renders the trend")
            // Read the NUMBER now: the next shape() resizes the SAME live item,
            // so holding the object would re-measure it after the resize.
            var baseH = baseSpark.height
            verify(baseH > 20, "the baseline keeps its trend strip (" + baseH + "px)")

            var tall = shape(696, 1228, "tall", { url: "http://x/y", mode: "value" })
            seedValue(128); tall.hist = hist; wait(32)
            var tallSpark = sparkOf(tall)
            verify(tallSpark !== null, "tall renders the trend")
            var tallH = tallSpark.height
            verify(tallH > baseH,
                   "and a tall tile hands it MORE height than the baseline strip ("
                   + baseH + " → " + tallH + ")")
            verify(tallH > 100, "not a 6px flat line (" + tallH + "px)")
        }

        function test_expanded_value_chart_exposes_axes_and_statistics() {
            hS.expanded = true
            hS.theme.textScale = 1.45
            var hist = [31, 36, 29, 42, 55, 48, 61, 44]
            var w = shape(760, 620, "full",
                          { url: "http://x/y", mode: "value",
                            jsonPath: "production.regions.europe.latency",
                            unit: "milliseconds" })
            seedValue(44); w.hist = hist; wait(32)
            var chart = sparkOf(w)
            var section = named(w, "httpTrendSection")
            var legend = named(w, "httpTrendLegend")
            verify(chart !== null && chart.visible, "expanded trend is rendered")
            verify(section !== null && legend !== null,
                   "trend exposes its semantic section and visual legend")
            verify(chart.height >= w.chartDetailHeight - 1,
                   "expanded chart receives its detailed allocation ("
                   + chart.height + "px)")
            compare(chart.axesVisible, true,
                    "the expanded trend identifies value and time domains")
            compare(chart.statisticsVisible, true,
                    "the expanded trend identifies average and peak")
            compare(legend.text,
                    "production.regions.europe.latency · milliseconds")
            verify(!legend.truncated && legend.contentWidth <= legend.width + 0.5,
                   "the complete configured path and unit fit the visual legend")
            verify(section.Accessible.name.indexOf(
                       "production.regions.europe.latency") >= 0,
                   "accessibility retains the configured JSON path")
            verify(section.Accessible.name.indexOf("unit milliseconds") >= 0,
                   "accessibility retains the configured unit")
            verify(section.Accessible.name.indexOf("average") >= 0
                   && section.Accessible.name.indexOf("peak") >= 0,
                   "accessibility retains the chart statistics")
            compare(chart.Accessible.ignored, true,
                    "the nested chart does not duplicate the semantic section")
        }

        function test_large_value_charts_keep_context_in_both_orientations() {
            var hist = [31, 36, 29, 42, 55, 48, 61, 44]
            var projections = [
                [696, 1637, "portrait"],
                [1692, 612, "landscape"]
            ]
            for (var i = 0; i < projections.length; i++) {
                var p = projections[i]
                var w = shape(p[0], p[1], "large",
                              { url: "http://x/y", mode: "value",
                                jsonPath: "service.latency", unit: "ms" })
                seedValue(44); w.hist = hist; wait(32)
                var chart = sparkOf(w)
                verify(chart !== null && chart.visible,
                       p[2] + " large trend is rendered")
                compare(chart.axesVisible, true,
                        p[2] + " large trend has value/time axes")
                compare(chart.statisticsVisible, true,
                        p[2] + " large trend has average/peak context")
            }
        }

        function test_value_micro_shows_the_number_alone() {
            var w = shape(423, 306, "compact", { url: "http://x/y", mode: "value", jsonPath: "d.v" })
            seedValue(128); wait(32)
            compare(w.rich, false, "no trend, no path caption on a half-cell")
        }

        function test_narrow_high_scale_header_is_complete_and_accessible() {
            hS.theme.textScale = 1.45
            hS.theme.fontChoice = "lexend"
            var w = shape(278, 654, "tall",
                          { url: "http://x/y", mode: "value" })
            seedValue(42.7); wait(32)
            compare(w.narrowHeader, true)
            compare(w.title, "HTTP",
                    "the constrained visual title uses a complete abbreviation")
            compare(w.Accessible.name, "HTTP / JSON",
                    "the accessibility name keeps the full widget identity")
        }

        function test_wide_high_scale_max_reading_and_unit_fit() {
            hS.theme.textScale = 1.45
            hS.theme.fontChoice = "hyperlegible"
            var w = shape(557, 327, "wide",
                          { url: "http://x/y", mode: "value",
                            jsonPath: "production.regions.europe.latency",
                            unit: "milliseconds", decimals: 6 })
            seedValue(999999.999999)
            w.hist = [31, 36, 29, 42, 55, 48, 61, 44]
            wait(32)
            var value = named(w, "httpValueLabel")
            var unit = named(w, "httpUnitLabel")
            verify(value !== null && unit !== null,
                   "the reading and its configured unit are rendered")
            compare(value.text, "999999.999999")
            compare(unit.text, "milliseconds")
            verify(!value.truncated && value.contentWidth <= value.width + 0.5,
                   "the maximum-precision reading fits its allocated column")
            verify(!unit.truncated && unit.contentWidth <= unit.width + 0.5,
                   "the complete unit fits without abbreviation")
            verify(value.font.pixelSize >= hS.theme.fontMinimum,
                   "the reading stays at or above the selected type floor")
            verify(unit.font.pixelSize >= hS.theme.fontMinimum,
                   "the unit stays at or above the selected type floor")
            verify(w.Accessible.description.indexOf("999999.999999") >= 0
                   && w.Accessible.description.indexOf("milliseconds") >= 0,
                   "the accessible reading preserves value and unit")
        }

        function test_micro_error_wraps_and_keeps_recovery_context() {
            hS.theme.textScale = 1.15
            hS.theme.fontChoice = "hyperlegible"
            var w = shape(278, 327, "compact",
                          { url: "http://x/y", mode: "value",
                            httpErr: "Endpoint returned an oversized response",
                            httpHelp: "Reduce the response size or select a narrower JSON path." })
            wait(32)
            var error = named(w, "httpReadingContext")
            verify(error !== null && error.visible, "the error replaces the reading")
            compare(error.text, "Endpoint returned an oversized response")
            verify(!error.truncated && error.contentWidth <= error.width + 0.5,
                   "the complete error wraps inside the micro tile")
            verify(error.font.pixelSize >= hS.theme.fontMinimum,
                   "the wrapped error stays at the selected type floor")
            verify(w.Accessible.description.indexOf(
                       "Endpoint returned an oversized response") >= 0,
                   "accessibility retains the complete error")
            verify(w.Accessible.description.indexOf(
                       "Reduce the response size") >= 0,
                   "accessibility retains recovery guidance even when it is not visual")
        }

        // ── mode: list - the same rule calendar applies to maxEvents ─────────
        // `listMax` is a MAXIMUM; the size decides how many of those fit.
        function test_list_never_shows_more_rows_than_the_user_asked_for() {
            var w = shape(696, 1637, "large", { url: "http://x/y", mode: "list", listMax: 3 })
            seedList(12); wait(32)
            verify(w.listRowsFit > 12, "a 1x2 portrait box has room for far more")
            compare(w.listShown, 3, "but the user said 3 rows, so it shows 3")
            compare(visibleListRows(w), 3)
        }
        function test_list_drops_the_tail_rather_than_overflowing_a_small_tile() {
            var w = shape(423, 306, "compact", { url: "http://x/y", mode: "list", listMax: 12 })
            seedList(12); wait(32)
            verify(w.listShown < 12,
                   "a 306px half-cell cannot hold twelve rows, so it shows fewer ("
                   + w.listShown + ")")
            verify(w.listShown > 0, "but it still lists the ones that fit")
            compare(visibleListRows(w), w.listShown, "every counted row is rendered")
        }
        function test_list_never_invents_rows_it_does_not_have() {
            var w = shape(696, 1637, "large", { url: "http://x/y", mode: "list", listMax: 12 })
            seedList(2); wait(32)
            compare(w.listShown, 2, "two items exist, so two rows")
        }
        function test_list_rows_scale_with_the_box() {
            var small = shape(423, 306, "compact", { url: "http://x/y", mode: "list", listMax: 12 })
            seedList(12); wait(32)
            var smallH = small.listRowH
            var big = shape(696, 1637, "large", { url: "http://x/y", mode: "list", listMax: 12 })
            seedList(12); wait(32)
            verify(big.listRowH > smallH,
                   "a taller box earns taller rows (" + smallH + " → " + big.listRowH + ")")
        }

        // ── the unconfigured state - what SHIPS in the presets ───────────────
        // It must stay legible at EVERY size x mode, because a freshly added
        // tile has no URL yet.
        function test_unconfigured_slot_is_legible_at_every_size_and_mode() {
            var modes = ["value", "gauge", "list"]
            for (var m = 0; m < modes.length; m++) {
                for (var i = 0; i < allSizes.length; i++) {
                    var c = allSizes[i]
                    var w = shape(c[0], c[1], c[2], { url: "", mode: modes[m] })
                    var tag = modes[m] + " " + c[0] + "x" + c[1]
                    var hints = findAllNodes(w, function (n) {
                        return n.hasOwnProperty("text")
                               && String(n.text).indexOf("Add a URL in settings") >= 0
                               && root.effVisible(n)
                    }, [])
                    compare(hints.length, 1, tag + ": the prompt is shown when no URL is set")
                    verify(hints[0].font.pixelSize >= 11,
                           tag + ": the prompt stays legible (" + hints[0].font.pixelSize + "px)")
                    verify(hints[0].width <= c[0],
                           tag + ": the prompt fits inside the tile")
                }
            }
        }

        // The refresh control is a real touch target at every size that hosts it,
        // and the half-cell hosts the READOUT instead of a shrunken button.
        function test_refresh_is_touch_sized_or_absent() {
            for (var i = 0; i < allSizes.length; i++) {
                var c = allSizes[i]
                var w = shape(c[0], c[1], c[2], { url: "http://x/y", mode: "value" })
                seedValue(42); wait(32)
                var tag = c[0] + "x" + c[1]
                var mas = findAllNodes(w, function (n) {
                    return n.hasOwnProperty("pressed") && n.hasOwnProperty("containsMouse")
                           && root.effVisible(n)
                }, [])
                if (w.micro) {
                    compare(mas.length, 0,
                            tag + ": the half-cell leaves refreshing to the poll + the overlay")
                } else {
                    compare(mas.length, 1, tag + ": the refresh control is on the tile")
                    verify(mas[0].parent.height >= hS.theme.touchTertiary,
                           tag + ": refresh is " + mas[0].parent.height + "px >= "
                           + hS.theme.touchTertiary)
                }
            }
        }

        // The list model must be the COUNT: a poll must not rebuild every row.
        function test_a_poll_does_not_rebuild_the_list_delegates() {
            var w = shape(696, 819, "compact", { url: "http://x/y", mode: "list", listMax: 5 })
            seedList(5); wait(32)
            var rows = findAllNodes(w, function (n) {
                return n.hasOwnProperty("text") && /^• service-/.test(String(n.text))
                       && root.effVisible(n)
            }, [])
            compare(rows.length, 5)
            var first = rows[0]
            // A new reading with the same shape: values change, delegates live on.
            hS.storeCtl.patchSettings(curId, {
                httpList: ["service-0: DEGRADED", "service-1: ok", "service-2: ok",
                           "service-3: ok", "service-4: ok"] })
            wait(32)
            compare(first.text, "• service-0: DEGRADED",
                    "the SAME delegate re-rendered - it was not destroyed and rebuilt")
        }
    }
}
