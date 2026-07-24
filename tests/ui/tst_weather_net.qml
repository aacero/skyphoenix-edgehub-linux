import QtQuick
import QtTest
import "fixtures.js" as Fx
import "../../ui/qml/widgets" as W

// ─────────────────────────────────────────────────────────────────────────
// tst_weather_net - network path of ui/qml/widgets/WeatherWidget.qml, driven
// entirely offline through the `xhrFactory` seam (handed to NetHub, which the
// widget routes both of its requests through). A FakeXHR (fixtures.js) captures
// the request URL and resolves ONLY on an explicit test call (resolveWith /
// fireTimeout) - no wall-clock waits, no real sockets.
//
// Covers: forecast URL construction (lat/lon/units/forecast_days), geocode URL
// (encodeURIComponent of the city), every fixture → widget state mapping (valid
// forecast → loaded/rendered, non-200 → Offline, missing daily → No data,
// malformed → Parse error, timeout → Timed out; geocode valid → settings
// patched, empty → City not found), and - since E8 - that the egress gate's
// kill switch and host allowlist actually govern both requests.
// ─────────────────────────────────────────────────────────────────────────
Item {
    id: root
    width: 760; height: 620

    WidgetHarness {
        id: h; anchors.fill: parent
        widgetFile: "WeatherWidget.qml"; expanded: true
    }
    WidgetHarness {
        id: hShared
        width: 1; height: 1; visible: false; active: false
        widgetFile: "WeatherWidget.qml"; expanded: false
    }

    // Stands in for the app-global gate Dashboard injects, so the tests can drive
    // `offline` / `allowHosts` the way managed config does.
    W.NetHub { id: gate }

    function clearSettings(harness) {
        var s = harness.storeCtl.settingsFor("test-instance")
        for (var k in s) delete s[k]
        harness.storeCtl._touchSettings()
    }

    // ── forecast URL construction ────────────────────────────────────────
    TestCase {
        name: "WeatherNetForecastUrl"
        when: windowShown
        property var lastFake: null
        function init() {
            tryVerify(function () { return h.ready }, 3000)
            clearSettings(h); h.active = false
            h.item.netHub = null
            h.item._hub()._sharedProviders = ({})
            h.item._hub().sharedRevision = 0
            var tc = this
            h.item.xhrFactory = function () { tc.lastFake = Fx.makeFakeXHR(); return tc.lastFake }
        }

        function test_unconfigured_location_makes_no_request() {
            var w = h.item
            lastFake = null
            w.refresh()
            compare(lastFake, null, "setup-required weather does not send a default-city request")
            compare(w.locationConfigured, false)
            compare(w.errorText, "Set a location")
            compare(w.providerState, "unconfigured")
            compare(w.status, "Setup")
        }

        function test_config_flows_into_forecast_url() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance",
                { lat: 35.68, lon: 139.69, units: "fahrenheit",
                  windUnits: "mph", precipitationUnits: "inch", forecastDays: 7 })
            w.refresh()
            compare(w.providerState, "loading")
            compare(w.status, "Loading")
            var u = lastFake.url
            verify(u.indexOf("latitude=35.68") >= 0, "configured latitude used")
            verify(u.indexOf("longitude=139.69") >= 0, "configured longitude used")
            verify(u.indexOf("temperature_unit=fahrenheit") >= 0, "fahrenheit adds the unit override")
            verify(u.indexOf("wind_speed_unit=mph") >= 0, "wind units reach the provider")
            verify(u.indexOf("precipitation_unit=inch") >= 0, "precipitation units reach the provider")
            verify(u.indexOf("forecast_days=8") >= 0, "7 forecast days → forecast_days=8")
        }
    }

    TestCase {
        name: "WeatherSharedProvider"
        when: windowShown
        property var firstFake: null
        property int secondFactoryCalls: 0

        function init() {
            tryVerify(function () { return h.ready && hShared.ready }, 3000)
            clearSettings(h)
            clearSettings(hShared)
            h.active = false
            hShared.active = false
            gate.offline = false
            gate.allowHosts = []
            gate.requests = 0
            gate.blocked = 0
            gate._sharedProviders = ({})
            gate.sharedRevision = 0
            h.storeCtl.patchSettings("test-instance",
                { lat: 48.2, lon: 16.37, place: "Vienna" })
            hShared.storeCtl.patchSettings("test-instance",
                { lat: 48.2, lon: 16.37, place: "Vienna" })
            h.item.netHub = gate
            hShared.item.netHub = gate
            var tc = this
            h.item.xhrFactory = function () {
                tc.firstFake = Fx.makeFakeXHR()
                return tc.firstFake
            }
            hShared.item.xhrFactory = function () {
                tc.secondFactoryCalls++
                return Fx.makeFakeXHR()
            }
        }
        function cleanup() {
            h.item.netHub = null
            hShared.item.netHub = null
        }

        function test_two_hosts_share_one_inflight_and_result() {
            h.item.refresh(false)
            verify(firstFake !== null && firstFake.sent)
            hShared.item.refresh(false)
            compare(secondFactoryCalls, 0, "second host does not duplicate the request")
            compare(hShared.item.providerState, "loading")
            firstFake.resolveWith(200, Fx.FORECAST_VALID)
            compare(h.item.loaded, true)
            compare(hShared.item.loaded, true, "second host receives the shared result")
            fuzzyCompare(hShared.item.curTemp, 21.4, 0.001)
            compare(gate.requests, 1)
        }
    }

    // ── forecast response → widget state ─────────────────────────────────
    TestCase {
        name: "WeatherNetForecastStates"
        when: windowShown
        property var lastFake: null
        function init() {
            tryVerify(function () { return h.ready }, 3000)
            clearSettings(h); h.active = false
            h.item.netHub = null
            h.item._hub()._sharedProviders = ({})
            h.item._hub().sharedRevision = 0
            h.storeCtl.patchSettings("test-instance", { lat: 48.2, lon: 16.37, place: "Vienna" })
            h.item.loaded = false; h.item.errorText = ""   // reset render state between cases
            var tc = this
            h.item.xhrFactory = function () { tc.lastFake = Fx.makeFakeXHR(); return tc.lastFake }
        }
        function drive(status, body) { h.item.refresh(); lastFake.resolveWith(status, body) }

        function test_valid_forecast_renders() {
            var w = h.item
            w.nowMsOverride = 800000
            drive(200, Fx.FORECAST_VALID)
            compare(w.loaded, true, "valid payload marks the tile loaded")
            compare(w.errorText, "", "no error on success")
            fuzzyCompare(w.curTemp, 21.4, 0.001, "current temperature parsed")
            fuzzyCompare(w.feels, 19.8, 0.001, "apparent temperature parsed")
            compare(w.curCode, 3, "current weather code parsed")
            compare(w.days.length, 5, "five daily rows parsed")
            compare(w.days[0].day, "Today", "first row labelled Today")
            compare(w.days[1].max, 23, "day-2 max rounded from 22.6")
            compare(w.lastSuccessAt, 800000)
            compare(w.stale, false)
            compare(w.providerState, "fresh")
            w.nowMsOverride = 800000 + w.refreshSec * 2000
            compare(w.stale, true)
            compare(w.providerState, "stale")
            compare(w.status, "Stale")
            w.nowMsOverride = -1
        }

        function test_non_200_goes_offline() {
            var w = h.item
            drive(200, Fx.FORECAST_VALID)
            drive(503, "")
            compare(w.loaded, true, "a server error preserves the last useful reading")
            compare(w.errorText, "Unavailable", "server rejection is distinct from offline")
            compare(w.providerState, "error")
            compare(w.status, "Error")
        }

        function test_missing_daily_yields_no_forecast() {
            var w = h.item
            drive(200, Fx.FORECAST_MISSING_DAILY)
            compare(w.loaded, false, "missing daily.time is not a valid render")
            compare(w.errorText, "No data", "missing fields → No data")
            compare(w.providerState, "error")
        }

        function test_malformed_body_is_parse_error() {
            var w = h.item
            drive(200, Fx.MALFORMED_JSON)
            compare(w.loaded, false, "un-parseable body is not loaded")
            compare(w.errorText, "Parse error", "malformed JSON → Parse error")
        }

        function test_timeout_sets_timed_out() {
            var w = h.item
            w.refresh()
            compare(w.loaded, false, "no data yet")
            lastFake.fireTimeout()
            compare(w.errorText, "Timed out", "an unresolved socket times out")
            compare(w.providerState, "disconnected")
            compare(w.status, "Offline")
        }

        // A superseded (aborted) request must not clobber the newer one's result.
        function test_stale_request_is_ignored_after_supersede() {
            var w = h.item
            w.refresh()
            var stale = lastFake
            w.refresh()               // supersedes: aborts `stale`, installs a new fake
            verify(stale.aborted, "the older in-flight request is aborted")
            var fresh = lastFake
            fresh.resolveWith(200, Fx.FORECAST_VALID)
            compare(w.loaded, true, "the fresh request lands")
            stale.resolveWith(200, Fx.FORECAST_MISSING_DAILY)  // late callback from the aborted one
            compare(w.loaded, true, "the stale late callback is ignored (loaded stays true)")
            compare(w.errorText, "", "stale callback did not overwrite the good result")
        }

        function test_success_after_failure_reports_recovery() {
            var w = h.item
            w.nowMsOverride = 900000
            drive(503, "")
            compare(w.errorText, "Unavailable")
            drive(200, Fx.FORECAST_VALID)
            compare(w.errorText, "")
            compare(w.recentlyRecovered, true)
            compare(w.status, "Recovered")
            verify(w.stateHelp.indexOf("restored") >= 0)
            w.nowMsOverride = -1
        }
    }

    // ── geocode path ─────────────────────────────────────────────────────
    TestCase {
        name: "WeatherNetGeocode"
        when: windowShown
        property var lastFake: null
        function init() {
            tryVerify(function () { return h.ready }, 3000)
            clearSettings(h); h.active = false
            h.item.netHub = null
            var tc = this
            h.item.xhrFactory = function () { tc.lastFake = Fx.makeFakeXHR(); return tc.lastFake }
        }

        function test_geocode_url_encodes_city() {
            var w = h.item
            w.geocode("New York")
            compare(w.geocoding, true, "a valid name starts a lookup")
            verify(lastFake !== null, "factory used for geocode")
            var u = lastFake.url
            verify(u.indexOf("https://geocoding-api.open-meteo.com/v1/search") === 0, "hits the geocoding API")
            verify(u.indexOf("name=New%20York") >= 0, "city name is URL-encoded (" + u + ")")
            verify(u.indexOf("count=1") >= 0, "asks for a single best match")
        }

        function test_geocode_valid_patches_settings() {
            var w = h.item
            w.geocode("Tokyo")
            lastFake.resolveWith(200, Fx.GEOCODE_VALID)
            compare(w.geocoding, false, "lookup finished")
            var s = h.storeCtl.settingsFor("test-instance")
            fuzzyCompare(s.lat, 35.6895, 0.0001, "latitude persisted from the geocode result")
            fuzzyCompare(s.lon, 139.6917, 0.0001, "longitude persisted")
            compare(s.place, "Tokyo, Tokyo, JP", "labelled name/admin1/country persisted")
        }

        function test_geocode_empty_is_city_not_found() {
            var w = h.item
            w.geocode("Nowhereville")
            lastFake.resolveWith(200, Fx.GEOCODE_EMPTY)
            compare(w.geocoding, false, "lookup finished")
            compare(w.errorText, "City not found", "no results → City not found")
        }

        function test_geocode_malformed_is_lookup_failed() {
            var w = h.item
            w.geocode("Tokyo")
            lastFake.resolveWith(200, Fx.MALFORMED_JSON)
            compare(w.errorText, "Lookup failed", "un-parseable geocode body → Lookup failed")
        }
    }

    // ── egress gate (E8) ─────────────────────────────────────────────────
    // Weather used to build its own XHR, which put it outside the offline switch
    // and the allowlist entirely. Now that it routes through NetHub, both of its
    // requests must be refusable centrally - that is the whole point of the
    // migration, so assert it rather than trusting the call site.
    TestCase {
        name: "WeatherNetGate"
        when: windowShown
        property var lastFake: null
        function init() {
            tryVerify(function () { return h.ready }, 3000)
            clearSettings(h); h.active = false; lastFake = null
            h.storeCtl.patchSettings("test-instance", { lat: 48.2, lon: 16.37, place: "Vienna" })
            h.item.loaded = false; h.item.errorText = ""
            gate.offline = false; gate.allowHosts = []
            gate.requests = 0; gate.blocked = 0
            gate._sharedProviders = ({})
            gate.sharedRevision = 0
            h.item.netHub = gate
            var tc = this
            h.item.xhrFactory = function () { tc.lastFake = Fx.makeFakeXHR(); return tc.lastFake }
        }
        function cleanup() { gate.offline = false; gate.allowHosts = [] }

        function test_offline_refuses_the_forecast() {
            var w = h.item
            gate.offline = true
            w.refresh()
            compare(lastFake, null, "the kill switch refuses before any socket is opened")
            compare(gate.requests, 0, "nothing counted as sent")
            compare(gate.blocked, 1, "the gate counted the refusal (attestation)")
            compare(w.loaded, false, "no stale reading is presented as live")
            compare(w.errorText, "Offline", "the tile says why it has no data")
            compare(w.providerState, "disconnected")
            compare(w.status, "Offline")
        }

        // The city lookup is egress too - it was the second raw XHR in this file.
        function test_offline_refuses_the_geocode() {
            var w = h.item
            gate.offline = true
            w.geocode("Tokyo")
            compare(lastFake, null, "the geocode lookup is gated as well")
            compare(gate.blocked, 1, "counted as blocked")
            compare(w.geocoding, false, "the lookup settles instead of spinning forever")
            compare(w.errorText, "Offline")
        }

        function test_allowlist_excluding_open_meteo_blocks_the_forecast() {
            var w = h.item
            gate.allowHosts = ["intranet.example.com"]
            w.refresh()
            compare(lastFake, null, "an unlisted host never gets a socket")
            compare(gate.requests, 0, "not counted as sent")
            compare(gate.blocked, 1, "counted as blocked")
            compare(w.errorText, "Blocked", "the tile distinguishes policy from failure")
            compare(w.providerState, "blocked")
            compare(w.status, "Blocked")
        }

        // The allowlist is per-host: the forecast and the geocode live on
        // different Open-Meteo hosts, so listing one must not admit the other.
        function test_allowlist_is_per_host_not_per_domain() {
            var w = h.item
            gate.allowHosts = ["api.open-meteo.com"]
            w.refresh()
            verify(lastFake !== null && lastFake.sent, "the listed forecast host is admitted")
            lastFake = null
            w.geocode("Tokyo")
            compare(lastFake, null, "the unlisted geocoding host is still refused")
            compare(w.errorText, "Blocked")
        }

        function test_allowlisted_host_still_fetches_normally() {
            var w = h.item
            gate.allowHosts = ["api.open-meteo.com"]
            w.refresh()
            verify(lastFake !== null && lastFake.sent, "listing the host lets the forecast through")
            compare(gate.requests, 1, "counted as sent, by host")
            compare(gate.blocked, 0, "nothing refused")
            lastFake.resolveWith(200, Fx.FORECAST_VALID)
            compare(w.loaded, true, "and the reading lands exactly as before the gate")
            compare(w.errorText, "")
        }
    }
}
