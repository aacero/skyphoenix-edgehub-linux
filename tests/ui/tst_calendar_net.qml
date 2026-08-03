import QtQuick
import QtTest
import "fixtures.js" as Fx
import "../../ui/qml" as App
import "../../ui/qml/widgets" as W


// ─────────────────────────────────────────────────────────────────────────
// tst_calendar_net - network path of ui/qml/widgets/CalendarWidget.qml, driven
// offline through the `xhrFactory` seam (handed to NetHub, which the widget
// routes its fetch through). A FakeXHR (fixtures.js) captures the request URL
// and resolves ONLY on an explicit test call - no wall-clock waits, no real
// sockets.
//
// Covers: request URL (pass-through + webcal:// → https:// rewrite), empty-URL
// short-circuit, every fixture → widget state mapping (valid ICS → events
// parsed, non-200 → fetch error, empty calendar → "No upcoming events",
// un-readable body → read error, timeout → timed out), and - since E8 - that
// the egress gate's kill switch and host allowlist actually govern the fetch.
// ─────────────────────────────────────────────────────────────────────────
Item {
    id: root
    width: 640; height: 720

    WidgetHarness {
        id: h; anchors.fill: parent
        widgetFile: "CalendarWidget.qml"; expanded: true
    }

    // Stands in for the app-global gate Dashboard injects, so the tests can drive
    // `offline` / `allowHosts` the way managed config does.
    W.NetHub { id: gate }
    App.WidgetConfigSchema { id: configSchema }

    function clearSettings(harness) {
        var s = harness.storeCtl.settingsFor("test-instance")
        for (var k in s) delete s[k]
        harness.storeCtl._touchSettings()
    }

    TestCase {
        name: "CalendarConfigPrivacy"

        function test_subscription_url_is_masked_and_recommends_a_reference() {
            var sections = configSchema.schemaFor("calendar").sections
            var field = null
            for (var i = 0; i < sections.length; i++) {
                var fields = sections[i].fields || []
                for (var j = 0; j < fields.length; j++)
                    if (fields[j].key === "url") field = fields[j]
            }
            verify(field !== null, "calendar URL field exists")
            compare(field.type, "secret", "calendar URL uses the masked editor")
            verify(field.help.indexOf("${env:CALENDAR_ICS_URL}") >= 0,
                   "a non-persisted environment reference is documented")
            verify(field.help.indexOf("0600") >= 0,
                   "legacy literal storage protection is disclosed")
        }
    }

    // ── request URL construction / short-circuit ─────────────────────────
    TestCase {
        name: "CalendarNetUrl"
        when: windowShown
        property var lastFake: null
        function init() {
            tryVerify(function () { return h.ready }, 3000)
            clearSettings(h); h.active = false; lastFake = null
            var tc = this
            h.item.xhrFactory = function () { tc.lastFake = Fx.makeFakeXHR(); return tc.lastFake }
        }

        function test_empty_url_makes_no_request() {
            var w = h.item
            w.refresh()
            compare(lastFake, null, "an empty URL never constructs an XHR")
            compare(w.loading, false, "empty URL → not loading")
            compare(w.errorText, "", "empty URL → no error")
            compare(w.events.length, 0, "empty URL → no events")
            compare(w.providerState, "unconfigured")
            compare(w.status, "Setup")
        }

        function test_https_url_passed_through() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { url: "https://example.com/cal.ics" })
            w.refresh()
            verify(lastFake !== null, "factory used instead of a real XHR")
            compare(w.providerState, "loading")
            compare(w.status, "Loading")
            compare(lastFake.method, "GET", "ICS fetch is a GET")
            verify(lastFake.sent, "send() was called")
            compare(lastFake.url, "https://example.com/cal.ics", "https URL used verbatim")
        }

        // webcal:// (iCloud/Apple) is ICS over HTTP(S); the widget rewrites the
        // scheme rather than handing XMLHttpRequest a scheme it rejects.
        function test_webcal_scheme_rewritten_to_https() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { url: "webcal://example.com/shared.ics" })
            w.refresh()
            verify(lastFake !== null, "webcal is not rejected before a request is built")
            compare(lastFake.url, "https://example.com/shared.ics", "webcal:// → https://")
            verify(w.errorText !== "Invalid URL", "webcal is not treated as invalid")
        }

        function test_secret_reference_resolves_inside_the_gate() {
            var w = h.item
            gate.secretResolver = {
                resolveSecret: function (raw) {
                    return raw === "${env:CALENDAR_ICS_URL}"
                        ? { ok: true, value: "https://private.example/feed.ics", error: "", plaintext: false }
                        : { ok: false, value: "", error: "missing", plaintext: false }
                }
            }
            w.netHub = gate
            h.storeCtl.patchSettings("test-instance", { url: "${env:CALENDAR_ICS_URL}" })
            w.refresh()
            compare(w.url, "${env:CALENDAR_ICS_URL}", "the widget retains only the reference")
            compare(lastFake.url, "https://private.example/feed.ics")
            verify(w.sourceHost().indexOf("private calendar") >= 0,
                   "the display does not reveal the resolved host")
            gate.secretResolver = null
        }

        function cleanup() {
            h.item.netHub = null
            gate.secretResolver = null
        }
    }

    // ── response → widget state ──────────────────────────────────────────
    TestCase {
        name: "CalendarNetStates"
        when: windowShown
        property var lastFake: null
        function init() {
            tryVerify(function () { return h.ready }, 3000)
            clearSettings(h); h.active = false; lastFake = null
            h.item.events = []; h.item.errorText = ""; h.item.loading = false
            h.storeCtl.patchSettings("test-instance", { url: "https://example.com/cal.ics" })
            var tc = this
            h.item.xhrFactory = function () { tc.lastFake = Fx.makeFakeXHR(); return tc.lastFake }
        }
        function drive(status, body) { h.item.refresh(); lastFake.resolveWith(status, body) }

        function test_valid_ics_parses_events() {
            var w = h.item
            w.nowMsOverride = 700000
            drive(200, Fx.icsValid())
            compare(w.loading, false, "settled")
            compare(w.errorText, "", "a valid feed clears any error")
            compare(w.events.length, 3, "three upcoming VEVENTs parsed")
            verify(w.events[0].start.getTime() <= w.events[1].start.getTime(), "events are sorted ascending")
            var titles = w.events.map(function (e) { return e.title })
            verify(titles.indexOf("Standup") >= 0 && titles.indexOf("Review") >= 0
                   && titles.indexOf("Planning") >= 0, "all three summaries present")
            compare(w.lastSuccessAt, 700000)
            compare(w.stale, false)
            compare(w.providerState, "fresh")
            w.nowMsOverride = 700000 + w.refreshSec * 2000
            compare(w.stale, true)
            compare(w.providerState, "stale")
            compare(w.status, "Stale")
            w.nowMsOverride = -1
        }

        function test_non_200_sets_fetch_error() {
            var w = h.item
            drive(200, Fx.icsValid())
            var prior = w.events.length
            drive(404, "")
            compare(w.loading, false, "settled")
            compare(w.errorText, "Couldn't fetch calendar", "a 404 reports a fetch error")
            verify(Array.isArray(w.events), "events remains a valid array (uncorrupted)")
            compare(w.events.length, prior, "the last useful agenda remains visible")
        }

        // The widget can emit THREE distinct warnings, all sharing an
        // "Unsupported" prefix. This case's payload (FREQ=HOURLY;BYMINUTE=30)
        // fires two of them at once, and asserting only indexOf("Unsupported")
        // cannot tell which - so either emit site could be deleted and this
        // still passed. Each is now pinned by name below; this case keeps the
        // "partial parse still shows the useful events" contract.
        function test_unsupported_recurrence_is_disclosed() {
            var future = Qt.formatDateTime(new Date(Date.now() + 86400000), "yyyyMMdd'T'HHmmss")
            drive(200, "BEGIN:VCALENDAR\nBEGIN:VEVENT\nDTSTART:" + future
                  + "\nSUMMARY:Hourly\nRRULE:FREQ=HOURLY;BYMINUTE=30\nEND:VEVENT\nEND:VCALENDAR")
            verify(h.item.parseWarnings.length >= 1)
            verify(h.item.parseWarnings.join(" ").indexOf("Unsupported") >= 0)
            compare(h.item.providerState, "fresh", "partial parsing does not discard useful events")
            compare(h.item.status, "Partial")
            compare(h.item.events.length, 1, "the event itself is still shown, once")
        }

        // Each warning names WHAT it could not honour, so a user can act on it.
        // A bare "Unsupported" would leave them guessing which rule was dropped.
        function test_each_parse_warning_names_its_own_cause_data() {
            return [
                { tag: "recurrence-part",
                  rrule: "RRULE:FREQ=DAILY;BYSETPOS=2", tzid: "",
                  want: "Unsupported recurrence rule: BYSETPOS" },
                // HOURLY, not MONTHLY: MONTHLY and YEARLY ARE supported (they
                // step by calendar month/year for birthdays and monthly bills),
                // which the `supportedParts` list above them does not reveal.
                { tag: "recurrence-frequency",
                  rrule: "RRULE:FREQ=HOURLY", tzid: "",
                  want: "Unsupported recurrence frequency: HOURLY" },
                // The half of the widget's own promise ("reports any unsupported
                // timezone") that no test had ever triggered: it needs a TZID the
                // offset table cannot resolve, which no fixture supplied.
                { tag: "timezone",
                  rrule: "", tzid: ";TZID=Mars/Olympus",
                  want: "Unsupported timezone: Mars/Olympus" }
            ]
        }
        function test_each_parse_warning_names_its_own_cause(data) {
            var future = Qt.formatDateTime(new Date(Date.now() + 86400000), "yyyyMMdd'T'HHmmss")
            drive(200, "BEGIN:VCALENDAR\nBEGIN:VEVENT\nDTSTART" + data.tzid + ":" + future
                  + "\nSUMMARY:Thing" + (data.rrule.length ? "\n" + data.rrule : "")
                  + "\nEND:VEVENT\nEND:VCALENDAR")
            var joined = h.item.parseWarnings.join(" | ")
            verify(joined.indexOf(data.want) >= 0,
                   "expected '" + data.want + "' among [" + joined + "]")
            compare(h.item.status, "Partial",
                    "and the header says the agenda is not complete coverage")
        }

        // The frequencies the widget really does expand must NOT be disclosed as
        // dropped - a regression routing them into the unsupported branch would
        // silently degrade every birthday and monthly bill to a single instance
        // while still rendering something plausible.
        function test_supported_recurrence_frequencies_are_not_warned_about_data() {
            return [ { tag: "daily", freq: "DAILY" }, { tag: "weekly", freq: "WEEKLY" },
                     { tag: "monthly", freq: "MONTHLY" }, { tag: "yearly", freq: "YEARLY" } ]
        }
        function test_supported_recurrence_frequencies_are_not_warned_about(data) {
            var future = Qt.formatDateTime(new Date(Date.now() + 86400000), "yyyyMMdd'T'HHmmss")
            drive(200, "BEGIN:VCALENDAR\nBEGIN:VEVENT\nDTSTART:" + future
                  + "\nSUMMARY:Thing\nRRULE:FREQ=" + data.freq + "\nEND:VEVENT\nEND:VCALENDAR")
            compare(h.item.parseWarnings.length, 0,
                    data.freq + " is expanded, not dropped: " + h.item.parseWarnings.join(" | "))
            verify(h.item.events.length >= 1, data.freq + " still yields an upcoming occurrence")
        }

        // A calendar the widget fully understands must not cry partial.
        function test_a_fully_supported_calendar_warns_about_nothing() {
            drive(200, Fx.icsValid())
            compare(h.item.parseWarnings.length, 0,
                    "nothing was dropped, so nothing is disclosed: "
                    + h.item.parseWarnings.join(" | "))
            verify(h.item.status !== "Partial", "and the header does not say Partial")
        }

        function test_empty_calendar_is_no_upcoming_events() {
            var w = h.item
            drive(200, Fx.ICS_EMPTY)
            compare(w.events.length, 0, "a calendar with no VEVENT yields nothing")
            compare(w.errorText, "", "an empty successful feed is not an error")
            compare(w.providerState, "empty")
            compare(w.status, "Empty")
        }

        // 200 OK but an unreadable body (parse throws) → read-error branch.
        function test_unreadable_body_is_read_error() {
            var w = h.item
            drive(200, null)   // parseICS(null) throws → caught
            compare(w.errorText, "Couldn't read calendar", "an un-parseable body reports a read error")
        }

        function test_timeout_sets_timed_out() {
            var w = h.item
            w.refresh()
            compare(w.loading, true, "in flight")
            lastFake.fireTimeout()
            compare(w.loading, false, "timeout settles the request")
            compare(w.errorText, "Calendar timed out", "an unresolved socket times out")
            compare(w.providerState, "disconnected")
            compare(w.status, "Offline")
        }

        // A superseded fetch's late callback must not overwrite the newer result.
        function test_stale_fetch_ignored_after_supersede() {
            var w = h.item
            w.refresh()
            var stale = lastFake
            w.refresh()
            verify(stale.aborted, "the older in-flight fetch is aborted")
            var fresh = lastFake
            fresh.resolveWith(200, Fx.icsValid())
            compare(w.events.length, 3, "the fresh fetch lands")
            stale.resolveWith(404, "")   // late callback from the aborted fetch
            compare(w.errorText, "", "the stale callback is ignored (no error set)")
            compare(w.events.length, 3, "events untouched by the stale callback")
        }
    }

    // ── egress gate (E8) ─────────────────────────────────────────────────
    // Calendar used to build its own XHR, which put the ICS subscription fetch
    // outside the offline switch and the allowlist entirely. Now that it routes
    // through NetHub it must be refusable centrally - that is the whole point of
    // the migration, so assert it rather than trusting the call site.
    TestCase {
        name: "CalendarNetGate"
        when: windowShown
        property var lastFake: null
        function init() {
            tryVerify(function () { return h.ready }, 3000)
            clearSettings(h); h.active = false; lastFake = null
            h.item.events = []; h.item.errorText = ""; h.item.loading = false
            h.storeCtl.patchSettings("test-instance", { url: "https://example.com/cal.ics" })
            gate.offline = false; gate.allowHosts = []
            gate.requests = 0; gate.blocked = 0
            gate._sharedProviders = ({})
            gate.sharedRevision = 0
            h.item.netHub = gate
            var tc = this
            h.item.xhrFactory = function () { tc.lastFake = Fx.makeFakeXHR(); return tc.lastFake }
        }
        function cleanup() { gate.offline = false; gate.allowHosts = [] }

        function test_offline_refuses_the_fetch() {
            var w = h.item
            gate.offline = true
            w.refresh()
            compare(lastFake, null, "the kill switch refuses before any socket is opened")
            compare(gate.requests, 0, "nothing counted as sent")
            compare(gate.blocked, 1, "the gate counted the refusal (attestation)")
            compare(w.loading, false, "the fetch settles instead of spinning forever")
            compare(w.errorText, "Calendar is offline", "the tile says why it has no agenda")
            compare(w.events.length, 0, "no events invented while offline")
            compare(w.providerState, "disconnected")
            compare(w.status, "Offline")
        }

        function test_allowlist_excluding_the_host_blocks_the_fetch() {
            var w = h.item
            gate.allowHosts = ["intranet.example.com"]
            w.refresh()
            compare(lastFake, null, "an unlisted host never gets a socket")
            compare(gate.requests, 0, "not counted as sent")
            compare(gate.blocked, 1, "counted as blocked")
            compare(w.loading, false, "the refusal settles the request")
            compare(w.errorText, "Calendar host not allowed", "policy is distinguished from failure")
            compare(w.providerState, "blocked")
            compare(w.status, "Blocked")
        }

        function test_allowlisted_host_still_fetches_normally() {
            var w = h.item
            gate.allowHosts = ["example.com"]
            w.refresh()
            verify(lastFake !== null && lastFake.sent, "listing the host lets the ICS fetch through")
            compare(gate.requests, 1, "counted as sent, by host")
            compare(gate.blocked, 0, "nothing refused")
            lastFake.resolveWith(200, Fx.icsValid())
            compare(w.events.length, 3, "and the agenda parses exactly as before the gate")
            compare(w.errorText, "")
        }

        // webcal:// is rewritten to https:// BEFORE the gate sees it. If it were
        // not, NetHub would classify the unknown scheme as a local file and wave
        // it through - a private calendar fetch escaping the kill switch.
        function test_webcal_is_gated_on_its_real_https_host() {
            var w = h.item
            gate.offline = true
            h.storeCtl.patchSettings("test-instance", { url: "webcal://example.com/shared.ics" })
            w.refresh()
            compare(lastFake, null, "webcal:// is not a local-file bypass around offline")
            compare(gate.blocked, 1, "it is gated as the https host it really is")
            compare(w.errorText, "Calendar is offline")
        }
    }
}
