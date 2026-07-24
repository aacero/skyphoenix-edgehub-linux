import QtQuick
import QtTest
import "../../ui/qml" as App


// ─────────────────────────────────────────────────────────────────────────
// tst_gen_calendar - COMPREHENSIVE coverage for area "widget:calendar"
// (ui/qml/widgets/CalendarWidget.qml, an ICS agenda widget).
//
// Exercises DTSTART/zone parsing, recurrence expansion (DAILY/WEEKLY/BYDAY/
// MONTHLY/YEARLY), EXDATE handling, horizon + past-event pruning, all-day
// semantics, config (url / maxEvents) honouring + reactivity through
// store.revision, effAccent recolouring, host-injected chrome props, the
// fetch state machine, and the schema↔widget key sync.
//
// Several assertions deliberately encode the CORRECT expected behaviour and
// therefore FAIL against real bugs flagged in the audit (MONTHLY/YEARLY
// recurrence dropped entirely, TZID ignored, past-today events not pruned,
// exclusive all-day DTEND over-shown, compact face ignoring maxEvents,
// webcal:// not rewritten). Those failures are the point and are reported as
// likelyRealBug.
// ─────────────────────────────────────────────────────────────────────────
Item {
    id: root
    width: 1700; height: 2600

    // Main harness: expanded - parsing / config / reactivity / accent.
    WidgetHarness {
        id: h; x: 0; y: 0; width: 460; height: 700
        widgetFile: "CalendarWidget.qml"; expanded: true
    }
    // Compact tile - the collapsed face (maxEvents cap behaviour). 696x819 is
    // the REAL 1x1 portrait footprint; it was 320x220, a box the size model
    // cannot produce (calendar's smallest declared size is 0.5x1 / 1x0.5, and
    // the half-cell is 348x409). That matters here specifically: at 220px tall
    // only ~3 rows FIT, so the old host could not tell "honours maxEvents=6"
    // from "correctly drops what doesn't fit".
    WidgetHarness {
        id: hTile; x: 700; y: 0; width: 696; height: 819
        widgetFile: "CalendarWidget.qml"; expanded: false
    }
    // Resizable host for the per-sizeClass structure tests (W1 wave 3) - the
    // REAL projected footprints of calendar's five declared sizes:
    //   0.5x1  → 348x819 portrait (tall) · 846x306 landscape (wide)
    //   1x0.5  → 696x409 portrait (wide) · 423x612 landscape (tall)
    //   1x1    → 696x819 portrait · 846x612 landscape  (compact)
    //   1x1.5  → 696x1228 portrait (tall) · 1269x612 landscape (wide)
    //   1x2    → 696x1637 portrait · 1692x612 landscape (BOTH "large")
    Item { id: sizeWrap; x: 0; y: 900; width: 696; height: 819
        WidgetHarness { id: hS; anchors.fill: parent
            widgetFile: "CalendarWidget.qml"; expanded: false; active: false } }

    // Shared config-schema area, instantiated directly.
    App.WidgetConfigSchema { id: sc }

    // ── helpers ───────────────────────────────────────────────────────────
    function pad(n) { return (n < 10 ? "0" : "") + n }
    function icsDay(d) { return d.getFullYear() + pad(d.getMonth() + 1) + pad(d.getDate()) }
    function icsDateTime(d) {
        return icsDay(d) + "T" + pad(d.getHours()) + pad(d.getMinutes()) + pad(d.getSeconds())
    }
    function atNine(d) { var x = new Date(d); x.setHours(9, 0, 0, 0); return x }
    function daysFromNow(n) { var d = atNine(new Date()); d.setDate(d.getDate() + n); return d }
    function midnight(d) { var x = new Date(d); x.setHours(0, 0, 0, 0); return x }

    function vcal(body) { return "BEGIN:VCALENDAR\n" + body + "END:VCALENDAR\n" }
    function vevent(lines) { return "BEGIN:VEVENT\n" + lines + "END:VEVENT\n" }

    // Deterministic fake occurrences (bypasses the network / parser).
    function fakeEvents(n) {
        var out = []
        var base = daysFromNow(1)
        for (var i = 0; i < n; i++) {
            var s = new Date(base.getTime() + i * 3600000)
            out.push({ title: "E" + i, location: "", allDay: false,
                       start: s, end: new Date(s.getTime() + 1800000) })
        }
        return out
    }

    function clear(harness) {
        var s = harness.storeCtl.settingsFor("test-instance")
        for (var k in s) delete s[k]
        harness.storeCtl._touchSettings()
    }

    // Text-node harvesting (mirrors tst_gen_clock).
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
    function textEquals(harness, str) {
        var t = allTexts(harness)
        for (var i = 0; i < t.length; i++) if (t[i].text === str) return t[i]
        return null
    }
    // Count VISIBLE text nodes whose text matches /^E\d+$/ (our fake titles).
    function visibleEventRowCount(harness) {
        var t = allTexts(harness), n = 0
        for (var i = 0; i < t.length; i++)
            if (/^E\d+$/.test(t[i].text) && t[i].visible) n++
        return n
    }

    // ── DTSTART / zone parsing ──────────────────────────────────────────────
    TestCase {
        name: "CalendarParseDT"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000); clear(h) }

        function test_floating_datetime_is_device_local() {
            var w = h.item
            var got = w.parseDT("20260712T090000", "DTSTART;VALUE=DATE-TIME")
            var exp = new Date(2026, 6, 12, 9, 0, 0)
            compare(got.getTime(), exp.getTime(), "floating DTSTART is device-local")
        }
        function test_utc_datetime_converts_from_zulu() {
            var w = h.item
            var got = w.parseDT("20260712T090000Z", "DTSTART")
            compare(got.getTime(), Date.UTC(2026, 6, 12, 9, 0, 0), "…Z is UTC")
        }
        function test_value_date_is_local_midnight() {
            var w = h.item
            var got = w.parseDT("20260712", "DTSTART;VALUE=DATE")
            var exp = new Date(2026, 6, 12)
            compare(got.getTime(), exp.getTime(), "VALUE=DATE → local midnight")
        }
        // AUDIT (high): DTSTART;TZID=… is ignored - parsed as floating-local. A
        // correct parser must treat the named zone differently from a floating
        // wall time, so on any host NOT in that zone the two instants differ.
        function test_tzid_is_not_treated_as_floating_local() {
            var w = h.item
            var tzid  = w.parseDT("20260712T090000", "DTSTART;TZID=America/New_York")
            var floatDt = w.parseDT("20260712T090000", "DTSTART")
            verify(tzid.getTime() !== floatDt.getTime(),
                   "TZID=America/New_York must not resolve to the same instant as a floating local time")
        }
        function test_malformed_dtstart_is_skipped_no_invalid_date() {
            var w = h.item
            var ics = vcal(
                vevent("SUMMARY:Broken\nDTSTART;VALUE=DATE-TIME:\n") +
                vevent("SUMMARY:Good\nDTSTART;VALUE=DATE-TIME:" + icsDateTime(daysFromNow(1)) + "\n"))
            var evs = w.parseICS(ics)
            for (var i = 0; i < evs.length; i++)
                verify(!isNaN(evs[i].start.getTime()), "no Invalid Date leaks into the sorted list")
            var titles = evs.map(function (e) { return e.title })
            verify(titles.indexOf("Good") >= 0, "the valid event still parses")
        }
    }

    // ── weekdayNums / exKey primitives ──────────────────────────────────────
    TestCase {
        name: "CalendarPrimitives"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000) }

        function test_weekday_nums() {
            var w = h.item
            compare(w.weekdayNums("MO,WE,FR"), [1, 3, 5], "MO,WE,FR")
            compare(w.weekdayNums("SU,SA"), [0, 6], "SU,SA")
            compare(w.weekdayNums("2MO"), [1], "ordinal prefix tolerated")
        }
        function test_daystart_zeroes_time() {
            var w = h.item
            var ds = w.dayStart(new Date(2026, 6, 12, 15, 30, 0))
            compare(ds.getHours(), 0)
            compare(ds.getMinutes(), 0)
        }

        function test_tomorrow_uses_the_next_calendar_day_across_dst() {
            var w = h.item
            var now = new Date()
            var tomorrow = new Date(now)
            tomorrow.setDate(tomorrow.getDate() + 1)
            tomorrow.setHours(9, 0, 0, 0)
            var ev = { start: tomorrow, allDay: false }
            verify(w.fmtWhen(ev).indexOf("Tomorrow") === 0,
                   "tomorrow is labelled by local calendar date")
        }
    }

    // ── recurrence expansion ────────────────────────────────────────────────
    TestCase {
        name: "CalendarRecurrence"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000) }

        function only(evs, title) { return evs.filter(function (e) { return e.title === title }) }

        function test_single_event_shows() {
            var w = h.item
            var ics = vcal(vevent("SUMMARY:One\nDTSTART;VALUE=DATE-TIME:" + icsDateTime(daysFromNow(2)) + "\n"))
            compare(only(w.parseICS(ics), "One").length, 1, "a lone future event appears once")
        }
        function test_daily_byday_free_expands_multiple() {
            var w = h.item
            var ics = vcal(vevent(
                "SUMMARY:Daily\nDTSTART;VALUE=DATE-TIME:" + icsDateTime(daysFromNow(-1)) + "\n" +
                "RRULE:FREQ=DAILY\n"))
            verify(only(w.parseICS(ics), "Daily").length > 5, "DAILY yields many occurrences across the horizon")
        }
        function test_daily_count_bounds_occurrences() {
            var w = h.item
            var ics = vcal(vevent(
                "SUMMARY:Cnt\nDTSTART;VALUE=DATE-TIME:" + icsDateTime(daysFromNow(0)) + "\n" +
                "RRULE:FREQ=DAILY;COUNT=3\n"))
            var evs = only(w.parseICS(ics), "Cnt")
            verify(evs.length >= 1 && evs.length <= 3, "COUNT=3 caps the series (got " + evs.length + ")")
        }
        function test_daily_until_bounds_occurrences() {
            var w = h.item
            var until = daysFromNow(3)
            var ics = vcal(vevent(
                "SUMMARY:Unt\nDTSTART;VALUE=DATE-TIME:" + icsDateTime(daysFromNow(0)) + "\n" +
                "RRULE:FREQ=DAILY;UNTIL=" + icsDateTime(until) + "\n"))
            var evs = only(w.parseICS(ics), "Unt")
            for (var i = 0; i < evs.length; i++)
                verify(evs[i].start.getTime() <= until.getTime() + 1000, "no occurrence past UNTIL")
        }
        function test_weekly_byday_only_listed_weekdays() {
            var w = h.item
            var ics = vcal(vevent(
                "SUMMARY:Standup\nDTSTART;VALUE=DATE-TIME:" + icsDateTime(daysFromNow(-1)) + "\n" +
                "RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR\n"))
            var evs = only(w.parseICS(ics), "Standup")
            verify(evs.length > 1, "multiple weekly occurrences")
            for (var i = 0; i < evs.length; i++) {
                var dow = evs[i].start.getDay()
                verify(dow === 1 || dow === 3 || dow === 5, "only Mon/Wed/Fri")
            }
        }
        function test_weekly_byday_interval_skips_weeks() {
            var w = h.item
            var ics = vcal(vevent(
                "SUMMARY:Fort\nDTSTART;VALUE=DATE-TIME:" + icsDateTime(daysFromNow(-1)) + "\n" +
                "RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;INTERVAL=2\n"))
            var evs = only(w.parseICS(ics), "Fort")
            // Collect the distinct (Sunday-anchored) week indices the occurrences fall in.
            var weeks = {}
            for (var i = 0; i < evs.length; i++) {
                var d = w.dayStart(evs[i].start); d.setDate(d.getDate() - d.getDay())
                weeks[Math.round(d.getTime() / (7 * 86400000))] = true
            }
            var idx = Object.keys(weeks).map(Number).sort(function (a, b) { return a - b })
            for (var j = 1; j < idx.length; j++)
                verify(idx[j] - idx[j - 1] >= 2, "INTERVAL=2 leaves a gap between active weeks (got "
                       + idx.join(",") + ")")
        }

        // AUDIT (high): MONTHLY recurrence started in the past is dropped entirely.
        function test_monthly_started_last_month_shows_this_period() {
            var w = h.item
            var target = daysFromNow(3)
            var ds = new Date(target); ds.setMonth(ds.getMonth() - 1)
            var ics = vcal(vevent(
                "SUMMARY:Monthly\nDTSTART;VALUE=DATE-TIME:" + icsDateTime(ds) + "\n" +
                "RRULE:FREQ=MONTHLY\n"))
            verify(only(w.parseICS(ics), "Monthly").length >= 1,
                   "a MONTHLY event started last month should show its upcoming occurrence")
        }
        // AUDIT (high): YEARLY recurrence (birthday) whose DTSTART is years ago is
        // dropped entirely rather than rolling to the next anniversary.
        function test_yearly_birthday_shows_next_anniversary() {
            var w = h.item
            var md = daysFromNow(5)          // this year's anniversary, 5 days out
            var old = new Date(md); old.setFullYear(2015)
            var ics = vcal(vevent(
                "SUMMARY:Birthday\nDTSTART;VALUE=DATE:" + icsDay(old) + "\n" +
                "RRULE:FREQ=YEARLY\n"))
            verify(only(w.parseICS(ics), "Birthday").length >= 1,
                   "a YEARLY birthday should appear on its next anniversary within the horizon")
        }
    }

    // ── expand(): horizon, duration, past-pruning, EXDATE (controlled clock) ──
    TestCase {
        name: "CalendarExpandBounds"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000) }

        function horizonFrom(now) { return new Date(now.getTime() + 30 * 86400000) }

        function test_in_progress_multiday_event_still_shows() {
            var w = h.item
            var now = new Date(); now.setHours(15, 0, 0, 0)
            var start = new Date(now); start.setDate(start.getDate() - 1); start.setHours(20, 0, 0, 0)
            var end = new Date(now); end.setDate(end.getDate() + 1); end.setHours(20, 0, 0, 0)
            var ev = { title: "Trip", start: start, end: end, allDay: false }
            compare(w.expand(ev, horizonFrom(now), now).length, 1,
                    "a multi-day event straddling now is still shown")
        }
        // AUDIT (medium): an event that already ENDED earlier today keeps showing
        // because the guard compares against start-of-day, not now.
        function test_event_ended_earlier_today_is_pruned() {
            var w = h.item
            var now = new Date(); now.setHours(15, 0, 0, 0)
            var start = new Date(now); start.setHours(10, 0, 0, 0)
            var end = new Date(now); end.setHours(11, 0, 0, 0)
            var ev = { title: "Done", start: start, end: end, allDay: false }
            compare(w.expand(ev, horizonFrom(now), now).length, 0,
                    "an event that ended earlier today should be pruned")
        }
        // AUDIT: all-day DTEND is exclusive; an all-day event whose end is today
        // occupied only yesterday and must not be shown today.
        function test_allday_exclusive_end_not_shown_extra_day() {
            var w = h.item
            var now = new Date(); now.setHours(15, 0, 0, 0)
            var start = midnight(now); start.setDate(start.getDate() - 1)
            var end = midnight(now)              // exclusive → yesterday only
            var ev = { title: "Yday", start: start, end: end, allDay: true }
            compare(w.expand(ev, horizonFrom(now), now).length, 0,
                    "an all-day event ending (exclusive) today should not appear today")
        }
        function test_event_beyond_horizon_excluded() {
            var w = h.item
            var now = new Date(); now.setHours(9, 0, 0, 0)
            var start = new Date(now.getTime() + 40 * 86400000)   // past the 30-day horizon
            var ev = { title: "Far", start: start, end: new Date(start.getTime() + 3600000), allDay: false }
            compare(w.expand(ev, horizonFrom(now), now).length, 0, "beyond horizon → not shown")
        }
        function test_exdate_excludes_matching_occurrence() {
            var w = h.item
            var now = new Date(); now.setHours(0, 0, 0, 0)
            var start = new Date(now); start.setHours(9, 0, 0, 0)
            var skip = new Date(start.getTime() + 86400000)       // tomorrow's occurrence
            var ev = { title: "Ex", start: start, end: new Date(start.getTime() + 3600000),
                       allDay: false, rrule: "FREQ=DAILY;COUNT=4", exdates: [skip] }
            var occ = w.expand(ev, horizonFrom(now), now)
            for (var i = 0; i < occ.length; i++)
                verify(w.exKey(occ[i].start) !== w.exKey(skip), "the EXDATE instance is excluded")
        }
        function test_allday_exdate_excludes_by_date() {
            var w = h.item
            var now = midnight(new Date())
            var start = new Date(now)                             // all-day, midnight
            var skip = new Date(now.getTime() + 86400000)
            var ev = { title: "AX", start: start, end: new Date(start.getTime() + 86400000),
                       allDay: true, rrule: "FREQ=DAILY;COUNT=4", exdates: [skip] }
            var occ = w.expand(ev, horizonFrom(now), now)
            var skipKey = skip.getFullYear() + "-" + skip.getMonth() + "-" + skip.getDate()
            for (var i = 0; i < occ.length; i++) {
                var k = occ[i].start.getFullYear() + "-" + occ[i].start.getMonth() + "-" + occ[i].start.getDate()
                verify(k !== skipKey, "the excluded all-day date does not appear")
            }
        }
        // DAILY stepping must keep a constant local wall-clock time. Within a
        // non-DST horizon this holds; across a DST transition (host-dependent)
        // the fixed-ms stepping drifts (audit medium).
        function test_daily_stepping_keeps_local_hour() {
            var w = h.item
            var now = new Date(); now.setHours(9, 0, 0, 0)
            var ev = { title: "Nine", start: new Date(now),
                       end: new Date(now.getTime() + 3600000), allDay: false, rrule: "FREQ=DAILY" }
            var occ = w.expand(ev, horizonFrom(now), now)
            verify(occ.length >= 20, "a month of daily occurrences")
            for (var i = 0; i < occ.length; i++)
                compare(occ[i].start.getHours(), 9, "occurrence " + i + " keeps 09:00 local")
        }
        // AUDIT (medium): a decades-old unbounded DAILY series must not iterate
        // without a guard. It should still complete quickly and yield today's run.
        function test_ancient_daily_completes_and_yields_current_run() {
            var w = h.item
            var ics = vcal(vevent(
                "SUMMARY:Ancient\nDTSTART;VALUE=DATE-TIME:20000101T090000\nRRULE:FREQ=DAILY\n"))
            var t0 = Date.now()
            var evs = w.parseICS(ics).filter(function (e) { return e.title === "Ancient" })
            var dt = Date.now() - t0
            verify(evs.length > 0, "still yields upcoming occurrences")
            verify(dt < 4000, "parse of a 26-year DAILY series completed in " + dt + "ms")
        }
    }

    // ── all-day vs timed classification (parseICS) ──────────────────────────
    TestCase {
        name: "CalendarAllDay"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000) }

        function test_value_date_is_all_day_datetime_is_not() {
            var w = h.item
            var when = daysFromNow(1)
            var ics = vcal(
                vevent("SUMMARY:Timed\nDTSTART;VALUE=DATE-TIME:" + icsDateTime(when) + "\n") +
                vevent("SUMMARY:Allday\nDTSTART;VALUE=DATE:" + icsDay(when) + "\n"))
            var evs = w.parseICS(ics)
            var timed = null, all = null
            for (var i = 0; i < evs.length; i++) {
                if (evs[i].title === "Timed") timed = evs[i]
                if (evs[i].title === "Allday") all = evs[i]
            }
            verify(timed && all, "both parsed")
            compare(timed.allDay, false, "DATE-TIME is not all-day")
            compare(all.allDay, true, "DATE is all-day")
        }
    }

    // ── fmtWhen labelling ───────────────────────────────────────────────────
    TestCase {
        name: "CalendarFmtWhen"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000) }

        function test_today_tomorrow_and_dated() {
            var w = h.item
            var now = new Date()
            // Construct events by CALENDAR DATE at noon (not now+Nh): an hour-offset
            // is time-of-day fragile - e.g. after ~22:00 wall-clock, now+26h rolls
            // into the day AFTER tomorrow, and near midnight now+1h rolls into
            // tomorrow. Noon on the target date is always that date, DST-safe.
            function atNoon(dayOffset) {
                return new Date(now.getFullYear(), now.getMonth(), now.getDate() + dayOffset, 12, 0, 0)
            }
            var todayEv = { start: atNoon(0), allDay: false }
            verify(w.fmtWhen(todayEv).indexOf("Today") === 0, "same-day → 'Today …'")
            var tomEv = { start: atNoon(1), allDay: false }
            verify(w.fmtWhen(tomEv).indexOf("Tomorrow") === 0, "next-day → 'Tomorrow …'")
            var farEv = { start: atNoon(6), allDay: false }
            var lbl = w.fmtWhen(farEv)
            verify(lbl.indexOf("Today") !== 0 && lbl.indexOf("Tomorrow") !== 0, "far event → dated label")
        }
        function test_allday_omits_time() {
            var w = h.item
            var ev = { start: new Date(), allDay: true }
            verify(w.fmtWhen(ev).indexOf(":") < 0, "all-day label carries no HH:mm")
        }
    }

    // ── config: url + maxEvents honouring & reactivity ──────────────────────
    TestCase {
        name: "CalendarConfig"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000); clear(h) }
        function set(k, v) { h.storeCtl.setSetting("test-instance", k, v) }

        function test_default_max_events_is_five() {
            compare(h.item.maxEvents, 5, "maxEvents defaults to 5")
        }
        function test_url_reacts_to_store_edit() {
            var w = h.item
            compare(w.url, "", "starts empty")
            set("url", "https://example.com/a.ics")
            compare(w.url, "https://example.com/a.ics", "cfg/url reacts to a store edit (revision bump)")
        }
        function test_shown_events_honours_max_events() {
            var w = h.item
            w.events = fakeEvents(8)
            set("maxEvents", 3)
            compare(w.shownEvents.length, 3, "shownEvents capped to maxEvents=3")
            set("maxEvents", 6)
            compare(w.shownEvents.length, 6, "raising maxEvents reveals more")
            set("maxEvents", 12)
            compare(w.shownEvents.length, 8, "…but never more than the available events")
        }
    }

    // ── compact tile: maxEvents on the collapsed face (audit low) ────────────
    TestCase {
        name: "CalendarCompactCap"
        when: windowShown
        function init() {
            tryVerify(function () { return hTile.ready }, 3000); clear(hTile)
            hTile.item.sizeClass = "compact"
        }

        // AUDIT: the compact face hard-caps at 3 and ignores maxEvents.
        function test_compact_face_honours_max_events() {
            var w = hTile.item
            // A non-empty url makes the event rows (not the empty prompt) visible;
            // the unreachable host fails fast without clobbering w.events.
            hTile.storeCtl.patchSettings("test-instance", { url: "http://127.0.0.1:1/x.ics", maxEvents: 6 })
            w.events = fakeEvents(8)
            compare(w.shownEvents.length, 6, "shownEvents honours maxEvents=6")
            wait(50)
            compare(visibleEventRowCount(hTile), 6,
                    "the compact tile should render maxEvents rows, not a hardcoded 3")
        }
    }

    // ── effAccent + host-injected chrome props ──────────────────────────────
    TestCase {
        name: "CalendarChrome"
        when: windowShown
        function init() {
            tryVerify(function () { return h.ready }, 3000)
            clear(h)
            h.item.accentName = ""; h.item.titleOverride = ""; h.item.cardBackdrop = "none"
        }

        function test_default_accent_is_services_category() {
            compare(String(h.item.effAccent), String(h.theme.catServices), "defaults to the Services accent")
        }
        function test_accent_preset_recolours_and_paints_bars() {
            var w = h.item
            w.events = fakeEvents(3)
            w.accentName = "purple"
            compare(String(w.effAccent), String(Qt.color(h.theme.accentPresets["purple"].a)),
                    "effAccent tracks the configured accent preset")
        }
        function test_title_override_reflected_in_header() {
            var w = h.item
            w.titleOverride = "My Agenda"
            var node = textEquals(h, "My Agenda")
            verify(node !== null && node.visible, "WidgetChrome header shows the injected titleOverride")
        }
        function test_card_backdrop_prop_injected() {
            var w = h.item
            w.cardBackdrop = "aurora"
            compare(w.cardBackdrop, "aurora", "injected cardBackdrop is honoured by the chrome")
        }
    }

    // ── fetch state machine (no live server) ────────────────────────────────
    TestCase {
        name: "CalendarFetch"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000); clear(h) }
        function set(k, v) { h.storeCtl.setSetting("test-instance", k, v) }

        function test_empty_url_makes_no_request() {
            var w = h.item
            w.refresh()
            compare(w.loading, false, "empty url → not loading")
            compare(w.errorText, "", "empty url → no error")
            compare(w.events.length, 0, "empty url → no events")
        }
        function test_unreachable_url_sets_error_without_corrupting_events() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { url: "http://127.0.0.1:1/nope.ics" })
            w.refresh()   // drive directly; avoid the 300ms debounce race
            tryVerify(function () { return !w.loading && w.errorText.length > 0 }, 14000,
                      "an unreachable URL settles with an error")
            verify(Array.isArray(w.events), "events remains a valid (uncorrupted) array")
        }
        // AUDIT (medium): webcal:// links (iCloud/Apple) are handed straight to
        // XMLHttpRequest with no https rewrite; a correct impl rewrites the scheme
        // rather than rejecting the URL as invalid.
        function test_webcal_url_is_not_rejected_as_invalid() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { url: "webcal://127.0.0.1:1/shared.ics" })
            w.refresh()
            tryVerify(function () { return !w.loading }, 14000, "fetch settles")
            verify(w.errorText !== "Invalid URL",
                   "webcal:// should be rewritten to https, not rejected as an invalid URL (got '"
                   + w.errorText + "')")
        }
    }

    // ── schema ↔ widget key sync (shared config-schema area) ────────────────
    TestCase {
        name: "CalendarSchema"
        when: windowShown

        function keysOf(s) {
            var keys = {}
            for (var i = 0; i < s.sections.length; i++)
                for (var j = 0; j < (s.sections[i].fields || []).length; j++)
                    if (s.sections[i].fields[j].key) keys[s.sections[i].fields[j].key] = true
            return keys
        }
        function fieldOf(s, key) {
            for (var i = 0; i < s.sections.length; i++)
                for (var j = 0; j < (s.sections[i].fields || []).length; j++)
                    if (s.sections[i].fields[j].key === key) return s.sections[i].fields[j]
            return null
        }

        function test_calendar_schema_exposes_url_and_max_events() {
            var s = sc.schemaFor("calendar")
            verify(s && s.sections && s.sections.length > 0, "calendar has a schema")
            var keys = keysOf(s)
            verify(keys["url"] === true, "schema exposes 'url'")
            verify(keys["maxEvents"] === true, "schema exposes 'maxEvents'")
        }
        function test_max_events_field_bounds_match_widget() {
            var f = fieldOf(sc.schemaFor("calendar"), "maxEvents")
            verify(f !== null, "maxEvents field present")
            compare(f.min, 1, "min 1")
            compare(f.max, 12, "max 12")
            compare(f.dflt, 5, "default 5 matches the widget's fallback")
        }
        // The decision below is user-facing, so it is documented where the user
        // sets the number, not only in the code.
        function test_max_events_help_states_it_is_a_maximum() {
            var f = fieldOf(sc.schemaFor("calendar"), "maxEvents")
            verify(f.help && f.help.length > 0, "maxEvents carries a help string")
            verify(/at most/i.test(f.help),
                   "the help says it is a MAXIMUM, not an exact count: " + f.help)
        }
    }

    // ── Per-sizeClass structure + THE maxEvents DECISION (W1 wave 3) ─────────
    TestCase {
        name: "CalendarSizes"
        when: windowShown

        function initTestCase() { tryVerify(function () { return hS.ready }, 3000) }

        function shape(width, height, cls, maxEvents, nEvents) {
            sizeWrap.width = width; sizeWrap.height = height
            hS.item.sizeClass = cls
            hS.storeCtl.patchSettings("test-instance",
                { url: "http://127.0.0.1:1/x.ics", maxEvents: maxEvents })
            hS.item.events = fakeEvents(nEvents === undefined ? 12 : nEvents)
            wait(32)
            return hS.item
        }

        // ── THE DECISION, both directions ───────────────────────────────────
        // maxEvents is a MAXIMUM the user asks for; the size decides how many of
        // those actually fit.

        // 1. NEVER more than the user asked for - however much room there is.
        function test_a_huge_tile_never_shows_more_than_the_user_asked_for() {
            var w = shape(696, 1637, "large", 3, 12)
            compare(w.rowsFit >= 12, true, "a 1x2 portrait box has room for far more")
            compare(w.shownCount, 3, "but the user said 3, so it shows 3")
            compare(w.shownEvents.length, 3)
        }

        // 2. NEVER overflow the box - a small tile drops the tail instead.
        function test_a_small_tile_drops_the_tail_rather_than_overflowing() {
            var w = shape(846, 306, "wide", 12, 12)
            verify(w.shownCount < 12,
                   "a 306px-tall box cannot hold 12 rows, so it shows fewer ("
                   + w.shownCount + ")")
            verify(w.shownCount > 0, "but it still shows the ones that fit")
            // Nothing is clipped: the last row ends inside the card.
            wait(32)
            compare(visibleEventRowCount(hS), w.shownCount,
                    "every counted row is actually rendered")
        }

        // 3. Never more than we actually HAVE.
        function test_never_invents_events_it_does_not_have() {
            var w = shape(696, 1637, "large", 12, 2)
            compare(w.shownCount, 2, "two events exist, so two are shown")
        }

        // ── Per-size structure ──────────────────────────────────────────────
        // An agenda reads top-to-bottom, so a second column is EARNED (when one
        // column would drop events), never taken just because the box is wide.
        function test_one_column_while_one_column_is_enough() {
            var tall = shape(696, 1228, "tall", 12, 12)
            verify(tall.rowsPerCol >= 12, "one column already holds all twelve")
            compare(tall.eventCols, 1, "so it stays a single, top-to-bottom agenda")
            compare(tall.shownCount, 12)
        }
        function test_columns_are_earned_when_one_column_would_drop_events() {
            var wide = shape(696, 409, "wide", 12, 12)
            verify(wide.rowsPerCol < 12, "a 409px box cannot stack twelve rows")
            compare(wide.eventCols, 2, "so it earns a second column")
            compare(wide.shownCount, 12, "and all twelve fit after all")
        }
        // `large` is the SAME class for both 1x2 projections - the count has to
        // come from the box, not the class.
        function test_large_resolves_by_shape_not_by_class_alone() {
            var largePt = shape(696, 1637, "large", 12, 12)
            compare(largePt.eventCols, 1, "1x2 PORTRAIT is tall → one column")
            var largeLs = shape(1692, 612, "large", 12, 12)
            verify(largeLs.eventCols > 1,
                   "1x2 LANDSCAPE is the same class but wide-and-short → columns ("
                   + largeLs.eventCols + ")")
            compare(largeLs.shownCount, 12, "both projections still show all twelve")
        }
        // A column is only added if it can be read: never narrower than the
        // narrowest tile that already reads fine (the 348px half-cell).
        function test_a_narrow_box_never_splits_into_unreadable_columns() {
            var w = shape(348, 819, "tall", 12, 12)
            compare(w.maxColsByWidth, 1, "348px seats exactly one readable column")
            compare(w.eventCols, 1, "so it stays one column and drops the tail instead")
            verify(w.shownCount < 12, "showing " + w.shownCount + " of 12")
        }

        // The row scale follows the box instead of a fixed 12px/26px everywhere.
        function test_rows_scale_with_the_box() {
            var small = shape(846, 306, "wide", 12, 12)
            var smallH = small.rowH
            var big = shape(696, 1637, "large", 12, 12)
            verify(big.rowH > smallH,
                   "a taller box earns taller rows (" + smallH + " → " + big.rowH + ")")
        }

        // 1x2 is calendar's largest declared size, and 12 events is why: the cap
        // stops short of filling the whole screen.
        function test_the_largest_size_can_show_the_whole_twelve_event_cap() {
            var w = shape(696, 1637, "large", 12, 12)
            compare(w.shownCount, 12, "1x2 portrait holds the entire maxEvents cap")
        }

        // The unconfigured state ships in the presets - it must stay legible.
        function test_unconfigured_prompt_is_legible_at_every_declared_size() {
            var cases = [
                [348, 819, "tall"],  [846, 306, "wide"],      // 0.5x1
                [696, 409, "wide"],  [423, 612, "tall"],      // 1x0.5
                [696, 819, "compact"], [846, 612, "compact"], // 1x1
                [696, 1228, "tall"], [1269, 612, "wide"],     // 1x1.5
                [696, 1637, "large"], [1692, 612, "large"]    // 1x2
            ]
            for (var i = 0; i < cases.length; i++) {
                sizeWrap.width = cases[i][0]; sizeWrap.height = cases[i][1]
                hS.item.sizeClass = cases[i][2]
                hS.storeCtl.patchSettings("test-instance", { url: "" })
                hS.item.events = []
                wait(32)
                var tag = cases[i][0] + "x" + cases[i][1]
                var t = allTexts(hS), found = null
                for (var j = 0; j < t.length; j++)
                    if (t[j].text.indexOf("Add a calendar") >= 0 && t[j].visible) found = t[j]
                verify(found !== null, tag + ": the prompt is shown when no URL is set")
                verify(found.font.pixelSize >= 11,
                       tag + ": the prompt stays legible (" + found.font.pixelSize + "px)")
                verify(found.width <= cases[i][0],
                       tag + ": the prompt fits inside the tile")
            }
        }
    }
}
