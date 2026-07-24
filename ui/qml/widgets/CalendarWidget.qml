import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Calendar - real agenda from an ICS subscription URL (Google/Outlook/Nextcloud
// all provide one). Fetched + parsed in QML (no extra deps). Handles VEVENT +
// simple DAILY/WEEKLY recurrence; MONTHLY/YEARLY fall back to a single instance.
// Genuine empty state prompts for a URL rather than showing fake events.
//
// The fetch goes through NetHub, never a raw XHR, so the global offline switch,
// the host allowlist and the attestation counters cover it. Parsed events stay in
// widget properties: they are never written to the store, so a poll cannot churn
// config.toml.
//
// `url` is a bearer capability. It may be stored as an environment/file secret
// reference; NetHub resolves that reference inside request() so the plaintext URL
// never becomes a widget property. Legacy literal URLs remain supported.
WidgetChrome {
    id: w
    property var metrics: ({})
    property bool expanded: false
    property bool active: true
    property var store: null
    property string instanceId: ""
    property int tick: 0
    // The egress gate. Injected by Dashboard (one app-global instance); a local
    // fallback keeps the widget self-contained in tests / standalone use.
    property var netHub: null
    NetHub { id: _fallbackHub }
    function _hub() { return netHub ? netHub : _fallbackHub }
    // Test seam: a per-request XHR factory handed to the gate, so a FakeXHR can be
    // injected. null in production → the gate builds the real XHR.
    property var xhrFactory: null

    title: "Calendar"; iconName: "calendar"; accentColor: theme.catServices

    readonly property var cfg: {
        var _ = store ? store.revision : 0
        return (store && instanceId) ? JSON.parse(JSON.stringify(store.settingsFor(instanceId))) : ({})
    }
    readonly property string url: cfg.url || ""
    readonly property int maxEvents: cfg.maxEvents !== undefined ? cfg.maxEvents : 5
    property var events: []        // expanded, sorted upcoming
    property string errorText: ""
    property bool loading: false
    property double lastSuccessAt: 0
    property double nowMsOverride: -1
    property var parseWarnings: []
    property string stateHelp: ""
    readonly property int refreshSec: 900
    readonly property string sharedKind: "calendar-ics-v1"
    function currentMs() { return w.nowMsOverride >= 0 ? w.nowMsOverride : Date.now() }
    ProviderState {
        id: provider
        configured: w.url.length > 0
        loading: w.loading
        hasData: w.events.length > 0
        errorText: w.errorText
        lastSuccessAt: w.lastSuccessAt
        nowMs: (w.tick, w.currentMs())
        staleAfterSec: w.refreshSec * 2
    }
    readonly property string providerState: provider.state
    readonly property int refreshAgeSec: provider.ageSec
    readonly property bool stale: provider.isStale
    function freshnessText() { return provider.freshnessText }
    function sourceHost() {
        if (w._hub()._looksLikeRef && w._hub()._looksLikeRef(w.url))
            return "private calendar source"
        var m = /^(?:https?|webcal):\/\/([^\/:?#]+)/i.exec(w.url)
        return m ? m[1] : "configured calendar"
    }
    function addParseWarning(message) {
        if (w.parseWarnings.indexOf(message) < 0) w.parseWarnings = w.parseWarnings.concat([message])
    }
    status: (provider.state === "fresh" || provider.state === "empty")
            && w.parseWarnings.length ? "Partial" : provider.badgeLabel
    statusColor: provider.state !== "fresh" || w.parseWarnings.length
                 ? theme.warning : w.effAccent

    // ── Per-size layout (sizeClass injected by Dashboard) ────────────────────
    readonly property bool horiz: sizeClass === "wide"
    readonly property bool tallish: sizeClass === "tall" || sizeClass === "large"

    readonly property real rowH: Math.max(40, Math.min(height * 0.075, 64))
    // Rows one column can hold without overflowing.
    readonly property int rowsPerCol: {
        var avail = w.height - w.headerHeight - 24 - 2 * theme.spacingSm
        return Math.max(1, Math.floor(avail / (w.rowH + 4)))
    }
    // What we would show if the box were unlimited.
    readonly property int wantCount: Math.max(0, Math.min(w.maxEvents, w.events.length))
    // An agenda reads top-to-bottom, so ONE column is the right answer whenever
    // one column can carry what the user asked for. Extra columns are earned only
    // when a single column would drop events AND the width can seat a readable
    // one (~340px - the width of the narrowest tile that already reads fine, the
    // 0.5x1 portrait half-cell).
    //
    // This has to be geometric rather than keyed off sizeClass alone: `large` is
    // the SAME class for 1x2 portrait (696x1637) and 1x2 landscape (1692x612),
    // so the class cannot say whether events want one column or four. It is a
    // count derived from the box, not a size class re-derived from w/h.
    readonly property int maxColsByWidth: Math.max(1, Math.min(4, Math.floor(width / 340)))
    readonly property int eventCols: {
        if (w.expanded) return 1
        var needed = Math.ceil(w.wantCount / Math.max(1, w.rowsPerCol))
        return Math.max(1, Math.min(needed, w.maxColsByWidth))
    }
    // How many rows the box can hold without overflowing.
    readonly property int rowsFit: {
        // The overlay's list scrolls, so nothing is dropped there.
        if (w.expanded) return w.maxEvents
        return w.rowsPerCol * w.eventCols
    }

    // ── THE maxEvents DECISION ───────────────────────────────────────────────
    // A size-derived row cap and a user setting could fight; they don't, because
    // they answer different questions:
    //
    //   `maxEvents` is a MAXIMUM - "never show me more than this many".
    //   The SIZE decides how many of those actually fit.
    //
    // So the count is the min of three things: what the user asked for, what we
    // actually have, and what the box holds. NEVER more than the user asked for
    // (a big tile does not overrule "only show me 3"), and NEVER an overflowing
    // box (a small tile drops the tail rather than clipping it mid-row). This is
    // the same rule weather applies to `forecastDays`, and it is pinned by tests.
    readonly property int shownCount: Math.max(0, Math.min(w.wantCount, w.rowsFit))
    readonly property var shownEvents: events.slice(0, shownCount)

    function pad(n) { return (n < 10 ? "0" : "") + n }
    function dayStart(d) { var x = new Date(d); x.setHours(0, 0, 0, 0); return x }

    function parseDT(val, key) {
        val = val.trim()
        var y = +val.substr(0, 4), mo = +val.substr(4, 2) - 1, d = +val.substr(6, 2)
        if (val.length <= 8) return new Date(y, mo, d)
        var h = +val.substr(9, 2), mi = +val.substr(11, 2), s = +val.substr(13, 2) || 0
        if (val.indexOf("Z") >= 0) return new Date(Date.UTC(y, mo, d, h, mi, s))
        // A named zone (DTSTART;TZID=…) is NOT a floating wall time: anchor it to
        // the zone's offset. Only a bare timed value stays device-local.
        var tz = tzidOf(key)
        var off = tz ? tzOffsetMinutes(tz, y, mo, d) : null
        if (off !== null) return new Date(Date.UTC(y, mo, d, h, mi, s) - off * 60000)
        if (tz) w.addParseWarning("Unsupported timezone: " + tz)
        return new Date(y, mo, d, h, mi, s)
    }

    // Extract a TZID parameter from a property line's key part.
    function tzidOf(key) { var m = /TZID=([^;:]+)/.exec(key || ""); return m ? m[1].trim() : null }

    // Best-effort zone → offset (minutes east of UTC) WITHOUT a tz database
    // (QML's JS engine has no Intl). Explicit numeric-offset zones resolve
    // exactly; a table of common IANA zones carries US/EU daylight-saving rules;
    // anything unrecognised returns null so the caller falls back to floating.
    function tzOffsetMinutes(tzid, y, mo, d) {
        if (!tzid) return null
        var m = /(?:GMT|UTC)?\s*([+-])(\d{2}):?(\d{2})/.exec(tzid)
        if (m) { var v = (+m[2]) * 60 + (+m[3]); return m[1] === "-" ? -v : v }
        var eg = /Etc\/GMT([+-])(\d{1,2})/.exec(tzid)   // POSIX sign is inverted
        if (eg) return (eg[1] === "+" ? -1 : 1) * (+eg[2]) * 60
        var zones = {
            "America/New_York": [-300, "US"], "America/Chicago": [-360, "US"],
            "America/Denver": [-420, "US"], "America/Los_Angeles": [-480, "US"],
            "America/Anchorage": [-540, "US"], "America/Phoenix": [-420, null],
            "America/Sao_Paulo": [-180, null], "America/Halifax": [-240, "US"],
            "Europe/London": [0, "EU"], "Europe/Dublin": [0, "EU"], "Europe/Lisbon": [0, "EU"],
            "Europe/Berlin": [60, "EU"], "Europe/Paris": [60, "EU"], "Europe/Madrid": [60, "EU"],
            "Europe/Rome": [60, "EU"], "Europe/Amsterdam": [60, "EU"], "Europe/Zurich": [60, "EU"],
            "Europe/Vienna": [60, "EU"], "Europe/Warsaw": [60, "EU"], "Europe/Athens": [120, "EU"],
            "Europe/Helsinki": [120, "EU"], "Europe/Istanbul": [180, null], "Europe/Moscow": [180, null],
            "UTC": [0, null], "Etc/UTC": [0, null], "GMT": [0, null],
            "Asia/Kolkata": [330, null], "Asia/Dubai": [240, null], "Asia/Shanghai": [480, null],
            "Asia/Singapore": [480, null], "Asia/Hong_Kong": [480, null], "Asia/Tokyo": [540, null],
            "Australia/Sydney": [600, "AUE"], "Pacific/Auckland": [720, "NZ"]
        }
        var z = zones[tzid]
        if (!z) return null
        return z[0] + (z[1] && inDst(z[1], y, mo, d) ? 60 : 0)
    }

    function nthSunday(y, mo, n) {
        var first = new Date(y, mo, 1).getDay()
        return 1 + ((7 - first) % 7) + (n - 1) * 7
    }
    function lastSunday(y, mo) {
        var last = new Date(y, mo + 1, 0)
        return last.getDate() - last.getDay()
    }
    // Approximate daylight-saving membership by local calendar date (mo 0-based).
    function inDst(rule, y, mo, d) {
        if (rule === "US") {   // 2nd Sun Mar → 1st Sun Nov
            if (mo < 2 || mo > 10) return false
            if (mo > 2 && mo < 10) return true
            return mo === 2 ? d >= nthSunday(y, 2, 2) : d < nthSunday(y, 10, 1)
        }
        if (rule === "EU") {   // last Sun Mar → last Sun Oct
            if (mo < 2 || mo > 9) return false
            if (mo > 2 && mo < 9) return true
            return mo === 2 ? d >= lastSunday(y, 2) : d < lastSunday(y, 9)
        }
        if (rule === "AUE") {  // southern: 1st Sun Oct → 1st Sun Apr
            if (mo > 9 || mo < 3) return true
            if (mo > 3 && mo < 9) return false
            return mo === 9 ? d >= nthSunday(y, 9, 1) : d < nthSunday(y, 3, 1)
        }
        if (rule === "NZ") {   // southern: last Sun Sep → 1st Sun Apr
            if (mo > 8 || mo < 3) return true
            if (mo > 3 && mo < 8) return false
            return mo === 8 ? d >= lastSunday(y, 8) : d < nthSunday(y, 3, 1)
        }
        return false
    }

    // BYDAY tokens → weekday numbers (SU=0…SA=6), tolerating ordinal prefixes
    // like "2MO" by keeping only the trailing two-letter day code.
    function weekdayNums(byday) {
        var map = { SU: 0, MO: 1, TU: 2, WE: 3, TH: 4, FR: 5, SA: 6 }
        var out = []
        byday.split(",").forEach(function (t) {
            var d = t.replace(/[^A-Z]/g, "").slice(-2)
            if (map[d] !== undefined) out.push(map[d])
        })
        return out
    }
    // Comparison key for EXDATE matching: calendar day + hour + minute (robust to
    // the small tz/format variations between DTSTART and EXDATE in real feeds).
    function exKey(d) {
        return d.getFullYear() + "-" + d.getMonth() + "-" + d.getDate() + "-" + d.getHours() + "-" + d.getMinutes()
    }

    function expand(ev, horizonEnd, now) {
        var out = []
        var todayStart = dayStart(now)
        // Duration of the event, used so an occurrence that STARTED before today
        // but hasn't finished yet (multi-day / in-progress) still counts.
        var dur = (ev.end && ev.start) ? (ev.end.getTime() - ev.start.getTime()) : 0
        var excl = {}
        if (ev.exdates) ev.exdates.forEach(function (d) { excl[exKey(d)] = true })
        // Emit one occurrence (honours EXDATE exclusions + horizon/past bounds).
        function emit(occStart) {
            if (excl[exKey(occStart)]) return                          // cancelled (EXDATE)
            if (occStart > horizonEnd) return
            var finished
            if (ev.allDay) {
                // All-day DTEND is exclusive; the event occupies whole days
                // (default 1). Past once its last-occupied day is before today.
                var occEnd = occStart.getTime() + (dur > 0 ? dur : 86400000)
                finished = occEnd <= todayStart.getTime()
            } else {
                // Timed: past only once it has actually ended - compare against
                // now, not start-of-day (else events done earlier today linger).
                finished = occStart.getTime() + dur < now.getTime()
            }
            if (finished) return
            out.push({ title: ev.title, location: ev.location, url: ev.url || "", allDay: ev.allDay,
                       start: new Date(occStart), end: new Date(occStart.getTime() + dur) })
        }
        if (!ev.rrule) {
            var effEnd = ev.end || ev.start
            if (effEnd >= todayStart && ev.start <= horizonEnd) emit(ev.start)
            return out
        }
        var parts = {}
        ev.rrule.split(";").forEach(function (p) { var kv = p.split("="); parts[kv[0]] = kv[1] })
        var supportedParts = ["FREQ", "INTERVAL", "COUNT", "UNTIL", "BYDAY"]
        for (var partName in parts)
            if (supportedParts.indexOf(partName) < 0)
                w.addParseWarning("Unsupported recurrence rule: " + partName)
        var interval = +(parts.INTERVAL || 1)
        var count = parts.COUNT ? +parts.COUNT : 100000
        var until = parts.UNTIL ? parseDT(parts.UNTIL, "") : horizonEnd
        var freq = parts.FREQ, n = 0

        // WEEKLY with BYDAY (e.g. MO,WE,FR): walk day-by-day across the horizon and
        // emit each listed weekday that falls on an active interval-week.
        if (freq === "WEEKLY" && parts.BYDAY) {
            var days = weekdayNums(parts.BYDAY)
            var startWeek = dayStart(ev.start); startWeek.setDate(startWeek.getDate() - startWeek.getDay())
            var cursor = dayStart(ev.start)
            if (cursor < todayStart) cursor = new Date(todayStart)
            var guard = 0
            while (cursor <= horizonEnd && cursor <= until && n < count && out.length < 200 && guard < 800) {
                guard++
                if (days.indexOf(cursor.getDay()) >= 0) {
                    var cw = dayStart(cursor); cw.setDate(cw.getDate() - cw.getDay())
                    var weekIdx = Math.round((cw.getTime() - startWeek.getTime()) / (7 * 86400000))
                    if (weekIdx >= 0 && weekIdx % interval === 0) {
                        var occ = new Date(cursor)
                        occ.setHours(ev.start.getHours(), ev.start.getMinutes(), ev.start.getSeconds(), 0)
                        if (occ >= ev.start) { emit(occ); n++ }
                    }
                }
                var nc = new Date(cursor); nc.setDate(nc.getDate() + 1); cursor = nc  // calendar-day step (DST-safe)
            }
            return out
        }

        // MONTHLY / YEARLY: step by calendar month/year, rolling a past DTSTART
        // forward to its upcoming occurrence (birthdays, monthly bills, …).
        if (freq === "MONTHLY" || freq === "YEARLY") {
            var occM = new Date(ev.start), guardM = 0
            while (occM <= horizonEnd && occM <= until && n < count && out.length < 200 && guardM < 100000) {
                guardM++
                emit(occM)
                var nxM = new Date(occM)
                if (freq === "MONTHLY") nxM.setMonth(nxM.getMonth() + interval)
                else nxM.setFullYear(nxM.getFullYear() + interval)
                occM = nxM; n++
            }
            return out
        }

        var stepDays = freq === "WEEKLY" ? 7 * interval : (freq === "DAILY" ? interval : 0)
        if (stepDays === 0) { // unsupported FREQ → single instance
            w.addParseWarning("Unsupported recurrence frequency: " + freq)
            var effEnd0 = ev.end || ev.start
            if (effEnd0 >= todayStart && ev.start <= horizonEnd) emit(ev.start)
            return out
        }
        // Step by calendar days so the local wall-clock time survives DST
        // transitions (a fixed 86400000ms delta would drift the hour by ±1).
        var occ2 = new Date(ev.start)
        while (occ2 <= horizonEnd && occ2 <= until && n < count && out.length < 200) {
            emit(occ2)
            var nx2 = new Date(occ2); nx2.setDate(nx2.getDate() + stepDays); occ2 = nx2; n++
        }
        return out
    }

    function parseICS(text) {
        w.parseWarnings = []
        var raw = text.replace(/\r\n/g, "\n").replace(/\n[ \t]/g, "") // unfold
        var lines = raw.split("\n")
        var evs = [], cur = null
        for (var i = 0; i < lines.length; i++) {
            var line = lines[i]
            if (line === "BEGIN:VEVENT") cur = {}
            else if (line === "END:VEVENT") { if (cur && cur.start) evs.push(cur); cur = null }
            else if (cur) {
                var ci = line.indexOf(":"); if (ci < 0) continue
                var key = line.substring(0, ci), val = line.substring(ci + 1)
                var name = key.split(";")[0]
                if (name === "SUMMARY") cur.title = val
                else if (name === "LOCATION") cur.location = val
                else if (name === "URL") cur.url = val
                else if (name === "RRULE") cur.rrule = val
                else if (name === "DTSTART") {
                    cur.start = parseDT(val, key)
                    // VALUE=DATE marks an all-day event, but must NOT match the
                    // longer VALUE=DATE-TIME (which is a normal timed event).
                    cur.allDay = key.indexOf("VALUE=DATE") >= 0 && key.indexOf("VALUE=DATE-TIME") < 0
                }
                else if (name === "DTEND") cur.end = parseDT(val, key)
                else if (name === "EXDATE") {
                    cur.exdates = cur.exdates || []
                    val.split(",").forEach(function (v) { if (v.trim().length) cur.exdates.push(parseDT(v, key)) })
                }
            }
        }
        var now = new Date(), horizon = new Date(now.getTime() + 30 * 86400000)
        var all = []
        for (var j = 0; j < evs.length; j++)
            all = all.concat(expand(evs[j], horizon, now))
        all.sort(function (a, b) { return a.start - b.start })
        return all.slice(0, 60)
    }

    // The sequence token - not the XHR object - is the supersede guard: the gate
    // refuses offline/blocked requests synchronously and returns null, so there is
    // no XHR to compare a callback against in exactly the cases that must still report.
    property var _xhr: null
    property int _seq: 0
    function _syncShared() {
        if (!w.url.length || !w._hub().sharedProvider) return false
        var entry = w._hub().sharedProvider(w.sharedKind, w.url)
        if (!entry) return false
        w.loading = !!entry.loading
        if (entry.events !== undefined) w.events = entry.events
        if (entry.parseWarnings !== undefined) w.parseWarnings = entry.parseWarnings
        if (entry.lastSuccessAt !== undefined) w.lastSuccessAt = Number(entry.lastSuccessAt || 0)
        w.errorText = entry.errorText || ""
        w.stateHelp = entry.stateHelp || ""
        return true
    }
    Connections {
        target: w._hub()
        function onSharedRevisionChanged() { w._syncShared() }
    }
    Component.onDestruction: {
        if (_xhr) _xhr.abort()
        if (w.url.length && w._hub().releaseSharedProvider)
            w._hub().releaseSharedProvider(w.sharedKind, w.url, w, "")
    }
    function refresh(force) {
        var forceNow = force === undefined ? true : !!force
        if (!url.length) {
            events = []; errorText = ""; stateHelp = ""; loading = false; parseWarnings = []
            return
        }
        if (_xhr) _xhr.abort()
        w._xhr = null
        if (w._hub().claimSharedProvider
                && !w._hub().claimSharedProvider(w.sharedKind, w.url, w,
                                                  forceNow ? 0 : 3000)) {
            w._syncShared()
            return
        }
        loading = true
        stateHelp = ""
        var seq = ++w._seq
        var xhr = w._hub().request({
            url: w.url,
            urlIsSecretRef: true,
            normalizeWebcal: true,
            timeout: 12000,
            maxResponseBytes: 2097152,
            xhrFactory: w.xhrFactory,
            onDone: function (status, body) {
                if (seq !== w._seq) return   // superseded by a newer fetch
                w._xhr = null
                w.loading = false
                try {
                    w.events = w.parseICS(body)
                    w.errorText = ""
                    w.stateHelp = w.events.length
                        ? "Calendar is up to date."
                        : "The subscription connected successfully but has no events in the next 30 days."
                    w.lastSuccessAt = w.currentMs()
                    if (w._hub().publishSharedProvider)
                        w._hub().publishSharedProvider(w.sharedKind, w.url, w, {
                            events: w.events,
                            parseWarnings: w.parseWarnings,
                            errorText: "",
                            stateHelp: w.stateHelp,
                            lastSuccessAt: w.lastSuccessAt
                        })
                } catch (e) {
                    w.errorText = "Couldn't read calendar"
                    w.stateHelp = "Check that the subscription returns a valid ICS calendar."
                    if (w._hub().publishSharedProvider)
                        w._hub().publishSharedProvider(w.sharedKind, w.url, w, {
                            events: w.events,
                            parseWarnings: w.parseWarnings,
                            errorText: w.errorText,
                            stateHelp: w.stateHelp,
                            lastSuccessAt: w.lastSuccessAt
                        })
                }
            },
            onError: function (reason) {
                if (seq !== w._seq) return
                w._xhr = null
                w.loading = false
                w.errorText = reason === "offline" ? "Calendar is offline"
                    : reason === "blocked" ? "Calendar host not allowed"
                    : reason === "timeout" ? "Calendar timed out"
                    : reason === "open-failed" || reason === "unsupported-scheme" ? "Invalid URL"
                    : reason === "response-too-large" ? "Calendar response is too large"
                    : reason.indexOf("url-secret:") === 0 ? "Private calendar URL unavailable"
                    : "Couldn't fetch calendar"
                w.stateHelp = reason === "offline" ? "Turn off Offline mode, then refresh."
                    : reason === "blocked" ? "Allow this calendar host in network policy."
                    : reason.indexOf("url-secret:") === 0
                        ? "Check the environment or file reference in widget settings."
                    : reason === "response-too-large"
                        ? "Use a calendar subscription smaller than 2 MiB."
                    : "Check the subscription URL and network, then refresh."
                if (w._hub().publishSharedProvider)
                    w._hub().publishSharedProvider(w.sharedKind, w.url, w, {
                        events: w.events,
                        parseWarnings: w.parseWarnings,
                        errorText: w.errorText,
                        stateHelp: w.stateHelp,
                        lastSuccessAt: w.lastSuccessAt
                    })
            }
        })
        if (seq === w._seq) w._xhr = xhr
    }

    property string _urlKey: url
    on_UrlKeyChanged: if (w.active) refreshDebounce.restart()
    onActiveChanged: if (w.active) refreshDebounce.restart()
    Component.onCompleted: if (w.active) refreshDebounce.restart()
    Timer { id: refreshDebounce; interval: 300; onTriggered: if (w.active) w.refresh(false) }
    Timer { interval: w.refreshSec * 1000; repeat: true; running: w.active && w.url.length > 0
            onTriggered: if (w.active) w.refresh(false) }

    function fmtWhen(ev) {
        var d = ev.start, now = new Date()
        var sameDay = d.toDateString() === now.toDateString()
        var tomorrow = new Date(now)
        tomorrow.setDate(tomorrow.getDate() + 1)
        var isTom = d.toDateString() === tomorrow.toDateString()
        var day = sameDay ? "Today" : (isTom ? "Tomorrow" : Qt.formatDate(d, "ddd MMM d"))
        return ev.allDay ? day : day + " " + Qt.formatTime(d, "HH:mm")
    }

    // ── Tile: the agenda, as many events as the box and the user allow ───────
    // Every size used to render the same 12px rows with a fixed 26px bar, so a
    // 696x1637 box showed five 12px lines and a metre of nothing.
    ColumnLayout {
        anchors.fill: parent; anchors.margins: theme.spacingSm
        visible: !w.expanded; spacing: theme.spacingXs

        // The UNCONFIGURED state - this is what ships in the presets, so it has
        // to stay legible at every declared size, not just at 1x1.
        Text {
            visible: !w.url.length
            Layout.fillWidth: true; Layout.fillHeight: true
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
            text: "Add a calendar\n(ICS URL) in settings"
            color: theme.textTertiary
            font.pixelSize: Math.max(theme.fontMinimum,
                                     Math.min(w.width * 0.038, w.height * 0.045, 18))
        }

        ColumnLayout {
            visible: w.url.length > 0
            Layout.fillWidth: true; Layout.fillHeight: true
            Layout.maximumWidth: Number.POSITIVE_INFINITY
            spacing: theme.spacingXs

            RowLayout {
                Layout.fillWidth: true
                Text {
                    text: (w.tick, "Up next"); color: theme.textTertiary
                    font.pixelSize: Math.max(theme.fontMinimum,
                                             Math.min(w.rowH * 0.30, theme.fontLabel))
                }
                Item { Layout.fillWidth: true }
                Text {
                    visible: w.loading || w.errorText.length > 0 || w.stale
                    text: w.loading ? "Loading calendar..."
                        : (w.errorText.length ? w.errorText : "Calendar data is stale")
                    color: w.loading ? theme.textSecondary : theme.warning
                    font.pixelSize: Math.max(theme.fontMinimum,
                                             Math.min(w.rowH * 0.30, theme.fontLabel))
                    elide: Text.ElideRight
                    Layout.maximumWidth: Math.max(80, w.width * 0.58)
                }
            }

            GridLayout {
                Layout.fillWidth: true; Layout.fillHeight: true
                // A wide box flows the SAME rows into columns instead of stretching
                // a 12px title across 1692px.
                columns: w.eventCols
                rowSpacing: 4; columnSpacing: theme.spacingLg

                Repeater {
                    // The model is the COUNT: a refetch moves the bound values in
                    // long-lived delegates instead of rebuilding the list.
                    model: w.shownCount
                    delegate: RowLayout {
                        id: evRow
                        required property int index
                        readonly property var ev: w.shownEvents[evRow.index]
                        Layout.fillWidth: true
                        Layout.preferredHeight: Math.round(w.rowH)
                        Layout.alignment: Qt.AlignTop
                        spacing: theme.spacingSm
                        Rectangle {
                            Layout.preferredWidth: 3
                            Layout.preferredHeight: Math.round(w.rowH * 0.62)
                            radius: 2; color: w.effAccent
                        }
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: 0
                            Text { text: evRow.ev ? (evRow.ev.title || "(busy)") : ""
                                color: theme.textPrimary
                                font.pixelSize: Math.max(theme.fontMinimum,
                                                         Math.min(w.rowH * 0.34, theme.fontTitle))
                                elide: Text.ElideRight; Layout.fillWidth: true }
                            Text { text: evRow.ev ? w.fmtWhen(evRow.ev) : ""
                                color: theme.textSecondary
                                font.pixelSize: Math.max(theme.fontMinimum,
                                                         Math.min(w.rowH * 0.28, theme.fontLabel))
                                elide: Text.ElideRight; Layout.fillWidth: true }
                        }
                    }
                }
            }
            ColumnLayout {
                visible: w.events.length === 0
                Layout.fillWidth: true; Layout.fillHeight: true
                spacing: theme.spacingXs
                Text {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: w.errorText || (w.loading ? "Loading calendar..." : "No upcoming events")
                    color: w.errorText.length ? theme.warning : theme.textSecondary
                    font.pixelSize: Math.max(theme.fontLabel,
                                             Math.min(w.width * 0.04, w.rowH * 0.4, 22))
                    wrapMode: Text.WordWrap
                }
                Text {
                    visible: !w.loading && (w.stateHelp.length > 0 || w.errorText.length > 0)
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: w.stateHelp
                    color: theme.textTertiary
                    font.pixelSize: Math.max(theme.fontMinimum, Math.min(w.rowH * 0.3, 17))
                    wrapMode: Text.WordWrap
                }
            }
            Item { Layout.fillHeight: true }
        }
    }

    // Expanded uses the same agenda and a single refresh action. Subscription
    // editing belongs to the adjacent shared WidgetConfigPanel.
    ColumnLayout {
        anchors.fill: parent; visible: w.expanded; spacing: theme.spacingMd

        RowLayout {
            Layout.fillWidth: true; spacing: theme.spacingSm
            ColumnLayout {
                Layout.fillWidth: true; spacing: 2
                Text {
                    Layout.fillWidth: true
                    text: w.url.length ? "Upcoming events" : "Calendar not connected"
                    color: theme.textPrimary; font.pixelSize: theme.fontTitle; font.bold: true
                }
                Text {
                    Layout.fillWidth: true
                    text: w.url.length
                        ? "Source: " + w.sourceHost()
                        : "Add the private ICS reference in the configuration panel."
                    color: theme.textSecondary; font.pixelSize: theme.fontLabel
                    elide: Text.ElideRight
                }
            }
            PillButton {
                label: w.loading ? "Refreshing..." : "Refresh now"
                primary: true; tint: w.effAccent
                enabled: w.url.length > 0 && !w.loading
                onClicked: w.refresh(true)
            }
        }

        ListView {
            Layout.fillWidth: true; Layout.fillHeight: true; clip: true; spacing: 6
            model: w.shownEvents
            delegate: RowLayout {
                required property var modelData
                width: ListView.view ? ListView.view.width : 0
                spacing: theme.spacingSm
                Rectangle { Layout.preferredWidth: 4; Layout.preferredHeight: 40; radius: 2; color: w.effAccent }
                ColumnLayout {
                    Layout.fillWidth: true; spacing: 0
                    Text { text: modelData.title || "(busy)"; color: theme.textPrimary; font.pixelSize: 20
                        font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
                    Text { text: w.fmtWhen(modelData) + (modelData.location ? "  ·  " + modelData.location : "")
                        color: theme.textSecondary; font.pixelSize: theme.fontLabel; elide: Text.ElideRight; Layout.fillWidth: true }
                }
            }
        }
        Text {
            visible: w.events.length === 0; Layout.alignment: Qt.AlignHCenter
            text: w.loading ? "Loading calendar..." : (w.errorText || (w.url.length ? "No upcoming events" : "Add an ICS reference in the configuration panel."))
            color: w.errorText.length ? theme.warning : theme.textTertiary; font.pixelSize: theme.fontTitle
        }
        Text {
            visible: !w.loading && w.stateHelp.length > 0
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            text: w.stateHelp
            color: theme.textSecondary; font.pixelSize: theme.fontLabel
            wrapMode: Text.WordWrap
        }
        Text {
            visible: w.url.length > 0
            Layout.fillWidth: true
            text: w.freshnessText() + " · Requests " + w.sourceHost() + " every 15m"
                  + (w.parseWarnings.length ? " · " + w.parseWarnings.join("; ") : "")
            color: w.errorText.length || w.stale || w.parseWarnings.length
                   ? theme.warning : theme.textTertiary
            font.pixelSize: theme.fontMinimum; wrapMode: Text.WordWrap
        }
    }
}
