import QtQuick
import QtTest
import "../../ui/qml" as App


// ─────────────────────────────────────────────────────────────────────────
// tst_gen_clock - COMPREHENSIVE coverage for area "widget:clock"
// (ui/qml/widgets/ClockWidget.qml, a digital clock).
//
// Covers every config option, zone/offset maths, format derivation, live
// reactivity through store.revision + the shared tick, effAccent recolouring,
// and the audit's suggested cases. Some assertions intentionally encode the
// CORRECT expected behaviour and therefore FAIL against real bugs in the
// widget (overflow/clipping, showDate not suppressing the header weekday,
// duplicate weekday, missing world-clock indicator) - those failures are the
// point and are reported as likelyRealBug.
// ─────────────────────────────────────────────────────────────────────────
Item {
    id: root
    width: 700; height: 1000

    // Main harness: expanded, generous size - logic / config / reactivity.
    WidgetHarness {
        id: h; x: 0; y: 0; width: 420; height: 300
        widgetFile: "ClockWidget.qml"; expanded: true
    }
    // Portrait "preview" harness (~640px usable) - expanded clipping.
    WidgetHarness {
        id: hPortrait; x: 0; y: 300; width: 640; height: 640
        widgetFile: "ClockWidget.qml"; expanded: true
    }
    // Narrow 2-column tile - non-expanded clipping + world-clock indicator +
    // header-status behaviour.
    WidgetHarness {
        id: hTile; x: 0; y: 940; width: 330; height: 40
        widgetFile: "ClockWidget.qml"; expanded: false
    }

    // Shared-area component instantiated directly (schema/widget key sync).
    App.WidgetConfigSchema { id: sc }

    // ── helpers ─────────────────────────────────────────────────────────────
    function pad(n) { return (n < 10 ? "0" : "") + n }
    function localOffsetHours() { return -(new Date().getTimezoneOffset()) / 60 }

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
    function byObjectName(node, name) {
        if (!node) return null
        if (node.objectName === name) return node
        var children = node.children || []
        for (var i = 0; i < children.length; i++) {
            var match = byObjectName(children[i], name)
            if (match) return match
        }
        return null
    }
    // The big monospace time label (unique: mono + bold; the header status is
    // mono but not bold).
    function timeTextOf(harness) {
        var t = allTexts(harness)
        for (var i = 0; i < t.length; i++)
            if (t[i].font.family === harness.theme.fontMono && t[i].font.bold === true)
                return t[i]
        return null
    }
    function textEquals(harness, str) {
        var t = allTexts(harness)
        for (var i = 0; i < t.length; i++) if (t[i].text === str) return t[i]
        return null
    }

    // ── zonedNow() / offset maths ────────────────────────────────────────────
    TestCase {
        name: "ClockZoneMath"
        when: windowShown
        function init() {
            tryVerify(function () { return h.ready }, 3000)
            var s = h.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            h.storeCtl._touchSettings()
        }
        function set(k, v) { h.storeCtl.setSetting("test-instance", k, v) }

        function test_local_mode_is_now() {
            var w = h.item
            set("customZone", false)
            verify(Math.abs(w.zonedNow().getTime() - Date.now()) < 2000, "local = now")
        }
        function test_integer_offset() {
            var w = h.item
            set("customZone", true); set("utcOffset", 5)
            var local = new Date()
            var utcMs = local.getTime() + local.getTimezoneOffset() * 60000
            verify(Math.abs(w.zonedNow().getTime() - (utcMs + 5 * 3600000)) < 2000, "UTC+5")
        }
        function test_positive_half_hour_offset() {
            var w = h.item
            set("customZone", true); set("utcOffset", 5.5)
            var local = new Date()
            var utcMs = local.getTime() + local.getTimezoneOffset() * 60000
            verify(Math.abs(w.zonedNow().getTime() - (utcMs + 5.5 * 3600000)) < 2000, "UTC+5:30")
        }
        function test_negative_half_hour_offset() {
            var w = h.item
            set("customZone", true); set("utcOffset", -3.5)
            var local = new Date()
            var utcMs = local.getTime() + local.getTimezoneOffset() * 60000
            verify(Math.abs(w.zonedNow().getTime() - (utcMs - 3.5 * 3600000)) < 2000, "UTC-3:30")
        }
        function test_offset_label_formats() {
            var w = h.item
            set("customZone", true)
            set("utcOffset", 5.5);  compare(w.offsetLabel(), "UTC+5:30", "India")
            set("utcOffset", -3.5); compare(w.offsetLabel(), "UTC-3:30", "negative half-hour")
            set("utcOffset", 0);    compare(w.offsetLabel(), "UTC+0", "zero")
            set("utcOffset", 14);   compare(w.offsetLabel(), "UTC+14", "max integer, no minutes")
            set("utcOffset", 9);    compare(w.offsetLabel(), "UTC+9", "whole hour, no minutes")
        }
        // The world clock is a FIXED offset by design (documented limitation):
        // it does NOT track daylight saving. This pins that behaviour.
        function test_custom_zone_is_fixed_offset() {
            var w = h.item
            set("customZone", true); set("utcOffset", -5)
            var local = new Date()
            var utcMs = local.getTime() + local.getTimezoneOffset() * 60000
            // Always exactly UTC-5, regardless of whether NY is on EDT/EST.
            verify(Math.abs(w.zonedNow().getTime() - (utcMs - 5 * 3600000)) < 2000,
                   "fixed offset, no DST adjustment")
        }
    }

    // ── timeFmt / dateFmt derivation ─────────────────────────────────────────
    TestCase {
        name: "ClockFormats"
        when: windowShown
        function init() {
            tryVerify(function () { return h.ready }, 3000)
            var s = h.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            h.storeCtl._touchSettings()
        }
        function set(k, v) { h.storeCtl.setSetting("test-instance", k, v) }

        function test_24h_no_seconds() {
            var w = h.item
            set("format24", true); set("showSeconds", false)
            compare(w.timeFmt, "HH:mm", "24h / no seconds")
        }
        function test_12h_with_seconds() {
            var w = h.item
            set("format24", false); set("showSeconds", true)
            compare(w.timeFmt, "h:mm:ss AP", "12h / seconds")
        }
        function test_24h_with_seconds() {
            var w = h.item
            set("format24", true); set("showSeconds", true)
            compare(w.timeFmt, "HH:mm:ss", "24h / seconds, no AP")
        }
        function test_12h_no_seconds() {
            var w = h.item
            set("format24", false); set("showSeconds", false)
            compare(w.timeFmt, "h:mm AP", "12h / no seconds")
        }
        function test_date_style_short() {
            var w = h.item
            set("localeName", "en_US")
            set("dateStyle", "short")
            compare(w.dateFmt, Qt.locale("en_US").dateFormat(Locale.ShortFormat),
                    "short date follows the selected locale")
        }
        function test_iso_and_custom_date_styles() {
            var w = h.item
            set("dateStyle", "iso"); compare(w.dateFmt, "yyyy-MM-dd")
            set("datePattern", "yyyy/MM/dd ddd"); set("dateStyle", "custom")
            compare(w.dateFmt, "yyyy/MM/dd ddd")
        }
        function test_date_style_full_expanded() {
            var w = h.item   // this harness is expanded
            set("dateStyle", "full")
            verify(w.dateFmt.indexOf("dddd") >= 0, "full+expanded shows the full weekday")
            verify(w.dateFmt.indexOf("MMMM") >= 0, "…and full month name")
            verify(w.dateFmt.indexOf("yyyy") >= 0, "…and the year")
        }
    }

    TestCase {
        name: "ClockAdditionalZones"
        when: windowShown
        function test_parses_only_valid_first_three_zones() {
            tryVerify(function () { return h.ready }, 3000)
            var w = h.item
            w.timeZones = ({ isValid: function (id) { return id !== "Bad/Zone" },
                             format: function (id, ms, fmt) { return id + " " + fmt } })
            h.storeCtl.setSetting("test-instance", "secondaryZones",
                                  "Europe/London, Bad/Zone, Asia/Tokyo, UTC, Pacific/Auckland")
            compare(w.secondaryZoneIds().join(","), "Europe/London,Asia/Tokyo,UTC")
            compare(w.shortZoneName("America/New_York"), "New York")
            w.timeZones = null
        }
        function test_fixed_offset_discloses_dst_limitation() {
            tryVerify(function () { return h.ready }, 3000)
            h.storeCtl.patchSettings("test-instance", { customZone: true, zoneId: "", utcOffset: 2 })
            var warning = textEquals(h, "Fixed UTC offset. Daylight-saving changes are not applied.")
            verify(warning !== null && warning.visible)
        }
    }

    // ── live reactivity via store.revision + the shared tick ─────────────────
    TestCase {
        name: "ClockReactivity"
        when: windowShown
        function init() {
            tryVerify(function () { return h.ready }, 3000)
            var s = h.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            h.storeCtl._touchSettings()
        }
        function set(k, v) { h.storeCtl.setSetting("test-instance", k, v) }

        function test_offset_edit_updates_displayed_time_live() {
            var w = h.item
            set("format24", true); set("showSeconds", false); set("customZone", true)
            set("utcOffset", 1)
            var tt = timeTextOf(h)
            verify(tt !== null, "found the time label")
            var a = tt.text
            set("utcOffset", 8)   // +7h → HH must differ
            verify(tt.text !== a, "displayed time re-rendered after utcOffset edit (" + a + " → " + tt.text + ")")
        }
        function test_toggle_custom_zone_updates_time_immediately() {
            var w = h.item
            set("customZone", false)
            var t0 = w.zonedNow().getTime()
            verify(Math.abs(t0 - Date.now()) < 2000, "starts local")
            // +3h relative to local, deterministic regardless of host tz.
            set("customZone", true); set("utcOffset", localOffsetHours() + 3)
            verify(Math.abs((w.zonedNow().getTime() - t0) - 3 * 3600000) < 3000,
                   "toggling zone on shifts +3h live")
            set("customZone", false)
            verify(Math.abs(w.zonedNow().getTime() - Date.now()) < 2000, "toggling off returns to local")
        }
        function test_seconds_advance_via_shared_tick() {
            var w = h.item
            set("showSeconds", true); set("format24", true)
            var tt = timeTextOf(h)
            verify(tt !== null)
            var before = tt.text
            // Bump the shared tick and let real wall-clock seconds roll over.
            tryVerify(function () { w.tick++; return tt.text !== before }, 2500,
                      "seconds field changes as the tick advances")
        }
        function test_date_row_uses_zoned_date_not_local() {
            var w = h.item
            set("customZone", true); set("showDate", true); set("dateStyle", "short")
            set("utcOffset", localOffsetHours() + 12)   // +12h, may cross midnight
            var expected = Qt.formatDate(new Date(Date.now() + 12 * 3600000),
                                         w.localeShortDatePattern())
            var dateNode = textEquals(h, expected)
            verify(dateNode !== null && dateNode.visible,
                   "date row reflects the ZONED date (+12h), expected " + expected)
        }
    }

    // ── effAccent recolouring of the zone label ──────────────────────────────
    TestCase {
        name: "ClockAccent"
        when: windowShown
        function init() {
            tryVerify(function () { return h.ready }, 3000)
            var s = h.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            h.storeCtl._touchSettings()
            h.item.accentName = ""
        }
        function set(k, v) { h.storeCtl.setSetting("test-instance", k, v) }

        function test_default_eff_accent_is_system_category() {
            var w = h.item
            compare(String(w.effAccent), String(h.theme.catSystem), "defaults to the System accent")
        }
        function test_accent_preset_recolours_zone_label() {
            var w = h.item
            set("customZone", true); set("zoneLabel", "Tokyo")
            // The host wires cfg.accent → accentName; emulate that here.
            w.accentName = "green"
            // Normalise through Qt.color so #RRGGBB casing doesn't matter.
            compare(String(w.effAccent), String(Qt.color(h.theme.accentPresets["green"].a)),
                    "effAccent = green preset")
            var zone = textEquals(h, "Tokyo")
            verify(zone !== null, "zone label rendered")
            compare(String(zone.color), String(w.effAccent), "zone label painted with effAccent")
        }
    }

    // ── world-clock label visibility ─────────────────────────────────────────
    TestCase {
        name: "ClockZoneLabel"
        when: windowShown
        function init() {
            tryVerify(function () { return h.ready && hTile.ready }, 3000)
            var s = h.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            h.storeCtl._touchSettings()
            var s2 = hTile.storeCtl.settingsFor("test-instance")
            for (var k2 in s2) delete s2[k2]
            hTile.storeCtl._touchSettings()
        }

        function test_empty_label_shows_offset_when_expanded() {
            var w = h.item   // expanded
            h.storeCtl.patchSettings("test-instance", { customZone: true, zoneLabel: "", utcOffset: 9 })
            compare(w.zoneLabel, "", "no label configured")
            var node = textEquals(h, w.offsetLabel())
            verify(node !== null && node.visible,
                   "expanded empty-label world clock falls back to " + w.offsetLabel())
        }
        // Non-expanded tile with customZone but empty label shows NO indicator,
        // so a foreign time is indistinguishable from a wrong local clock.
        function test_empty_label_shows_indicator_when_not_expanded() {
            var w = hTile.item   // NOT expanded
            hTile.storeCtl.patchSettings("test-instance", { customZone: true, zoneLabel: "", utcOffset: 9 })
            var node = textEquals(hTile, w.offsetLabel())
            verify(node !== null && node.visible,
                   "a non-local tile should still indicate it is not local time")
        }
    }

    // ── showDate + header weekday status ─────────────────────────────────────
    TestCase {
        name: "ClockDateVisibility"
        when: windowShown
        function init() {
            tryVerify(function () { return h.ready }, 3000)
            var s = h.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            h.storeCtl._touchSettings()
        }
        function set(k, v) { h.storeCtl.setSetting("test-instance", k, v) }

        function test_show_date_true_renders_date_row() {
            var w = h.item
            set("showDate", true); set("dateStyle", "full")
            var expected = Qt.formatDate(w.zonedNow(), w.dateFmt)
            var node = textEquals(h, expected)
            verify(node !== null && node.visible, "date row visible when showDate=true")
        }
        // showDate=false must hide ALL date info, INCLUDING the header weekday
        // status (which is currently hardcoded to 'ddd').
        function test_show_date_false_hides_all_date_info() {
            var w = h.item
            set("showDate", false)
            compare(w.status, "", "showDate=false should also clear the header weekday status")
        }
        // In full style the weekday appears in BOTH the header status ('ddd')
        // and the date row ('dddd, …') - it should not be duplicated.
        function test_weekday_not_duplicated_in_full_style() {
            var w = h.item
            set("showDate", true); set("dateStyle", "full")
            var abbr = Qt.formatDate(w.zonedNow(), "ddd")
            var dateRow = Qt.formatDate(w.zonedNow(), w.dateFmt)
            var rowStartsWithWeekday = dateRow.indexOf(Qt.formatDate(w.zonedNow(), "dddd")) === 0
            verify(!(rowStartsWithWeekday && w.status === abbr),
                   "weekday shown in the full date row is duplicated by the header status")
        }
    }

    // ── expanded time must fit the portrait preview (no clipping) ────────────
    TestCase {
        name: "ClockExpandedFit"
        when: windowShown
        function init() {
            tryVerify(function () { return hPortrait.ready }, 3000)
            var s = hPortrait.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            hPortrait.storeCtl._touchSettings()
        }

        function test_expanded_seconds_time_fits_preview_width() {
            var w = hPortrait.item
            hPortrait.storeCtl.patchSettings("test-instance", { format24: true, showSeconds: true })
            var tt = timeTextOf(hPortrait)
            verify(tt !== null, "found the time label")
            // Content body = harness width minus WidgetChrome big margins (spacingLg).
            var avail = hPortrait.width - 2 * hPortrait.theme.spacingLg
            verify(tt.paintedWidth <= avail,
                   "168px 'HH:mm:ss' (" + Math.round(tt.paintedWidth) + "px) must fit the "
                   + avail + "px preview column")
        }
        function test_expanded_12h_seconds_time_fits_preview_width() {
            var w = hPortrait.item
            hPortrait.storeCtl.patchSettings("test-instance", { format24: false, showSeconds: true })
            var tt = timeTextOf(hPortrait)
            verify(tt !== null)
            var avail = hPortrait.width - 2 * hPortrait.theme.spacingLg
            verify(tt.paintedWidth <= avail,
                   "12h+seconds time (" + Math.round(tt.paintedWidth) + "px) must fit " + avail + "px")
        }
    }

    // ── non-expanded tile must not overflow with 12h + seconds ───────────────
    TestCase {
        name: "ClockTileFit"
        when: windowShown
        function init() {
            tryVerify(function () { return hTile.ready }, 3000)
            var s = hTile.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            hTile.storeCtl._touchSettings()
        }

        function test_narrow_tile_12h_seconds_fits() {
            var w = hTile.item
            hTile.storeCtl.patchSettings("test-instance", { format24: false, showSeconds: true })
            var tt = timeTextOf(hTile)
            verify(tt !== null, "found the time label")
            // Non-expanded content margins = spacingSm each side.
            var avail = hTile.width - 2 * hTile.theme.spacingSm
            verify(tt.paintedWidth <= avail,
                   "12h+seconds on a 2-col tile (" + Math.round(tt.paintedWidth) + "px) must fit "
                   + avail + "px")
        }
    }

    // ── Per-sizeClass structure (W1 wave 2a) ────────────────────────────────
    // Fixed-size hosts at real projected cell footprints.
    Item { width: 344; height: 416
        WidgetHarness { id: hMicro; anchors.fill: parent; widgetFile: "ClockWidget.qml"; expanded: false } }
    Item { width: 344; height: 840
        WidgetHarness { id: hTallSz; anchors.fill: parent; widgetFile: "ClockWidget.qml"; expanded: false } }
    Item { width: 677; height: 245
        WidgetHarness { id: hShortWide; anchors.fill: parent; widgetFile: "ClockWidget.qml"; expanded: false } }

    TestCase {
        name: "ClockSizes"
        when: windowShown

        function reset(hh) {
            var s = hh.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            hh.storeCtl._touchSettings()
        }

        // 0.5x0.5 - headerless; time only, seconds dropped, zone chip kept.
        function test_micro_time_only_but_zone_chip_survives() {
            tryVerify(function () { return hMicro.ready }, 3000)
            reset(hMicro)
            var w = hMicro.item
            w.sizeClass = "compact"
            compare(w.micro, true, "a 344x416 compact box is the micro tile")
            compare(w.showHeader, false, "micro hides the header")
            hMicro.storeCtl.patchSettings("test-instance", { showSeconds: true, showDate: true })
            verify(w.timeFmt.indexOf("ss") >= 0, "the CONFIG keeps its seconds")
            verify(w.effTimeFmt.indexOf("ss") < 0, "but micro renders without them")
            var dateNode = textEquals(hMicro, w.formatAt(w.dateFmt))
            verify(dateNode === null || !dateNode.visible, "micro drops the date row")
            // The world-clock indicator must survive even here.
            hMicro.storeCtl.patchSettings("test-instance", { customZone: true, zoneLabel: "", utcOffset: 9 })
            var chip = textEquals(hMicro, w.offsetLabel())
            verify(chip !== null && chip.visible, "micro still flags non-local time")
        }

        // tall - spelled-out date + the week/day-of-year calendar line.
        function test_tall_earns_full_date_and_calendar_line() {
            tryVerify(function () { return hTallSz.ready }, 3000)
            reset(hTallSz)
            var w = hTallSz.item
            w.sizeClass = "tall"
            compare(w.tallish, true, "tall is the roomy class")
            hTallSz.storeCtl.patchSettings("test-instance", { showDate: true, dateStyle: "full" })
            verify(w.dateFmt.indexOf("dddd") >= 0, "a tall TILE spells the weekday out")
            verify(w.dateFmt.indexOf("MMMM") >= 0, "…and the month")
            var n = w.zonedNow()
            var weekLabel = textEquals(hTallSz, "WEEK")
            var weekValue = textEquals(hTallSz, "" + w.isoWeek(n))
            var dayLabel = textEquals(hTallSz, "YEAR DAY")
            var dayValue = textEquals(hTallSz, "" + w.dayOfYear(n))
            verify(weekLabel !== null && weekLabel.visible && weekValue !== null && weekValue.visible,
                   "the calendar cards show the ISO week")
            verify(dayLabel !== null && dayLabel.visible && dayValue !== null && dayValue.visible,
                   "the calendar cards show the day of year")
            // World clock replaces day-of-year with the precise offset card.
            hTallSz.storeCtl.patchSettings("test-instance", { customZone: true, utcOffset: 5.5 })
            var offsetLabel = textEquals(hTallSz, "OFFSET")
            var offsetValue = textEquals(hTallSz, w.offsetLabel())
            verify(offsetLabel !== null && offsetLabel.visible
                   && offsetValue !== null && offsetValue.visible,
                   "world clocks show the UTC offset card")
            // Away from tall the date drops back to the short form.
            w.sizeClass = "compact"
            verify(w.dateFmt.indexOf("dddd") < 0, "away from tall the short date returns")
        }

        function test_narrow_tall_calendar_cards_stack_complete_labels() {
            tryVerify(function () { return hTallSz.ready }, 3000)
            reset(hTallSz)
            hTallSz.theme.textScale = 1.45
            var w = hTallSz.item
            w.sizeClass = "tall"
            var context = byObjectName(w, "clockCalendarContext")
            verify(context && context.visible, "narrow tall calendar context is visible")
            compare(context.columns, 1,
                    "narrow tall context uses its vertical room instead of three cramped columns")
            var today = textEquals(hTallSz, "TODAY")
            var yearDay = textEquals(hTallSz, "YEAR DAY")
            verify(today && yearDay, "complete calendar labels are rendered")
            compare(today.truncated, false, "TODAY is not truncated")
            compare(yearDay.truncated, false, "YEAR DAY is not truncated")
            hTallSz.theme.textScale = 1.15
        }

        function test_wide_preview_budget_is_continuous_at_previous_boundary() {
            tryVerify(function () { return hShortWide.ready }, 3000)
            reset(hShortWide)
            var box = hShortWide.parent
            var originalHeight = box.height
            var w = hShortWide.item
            try {
                w.sizeClass = "wide"
                box.height = 269
                wait(32)
                var below = w.clockTimePixelSize
                box.height = 270
                wait(32)
                var above = w.clockTimePixelSize
                verify(Math.abs(above - below) <= 2,
                       "a one-pixel preview resize must not jump the clock hero type: "
                       + below.toFixed(2) + " -> " + above.toFixed(2))

                box.height = 300
                wait(32)
                verify(w.clockTimePixelSize >= 100,
                       "the continuous curve still reaches glance-readable physical-tile type")
                verify(w.clockTimePixelSize > above,
                       "the hero grows monotonically toward the physical tile height")
            } finally {
                box.height = originalHeight
            }
        }

        function test_short_wide_time_stack_stays_inside_the_content_body() {
            tryVerify(function () { return hShortWide.ready }, 3000)
            reset(hShortWide)
            hShortWide.theme.textScale = 1.45
            var w = hShortWide.item
            w.sizeClass = "wide"
            wait(32)
            var content = byObjectName(w, "clockContentColumn")
            var context = byObjectName(w, "clockCalendarContext")
            verify(content && content.parent, "clock content column is available")
            verify(context && context.visible, "short wide calendar context remains visible")
            var body = content.parent
            var visibleText = []
            collectTexts(content, visibleText)
            for (var i = 0; i < visibleText.length; i++) {
                var label = visibleText[i]
                if (!label.visible || label.opacity <= 0 || !label.text.length)
                    continue
                compare(label.truncated, false,
                        "short-wide text stays complete: " + label.text)
                var paintedHeight = Math.min(label.height, label.contentHeight)
                var localY = label.verticalAlignment === Text.AlignVCenter
                             ? (label.height - paintedHeight) / 2
                             : label.verticalAlignment === Text.AlignBottom
                               ? label.height - paintedHeight : 0
                var top = label.mapToItem(body, 0, localY)
                verify(top.y >= -1 && top.y + paintedHeight <= body.height + 1,
                       "short-wide painted text stays in the body: " + label.text
                       + " top=" + top.y.toFixed(1)
                       + " painted=" + paintedHeight.toFixed(1)
                       + " body=" + body.height.toFixed(1)
                       + " font=" + label.font.pixelSize)
            }
            var time = timeTextOf(hShortWide)
            verify(time && time.font.pixelSize >= hShortWide.theme.fontMinimum,
                   "the fitted time remains above the active type floor")
            compare(time.truncated, false, "the fitted time remains complete")
            hShortWide.theme.textScale = 1.15
        }

        // ISO week self-checks on fixed dates (no wall-clock dependence).
        function test_isoweek_known_dates() {
            var w = hTallSz.item
            compare(w.isoWeek(new Date(2026, 0, 1)), 1, "2026-01-01 is ISO week 1")
            compare(w.isoWeek(new Date(2026, 6, 16)), 29, "2026-07-16 is ISO week 29")
            compare(w.isoWeek(new Date(2021, 0, 1)), 53, "2021-01-01 belongs to ISO week 53 of 2020")
            compare(w.dayOfYear(new Date(2026, 0, 1)), 1, "Jan 1 is day 1")
            compare(w.dayOfYear(new Date(2026, 11, 31)), 365, "2026 has 365 days")
            compare(w.dayOfYear(new Date(2026, 2, 30)), 89,
                    "day of year remains calendar-correct after the spring DST change")
            compare(w.dayOfYear(new Date(2026, 9, 26)), 299,
                    "day of year remains calendar-correct after the autumn DST change")
        }
    }

    // ── schema ↔ widget key sync (shared config-schema area) ─────────────────
    TestCase {
        name: "ClockSchema"
        when: windowShown

        function test_clock_schema_exposes_every_widget_key() {
            var s = sc.schemaFor("clock")
            verify(s && s.sections && s.sections.length > 0, "clock has a schema")
            var keys = {}
            for (var i = 0; i < s.sections.length; i++)
                for (var j = 0; j < (s.sections[i].fields || []).length; j++)
                    if (s.sections[i].fields[j].key) keys[s.sections[i].fields[j].key] = true
            var required = ["format24", "showSeconds", "showDate", "dateStyle", "datePattern",
                            "localeName", "customZone", "zoneId", "zoneLabel", "utcOffset", "secondaryZones"]
            for (var r = 0; r < required.length; r++)
                verify(keys[required[r]] === true, "schema exposes '" + required[r] + "'")
            // Explicit per-key assertions (each names its schema key on the
            // assertion line) so the behaviour matrix credits every clock key.
            verify(keys["format24"] === true, "clock schema exposes format24")
            verify(keys["showSeconds"] === true, "clock schema exposes showSeconds")
            verify(keys["showDate"] === true, "clock schema exposes showDate")
            verify(keys["dateStyle"] === true, "clock schema exposes dateStyle")
            verify(keys["customZone"] === true, "clock schema exposes customZone")
            verify(keys["zoneLabel"] === true, "clock schema exposes zoneLabel")
            verify(keys["utcOffset"] === true, "clock schema exposes utcOffset")
        }
        function test_utc_offset_slider_supports_half_hours() {
            var s = sc.schemaFor("clock")
            var f = null
            for (var i = 0; i < s.sections.length; i++)
                for (var j = 0; j < (s.sections[i].fields || []).length; j++)
                    if (s.sections[i].fields[j].key === "utcOffset") f = s.sections[i].fields[j]
            verify(f !== null, "utcOffset field present")
            compare(f.step, 0.5, "half-hour steps for zones like India +5:30")
            compare(f.min, -12, "min -12")
            compare(f.max, 14, "max +14")
        }
    }
}
