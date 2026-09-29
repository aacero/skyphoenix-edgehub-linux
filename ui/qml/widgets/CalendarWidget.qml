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
    readonly property string configuredViewMode: cfg.viewMode || "auto"
    property string userViewMode: ""
    readonly property real aspect: width / Math.max(1, height)
    readonly property string autoViewMode: {
        if (aspect < 0.90) return "agenda"
        if (aspect <= 1.45) return "month"
        return "week"
    }
    readonly property string effectiveViewMode: {
        if (userViewMode !== "") return userViewMode
        if (configuredViewMode !== "auto") return configuredViewMode
        return autoViewMode
    }

    // ── Date navigation & Day drawer state ───────────────────────────────────
    property int displayYear: (new Date()).getFullYear()
    property int displayMonth: (new Date()).getMonth()
    property int weekOffset: 0
    property var selectedDate: null
    property bool dayDetailOpen: false

    function prevMonth() {
        if (w.displayMonth === 0) {
            w.displayMonth = 11
            w.displayYear--
        } else {
            w.displayMonth--
        }
    }
    function nextMonth() {
        if (w.displayMonth === 11) {
            w.displayMonth = 0
            w.displayYear++
        } else {
            w.displayMonth++
        }
    }
    function prevWeek() { w.weekOffset-- }
    function nextWeek() { w.weekOffset++ }
    function goToday() {
        var now = new Date()
        w.displayYear = now.getFullYear()
        w.displayMonth = now.getMonth()
        w.weekOffset = 0
    }
    function openDayDetail(date) {
        w.selectedDate = new Date(date)
        w.dayDetailOpen = true
    }
    function closeDayDetail() {
        w.dayDetailOpen = false
    }

    function eventsForDate(targetDate) {
        if (!w.events || !w.events.length || !targetDate) return []
        var y = targetDate.getFullYear(), m = targetDate.getMonth(), d = targetDate.getDate()
        var startOfDay = new Date(y, m, d, 0, 0, 0, 0).getTime()
        var endOfDay = new Date(y, m, d, 23, 59, 59, 999).getTime()
        var res = []
        for (var i = 0; i < w.events.length; i++) {
            var ev = w.events[i]
            if (!ev || !ev.start) continue
            var s = ev.start.getTime()
            var e = ev.end ? ev.end.getTime() : s
            var effEnd = (ev.allDay && e > s) ? (e - 1) : e
            if (s <= endOfDay && effEnd >= startOfDay) res.push(ev)
        }
        return res
    }

    readonly property var monthCells: {
        var _ = w.events
        var y = w.displayYear, mo = w.displayMonth
        var firstDay = new Date(y, mo, 1).getDay()
        var daysInMo = new Date(y, mo + 1, 0).getDate()
        var prevDays = new Date(y, mo, 0).getDate()
        var today = new Date()
        var todayY = today.getFullYear(), todayM = today.getMonth(), todayD = today.getDate()
        var list = []
        for (var i = 0; i < 42; i++) {
            var cellD, cellM = mo, cellY = y, inMonth = false
            if (i < firstDay) {
                cellD = prevDays - firstDay + 1 + i
                cellM = mo === 0 ? 11 : mo - 1
                cellY = mo === 0 ? y - 1 : y
            } else if (i < firstDay + daysInMo) {
                cellD = i - firstDay + 1
                inMonth = true
            } else {
                cellD = i - (firstDay + daysInMo) + 1
                cellM = mo === 11 ? 0 : mo + 1
                cellY = mo === 11 ? y + 1 : y
            }
            var dt = new Date(cellY, cellM, cellD, 12, 0, 0, 0)
            var isToday = (cellY === todayY && cellM === todayM && cellD === todayD)
            var evs = w.eventsForDate(dt)
            list.push({
                year: cellY, month: cellM, day: cellD,
                inMonth: inMonth,
                isToday: isToday,
                date: dt,
                events: evs,
                eventCount: evs.length
            })
        }
        return list
    }

    readonly property var weekDays: {
        var _ = w.events
        var today = new Date()
        var todayY = today.getFullYear(), todayM = today.getMonth(), todayD = today.getDate()
        var base = new Date(today.getFullYear(), today.getMonth(), today.getDate() + w.weekOffset * 7, 12, 0, 0, 0)
        var list = []
        for (var j = 0; j < 7; j++) {
            var d = new Date(base.getFullYear(), base.getMonth(), base.getDate() + j, 12, 0, 0, 0)
            var isToday = (d.getFullYear() === todayY && d.getMonth() === todayM && d.getDate() === todayD)
            var evs = w.eventsForDate(d)
            list.push({
                date: d,
                dayIndex: j,
                isToday: isToday,
                events: evs,
                eventCount: evs.length
            })
        }
        return list
    }

    // Interactive View Mode Switcher Chips in Header
    headerRightItem: [
        RowLayout {
            id: viewModeChips
            visible: !w.expanded && w.url.length > 0 && w.width >= 420
            spacing: 2
            Repeater {
                model: [
                    { id: "agenda", label: "List" },
                    { id: "month", label: "Month" },
                    { id: "week", label: "Week" }
                ]
                delegate: Rectangle {
                    id: chip
                    required property var modelData
                    readonly property bool active: w.effectiveViewMode === modelData.id
                    implicitWidth: Math.max(48, chipLabel.implicitWidth + 14)
                    implicitHeight: 28
                    radius: 14
                    color: chip.active ? Qt.rgba(w.effAccent.r, w.effAccent.g, w.effAccent.b, 0.22) : "transparent"
                    border.width: 1
                    border.color: chip.active ? w.effAccent : Qt.rgba(255, 255, 255, 0.15)
                    Text {
                        id: chipLabel
                        anchors.centerIn: parent
                        text: chip.modelData.label
                        font.family: theme.fontDisplay
                        font.pixelSize: theme.fontMinimum
                        font.weight: chip.active ? Font.DemiBold : Font.Normal
                        color: chip.active ? w.effAccent : theme.textSecondary
                    }
                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -4
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (w.userViewMode === chip.modelData.id) {
                                w.userViewMode = ""
                            } else {
                                w.userViewMode = chip.modelData.id
                            }
                        }
                    }
                    Accessible.role: Accessible.Button
                    Accessible.name: "View " + chip.modelData.label
                    Accessible.onPressAction: {
                        if (w.userViewMode === chip.modelData.id) {
                            w.userViewMode = ""
                        } else {
                            w.userViewMode = chip.modelData.id
                        }
                    }
                }
            }
        }
    ]

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
    readonly property real eventTitlePixelSize: Math.max(
        theme.fontMinimum, Math.min(rowH * 0.34, theme.fontTitle))
    readonly property real eventWhenPixelSize: Math.max(
        theme.fontMinimum, Math.min(rowH * 0.28, theme.fontLabel))
    // Narrow agenda columns spend a second line on the event title. The full
    // source title remains the Text value and the row's accessible name.
    readonly property bool wrapEventTitles: width < theme.fontTitle * 20
    readonly property int eventTitleLines: wrapEventTitles ? 2 : 1
    TextMetrics {
        id: eventTitleMetrics
        font.family: theme.fontDisplay
        font.pixelSize: w.eventTitlePixelSize
    }
    TextMetrics {
        id: eventWhenMetrics
        font.family: theme.fontDisplay
        font.pixelSize: w.eventWhenPixelSize
    }
    readonly property real eventRowH: Math.max(
        rowH,
        Math.ceil(eventTitleMetrics.height * eventTitleLines
                  + eventWhenMetrics.height))
    readonly property real eventRowSpacing: theme.spacingXs
    // Rows one column can hold without overflowing.
    readonly property int rowsPerCol: {
        var headerUse = agendaHeader.visible
            ? agendaHeader.implicitHeight + tileAgenda.spacing : 0
        var avail = Math.max(0, tileAgenda.height - headerUse)
        return Math.max(1, Math.floor(
            (avail + w.eventRowSpacing)
            / (w.eventRowH + w.eventRowSpacing)))
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
        var isDateOnly = (val.length <= 8) || (key && key.indexOf("VALUE=DATE") >= 0 && key.indexOf("VALUE=DATE-TIME") < 0)
        var y = +val.substr(0, 4), mo = +val.substr(4, 2) - 1, d = +val.substr(6, 2)
        if (val.length <= 8) {
            var dt = new Date(y, mo, d)
            dt.isDateOnly = true
            return dt
        }
        var h = +val.substr(9, 2), mi = +val.substr(11, 2), s = +val.substr(13, 2) || 0
        var res
        if (val.indexOf("Z") >= 0) {
            res = new Date(Date.UTC(y, mo, d, h, mi, s))
        } else {
            var tz = tzidOf(key)
            var off = tz ? tzOffsetMinutes(tz, y, mo, d) : null
            if (off !== null) res = new Date(Date.UTC(y, mo, d, h, mi, s) - off * 60000)
            else {
                if (tz) w.addParseWarning("Unsupported timezone: " + tz)
                res = new Date(y, mo, d, h, mi, s)
            }
        }
        if (isDateOnly && res) res.isDateOnly = true
        return res
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
    function exDateKey(d) {
        return d.getFullYear() + "-" + d.getMonth() + "-" + d.getDate()
    }

    function expand(ev, horizonEnd, now) {
        var out = []
        var todayStart = dayStart(now)
        // Duration of the event, used so an occurrence that STARTED before today
        // but hasn't finished yet (multi-day / in-progress) still counts.
        var dur = (ev.end && ev.start) ? (ev.end.getTime() - ev.start.getTime()) : 0
        var exclKeys = {}
        var exclDates = {}
        if (ev.exdates) {
            ev.exdates.forEach(function (d) {
                if (!d || isNaN(d.getTime())) return
                exclKeys[exKey(d)] = true
                if (d.isDateOnly || ev.allDay)
                    exclDates[exDateKey(d)] = true
            })
        }

        function isExcluded(occStart) {
            if (exclKeys[exKey(occStart)]) return true
            if (exclDates[exDateKey(occStart)]) return true
            if (ev.exdates) {
                var t = occStart.getTime()
                var dk = exDateKey(occStart)
                for (var i = 0; i < ev.exdates.length; i++) {
                    var ed = ev.exdates[i]
                    if (!ed || isNaN(ed.getTime())) continue
                    if (ed.isDateOnly && dk === exDateKey(ed)) return true
                    if (Math.abs(t - ed.getTime()) < 60000) return true
                }
            }
            return false
        }

        // Emit one occurrence (honours EXDATE exclusions + horizon/past bounds).
        function emit(occStart) {
            if (isExcluded(occStart)) return                          // cancelled (EXDATE / RECURRENCE-ID)
            if (ev.untilCutoff && occStart >= ev.untilCutoff) return  // RANGE=THISANDFUTURE cancelled
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
        if (parts.UNTIL && until && until.isDateOnly) {
            until = new Date(until.getFullYear(), until.getMonth(), until.getDate(), 23, 59, 59, 999)
        }
        if (until.getTime() + dur < todayStart.getTime()) return out

        var freq = parts.FREQ, n = 0

        // WEEKLY with BYDAY (e.g. MO,WE,FR): walk day-by-day across the horizon and
        // emit each listed weekday that falls on an active interval-week.
        if (freq === "WEEKLY" && parts.BYDAY) {
            var days = weekdayNums(parts.BYDAY)
            var startWeek = dayStart(ev.start); startWeek.setDate(startWeek.getDate() - startWeek.getDay())
            var cursor = dayStart(ev.start)
            if (parts.COUNT && cursor < todayStart) {
                // Pre-count past occurrences so a COUNT-bounded series from years ago
                // does not re-emit occurrences today.
                var scanWeek = new Date(startWeek)
                var scanLimit = new Date(todayStart)
                while (scanWeek <= scanLimit && n < count) {
                    var wIdx = Math.round((scanWeek.getTime() - startWeek.getTime()) / (7 * 86400000))
                    if (wIdx >= 0 && wIdx % interval === 0) {
                        for (var di = 0; di < days.length; di++) {
                            var occD = new Date(scanWeek)
                            occD.setDate(occD.getDate() + days[di])
                            occD.setHours(ev.start.getHours(), ev.start.getMinutes(), ev.start.getSeconds(), 0)
                            if (occD >= ev.start && occD < todayStart) {
                                n++
                                if (n >= count) break
                            }
                        }
                    }
                    scanWeek.setDate(scanWeek.getDate() + 7)
                }
                if (n >= count) return out
            }
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
        var rawEvents = [], cur = null
        var cancelledUids = {}
        var exclusionsByUid = {}
        var rangeUntilByUid = {}

        for (var i = 0; i < lines.length; i++) {
            var line = lines[i]
            if (line === "BEGIN:VEVENT") {
                cur = {}
            } else if (line === "END:VEVENT") {
                if (cur) {
                    var isCancelled = (cur.status === "CANCELLED" || cur.status === "CANCELED")
                    if (isCancelled) {
                        if (cur.recurrenceId && cur.uid) {
                            if (!exclusionsByUid[cur.uid]) exclusionsByUid[cur.uid] = []
                            exclusionsByUid[cur.uid].push(cur.recurrenceId)
                            if (cur.rangeThisAndFuture) {
                                rangeUntilByUid[cur.uid] = cur.recurrenceId
                            }
                        } else if (cur.uid) {
                            cancelledUids[cur.uid] = true
                        }
                    } else {
                        if (cur.recurrenceId && cur.uid) {
                            if (!exclusionsByUid[cur.uid]) exclusionsByUid[cur.uid] = []
                            exclusionsByUid[cur.uid].push(cur.recurrenceId)
                            if (cur.start) rawEvents.push(cur)
                        } else if (cur.start) {
                            rawEvents.push(cur)
                        }
                    }
                }
                cur = null
            } else if (cur) {
                var ci = line.indexOf(":")
                if (ci < 0) continue
                var key = line.substring(0, ci), val = line.substring(ci + 1)
                var name = key.split(";")[0]
                if (name === "SUMMARY") cur.title = val
                else if (name === "LOCATION") cur.location = val
                else if (name === "URL") cur.url = val
                else if (name === "RRULE") cur.rrule = val
                else if (name === "UID") cur.uid = val.trim()
                else if (name === "STATUS") cur.status = val.trim().toUpperCase()
                else if (name === "RECURRENCE-ID") {
                    cur.recurrenceId = parseDT(val, key)
                    if (cur.recurrenceId && ((val.trim().length <= 8) || (key.indexOf("VALUE=DATE") >= 0 && key.indexOf("VALUE=DATE-TIME") < 0)))
                        cur.recurrenceId.isDateOnly = true
                    if (key.indexOf("RANGE=THISANDFUTURE") >= 0)
                        cur.rangeThisAndFuture = true
                }
                else if (name === "DTSTART") {
                    cur.start = parseDT(val, key)
                    // VALUE=DATE marks an all-day event, but must NOT match the
                    // longer VALUE=DATE-TIME (which is a normal timed event).
                    cur.allDay = key.indexOf("VALUE=DATE") >= 0 && key.indexOf("VALUE=DATE-TIME") < 0
                    if (cur.allDay && cur.start) cur.start.isDateOnly = true
                }
                else if (name === "DTEND") cur.end = parseDT(val, key)
                else if (name === "EXDATE") {
                    cur.exdates = cur.exdates || []
                    val.split(",").forEach(function (v) {
                        var vt = v.trim()
                        if (vt.length) {
                            var exd = parseDT(vt, key)
                            if (exd) {
                                if ((vt.length <= 8) || (key.indexOf("VALUE=DATE") >= 0 && key.indexOf("VALUE=DATE-TIME") < 0))
                                    exd.isDateOnly = true
                                cur.exdates.push(exd)
                            }
                        }
                    })
                }
            }
        }
        var horizonDays = Math.max(30, (cfg.horizonDays !== undefined ? cfg.horizonDays : 90))
        var now = new Date(), horizon = new Date(now.getTime() + horizonDays * 86400000)
        var all = []
        for (var j = 0; j < rawEvents.length; j++) {
            var ev = rawEvents[j]
            if (ev.uid && cancelledUids[ev.uid]) continue
            if (ev.uid && exclusionsByUid[ev.uid]) {
                ev.exdates = (ev.exdates || []).concat(exclusionsByUid[ev.uid])
            }
            if (ev.uid && rangeUntilByUid[ev.uid]) {
                ev.untilCutoff = rangeUntilByUid[ev.uid]
            }
            all = all.concat(expand(ev, horizon, now))
        }
        all.sort(function (a, b) { return a.start - b.start })
        return all.slice(0, 100)
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
                    var hDays = Math.max(30, (w.cfg.horizonDays !== undefined ? w.cfg.horizonDays : 90))
                    w.stateHelp = w.events.length
                        ? "Calendar is up to date."
                        : ("The subscription connected successfully but has no events in the next " + hDays + " days.")
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
        id: tileAgenda
        objectName: "calendarTileAgenda"
        anchors.fill: parent; anchors.margins: theme.spacingSm
        visible: !w.expanded && (!w.url.length || (w.effectiveViewMode === "agenda" && (!w.dayDetailOpen || w.selectedDate === null)))
        spacing: theme.spacingXs

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
                id: agendaHeader
                objectName: "calendarAgendaHeader"
                visible: w.events.length > 0
                Layout.fillWidth: true
                Text {
                    text: (w.tick, "Up next"); color: theme.textTertiary
                    font.pixelSize: Math.max(theme.fontMinimum,
                                             Math.min(w.rowH * 0.30, theme.fontLabel))
                }
                Item { Layout.fillWidth: true }
                Text {
                    visible: w.events.length > 0
                             && (w.loading || w.errorText.length > 0 || w.stale)
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
                id: eventGrid
                objectName: "calendarEventGrid"
                visible: w.events.length > 0
                Layout.fillWidth: true
                // A wide box flows the SAME rows into columns instead of stretching
                // a 12px title across 1692px.
                columns: w.eventCols
                rowSpacing: w.eventRowSpacing; columnSpacing: theme.spacingLg

                Repeater {
                    // The model is the COUNT: a refetch moves the bound values in
                    // long-lived delegates instead of rebuilding the list.
                    model: w.shownCount
                    delegate: RowLayout {
                        id: evRow
                        objectName: "calendarEventRow"
                        required property int index
                        readonly property var ev: w.shownEvents[evRow.index]
                        readonly property string accessibleSummary: ev
                            ? (ev.title || "(busy)") + ", " + w.fmtWhen(ev)
                              + (ev.location ? ", " + ev.location : "")
                            : ""
                        Accessible.name: accessibleSummary
                        Layout.fillWidth: true
                        Layout.preferredHeight: Math.round(w.eventRowH)
                        Layout.alignment: Qt.AlignTop
                        spacing: theme.spacingSm
                        Rectangle {
                            Layout.preferredWidth: 3
                            Layout.preferredHeight: Math.round(w.eventRowH * 0.62)
                            radius: 2; color: w.effAccent
                        }
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: 0
                            Text {
                                objectName: "calendarEventTitle"
                                text: evRow.ev ? (evRow.ev.title || "(busy)") : ""
                                color: theme.textPrimary
                                font.pixelSize: w.eventTitlePixelSize
                                font.family: theme.fontDisplay
                                wrapMode: w.wrapEventTitles
                                          ? Text.WordWrap : Text.NoWrap
                                maximumLineCount: w.eventTitleLines
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                                Accessible.name: text
                            }
                            Text {
                                objectName: "calendarEventWhen"
                                text: evRow.ev ? w.fmtWhen(evRow.ev) : ""
                                color: theme.textSecondary
                                font.pixelSize: w.eventWhenPixelSize
                                font.family: theme.fontDisplay
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }
                        }
                    }
                }
            }

            Item {
                objectName: "calendarEmptyState"
                visible: w.events.length === 0
                Layout.fillWidth: true; Layout.fillHeight: true
                ColumnLayout {
                    anchors.centerIn: parent
                    width: Math.max(0, parent.width - 2 * theme.spacingSm)
                    spacing: theme.spacingXs
                    Text {
                        objectName: "calendarEmptyTitle"
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                        text: w.errorText
                              || (w.loading ? "Loading calendar..."
                                            : "No upcoming events")
                        color: w.errorText.length
                               ? theme.warning : theme.textSecondary
                        font.pixelSize: Math.max(
                            theme.fontLabel,
                            Math.min(w.width * 0.04, w.rowH * 0.4, 22))
                        font.family: theme.fontDisplay
                        wrapMode: Text.WordWrap
                        Accessible.name: text
                    }
                    Text {
                        objectName: "calendarEmptyHelp"
                        visible: !w.loading
                                 && (w.stateHelp.length > 0
                                     || w.errorText.length > 0)
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                        text: w.stateHelp
                        color: theme.textTertiary
                        font.pixelSize: Math.max(
                            theme.fontMinimum,
                            Math.min(w.rowH * 0.3, 17))
                        font.family: theme.fontDisplay
                        wrapMode: Text.WordWrap
                        Accessible.name: text
                    }
                }
            }
            Item {
                visible: w.events.length > 0
                Layout.fillHeight: true
            }
        }
    }

    // ── Tile: Month view (7-col grid, today highlight, event dots, clickable days)
    ColumnLayout {
        id: tileMonth
        objectName: "calendarTileMonth"
        anchors.fill: parent; anchors.margins: theme.spacingSm
        visible: !w.expanded && w.url.length > 0 && w.effectiveViewMode === "month" && (!w.dayDetailOpen || w.selectedDate === null)
        spacing: theme.spacingXs

        // Header: Prev Month, Title (e.g. October 2026), Today button, Next Month
        RowLayout {
            id: monthHeader
            objectName: "calendarMonthHeader"
            Layout.fillWidth: true
            Layout.preferredHeight: 38
            spacing: theme.spacingSm

            Rectangle {
                id: btnPrevMonth
                objectName: "calendarMonthPrev"
                Layout.preferredWidth: 44
                Layout.preferredHeight: 38
                radius: theme.radiusSm
                color: prevMa.pressed ? theme.cardFillSubtle : "transparent"
                AppIcon {
                    name: "ui-caret-left"
                    size: 18
                    color: theme.textSecondary
                    anchors.centerIn: parent
                }
                MouseArea {
                    id: prevMa
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: w.prevMonth()
                }
                Accessible.role: Accessible.Button
                Accessible.name: "Previous month"
                Accessible.onPressAction: w.prevMonth()
            }

            Text {
                id: monthTitle
                objectName: "calendarMonthTitle"
                text: Qt.formatDate(new Date(w.displayYear, w.displayMonth, 1), "MMMM yyyy")
                font.family: theme.fontDisplay
                font.pixelSize: Math.max(theme.fontLabel, Math.min(w.width * 0.045, theme.fontTitle))
                font.bold: true
                color: theme.textPrimary
                Layout.alignment: Qt.AlignVCenter
            }

            Rectangle {
                id: btnMonthToday
                objectName: "calendarMonthToday"
                readonly property bool notCurrentMonth: {
                    var now = new Date()
                    return w.displayYear !== now.getFullYear() || w.displayMonth !== now.getMonth()
                }
                visible: notCurrentMonth
                implicitWidth: todayLabel.implicitWidth + 14
                implicitHeight: 28
                radius: 14
                color: todayMa.pressed ? theme.cardFillSubtle : "transparent"
                border.width: 1
                border.color: w.effAccent
                Text {
                    id: todayLabel
                    anchors.centerIn: parent
                    text: "Today"
                    font.family: theme.fontDisplay
                    font.pixelSize: theme.fontMinimum
                    color: w.effAccent
                }
                MouseArea {
                    id: todayMa
                    anchors.fill: parent
                    anchors.margins: -4
                    cursorShape: Qt.PointingHandCursor
                    onClicked: w.goToday()
                }
                Accessible.role: Accessible.Button
                Accessible.name: "Go to today"
                Accessible.onPressAction: w.goToday()
            }

            Item { Layout.fillWidth: true }

            Rectangle {
                id: btnNextMonth
                objectName: "calendarMonthNext"
                Layout.preferredWidth: 44
                Layout.preferredHeight: 38
                radius: theme.radiusSm
                color: nextMa.pressed ? theme.cardFillSubtle : "transparent"
                AppIcon {
                    name: "ui-caret-right"
                    size: 18
                    color: theme.textSecondary
                    anchors.centerIn: parent
                }
                MouseArea {
                    id: nextMa
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: w.nextMonth()
                }
                Accessible.role: Accessible.Button
                Accessible.name: "Next month"
                Accessible.onPressAction: w.nextMonth()
            }
        }

        // Day of week labels
        RowLayout {
            Layout.fillWidth: true
            spacing: 2
            Repeater {
                model: ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
                delegate: Text {
                    required property string modelData
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: modelData
                    color: theme.textTertiary
                    font.family: theme.fontDisplay
                    font.pixelSize: theme.fontMinimum
                }
            }
        }

        // 42-day Month Grid
        GridLayout {
            id: monthGrid
            objectName: "calendarMonthGrid"
            Layout.fillWidth: true
            Layout.fillHeight: true
            columns: 7
            rows: 6
            rowSpacing: 2
            columnSpacing: 2

            Repeater {
                model: w.monthCells
                delegate: Rectangle {
                    id: dayCell
                    objectName: "calendarMonthDayCell"
                    required property var modelData
                    required property int index
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    radius: theme.radiusSm
                    color: dayMa.pressed
                        ? theme.cardFillSubtle
                        : (modelData.isToday
                            ? Qt.rgba(w.effAccent.r, w.effAccent.g, w.effAccent.b, 0.18)
                            : "transparent")
                    border.width: modelData.isToday ? 1 : 0
                    border.color: modelData.isToday ? w.effAccent : "transparent"

                    ColumnLayout {
                        anchors.centerIn: parent
                        spacing: 1
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: dayCell.modelData.day
                            font.family: theme.fontDisplay
                            font.pixelSize: Math.max(theme.fontMinimum, Math.min(dayCell.height * 0.40, 16))
                            font.bold: dayCell.modelData.isToday
                            color: dayCell.modelData.inMonth
                                ? (dayCell.modelData.isToday ? w.effAccent : theme.textPrimary)
                                : theme.textTertiary
                            opacity: dayCell.modelData.inMonth ? 1.0 : 0.45
                        }
                        Row {
                            Layout.alignment: Qt.AlignHCenter
                            spacing: 2
                            visible: dayCell.modelData.eventCount > 0
                            Repeater {
                                model: Math.min(3, dayCell.modelData.eventCount)
                                delegate: Rectangle {
                                    width: 4; height: 4; radius: 2
                                    color: dayCell.modelData.isToday ? w.effAccent : theme.accentReadable
                                }
                            }
                        }
                    }
                    MouseArea {
                        id: dayMa
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: w.openDayDetail(dayCell.modelData.date)
                    }
                    Accessible.role: Accessible.Button
                    Accessible.name: Qt.formatDate(dayCell.modelData.date, "dddd, MMMM d, yyyy")
                        + (dayCell.modelData.eventCount > 0
                            ? (", " + dayCell.modelData.eventCount + " events")
                            : ", no events")
                    Accessible.onPressAction: w.openDayDetail(dayCell.modelData.date)
                }
            }
        }
    }

    // ── Tile: Week view (7 day columns, event pills, clickable days) ─────────
    ColumnLayout {
        id: tileWeek
        objectName: "calendarTileWeek"
        anchors.fill: parent; anchors.margins: theme.spacingSm
        visible: !w.expanded && w.url.length > 0 && w.effectiveViewMode === "week" && (!w.dayDetailOpen || w.selectedDate === null)
        spacing: theme.spacingXs

        // Header: Prev Week, Date range, Today button, Next Week
        RowLayout {
            id: weekHeader
            objectName: "calendarWeekHeader"
            Layout.fillWidth: true
            Layout.preferredHeight: 38
            spacing: theme.spacingSm

            Rectangle {
                id: btnPrevWeek
                objectName: "calendarWeekPrev"
                Layout.preferredWidth: 44
                Layout.preferredHeight: 38
                radius: theme.radiusSm
                color: prevWkMa.pressed ? theme.cardFillSubtle : "transparent"
                AppIcon {
                    name: "ui-caret-left"
                    size: 18
                    color: theme.textSecondary
                    anchors.centerIn: parent
                }
                MouseArea {
                    id: prevWkMa
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: w.prevWeek()
                }
                Accessible.role: Accessible.Button
                Accessible.name: "Previous week"
                Accessible.onPressAction: w.prevWeek()
            }

            Text {
                id: weekTitle
                objectName: "calendarWeekTitle"
                readonly property string rangeText: {
                    if (!w.weekDays.length) return "Week"
                    var d1 = w.weekDays[0].date
                    var d2 = w.weekDays[6].date
                    return Qt.formatDate(d1, "MMM d") + " – " + Qt.formatDate(d2, "MMM d, yyyy")
                }
                text: rangeText
                font.family: theme.fontDisplay
                font.pixelSize: Math.max(theme.fontLabel, Math.min(w.width * 0.035, theme.fontTitle))
                font.bold: true
                color: theme.textPrimary
                Layout.alignment: Qt.AlignVCenter
            }

            Rectangle {
                id: btnWeekToday
                objectName: "calendarWeekToday"
                visible: w.weekOffset !== 0
                implicitWidth: todayWkLabel.implicitWidth + 14
                implicitHeight: 28
                radius: 14
                color: todayWkMa.pressed ? theme.cardFillSubtle : "transparent"
                border.width: 1
                border.color: w.effAccent
                Text {
                    id: todayWkLabel
                    anchors.centerIn: parent
                    text: "Today"
                    font.family: theme.fontDisplay
                    font.pixelSize: theme.fontMinimum
                    color: w.effAccent
                }
                MouseArea {
                    id: todayWkMa
                    anchors.fill: parent
                    anchors.margins: -4
                    cursorShape: Qt.PointingHandCursor
                    onClicked: w.goToday()
                }
                Accessible.role: Accessible.Button
                Accessible.name: "Go to this week"
                Accessible.onPressAction: w.goToday()
            }

            Item { Layout.fillWidth: true }

            Rectangle {
                id: btnNextWeek
                objectName: "calendarWeekNext"
                Layout.preferredWidth: 44
                Layout.preferredHeight: 38
                radius: theme.radiusSm
                color: nextWkMa.pressed ? theme.cardFillSubtle : "transparent"
                AppIcon {
                    name: "ui-caret-right"
                    size: 18
                    color: theme.textSecondary
                    anchors.centerIn: parent
                }
                MouseArea {
                    id: nextWkMa
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: w.nextWeek()
                }
                Accessible.role: Accessible.Button
                Accessible.name: "Next week"
                Accessible.onPressAction: w.nextWeek()
            }
        }

        // 7 Day Columns
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: theme.spacingSm

            Repeater {
                model: w.weekDays
                delegate: Rectangle {
                    id: weekCol
                    objectName: "calendarWeekCol"
                    required property var modelData
                    required property int index
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.preferredWidth: 1
                    radius: theme.radiusMd
                    color: weekColMa.pressed
                        ? theme.cardFillSubtle
                        : (modelData.isToday
                            ? Qt.rgba(w.effAccent.r, w.effAccent.g, w.effAccent.b, 0.12)
                            : Qt.rgba(255, 255, 255, 0.03))
                    border.width: modelData.isToday ? 1 : 0
                    border.color: modelData.isToday ? w.effAccent : "transparent"

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 4
                        spacing: 4

                        // Column header
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            Text {
                                text: weekCol.width < 65 ? Qt.formatDate(weekCol.modelData.date, "ddd") : (weekCol.modelData.isToday ? "Today" : Qt.formatDate(weekCol.modelData.date, "ddd"))
                                font.family: theme.fontDisplay
                                font.pixelSize: theme.fontMinimum
                                font.bold: weekCol.modelData.isToday
                                color: weekCol.modelData.isToday ? w.effAccent : theme.textSecondary
                            }
                            Item { Layout.fillWidth: true }
                            Text {
                                text: Qt.formatDate(weekCol.modelData.date, "d")
                                font.family: theme.fontDisplay
                                font.pixelSize: theme.fontMinimum
                                font.bold: weekCol.modelData.isToday
                                color: weekCol.modelData.isToday ? w.effAccent : theme.textPrimary
                            }
                        }

                        // Event pills list
                        ColumnLayout {
                            id: weekPillCol
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            spacing: 2
                            clip: true

                            readonly property int maxVisiblePills: Math.max(1, Math.floor((height - 2) / 28))

                            Repeater {
                                model: weekCol.modelData.events.slice(0, weekPillCol.maxVisiblePills)
                                delegate: Rectangle {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 24
                                    radius: 3
                                    color: Qt.rgba(w.effAccent.r, w.effAccent.g, w.effAccent.b, 0.16)
                                    border.width: 1
                                    border.color: Qt.rgba(w.effAccent.r, w.effAccent.g, w.effAccent.b, 0.28)
                                    RowLayout {
                                        anchors.fill: parent
                                        anchors.leftMargin: 3
                                        anchors.rightMargin: 3
                                        spacing: 3
                                        Rectangle {
                                            Layout.preferredWidth: 2; Layout.preferredHeight: 14; radius: 1
                                            color: w.effAccent
                                        }
                                        Text {
                                            text: modelData.title || "(busy)"
                                            font.family: theme.fontDisplay
                                            font.pixelSize: Math.max(theme.fontMinimum - 1, 9)
                                            color: theme.textPrimary
                                            elide: Text.ElideRight
                                            Layout.fillWidth: true
                                        }
                                    }
                                }
                            }

                            Text {
                                visible: weekCol.modelData.eventCount > weekPillCol.maxVisiblePills
                                text: "+" + (weekCol.modelData.eventCount - weekPillCol.maxVisiblePills) + " more"
                                font.family: theme.fontDisplay
                                font.pixelSize: Math.max(theme.fontMinimum - 1, 9)
                                color: w.effAccent
                                Layout.alignment: Qt.AlignHCenter
                            }

                            Item {
                                visible: weekCol.modelData.eventCount === 0
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                Text {
                                    anchors.centerIn: parent
                                    text: "—"
                                    color: theme.textTertiary
                                    font.pixelSize: theme.fontMinimum
                                }
                            }
                            Item { Layout.fillHeight: true }
                        }
                    }

                    MouseArea {
                        id: weekColMa
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: w.openDayDetail(weekCol.modelData.date)
                    }
                    Accessible.role: Accessible.Button
                    Accessible.name: Qt.formatDate(weekCol.modelData.date, "dddd, MMMM d")
                        + (weekCol.modelData.eventCount > 0
                            ? (", " + weekCol.modelData.eventCount + " events")
                            : ", no events")
                    Accessible.onPressAction: w.openDayDetail(weekCol.modelData.date)
                }
            }
        }
    }

    // ── Day detail expander (opened by clicking day tile in Month/Week view) ──
    Rectangle {
        id: dayDetailDrawer
        objectName: "calendarDayDetail"
        anchors.fill: parent
        anchors.margins: theme.spacingSm
        visible: !w.expanded && w.dayDetailOpen && w.selectedDate !== null
        z: 20
        radius: theme.radiusMd
        color: theme.cardFillColor
        border.width: 1
        border.color: w.effAccent

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: theme.spacingSm
            spacing: theme.spacingSm

            RowLayout {
                Layout.fillWidth: true
                spacing: theme.spacingSm

                Rectangle {
                    id: btnDayDetailClose
                    objectName: "calendarDayDetailClose"
                    Layout.preferredWidth: 44
                    Layout.preferredHeight: 44
                    radius: theme.radiusSm
                    color: closeMa.pressed ? theme.cardFillSubtle : Qt.rgba(255, 255, 255, 0.06)
                    border.width: 1
                    border.color: Qt.rgba(255, 255, 255, 0.12)
                    AppIcon {
                        name: "ui-caret-left"
                        size: 22
                        color: theme.textPrimary
                        anchors.centerIn: parent
                    }
                    MouseArea {
                        id: closeMa
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: w.closeDayDetail()
                    }
                    Accessible.role: Accessible.Button
                    Accessible.name: "Back to calendar"
                    Accessible.onPressAction: w.closeDayDetail()
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 1
                    Text {
                        objectName: "calendarDayDetailTitle"
                        text: w.selectedDate ? Qt.formatDate(w.selectedDate, "dddd, MMMM d") : ""
                        font.family: theme.fontDisplay
                        font.pixelSize: theme.fontTitle
                        font.bold: true
                        color: theme.textPrimary
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                    Text {
                        readonly property int evCount: w.selectedDate ? w.eventsForDate(w.selectedDate).length : 0
                        text: evCount === 0 ? "No events scheduled" : (evCount === 1 ? "1 event" : (evCount + " events"))
                        font.family: theme.fontDisplay
                        font.pixelSize: theme.fontLabel
                        color: theme.textSecondary
                    }
                }
            }

            ListView {
                id: dayEventsList
                objectName: "calendarDayDetailList"
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: theme.spacingXs
                model: w.selectedDate ? w.eventsForDate(w.selectedDate) : []
                delegate: RowLayout {
                    required property var modelData
                    width: dayEventsList.width
                    spacing: theme.spacingSm
                    Rectangle {
                        Layout.preferredWidth: 3
                        Layout.preferredHeight: 38
                        radius: 2
                        color: w.effAccent
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 1
                        Text {
                            text: modelData.title || "(busy)"
                            color: theme.textPrimary
                            font.family: theme.fontDisplay
                            font.pixelSize: theme.fontLabel
                            font.bold: true
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                        Text {
                            readonly property string whenStr: modelData.allDay
                                ? "All day"
                                : (Qt.formatTime(modelData.start, "HH:mm") + (modelData.end ? " – " + Qt.formatTime(modelData.end, "HH:mm") : ""))
                            text: whenStr + (modelData.location ? "  ·  " + modelData.location : "")
                            color: theme.textSecondary
                            font.family: theme.fontDisplay
                            font.pixelSize: theme.fontMinimum
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                    }
                }
            }

            Item {
                visible: (w.selectedDate ? w.eventsForDate(w.selectedDate).length : 0) === 0
                Layout.fillWidth: true
                Layout.fillHeight: true
                Text {
                    anchors.centerIn: parent
                    text: "No events scheduled for this day"
                    color: theme.textTertiary
                    font.family: theme.fontDisplay
                    font.pixelSize: theme.fontLabel
                }
            }
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
