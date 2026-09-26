# The Sky Tonight Widget

The **The Sky Tonight** widget displays stargazing and night-sky observing conditions on your Xeneon Edge display. It combines deterministic local astronomical calculations (twilights, dark-sky windows, moon phase) with real-time cloud forecasts from Open-Meteo.

All network queries are gated through the Hub's safe [`NetHub`](../architecture/) egress gate, requiring zero plugins, zero cloud dependencies, zero external Node.js scripts, and zero headless browser overhead.

---

## 1. Overview & Capabilities

- **Tonight's Observing Verdict**: Evaluates tonight's 8 PM – 2 AM observing window and provides an instant rating:
  - 🌟 **Clear** ($\le 25\%$ avg clouds) — Great for observing
  - ⛅ **Partly Cloudy** ($\le 55\%$ avg clouds) — Gaps to peek through
  - 🌥️ **Mostly Cloudy** ($\le 80\%$ avg clouds) — Limited windows
  - ☁️ **Overcast** ($> 80\%$ avg clouds) — Skywatching unlikely
- **Dark-Sky Window**: Computes the exact start and end of true dark sky based on **astronomical dusk and dawn** (when the sun descends 18° below the horizon). When astronomical darkness is active, the widget highlights a live `🌌 DARK SKY ACTIVE` badge.
- **Solar & Twilight Timeline**: Displays the complete evening-to-morning twilight progression:
  - ☀️ **Sunset** (solar altitude $-0.833^\circ$)
  - **Civil Dusk** (solar altitude $-6.0^\circ$)
  - **Nautical Dusk** (solar altitude $-12.0^\circ$)
  - 🌌 **Astronomical Dusk / Dark Sky Window** (solar altitude $-18.0^\circ$)
  - 🌅 **Sunrise** (solar altitude $-0.833^\circ$)
- **Hourly Observing Window Chart**: A mini bar chart visualizing cloud percentage hour-by-hour across the key observing window (8 PM, 9 PM, 10 PM, 11 PM, 12 AM, 1 AM, 2 AM), highlighting the clearest hour.
- **Moon Phase & Illumination**: Computes exact geocentric lunar age in days, illuminated percentage, and phase glyph locally on-device via the Meeus algorithm.
- **Naked-Eye Planets (Rise & Set)**: Computes local rise and set times and viewing conditions for all 5 classical naked-eye planets (Mercury ☿, Venus ♀, Mars ♂, Jupiter ♃, Saturn ♄) offline. Identifies whether each planet is an evening object, morning object, or visible all night.
- **Location Inheritance & Geocoding**:
  - Automatically inherits coordinates and city name from any configured `Weather` or `Moon` widget on your dashboard.
  - Built-in city search / geocoding via Open-Meteo.
- **100% Offline Capable for Celestial Events**: Twilight, moon phase, and planetary rise/set calculations are performed entirely locally on-device. If network access is lost, astronomical times and celestial positions continue to update seamlessly, while cloud telemetry degrades cleanly.

---

## 2. Configuration Settings

| Setting | Type | Default | Description |
|---|---|---|---|
| **Location setup** | Segmented | `Search city` | Choose between searching by city name or entering manual coordinates. |
| **Place name** | Text | `""` | City or town name (e.g. `St. Augustine, FL` or `London, UK`). Leaving this empty auto-inherits the location from your Weather or Moon widget. |
| **Look up coordinates** | Action | — | Queries Open-Meteo to resolve city name into latitude and longitude coordinates. |
| **Latitude / Longitude** | Number | `0.0` / `0.0` | Exact observer coordinates ($-90^\circ$ to $+90^\circ$ lat, $-180^\circ$ to $+180^\circ$ lon). |
| **Show twilight timeline** | Toggle | `true` | Shows sunset, civil dusk, nautical dusk, and astronomical twilight dark-sky window. |
| **Show cloud cover forecast** | Toggle | `true` | Shows tonight's average cloud cover, observing verdict, and clearest hour. |
| **Show hourly chart** | Toggle | `true` | Shows the 8 PM – 2 AM hourly cloud cover bar chart on roomy and tall tiles. |
| **Show moon phase** | Toggle | `true` | Shows moon phase glyph, illumination percentage, and lunar age. |
| **Show naked-eye planets** | Toggle | `true` | Shows rise and set times and viewing conditions for Mercury, Venus, Mars, Jupiter, and Saturn. |

---

## 3. Astronomical Algorithms & Sources

- **Solar Twilights**: Standard NOAA / Jean Meeus solar coordinates algorithm computing Greenwich Mean Sidereal Time (GMST), Right Ascension ($\alpha$), and Declination ($\delta$), solved for zenith angles of $90.833^\circ$ (sunset/sunrise), $96.0^\circ$ (civil twilight), $102.0^\circ$ (nautical twilight), and $108.0^\circ$ (astronomical twilight).
- **Moon Phase & Illumination**: Low-precision Jean Meeus lunar coordinates algorithm computing phase angle $i$, illuminated fraction $(1 + \cos i) / 2$, and mean elongation.
- **Planetary Ephemerides**: NASA JPL Keplerian orbital elements with rates per century ($T$ from epoch J2000.0) combined with Jean Meeus topocentric hour-angle reduction to compute equatorial Right Ascension and Declination ($\alpha, \delta$), zenith altitude, and rise/set times for Mercury, Venus, Mars, Jupiter, and Saturn in $\sim 0.02\text{ ms}$ with zero network requests.
- **Cloud Cover**: Free hourly cloud telemetry from [Open-Meteo](https://open-meteo.com) (`api.open-meteo.com/v1/forecast`), refreshed automatically every 30 minutes when active.
