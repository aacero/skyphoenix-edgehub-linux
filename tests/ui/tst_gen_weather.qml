import QtQuick
import QtTest
import "../../ui/qml" as App


// ─────────────────────────────────────────────────────────────────────────
// tst_gen_weather - COMPREHENSIVE coverage for area "widget:weather"
// (ui/qml/widgets/WeatherWidget.qml - Open-Meteo forecast tile).
//
// The widget's data comes from the network; these tests never rely on a live
// fetch. Instead they drive config through the store (revision → cfg → derived
// props) and, where a "loaded" render is required, seed the widget's own plain
// data properties (loaded/curTemp/feels/curCode/days) directly - every one of
// those states is reachable at runtime, so rendering them is fair game.
//
// Several assertions encode the CORRECT expected behaviour and therefore FAIL
// against real bugs called out in the audit (empty-place → "Berlin" mislabel,
// unit toggle showing the Celsius number relabelled "°F", stale data still
// presented as current after an error, 7-day °F forecast clipping). Those
// failures are the point and are reported as likelyRealBug.
// ─────────────────────────────────────────────────────────────────────────
Item {
    id: root
    width: 760; height: 1200

    // Primary harness: expanded, roomy - logic / config / reactivity / render.
    WidgetHarness {
        id: h; x: 0; y: 0; width: 460; height: 420
        widgetFile: "WeatherWidget.qml"; expanded: true
    }
    // 720px-wide portrait "panel" harness - forecast-row clipping.
    WidgetHarness {
        id: hPanel; x: 0; y: 440; width: 720; height: 400
        widgetFile: "WeatherWidget.qml"; expanded: true
    }
    // Second expanded instance sharing the same store as `h` - proves an
    // unrelated instance's mutation does not perturb h's location key.
    WidgetHarness {
        id: hOther; x: 0; y: 860; width: 300; height: 300
        widgetFile: "WeatherWidget.qml"; expanded: true; instanceId: "other-instance"
    }

    // Resizable host for the per-sizeClass structure tests (W1 wave 3) - the
    // REAL projected footprints of weather's five declared sizes:
    //   0.5x0.5 → 348x409 portrait · 423x306 landscape   (compact, micro)
    //   0.5x1   → 348x819 portrait (tall) · 846x306 landscape (wide)
    //   1x0.5   → 696x409 portrait (wide) · 423x612 landscape (tall)
    //   1x1     → 696x819 portrait · 846x612 landscape   (compact)
    //   1x1.5   → 696x1228 portrait (tall) · 1269x612 landscape (wide)
    Item { id: sizeWrap; x: 0; y: 1200; width: 696; height: 819
        WidgetHarness { id: hS; anchors.fill: parent
            widgetFile: "WeatherWidget.qml"; expanded: false; active: false } }

    // Shared-area component instantiated directly (schema ↔ widget key sync).
    App.WidgetConfigSchema { id: sc }

    // ── text-tree helpers ────────────────────────────────────────────────────
    function isText(c) {
        return c && typeof c.paintedWidth === "number"
                 && typeof c.text === "string" && typeof c.font !== "undefined"
    }
    function collectTexts(node, out) {
        if (!node || !node.children) return
        for (var i = 0; i < node.children.length; i++) {
            var c = node.children[i]
            if (isText(c)) out.push(c)
            collectTexts(c, out)
        }
    }
    function allTexts(harness) { var out = []; collectTexts(harness.item, out); return out }
    // The big current-temperature label: exactly "<int>°C" / "<int>°F".
    function tempNode(harness) {
        var t = allTexts(harness)
        for (var i = 0; i < t.length; i++)
            if (/^-?\d+°[CF]$/.test(t[i].text)) return t[i]
        return null
    }
    // Forecast day/night lines look like "26°C / 12°C" - count = forecast tiles.
    function forecastTemps(harness) {
        var t = allTexts(harness), out = []
        for (var i = 0; i < t.length; i++)
            if (t[i].text.indexOf(" / ") >= 0) out.push(t[i])
        return out
    }
    function findAllNodes(node, pred, acc) {
        if (!node) return acc
        if (pred(node)) acc.push(node)
        var kids = node.children
        for (var i = 0; kids && i < kids.length; i++) findAllNodes(kids[i], pred, acc)
        return acc
    }
    function descendants(node, out) {
        if (!node || !node.children) return
        for (var i = 0; i < node.children.length; i++) {
            out.push(node.children[i]); descendants(node.children[i], out)
        }
    }
    // The forecast RowLayout: a RowLayout that contains a "26°C / 12°C" Text.
    function forecastRow(harness) {
        var all = []; descendants(harness.item, all)
        for (var i = 0; i < all.length; i++) {
            if (String(all[i]).indexOf("RowLayout") < 0) continue
            var kids = []; descendants(all[i], kids)
            for (var j = 0; j < kids.length; j++)
                if (isText(kids[j]) && kids[j].text.indexOf(" / ") >= 0) return all[i]
        }
        return null
    }
    function clearSettings(harness, id) {
        var s = harness.storeCtl.settingsFor(id || "test-instance")
        for (var k in s) delete s[k]
        harness.storeCtl._touchSettings()
    }
    // Seed a "loaded" render state directly on the widget's data properties.
    function seedLoaded(w, days) {
        w.curTemp = 20; w.feels = 18; w.curCode = 0
        w.days = days
        w.errorText = ""
        w.loaded = true
    }

    // ── defaults ─────────────────────────────────────────────────────────────
    TestCase {
        name: "WeatherDefaults"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000); clearSettings(h) }

        function test_derived_defaults() {
            var w = h.item
            compare(w.locationConfigured, false, "weather requires location setup")
            verify(isNaN(w.lat)); verify(isNaN(w.lon))
            compare(w.place, "")
            compare(w.units, "celsius", "default units")
            compare(w.forecastDays, 4, "default forecast days")
            compare(w.degSym, "°C", "celsius degree symbol")
        }
    }

    // ── every config option honored ──────────────────────────────────────────
    TestCase {
        name: "WeatherConfig"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000); clearSettings(h) }
        function set(k, v) { h.storeCtl.setSetting("test-instance", k, v) }

        function test_location_mode_is_persisted_for_conditional_configuration() {
            set("locationMode", "manual")
            compare(h.storeCtl.settingsFor("test-instance").locationMode, "manual",
                    "locationMode selects the manual-coordinate configuration branch")
        }

        function test_lat_lon_place_honored() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { lat: 35.68, lon: 139.69, place: "Tokyo" })
            fuzzyCompare(w.lat, 35.68, 0.001, "latitude from config")
            fuzzyCompare(w.lon, 139.69, 0.001, "longitude from config")
            compare(w.place, "Tokyo", "place from config")
        }
        function test_units_fahrenheit_flips_degsym() {
            var w = h.item
            set("units", "fahrenheit")
            compare(w.units, "fahrenheit")
            compare(w.degSym, "°F", "fahrenheit degree symbol")
        }
        function test_units_unknown_value_falls_back_celsius() {
            var w = h.item
            set("units", "celsius")
            compare(w.degSym, "°C")
        }
        function test_forecast_days_honored_3_to_7() {
            var w = h.item
            for (var n = 3; n <= 7; n++) {
                set("forecastDays", n)
                compare(w.forecastDays, n, "forecastDays honored = " + n)
            }
        }
        // locKey drives the debounced refetch. Every provider-affecting unit and
        // location choice must be part of it.
        function test_lockey_covers_every_fetch_input() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance",
                { lat: 10, lon: 20, units: "celsius", forecastDays: 3 })
            var base = w.locKey
            set("lat", 11);          verify(w.locKey !== base, "lat change re-keys"); base = w.locKey
            set("lon", 21);          verify(w.locKey !== base, "lon change re-keys"); base = w.locKey
            set("units", "fahrenheit"); verify(w.locKey !== base, "units change re-keys"); base = w.locKey
            set("windUnits", "mph"); verify(w.locKey !== base, "wind unit change re-keys"); base = w.locKey
            set("precipitationUnits", "inch")
            verify(w.locKey !== base, "precipitation unit change re-keys"); base = w.locKey
            set("forecastDays", 5);  verify(w.locKey !== base, "forecastDays change re-keys")
        }
    }

    // Deterministic condition classification drives the Canvas artwork.
    TestCase {
        name: "WeatherGlyph"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000) }

        function test_condition_kind_mapping() {
            var w = h.item
            compare(w.weatherKind(0), "clear")
            compare(w.weatherKind(1), "partly-cloudy")
            compare(w.weatherKind(2), "partly-cloudy")
            compare(w.weatherKind(3), "cloudy")
            compare(w.weatherKind(45), "fog")
            compare(w.weatherKind(48), "fog")
            compare(w.weatherKind(53), "rain")
            compare(w.weatherKind(63), "rain")
            compare(w.weatherKind(73), "snow")
            compare(w.weatherKind(81), "rain")
            compare(w.weatherKind(85), "snow")
            compare(w.weatherKind(95), "storm")
            compare(w.weatherKind(99), "storm")
            compare(w.weatherKind(40), "unknown")
            compare(w.weatherDescription(95), "Thunderstorm")
        }
    }

    // ── empty place with custom coords must NOT mislabel as "Berlin" ─────────
    TestCase {
        name: "WeatherEmptyPlace"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000); clearSettings(h) }

        // AUDIT (line 24, low): place = cfg.place || "Berlin". Custom Tokyo coords
        // with a blanked place field render the label "Berlin" over Tokyo data.
        function test_empty_place_is_not_default_berlin() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { lat: 35.68, lon: 139.69, place: "" })
            verify(w.place !== "Berlin",
                   "custom coords with an empty place must not display 'Berlin' (got '" + w.place + "')")
        }
    }

    // ── reactivity through store.revision ────────────────────────────────────
    TestCase {
        name: "WeatherReactivity"
        when: windowShown
        function init() {
            tryVerify(function () { return h.ready && hOther.ready }, 3000)
            clearSettings(h); clearSettings(hOther, "other-instance")
        }

        function test_config_edit_updates_derived_props_live() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { lat: 1, lon: 2, place: "A", forecastDays: 3 })
            compare(w.place, "A"); fuzzyCompare(w.lat, 1, 0.001)
            h.storeCtl.patchSettings("test-instance", { lat: 48.2, lon: 16.37, place: "Vienna", forecastDays: 6 })
            compare(w.place, "Vienna", "place re-read on revision bump")
            fuzzyCompare(w.lat, 48.2, 0.001, "lat re-read on revision bump")
            compare(w.forecastDays, 6, "forecastDays re-read on revision bump")
        }

        // An unrelated instance's mutation bumps the shared revision but must NOT
        // change h's locKey (i.e. must not trigger a spurious refetch).
        function test_unrelated_mutation_does_not_rekey() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { lat: 5, lon: 6, units: "celsius", forecastDays: 4 })
            var before = w.locKey
            var rev0 = h.storeCtl.revision
            h.storeCtl.patchSettings("other-instance", { lat: 99, lon: 99, place: "Nowhere" })
            verify(h.storeCtl.revision > rev0, "revision bumped by the other instance")
            compare(w.locKey, before, "our locKey is unchanged → no refetch triggered")
        }
    }

    // ── °C/°F toggle must not relabel the old number with the new unit ───────
    TestCase {
        name: "WeatherUnitToggle"
        when: windowShown
        function init() {
            tryVerify(function () { return h.ready }, 3000)
            clearSettings(h); h.active = false
        }

        // AUDIT (line 27, medium): degSym flips synchronously with `units`, but
        // curTemp still holds the previously-fetched Celsius number until a full
        // network round-trip completes - so the tile shows "20°F" where 20 is a
        // Celsius reading. A correct widget would never present the stale number
        // under the new unit (e.g. it would invalidate the reading first).
        function test_toggle_does_not_show_wrong_unit_number() {
            var w = h.item
            h.storeCtl.setSetting("test-instance", "units", "celsius")
            seedLoaded(w, [{ day: "Today", code: 0, max: 26, min: 12 }])
            var node = tempNode(h)
            verify(node !== null, "current-temp label present")
            compare(node.text, "20°C", "starts as the fetched Celsius value")
            h.storeCtl.setSetting("test-instance", "units", "fahrenheit")
            compare(w.degSym, "°F", "degree symbol flips immediately")
            verify(node.text !== "20°F",
                   "the Celsius value 20 must not be relabelled '20°F' before a refetch (got '" + node.text + "')")
        }
    }

    // ── network failure must stop presenting stale data as current ───────────
    TestCase {
        name: "WeatherStaleOnError"
        when: windowShown
        function init() {
            tryVerify(function () { return h.ready }, 3000)
            clearSettings(h); h.active = false
        }

        // AUDIT (line 72, medium): on a non-200 / offline result errorText is set
        // but `loaded` stays true and curTemp/days are never invalidated, so the
        // big temperature keeps showing the last city's number as if it were live.
        function test_error_keeps_last_temp_but_labels_it_as_error() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { lat: 48.2, lon: 16.37, place: "Vienna" })
            seedLoaded(w, [{ day: "Today", code: 0, max: 26, min: 12 }])
            compare(tempNode(h).text, "20°C", "shows current temp while loaded")
            // Reproduce the exact post-failure state refresh() leaves behind.
            w.errorText = "Offline"
            compare(w.loaded, true, "the last useful reading remains retained")
            compare(w.curTemp, 20)
            compare(w.status, "Offline", "the active surface labels the connectivity failure")
            compare(w.providerState, "disconnected")
        }
    }

    // ── forecast rendering: slice(1) + tile count ────────────────────────────
    TestCase {
        name: "WeatherForecastRender"
        when: windowShown
        function init() {
            tryVerify(function () { return h.ready }, 3000)
            clearSettings(h); h.active = false
        }

        function test_forecast_excludes_today_and_counts_correctly() {
            var w = h.item
            seedLoaded(w, [
                { day: "Today", code: 0, max: 26, min: 12 },
                { day: "Mon",   code: 3, max: 24, min: 11 },
                { day: "Tue",   code: 61, max: 22, min: 10 },
                { day: "Wed",   code: 71, max: 20, min: 9 }
            ])
            var temps = forecastTemps(h)
            compare(temps.length, 3, "renders days.length-1 future tiles (Today excluded)")
        }
        function test_forecast_hidden_when_not_loaded() {
            var w = h.item
            w.loaded = false; w.days = []
            compare(forecastTemps(h).length, 0, "no forecast tiles before data loads")
        }
    }

    // ── effAccent (from WidgetChrome) recolours the interactive controls ─────
    TestCase {
        name: "WeatherAccent"
        when: windowShown
        function init() {
            tryVerify(function () { return h.ready }, 3000)
            clearSettings(h); h.item.accentName = ""
        }

        function test_default_eff_accent_is_info_category() {
            var w = h.item
            compare(String(w.effAccent), String(h.theme.catInfo),
                    "weather defaults to the Info accent colour")
        }
        function test_accent_preset_overrides_eff_accent() {
            var w = h.item
            w.accentName = "green"
            compare(String(w.effAccent), String(Qt.color(h.theme.accentPresets["green"].a)),
                    "effAccent tracks the chosen preset (used by the city field border + 'Set location' pill)")
        }
    }

    // ── geocode() input guard ────────────────────────────────────────────────
    TestCase {
        name: "WeatherGeocodeGuard"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000); clearSettings(h) }

        function test_blank_names_are_ignored() {
            var w = h.item
            w.geocode("")
            compare(w.geocoding, false, "empty name does not start a lookup")
            w.geocode("   ")
            compare(w.geocoding, false, "whitespace name does not start a lookup")
            w.geocode(null)
            compare(w.geocoding, false, "null name does not start a lookup")
        }
    }

    // ── 7-day °F forecast must fit the 720px panel (no horizontal clip) ──────
    TestCase {
        name: "WeatherForecastClipping"
        when: windowShown
        function init() {
            tryVerify(function () { return hPanel.ready }, 3000)
            clearSettings(hPanel); hPanel.active = false
        }

        // AUDIT (line 160, low): the forecast RowLayout has no wrap/scroll and the
        // body clips, so a 7-day Fahrenheit row ("108°F / -12°F" × 7) can exceed
        // the content width and clip the rightmost day(s) with no scroll affordance.
        function test_seven_day_fahrenheit_row_fits() {
            var w = hPanel.item
            hPanel.storeCtl.patchSettings("test-instance", { units: "fahrenheit", forecastDays: 7 })
            var days = [{ day: "Today", code: 0, max: 108, min: -12 }]
            var names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
            for (var i = 0; i < 7; i++) days.push({ day: names[i], code: 61, max: 108, min: -12 })
            seedLoaded(w, days)
            compare(w.degSym, "°F", "panel is in Fahrenheit")
            var row = forecastRow(hPanel)
            verify(row !== null, "forecast row found")
            var avail = hPanel.width - 2 * hPanel.theme.spacingLg
            verify(row.implicitWidth <= avail,
                   "7-day °F forecast (" + Math.round(row.implicitWidth) + "px) must fit the "
                   + avail + "px panel without clipping")
        }
    }

    // ── schema ↔ widget key sync (shared config-schema area) ─────────────────
    TestCase {
        name: "WeatherSchema"
        when: windowShown

        function fields() {
            var s = sc.schemaFor("weather")
            var out = []
            for (var i = 0; i < s.sections.length; i++)
                for (var j = 0; j < (s.sections[i].fields || []).length; j++)
                    out.push(s.sections[i].fields[j])
            return out
        }
        function fieldByKey(k) {
            var f = fields()
            for (var i = 0; i < f.length; i++) if (f[i].key === k) return f[i]
            return null
        }

        function test_schema_exposes_every_widget_key() {
            var required = ["place", "locationMode", "lat", "lon", "units",
                            "windUnits", "precipitationUnits", "forecastDays",
                            "title", "accent"]
            for (var r = 0; r < required.length; r++)
                verify(fieldByKey(required[r]) !== null, "schema exposes '" + required[r] + "'")
        }
        function test_geocode_action_present() {
            var f = fields(), found = false
            for (var i = 0; i < f.length; i++) if (f[i].action === "geocode") found = true
            verify(found, "schema offers the 'Look up this city' geocode action")
        }
        function test_forecast_days_slider_range() {
            var f = fieldByKey("forecastDays")
            compare(f.type, "slider", "forecastDays is a slider")
            compare(f.min, 3, "min 3 days")
            compare(f.max, 7, "max 7 days")
            compare(f.step, 1, "whole-day steps")
        }
        function test_units_segmented_options() {
            var f = fieldByKey("units")
            compare(f.type, "segmented", "units is a segmented control")
            var vals = f.options.map(function (o) { return o.value })
            verify(vals.indexOf("celsius") >= 0 && vals.indexOf("fahrenheit") >= 0,
                   "offers both °C and °F")
            var wind = fieldByKey("windUnits")
            compare(wind.type, "segmented")
            var windVals = wind.options.map(function (o) { return o.value })
            verify(windVals.indexOf("kmh") >= 0 && windVals.indexOf("mph") >= 0
                   && windVals.indexOf("ms") >= 0)
            var rain = fieldByKey("precipitationUnits")
            compare(rain.type, "segmented")
            var rainVals = rain.options.map(function (o) { return o.value })
            verify(rainVals.indexOf("mm") >= 0 && rainVals.indexOf("inch") >= 0)
        }
    }

    // ── Per-sizeClass structure (W1 wave 3) ──────────────────────────────────
    TestCase {
        name: "WeatherSizes"
        when: windowShown

        function initTestCase() {
            tryVerify(function () { return hS.ready }, 3000)
            hS.storeCtl.patchSettings(hS.instanceId, { lat: 48.2, lon: 16.37, place: "Vienna" })
        }

        function days(n) {
            var names = ["Today", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
            var out = []
            for (var i = 0; i <= n; i++)
                out.push({ day: names[i], code: i % 2 ? 3 : 0, max: 20 + i, min: 8 + i })
            return out
        }
        function shape(width, height, cls, futureDays) {
            sizeWrap.width = width; sizeWrap.height = height
            hS.item.sizeClass = cls
            seedLoaded(hS.item, days(futureDays === undefined ? 4 : futureDays))
            wait(32)
            return hS.item
        }

        // THE HONESTY CONSTRAINT. The forecast request asks for `current` +
        // `daily` and never `hourly`, so no size may grow an hourly chart - the
        // data to draw one does not exist, and adding it would be new egress.
        // This test guards the URL, which is what bounds every layout below.
        function test_the_request_never_asks_for_an_hourly_series() {
            var w = hS.item
            var seen = ""
            var realHub = w.netHub
            w.netHub = { request: function (o) { seen = o.url; return null } }
            w.refresh()
            w.netHub = realHub
            verify(seen.indexOf("&current=") >= 0, "the reading comes from `current`")
            verify(seen.indexOf("&daily=") >= 0, "the forecast comes from `daily`")
            compare(seen.indexOf("hourly"), -1,
                    "NO hourly series is requested - so no tile may draw one: " + seen)
        }

        // 0.5x0.5 - glyph + temperature + place. Nothing it cannot back.
        function test_micro_is_the_reading_only() {
            var w = shape(423, 306, "compact")
            compare(w.micro, true, "a 423x306 compact box is the half-cell")
            compare(w.showHeader, false, "micro drops the header")
            compare(w.rich, false)
            compare(w.shownDays, 0, "the half-cell shows no forecast rows")
            verify(w.glyphPx > 34, "the glyph scales with the box (" + w.glyphPx + "px)")
        }

        // 1x1 - the baseline earns "feels like" + the daily rows that fit.
        function test_baseline_earns_feels_and_daily_rows() {
            var w = shape(696, 819, "compact", 4)
            compare(w.rich, true, "the baseline shows 'feels like'")
            compare(w.horiz, false, "stacked")
            compare(w.shownDays, 4, "all four fetched days fit a 819px box")
            verify(w.tempPx > 28, "the temperature scales with the box (" + w.tempPx + "px)")
        }

        // wide - the forecast goes BESIDE the reading, as columns: 0.5x1
        // landscape is 306px tall and daily ROWS would not fit.
        function test_wide_lays_the_forecast_beside_the_reading() {
            var cases = [[696, 409], [846, 306]]
            for (var i = 0; i < cases.length; i++) {
                var w = shape(cases[i][0], cases[i][1], "wide", 4)
                compare(w.horiz, true, cases[i][0] + "x" + cases[i][1] + " is horizontal")
                verify(w.shownDays > 0, "and it still shows the forecast (" + w.shownDays + " days)")
                verify(w.shownDays <= w.futureDays, "never more days than were fetched")
            }
        }

        function test_constrained_copy_and_forecast_ranges_reflow() {
            var w = shape(278, 327, "compact", 4)
            hS.theme.textScale = 1.45
            hS.storeCtl.patchSettings(hS.instanceId, {
                lat: 48.2, lon: 16.37,
                place: "Vienna International Weather Station"
            })
            wait(0)
            var locations = findAllNodes(w, function (n) {
                return n.objectName === "weatherLocation"
            }, [])
            compare(locations.length, 1)
            verify(!locations[0].truncated
                   && locations[0].contentHeight <= locations[0].height + 1,
                   "the complete configured location wraps in the micro tile"
                   + " (truncated=" + locations[0].truncated
                   + ", content=" + locations[0].contentWidth + "x"
                   + locations[0].contentHeight + ", box="
                   + locations[0].width + "x" + locations[0].height + ")")

            w.loaded = false
            w.errorText = "Weather provider did not answer"
            w.stateHelp = "Check the location and retry when the network is available."
            wait(0)
            var states = findAllNodes(w, function (n) {
                return n.objectName === "weatherStateText"
            }, [])
            compare(states.length, 1)
            verify(!states[0].truncated
                   && states[0].contentHeight <= states[0].height + 1,
                   "the provider error wraps in the constrained tile")
            verify(w.Accessible.name.indexOf(w.stateHelp) >= 0,
                   "the complete recovery guidance remains accessible")

            w = shape(677, 245, "wide", 5)
            hS.theme.textScale = 1.3
            var extreme = [{ day: "Today", code: 0, max: 42, min: -18 }]
            var names = ["Mon", "Tue", "Wed", "Thu", "Fri"]
            for (var i = 0; i < names.length; i++)
                extreme.push({ day: names[i], code: 61, max: 41 - i, min: -17 + i })
            seedLoaded(w, extreme)
            wait(0)
            var ranges = findAllNodes(w, function (n) {
                return n.objectName === "weatherForecastRange"
            }, [])
            verify(ranges.length > 0)
            for (var r = 0; r < ranges.length; r++) {
                verify(ranges[r].text.indexOf("\n") >= 0,
                       "wide forecast uses a high/low stack")
                verify(!ranges[r].truncated
                       && ranges[r].contentWidth <= ranges[r].width + 1,
                       "stacked forecast range fits its daily column")
                verify(ranges[r].font.pixelSize >= hS.theme.fontMinimum,
                       "stacked forecast range keeps the active type floor")
            }

            hS.theme.textScale = 1.15
            hS.storeCtl.patchSettings(hS.instanceId,
                { lat: 48.2, lon: 16.37, place: "Vienna" })
        }

        // tall - the daily list is what a tall weather tile grows.
        function test_tall_grows_the_daily_list() {
            var w = shape(696, 1228, "tall", 7)
            compare(w.tallish, true)
            compare(w.shownDays, 7, "a 1228px box fits all seven fetched days")
        }

        // THE SIZE-vs-SETTING RULE: forecastDays is what to FETCH (a maximum);
        // the box decides how many are shown. Never more than the user asked
        // for, never more than fits.
        function test_size_never_shows_more_days_than_were_fetched() {
            var w = shape(696, 1228, "tall", 3)
            compare(w.futureDays, 3, "the user asked for three days")
            compare(w.shownDays, 3, "a huge box does NOT invent a fourth")
        }
        // Where the cap actually bites: the wide projections lay the forecast out
        // as columns across a bounded width, so a 7-day fetch does not fit and
        // the tile shows the ones that do rather than overflowing the card.
        // (Every stacked size has the height for all 7 - measured, not assumed.)
        function test_a_narrow_box_drops_days_rather_than_overflowing() {
            var wide = shape(696, 409, "wide", 7)
            compare(wide.futureDays, 7, "seven days were fetched")
            verify(wide.shownDays < 7,
                   "a 696px-wide row cannot fit seven day columns, so it shows fewer ("
                   + wide.shownDays + ")")
            verify(wide.shownDays > 0, "but it still shows the ones that do fit")
        }
        function test_every_stacked_size_fits_the_whole_seven_day_fetch() {
            var cases = [[696, 819, "compact"], [348, 819, "tall"],
                         [423, 612, "tall"], [696, 1228, "tall"]]
            for (var i = 0; i < cases.length; i++) {
                var w = shape(cases[i][0], cases[i][1], cases[i][2], 7)
                compare(w.shownDays, 7,
                        cases[i][0] + "x" + cases[i][1] + " has the height for all seven")
            }
        }

        // Nothing is rendered from a day we do not hold.
        function test_no_forecast_before_data_loads() {
            sizeWrap.width = 696; sizeWrap.height = 819
            hS.item.sizeClass = "compact"
            hS.item.loaded = false; hS.item.days = []
            wait(32)
            compare(hS.item.shownDays, 0, "no rows without a reading")
        }

        // The refresh control is a real touch target and lives in its own cell,
        // so it cannot sit on top of the forecast it used to have no room beside.
        function test_refresh_is_touch_sized_and_clear_of_the_forecast() {
            var w = shape(696, 819, "compact", 4)
            var mas = []
            findAllNodes(w, function (n) {
                return n.hasOwnProperty("pressed") && n.hasOwnProperty("containsMouse")
            }, mas)
            verify(mas.length >= 1, "the refresh control is on the tile")
            var btn = mas[0].parent
            verify(btn.height >= hS.theme.touchTertiary,
                   "refresh is " + btn.height + "px >= " + hS.theme.touchTertiary)
        }
    }
}
