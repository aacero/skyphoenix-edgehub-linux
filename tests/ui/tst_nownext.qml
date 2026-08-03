import QtQuick
import QtTest
import "fixtures.js" as Fx
import "../../ui/qml/widgets" as W

// ─────────────────────────────────────────────────────────────────────────
// tst_nownext - ui/qml/widgets/NowNextWidget.qml.
//
// The widget derives now/next from a nested CalendarWidget's ICS model rather
// than parsing ICS a second time. Two consequences this file has to prove:
//   1. The derivation is right - including the all-day case, where CalendarWidget
//      leaves end == start and a naive start<=now<end would report that an all-day
//      event is never happening.
//   2. Embedding a Calendar did not smuggle a fetch around the egress gate. The
//      nested instance must obey the SAME NetHub kill switch and allowlist, or the
//      "no telemetry / local-only" claim has a hole in it that no lint would see
//      (check_no_raw_xhr.sh only proves this file builds no XHR itself - it cannot
//      prove the one it delegates to is gated).
//
// Events are injected straight into the nested model where the ICS layer is not
// what is under test, and driven through a FakeXHR where it is.
// ─────────────────────────────────────────────────────────────────────────
Item {
    id: root
    width: 1000; height: 760

    WidgetHarness {
        id: h; x: 0; y: 0; width: 620; height: parent.height
        widgetFile: "NowNextWidget.qml"; expanded: true
    }
    W.NetHub { id: gate }

    function clearSettings(harness) {
        var s = harness.storeCtl.settingsFor("test-instance")
        for (var k in s) delete s[k]
        harness.storeCtl._touchSettings()
    }
    // The nested agenda model, reached the way a caller never should - this is the
    // one place that is allowed to know it exists.
    function agenda() {
        var kids = root.findAll(h.item, function (n) { return n.hasOwnProperty("parseICS") }, [])
        return kids.length ? kids[0] : null
    }
    function findAll(node, pred, acc) {
        acc = acc || []
        if (!node) return acc
        if (pred(node)) acc.push(node)
        var kids = node.children
        for (var i = 0; kids && i < kids.length; i++) findAll(kids[i], pred, acc)
        return acc
    }
    // A Timer is not a visual child - it is a resource. `data` is the union of
    // children and resources, so this is the only walk that can see one.
    function findAllData(node, pred, acc) {
        acc = acc || []
        if (!node) return acc
        if (pred(node)) acc.push(node)
        var kids = node.data
        for (var i = 0; kids && i < kids.length; i++) findAllData(kids[i], pred, acc)
        return acc
    }
    function ev(title, startDelta, durMin, allDay) {
        var s = new Date(Date.now() + startDelta * 60000)
        return { title: title, location: "", allDay: !!allDay,
                 start: s, end: new Date(s.getTime() + durMin * 60000) }
    }
    function setEvents(list) { var a = root.agenda(); a.events = list }

    // ── now / next derivation ────────────────────────────────────────────
    TestCase {
        name: "NowNextDerivation"
        when: windowShown
        function init() {
            tryVerify(function () { return h.ready }, 3000)
            clearSettings(h); h.active = false
            // The url change below arms CalendarWidget's 300 ms refresh debounce.
            // Hand it a fake that never resolves, so a stray fire can neither reach
            // the network nor overwrite the events this test injects.
            h.item.xhrFactory = function () { return Fx.makeFakeXHR() }
            h.storeCtl.patchSettings("test-instance", { url: "https://example.com/cal.ics" })
            verify(root.agenda() !== null, "the nested agenda model exists")
            root.setEvents([])
        }

        function test_an_event_in_progress_is_now() {
            root.setEvents([ root.ev("Standup", -10, 30) ])       // started 10 min ago, 30 min long
            verify(h.item.nowEvent !== null, "an in-progress event is 'now'")
            compare(h.item.nowEvent.title, "Standup")
            compare(h.item.nextEvent, null, "and there is nothing after it")
        }

        function test_the_soonest_future_event_is_next() {
            root.setEvents([ root.ev("Soon", 30, 60), root.ev("Later", 300, 60) ])
            compare(h.item.nowEvent, null, "nothing is happening yet")
            compare(h.item.nextEvent.title, "Soon", "the soonest upcoming event is next")
        }

        function test_now_and_next_are_reported_together() {
            root.setEvents([ root.ev("Standup", -5, 25), root.ev("Review", 60, 30) ])
            compare(h.item.nowEvent.title, "Standup")
            compare(h.item.nextEvent.title, "Review", "next is the one after the current one")
        }

        // The boundary that matters: an event that has just ended is not 'now'.
        function test_a_finished_event_is_neither_now_nor_next() {
            root.setEvents([ root.ev("Done", -120, 30) ])
            compare(h.item.nowEvent, null, "an ended event is not 'now'")
            compare(h.item.nextEvent, null, "and it is certainly not 'next'")
        }

        // CalendarWidget leaves dur = 0 for an all-day event with no DTEND, so
        // end == start (midnight). Without endOf()'s day-long floor, an all-day
        // event today would never be 'now'.
        function test_an_allday_event_today_is_now() {
            var midnight = new Date(); midnight.setHours(0, 0, 0, 0)
            root.setEvents([ { title: "Conference", location: "", allDay: true,
                               start: midnight, end: midnight } ])
            verify(h.item.nowEvent !== null, "a zero-length all-day event today still counts as now")
            compare(h.item.nowEvent.title, "Conference")
            compare(h.item.untilText(h.item.nowEvent), "all day")
        }

        function test_endOf_gives_an_allday_event_its_whole_day() {
            var midnight = new Date(); midnight.setHours(0, 0, 0, 0)
            var e = { title: "X", allDay: true, start: midnight, end: midnight }
            var nextMidnight = new Date(midnight)
            nextMidnight.setDate(nextMidnight.getDate() + 1)
            compare(h.item.endOf(e), nextMidnight.getTime(),
                    "all-day spans the complete local calendar day")
            var timed = root.ev("Y", 0, 30)
            compare(h.item.endOf(timed), timed.end.getTime(), "a timed event keeps its real end")
        }

        function test_endOf_is_calendar_based_at_dst_boundary() {
            var midnight = new Date(2026, 2, 29, 0, 0, 0, 0)
            var expected = new Date(midnight)
            expected.setDate(expected.getDate() + 1)
            var e = { title: "DST day", allDay: true, start: midnight, end: midnight }
            compare(h.item.endOf(e), expected.getTime(),
                    "all-day end is next local midnight, including a short or long DST day")
        }

        function test_no_events_means_no_now_and_no_next() {
            root.setEvents([])
            compare(h.item.nowEvent, null)
            compare(h.item.nextEvent, null)
        }
    }

    // ── copy ─────────────────────────────────────────────────────────────
    TestCase {
        name: "NowNextCopy"
        when: windowShown
        function init() {
            tryVerify(function () { return h.ready }, 3000)
            clearSettings(h); h.active = false
            // The url change below arms CalendarWidget's 300 ms refresh debounce.
            // Hand it a fake that never resolves, so a stray fire can neither reach
            // the network nor overwrite the events this test injects.
            h.item.xhrFactory = function () { return Fx.makeFakeXHR() }
            h.storeCtl.patchSettings("test-instance", { url: "https://example.com/cal.ics" })
            root.setEvents([])
        }

        function test_humanDelta_reads_naturally() {
            var w = h.item
            compare(w.humanDelta(0), "now")
            compare(w.humanDelta(-5), "now", "a past start never reads as negative time")
            compare(w.humanDelta(1), "in 1 min")
            compare(w.humanDelta(45), "in 45 min")
            compare(w.humanDelta(60), "in 1 h")
            compare(w.humanDelta(90), "in 1 h 30 min")
            compare(w.humanDelta(1440), "in 1 day")
            compare(w.humanDelta(2880), "in 2 days")
        }

        // Rounding UP: for the 59 s before a meeting, "in 0 min" would be wrong.
        function test_minutesUntil_rounds_up() {
            var w = h.item
            compare(w.minutesUntil(new Date(Date.now() + 30000)), 1, "30 s away is 'in 1 min'")
            compare(w.minutesUntil(new Date(Date.now() + 61000)), 2)
        }

        function test_whenText_shows_the_clock_time_and_the_delta() {
            var e = root.ev("Review", 45, 30)
            var t = h.item.whenText(e)
            compare(t.indexOf(Qt.formatTime(e.start, "HH:mm")) >= 0, true, "shows the start time")
            compare(t.indexOf("in 45 min") >= 0, true, "and how long until it")
        }

        function test_buffer_window_and_meeting_link_are_useful() {
            var w = h.item
            var soon = root.ev("Review", 5, 30)
            soon.location = "Video https://meet.example.com/abc"
            compare(w.whenText(soon).indexOf("starts soon") >= 0, true)
            compare(w.meetingUrl(soon), "https://meet.example.com/abc")
            soon.url = "https://teams.example.com/join"
            compare(w.meetingUrl(soon), "https://teams.example.com/join")
        }

        // `bufferMin` is the widget's one tunable and it was the least-covered
        // setting found in the whole audit: its ONLY appearance anywhere under
        // tests/ was tst_schema_completeness.qml:63 asserting the field exists.
        // The test above does produce "starts soon", but at the DEFAULT buffer -
        // so a widget that hardcoded 10 instead of reading cfg.bufferMin passed
        // every test in the suite.
        // COVERS: schema:nownext.bufferMin
        function test_buffer_minutes_setting_moves_the_starts_soon_boundary_data() {
            return [
                { tag: "tight-5", buffer: 5 },
                { tag: "default-10", buffer: 10 },
                { tag: "wide-30", buffer: 30 },
                { tag: "max-120", buffer: 120 }
            ]
        }
        function test_buffer_minutes_setting_moves_the_starts_soon_boundary(data) {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { bufferMin: data.buffer })
            compare(w.bufferMin, data.buffer, "the setting reaches the widget")

            // Exactly ON the boundary is inside the window: the copy says
            // "starts soon" for anything up to and including the buffer.
            var onEdge = root.ev("Review", data.buffer, 30)
            verify(w.whenText(onEdge).indexOf("starts soon") >= 0,
                   "an event " + data.buffer + " min out is inside a "
                   + data.buffer + "-minute buffer")

            // One minute past it is not, and must fall back to the delta copy.
            var pastEdge = root.ev("Review", data.buffer + 1, 30)
            var t = w.whenText(pastEdge)
            verify(t.indexOf("starts soon") < 0,
                   "an event " + (data.buffer + 1) + " min out is outside it (got '"
                   + t + "')")
            verify(t.indexOf("in ") >= 0,
                   "and still says how long until it")
        }

        // The widget clamps to 0..120 (NowNextWidget.qml:59-60). A stored value
        // outside that range is not a reason to render nonsense.
        function test_buffer_minutes_are_clamped_to_a_sane_range_data() {
            return [
                { tag: "over-max", stored: 500, effective: 120 },
                { tag: "negative", stored: -5, effective: 0 },
                { tag: "at-max", stored: 120, effective: 120 },
                { tag: "at-min", stored: 0, effective: 0 }
            ]
        }
        function test_buffer_minutes_are_clamped_to_a_sane_range(data) {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { bufferMin: data.stored })
            compare(w.bufferMin, data.effective,
                    data.stored + " must clamp to " + data.effective)
        }

        // A zero buffer means "never tell me something starts soon" - and the
        // `mins > 0` half of the guard must keep an event starting THIS minute
        // out of the window too, rather than 0 <= 0 letting it back in.
        function test_a_zero_buffer_disables_the_starts_soon_copy() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { bufferMin: 0 })
            compare(w.bufferMin, 0)
            var imminent = root.ev("Review", 0, 30)
            verify(w.whenText(imminent).indexOf("starts soon") < 0,
                   "a zero buffer never produces the starts-soon copy")
            var oneOut = root.ev("Review", 1, 30)
            verify(w.whenText(oneOut).indexOf("starts soon") < 0)
        }

        function test_meeting_link_strips_calendar_punctuation() {
            var e = root.ev("Review", 5, 30)
            e.location = "Join at https://meet.example.com/abc)."
            compare(h.item.meetingUrl(e), "https://meet.example.com/abc")
        }

        function test_join_requires_a_second_confirming_action() {
            var w = h.item
            var opened = []
            w.externalOpener = function (url) { opened.push(url); return true }
            var target = "https://meet.example.com/room"
            w.requestJoin(target)
            compare(opened.length, 0, "first action only arms confirmation")
            compare(w.pendingJoinUrl, target)
            compare(w.joinLabel(target), "Open meet.example.com?")
            w.requestJoin(target)
            compare(opened.length, 1, "second action opens the destination")
            compare(opened[0], target)
            compare(w.pendingJoinUrl, "")
        }
    }

    // ── settings ─────────────────────────────────────────────────────────
    TestCase {
        name: "NowNextSettings"
        when: windowShown
        function init() {
            tryVerify(function () { return h.ready }, 3000)
            clearSettings(h); h.active = false
            // The url change below arms CalendarWidget's 300 ms refresh debounce.
            // Hand it a fake that never resolves, so a stray fire can neither reach
            // the network nor overwrite the events this test injects.
            h.item.xhrFactory = function () { return Fx.makeFakeXHR() }
        }

        // One tile, one source of truth: the nested model must read the SAME url
        // setting, not a second copy of it.
        function test_the_url_setting_reaches_the_nested_agenda() {
            h.storeCtl.patchSettings("test-instance", { url: "https://example.com/cal.ics" })
            compare(h.item.url, "https://example.com/cal.ics")
            compare(root.agenda().url, "https://example.com/cal.ics",
                    "the agenda model reads the same setting, not its own")
        }

        function test_no_url_asks_for_one_rather_than_inventing_events() {
            // Seed a real agenda first, so this proves the empty url CLEARS it
            // rather than merely observing a model that was already empty.
            h.storeCtl.patchSettings("test-instance", { url: "https://example.com/cal.ics" })
            root.setEvents([ root.ev("Standup", -5, 30) ])
            verify(h.item.nowEvent !== null, "there is something to lose")
            h.storeCtl.patchSettings("test-instance", { url: "" })
            h.item.refresh()
            compare(h.item.url, "")
            compare(h.item.events.length, 0, "no url → the agenda is emptied…")
            compare(h.item.nowEvent, null, "…so nothing is invented")
            compare(h.item.nextEvent, null)
        }
    }

    // ── the egress gate ──────────────────────────────────────────────────
    // Embedding CalendarWidget must not create a fetch that escapes the gate.
    TestCase {
        name: "NowNextGate"
        when: windowShown
        property var lastFake: null
        function init() {
            tryVerify(function () { return h.ready }, 3000)
            clearSettings(h); h.active = false; lastFake = null
            h.storeCtl.patchSettings("test-instance", { url: "https://example.com/cal.ics" })
            gate.offline = false; gate.allowHosts = []
            gate.requests = 0; gate.blocked = 0
            gate._sharedProviders = ({})
            gate.sharedRevision = 0
            h.item.netHub = gate
            var tc = this
            h.item.xhrFactory = function () { tc.lastFake = Fx.makeFakeXHR(); return tc.lastFake }
        }
        function cleanup() {
            gate.offline = false; gate.allowHosts = []
            gate._sharedProviders = ({})
            gate.sharedRevision = 0
            h.item.netHub = null
        }

        function test_offline_refuses_the_agenda_fetch() {
            gate.offline = true
            h.item.refresh()
            compare(lastFake, null, "the kill switch refuses before any socket is opened")
            compare(gate.requests, 0, "nothing counted as sent")
            compare(gate.blocked, 1, "the refusal is counted (attestation)")
            compare(h.item.errorText, "Calendar is offline", "and the tile says why")
        }

        function test_an_unlisted_host_is_blocked() {
            gate.allowHosts = ["intranet.example.com"]
            h.item.refresh()
            compare(lastFake, null, "an unlisted host never gets a socket")
            compare(gate.blocked, 1, "counted as blocked")
            compare(h.item.errorText, "Calendar host not allowed")
        }

        // The end-to-end path: a real ICS body through the gate becomes now/next.
        function test_an_allowed_fetch_parses_into_now_and_next() {
            gate.allowHosts = ["example.com"]
            h.item.refresh()
            verify(lastFake !== null && lastFake.sent, "listing the host lets the fetch through")
            compare(gate.requests, 1, "counted as sent")
            lastFake.resolveWith(200, Fx.icsValid())
            verify(h.item.events.length > 0, "the ICS parsed via the nested model")
            verify(h.item.nowEvent !== null || h.item.nextEvent !== null,
                   "and it resolved into something to show")
        }

        function test_the_poll_is_gated_on_active() {
            var a = root.agenda()
            h.active = false
            var timers = root.findAllData(a, function (n) {
                return n.hasOwnProperty("interval") && n.interval === 900000
            }, [])
            verify(timers.length === 1, "the agenda has its 15-minute poll")
            compare(timers[0].running, false, "an inactive tile does not poll")
            h.active = true
            compare(timers[0].running, true, "an active tile with a URL does")
            h.active = false
        }
    }

    // ── Per-sizeClass structure (W1 wave 2b) ────────────────────────────────
    // Fixed-size hosts at the real projected cell footprints. nownext declares no
    // 0.5x0.5 and no 1x2+, so there is no micro and no large case.
    Item { width: 348; height: 819
        WidgetHarness { id: nTall; anchors.fill: parent; widgetFile: "NowNextWidget.qml"; expanded: false } }
    Item { width: 696; height: 819
        WidgetHarness { id: nBase; anchors.fill: parent; widgetFile: "NowNextWidget.qml"; expanded: false } }
    Item { id: nWideWrap; width: 846; height: 306
        WidgetHarness { id: nWide; anchors.fill: parent; widgetFile: "NowNextWidget.qml"; expanded: false } }

    TestCase {
        name: "NowNextSizes"
        when: windowShown

        function agendaOf(host) {
            var kids = root.findAll(host.item, function (n) { return n.hasOwnProperty("parseICS") }, [])
            return kids.length ? kids[0] : null
        }
        function seed(host) {
            host.storeCtl.patchSettings(host.instanceId, { url: "https://example.invalid/a.ics" })
            var current = root.ev("Standup", -10, 30)
            var next = root.ev("Design review", 55, 60)
            current.url = "https://meet.example.com/current"
            next.url = "https://meet.example.com/next"
            agendaOf(host).events = [ current, next ]
        }
        // The content GridLayout: the "NOW" label's grandparent.
        function layOf(host) {
            var t = root.findAll(host.item, function (n) {
                return n.hasOwnProperty("text") && String(n.text) === "NOW" }, [])[0]
            return t ? t.parent.parent : null
        }

        // The type is sized off the BOX, not off `expanded` - the wave-2b bug.
        function test_the_type_scales_with_the_tile() {
            tryVerify(function () { return nBase.ready }, 3000)
            tryVerify(function () { return nTall.ready }, 3000)
            nTall.item.sizeClass = "tall"; seed(nTall)
            var n = nBase.item
            n.sizeClass = "compact"
            seed(nBase)
            wait(32)
            verify(n.titlePx > 17,
                   "a 696x819 tile reads past the old flat 17px (" + n.titlePx.toFixed(0) + ")")
            verify(n.titlePx > nTall.item.titlePx,
                   "…and bigger than a 348x819 sliver's (" + n.titlePx.toFixed(0)
                   + " vs " + nTall.item.titlePx.toFixed(0) + ")")
            verify(n.nextTitlePx < n.titlePx, "NEXT stays quieter than NOW")
            verify(n.metaPx >= nBase.theme.fontLabel,
                   "metadata never drops below the shared legibility floor")
        }

        function test_join_is_available_at_each_supported_shape() {
            var hosts = [
                { host: nTall, cls: "tall" },
                { host: nBase, cls: "compact" },
                { host: nWide, cls: "wide" }
            ]
            for (var i = 0; i < hosts.length; i++) {
                tryVerify((function (entry) { return function () { return entry.host.ready } })(hosts[i]), 3000)
                hosts[i].host.item.sizeClass = hosts[i].cls
                seed(hosts[i].host)
                wait(32)
                var buttons = root.findAll(hosts[i].host.item, function (n) {
                    return n.hasOwnProperty("label") && n.hasOwnProperty("clicked")
                           && n.visible && String(n.label).indexOf("Join ") === 0
                }, [])
                verify(buttons.length > 0, hosts[i].cls + " exposes a Join action")
                verify(buttons[0].height >= 48, hosts[i].cls + " Join is touch sized")
            }
        }

        // wide - the two blocks sit side by side rather than splitting 306px.
        function test_wide_puts_now_beside_next() {
            tryVerify(function () { return nWide.ready }, 3000)
            var n = nWide.item
            n.sizeClass = "tall"
            seed(nWide)
            wait(32)
            var lay = layOf(nWide)
            compare(lay.columns, 1, "a tall box stacks the two blocks")
            n.sizeClass = "wide"
            wait(32)
            compare(n.horiz, true, "wide is the horizontal shape")
            compare(lay.columns, 3, "wide is NOW | hairline | NEXT")
            // Side by side, each block gets the whole height rather than half.
            verify(n._blockH > 200, "each block gets the banner's full height ("
                   + n._blockH.toFixed(0) + ")")
            n.sizeClass = "tall"
        }

        // Only NOW showing must not leave the hairline or a phantom column.
        function test_a_lone_block_hides_the_hairline() {
            tryVerify(function () { return nBase.ready }, 3000)
            var n = nBase.item
            n.sizeClass = "compact"
            nBase.storeCtl.patchSettings(nBase.instanceId, { url: "https://example.invalid/a.ics" })
            agendaOf(nBase).events = [ root.ev("Standup", -10, 30) ]
            wait(32)
            verify(n.nowEvent !== null, "NOW is showing")
            compare(n.nextEvent, null, "NEXT is not")
            var hair = root.findAll(n, function (x) {
                return x.hasOwnProperty("color") && x.hasOwnProperty("border")
                       && x.height === 1 }, [])
            for (var i = 0; i < hair.length; i++)
                compare(hair[i].visible, false, "the hairline is hidden with only one block")
        }
    }
}
