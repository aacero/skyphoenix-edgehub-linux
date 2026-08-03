import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Weather - real forecast from Open-Meteo (free, no API key). Location comes
// from the instance settings (lat/lon/place). Degrades gracefully offline.
//
// Both requests (forecast + city geocode) go through NetHub, never a raw XHR, so
// the global offline switch, the host allowlist and the attestation counters
// cover them. Readings use NetHub's volatile shared-provider cache, so tile,
// overlay, and passive clones can reuse one result without writing to config.
//
// Sizing (W1 wave 3): layout keys off the injected `sizeClass`. Every tile used
// to render the same glyph + temperature + place, so a 696x1228 box showed a
// 34px glyph over a 28px number and ~1000px of nothing.
//
// WHAT THE TILE CAN HONESTLY SHOW IS BOUNDED BY THE REQUEST, and the request is
// `&current=` + `&daily=` - never `hourly` (see refresh()). So there is no hourly
// series to chart, and a tall tile that drew one would be inventing data. Adding
// `&hourly=` would be new egress + a new feature: NetHub gates it and the
// no-egress attestation watches the default config. So the taller sizes grow the
// only way the payload allows - today's detail, then N DAILY rows:
//   • 0.5x0.5 (micro) - headerless: glyph + temperature + place.
//   • 1x1 (baseline)  - + "feels like", + the daily rows that fit.
//   • wide            - glyph/temp block beside the forecast as COLUMNS (the
//                       wide projections are 306-409px tall; rows would not fit).
//   • tall            - the daily forecast as a list, filling the height.
//   • full (overlay)  - unchanged (the city search is genuinely modal).
//
// `forecastDays` (the user's setting, capped at 7 by the schema) is how many days
// are FETCHED. The size decides how many of them are SHOWN: never more than the
// user asked for, never more than fits. Same rule as calendar's maxEvents.
WidgetChrome {
    id: w
    property var metrics: ({})
    property bool expanded: false
    property bool active: true
    property var store: null
    property string instanceId: ""
    property int tick: 0
    property double nowMsOverride: -1
    // The egress gate. Injected by Dashboard (one app-global instance); a local
    // fallback keeps the widget self-contained in tests / standalone use.
    property var netHub: null
    NetHub { id: _fallbackHub }
    function _hub() { return netHub ? netHub : _fallbackHub }
    // Test seam: a per-request XHR factory handed to the gate, so a FakeXHR can be
    // injected. null in production → the gate builds the real XHR.
    property var xhrFactory: null

    title: "Weather"; iconName: "weather"; accentColor: theme.catInfo
    showHeader: !micro

    // ── Per-size layout (sizeClass injected by Dashboard) ────────────────────
    readonly property bool horiz: sizeClass === "wide"
    readonly property bool tallish: sizeClass === "tall" || sizeClass === "large"
    // Anything past "glyph + temperature + place" needs more than a half-cell.
    readonly property bool rich: !micro
    // 1x1.5 in either orientation has enough area for the current-condition
    // details that otherwise live only in the expanded view.
    readonly property bool roomy: !expanded && width * height > 700000

    // The days we actually hold, minus today. `days` is only rebuilt by a fetch
    // (every 30 min), never by a tick.
    readonly property int futureDays: Math.max(0, w.days.length - 1)

    // "Now" scales with the box; the forecast takes what is left.
    readonly property real glyphPx: w.micro ? Math.min(w.width * 0.30, w.height * 0.26, 72)
        : w.horiz ? Math.min(w.width * 0.10, w.height * 0.26, 80)
        : Math.min(w.width * 0.18, w.height * 0.13, 88)
    readonly property real tempPx: Math.max(18, Math.round(w.glyphPx * 0.78))
    readonly property real subPx: Math.max(theme.fontLabel, Math.min(w.tempPx * 0.38, 21))
    // Width the "now" block claims when the forecast sits beside it.
    readonly property real nowW: Math.min(w.width * 0.32, 340)

    // How many daily entries FIT. The user's forecastDays is a MAXIMUM (what to
    // fetch); the box decides how many of those are rendered - never more than we
    // hold, never an overflowing card.
    readonly property real dayRowH: Math.max(34, Math.min(w.height * 0.055, 52))
    readonly property int dayRowsFit: {
        if (w.expanded || w.micro || w.horiz || !w.loaded) return 0
        // "Now" keeps a legible minimum and the refresh strip its touch row.
        var avail = w.height - w.headerHeight - 150 - 3 * theme.spacingSm - theme.touchTertiary
        return Math.max(0, Math.min(w.futureDays, Math.floor(avail / (w.dayRowH + 4))))
    }
    readonly property real dayColW: Math.max(72, Math.min(w.width * 0.11, 120))
    readonly property int dayColsFit: {
        if (w.expanded || w.micro || !w.horiz || !w.loaded) return 0
        var avail = w.width - w.nowW - theme.touchTertiary - 3 * theme.spacingSm
        return Math.max(0, Math.min(w.futureDays, Math.floor(avail / w.dayColW)))
    }
    readonly property int shownDays: w.horiz ? w.dayColsFit : w.dayRowsFit

    readonly property var cfg: {
        var _ = store ? store.revision : 0
        return (store && instanceId) ? JSON.parse(JSON.stringify(store.settingsFor(instanceId))) : ({})
    }
    property real lat: cfg.lat !== undefined ? Number(cfg.lat) : NaN
    property real lon: cfg.lon !== undefined ? Number(cfg.lon) : NaN
    readonly property string locationMode: cfg.locationMode || "search"
    // Only default to "Berlin" when no coordinates are configured either - a
    // custom location with a blanked place field must not be mislabelled Berlin;
    // fall back to the coordinates instead.
    property string place: cfg.place ? cfg.place
        : (isFinite(lat) && isFinite(lon) ? Number(lat).toFixed(2) + ", " + Number(lon).toFixed(2) : "")
    readonly property bool locationConfigured: isFinite(w.lat) && isFinite(w.lon)
                                               && w.lat >= -90 && w.lat <= 90
                                               && w.lon >= -180 && w.lon <= 180
    readonly property string units: cfg.units || "celsius"
    readonly property string windUnits: cfg.windUnits || "kmh"
    readonly property string precipitationUnits: cfg.precipitationUnits || "mm"
    readonly property int forecastDays: cfg.forecastDays !== undefined ? cfg.forecastDays : 4
    readonly property string degSym: units === "fahrenheit" ? "°F" : "°C"
    readonly property string windSym: windUnits === "mph" ? "mph"
        : (windUnits === "ms" ? "m/s" : "km/h")
    readonly property string precipitationSym: precipitationUnits === "inch" ? "in" : "mm"
    // 16-point compass. A bearing in degrees is data; "NW" is information.
    function compassPoint(deg) {
        if (!isFinite(deg)) return ""
        var pts = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                   "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        return pts[Math.round(((deg % 360) + 360) % 360 / 22.5) % 16]
    }
    readonly property string windText: isFinite(w.windSpeed)
        ? Math.round(w.windSpeed) + " " + w.windSym
          + (w.compassPoint(w.windDirection).length ? " " + w.compassPoint(w.windDirection) : "")
        : "-"
    readonly property string rainText: isFinite(w.precipChance)
        ? Math.round(w.precipChance) + "%"
        : (isFinite(w.precipitation) ? w.precipitation + " " + w.precipitationSym : "-")
    // WHO/WMO bands. A number alone does not tell you whether to care.
    function uvBand(v) {
        if (!isFinite(v)) return ""
        if (v < 3) return "Low"
        if (v < 6) return "Moderate"
        if (v < 8) return "High"
        if (v < 11) return "Very high"
        return "Extreme"
    }
    readonly property string uvText: isFinite(w.uvIndex)
        ? Math.round(w.uvIndex) + " " + w.uvBand(w.uvIndex) : "-"

    property bool loaded: false
    property string errorText: ""
    property string stateHelp: ""
    property bool sharedLoading: false
    property real curTemp: 0
    property real feels: 0
    property int curCode: 0
    property var days: []   // [{ day, code, min, max }]
    property real humidity: NaN
    property real windSpeed: NaN
    property real precipitation: NaN
    // "Do I need an umbrella" is a probability, not a millimetre reading: 0.2 mm
    // at 90% is a wet walk, 2 mm at 10% is a dry one. Open-Meteo returns it in
    // the same call, so it costs nothing to ask for.
    property real precipChance: NaN
    property real windDirection: NaN
    property real uvIndex: NaN
    property real cloudCover: NaN
    property real pressure: NaN
    property string sunrise: ""
    property string sunset: ""
    property double lastSuccessAt: 0
    property double recoveredAt: 0
    readonly property int refreshSec: 1800
    readonly property string sharedKind: "weather-open-meteo-v1"
    readonly property string sharedKey: w.lat + "," + w.lon + "," + w.units + ","
                                        + w.windUnits + "," + w.precipitationUnits + ","
                                        + w.forecastDays
    function currentMs() { return w.nowMsOverride >= 0 ? w.nowMsOverride : Date.now() }
    ProviderState {
        id: provider
        configured: w.locationConfigured
        loading: w._fxhr !== null || w.sharedLoading
        hasData: w.loaded
        errorText: w.errorText
        lastSuccessAt: w.lastSuccessAt
        nowMs: (w.tick, w.currentMs())
        staleAfterSec: w.refreshSec * 2
    }
    readonly property string providerState: provider.state
    readonly property int refreshAgeSec: provider.ageSec
    readonly property bool stale: provider.isStale
    readonly property bool recentlyRecovered: w.recoveredAt > 0
        && w.currentMs() >= w.recoveredAt && w.currentMs() - w.recoveredAt < 60000
    function freshnessText() { return provider.freshnessText }
    status: w.recentlyRecovered ? "Recovered" : provider.badgeLabel
    statusColor: provider.state === "loading" || provider.state === "unconfigured"
        ? w.effAccent : theme.warning
    Accessible.role: Accessible.Pane
    Accessible.name: {
        var location = w.place.length ? w.place : "Location not configured"
        if (w.errorText.length)
            return "Weather for " + location + ". " + w.errorText + ". " + w.stateHelp
        if (!w.loaded)
            return "Weather for " + location + ". " + provider.badgeLabel
        return "Weather for " + location + ". "
               + w.weatherDescription(w.curCode) + ", "
               + Math.round(w.curTemp) + w.degSym + ". Feels "
               + Math.round(w.feels) + w.degSym
    }

    function weatherKind(code) {
        if (code === 0) return "clear"
        if (code >= 1 && code <= 2) return "partly-cloudy"
        if (code === 3) return "cloudy"
        if (code === 45 || code === 48) return "fog"
        if ((code >= 51 && code <= 67) || (code >= 80 && code <= 82)) return "rain"
        if ((code >= 71 && code <= 77) || (code >= 85 && code <= 86)) return "snow"
        if (code >= 95) return "storm"
        return "unknown"
    }
    function weatherDescription(code) {
        var names = {
            "clear": "Clear sky", "partly-cloudy": "Partly cloudy",
            "cloudy": "Cloudy", "fog": "Fog", "rain": "Rain",
            "snow": "Snow", "storm": "Thunderstorm",
            "unknown": "Weather unavailable"
        }
        return names[w.weatherKind(code)]
    }

    // In-flight requests, tracked so a newer fetch aborts an older one (last-write
    // wins cleanly) and a hung socket resolves via a timeout instead of spinning.
    // The sequence tokens - not the XHR object - are the supersede guard: the gate
    // refuses offline/blocked requests synchronously and returns null, so there is
    // no XHR to compare a callback against in exactly the cases that must still report.
    property var _fxhr: null
    property int _fseq: 0
    property var _gxhr: null
    property int _gseq: 0
    function _syncShared() {
        if (!w.locationConfigured || !w._hub().sharedProvider) return false
        var entry = w._hub().sharedProvider(w.sharedKind, w.sharedKey)
        if (!entry) return false
        w.sharedLoading = !!entry.loading
        var keys = ["loaded", "errorText", "stateHelp", "curTemp", "feels", "curCode",
                    "days", "humidity", "windSpeed", "precipitation", "sunrise",
                    "sunset", "lastSuccessAt", "recoveredAt"]
        for (var i = 0; i < keys.length; i++)
            if (entry[keys[i]] !== undefined) w[keys[i]] = entry[keys[i]]
        return true
    }
    function _snapshot() {
        return {
            loaded: w.loaded, errorText: w.errorText, stateHelp: w.stateHelp,
            curTemp: w.curTemp, feels: w.feels, curCode: w.curCode,
            days: w.days, humidity: w.humidity, windSpeed: w.windSpeed,
            precipitation: w.precipitation, sunrise: w.sunrise, sunset: w.sunset,
            lastSuccessAt: w.lastSuccessAt, recoveredAt: w.recoveredAt
        }
    }
    Connections {
        target: w._hub() && w._hub().sharedRevision !== undefined ? w._hub() : null
        function onSharedRevisionChanged() { w._syncShared() }
    }
    Component.onDestruction: {
        if (_fxhr) _fxhr.abort()
        if (_gxhr) _gxhr.abort()
        if (w.locationConfigured && w._hub().releaseSharedProvider)
            w._hub().releaseSharedProvider(w.sharedKind, w.sharedKey, w, "")
    }

    // Map a forecast payload → the rendered reading.
    function _applyForecast(body) {
        try {
            var d = JSON.parse(body)
            if (!d || !d.current || !d.daily || !d.daily.time) {
                w.loaded = false
                w.errorText = "No data"
                w.stateHelp = "The provider response is missing current or daily conditions."
                return
            }
            var recovering = w.errorText.length > 0
            w.curTemp = d.current.temperature_2m
            w.feels = d.current.apparent_temperature
            w.curCode = d.current.weather_code
            w.humidity = Number(d.current.relative_humidity_2m)
            w.windSpeed = Number(d.current.wind_speed_10m)
            w.precipitation = Number(d.current.precipitation)
            w.precipChance = Number(d.current.precipitation_probability)
            w.windDirection = Number(d.current.wind_direction_10m)
            w.uvIndex = Number(d.current.uv_index)
            w.cloudCover = Number(d.current.cloud_cover)
            w.pressure = Number(d.current.surface_pressure)
            w.sunrise = d.daily.sunrise && d.daily.sunrise.length ? String(d.daily.sunrise[0]).slice(11, 16) : ""
            w.sunset = d.daily.sunset && d.daily.sunset.length ? String(d.daily.sunset[0]).slice(11, 16) : ""
            var out = []
            var names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            for (var i = 0; i < d.daily.time.length; i++) {
                // "YYYY-MM-DD" - parse as LOCAL midnight so getDay() names the
                // right weekday (new Date(str) would parse it as UTC and, west
                // of UTC, shift the label a day earlier).
                var p = ("" + d.daily.time[i]).split("-")
                var dt = new Date(+p[0], +p[1] - 1, +p[2])
                out.push({ day: i === 0 ? "Today" : names[dt.getDay()],
                           code: d.daily.weather_code[i],
                           max: Math.round(d.daily.temperature_2m_max[i]),
                           min: Math.round(d.daily.temperature_2m_min[i]) })
            }
            w.days = out
            w.loaded = true
            w.errorText = ""
            w.stateHelp = recovering ? "Connection restored. Forecast updated." : "Forecast is up to date."
            w.lastSuccessAt = w.currentMs()
            w.recoveredAt = recovering ? w.lastSuccessAt : 0
        } catch (e) {
            w.loaded = false
            w.errorText = "Parse error"
            w.stateHelp = "Retry later or check the configured location."
        }
    }

    function refresh(force) {
        var forceNow = force === undefined ? true : !!force
        if (!w.locationConfigured) {
            w.loaded = false
            w.errorText = "Set a location"
            w.stateHelp = "Search for a city or enter valid coordinates in settings."
            return
        }
        var fdays = Math.max(1, Math.min(16, w.forecastDays + 1))
        var url = "https://api.open-meteo.com/v1/forecast?latitude=" + w.lat + "&longitude=" + w.lon
                + "&current=temperature_2m,apparent_temperature,weather_code,relative_humidity_2m,wind_speed_10m,precipitation"
                + ",precipitation_probability,wind_direction_10m,uv_index,cloud_cover,surface_pressure"
                + "&daily=weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset"
                + (w.units === "fahrenheit" ? "&temperature_unit=fahrenheit" : "")
                + (w.windUnits !== "kmh" ? "&wind_speed_unit=" + w.windUnits : "")
                + (w.precipitationUnits === "inch" ? "&precipitation_unit=inch" : "")
                + "&timezone=auto&forecast_days=" + fdays
        if (w._fxhr) w._fxhr.abort()
        w._fxhr = null
        if (w._hub().claimSharedProvider
                && !w._hub().claimSharedProvider(w.sharedKind, w.sharedKey, w,
                                                  forceNow ? 0 : 3000)) {
            w._syncShared()
            return
        }
        w.sharedLoading = true
        var seq = ++w._fseq
        var xhr = w._hub().request({
            url: url,
            timeout: 8000,
            xhrFactory: w.xhrFactory,
            onDone: function (status, body) {
                if (seq !== w._fseq) return   // superseded by a newer request
                w._fxhr = null
                w.sharedLoading = false
                w._applyForecast(body)
                if (w._hub().publishSharedProvider)
                    w._hub().publishSharedProvider(w.sharedKind, w.sharedKey, w, w._snapshot())
            },
            onError: function (reason) {
                if (seq !== w._fseq) return
                w._fxhr = null
                w.sharedLoading = false
                // Keep a last known good forecast useful during a transient
                // refresh failure. ProviderState already communicates age and
                // staleness, so replacing valid readings with an error is a
                // worse failure mode than continuing to show them.
                w.errorText = reason === "timeout" ? "Timed out"
                    : reason === "blocked" ? "Blocked"
                    : reason === "offline" ? "Offline"
                    : reason === "response-too-large" ? "Response too large"
                    : "Unavailable"
                w.stateHelp = reason === "blocked"
                    ? "Allow api.open-meteo.com in network policy."
                    : reason === "offline"
                        ? "Turn off Offline mode, then refresh."
                    : "Check the network and configured location, then refresh."
                if (w._hub().publishSharedProvider)
                    w._hub().publishSharedProvider(w.sharedKind, w.sharedKey, w, w._snapshot())
            }
        })
        if (seq === w._fseq) w._fxhr = xhr
    }

    // Look up a city name → lat/lon via Open-Meteo's geocoding API, then persist.
    // The result IS persisted (lat/lon/place): it is a deliberate user choice, not
    // a poll reading, so it belongs in config.toml.
    property bool geocoding: false
    function geocode(name) {
        if (!name || !name.trim().length) return
        geocoding = true
        var url = "https://geocoding-api.open-meteo.com/v1/search?count=1&name=" + encodeURIComponent(name.trim())
        if (w._gxhr) w._gxhr.abort()
        w._gxhr = null
        var seq = ++w._gseq
        var xhr = w._hub().request({
            url: url,
            timeout: 8000,
            xhrFactory: w.xhrFactory,
            onDone: function (status, body) {
                if (seq !== w._gseq) return
                w._gxhr = null
                w.geocoding = false
                try {
                    var d = JSON.parse(body)
                    if (d && d.results && d.results.length) {
                        var r = d.results[0]
                        var region = r.admin1 ? ", " + r.admin1 : ""
                        var label = r.name + region + (r.country_code ? ", " + r.country_code : "")
                        if (w.store) w.store.patchSettings(w.instanceId, { "lat": r.latitude, "lon": r.longitude, "place": label })
                    } else {
                        w.errorText = "City not found"
                    }
                } catch (e) { w.errorText = "Lookup failed" }
            },
            onError: function (reason) {
                if (seq !== w._gseq) return
                w._gxhr = null
                w.geocoding = false
                w.errorText = reason === "offline" ? "Offline"
                    : reason === "blocked" ? "Blocked"
                    : reason === "timeout" ? "Lookup timed out" : "Lookup failed"
            }
        })
        if (seq === w._gseq) w._gxhr = xhr
    }

    // Debounce: lat and lon both "change" as settings load - coalesce to one fetch.
    property string locKey: w.sharedKey
    // Honor `active` (S3): don't fetch/repaint on the inactive (non-driver)
    // instance; refetch once when it becomes active again.
    onLocKeyChanged: {
        if (w._fxhr) w._fxhr.abort()
        w._fxhr = null
        w._fseq++
        w.sharedLoading = false
        w.loaded = false
        w.errorText = ""
        w.stateHelp = "Updating forecast for the new settings."
        w._syncShared()
        if (w.active) refreshDebounce.restart()
    }
    onActiveChanged: if (w.active) refreshDebounce.restart()
    // A units flip changes degSym synchronously, but curTemp still holds the old
    // reading in the previous unit - invalidate it so the tile never relabels a
    // Celsius number as "°F" until the refetch lands.
    Component.onCompleted: if (w.active) refreshDebounce.restart()
    Timer { id: refreshDebounce; interval: 350; onTriggered: if (w.active) w.refresh(false) }
    Timer { interval: w.refreshSec * 1000; repeat: true; running: w.active && w.locationConfigured
            onTriggered: if (w.active) w.refresh(false) }

    // ── Tile (every non-overlay size) ────────────────────────────────────────
    GridLayout {
        anchors.fill: parent
        visible: !w.expanded
        // Wide puts the forecast BESIDE "now" (3 columns: now · forecast ·
        // refresh); everything else stacks them (3 rows).
        columns: w.horiz ? 3 : 1
        rowSpacing: theme.spacingSm
        columnSpacing: theme.spacingMd

        // "Now": glyph + temperature, then feels/place. Identical everywhere -
        // only its scale changes.
        ColumnLayout {
            id: nowCell
            Layout.fillWidth: !w.horiz
            // Stacked: "now" absorbs the slack the capped forecast rows leave, so
            // it sits centred in its share rather than pinned to the top edge.
            Layout.fillHeight: !w.horiz
            Layout.preferredWidth: w.horiz ? Math.round(w.nowW) : -1
            // Alignment ONLY in the horizontal projection: setting it on the
            // stacked path would cancel fillWidth/fillHeight above (Qt Layouts:
            // alignment beats fill on that axis) and collapse the block.
            Layout.alignment: w.horiz ? Qt.AlignVCenter : 0
            Layout.maximumWidth: Number.POSITIVE_INFINITY
            spacing: 0

            Item { Layout.fillHeight: true; visible: !w.horiz }

            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: theme.spacingSm
                WeatherIcon {
                    Layout.preferredWidth: Math.max(28, w.glyphPx)
                    Layout.preferredHeight: Math.max(28, w.glyphPx)
                    code: w.loaded ? w.curCode : -1
                    primaryColor: w.effAccent
                    cloudColor: theme.textSecondary
                    detailColor: theme.catInfo
                }
                ColumnLayout {
                    spacing: 0
                    Text {
                        text: w.loaded ? Math.round(w.curTemp) + w.degSym
                              : (w.errorText.length ? "-" : "…")
                        font.pixelSize: w.tempPx; font.bold: true; color: theme.textPrimary
                    }
                    // "Feels like" is data the CURRENT reading already carries -
                    // it was locked in the overlay for no reason. The half-cell
                    // has no room for it.
                    Text {
                        visible: w.rich && w.loaded
                        text: "Feels " + Math.round(w.feels) + w.degSym
                        font.pixelSize: w.subPx; color: theme.textSecondary
                    }
                }
            }
            Item {
                Layout.fillWidth: true
                Layout.topMargin: 2
                Layout.preferredHeight: locationText.contentHeight
                Layout.minimumHeight: locationText.contentHeight
                Text {
                    id: locationText
                    objectName: "weatherLocation"
                    width: parent.width
                    height: contentHeight
                    horizontalAlignment: Text.AlignHCenter
                    text: !w.locationConfigured ? "Set location in settings"
                        : w.place
                    font.pixelSize: w.subPx
                    color: theme.textSecondary
                    wrapMode: Text.WordWrap
                }
            }
            Item {
                objectName: "weatherState"
                visible: w.errorText.length > 0 || w.stale || w.recentlyRecovered
                Layout.fillWidth: true
                Layout.preferredHeight: stateText.contentHeight
                Layout.minimumHeight: stateText.contentHeight
                Text {
                    id: stateText
                    objectName: "weatherStateText"
                    width: parent.width
                    height: contentHeight
                    horizontalAlignment: Text.AlignHCenter
                    text: w.errorText.length ? w.errorText
                        : (w.recentlyRecovered ? "Connection restored" : "Forecast is stale")
                    font.pixelSize: w.subPx
                    color: w.recentlyRecovered ? w.effAccent : theme.warning
                    wrapMode: Text.WordWrap
                }
            }

            Item { Layout.fillHeight: true; visible: !w.horiz }
        }

        // The forecast - the same delegates reflowed: a COLUMN per day when the
        // box is wide-and-short, a ROW per day when it is tall. Nothing is
        // recreated by a reflow, and the model is an int (the count), so a new
        // reading moves the bound VALUES rather than rebuilding delegates.
        GridLayout {
            id: forecastCell
            visible: w.shownDays > 0
            Layout.fillWidth: true
            Layout.fillHeight: !w.horiz
            Layout.alignment: w.horiz ? Qt.AlignVCenter : Qt.AlignTop
            Layout.maximumWidth: Number.POSITIVE_INFINITY
            columns: w.horiz ? w.shownDays : 1
            rowSpacing: 4
            columnSpacing: theme.spacingSm

            Repeater {
                model: w.shownDays
                delegate: GridLayout {
                    id: dayCell
                    required property int index
                    // days[0] is today - the forecast starts at 1.
                    readonly property var d: w.days[dayCell.index + 1]
                    columns: w.horiz ? 1 : 3
                    rowSpacing: 0
                    columnSpacing: theme.spacingSm
                    Layout.fillWidth: true
                    Layout.fillHeight: !w.horiz
                    // Rows share the height, but only up to a point: four days in
                    // an 819px box gave 125px rows with a 30px glyph adrift in the
                    // middle of each. Capped here, and every glyph/label below is
                    // sized from the row's ACTUAL height - so the row fills out
                    // instead of the row growing around fixed-size content.
                    Layout.maximumHeight: w.horiz ? 100000 : Math.max(44, w.dayRowH * 1.7)
                    // The scale each day entry is drawn at. Stacked: the row's own
                    // height. Wide: the column is bounded by its WIDTH but still
                    // has the box's height to spend - sizing off the width alone
                    // left 11px labels under a 19px glyph in a 409px-tall box.
                    readonly property real px: w.horiz
                        ? Math.min(w.dayColW * 0.75, w.height * 0.30)
                        : dayCell.height

                    Text {
                        text: dayCell.d ? dayCell.d.day : ""
                        font.pixelSize: Math.max(theme.fontLabel, Math.min(dayCell.px * 0.32, 21))
                        color: theme.textSecondary
                        horizontalAlignment: w.horiz ? Text.AlignHCenter : Text.AlignLeft
                        verticalAlignment: Text.AlignVCenter
                        elide: Text.ElideRight
                        Layout.preferredWidth: w.horiz ? -1 : Math.round(Math.min(w.width * 0.22, 96))
                        Layout.fillWidth: w.horiz
                        Layout.fillHeight: !w.horiz
                    }
                    WeatherIcon {
                        code: dayCell.d ? dayCell.d.code : -1
                        primaryColor: w.effAccent
                        cloudColor: theme.textSecondary
                        detailColor: theme.catInfo
                        Layout.preferredWidth: Math.max(28, Math.min(dayCell.px * 0.64, 48))
                        Layout.preferredHeight: Math.max(28, Math.min(dayCell.px * 0.64, 48))
                        Layout.alignment: Qt.AlignCenter
                        Layout.fillWidth: w.horiz
                    }
                    Text {
                        objectName: "weatherForecastRange"
                        text: !dayCell.d ? ""
                              : w.horiz ? "↑" + dayCell.d.max + w.degSym
                                          + "\n↓" + dayCell.d.min + w.degSym
                                        : dayCell.d.max + w.degSym
                                          + " / " + dayCell.d.min + w.degSym
                        font.pixelSize: Math.max(theme.fontLabel, Math.min(dayCell.px * 0.32, 21))
                        color: theme.textPrimary
                        horizontalAlignment: w.horiz ? Text.AlignHCenter : Text.AlignRight
                        verticalAlignment: Text.AlignVCenter
                        // Narrow daily columns use a conventional high/low
                        // stack. Each value remains at the active type floor
                        // instead of squeezing a slash-separated line below it.
                        fontSizeMode: w.horiz ? Text.FixedSize : Text.HorizontalFit
                        minimumPixelSize: theme.fontMinimum
                        elide: w.horiz ? Text.ElideNone : Text.ElideRight
                        Layout.fillWidth: !w.horiz
                        Layout.preferredWidth: w.horiz ? Math.round(w.dayColW) : -1
                        Layout.fillHeight: !w.horiz
                    }
                }
            }
        }

        // Refresh - a real touch target in its own cell, so it can never sit on
        // top of the forecast (it used to be a 36px circle anchored over the
        // bottom-right of a body that had no bottom content; now it does).
        Item {
            visible: !w.micro
            Layout.preferredHeight: theme.touchTertiary
            Layout.preferredWidth: w.horiz ? theme.touchTertiary : -1
            Layout.fillWidth: !w.horiz
            Layout.alignment: w.horiz ? Qt.AlignVCenter : Qt.AlignRight
            Rectangle {
                id: refreshCompact
                objectName: "weatherRefreshButton"
                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                width: theme.touchTertiary; height: theme.touchTertiary; radius: width / 2
                activeFocusOnTab: true
                Accessible.role: Accessible.Button
                Accessible.name: "Refresh weather"
                Accessible.onPressAction: w.refresh(true)
                color: Qt.rgba(w.effAccent.r, w.effAccent.g, w.effAccent.b,
                               refMA.pressed ? 0.32 : (refMA.containsMouse ? 0.22 : 0.14))
                AppIcon { anchors.centerIn: parent; name: "ui-refresh"; size: 24; color: w.effAccent }
                Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                            || event.key === Qt.Key_Space) {
                        w.refresh(true)
                        event.accepted = true
                    }
                }
                MouseArea {
                    id: refMA; anchors.fill: parent; hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor; onClicked: w.refresh(true)
                }
            }
        }

        RowLayout {
            objectName: "weatherConditionSummary"
            visible: w.roomy && w.loaded
            Layout.columnSpan: w.horiz ? 3 : 1
            Layout.fillWidth: true
            spacing: theme.spacingLg

            Repeater {
                model: [
                    { label: "RAIN", value: w.rainText },
                    { label: "WIND", value: w.windText },
                    { label: "HUMIDITY", value: isFinite(w.humidity) ? Math.round(w.humidity) + "%" : "-" }
                ]
                delegate: ColumnLayout {
                    required property var modelData
                    Layout.fillWidth: true; spacing: 0
                    Text {
                        Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter
                        text: modelData.label; color: theme.textTertiary
                        font.pixelSize: theme.fontLabel; font.letterSpacing: 1
                    }
                    Text {
                        Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter
                        text: modelData.value; color: theme.textSecondary
                        font.pixelSize: theme.fontLabel; font.family: theme.fontMono
                    }
                }
            }
        }
    }

    // ── Expanded (the overlay) ───────────────────────────────────────────────
    ColumnLayout {
        anchors.fill: parent
        visible: w.expanded
        spacing: w.expanded ? 12 : 4

        RowLayout {
            Layout.alignment: Qt.AlignHCenter; spacing: theme.spacingMd
            WeatherIcon {
                Layout.preferredWidth: 84; Layout.preferredHeight: 84
                code: w.loaded ? w.curCode : -1
                primaryColor: w.effAccent
                cloudColor: theme.textSecondary
                detailColor: theme.catInfo
            }
            ColumnLayout {
                spacing: 0
                Text { text: w.loaded ? Math.round(w.curTemp) + w.degSym : (w.errorText.length ? "-" : "…")
                    font.pixelSize: w.expanded ? 64 : 28; font.bold: true; color: theme.textPrimary }
                Text { visible: w.expanded && w.loaded; text: "Feels " + Math.round(w.feels) + w.degSym + "  ·  " + w.place
                    font.pixelSize: theme.fontLabel; color: theme.textSecondary }
            }
        }
        Text {
            Layout.alignment: Qt.AlignHCenter
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            // Compact: place (or the error). Expanded: surface the error reason too
            // (otherwise the big "-" gives no hint why there's no data).
            visible: !w.expanded || w.errorText.length > 0
            text: w.errorText.length ? w.errorText : w.place
            font.pixelSize: w.expanded && w.errorText.length ? theme.fontLabel : theme.fontMinimum
            color: w.errorText.length ? theme.warning : theme.textSecondary
            wrapMode: Text.WordWrap
            Layout.preferredHeight: contentHeight
            Layout.minimumHeight: contentHeight
        }
        RowLayout {
            Layout.alignment: Qt.AlignHCenter; visible: w.expanded && w.loaded; spacing: theme.spacingXl
            Repeater {
                model: w.days.slice(1)
                delegate: ColumnLayout {
                    required property var modelData; spacing: 2
                    Text { Layout.alignment: Qt.AlignHCenter; text: modelData.day; font.pixelSize: theme.fontLabel; color: theme.textSecondary }
                    WeatherIcon {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.preferredWidth: 36; Layout.preferredHeight: 36
                        code: modelData.code
                        primaryColor: w.effAccent
                        cloudColor: theme.textSecondary
                        detailColor: theme.catInfo
                    }
                    Text { Layout.alignment: Qt.AlignHCenter; text: modelData.max + w.degSym + " / " + modelData.min + w.degSym
                        font.pixelSize: theme.fontLabel; color: theme.textPrimary
                        // S12: shrink-to-fit the day's hi/lo so a wide 7-day °F row
                        // (e.g. "108°F / -12°F") never clips the panel.
                        fontSizeMode: Text.HorizontalFit; minimumPixelSize: theme.fontMinimum; elide: Text.ElideRight }
                }
            }
        }
        Text {
            visible: w.loaded
            Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter
            objectName: "weatherDetailLine"
            // Every clause is optional and omitted when its field is absent, so a
            // provider that drops one leaves a shorter line rather than "NaN".
            text: (isFinite(w.humidity) ? "Humidity " + Math.round(w.humidity) + "%" : "")
                  + (isFinite(w.windSpeed) ? " · Wind " + w.windText : "")
                  + (isFinite(w.precipChance) ? " · Rain " + Math.round(w.precipChance) + "%" : "")
                  + (isFinite(w.precipitation) ? " · " + w.precipitation + " " + w.precipitationSym : "")
                  + (isFinite(w.uvIndex) ? " · UV " + w.uvText : "")
                  + (isFinite(w.cloudCover) ? " · Cloud " + Math.round(w.cloudCover) + "%" : "")
                  + (isFinite(w.pressure) ? " · " + Math.round(w.pressure) + " hPa" : "")
                  + (w.sunrise.length ? " · Sunrise " + w.sunrise : "")
                  + (w.sunset.length ? " · Sunset " + w.sunset : "")
            color: theme.textSecondary; font.pixelSize: theme.fontLabel; elide: Text.ElideRight
        }
        Text {
            visible: w.locationConfigured
            Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter
            text: w.freshnessText() + " · Open-Meteo refreshes every 30m"
            color: w.errorText.length || w.stale ? theme.warning : theme.textTertiary
            font.pixelSize: theme.fontLabel
        }
        Text {
            visible: w.expanded && w.stateHelp.length > 0
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            text: w.stateHelp
            color: w.recentlyRecovered ? w.effAccent : theme.textSecondary
            font.pixelSize: theme.fontLabel
            wrapMode: Text.WordWrap
        }
        Item { Layout.fillHeight: true; visible: w.expanded }
        RowLayout {
            Layout.fillWidth: true; visible: w.expanded; spacing: theme.spacingSm
            TextField {
                id: cityField; Layout.fillWidth: true; Layout.preferredHeight: theme.touchSecondary
                placeholderText: "Search a city…"; placeholderTextColor: theme.textTertiary
                color: theme.textPrimary; font.pixelSize: theme.fontLabel
                background: Rectangle { radius: theme.radiusSm; color: theme.backgroundColor
                    border.color: cityField.activeFocus ? w.effAccent : theme.cardBorder; border.width: 1 }
                onAccepted: w.geocode(text)
            }
            PillButton { label: w.geocoding ? "…" : "Set location"; glyph: "📍"; primary: true; tint: w.effAccent
                onClicked: w.geocode(cityField.text) }
        }
    }

}
