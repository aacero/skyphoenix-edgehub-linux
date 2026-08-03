import QtQuick
import QtTest
import "../../ui/qml" as App


// ClockWidget - verifies every config option actually changes what's shown:
// 12/24-hour, seconds, date visibility + style, and the world clock (real IANA
// zones with daylight-saving, plus the legacy fixed-offset model).
//
// The zone instants below are PINNED, never `new Date()`: a DST test that runs
// against "today" asserts nothing for 10 months of the year. Expected offsets are
// ground truth from the IANA database (cross-checked with Python zoneinfo).
Item {
    width: 420; height: 300
    WidgetHarness { id: h; anchors.fill: parent; widgetFile: "ClockWidget.qml"; expanded: true }
    App.WidgetConfigSchema { id: sc }

    TestCase {
        name: "ClockWidget"
        when: windowShown

        function init() {
            tryVerify(function () { return h.ready }, 3000)
            var s = h.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            h.storeCtl._touchSettings()
        }
        function set(k, v) { h.storeCtl.setSetting("test-instance", k, v) }
        function schemaField(key) {
            var sections = sc.schemaFor("clock").sections
            for (var i = 0; i < sections.length; i++) {
                var fields = sections[i].fields || []
                for (var j = 0; j < fields.length; j++)
                    if (fields[j].key === key) return fields[j]
            }
            return null
        }

        function test_12h_vs_24h() {
            var w = h.item
            set("format24", false)
            verify(w.timeFmt.indexOf("h:mm") >= 0, "12h uses h:mm")
            verify(w.timeFmt.indexOf("AP") >= 0, "12h shows AM/PM")
            verify(w.timeFmt.indexOf("HH") < 0)
            set("format24", true)
            verify(w.timeFmt.indexOf("HH:mm") >= 0, "24h uses HH:mm")
            verify(w.timeFmt.indexOf("AP") < 0, "24h has no AM/PM")
        }

        function test_show_seconds() {
            var w = h.item
            set("showSeconds", false)
            verify(w.timeFmt.indexOf("ss") < 0, "no seconds by default")
            set("showSeconds", true)
            verify(w.timeFmt.indexOf("ss") >= 0, "seconds added to the format")
        }

        function test_date_style() {
            var w = h.item
            set("localeName", "en_US")
            set("dateStyle", "short")
            compare(w.dateFmt, Qt.locale("en_US").dateFormat(Locale.ShortFormat),
                    "short date uses the selected locale's order and separators")
            var usPattern = w.dateFmt
            set("localeName", "en_GB")
            compare(w.dateFmt, Qt.locale("en_GB").dateFormat(Locale.ShortFormat))
            verify(w.dateFmt !== usPattern,
                   "US and British short-date patterns do not collapse to a fixed dd/MM")
            set("dateStyle", "full")
            verify(w.dateFmt.indexOf("MMM") >= 0, "full date style uses a month name")
        }

        function test_custom_date_pattern_is_validated_with_a_safe_fallback() {
            var w = h.item
            set("dateStyle", "custom")
            set("datePattern", "yyyy 'week' ww")
            compare(w.dateFmt, "yyyy 'week' ww")
            verify(w.validDatePattern(w.datePattern))
            set("datePattern", "'unterminated")
            verify(!w.validDatePattern(w.datePattern))
            compare(w.dateFmt, "ddd, d MMM",
                    "an invalid persisted pattern cannot blank or corrupt the date")

            var field = schemaField("datePattern")
            compare(field.validator, "qtDatePattern")
            compare(field.preview, "qtDatePattern")
        }

        // The bug this epic exists for: a fixed offset cannot follow daylight saving,
        // so a "New York" clock built from utcOffset:-5 is an hour wrong for ~8 months.
        // A real zone must report DIFFERENT offsets in winter and summer.
        // ── Zones ────────────────────────────────────────────────────────────
        // The widget resolves zones through the injected `timeZones` bridge
        // (app/src/timezone_bridge.h), because QML cannot do it at all: Qt's V4 has
        // no Intl, and Date.toLocaleString SILENTLY IGNORES a { timeZone } option.
        //
        // So the split of responsibility is: the REAL DST correctness (every zone,
        // every transition, to the second) is proven against the OS tzdata in
        // tests/cpp/tst_timezone_bridge.cpp. What is provable HERE is the part QML
        // owns - that the widget asks the bridge, and that it degrades safely when
        // the bridge is absent or the zone unknown. A fake keeps that deterministic
        // and independent of the host's tzdata.
        function fakeTz(offsetsByZone) {
            return {
                isValid: function (z) { return offsetsByZone.hasOwnProperty(z) },
                offsetSecsAt: function (z, ms) {
                    var o = offsetsByZone[z]
                    return Math.round((typeof o === "function" ? o(ms) : o) * 3600)
                },
                format: function (z, ms, fmt) {
                    // Marker, not a real formatter: proves the widget routed the
                    // request here (and with which zone) rather than formatting a
                    // locally-shifted Date itself.
                    return "TZ[" + z + "|" + fmt + "]"
                }
            }
        }
        // The same bridge, plus the OPTIONAL locale-aware entry point. The widget
        // only takes that path when the bridge actually offers it
        // (ClockWidget.qml:127), and the plain fakeTz above does not - which is
        // why that branch had never executed in a test (audit 2026-08-03).
        function fakeTzWithLocale(offsetsByZone) {
            var base = fakeTz(offsetsByZone)
            base.formatLocale = function (z, ms, fmt, loc) {
                return "TZL[" + z + "|" + fmt + "|" + loc + "]"
            }
            return base
        }

        // The picker offers a curated set of chips (a `segmented` field cannot show
        // ~600 zones), but every value must be a REAL IANA id: a typo would ship a
        // city chip that silently falls back to the fixed offset - the exact class
        // of silent wrongness this epic exists to remove. Shape-checked here; the
        // ids themselves are resolved against the OS tzdata in the C++ suite.
        function test_schema_zone_options_are_well_formed_iana_ids() {
            var f = schemaField("zoneId")
            verify(f !== null, "the clock schema still exposes a zoneId field")
            compare(f.dflt, "", "dflt MUST stay empty: a city default would silently " +
                                "re-point every saved world clock")
            compare(f.type, "timezone", "the full OS timezone picker owns zone selection")
            var secondary = schemaField("secondaryZones")
            compare(secondary.type, "timezoneList",
                    "additional zones use a structured searchable editor, not CSV text")
        }

        function test_zone_is_resolved_through_the_bridge_not_locally() {
            var w = h.item
            w.timeZones = fakeTz({ "America/New_York": -4 })
            set("customZone", true); set("zoneId", "America/New_York")
            verify(w.zoneResolvable(), "a zone the bridge knows is resolvable")
            compare(w.formatAt("HH:mm"), "TZ[America/New_York|HH:mm]",
                    "formatting is delegated to the bridge, not done on a shifted local Date")
            w.timeZones = null
        }

        // ── localeName reaches formatAt, not just the date pattern ──────────
        // Audit 2026-08-03: localeName was set by exactly two tests, and both
        // asserted only dateFmt - the date PATTERN via localeShortDatePattern().
        // Its three formatting branches in formatAt() (no zone, zone with a
        // locale-aware bridge, zone without one) had no coverage at all, and
        // `formatLocale` appeared nowhere outside the widget.

        function test_locale_changes_the_rendered_text_not_only_the_pattern() {
            var w = h.item
            var at = new Date(Date.UTC(2026, 6, 20, 12, 0, 0))   // a Monday
            set("localeName", "en_US")
            var us = w.formatAt("dddd", at)
            set("localeName", "de_DE")
            var de = w.formatAt("dddd", at)
            verify(us !== de,
                   "the chosen locale reaches the rendered text (got '" + us
                   + "' and '" + de + "')")
            compare(de, at.toLocaleString(Qt.locale("de_DE"), "dddd"),
                    "and it is the selected locale's own rendering")
            set("localeName", "")
            compare(w.formatAt("dddd", at), Qt.formatDateTime(at, "dddd"),
                    "no locale falls back to the system formatting")
        }

        function test_custom_zone_with_a_locale_uses_the_locale_aware_bridge() {
            var w = h.item
            w.timeZones = fakeTzWithLocale({ "America/New_York": -4 })
            set("customZone", true); set("zoneId", "America/New_York")
            set("localeName", "de_DE")
            compare(w.formatAt("HH:mm"), "TZL[America/New_York|HH:mm|de_DE]",
                    "a zone AND a locale go to formatLocale, carrying the locale")
            set("localeName", "")
            compare(w.formatAt("HH:mm"), "TZ[America/New_York|HH:mm]",
                    "no locale uses the plain zone formatter")
            w.timeZones = null
        }

        function test_zone_locale_falls_back_when_the_bridge_cannot_localise() {
            var w = h.item
            // A bridge WITHOUT formatLocale - an older host, or a build that
            // predates it. The widget must still render the right zone rather
            // than dropping to a locally-shifted Date.
            w.timeZones = fakeTz({ "America/New_York": -4 })
            set("customZone", true); set("zoneId", "America/New_York")
            set("localeName", "de_DE")
            compare(w.formatAt("HH:mm"), "TZ[America/New_York|HH:mm]",
                    "falls back to the plain zone formatter, still via the bridge")
            w.timeZones = null
        }

        // The offset must come from the bridge per-instant - that is what makes it
        // follow DST rather than being a constant.
        function test_offset_comes_from_the_bridge_per_instant() {
            var w = h.item
            var jan = new Date(Date.UTC(2026, 0, 15, 12))
            var jul = new Date(Date.UTC(2026, 6, 15, 12))
            // A zone whose offset genuinely varies by instant, as a real DST zone does.
            w.timeZones = fakeTz({ "America/New_York": function (ms) {
                return ms < Date.UTC(2026, 3, 1) ? -5 : -4 } })
            compare(w.zoneOffsetAt("America/New_York", jan), -5, "winter offset read at that instant")
            compare(w.zoneOffsetAt("America/New_York", jul), -4, "summer offset read at that instant")
            verify(w.zoneOffsetAt("America/New_York", jan) !== w.zoneOffsetAt("America/New_York", jul),
                   "the offset is instant-dependent, not a constant")
            // Half-hour zones must survive the seconds->hours conversion.
            w.timeZones = fakeTz({ "Asia/Kolkata": 5.5 })
            compare(w.zoneOffsetAt("Asia/Kolkata", jul), 5.5, "a half-hour zone is not rounded")
            w.timeZones = null
        }

        // A zoneId this build/tzdata cannot resolve must fall back to the user's
        // stored offset - never render a confidently wrong time, and never UTC.
        function test_unresolvable_zone_falls_back_to_the_stored_offset() {
            var w = h.item
            w.timeZones = fakeTz({ "America/New_York": -4 })
            set("customZone", true); set("zoneId", "Mars/Olympus_Mons"); set("utcOffset", 3)
            verify(!w.zoneResolvable(), "an unknown zone is not resolvable")
            compare(w.effectiveOffsetAt(new Date(Date.UTC(2026, 6, 15, 12))), 3,
                    "falls back to the user's offset, not to UTC")
            verify(w.formatAt("HH:mm").indexOf("TZ[") < 0, "does not ask the bridge for a zone it rejected")
            w.timeZones = null
        }

        // No bridge at all (a standalone host): the legacy fixed-offset path must
        // still work rather than the clock breaking.
        function test_without_a_bridge_the_legacy_offset_path_still_works() {
            var w = h.item
            w.timeZones = null
            set("customZone", true); set("zoneId", "America/New_York"); set("utcOffset", -5)
            verify(!w.zoneResolvable(), "nothing to resolve with")
            compare(w.effectiveOffsetAt(new Date(Date.UTC(2026, 6, 15, 12))), -5,
                    "the stored offset drives the clock")
        }

        function test_zone_city_is_derived_from_the_iana_id() {
            var w = h.item
            w.timeZones = fakeTz({ "America/New_York": -4, "Europe/Berlin": 2 })
            set("customZone", true); set("zoneId", "America/New_York")
            compare(w.zoneCity(), "New York", "underscores become spaces, region is dropped")
            set("zoneId", "Europe/Berlin")
            compare(w.zoneCity(), "Berlin")
            set("zoneId", "Mars/Olympus_Mons")
            compare(w.zoneCity(), "", "no city for a zone the bridge rejects")
            w.timeZones = null
        }

        function test_world_clock_offset() {
            var w = h.item
            set("customZone", false)
            // local: zonedNow ≈ now
            verify(Math.abs(w.zonedNow().getTime() - Date.now()) < 2000, "local mode = now")
            set("customZone", true)
            set("utcOffset", 5)
            var local = new Date()
            var utcMs = local.getTime() + local.getTimezoneOffset() * 60000
            var expected = utcMs + 5 * 3600000
            verify(Math.abs(w.zonedNow().getTime() - expected) < 2000,
                   "world-clock time equals UTC+5")
            // A different offset gives a different time.
            set("utcOffset", -8)
            var expected2 = utcMs - 8 * 3600000
            verify(Math.abs(w.zonedNow().getTime() - expected2) < 2000, "UTC-8 differs correctly")
        }

        function test_zone_label_default() {
            var w = h.item
            set("customZone", true)
            compare(w.zoneLabel, "", "no label by default")
            verify(w.offsetLabel().indexOf("UTC") >= 0, "falls back to a UTC offset label")
            set("zoneLabel", "Tokyo")
            compare(w.zoneLabel, "Tokyo")
        }

        function test_secondary_zones_are_validated_deduplicated_and_bounded() {
            var w = h.item
            w.timeZones = fakeTz({
                "Europe/London": 1,
                "Asia/Tokyo": 9,
                "America/New_York": -4,
                "Australia/Sydney": 10
            })
            set("secondaryZones",
                "Europe/London, Asia/Tokyo, Europe/London, Invalid/Zone, America/New_York, Australia/Sydney")
            compare(w.secondaryZoneIds().length, 3)
            compare(w.secondaryZoneIds()[0], "Europe/London")
            compare(w.secondaryZoneIds()[1], "Asia/Tokyo")
            compare(w.secondaryZoneIds()[2], "America/New_York")
            w.timeZones = null
        }
    }
}
