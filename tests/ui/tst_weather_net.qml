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

        // The five fields above reach the PROVIDER. Until the fixture carried
        // them (audit 2026-08-03) nothing checked that they come back out again:
        // WeatherWidget.qml:246-250 parsed `undefined` in every test, so
        // humidity/wind/rain stayed NaN and rendered "-".
        function test_current_conditions_are_parsed_from_the_payload() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { lat: 35.68, lon: 139.69 })
            w.refresh()
            lastFake.resolveWith(200, Fx.FORECAST_VALID)
            compare(w.providerState, "fresh")
            compare(Math.round(w.humidity), 67, "humidity comes from relative_humidity_2m")
            compare(w.windSpeed, 12.4, "wind comes from wind_speed_10m")
            compare(w.precipitation, 1.2, "rain comes from precipitation")
        }

        // The five fields added for "more than a temperature". Each is requested
        // in the same call, so the cost is parse + layout, not another fetch.
        // COVERS: schema:weather.units
        function test_the_extra_current_conditions_are_parsed() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { lat: 35.68, lon: 139.69 })
            w.refresh()
            var u = lastFake.url
            for (var i = 0; i < 5; i++) {
                var f = ["precipitation_probability", "wind_direction_10m", "uv_index",
                         "cloud_cover", "surface_pressure"][i]
                verify(u.indexOf(f) >= 0, "the request asks for " + f)
            }
            lastFake.resolveWith(200, Fx.FORECAST_VALID)
            compare(Math.round(w.precipChance), 80)
            compare(Math.round(w.windDirection), 315)
            compare(w.cloudCover, 42)
            compare(Math.round(w.pressure), 1013)
            verify(Math.abs(w.uvIndex - 6.4) < 0.01)
        }

        // A bearing in degrees is data; "NW" is information.
        function test_wind_direction_reads_as_a_compass_point_data() {
            return [
                { tag: "north", deg: 0, want: "N" }, { tag: "east", deg: 90, want: "E" },
                { tag: "south", deg: 180, want: "S" }, { tag: "west", deg: 270, want: "W" },
                { tag: "north-west", deg: 315, want: "NW" },
                { tag: "wraps", deg: 359, want: "N" },
                { tag: "rounds-to-nearest", deg: 23, want: "NNE" },
                { tag: "negative-normalises", deg: -90, want: "W" }
            ]
        }
        function test_wind_direction_reads_as_a_compass_point(data) {
            compare(h.item.compassPoint(data.deg), data.want,
                    data.deg + " degrees reads as " + data.want)
        }

        function test_an_absent_bearing_is_omitted_not_guessed() {
            compare(h.item.compassPoint(NaN), "", "no bearing means no compass point")
            compare(h.item.compassPoint(undefined), "")
        }

        // "Do I need an umbrella" is a probability: 0.2 mm at 90% is a wet walk,
        // 2 mm at 10% is a dry one. The tile leads with the chance and falls back
        // to the millimetre reading only when the provider omits it.
        function test_rain_leads_with_the_chance_and_falls_back_to_the_amount() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { lat: 35.68, lon: 139.69 })
            w.refresh(); lastFake.resolveWith(200, Fx.FORECAST_VALID)
            compare(w.rainText, "80%", "a chance is what the tile leads with")

            w.refresh()
            lastFake.resolveWith(200, JSON.stringify({
                current: { temperature_2m: 21.4, apparent_temperature: 19.8,
                           weather_code: 3, precipitation: 1.2 },
                daily: { time: ["2026-07-13"], weather_code: [3],
                         temperature_2m_max: [24.1], temperature_2m_min: [12.3] }
            }))
            compare(w.rainText, "1.2 mm", "no probability falls back to the amount")
        }

        // WHO/WMO bands: a bare number does not say whether to care.
        function test_uv_index_is_banded_data() {
            return [ { tag: "low", uv: 2, want: "Low" }, { tag: "moderate", uv: 5, want: "Moderate" },
                     { tag: "high", uv: 7, want: "High" }, { tag: "very-high", uv: 9, want: "Very high" },
                     { tag: "extreme", uv: 11, want: "Extreme" } ]
        }
        function test_uv_index_is_banded(data) {
            compare(h.item.uvBand(data.uv), data.want, "UV " + data.uv + " is " + data.want)
        }

        // A provider that omits a field must shorten the line, never print NaN.
        function test_missing_extras_shorten_the_line_rather_than_printing_nan() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { lat: 35.68, lon: 139.69 })
            w.refresh()
            lastFake.resolveWith(200, JSON.stringify({
                current: { temperature_2m: 21.4, apparent_temperature: 19.8, weather_code: 3 },
                daily: { time: ["2026-07-13"], weather_code: [3],
                         temperature_2m_max: [24.1], temperature_2m_min: [12.3] }
            }))
            compare(w.providerState, "fresh", "a reading without the extras is still a reading")
            compare(w.rainText, "-")
            compare(w.windText, "-")
            compare(w.uvText, "-")
            var texts = []
            function collect(n) {
                if (!n) return
                if (n.text !== undefined && n.visible) texts.push("" + n.text)
                var k = n.children
                for (var i = 0; k && i < k.length; i++) collect(k[i])
            }
            collect(w)
            var joined = texts.join(" | ")
            verify(joined.indexOf("NaN") < 0, "nothing renders NaN (" + joined.slice(0, 200) + ")")
            verify(joined.indexOf("undefined") < 0, "and nothing renders undefined")
        }

        // Open-Meteo returns "YYYY-MM-DDTHH:MM"; the widget slices [11,16]. A
        // provider that changed the format would have produced silent garbage.
        function test_sunrise_and_sunset_are_sliced_to_local_clock_times() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { lat: 35.68, lon: 139.69 })
            w.refresh()
            lastFake.resolveWith(200, Fx.FORECAST_VALID)
            compare(w.sunrise, "05:12", "the FIRST day's sunrise, as HH:MM")
            compare(w.sunset, "21:34")
        }

        // A provider that omits them must not render "undefined".
        function test_missing_sun_times_are_empty_not_undefined() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { lat: 35.68, lon: 139.69 })
            w.refresh()
            lastFake.resolveWith(200, JSON.stringify({
                current: { temperature_2m: 21.4, apparent_temperature: 19.8,
                           weather_code: 3 },
                daily: { time: ["2026-07-13"], weather_code: [3],
                         temperature_2m_max: [24.1], temperature_2m_min: [12.3] }
            }))
            compare(w.providerState, "fresh")
            compare(w.sunrise, "", "absent sunrise is empty, never the string 'undefined'")
            compare(w.sunset, "")
        }

        // The unit settings reach the provider URL (asserted above) AND the
        // screen. Open-Meteo converts server-side, so the widget only relabels -
        // which means a wrong symbol mislabels a correct number: "12 km/h" when
        // the user asked for and received m/s. Nothing asserted windSym or
        // precipitationSym; "km/h", "m/s" and "in" appeared in no test at all.
        function test_unit_symbols_reach_the_card_data() {
            return [
                { tag: "kmh-default", wind: "kmh", precip: "mm", sym: "km/h", psym: "mm" },
                { tag: "mph", wind: "mph", precip: "mm", sym: "mph", psym: "mm" },
                { tag: "ms", wind: "ms", precip: "mm", sym: "m/s", psym: "mm" },
                { tag: "inch", wind: "kmh", precip: "inch", sym: "km/h", psym: "in" }
            ]
        }
        function test_unit_symbols_reach_the_card(data) {
            var w = h.item
            h.storeCtl.patchSettings("test-instance",
                { lat: 35.68, lon: 139.69,
                  windUnits: data.wind, precipitationUnits: data.precip })
            w.refresh()
            lastFake.resolveWith(200, Fx.FORECAST_VALID)
            compare(w.windSym, data.sym,
                    data.wind + " must be labelled " + data.sym
                    + " - the provider already converted the number, so a wrong "
                    + "symbol mislabels a correct value")
            compare(w.precipitationSym, data.psym)

            // And it must be the string the user actually sees, not just a
            // property: the roomy summary composes value + symbol by hand.
            var texts = []
            function collect(node) {
                if (!node) return
                if (node.text !== undefined && node.visible) texts.push("" + node.text)
                var kids = node.children || []
                for (var i = 0; i < kids.length; i++) collect(kids[i])
            }
            collect(w)
            // This harness is not `roomy`, so the standalone weatherConditionSummary
            // tiles are hidden and the composed detail line is the visible surface.
            var joined = texts.join(" | ")
            verify(joined.indexOf("Wind 12 " + data.sym) >= 0,
                   "the rendered wind reading carries the chosen unit (looked for "
                   + "'Wind 12 " + data.sym + "' in " + JSON.stringify(joined) + ")")
            // The line now leads with the CHANCE ("Rain 80%") and carries the
            // amount after it, so the unit travels with the amount clause.
            verify(joined.indexOf("· 1.2 " + data.psym) >= 0,
                   "and so does the rendered rain amount (in " + JSON.stringify(joined) + ")")
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
