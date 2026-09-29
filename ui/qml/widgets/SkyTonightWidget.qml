import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The Sky Tonight - Stargazing and astronomical observing conditions widget.
// Calculates local solar twilights, astronomical dusk/dawn dark-sky window,
// and moon phase & illumination deterministically on-device (Meeus/NOAA).
// Fetches tonight's hourly observing cloud cover (8 PM - 2 AM) from Open-Meteo.
// Fully functional offline for astronomical events, degrading cloud telemetry gracefully.
WidgetChrome {
    id: w
    property var metrics: ({})
    property bool expanded: false
    property bool active: true
    property var store: null
    property string instanceId: ""
    property int tick: 0
    property double nowMsOverride: -1

    // Egress gate
    property var netHub: null
    NetHub { id: _fallbackHub }
    function _hub() { return netHub ? netHub : _fallbackHub }
    property var xhrFactory: null

    title: w.customTitle.length ? w.customTitle : "The Sky Tonight"
    iconName: "moon-stars"
    accentColor: w.verdictAccent
    showHeader: !micro

    Accessible.name: title
    Accessible.description: w.locationConfigured
        ? (w.verdict + ". " + (w.bestWindow ? ("Clearest around " + w.bestWindow.label + " at " + w.bestWindow.cloud + "% cloud cover.") : ""))
        : "Set a location to view tonight's sky."

    // ── Configuration ─────────────────────────────────────────────────────────
    readonly property var cfg: {
        var _ = store ? store.revision : 0
        return (store && instanceId) ? JSON.parse(JSON.stringify(store.settingsFor(instanceId))) : ({})
    }

    readonly property string customTitle: String(cfg.title || "")
    readonly property bool showTwilights: cfg.showTwilights !== undefined ? Boolean(cfg.showTwilights) : true
    readonly property bool showClouds: cfg.showClouds !== undefined ? Boolean(cfg.showClouds) : true
    readonly property bool showHourlyBar: cfg.showHourlyBar !== undefined ? Boolean(cfg.showHourlyBar) : true
    readonly property bool showMoon: cfg.showMoon !== undefined ? Boolean(cfg.showMoon) : true
    readonly property bool showPlanets: cfg.showPlanets !== undefined ? Boolean(cfg.showPlanets) : true

    // Fallback location inherited from any configured Weather, Moon, or Sky widget in the store
    readonly property var _fallbackLocation: {
        if (!store || typeof store.allTiles !== "function") return null
        var tiles = store.allTiles()
        for (var i = 0; i < tiles.length; ++i) {
            var tile = tiles[i]
            if (tile.type === "weather" || tile.type === "moon" || tile.type === "skytonight") {
                if (tile.instanceId === w.instanceId) continue
                var s = store.settingsFor(tile.instanceId)
                if (s && s.lat !== undefined && s.lon !== undefined && (Number(s.lat) !== 0 || Number(s.lon) !== 0)) {
                    return { lat: Number(s.lat), lon: Number(s.lon), place: String(s.place || "") }
                }
            }
        }
        return null
    }

    readonly property real lat: (cfg.lat !== undefined && Number(cfg.lat) !== 0)
        ? Number(cfg.lat) : (_fallbackLocation ? _fallbackLocation.lat : 0)
    readonly property real lon: (cfg.lon !== undefined && Number(cfg.lon) !== 0)
        ? Number(cfg.lon) : (_fallbackLocation ? _fallbackLocation.lon : 0)
    readonly property string place: (cfg.place && String(cfg.place).length)
        ? String(cfg.place) : (_fallbackLocation ? _fallbackLocation.place : "")
    readonly property bool locationConfigured: (lat !== 0 || lon !== 0) || place.length > 0

    // ── Sizing properties ───────────────────────────────────────────────────
    readonly property bool micro: (sizeClass === "compact" && Math.min(width, height) < 480) || (width < 360 && height < 300)
    readonly property bool wideTile: width > 500 && height < 340
    readonly property bool tallTile: height > 400 && width < 460
    readonly property bool roomy: expanded || (width >= 500 && height >= 480 && width * height > 280000)
    readonly property bool twoColumn: !micro && width >= 720 && height >= 380

    // ── Current Reference Time ──────────────────────────────────────────────
    function currentDate() {
        return w.nowMsOverride > 0 ? new Date(w.nowMsOverride) : new Date()
    }

    // ── Local Astronomical Engine (NOAA / Meeus) ────────────────────────────
    function _solarAltitude(date, latitude, longitude) {
        var jd = date.getTime() / 86400000 + 2440587.5
        var n = jd - 2451545.0
        var L = (280.460 + 0.9856474 * n) % 360
        var g = ((357.528 + 0.9856003 * n) % 360) * Math.PI / 180
        var Lnorm = (L + 360) % 360
        var lambda = (Lnorm + 1.915 * Math.sin(g) + 0.020 * Math.sin(2 * g)) * Math.PI / 180
        var eps = (23.439 - 0.0000004 * n) * Math.PI / 180
        var alpha = Math.atan2(Math.cos(eps) * Math.sin(lambda), Math.cos(lambda))
        var delta = Math.asin(Math.sin(eps) * Math.sin(lambda))
        var gmst = (280.46061837 + 360.98564736629 * n) % 360
        var lmst = (gmst + longitude + 360) % 360
        var ha = (lmst * Math.PI / 180) - alpha
        var latR = latitude * Math.PI / 180
        var sinAlt = Math.sin(latR) * Math.sin(delta) + Math.cos(latR) * Math.cos(delta) * Math.cos(ha)
        return Math.asin(sinAlt) * 180 / Math.PI
    }

    function _interpTime(t1, t2, a1, a2, target) {
        var span = a2 - a1
        if (Math.abs(span) < 0.0001) return new Date((t1 + t2) / 2)
        var frac = Math.max(0, Math.min(1, (target - a1) / span))
        return new Date(t1 + (t2 - t1) * frac)
    }

    function calculateSunEvents(refDate, latitude, longitude) {
        if (latitude === 0 && longitude === 0) return null
        var noon = new Date(refDate.getFullYear(), refDate.getMonth(), refDate.getDate(), 12, 0, 0)
        if (refDate.getHours() < 6) {
            noon = new Date(noon.getTime() - 24 * 3600000)
        }
        var startMs = noon.getTime()
        var endMs = startMs + 24 * 3600000
        var stepMs = 5 * 60 * 1000

        var sunset = null, civilDusk = null, nauticalDusk = null, astroDusk = null
        var astroDawn = null, sunrise = null

        var prevAlt = _solarAltitude(noon, latitude, longitude)
        var prevMs = startMs

        for (var ms = startMs + stepMs; ms <= endMs; ms += stepMs) {
            var curDate = new Date(ms)
            var curAlt = _solarAltitude(curDate, latitude, longitude)

            if (prevAlt >= -0.833 && curAlt < -0.833 && !sunset)
                sunset = _interpTime(prevMs, ms, prevAlt, curAlt, -0.833)
            if (prevAlt >= -6.0 && curAlt < -6.0 && !civilDusk)
                civilDusk = _interpTime(prevMs, ms, prevAlt, curAlt, -6.0)
            if (prevAlt >= -12.0 && curAlt < -12.0 && !nauticalDusk)
                nauticalDusk = _interpTime(prevMs, ms, prevAlt, curAlt, -12.0)
            if (prevAlt >= -18.0 && curAlt < -18.0 && !astroDusk)
                astroDusk = _interpTime(prevMs, ms, prevAlt, curAlt, -18.0)

            if (prevAlt < -18.0 && curAlt >= -18.0 && !astroDawn)
                astroDawn = _interpTime(prevMs, ms, prevAlt, curAlt, -18.0)
            if (prevAlt < -0.833 && curAlt >= -0.833 && !sunrise)
                sunrise = _interpTime(prevMs, ms, prevAlt, curAlt, -0.833)

            prevAlt = curAlt
            prevMs = ms
        }

        return {
            sunset: sunset,
            civilDusk: civilDusk,
            nauticalDusk: nauticalDusk,
            astroDusk: astroDusk,
            astroDawn: astroDawn,
            sunrise: sunrise
        }
    }

    function calculateMoonInfo(date) {
        var jd = date.getTime() / 86400000 + 2440587.5
        var days = jd - 2451545.0
        var T = days / 36525
        var RAD = Math.PI / 180
        var DEG = 180 / Math.PI
        var Dm = (297.8501921 + 445267.1114034 * T) * RAD
        var M = (357.5291092 + 35999.0502909 * T) * RAD
        var Mp = (134.9633964 + 477198.8675055 * T) * RAD
        var i = 180 - Dm * DEG
              - 6.289 * Math.sin(Mp) + 2.100 * Math.sin(M)
              - 1.274 * Math.sin(2 * Dm - Mp) - 0.658 * Math.sin(2 * Dm)
              - 0.214 * Math.sin(2 * Mp) - 0.110 * Math.sin(Dm)
        i = ((i % 360) + 360) % 360
        var illum = Math.round((1 + Math.cos(i * RAD)) / 2 * 100)
        var phaseFrac = ((((Dm * DEG) % 360) + 360) % 360) / 360
        var age = phaseFrac * 29.530588853
        var names = [
          [1.84566, 'New Moon', '🌑'],
          [5.53699, 'Waxing Crescent', '🌒'],
          [9.22831, 'First Quarter', '🌓'],
          [12.91963, 'Waxing Gibbous', '🌔'],
          [16.61096, 'Full Moon', '🌕'],
          [20.30228, 'Waning Gibbous', '🌖'],
          [23.99361, 'Last Quarter', '🌗'],
          [27.68493, 'Waning Crescent', '🌘']
        ]
        var name = 'New Moon'
        var glyph = '🌑'
        for (var k = 0; k < names.length; k++) {
            if (age <= names[k][0]) {
                name = names[k][1]
                glyph = names[k][2]
                break
            }
        }
        return { illum: illum, age: age, name: name, glyph: glyph, cyclePos: phaseFrac }
    }

    function formatTime(d) {
        if (!d) return "—"
        return Qt.formatTime(d, "h:mm AP")
    }

    function formatHour(hr) {
        if (hr === 0) return "12 AM"
        if (hr < 12) return hr + " AM"
        if (hr === 12) return "12 PM"
        return (hr - 12) + " PM"
    }

    // ── Naked-Eye Planet Ephemeris Engine (NASA JPL / Meeus) ────────────────
    readonly property var _planetsData: ({
        mercury: { a: 0.38709927, a_dot: 0.00000037, e: 0.20563593, e_dot: 0.00001906, I: 7.00497902, I_dot: -0.00594749, L: 252.25032350, L_dot: 149472.67411175, w: 77.45779628, w_dot: 0.16047689, node: 48.33076593, node_dot: -0.12534081, symbol: "☿", name: "Mercury" },
        venus:   { a: 0.72333566, a_dot: 0.00000390, e: 0.00677672, e_dot: -0.00004107, I: 3.39467605, I_dot: -0.00078890, L: 181.97909950, L_dot: 58517.81538729, w: 131.60246718, w_dot: 0.00268329, node: 76.67984255, node_dot: -0.27769418, symbol: "♀", name: "Venus" },
        earth:   { a: 1.00000261, a_dot: 0.00000562, e: 0.01671123, e_dot: -0.00004392, I: -0.00001531, I_dot: -0.01294668, L: 100.46457166, L_dot: 35999.37244981, w: 102.93768193, w_dot: 0.32327364, node: 0.0, node_dot: 0.0 },
        mars:    { a: 1.52371034, a_dot: 0.00001847, e: 0.09339410, e_dot: 0.00007882, I: 1.84969142, I_dot: -0.00813131, L: -4.55343205, L_dot: 19140.30268499, w: -23.94362959, w_dot: 0.44441088, node: 49.55953891, node_dot: -0.29257343, symbol: "♂", name: "Mars" },
        jupiter: { a: 5.20288700, a_dot: -0.00011607, e: 0.04838624, e_dot: -0.00013253, I: 1.30439695, I_dot: -0.00183714, L: 34.39644051, L_dot: 3034.74612775, w: 14.72847983, w_dot: 0.21252668, node: 100.47390909, node_dot: 0.20469106, symbol: "♃", name: "Jupiter" },
        saturn:  { a: 9.53667594, a_dot: -0.00125060, e: 0.05386179, e_dot: -0.00050991, I: 2.48599187, I_dot: 0.00193609, L: 49.95424423, L_dot: 1222.49362201, w: 92.59887831, w_dot: -0.41897216, node: 113.66242448, node_dot: -0.28867794, symbol: "♄", name: "Saturn" }
    })

    function _getHeliocentric(p, T) {
        var d2r = Math.PI / 180
        var a = p.a + p.a_dot * T
        var e = p.e + p.e_dot * T
        var I = (p.I + p.I_dot * T) * d2r
        var L = ((p.L + p.L_dot * T) % 360 + 360) % 360
        var w = ((p.w + p.w_dot * T) % 360 + 360) % 360
        var node = ((p.node + p.node_dot * T) % 360 + 360) % 360 * d2r
        var omega = (w - (p.node + p.node_dot * T)) * d2r
        var M = ((L - w) % 360 + 360) % 360 * d2r

        var E = M + e * Math.sin(M)
        for (var k = 0; k < 5; k++) {
            var dE = (M - (E - e * Math.sin(E))) / (1 - e * Math.cos(E))
            E += dE
            if (Math.abs(dE) < 1e-6) break
        }

        var xp = a * (Math.cos(E) - e)
        var yp = a * Math.sqrt(1 - e * e) * Math.sin(E)

        var x = (Math.cos(omega) * Math.cos(node) - Math.sin(omega) * Math.sin(node) * Math.cos(I)) * xp +
                (-Math.sin(omega) * Math.cos(node) - Math.cos(omega) * Math.sin(node) * Math.cos(I)) * yp
        var y = (Math.cos(omega) * Math.sin(node) + Math.sin(omega) * Math.cos(node) * Math.cos(I)) * xp +
                (-Math.sin(omega) * Math.sin(node) + Math.cos(omega) * Math.cos(node) * Math.cos(I)) * yp
        var z = (Math.sin(omega) * Math.sin(I)) * xp + (Math.cos(omega) * Math.sin(I)) * yp
        return { x: x, y: y, z: z }
    }

    function _getPlanetEquatorial(planetKey, date) {
        var jd = date.getTime() / 86400000 + 2440587.5
        var T = (jd - 2451545.0) / 36525.0
        var d2r = Math.PI / 180
        var r2d = 180 / Math.PI
        var p = _getHeliocentric(_planetsData[planetKey], T)
        var e = _getHeliocentric(_planetsData.earth, T)
        var gx = p.x - e.x
        var gy = p.y - e.y
        var gz = p.z - e.z
        var eps = (23.4392911 - 0.0130042 * T) * d2r
        var eqX = gx
        var eqY = gy * Math.cos(eps) - gz * Math.sin(eps)
        var eqZ = gy * Math.sin(eps) + gz * Math.cos(eps)
        var ra = Math.atan2(eqY, eqX)
        var dec = Math.atan2(eqZ, Math.sqrt(eqX * eqX + eqY * eqY))
        return { ra: (ra * r2d + 360) % 360, dec: dec * r2d }
    }

    function calculatePlanetRiseSet(planetKey, refDate, latitude, longitude) {
        if (latitude === 0 && longitude === 0) return null
        var noon = new Date(refDate.getFullYear(), refDate.getMonth(), refDate.getDate(), 12, 0, 0)
        var eq = _getPlanetEquatorial(planetKey, noon)
        var d2r = Math.PI / 180
        var r2d = 180 / Math.PI

        var ut0 = new Date(Date.UTC(noon.getUTCFullYear(), noon.getUTCMonth(), noon.getUTCDate(), 0, 0, 0))
        var dUT0 = (ut0.getTime() / 86400000 + 2440587.5) - 2451545.0
        var theta0 = ((280.46061837 + 360.98564736629 * dUT0) % 360 + 360) % 360

        var latR = latitude * d2r
        var decR = eq.dec * d2r
        var h0 = -0.566 * d2r

        var cosH0 = (Math.sin(h0) - Math.sin(latR) * Math.sin(decR)) / (Math.cos(latR) * Math.cos(decR))
        if (cosH0 > 1) return { key: planetKey, name: _planetsData[planetKey].name, symbol: _planetsData[planetKey].symbol, rise: null, set: null, status: "Below horizon" }
        if (cosH0 < -1) return { key: planetKey, name: _planetsData[planetKey].name, symbol: _planetsData[planetKey].symbol, rise: null, set: null, status: "Circumpolar" }

        var H0 = Math.acos(cosH0) * r2d
        var m0 = ((eq.ra - longitude - theta0) % 360 + 360) % 360 / 360
        var m1 = (m0 - H0 / 360 + 1) % 1
        var m2 = (m0 + H0 / 360) % 1

        var riseDate = new Date(ut0.getTime() + m1 * 86400000)
        var setDate = new Date(ut0.getTime() + m2 * 86400000)

        var rH = riseDate.getHours()
        var sH = setDate.getHours()
        var stat = ""
        if (rH >= 17 && rH <= 22 && (sH >= 4 && sH <= 9)) {
            stat = "Up all night"
        } else if (sH >= 18 && sH <= 23) {
            stat = "Evening · sets " + formatTime(setDate)
        } else if (rH >= 1 && rH <= 6) {
            stat = "Morning · rises " + formatTime(riseDate)
        } else {
            stat = "Sets " + formatTime(setDate)
        }

        return {
            key: planetKey,
            name: _planetsData[planetKey].name,
            symbol: _planetsData[planetKey].symbol,
            rise: riseDate,
            set: setDate,
            status: stat
        }
    }

    function calculateAllPlanets(refDate, latitude, longitude) {
        if (!locationConfigured) return []
        var keys = ["mercury", "venus", "mars", "jupiter", "saturn"]
        var res = []
        for (var i = 0; i < keys.length; i++) {
            var p = calculatePlanetRiseSet(keys[i], refDate, latitude, longitude)
            if (p) res.push(p)
        }
        return res
    }

    // Dynamic astronomical state (recalculated on tick or date change)
    readonly property var sunEvents: locationConfigured ? calculateSunEvents(currentDate(), lat, lon) : null
    readonly property var moon: calculateMoonInfo(currentDate())
    readonly property var planets: locationConfigured ? calculateAllPlanets(currentDate(), lat, lon) : []

    readonly property bool isDarkSkyNow: {
        var cur = currentDate()
        if (!sunEvents || !sunEvents.astroDusk || !sunEvents.astroDawn) return false
        return cur >= sunEvents.astroDusk && cur < sunEvents.astroDawn
    }

    // ── Cloud Forecast State (Open-Meteo) ────────────────────────────────────
    property bool loading: false
    property bool cloudLoaded: false
    property string errorText: ""
    property var hourlyWindow: []
    property int avgCloud: 0
    property var bestWindow: null
    property double lastSuccessMs: 0
    property string lastSuccessStr: ""
    property string observingDateLabel: ""
    property var _fxhr: null
    property int _fseq: 0

    readonly property string verdict: {
        if (!locationConfigured) return "Location required"
        if (!cloudLoaded) return errorText.length ? errorText : "Forecasting tonight…"
        if (avgCloud <= 25) return "Clear — great for observing"
        if (avgCloud <= 55) return "Partly cloudy — gaps to peek through"
        if (avgCloud <= 80) return "Mostly cloudy — limited windows"
        return "Overcast — skywatching unlikely"
    }

    readonly property string verdictShort: {
        if (!locationConfigured) return "No location"
        if (!cloudLoaded) return errorText.length ? "Offline" : "Loading…"
        if (avgCloud <= 25) return "Clear"
        if (avgCloud <= 55) return "Partly Cloudy"
        if (avgCloud <= 80) return "Mostly Cloudy"
        return "Overcast"
    }

    readonly property string verdictEmoji: {
        if (!locationConfigured) return "🔭"
        if (!cloudLoaded) return "🔭"
        if (avgCloud <= 25) return "🌟"
        if (avgCloud <= 55) return "⛅"
        if (avgCloud <= 80) return "🌥️"
        return "☁️"
    }

    readonly property color verdictAccent: {
        if (!cloudLoaded) return theme.catInfo
        if (avgCloud <= 25) return "#F5A623"
        if (avgCloud <= 55) return theme.catInfo
        if (avgCloud <= 80) return theme.textSecondary
        return "#8B949E"
    }

    function _applyCloudData(body) {
        try {
            var j = JSON.parse(body)
            if (!j || !j.hourly || !j.hourly.time || !j.hourly.cloud_cover) {
                w.errorText = "Invalid data"
                return
            }
            var t = j.hourly.time, c = j.hourly.cloud_cover
            if (!t || !c || !t.length) {
                w.errorText = "Invalid data"
                return
            }

            // Reference evening date based on currentDate()
            var ref = currentDate()
            var eveDate = new Date(ref.getFullYear(), ref.getMonth(), ref.getDate(), 12, 0, 0)
            if (ref.getHours() < 6) {
                eveDate = new Date(eveDate.getTime() - 24 * 3600000)
            }
            var mornDate = new Date(eveDate.getTime() + 24 * 3600000)

            function _p2(num) { return (num < 10 ? "0" : "") + num }
            var targetEve = eveDate.getFullYear() + "-" + _p2(eveDate.getMonth() + 1) + "-" + _p2(eveDate.getDate())
            var targetMorn = mornDate.getFullYear() + "-" + _p2(mornDate.getMonth() + 1) + "-" + _p2(mornDate.getDate())

            var win = []
            for (var k = 0; k < t.length; k++) {
                var itemDate = t[k].slice(0, 10)
                var hr = parseInt(t[k].slice(11, 13), 10)
                if ((itemDate === targetEve && hr >= 20) || (itemDate === targetMorn && hr <= 2)) {
                    win.push({
                        hr: hr,
                        cloud: c[k],
                        label: formatHour(hr)
                    })
                }
            }

            var resolvedEveStr = targetEve
            if (!win.length) {
                var today = t[0].slice(0, 10)
                var tomorrow = ""
                for (var i = 0; i < t.length; i++) {
                    if (t[i].slice(0, 10) !== today) { tomorrow = t[i].slice(0, 10); break }
                }
                resolvedEveStr = today
                for (var k2 = 0; k2 < t.length; k2++) {
                    var d2 = t[k2].slice(0, 10)
                    var hr2 = parseInt(t[k2].slice(11, 13), 10)
                    if ((d2 === today && hr2 >= 20) || (d2 === tomorrow && hr2 <= 2)) {
                        win.push({
                            hr: hr2,
                            cloud: c[k2],
                            label: formatHour(hr2)
                        })
                    }
                }
            }

            if (!win.length) {
                w.errorText = "No evening data"
                return
            }
            w.hourlyWindow = win
            var sum = 0
            var best = win[0]
            for (var m = 0; m < win.length; m++) {
                sum += win[m].cloud
                if (win[m].cloud < best.cloud) best = win[m]
            }
            w.avgCloud = Math.round(sum / win.length)
            w.bestWindow = best
            w.cloudLoaded = true
            w.errorText = ""
            w.lastSuccessMs = Date.now()
            w.lastSuccessStr = Qt.formatTime(new Date(), "h:mm AP")

            var todayRef = ref.getFullYear() + "-" + _p2(ref.getMonth() + 1) + "-" + _p2(ref.getDate())
            if (resolvedEveStr === todayRef) {
                w.observingDateLabel = "Tonight (" + Qt.formatDate(eveDate, "ddd MMM d") + ")"
            } else if (ref.getHours() < 6) {
                w.observingDateLabel = "Tonight (" + Qt.formatDate(eveDate, "ddd MMM d") + ")"
            } else {
                w.observingDateLabel = Qt.formatDate(eveDate, "ddd MMM d")
            }
        } catch (e) {
            w.errorText = "Parse error"
        }
    }

    function refresh() {
        if (!w.locationConfigured) {
            w.errorText = "Set location"
            w.cloudLoaded = false
            return
        }
        var url = "https://api.open-meteo.com/v1/forecast?latitude=" + w.lat + "&longitude=" + w.lon
                + "&hourly=cloud_cover&timezone=auto&forecast_days=2&past_days=1"
        if (w._fxhr) { try { w._fxhr.abort() } catch (e) {} }
        w._fxhr = null
        w.loading = true
        var seq = ++w._fseq
        var xhr = w._hub().request({
            url: url,
            timeout: 8000,
            xhrFactory: w.xhrFactory,
            onDone: function(status, body) {
                if (seq !== w._fseq) return
                w._fxhr = null
                w.loading = false
                w._applyCloudData(body)
            },
            onError: function(reason) {
                if (seq !== w._fseq) return
                w._fxhr = null
                w.loading = false
                w.errorText = reason === "timeout" ? "Timed out"
                    : reason === "offline" ? "Offline"
                    : "Forecast unavailable"
            }
        })
        if (seq === w._fseq) w._fxhr = xhr
    }

    // Geocoding city search
    property bool geocoding: false
    property string geocodeError: ""
    property string geocodeStatus: ""
    property var _geocodeXhr: null
    property int _geocodeSeq: 0

    function geocode(name) {
        if (!name || !name.trim().length) return
        if (_geocodeXhr) { try { _geocodeXhr.abort() } catch (e) {} _geocodeXhr = null }
        geocoding = true
        geocodeError = ""
        geocodeStatus = "Searching…"
        var seq = ++_geocodeSeq
        var xhr = _hub().request({
            url: "https://geocoding-api.open-meteo.com/v1/search?count=1&name=" + encodeURIComponent(name.trim()),
            timeout: 8000,
            xhrFactory: w.xhrFactory,
            onDone: function(status, body) {
                if (seq !== _geocodeSeq) return
                _geocodeXhr = null
                geocoding = false
                try {
                    var d = JSON.parse(body)
                    if (d && d.results && d.results.length) {
                        var r = d.results[0]
                        var label = r.name + (r.country_code ? ", " + r.country_code : "")
                        if (store) store.patchSettings(instanceId, {
                            lat: r.latitude, lon: r.longitude, place: label
                        })
                        geocodeStatus = "✓ Set to " + label
                        refresh()
                    } else {
                        geocodeError = "City not found"
                        geocodeStatus = geocodeError
                    }
                } catch (e) {
                    geocodeError = "Lookup failed"
                    geocodeStatus = geocodeError
                }
            },
            onError: function(reason) {
                if (seq !== _geocodeSeq) return
                _geocodeXhr = null
                geocoding = false
                geocodeError = reason === "offline" ? "Offline" : "Lookup failed"
                geocodeStatus = geocodeError
            }
        })
        if (seq === _geocodeSeq) _geocodeXhr = xhr
    }

    // Auto-refresh when active and data is missing or older than 15 minutes
    Timer {
        id: pollTimer
        interval: 60000 // Check every minute
        running: w.locationConfigured
        repeat: true
        onTriggered: {
            if (w.active) {
                var age = Date.now() - w.lastSuccessMs
                if (!w.cloudLoaded || age >= 900000) w.refresh()
            }
        }
    }

    onActiveChanged: {
        if (active && locationConfigured) {
            var age = Date.now() - w.lastSuccessMs
            if (!cloudLoaded || age >= 900000) refresh()
        }
    }
    onLatChanged: if (locationConfigured) refresh()
    onLonChanged: if (locationConfigured) refresh()

    Component.onCompleted: {
        if (locationConfigured) refresh()
    }

    // ── Main UI Layout ──────────────────────────────────────────────────────
    ColumnLayout {
        id: mainLay
        anchors.fill: parent
        anchors.margins: w.micro ? theme.spacingXs : theme.spacingSm
        spacing: w.micro ? 2 : theme.spacingSm

        // ── Micro Mode (0.5x0.5) ────────────────────────────────────────────
        Item {
            visible: w.micro
            Layout.fillWidth: true
            Layout.fillHeight: true

            ColumnLayout {
                anchors.centerIn: parent
                spacing: 2

                Text {
                    id: microEmoji
                    text: w.verdictEmoji
                    font.pixelSize: Math.max(theme.fontMinimum, Math.min(parent.width * 0.35, 42))
                    Layout.alignment: Qt.AlignHCenter
                }

                Text {
                    id: microCloud
                    text: w.cloudLoaded ? (w.avgCloud + "%") : w.verdictShort
                    font.bold: true
                    font.pixelSize: Math.max(theme.fontMinimum, Math.min(parent.width * 0.22, 22))
                    color: w.verdictAccent
                    Layout.alignment: Qt.AlignHCenter
                }

                RowLayout {
                    Layout.alignment: Qt.AlignHCenter
                    spacing: 4
                    Text {
                        text: w.moon.glyph
                        font.pixelSize: theme.fontCaption
                    }
                    Text {
                        text: w.cloudLoaded ? w.verdictShort : (w.moon.illum + "%")
                        font.pixelSize: theme.fontMinimum
                        color: theme.textSecondary
                        elide: Text.ElideRight
                    }
                }
            }
        }

        // ── Standard & Roomy Header / Location ──────────────────────────────
        RowLayout {
            visible: !w.micro && w.place.length > 0
            Layout.fillWidth: true

            Text {
                text: "📍 " + ((w.width < 340) ? w.place.split(" ")[0] : w.place)
                font.pixelSize: theme.fontCaption
                font.bold: true
                color: theme.textSecondary
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }

            Rectangle {
                visible: w.isDarkSkyNow && w.width >= 340
                Layout.preferredHeight: 20
                Layout.preferredWidth: darkLabel.implicitWidth + 12
                radius: 10
                color: Qt.rgba(w.accentColor.r, w.accentColor.g, w.accentColor.b, 0.2)
                border.color: w.accentColor
                border.width: 1

                Text {
                    id: darkLabel
                    anchors.centerIn: parent
                    text: "🌌 DARK SKY ACTIVE"
                    font.pixelSize: theme.fontMinimum
                    font.bold: true
                    color: w.accentColor
                }
            }
        }

        // ── Card Components ─────────────────────────────────────────────────
        Component {
            id: heroCardComp
            Rectangle {
                id: heroCard
                anchors.fill: parent
                radius: theme.radiusSm
                color: theme.cardBackgroundAlt
                border.color: Qt.rgba(w.verdictAccent.r, w.verdictAccent.g, w.verdictAccent.b, 0.35)
                border.width: 1

                RowLayout {
                    anchors.fill: parent
                    anchors.margins: theme.spacingSm
                    spacing: theme.spacingSm

                    Text {
                        id: heroEmojiText
                        text: w.verdictEmoji
                        font.pixelSize: w.roomy ? 40 : 32
                        Layout.alignment: Qt.AlignVCenter
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        spacing: 2

                        Text {
                            id: heroTitle
                            text: (heroCard.width < 360) ? (w.verdict.indexOf("—") >= 0 ? w.verdict.split("—")[0].trim() : w.verdict) : w.verdict
                            font.bold: true
                            font.pixelSize: (w.roomy && heroCard.width >= 500) ? theme.fontTitle : theme.fontLabel
                            color: theme.textPrimary
                            wrapMode: Text.WordWrap
                            Layout.fillWidth: true
                        }

                        RowLayout {
                            spacing: theme.spacingSm
                            visible: w.cloudLoaded

                            Rectangle {
                                Layout.preferredHeight: 18
                                Layout.preferredWidth: avgText.implicitWidth + 8
                                radius: 4
                                color: Qt.rgba(theme.textSecondary.r, theme.textSecondary.g, theme.textSecondary.b, 0.15)
                                Text {
                                    id: avgText
                                    anchors.centerIn: parent
                                    text: "~" + w.avgCloud + "% avg cover"
                                    font.pixelSize: theme.fontMinimum
                                    color: theme.textSecondary
                                }
                            }

                            Text {
                                visible: w.bestWindow !== null
                                text: w.bestWindow ? ((heroCard.width < 620) ? (w.bestWindow.label + " (" + w.bestWindow.cloud + "%)") : ("Clearest at " + w.bestWindow.label + " (" + w.bestWindow.cloud + "%)")) : ""
                                font.pixelSize: theme.fontMinimum
                                color: w.verdictAccent
                                wrapMode: Text.WordWrap
                                Layout.fillWidth: true
                            }

                            Text {
                                visible: heroCard.width >= 620 && w.lastSuccessStr.length > 0
                                text: "· " + (w.loading ? "Updating…" : ("Updated " + w.lastSuccessStr))
                                font.pixelSize: theme.fontMinimum
                                color: theme.textTertiary
                            }
                        }
                    }
                }
            }
        }

        Component {
            id: twilightCardComp
            Rectangle {
                id: twilightCard
                anchors.fill: parent
                radius: theme.radiusSm
                color: theme.cardBackgroundAlt
                border.color: theme.cardBorder
                border.width: 1

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: theme.spacingSm
                    spacing: 4

                    RowLayout {
                        Layout.fillWidth: true
                        Text {
                            text: (twilightCard.width < 450) ? "☀️ TWILIGHT" : "☀️ TWILIGHT & DARK SKY"
                            font.pixelSize: theme.fontMinimum
                            font.bold: true
                            color: theme.textSecondary
                            Layout.fillWidth: true
                        }
                        Text {
                            visible: twilightCard.width >= 560
                            text: w.sunEvents ? ("Dark Sky: " + w.formatTime(w.sunEvents.astroDusk) + " – " + w.formatTime(w.sunEvents.astroDawn)) : ""
                            font.pixelSize: theme.fontMinimum
                            font.bold: true
                            color: w.isDarkSkyNow ? w.accentColor : theme.textPrimary
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: theme.spacingSm

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            Text { text: "Sunset"; font.pixelSize: theme.fontMinimum; color: theme.textSecondary }
                            Text { text: w.sunEvents ? w.formatTime(w.sunEvents.sunset) : "—"; font.pixelSize: (twilightCard.width < 360) ? theme.fontCaption : theme.fontLabel; font.bold: true; color: theme.textPrimary }
                        }

                        ColumnLayout {
                            visible: w.roomy && twilightCard.width >= 620
                            Layout.fillWidth: true
                            spacing: 0
                            Text { text: "Civil Dusk"; font.pixelSize: theme.fontMinimum; color: theme.textSecondary }
                            Text { text: w.sunEvents ? w.formatTime(w.sunEvents.civilDusk) : "—"; font.pixelSize: (twilightCard.width < 360) ? theme.fontCaption : theme.fontLabel; font.bold: true; color: theme.textPrimary }
                        }

                        ColumnLayout {
                            visible: w.roomy && twilightCard.width >= 620
                            Layout.fillWidth: true
                            spacing: 0
                            Text { text: "Nautical"; font.pixelSize: theme.fontMinimum; color: theme.textSecondary }
                            Text { text: w.sunEvents ? w.formatTime(w.sunEvents.nauticalDusk) : "—"; font.pixelSize: (twilightCard.width < 360) ? theme.fontCaption : theme.fontLabel; font.bold: true; color: theme.textPrimary }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            Text { text: twilightCard.width >= 480 ? "Astro Dusk (Dark)" : (twilightCard.width < 320 ? "Dark Sky" : "Astro Dusk"); font.pixelSize: theme.fontMinimum; color: w.accentColor }
                            Text { text: w.sunEvents ? w.formatTime(w.sunEvents.astroDusk) : "—"; font.pixelSize: (twilightCard.width < 360) ? theme.fontCaption : theme.fontLabel; font.bold: true; color: w.accentColor }
                        }

                        ColumnLayout {
                            visible: twilightCard.width >= 320
                            Layout.fillWidth: true
                            spacing: 0
                            Text { text: "Sunrise"; font.pixelSize: theme.fontMinimum; color: theme.textSecondary }
                            Text { text: w.sunEvents ? w.formatTime(w.sunEvents.sunrise) : "—"; font.pixelSize: (twilightCard.width < 360) ? theme.fontCaption : theme.fontLabel; font.bold: true; color: theme.textPrimary }
                        }
                    }
                }
            }
        }

        Component {
            id: chartCardComp
            Rectangle {
                id: chartCard
                anchors.fill: parent
                radius: theme.radiusSm
                color: theme.cardBackgroundAlt
                border.color: theme.cardBorder
                border.width: 1

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: theme.spacingSm
                    spacing: 4

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: theme.spacingSm

                        Text {
                            text: w.width > 680 ? "🔭 OBSERVING WINDOW (8 PM – 2 AM)" : "🔭 OBSERVING WINDOW"
                            font.pixelSize: theme.fontMinimum
                            font.bold: true
                            color: theme.textSecondary
                        }
                        Text {
                            visible: w.width > 600
                            text: "· " + (w.observingDateLabel.length ? w.observingDateLabel : "Tonight")
                            font.pixelSize: theme.fontMinimum
                            font.bold: true
                            color: w.accentColor
                            elide: Text.ElideRight
                        }
                        Item { Layout.fillWidth: true }
                        Text {
                            visible: w.width > 700 && (w.lastSuccessMs > 0 || w.loading)
                            text: w.loading ? "Refreshing…" : (w.lastSuccessStr.length ? ("Updated " + w.lastSuccessStr) : "")
                            font.pixelSize: theme.fontMinimum
                            color: w.loading ? w.accentColor : theme.textTertiary
                        }
                        Rectangle {
                            id: cardRefreshBtn
                            width: 28; height: 28
                            radius: 14
                            color: cardRefHover.containsMouse ? theme.cardBackgroundHover : Qt.rgba(255, 255, 255, 0.06)
                            border.color: theme.cardBorder; border.width: 1

                            Text {
                                anchors.centerIn: parent
                                text: "↻"
                                font.pixelSize: Math.max(theme.fontMinimum, 15)
                                font.bold: true
                                color: w.loading ? w.accentColor : (cardRefHover.containsMouse ? theme.textPrimary : theme.textSecondary)
                                rotation: w.loading ? 360 : 0
                                Behavior on rotation {
                                    NumberAnimation { duration: 800; loops: Animation.Infinite; running: w.loading }
                                }
                            }
                            MouseArea {
                                id: cardRefHover
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: w.refresh()
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Text {
                            text: "Sky Clarity"
                            font.pixelSize: theme.fontMinimum
                            color: theme.textSecondary
                            Layout.fillWidth: true
                        }
                        Text {
                            visible: w.bestWindow !== null
                            text: w.bestWindow
                                ? (w.bestWindow.cloud <= 10
                                    ? ("★ Optimal: " + w.bestWindow.label + " (Clear)")
                                    : ("★ Best: " + w.bestWindow.label + " (" + w.bestWindow.cloud + "% cloud)"))
                                : ""
                            font.pixelSize: theme.fontMinimum
                            font.bold: true
                            color: w.accentColor
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        spacing: 6

                        Repeater {
                            model: w.hourlyWindow

                            ColumnLayout {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                spacing: 3

                                Text {
                                    text: modelData.cloud <= 5 ? "Clear" : (modelData.cloud + "%")
                                    font.pixelSize: theme.fontMinimum
                                    font.bold: (w.bestWindow && modelData.hr === w.bestWindow.hr)
                                    color: (modelData.cloud <= 20)
                                        ? w.accentColor
                                        : ((w.bestWindow && modelData.hr === w.bestWindow.hr) ? theme.textPrimary : theme.textSecondary)
                                    Layout.alignment: Qt.AlignHCenter
                                }

                                Item {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true

                                    // Full-height subtle background track
                                    Rectangle {
                                        anchors.fill: parent
                                        anchors.leftMargin: Math.max(0, (parent.width - barWidth) / 2)
                                        anchors.rightMargin: Math.max(0, (parent.width - barWidth) / 2)
                                        readonly property real barWidth: Math.max(12, Math.min(parent.width * 0.55, 32))
                                        radius: 4
                                        color: Qt.rgba(1, 1, 1, 0.06)
                                        border.color: (w.bestWindow && modelData.hr === w.bestWindow.hr)
                                            ? Qt.rgba(w.accentColor.r, w.accentColor.g, w.accentColor.b, 0.3)
                                            : "transparent"
                                        border.width: 1
                                    }

                                    // Observing Clarity bar: 100% height when clear (0% cloud)
                                    Rectangle {
                                        readonly property real barWidth: Math.max(12, Math.min(parent.width * 0.55, 32))
                                        readonly property int clarity: Math.max(0, 100 - modelData.cloud)
                                        anchors.bottom: parent.bottom
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        width: barWidth
                                        height: Math.max(8, parent.height * (clarity / 100))
                                        radius: 4
                                        color: {
                                            if (clarity >= 80) {
                                                return (w.bestWindow && modelData.hr === w.bestWindow.hr)
                                                    ? w.accentColor
                                                    : Qt.rgba(theme.catInfo.r, theme.catInfo.g, theme.catInfo.b, 0.85)
                                            } else if (clarity >= 45) {
                                                return Qt.rgba(theme.catInfo.r, theme.catInfo.g, theme.catInfo.b, 0.5)
                                            } else {
                                                return Qt.rgba(theme.textSecondary.r, theme.textSecondary.g, theme.textSecondary.b, 0.35)
                                            }
                                        }
                                    }
                                }

                                Text {
                                    text: modelData.label
                                    font.pixelSize: theme.fontMinimum
                                    font.bold: (w.bestWindow && modelData.hr === w.bestWindow.hr)
                                    color: (w.bestWindow && modelData.hr === w.bestWindow.hr) ? theme.textPrimary : theme.textSecondary
                                    Layout.alignment: Qt.AlignHCenter
                                }
                            }
                        }
                    }
                }
            }
        }

        Component {
            id: moonCardComp
            Rectangle {
                id: moonCard
                anchors.fill: parent
                radius: theme.radiusSm
                color: theme.cardBackgroundAlt
                border.color: theme.cardBorder
                border.width: 1

                RowLayout {
                    anchors.fill: parent
                    anchors.margins: theme.spacingSm
                    spacing: theme.spacingSm

                    Text {
                        text: w.moon.glyph
                        font.pixelSize: w.roomy ? 32 : 24
                        Layout.alignment: Qt.AlignVCenter
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        spacing: 1

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: theme.spacingSm
                            Text {
                                text: (moonCard.width < 320) ? String(w.moon.name).split(" ")[0] : w.moon.name
                                font.bold: true
                                font.pixelSize: (moonCard.width < 340) ? theme.fontCaption : theme.fontLabel
                                color: theme.textPrimary
                                wrapMode: Text.WordWrap
                                Layout.fillWidth: true
                            }
                            Text {
                                text: (moonCard.width < 450) ? (w.moon.illum + "%") : ("· " + w.moon.illum + "% illuminated")
                                font.pixelSize: (moonCard.width < 340) ? theme.fontCaption : theme.fontLabel
                                color: theme.textSecondary
                                Layout.preferredWidth: contentWidth
                            }
                        }

                        Text {
                            visible: moonCard.width >= 340
                            text: (moonCard.width < 450)
                                ? ("Age ~" + w.moon.age.toFixed(1) + "d · " + (w.moon.cyclePos < 0.5 ? "Waxing" : "Waning"))
                                : ("Lunar age ~" + w.moon.age.toFixed(1) + " days (" + (w.moon.cyclePos < 0.5 ? "Waxing" : "Waning") + ")")
                            font.pixelSize: theme.fontMinimum
                            color: theme.textSecondary
                            Layout.fillWidth: true
                        }
                    }
                }
            }
        }

        Component {
            id: planetsCardComp
            Rectangle {
                id: planetsCard
                anchors.fill: parent
                radius: theme.radiusSm
                color: theme.cardBackgroundAlt
                border.color: theme.cardBorder
                border.width: 1

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: theme.spacingSm
                    spacing: 4

                    RowLayout {
                        Layout.fillWidth: true
                        Text {
                            text: (planetsCard.width < 450) ? "🪐 PLANETS" : "🪐 NAKED-EYE PLANETS"
                            font.pixelSize: theme.fontMinimum
                            font.bold: true
                            color: theme.textSecondary
                            Layout.fillWidth: true
                        }
                        Text {
                            text: "Rise & Set Tonight"
                            font.pixelSize: theme.fontMinimum
                            color: theme.textSecondary
                            visible: w.roomy
                        }
                    }

                    // ── 2-Column Mode: 5 Full-Width Ephemeris Rows ──────────
                    ColumnLayout {
                        visible: w.twoColumn
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        spacing: (planetsCard.height < 210) ? 2 : 4

                        Repeater {
                            model: w.planets

                            Rectangle {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                Layout.minimumHeight: (planetsCard.height < 210) ? 26 : 32
                                radius: theme.radiusSm
                                color: Qt.rgba(1, 1, 1, 0.035)
                                border.color: (modelData.status.indexOf("Up all night") >= 0 || modelData.status.indexOf("Evening") >= 0)
                                    ? Qt.rgba(w.accentColor.r, w.accentColor.g, w.accentColor.b, 0.28)
                                    : "transparent"
                                border.width: 1

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: theme.spacingSm + 4
                                    anchors.rightMargin: theme.spacingSm + 4
                                    spacing: theme.spacingSm

                                    // Planet symbol & Name
                                    RowLayout {
                                        spacing: 8
                                        Layout.preferredWidth: 110

                                        Text {
                                            text: modelData.symbol
                                            font.pixelSize: Math.max(theme.fontMinimum, 18)
                                            font.bold: true
                                            color: (modelData.status.indexOf("Up all night") >= 0 || modelData.status.indexOf("Evening") >= 0)
                                                ? w.accentColor : theme.textPrimary
                                        }

                                        Text {
                                            text: modelData.name
                                            font.bold: true
                                            font.pixelSize: theme.fontLabel
                                            color: theme.textPrimary
                                        }
                                    }

                                    // Status pill badge
                                    Rectangle {
                                        radius: 4
                                        color: (modelData.status.indexOf("Up all night") >= 0 || modelData.status.indexOf("Evening") >= 0)
                                            ? Qt.rgba(w.accentColor.r, w.accentColor.g, w.accentColor.b, 0.18)
                                            : Qt.rgba(1, 1, 1, 0.06)
                                        border.color: (modelData.status.indexOf("Up all night") >= 0 || modelData.status.indexOf("Evening") >= 0)
                                            ? Qt.rgba(w.accentColor.r, w.accentColor.g, w.accentColor.b, 0.4)
                                            : "transparent"
                                        border.width: 1
                                        implicitHeight: 22
                                        implicitWidth: statusTxt.implicitWidth + 14

                                        Text {
                                            id: statusTxt
                                            anchors.centerIn: parent
                                            text: (planetsCard.width < 680) ? String(modelData.status).split("·")[0].trim() : modelData.status
                                            font.pixelSize: theme.fontMinimum
                                            font.bold: (modelData.status.indexOf("Up all night") >= 0 || modelData.status.indexOf("Evening") >= 0)
                                            color: (modelData.status.indexOf("Up all night") >= 0 || modelData.status.indexOf("Evening") >= 0)
                                                ? w.accentColor : theme.textSecondary
                                        }
                                    }

                                    Item { Layout.fillWidth: true }

                                    // Rise & Set times
                                    RowLayout {
                                        visible: planetsCard.width >= 460
                                        spacing: theme.spacingSm

                                        RowLayout {
                                            spacing: 3
                                            visible: modelData.rise !== null
                                            Text {
                                                text: "Rise"
                                                font.pixelSize: theme.fontCaption
                                                color: theme.textSecondary
                                            }
                                            Text {
                                                text: modelData.rise ? w.formatTime(modelData.rise) : ""
                                                font.pixelSize: theme.fontCaption
                                                font.bold: true
                                                color: theme.textPrimary
                                            }
                                        }

                                        Text {
                                            visible: modelData.rise !== null && modelData.set !== null && planetsCard.width >= 500
                                            text: "·"
                                            font.pixelSize: theme.fontCaption
                                            color: theme.textSecondary
                                        }

                                        RowLayout {
                                            spacing: 3
                                            visible: modelData.set !== null && planetsCard.width >= 500
                                            Text {
                                                text: "Set"
                                                font.pixelSize: theme.fontCaption
                                                color: theme.textSecondary
                                            }
                                            Text {
                                                text: modelData.set ? w.formatTime(modelData.set) : ""
                                                font.pixelSize: theme.fontCaption
                                                font.bold: true
                                                color: theme.textPrimary
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // ── Single-Column Compact Mode: Horizontal Planet Row ──
                    RowLayout {
                        visible: !w.twoColumn
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        spacing: theme.spacingSm

                        Repeater {
                            model: (planetsCard.width < 450) ? w.planets.slice(0, 2) : ((planetsCard.width < 650) ? w.planets.slice(0, 3) : ((planetsCard.width < 850) ? w.planets.slice(0, 4) : w.planets))

                            ColumnLayout {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                spacing: 1

                                RowLayout {
                                    spacing: 2
                                    Text {
                                        text: modelData.symbol
                                        font.bold: true
                                        font.pixelSize: theme.fontLabel
                                        color: theme.textPrimary
                                    }
                                    Text {
                                        text: modelData.name
                                        font.bold: true
                                        font.pixelSize: theme.fontCaption
                                        color: theme.textPrimary
                                        elide: Text.ElideRight
                                    }
                                }

                                Text {
                                    text: (planetsCard.width < 600) ? String(modelData.status).split("·")[0].trim() : modelData.status
                                    font.pixelSize: theme.fontMinimum
                                    color: (modelData.status.indexOf("Up all night") >= 0 || modelData.status.indexOf("Evening") >= 0)
                                        ? w.accentColor : theme.textSecondary
                                    elide: Text.ElideRight
                                }

                                Text {
                                    visible: planetsCard.width > 500 && modelData.set !== null
                                    text: "Set " + w.formatTime(modelData.set)
                                    font.pixelSize: theme.fontMinimum
                                    color: theme.textSecondary
                                    elide: Text.ElideRight
                                }
                            }
                        }
                    }
                }
            }
        }

        // ── 2-Column Balanced Cards Layout (wide / roomy tiles) ─────────────
        RowLayout {
            id: cardsTwoCol
            visible: !w.micro && w.twoColumn
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: theme.spacingSm

            // Left Column: Weather & Observing Window
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredWidth: 1
                spacing: theme.spacingSm

                Loader {
                    active: cardsTwoCol.visible && w.showClouds
                    visible: w.showClouds
                    sourceComponent: heroCardComp
                    Layout.fillWidth: true
                    Layout.preferredHeight: w.roomy ? 88 : 72
                }

                Loader {
                    active: cardsTwoCol.visible && w.showHourlyBar && w.hourlyWindow.length > 0
                    visible: w.showHourlyBar && w.hourlyWindow.length > 0
                    sourceComponent: chartCardComp
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.minimumHeight: 120
                }
            }

            // Right Column: Celestial Bodies & Twilights
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredWidth: 1
                spacing: theme.spacingSm

                Loader {
                    active: cardsTwoCol.visible && w.showTwilights && w.sunEvents !== null
                    visible: w.showTwilights && w.sunEvents !== null
                    sourceComponent: twilightCardComp
                    Layout.fillWidth: true
                    Layout.preferredHeight: (w.height < 480) ? 66 : (w.roomy ? 80 : 64)
                }

                Loader {
                    active: cardsTwoCol.visible && w.showMoon
                    visible: w.showMoon
                    sourceComponent: moonCardComp
                    Layout.fillWidth: true
                    Layout.preferredHeight: (w.height < 480) ? 52 : (w.roomy ? 64 : 48)
                }

                Loader {
                    active: cardsTwoCol.visible && w.showPlanets && w.planets.length > 0
                    visible: w.showPlanets && w.planets.length > 0
                    sourceComponent: planetsCardComp
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.minimumHeight: 80
                }
            }
        }

        // ── Single-Column Layout (compact, narrow, or portrait tiles) ────────
        ColumnLayout {
            id: cardsSingleCol
            visible: !w.micro && !w.twoColumn
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: theme.spacingSm

            Loader {
                active: cardsSingleCol.visible && w.showClouds
                visible: w.showClouds
                sourceComponent: heroCardComp
                Layout.fillWidth: true
                Layout.preferredHeight: w.roomy ? 86 : 64
            }

            Loader {
                active: cardsSingleCol.visible && w.showTwilights && w.sunEvents !== null && w.height >= 340
                visible: w.showTwilights && w.sunEvents !== null && w.height >= 340
                sourceComponent: twilightCardComp
                Layout.fillWidth: true
                Layout.preferredHeight: w.roomy ? 72 : 56
            }

            Loader {
                active: cardsSingleCol.visible && w.showHourlyBar && w.hourlyWindow.length > 0 && w.roomy && w.width >= 360
                visible: w.showHourlyBar && w.hourlyWindow.length > 0 && w.roomy && w.width >= 360
                sourceComponent: chartCardComp
                Layout.fillWidth: true
                Layout.preferredHeight: 110
                Layout.maximumHeight: 140
            }

            Loader {
                active: cardsSingleCol.visible && w.showMoon && w.height >= 520
                visible: w.showMoon && w.height >= 520
                sourceComponent: moonCardComp
                Layout.fillWidth: true
                Layout.preferredHeight: w.roomy ? 56 : 44
            }

            Loader {
                active: cardsSingleCol.visible && w.showPlanets && w.planets.length > 0 && w.height >= 580
                visible: w.showPlanets && w.planets.length > 0 && w.height >= 580
                sourceComponent: planetsCardComp
                Layout.fillWidth: true
                Layout.preferredHeight: w.roomy ? 72 : 56
            }
        }

        // ── Roomy Footer with Refresh Button & Attribution ──────────────────
        RowLayout {
            visible: w.roomy
            Layout.fillWidth: true

            Text {
                text: w.lastSuccessMs > 0
                    ? ((w.width < 620)
                        ? ("Updated " + Qt.formatTime(new Date(w.lastSuccessMs), "HH:mm"))
                        : ("Updated " + Qt.formatTime(new Date(w.lastSuccessMs), "HH:mm") + " · Open-Meteo & Local Astro"))
                    : (w.locationConfigured
                        ? (w.width < 620 ? "Astronomical calculations active" : "Local astronomical calculations active")
                        : "Unconfigured")
                font.pixelSize: theme.fontMinimum
                color: theme.textSecondary
                Layout.fillWidth: true
            }

            PillButton {
                id: refreshBtn
                label: "Refresh"
                glyph: "↻"
                visible: w.locationConfigured
                onClicked: w.refresh()
            }
        }
    }
}
