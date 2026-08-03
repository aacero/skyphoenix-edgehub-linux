// ─────────────────────────────────────────────────────────────────────────
// fixtures.js - network payloads + a FakeXHR for the QML network tests
// (tst_weather_net.qml, tst_calendar_net.qml).
//
// The widgets fetch over XMLHttpRequest; these tests never touch a real socket.
// The widgets expose an `xhrFactory` seam (property var xhrFactory: null) -
// production uses the real `new XMLHttpRequest()`, tests inject makeFakeXHR().
// The FakeXHR captures the request (method/url/sent/aborted) and resolves ONLY
// on an explicit test call (resolveWith / fireTimeout) - no wall-clock waits.
// ─────────────────────────────────────────────────────────────────────────

// ── Open-Meteo forecast payloads (weather) ───────────────────────────────
// Must carry EVERY field WeatherWidget.refresh() asks the provider for
// (WeatherWidget.qml:287-288), not just the ones the headline needs. It used to
// omit relative_humidity_2m, wind_speed_10m, precipitation and daily
// sunrise/sunset - five of the requested fields - which left the parse at
// WeatherWidget.qml:246-250 running against `undefined` in every test: humidity,
// wind and rain stayed NaN, the whole condition-summary row rendered "-", and
// windSym/precipitationSym never appeared, so a unit setting could reach the
// provider URL and never reach the screen (audit 2026-08-03).
//
// Five daily rows → default forecastDays 4 (+1) request; days array of 5,
// forecast tiles = 4. Sunrise/sunset are Open-Meteo's "YYYY-MM-DDTHH:MM", which
// the widget slices at [11,16] to "HH:MM".
var FORECAST_VALID = JSON.stringify({
    current: {
        temperature_2m: 21.4, apparent_temperature: 19.8, weather_code: 3,
        relative_humidity_2m: 67, wind_speed_10m: 12.4, precipitation: 1.2,
        precipitation_probability: 80, wind_direction_10m: 315, uv_index: 6.4,
        cloud_cover: 42, surface_pressure: 1013.2
    },
    daily: {
        time: ["2026-07-13", "2026-07-14", "2026-07-15", "2026-07-16", "2026-07-17"],
        weather_code: [3, 61, 0, 80, 95],
        temperature_2m_max: [24.1, 22.6, 26.0, 20.2, 19.5],
        temperature_2m_min: [12.3, 11.1, 13.5, 10.0, 9.2],
        sunrise: ["2026-07-13T05:12", "2026-07-14T05:13", "2026-07-15T05:14",
                  "2026-07-16T05:15", "2026-07-17T05:16"],
        sunset: ["2026-07-13T21:34", "2026-07-14T21:33", "2026-07-15T21:32",
                 "2026-07-16T21:31", "2026-07-17T21:30"]
    }
});

// Failure shape: 200 OK but the daily.time array is missing → widget "No data".
var FORECAST_MISSING_DAILY = JSON.stringify({
    current: { temperature_2m: 21.4, apparent_temperature: 19.8, weather_code: 3 },
    daily: { weather_code: [3], temperature_2m_max: [24.1], temperature_2m_min: [12.3] }
});

// Failure shape: truncated / non-JSON body → widget "Parse error".
var MALFORMED_JSON = '{"current": {"temperature_2m": 21.4, ';

// ── Open-Meteo geocoding payloads (weather + config dialog) ───────────────
var GEOCODE_VALID = JSON.stringify({
    results: [{
        name: "Tokyo", latitude: 35.6895, longitude: 139.6917,
        admin1: "Tokyo", country_code: "JP"
    }]
});
// Failure shape: 200 OK but no matches → widget "City not found".
var GEOCODE_EMPTY = JSON.stringify({ results: [] });

// ── ICS payloads (calendar) ──────────────────────────────────────────────
// A valid VEVENT set must have DTSTARTs inside the widget's 30-day horizon, so
// it is built relative to `now` at call time (a fixed date would be pruned).
function pad(n) { return (n < 10 ? "0" : "") + n; }
function icsStamp(d) {
    return d.getFullYear() + pad(d.getMonth() + 1) + pad(d.getDate())
         + "T" + pad(d.getHours()) + pad(d.getMinutes()) + pad(d.getSeconds());
}
// Three upcoming timed VEVENTs (+2/+3/+5 days at 09:00 local) + one DAILY
// recurrence - a realistic "valid VEVENT set".
function icsValid() {
    var mk = function (days) {
        var d = new Date(); d.setDate(d.getDate() + days); d.setHours(9, 0, 0, 0); return d;
    };
    return "BEGIN:VCALENDAR\n"
        + "BEGIN:VEVENT\nSUMMARY:Standup\nLOCATION:Room 1\n"
        + "DTSTART;VALUE=DATE-TIME:" + icsStamp(mk(2)) + "\nEND:VEVENT\n"
        + "BEGIN:VEVENT\nSUMMARY:Review\n"
        + "DTSTART;VALUE=DATE-TIME:" + icsStamp(mk(3)) + "\nEND:VEVENT\n"
        + "BEGIN:VEVENT\nSUMMARY:Planning\n"
        + "DTSTART;VALUE=DATE-TIME:" + icsStamp(mk(5)) + "\nEND:VEVENT\n"
        + "END:VCALENDAR\n";
}
// Failure shape: well-formed calendar with no VEVENT → widget "No upcoming events".
var ICS_EMPTY = "BEGIN:VCALENDAR\nX-WR-CALNAME:Empty\nEND:VCALENDAR\n";

// ── FakeXHR ───────────────────────────────────────────────────────────────
// Implements the XMLHttpRequest surface the widgets use: open(method,url),
// send(), abort(), timeout, ontimeout, onreadystatechange, readyState, status,
// responseText. It does NOT resolve on its own - the test drives it:
//   resolveWith(status, body) → readyState=DONE(4), fire onreadystatechange
//   fireTimeout()             → fire ontimeout
// and records the captured request for URL assertions.
function makeFakeXHR() {
    return {
        method: "", url: "", sent: false, aborted: false,
        readyState: 0, status: 0, responseText: "",
        timeout: 0, ontimeout: null, onreadystatechange: null,
        // NetHub guards every header write with `xhr.setRequestHeader` before
        // calling it. Without this method the fake did not fail those writes -
        // it made the guard false, so the response-cap header and any auth
        // header were silently skipped for every suite using this fixture
        // (calendar, weather, nownext, moon, the cal+weather GUI test). A
        // regression dropping headers would have passed all of them.
        headers: {},
        setRequestHeader: function (k, v) { this.headers[k] = v; },
        open: function (m, u) { this.method = m; this.url = u; this.readyState = 1; },
        send: function () { this.sent = true; },
        abort: function () { this.aborted = true; },
        // ── test drivers ──
        resolveWith: function (status, body) {
            this.status = status;
            this.responseText = body;   // may be non-string to exercise a parse-catch
            this.readyState = 4;        // === XMLHttpRequest.DONE
            if (this.onreadystatechange) this.onreadystatechange();
        },
        fireTimeout: function () { if (this.ontimeout) this.ontimeout(); }
    };
}
