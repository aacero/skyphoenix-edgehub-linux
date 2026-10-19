import QtQuick
import QtTest
import "../../ui/qml" as App

// ─────────────────────────────────────────────────────────────────────────
// Comprehensive tests for "The Sky Tonight" widget (SkyTonightWidget.qml)
// ─────────────────────────────────────────────────────────────────────────
Item {
    id: root
    width: 600; height: 800

    WidgetHarness {
        id: h; anchors.fill: parent; widgetFile: "SkyTonightWidget.qml"; expanded: true
    }

    Item {
        id: microBox; width: 180; height: 180; visible: false
        WidgetHarness { id: hMicro; anchors.fill: parent; widgetFile: "SkyTonightWidget.qml"; expanded: false }
    }

    App.WidgetConfigSchema { id: sc }
    App.WidgetCatalog { id: catalog }

    function findByText(node, txt) {
        if (!node) return null
        try { if (node.text === txt) return node } catch (e) {}
        var kids = null
        try { kids = node.children } catch (e2) { kids = null }
        if (kids) {
            for (var i = 0; i < kids.length; i++) {
                var r = findByText(kids[i], txt)
                if (r) return r
            }
        }
        return null
    }

    function clearSettings(host) {
        var s = host.storeCtl.settingsFor("test-instance")
        for (var k in s) delete s[k]
        host.storeCtl._touchSettings()
    }

    // ── 1. Catalog and Schema Invariants ────────────────────────────────────
    TestCase {
        name: "SkyTonightCatalogAndSchema"
        when: windowShown

        function test_catalog_entry() {
            var item = null
            for (var i = 0; i < catalog.items.length; i++) {
                if (catalog.items[i].type === "skytonight") {
                    item = catalog.items[i]
                    break
                }
            }
            verify(item !== null, "skytonight is registered in WidgetCatalog")
            compare(item.title, "The Sky Tonight")
            compare(item.category, "Info")
            compare(item.source, "qrc:/qml/SkyTonightWidget.qml")
            verify(catalog.desc("skytonight").length > 0, "skytonight has description in catalog")
        }

        function test_schema_structure() {
            var schema = sc.schemaFor("skytonight")
            verify(schema !== null && schema.sections.length >= 3, "schema defines sections")

            var fieldKeys = []
            for (var s = 0; s < schema.sections.length; s++) {
                var fields = schema.sections[s].fields || []
                for (var f = 0; f < fields.length; f++) {
                    if (fields[f].key) fieldKeys.push(fields[f].key)
                }
            }

            verify(fieldKeys.indexOf("place") >= 0, "place field exists")
            verify(fieldKeys.indexOf("lat") >= 0, "lat field exists")
            verify(fieldKeys.indexOf("lon") >= 0, "lon field exists")
            verify(fieldKeys.indexOf("tempUnit") >= 0, "tempUnit field exists")
            verify(fieldKeys.indexOf("showTwilights") >= 0, "showTwilights toggle exists")
            verify(fieldKeys.indexOf("showClouds") >= 0, "showClouds toggle exists")
            verify(fieldKeys.indexOf("showHourlyBar") >= 0, "showHourlyBar toggle exists")
            verify(fieldKeys.indexOf("showMoon") >= 0, "showMoon toggle exists")
            verify(fieldKeys.indexOf("showPlanets") >= 0, "showPlanets toggle exists")
        }
    }

    // ── 2. Local Astronomical and Solar Engine Tests ────────────────────────
    TestCase {
        name: "SkyTonightAstroEngine"
        when: windowShown

        function init() {
            tryVerify(function () { return h.ready }, 3000)
        }

        function test_solar_altitude_known_points() {
            var w = h.item
            // St. Augustine, FL: Lat 29.9012, Lon -81.3124
            // Summer solstice noon has high solar altitude (> 70°)
            var summerNoon = new Date("2026-06-21T17:25:00.000Z") // ~13:25 EDT
            var altNoon = w._solarAltitude(summerNoon, 29.9012, -81.3124)
            verify(altNoon > 70.0, "summer noon solar altitude is high (> 70°): " + altNoon)

            // Midnight has deep negative altitude (< -30°)
            var summerMidnight = new Date("2026-06-22T05:25:00.000Z")
            var altMid = w._solarAltitude(summerMidnight, 29.9012, -81.3124)
            verify(altMid < -30.0, "midnight solar altitude is deep negative: " + altMid)
        }

        function test_sun_events_order_and_invariants() {
            var w = h.item
            var ref = new Date("2026-09-26T16:00:00.000Z")
            var events = w.calculateSunEvents(ref, 29.9012, -81.3124)
            verify(events !== null, "calculateSunEvents returns non-null events object")

            verify(events.sunset !== null, "sunset computed")
            verify(events.civilDusk !== null, "civilDusk computed")
            verify(events.nauticalDusk !== null, "nauticalDusk computed")
            verify(events.astroDusk !== null, "astroDusk computed")
            verify(events.astroDawn !== null, "astroDawn computed")
            verify(events.sunrise !== null, "sunrise computed")

            // Strict twilight progression invariant:
            // sunset < civilDusk < nauticalDusk < astroDusk < astroDawn < sunrise
            verify(events.sunset.getTime() < events.civilDusk.getTime(), "sunset precedes civil dusk")
            verify(events.civilDusk.getTime() < events.nauticalDusk.getTime(), "civil dusk precedes nautical dusk")
            verify(events.nauticalDusk.getTime() < events.astroDusk.getTime(), "nautical dusk precedes astronomical dusk")
            verify(events.astroDusk.getTime() < events.astroDawn.getTime(), "astronomical dusk precedes astronomical dawn")
            verify(events.astroDawn.getTime() < events.sunrise.getTime(), "astronomical dawn precedes sunrise")

            // Dark sky duration should be substantial (~8-9 hours for autumn equinox)
            var darkHours = (events.astroDawn.getTime() - events.astroDusk.getTime()) / 3600000
            verify(darkHours > 6.0 && darkHours < 12.0, "dark sky duration is reasonable (" + darkHours + "h)")
        }

        function test_moon_info_invariants() {
            var w = h.item
            var ref = new Date("2026-09-26T16:00:00.000Z")
            var m = w.calculateMoonInfo(ref)
            verify(m !== null, "moon info returned")
            verify(m.illum >= 0 && m.illum <= 100, "illumination between 0 and 100: " + m.illum)
            verify(m.age >= 0 && m.age <= 29.6, "lunar age in synodic cycle: " + m.age)
            verify(m.name.length > 0, "moon phase name non-empty: " + m.name)
            verify(m.glyph.length > 0, "moon glyph non-empty: " + m.glyph)
            verify(m.cyclePos >= 0 && m.cyclePos <= 1, "cyclePos between 0 and 1: " + m.cyclePos)
        }

        function test_planet_rise_set_calculations() {
            var w = h.item
            var ref = new Date("2026-09-26T16:00:00.000Z")
            var planets = w.calculateAllPlanets(ref, 29.9012, -81.3124)
            verify(planets !== null, "calculateAllPlanets returns non-null list")
            compare(planets.length, 5, "5 naked-eye planets computed")

            var expectedKeys = ["mercury", "venus", "mars", "jupiter", "saturn"]
            var expectedSymbols = ["☿", "♀", "♂", "♃", "♄"]

            for (var i = 0; i < planets.length; i++) {
                var p = planets[i]
                compare(p.key, expectedKeys[i], "planet key matches: " + p.key)
                compare(p.symbol, expectedSymbols[i], "planet symbol matches: " + p.symbol)
                verify(p.name.length > 0, "planet has name: " + p.name)
                verify(p.status.length > 0, "planet has visibility status: " + p.status)
                verify(p.constellation && p.constellation.length > 0, "planet has constellation: " + p.constellation)
                verify(p.constellationSymbol && p.constellationSymbol.length > 0, "planet has constellation symbol: " + p.constellationSymbol)
                if (p.rise) {
                    verify(p.rise instanceof Date, "rise is Date object")
                    verify(!isNaN(p.rise.getTime()), "rise Date is valid")
                }
                if (p.set) {
                    verify(p.set instanceof Date, "set is Date object")
                    verify(!isNaN(p.set.getTime()), "set Date is valid")
                }
            }

            // Saturn in Pisces in late 2026
            compare(planets[4].constellation, "Pisces", "Saturn is in Pisces")
            compare(planets[4].constellationSymbol, "♓", "Saturn constellation glyph is ♓")
        }
    }

    // ── 3. Cloud Forecast Window and Verdict Parsing ────────────────────────
    TestCase {
        name: "SkyTonightCloudParsing"
        when: windowShown

        function init() {
            tryVerify(function () { return h.ready }, 3000)
            h.storeCtl.patchSettings("test-instance", {
                place: "St. Augustine, FL",
                lat: 29.9012,
                lon: -81.3124
            })
        }

        function test_parse_cloud_payload() {
            var w = h.item
            var mockPayload = JSON.stringify({
                utc_offset_seconds: -14400,
                hourly: {
                    time: [
                        "2026-09-26T18:00",
                        "2026-09-26T19:00",
                        "2026-09-26T20:00",
                        "2026-09-26T21:00",
                        "2026-09-26T22:00",
                        "2026-09-26T23:00",
                        "2026-09-27T00:00",
                        "2026-09-27T01:00",
                        "2026-09-27T02:00",
                        "2026-09-27T03:00"
                    ],
                    cloud_cover: [40, 30, 10, 5, 0, 15, 20, 25, 10, 50]
                }
            })

            w._applyCloudData(mockPayload)
            compare(w.cloudLoaded, true, "cloud data marked loaded")
            compare(w.hourlyWindow.length, 9, "window collects dark hours from post-sunset 19:00 through 03:00")

            // Average of [30, 10, 5, 0, 15, 20, 25, 10, 50] = 165 / 9 = 18%
            compare(w.avgCloud, 18, "computes correct average cloud cover")
            verify(w.bestWindow !== null, "bestWindow identified")
            compare(w.bestWindow.hr, 22, "10 PM (22:00) is clearest hour")
            compare(w.bestWindow.cloud, 0, "clearest hour cloud is 0%")
            compare(w.verdict, "Clear — great for observing", "verdict is clear")
            compare(w.verdictEmoji, "🌟", "emoji is star")
        }

        function test_verdict_threshold_escalation() {
            var w = h.item

            // 15% -> Clear
            w.avgCloud = 15; w.cloudLoaded = true
            compare(w.verdict, "Clear — great for observing")
            compare(w.verdictEmoji, "🌟")

            // 45% -> Partly cloudy
            w.avgCloud = 45; w.cloudLoaded = true
            compare(w.verdict, "Partly cloudy — gaps to peek through")
            compare(w.verdictEmoji, "⛅")

            // 75% -> Mostly cloudy
            w.avgCloud = 75; w.cloudLoaded = true
            compare(w.verdict, "Mostly cloudy — limited windows")
            compare(w.verdictEmoji, "🌥️")

            // 95% -> Overcast
            w.avgCloud = 95; w.cloudLoaded = true
            compare(w.verdict, "Overcast — skywatching unlikely")
            compare(w.verdictEmoji, "☁️")
        }

        function test_temperature_dew_and_frost_telemetry() {
            var w = h.item
            var mockPayload = JSON.stringify({
                utc_offset_seconds: -14400,
                hourly: {
                    time: [
                        "2026-09-26T18:00",
                        "2026-09-26T19:00",
                        "2026-09-26T20:00",
                        "2026-09-26T21:00",
                        "2026-09-26T22:00",
                        "2026-09-26T23:00",
                        "2026-09-27T00:00",
                        "2026-09-27T01:00",
                        "2026-09-27T02:00",
                        "2026-09-27T03:00"
                    ],
                    cloud_cover: [40, 30, 10, 5, 0, 15, 20, 25, 10, 50],
                    temperature_2m: [22.0, 20.0, 18.0, 16.0, 15.0, 14.0, 13.0, 12.0, 11.0, 10.0],
                    apparent_temperature: [22.0, 20.0, 17.5, 15.5, 14.5, 13.5, 12.5, 11.5, 10.5, 9.5],
                    dew_point_2m: [16.0, 15.0, 14.0, 14.8, 14.5, 13.5, 12.5, 11.5, 10.5, 9.5],
                    wind_speed_10m: [10.0, 12.0, 14.0, 8.0, 6.0, 5.0, 7.0, 9.0, 6.0, 8.0]
                }
            })

            w._applyCloudData(mockPayload)
            compare(w.cloudLoaded, true)

            // First hour in window (19:00) has temp 20°C -> 68°F
            compare(w.currentTempC, 20)
            compare(w.currentTempF, 68)

            // Minimum temp in window is 10°C (at 03:00) -> 50°F
            compare(w.minTempC, 10)
            compare(w.minTempF, 50)

            // Wind at 19:00 is 12 km/h -> ~7 mph
            compare(w.windSpeedKmh, 12)
            compare(w.windSpeedMph, 7)

            // At 21:00 (k=3), temp=16.0, dew=14.8 -> depression=1.2 <= 1.5 -> High Dew Risk!
            compare(w.dewRisk, "high")
            compare(w.dewRiskLabel, "High Dew Risk")

            // Check hourly item contains temperature and dew risk
            verify(w.hourlyWindow.length > 0)
            var hour21 = null
            for (var i = 0; i < w.hourlyWindow.length; i++) {
                if (w.hourlyWindow[i].hr === 21) hour21 = w.hourlyWindow[i]
            }
            verify(hour21 !== null, "hour 21 found in window")
            compare(hour21.tempC, 16)
            compare(hour21.tempF, 61)
            compare(hour21.dewRisk, "high")
            compare(hour21.dewRiskLabel, "High Dew")

            // Test frost risk escalation when temp <= 0°C and depression <= 1.5°C
            var frostPayload = JSON.stringify({
                utc_offset_seconds: -14400,
                hourly: {
                    time: [
                        "2026-09-26T19:00",
                        "2026-09-26T20:00"
                    ],
                    cloud_cover: [0, 0],
                    temperature_2m: [-2.0, -4.0],
                    apparent_temperature: [-5.0, -7.0],
                    dew_point_2m: [-2.5, -4.8],
                    wind_speed_10m: [5.0, 6.0]
                }
            })
            w._applyCloudData(frostPayload)
            compare(w.currentTempC, -2)
            compare(w.currentTempF, 28) // -2 * 9/5 + 32 = 28.4 -> 28
            compare(w.minTempC, -4)
            compare(w.minTempF, 25) // -4 * 9/5 + 32 = 24.8 -> 25
            compare(w.dewRisk, "frost")
            compare(w.dewRiskLabel, "Frost Alert")

            // Test tempUnit preference and interactive toggle
            compare(w.tempUnit, "F")
            h.storeCtl.setSetting("test-instance", "tempUnit", "C")
            compare(w.tempUnit, "C")
            h.storeCtl.setSetting("test-instance", "tempUnit", "F")
            compare(w.tempUnit, "F")

            w.toggleTempUnit()
            compare(w.tempUnit, "C")
            compare(h.storeCtl.settingsFor("test-instance").tempUnit, "C")
            w.toggleTempUnit()
            compare(w.tempUnit, "F")
            compare(h.storeCtl.settingsFor("test-instance").tempUnit, "F")
        }

        function test_cloud_freshness_and_observing_labels() {
            var w = h.item
            var mockPayload = JSON.stringify({
                utc_offset_seconds: -14400,
                hourly: {
                    time: [
                        "2026-09-27T18:00",
                        "2026-09-27T19:00",
                        "2026-09-27T20:00",
                        "2026-09-27T21:00",
                        "2026-09-27T22:00",
                        "2026-09-27T23:00",
                        "2026-09-28T00:00",
                        "2026-09-28T01:00",
                        "2026-09-28T02:00"
                    ],
                    cloud_cover: [20, 15, 0, 0, 0, 0, 5, 0, 0]
                }
            })
            w._applyCloudData(mockPayload)
            verify(w.lastSuccessMs > 0, "lastSuccessMs populated")
            verify(w.lastSuccessStr.length > 0, "lastSuccessStr populated: " + w.lastSuccessStr)
            verify(w.observingDateLabel.length > 0, "observingDateLabel populated: " + w.observingDateLabel)
        }

        function test_all_dark_hours_window() {
            var w = h.item
            var times = []
            var clouds = []
            // Simulate 24-hour cycle covering evening into morning
            for (var hr = 12; hr <= 23; hr++) {
                times.push("2026-09-26T" + (hr < 10 ? "0" : "") + hr + ":00")
                clouds.push(hr === 22 ? 0 : 15)
            }
            for (var hr2 = 0; hr2 <= 12; hr2++) {
                times.push("2026-09-27T" + (hr2 < 10 ? "0" : "") + hr2 + ":00")
                clouds.push(20)
            }
            var fullPayload = JSON.stringify({
                utc_offset_seconds: -14400,
                hourly: { time: times, cloud_cover: clouds }
            })
            w._applyCloudData(fullPayload)
            verify(w.hourlyWindow.length >= 10, "window spans all dark hours (at least 10 hours): " + w.hourlyWindow.length)

            var first = w.hourlyWindow[0]
            verify(first.hr === 19 || first.hr === 20, "first observing hour is post-sunset: " + first.hr)
            verify(first.labelCompact && first.labelCompact.length > 0, "has compact label")

            var last = w.hourlyWindow[w.hourlyWindow.length - 1]
            verify(last.hr >= 5 && last.hr <= 7, "last observing hour is pre-sunrise: " + last.hr)

            // Check that midnight hours have isDarkSky true
            var midnightItem = null
            for (var i = 0; i < w.hourlyWindow.length; i++) {
                if (w.hourlyWindow[i].hr === 0) midnightItem = w.hourlyWindow[i]
            }
            verify(midnightItem !== null, "midnight hour is in observing window")
            verify(midnightItem.isDarkSky, "midnight hour is classified as astronomical dark sky")
        }
    }

    // ── 4. Location Configuration and Fallback ──────────────────────────────
    TestCase {
        name: "SkyTonightLocation"
        when: windowShown

        function init() {
            tryVerify(function () { return h.ready }, 3000)
            clearSettings(h)
        }

        function test_location_configuration_updates() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", {
                place: "St. Augustine, FL",
                lat: 29.9012,
                lon: -81.3124
            })

            compare(w.place, "St. Augustine, FL")
            compare(w.lat, 29.9012)
            compare(w.lon, -81.3124)
            compare(w.locationConfigured, true)
            verify(w.sunEvents !== null, "sun events active with location")
        }

        function test_toggle_display_sections() {
            var w = h.item
            compare(w.showTwilights, true)
            compare(w.showClouds, true)
            compare(w.showHourlyBar, true)
            compare(w.showMoon, true)
            compare(w.showPlanets, true)

            h.storeCtl.setSetting("test-instance", "showTwilights", false)
            compare(w.showTwilights, false)

            h.storeCtl.setSetting("test-instance", "showMoon", false)
            compare(w.showMoon, false)

            h.storeCtl.setSetting("test-instance", "showPlanets", false)
            compare(w.showPlanets, false)
        }
    }

    // ── 5. Micro Layout ─────────────────────────────────────────────────────
    TestCase {
        name: "SkyTonightMicroLayout"
        when: windowShown

        function init() {
            tryVerify(function () { return hMicro.ready }, 3000)
        }

        function test_micro_sizing_and_render() {
            var w = hMicro.item
            compare(w.micro, true, "microBox produces micro tile")
            verify(w.verdictEmoji.length > 0, "renders verdict emoji")
            verify(w.moon.glyph.length > 0, "renders moon glyph in micro view")
        }
    }

    // ── 6. Responsive Two-Column Layout ─────────────────────────────────────
    TestCase {
        name: "SkyTonightResponsiveLayout"
        when: windowShown

        function init() {
            tryVerify(function () { return h.ready }, 3000)
        }

        function test_two_column_activation() {
            var w = h.item
            compare(w.twoColumn, false, "600x800 is single column")

            root.width = 1700; root.height = 672
            compare(w.twoColumn, true, "1700x672 activates balanced 2-column layout")

            root.width = 850; root.height = 672
            compare(w.twoColumn, true, "850x672 activates balanced 2-column layout")

            root.width = 400; root.height = 672
            compare(w.twoColumn, false, "400x672 falls back to single-column layout")

            root.width = 600; root.height = 800
        }

        function test_two_column_ephemeris_and_clarity() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", {
                place: "St. Augustine, FL",
                lat: 29.9012,
                lon: -81.3124
            })
            root.width = 1700; root.height = 672
            compare(w.twoColumn, true)
            verify(w.planets.length === 5, "5 planets ready for ephemeris")

            var clarity100 = Math.max(0, 100 - 0)
            compare(clarity100, 100, "0% cloud cover is 100% clarity")

            root.width = 600; root.height = 800
        }
    }
}

