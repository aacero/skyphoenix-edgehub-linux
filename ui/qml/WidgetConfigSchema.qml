import QtQuick

// WidgetConfigSchema - declarative config schema per widget type, shared by the
// on-device (hub) config view and the desktop Manager. The config renderer turns
// these into a professional, sectioned form. Field types:
//   text | textarea | number | slider | toggle | segmented | select | date | hour |
//   tasks | action | info | accent
// Fields may carry `help` (a one-line hint under the label). Every widget gets a
// "General" section (custom title) and an "About" section describing it.
//
// IMPORTANT: every option here is honoured by the corresponding widget - nothing
// is decorative. Keep keys in sync with the widget's `cfg` reads + catalog defaults.
QtObject {
    id: sc

    function titleSection(def) {
        return { title: "General", cols: 1, fields: [
            { key: "title", label: "Custom title", type: "text", placeholder: def,
              help: "Shown in the widget header. Leave blank for the default." } ] }
    }
    function about(text) {
        return { title: "About this widget", cols: 1, fields: [ { type: "info", text: text } ] }
    }
    // Universal per-widget appearance - added to EVERY widget so any of them can
    // be given its own accent + an animated in-card backdrop to stand out.
    function appearanceSection() {
        return { title: "Widget appearance", cols: 1,
            desc: "Give this widget its own look so it stands out.", fields: [
            { key: "accent", label: "Accent colour", type: "accent", dflt: "",
              help: "Recolours this widget's icon, glow and highlights." },
            { key: "cardBackdrop", label: "Card backdrop", type: "segmented", dflt: "none",
              help: "A subtle animated backdrop inside this widget's card.", options: [
                { value: "none", label: "None" }, { value: "orbs", label: "Orbs" },
                { value: "mesh", label: "Mesh" }, { value: "aurora", label: "Aurora" },
                { value: "waves", label: "Waves" }, { value: "stars", label: "Stars" },
                { value: "bokeh", label: "Bokeh" }, { value: "grid", label: "Grid" } ] } ] }
    }

    function graphStyleField(visibleWhen) {
        var field = { key: "graphStyle", label: "Graph style", type: "segmented",
            dflt: "smooth",
            help: "Smooth keeps the raw samples faintly visible and overlays a stable trend, so real spikes are never hidden.",
            options: [
                { value: "smooth", label: "Smooth" },
                { value: "line", label: "Line" },
                { value: "bars", label: "Bars" } ] }
        if (visibleWhen) field.visibleWhen = visibleWhen
        return field
    }

    function graphScaleField(visibleWhen) {
        var field = { key: "graphScale", label: "Graph range", type: "segmented",
            dflt: "zero",
            help: "From zero shows the true size of changes. Rolling range magnifies variation and labels the exact range on the axis.",
            options: [
                { value: "zero", label: "From zero" },
                { value: "range", label: "Rolling range" } ] }
        if (visibleWhen) field.visibleWhen = visibleWhen
        return field
    }

    function gpuDeviceOptions(runtimeMetrics, selectedValue) {
        var devices = runtimeMetrics && Array.isArray(runtimeMetrics.gpu_devices)
                      ? runtimeMetrics.gpu_devices : []
        var primaryId = runtimeMetrics ? String(runtimeMetrics.gpu_primary_id || "") : ""
        var primaryName = ""
        var options = []
        var seen = ({})
        for (var i = 0; i < devices.length; i++) {
            var device = devices[i] || ({})
            var id = String(device.id || "")
            if (!id.length || seen[id]) continue
            seen[id] = true
            var name = String(device.name || device.vendor || id)
            var identity = name === id ? id : name + " (" + id + ")"
            options.push({ value: id, label: identity })
            if (id === primaryId) primaryName = name
        }
        var autoLabel = primaryName.length ? "Automatic: " + primaryName : "Automatic"
        options.unshift({ value: "auto", label: autoLabel })
        var selected = String(selectedValue || "auto")
        if (selected !== "auto" && !seen[selected])
            options.push({ value: selected, label: "Offline selection (" + selected + ")" })
        return options
    }

    function networkInterfaceOptions(runtimeMetrics, selectedValue) {
        var interfaces = runtimeMetrics && Array.isArray(runtimeMetrics.net_interfaces)
                         ? runtimeMetrics.net_interfaces : []
        var options = [
            { value: "", label: "Aggregate physical links" }
        ]
        var seen = ({})
        for (var i = 0; i < interfaces.length; i++) {
            var netif = interfaces[i] || ({})
            var name = String(netif.name || "")
            if (!name.length || seen[name] || String(netif.category || "") === "local")
                continue
            seen[name] = true
            var friendly = String(netif.friendly_name || "")
            var identity = friendly.length ? friendly + " (" + name + ")" : name
            var context = [String(netif.category || "interface"),
                           String(netif.link_state || "unknown")]
            if (netif.speed_mbps !== undefined && netif.speed_mbps !== null)
                context.push(String(netif.speed_mbps) + " Mbps")
            options.push({ value: name, label: identity + " · " + context.join(" · ") })
        }
        var selected = String(selectedValue || "")
        if (selected.length && !seen[selected])
            options.push({ value: selected, label: "Offline interface (" + selected + ")" })
        return options
    }

    function diskMountOptions(runtimeMetrics, selectedValue) {
        var mounts = runtimeMetrics && Array.isArray(runtimeMetrics.disk_mounts)
                     ? runtimeMetrics.disk_mounts : []
        var options = []
        var seen = ({})
        for (var i = 0; i < mounts.length; i++) {
            var mount = mounts[i] || ({})
            var path = String(mount.path || "")
            if (!path.length || seen[path]) continue
            seen[path] = true
            var context = []
            if (String(mount.fs_type || "").length) context.push(String(mount.fs_type))
            if (String(mount.source || "").length) context.push(String(mount.source))
            options.push({
                value: path,
                label: path + (context.length ? " · " + context.join(" · ") : "")
            })
        }
        if (!seen["/"]) options.unshift({ value: "/", label: "/ · Root filesystem" })
        var selected = String(selectedValue || "/")
        if (selected.length && !seen[selected] && selected !== "/")
            options.push({ value: selected, label: "Offline mount (" + selected + ")" })
        return options
    }

    // Public entry: the per-type schema PLUS the universal appearance section.
    // Runtime metrics are optional. The GPU editor uses them to present stable,
    // discovered DRM identities instead of invented "GPU 1" choices.
    function schemaFor(type, runtimeMetrics, currentValue) {
        var s = _schemaFor(type)
        if (type === "gpu" && s && s.sections && s.sections.length) {
            var fields = s.sections[0].fields || []
            for (var i = 0; i < fields.length; i++) {
                if (fields[i].key !== "gpuDevice") continue
                fields[i].options = gpuDeviceOptions(runtimeMetrics, currentValue)
                break
            }
        }
        if (type === "sensors" && s && s.sections && s.sections.length) {
            for (var sectionIndex = 0; sectionIndex < s.sections.length; sectionIndex++) {
                var sensorFields = s.sections[sectionIndex].fields || []
                for (var sensorIndex = 0; sensorIndex < sensorFields.length; sensorIndex++) {
                    if (sensorFields[sensorIndex].key !== "gpuDevice") continue
                    sensorFields[sensorIndex].options =
                        gpuDeviceOptions(runtimeMetrics, currentValue)
                }
            }
        }
        if (type === "net" && s && s.sections && s.sections.length > 1) {
            var netFields = s.sections[1].fields || []
            for (var j = 0; j < netFields.length; j++) {
                if (netFields[j].key !== "interfaceName") continue
                netFields[j].options = networkInterfaceOptions(runtimeMetrics, currentValue)
                break
            }
        }
        if (type === "disk" && s && s.sections && s.sections.length) {
            var diskFields = s.sections[0].fields || []
            for (var k = 0; k < diskFields.length; k++) {
                if (diskFields[k].key !== "mountPath") continue
                diskFields[k].options = diskMountOptions(runtimeMetrics, currentValue)
                break
            }
        }
        if (s && s.sections)
            s.sections.push(appearanceSection())
        return s
    }

    function _schemaFor(type) {
        switch (type) {

        case "packages": return { sections: [
            { title: "Display", cols: 1, fields: [
                { key: "showDistro", label: "Show the distribution name", type: "toggle", dflt: true,
                  help: "Reads the name your system reports in /etc/os-release." } ] },
            titleSection("Packages"),
            about("A read-only inventory from pacman's local database or dpkg's installed "
                  + "status records. RPM-family systems are detected explicitly without "
                  + "executing rpm. Refresh never installs, removes, updates, or synchronizes "
                  + "package metadata.") ] }

        case "sinceinstall": return { sections: [
            { title: "Display", cols: 1, fields: [
                { key: "ageUnit", label: "Show as", type: "segmented", dflt: "auto", options: [
                    { value: "auto", label: "Automatic" },
                    { value: "days", label: "Days" },
                    { value: "months", label: "Months" },
                    { value: "years", label: "Years" } ],
                  help: "Automatic switches from elapsed days to completed calendar months and years." },
                { key: "showDate", label: "Show the evidence date", type: "toggle", dflt: true,
                  help: "Estimated dates are labelled as the earliest visible record, not as a confirmed installation date." } ] },
            titleSection("System Age"),
            about("Uses a distribution installer record when available. Otherwise it shows "
                  + "the earliest readable package-history record as an estimate and names "
                  + "the exact evidence source. Rotated or deleted logs can make an estimate "
                  + "younger than the system.") ] }

        case "clock": return { sections: [
            { title: "Display", cols: 1, fields: [
                { key: "format24", label: "24-hour clock", type: "toggle", dflt: false },
                { key: "showSeconds", label: "Show seconds", type: "toggle", dflt: false },
                { key: "showDate", label: "Show the date", type: "toggle", dflt: true },
                { key: "dateStyle", label: "Date style", type: "segmented", dflt: "full", options: [
                    { value: "full",  label: "Weekday, 5 Jan" },
                    { value: "short", label: "05/01" },
                    { value: "iso", label: "2026-01-05" },
                    { value: "custom", label: "Custom" } ] },
                { key: "datePattern", label: "Custom date pattern", type: "text", dflt: "ddd, d MMM",
                  visibleWhen: { key: "dateStyle", equals: "custom", dflt: "full" },
                  validator: "qtDatePattern", preview: "qtDatePattern",
                  help: "Qt date tokens include ddd, MMM, MM and yyyy." },
                { key: "localeName", label: "Locale", type: "text", placeholder: "System default", dflt: "",
                  help: "Optional locale such as en_GB or de_AT for translated day and month names." } ] },
            { title: "Time zone (world clock)", cols: 1,
              desc: "Show another city's time instead of your local time.", fields: [
                { key: "customZone", label: "Use a specific time zone", type: "toggle", dflt: false },
                // dflt "" MUST stay the fixed-offset mode: it is what a config saved
                // before this field has, and defaulting to a city would silently
                // re-point every existing world clock to the wrong place.
                { key: "zoneId", label: "City / IANA zone", type: "timezone", dflt: "",
                  visibleWhen: { key: "customZone", equals: true, dflt: false },
                  help: "Search or choose any zone supplied by the OS tzdata. It follows real daylight-saving rules." },
                { key: "zoneLabel", label: "Zone name", type: "text", placeholder: "New York", dflt: "",
                  visibleWhen: { key: "customZone", equals: true, dflt: false },
                  help: "A label shown above the time. Leave blank to use the city." },
                { key: "utcOffset", label: "UTC offset", type: "slider", min: -12, max: 14, step: 0.5, suffix: " h", dflt: 0,
                  visibleWhen: [ { key: "customZone", equals: true, dflt: false },
                                 { key: "zoneId", equals: "", dflt: "" } ],
                  help: "Only used when City is Fixed offset. It never changes for daylight saving." },
                { key: "secondaryZones", label: "Additional zones", type: "timezoneList", dflt: "",
                  visibleWhen: { key: "customZone", equals: true, dflt: false },
                  help: "Search and choose up to three OS-provided IANA zones. They appear in tall and expanded views." } ] },
            titleSection("Clock"),
            about("A digital clock with locale-aware dates and OS-backed world clocks. Sunrise and sunset remain part of the shared location work so this widget never requests a location on its own.") ] }

        case "analog": return { sections: [
            { title: "Display", cols: 1, fields: [
                { key: "showSeconds", label: "Show the second hand", type: "toggle", dflt: true },
                { key: "showNumerals", label: "Show hour numerals", type: "toggle", dflt: false },
                { key: "faceStyle", label: "Face", type: "segmented", dflt: "classic", options: [
                    { value: "classic", label: "Classic" }, { value: "minimal", label: "Minimal" } ] },
                { key: "handStyle", label: "Hands", type: "segmented", dflt: "round", options: [
                    { value: "round", label: "Rounded" }, { value: "slender", label: "Slender" } ] } ] },
            { title: "Time zone", cols: 1, fields: [
                { key: "customZone", label: "Use a specific time zone", type: "toggle", dflt: false },
                { key: "zoneId", label: "City / IANA zone", type: "timezone", dflt: "",
                  visibleWhen: { key: "customZone", equals: true, dflt: false },
                  help: "Choose any OS tzdata zone for daylight-saving-correct time, or leave blank for a fixed offset." },
                { key: "zoneLabel", label: "Zone name", type: "text", dflt: "", placeholder: "Tokyo",
                  visibleWhen: { key: "customZone", equals: true, dflt: false } },
                { key: "utcOffset", label: "Fixed UTC offset", type: "slider", min: -12, max: 14, step: 0.5, suffix: " h", dflt: 0,
                  visibleWhen: [ { key: "customZone", equals: true, dflt: false },
                                 { key: "zoneId", equals: "", dflt: "" } ],
                  help: "Only used with an empty IANA zone. Fixed offsets do not follow daylight saving." } ] },
            titleSection("Analog Clock"),
            about("A responsive analog world clock. Effective Reduce Motion removes the moving second hand even when it is enabled here.") ] }

        case "moon": return { sections: [
            { title: "Location", cols: 1, fields: [
                { key: "hemisphere", label: "Hemisphere", type: "segmented", dflt: "north",
                  help: "Flips the illuminated side to match your sky.", options: [
                    { value: "north", label: "Northern" },
                    { value: "south", label: "Southern" } ] },
                { key: "showAccuracyNote", label: "Show calculation note", type: "toggle", dflt: true,
                  help: "Discloses that the phase and local event times are approximate." },
                { key: "showLocalEvents", label: "Show moonrise and moonset", type: "toggle", dflt: false,
                  help: "Optional. Coordinates stay in your local configuration and are used only for an on-device approximate calculation." },
                { key: "locationMode", label: "Location setup", type: "segmented", dflt: "search",
                  visibleWhen: { key: "showLocalEvents", equals: true, dflt: false }, options: [
                    { value: "search", label: "Search city" },
                    { value: "manual", label: "Manual coordinates" } ] },
                { key: "place", label: "Place name", type: "text", placeholder: "Vienna, AT",
                  visibleWhen: [
                    { key: "showLocalEvents", equals: true, dflt: false },
                    { key: "locationMode", equals: "search", dflt: "search" } ] },
                { type: "action", actionLabel: "Look up this city and set coordinates", action: "geocode",
                  visibleWhen: [
                    { key: "showLocalEvents", equals: true, dflt: false },
                    { key: "locationMode", equals: "search", dflt: "search" } ] } ] },
            { title: "Manual coordinates", cols: 2, fields: [
                { key: "lat", label: "Latitude", type: "number", min: -90, max: 90, step: 0.01,
                  visibleWhen: [
                    { key: "showLocalEvents", equals: true, dflt: false },
                    { key: "locationMode", equals: "manual", dflt: "search" } ] },
                { key: "lon", label: "Longitude", type: "number", min: -180, max: 180, step: 0.01,
                  visibleWhen: [
                    { key: "showLocalEvents", equals: true, dflt: false },
                    { key: "locationMode", equals: "manual", dflt: "search" } ] } ] },
            titleSection("Moon Phase"),
            about("A private local phase estimate based on a standard synodic cycle. Optional coordinates add approximate moonrise and moonset times without a weather or astronomy service.") ] }

        case "cpu": return { sections: [
            { title: "Display", cols: 1, fields: [
                { key: "showTemp", label: "Show temperature label", type: "toggle", dflt: true,
                  help: "Hides only the numeric label. Thermal warning and critical states remain active." },
                { key: "tempSource", label: "Temperature source", type: "segmented", dflt: "auto",
                  help: "Choose which available CPU sensor drives the reading and thermal warning.", options: [
                    { value: "auto", label: "Automatic" },
                    { value: "package", label: "Package" },
                    { value: "hottest", label: "Hottest" } ] },
                { key: "showHistory", label: "Show the history graph", type: "toggle", dflt: true },
                { key: "historyWindow", label: "History window", type: "segmented", dflt: "2m",
                  visibleWhen: { key: "showHistory", equals: true, dflt: true }, options: [
                    { value: "1m", label: "1 minute" },
                    { value: "2m", label: "2 minutes" },
                    { value: "5m", label: "5 minutes" } ] },
                graphStyleField({ key: "showHistory", equals: true, dflt: true }),
                { key: "showFrequency", label: "Show CPU frequency", type: "toggle", dflt: true,
                  help: "Adds the average current frequency when the widget has enough room." },
                { key: "showLoadAverage", label: "Show load averages", type: "toggle", dflt: true,
                  help: "Adds the 1, 5 and 15 minute load averages in large and expanded views." },
                { key: "showPerCore", label: "Show busiest cores", type: "toggle", dflt: true,
                  help: "Live activity for the eight busiest logical CPUs, in the expanded view and on a large tile." },
                { key: "showTopProcess", label: "Show busiest process", type: "toggle", dflt: true,
                  help: "The local process using the most CPU in the latest sample, on the tile and in the expanded view." },
                { key: "warnTemp", label: "Warn above", type: "slider", min: 60, max: 100, step: 1, suffix: " °C", dflt: 85,
                  help: "The widget turns red above this temperature and amber as it approaches it, even if the temperature label is hidden." } ] },
            titleSection("CPU"),
            about("Live processor utilization, frequency, load averages and temperature, straight from the Linux kernel.") ] }

        case "gpu": return { sections: [
            { title: "Display", cols: 1, fields: [
                { key: "gpuDevice", label: "GPU device", type: "select", dflt: "auto",
                  help: "Automatic follows the preferred DRM device. Discovered devices include their stable card identity, and an offline selection remains available for recovery.",
                  options: [ { value: "auto", label: "Automatic" } ] },
                { key: "showTemp", label: "Show temperature label", type: "toggle", dflt: true,
                  help: "Hides the numeric temperature label only. Thermal warnings remain active." },
                { key: "showHistory", label: "Show the history graph", type: "toggle", dflt: true },
                graphStyleField({ key: "showHistory", equals: true, dflt: true }),
                { key: "showDetails", label: "Show hardware details", type: "toggle", dflt: true,
                  help: "Large and expanded views show supported VRAM, power, clock, fan, driver and device information." },
                { key: "warnTemp", label: "Warn above", type: "slider", min: 60, max: 110, step: 1, suffix: " °C", dflt: 90,
                  help: "The widget turns red above this temperature and amber as it approaches it, even if the temperature label is hidden." } ] },
            titleSection("GPU"),
            about("Live AMD, Intel and NVIDIA DRM device capabilities with utilization, temperature and supported hardware telemetry.") ] }

        case "ram": return { sections: [
            { title: "Display", cols: 1, fields: [
                { key: "unit", label: "Center reading", type: "segmented", dflt: "percent", options: [
                    { value: "percent", label: "Percent" },
                    { value: "gb", label: "GiB used" } ] },
                { key: "showHistory", label: "Show the history graph", type: "toggle", dflt: true },
                { key: "historyWindow", label: "History window", type: "segmented", dflt: "2m",
                  visibleWhen: { key: "showHistory", equals: true, dflt: true }, options: [
                    { value: "1m", label: "1 minute" },
                    { value: "2m", label: "2 minutes" },
                    { value: "5m", label: "5 minutes" } ] },
                graphStyleField({ key: "showHistory", equals: true, dflt: true }),
                { key: "showDetails", label: "Show memory details", type: "toggle", dflt: true,
                  help: "Large and expanded views show available memory, cache, buffers, swap and Linux pressure." },
                { key: "warnPercent", label: "Warn above", type: "slider", min: 50, max: 95,
                  step: 1, suffix: " %", dflt: 75,
                  help: "The gauge turns amber at this memory use. Linux PSI reports the share of time at least one task stalled for memory during the last 10 seconds." } ] },
            titleSection("Memory"),
            about("Physical memory, swap and Linux pressure with binary memory values labelled in GiB.") ] }

        case "net": return { sections: [
            { title: "Display", cols: 1, fields: [
                { key: "showHistory", label: "Show the throughput graph", type: "toggle", dflt: true },
                { key: "historyWindow", label: "History window", type: "segmented", dflt: "2m",
                  visibleWhen: { key: "showHistory", equals: true, dflt: true }, options: [
                    { value: "1m", label: "1 minute" },
                    { value: "2m", label: "2 minutes" },
                    { value: "5m", label: "5 minutes" } ] },
                { key: "showDetails", label: "Show link details", type: "toggle", dflt: true,
                  help: "Roomy and expanded views show interface identity, link state, speed, totals, drops and errors." },
                { key: "unit", label: "Units", type: "segmented", dflt: "bytes", options: [
                    { value: "bytes", label: "MB/s" },
                    { value: "bits",  label: "Mbps" } ] },
                { key: "scaleMode", label: "Graph scale", type: "segmented", dflt: "auto", options: [
                    { value: "auto", label: "Automatic" },
                    { value: "fixed", label: "Fixed" } ] },
                { key: "fixedScaleMbps", label: "Fixed graph maximum", type: "slider",
                  min: 10, max: 10000, step: 10, suffix: " Mbps", dflt: 100,
                  visibleWhen: { key: "scaleMode", equals: "fixed", dflt: "auto" } },
                graphStyleField({ key: "showHistory", equals: true, dflt: true }) ] },
            { title: "Interfaces", cols: 1, fields: [
                { key: "interfaceName", label: "Traffic source", type: "select", dflt: "",
                  help: "Aggregate counts physical links once. Select exactly one VPN, bridge, container, or virtual interface to inspect it without also counting its encapsulated physical traffic.",
                  options: [ { value: "", label: "Aggregate physical links" } ] } ] },
            titleSection("Network"),
            about("Kernel network throughput by interface, with explicit virtual-link inclusion, link details, totals and resettable session peaks. No traffic is generated and loopback is never counted.") ] }

        case "disk": return { sections: [
            { title: "Display", cols: 1, fields: [
                { key: "mountPath", label: "Filesystem", type: "select", dflt: "/",
                  help: "Choose a discovered local or network filesystem. An unplugged selection stays visible so it can reconnect.",
                  options: [ { value: "/", label: "/ · Root filesystem" } ] },
                { key: "showActivity", label: "Show read and write activity", type: "toggle", dflt: true,
                  help: "Uses Linux block-device counters when the selected filesystem exposes them." },
                { key: "warnPercent", label: "Warn above", type: "slider", min: 50, max: 99, step: 1, suffix: " %", dflt: 90,
                  help: "The widget names Healthy, Warning, and Critical states. Critical begins at least one point above this threshold." } ] },
            titleSection("Disk"),
            about("Capacity, filesystem identity and supported read/write activity for a discovered mount. Values come from statvfs and Linux block-device counters.") ] }

        case "sensors": return { sections: [
            { title: "GPU source", cols: 1, fields: [
                { key: "gpuDevice", label: "GPU device", type: "select", dflt: "auto",
                  help: "Automatic follows the preferred DRM device. Choose a discovered GPU to keep utilization, temperature, power, and fan rows on one device.",
                  options: [ { value: "auto", label: "Automatic" } ] } ] },
            { title: "Rows to show", cols: 1, fields: [
                { key: "showCpu", label: "CPU load", type: "toggle", dflt: true },
                { key: "showGpu", label: "GPU load", type: "toggle", dflt: true },
                { key: "showRam", label: "Memory", type: "toggle", dflt: true },
                { key: "showDisk", label: "Disk usage", type: "toggle", dflt: true },
                { key: "showTemps", label: "Temperatures", type: "toggle", dflt: true,
                  help: "CPU and GPU temperature bars with configurable warning levels." },
                { key: "showGpuPower", label: "GPU power", type: "toggle", dflt: true },
                { key: "showGpuFan", label: "GPU fan", type: "toggle", dflt: true } ] },
            { title: "Order", cols: 1, fields: [
                { key: "rowOrder", label: "Row order", type: "reorder", dflt: [],
                  help: "Use the large arrow buttons to move rows. Stable row IDs are saved so translated labels will not break the order.",
                  options: [
                    { value: "cpu", label: "CPU load" },
                    { value: "gpu", label: "GPU load" },
                    { value: "ram", label: "Memory" },
                    { value: "disk", label: "Disk usage" },
                    { value: "cpu_temp", label: "CPU temperature" },
                    { value: "gpu_temp", label: "GPU temperature" },
                    { value: "gpu_power", label: "GPU power" },
                    { value: "gpu_fan", label: "GPU fan" } ] } ] },
            { title: "Warning levels", cols: 2, fields: [
                { key: "warnCpu", label: "CPU load", type: "slider", min: 50, max: 95, step: 1, suffix: " %", dflt: 85 },
                { key: "warnGpu", label: "GPU load", type: "slider", min: 50, max: 95, step: 1, suffix: " %", dflt: 85 },
                { key: "warnRam", label: "Memory", type: "slider", min: 50, max: 95, step: 1, suffix: " %", dflt: 85 },
                { key: "warnDisk", label: "Disk", type: "slider", min: 50, max: 99, step: 1, suffix: " %", dflt: 90 },
                { key: "warnCpuTemp", label: "CPU temperature", type: "slider", min: 50, max: 100, step: 1, suffix: " °C", dflt: 80 },
                { key: "warnGpuTemp", label: "GPU temperature", type: "slider", min: 50, max: 100, step: 1, suffix: " °C", dflt: 80 } ] },
            titleSection("Sensors"),
            about("A configurable hardware board for CPU, GPU, memory, disk, temperatures, and supported GPU power and fan telemetry. Small layouts disclose hidden rows; every shown row names its state and source.") ] }

        case "weather": return { sections: [
            { title: "Location", cols: 1, fields: [
                { key: "locationMode", label: "Location setup", type: "segmented", dflt: "search", options: [
                    { value: "search", label: "Search city" },
                    { value: "manual", label: "Manual coordinates" } ] },
                { key: "place", label: "Place name", type: "text", placeholder: "Vienna, AT",
                  visibleWhen: { key: "locationMode", equals: "search", dflt: "search" } },
                { type: "action", actionLabel: "Look up this city and set coordinates", action: "geocode",
                  visibleWhen: { key: "locationMode", equals: "search", dflt: "search" } } ] },
            { title: "Coordinates", cols: 2, fields: [
                { key: "lat", label: "Latitude", type: "number", min: -90, max: 90, step: 0.01,
                  visibleWhen: { key: "locationMode", equals: "manual", dflt: "search" } },
                { key: "lon", label: "Longitude", type: "number", min: -180, max: 180, step: 0.01,
                  visibleWhen: { key: "locationMode", equals: "manual", dflt: "search" } } ] },
            { title: "Units & forecast", cols: 1, fields: [
                { key: "units", label: "Temperature", type: "segmented", dflt: "celsius", options: [
                    { value: "celsius", label: "°C" },
                    { value: "fahrenheit", label: "°F" } ] },
                { key: "windUnits", label: "Wind speed", type: "segmented", dflt: "kmh", options: [
                    { value: "kmh", label: "km/h" },
                    { value: "mph", label: "mph" },
                    { value: "ms", label: "m/s" } ] },
                { key: "precipitationUnits", label: "Precipitation", type: "segmented", dflt: "mm", options: [
                    { value: "mm", label: "mm" },
                    { value: "inch", label: "in" } ] },
                { key: "forecastDays", label: "Forecast days", type: "slider", min: 3, max: 7, step: 1, suffix: " days", dflt: 4 } ] },
            titleSection("Weather"),
            about("Current conditions, humidity, wind, precipitation, sunrise, sunset and a multi-day forecast from Open-Meteo. A location is required before any request is sent. Tile and overlay share one volatile provider result.") ] }

        case "focus": return { sections: [
            { title: "Custom lengths", cols: 2, desc: "Used when you pick the “Custom” preset on the timer.", fields: [
                { key: "workMin", label: "Focus", type: "number", min: 1, max: 180, step: 1, suffix: " min", dflt: 25,
                  visibleWhen: { key: "preset", equals: "custom", dflt: "classic" } },
                { key: "breakMin", label: "Short break", type: "number", min: 1, max: 60, step: 1, suffix: " min", dflt: 5,
                  visibleWhen: { key: "preset", equals: "custom", dflt: "classic" } },
                { key: "longBreakMin", label: "Long break", type: "number", min: 1, max: 90, step: 1, suffix: " min", dflt: 15,
                  visibleWhen: { key: "preset", equals: "custom", dflt: "classic" } },
                { key: "longBreakEvery", label: "Long break after", type: "number", min: 2, max: 12, step: 1, suffix: " sessions", dflt: 4,
                  visibleWhen: { key: "preset", equals: "custom", dflt: "classic" } } ] },
            { title: "Behaviour", cols: 1, fields: [
                { key: "behaviorProfile", label: "Profile", type: "segmented", dflt: "custom", options: [
                    { value: "calm", label: "Calm" }, { value: "momentum", label: "Momentum" },
                    { value: "custom", label: "Custom" } ],
                  help: "Calm removes points, nudges and celebrations. Custom uses the switches below." },
                { key: "autoStartBreak", label: "Auto-start the break", type: "toggle", dflt: false },
                { key: "autoStartFocus", label: "Auto-start focus after a break", type: "toggle", dflt: false },
                { key: "notifyWhenHidden", label: "Notify when an off-page phase finishes", type: "toggle", dflt: false,
                  help: "Shows a persistent Hub alert and a high-priority desktop notification when this timer is not on the visible Hub screen." } ] },
            { title: "Momentum (ADHD-friendly)", cols: 1,
              desc: "Small wins to keep you going.", fields: [
                { key: "dailyGoal", label: "Daily focus goal", type: "number", min: 1, max: 16, step: 1, suffix: " sessions", dflt: 4,
                  help: "Progress toward this shows on the timer; hitting it triggers a bigger celebration." },
                { key: "celebrate", label: "Celebrate finished sessions", type: "toggle", dflt: true,
                  help: "A burst of colour + a “nice!” when a focus session completes - a little dopamine hit." },
                { key: "rewardPoints", label: "Earn reward points", type: "toggle", dflt: true,
                  help: "Rack up points per session (bonus for hitting your goal)." },
                { key: "showNudges", label: "Show encouraging nudges", type: "toggle", dflt: true },
                { key: "breakSuggestions", label: "Suggest a break activity", type: "toggle", dflt: true } ] },
            titleSection("Focus Timer"),
            about("A Pomodoro focus timer. Pick a preset or set custom lengths; it keeps running even when this view is closed.") ] }

        case "tasks": return { sections: [
            { title: "Display", cols: 1, fields: [
                { key: "hideCompleted", label: "Hide completed tasks", type: "toggle", dflt: false },
                { key: "displayMode", label: "Show", type: "segmented", dflt: "all", options: [
                    { value: "all", label: "All" }, { value: "top3", label: "First 3" } ],
                  help: "First 3 shows the first three items in your current ordering." },
                { key: "behaviorProfile", label: "Completion style", type: "segmented", dflt: "custom", options: [
                    { value: "calm", label: "Calm" }, { value: "momentum", label: "Celebrate" },
                    { value: "custom", label: "Custom" } ] },
                { key: "celebrate", label: "Celebrate clearing the list", type: "toggle", dflt: true,
                  help: "A little burst when you check off the last task." } ] },
            titleSection("Tasks"),
            about("Edit the checklist directly in the live widget preview. It keeps stable task identity, supports ordering and undo, and offers a focused First 3 view. Clearing completed tasks requires confirmation.") ] }

        case "hydration": return { sections: [
            { title: "Goal", cols: 1, fields: [
                { key: "goal", label: "Daily goal", type: "number", min: 1, max: 20, step: 1, suffix: " glasses", dflt: 8 },
                { key: "glassMl", label: "Serving size", type: "number", min: 100, max: 1000, step: 50, suffix: " ml", dflt: 250,
                  help: "Each tap adds this amount. The display can convert the total to fluid ounces." },
                { key: "unit", label: "Volume", type: "segmented", dflt: "ml", options: [
                    { value: "ml", label: "ml / L" }, { value: "oz", label: "fl oz" } ] },
                { key: "showStreak", label: "Show goal streak", type: "toggle", dflt: true },
                { key: "celebrate", label: "Celebrate reaching the goal", type: "toggle", dflt: true } ] },
            titleSection("Hydration"),
            about("Count configurable servings toward a daily goal, show ml/L or fluid ounces, and undo the most recent adjustment. This is a personal tracker, not medical advice.") ] }

        case "break": return { sections: [
            { title: "Reminder", cols: 1, fields: [
                { key: "intervalMin", label: "Remind me every", type: "slider", min: 5, max: 120, step: 5, suffix: " min", dflt: 30 },
                { key: "snoozeMin", label: "Snooze", type: "number", min: 1, max: 30, step: 1, suffix: " min", dflt: 5 },
                { key: "message", label: "Reminder message", type: "text", placeholder: "Time to stretch!", dflt: "" },
                { key: "showSuggestion", label: "Suggest a break activity", type: "toggle", dflt: true,
                  help: "Shows a small “try this” idea when a break is due." },
                { key: "priorityAlertEnabled", label: "Show a full-screen alert", type: "toggle", dflt: true,
                  help: "Keeps a large visual reminder on the Hub until you acknowledge, snooze, or dismiss it." },
                { key: "notifyWhenHidden", label: "Notify when due off-page", type: "toggle", dflt: false,
                  help: "Shows a persistent high-priority desktop notification when this reminder is not on the visible Hub screen." } ] },
            { title: "Active schedule", cols: 2, fields: [
                { key: "workStartHour", label: "Start", type: "hour", min: 0, max: 23, dflt: 9 },
                { key: "workEndHour", label: "End", type: "hour", min: 0, max: 23, dflt: 17 },
                { key: "workDays", label: "Weekdays", type: "weekdays", dflt: "1,2,3,4,5",
                  help: "Choose active shift-start days. Overnight schedules continue into the following morning." } ] },
            titleSection("Break Reminder"),
            about("A persistent break timer with structured active hours, overnight schedules, snooze, a full-screen Hub alert, reduced-motion-safe feedback, and optional off-page desktop notifications.") ] }

        case "countdown": return { sections: [
            { title: "Event", cols: 2, fields: [
                { key: "label", label: "Label", type: "text", placeholder: "Vacation" },
                { key: "date", label: "Date", type: "date" },
                { key: "targetHour", label: "Hour", type: "hour", min: 0, max: 23, step: 1, dflt: 0 },
                { key: "targetMinute", label: "Minute", type: "segmented", dflt: 0, options: [
                    { value: 0, label: ":00" }, { value: 15, label: ":15" },
                    { value: 30, label: ":30" }, { value: 45, label: ":45" } ],
                  help: "Uses the device-local timezone shown in the live preview." } ] },
            { title: "Behaviour", cols: 1, fields: [
                { key: "repeatYearly", label: "Repeats every year", type: "toggle", dflt: false,
                  help: "For birthdays and anniversaries - counts down to the next occurrence and never shows “passed”." },
                { key: "leapDayPolicy", label: "February 29 in non-leap years", type: "segmented",
                  dflt: "nextLeap", visibleWhen: { key: "repeatYearly", equals: true, dflt: false },
                  options: [
                    { value: "nextLeap", label: "Next leap year" },
                    { value: "feb28", label: "February 28" },
                    { value: "mar1", label: "March 1" } ],
                  help: "Applies only when the selected recurring date is February 29." },
                { key: "precision", label: "Precision", type: "segmented", dflt: "days", options: [
                    { value: "days", label: "Days" }, { value: "auto", label: "Auto" } ],
                  help: "Auto switches to hours inside the final 48 hours." },
                { key: "afterEvent", label: "After the event", type: "segmented", dflt: "passed", options: [
                    { value: "passed", label: "Show passed" }, { value: "complete", label: "Show complete" } ] } ] },
            titleSection("Countdown"),
            about("Counts down to a device-local date and time, with optional hour precision, yearly repetition, milestone context and a calm completed state. System notifications remain future shared lifecycle work.") ] }

        case "eod": return { sections: [
            { title: "Work hours", cols: 2, fields: [
                { key: "startHour", label: "Start hour", type: "hour", min: 0, max: 23, step: 1, dflt: 9 },
                { key: "endHour", label: "End hour", type: "hour", min: 0, max: 23, step: 1, dflt: 17 },
                { key: "startMinute", label: "Start minute", type: "segmented", dflt: 0, options: [
                    { value: 0, label: ":00" }, { value: 15, label: ":15" },
                    { value: 30, label: ":30" }, { value: 45, label: ":45" } ] },
                { key: "endMinute", label: "End minute", type: "segmented", dflt: 0, options: [
                    { value: 0, label: ":00" }, { value: 15, label: ":15" },
                    { value: 30, label: ":30" }, { value: 45, label: ":45" } ] },
                { key: "allowOvernight", label: "Allow overnight window", type: "toggle", dflt: false,
                  help: "Lets the direct controls place the end before the start for a shift up to 12 hours." },
                { key: "workDays", label: "Active weekdays", type: "weekdays", dflt: "0,1,2,3,4,5,6",
                  help: "Choose the weekdays on which the work window starts. Overnight shifts remain assigned to their start day." } ] },
            { title: "Display", cols: 1, fields: [
                { key: "progressStyle", label: "Progress style", type: "segmented", dflt: "bar", options: [
                    { value: "bar", label: "Bar" },
                    { value: "ring", label: "Ring" } ] },
                { key: "showPercent", label: "Show percent complete", type: "toggle", dflt: true } ] },
            titleSection("End of Day"),
            about("How much of the configured work window is left, including quarter-hour precision, optional overnight shifts and scheduled weekdays.") ] }

        case "habit": return { sections: [
            { title: "Habit", cols: 1, fields: [
                { key: "name", label: "Habit name", type: "text", placeholder: "Meditate", dflt: "",
                  help: "What you're building a streak for." },
                { key: "cadence", label: "Schedule", type: "segmented", dflt: "daily", options: [
                    { value: "daily", label: "Daily" }, { value: "weekdays", label: "Weekdays" },
                    { value: "weekends", label: "Weekends" }, { value: "custom", label: "Custom" } ] },
                { key: "activeDays", label: "Custom weekdays", type: "weekdays", dflt: "1,2,3,4,5",
                  visibleWhen: { key: "cadence", equals: "custom" },
                  help: "Choose every day on which this habit should be active." },
                { key: "paused", label: "Pause this habit", type: "toggle", dflt: false },
                { key: "showStreak", label: "Show streak and personal best", type: "toggle", dflt: true },
                { key: "celebrate", label: "Celebrate check-ins", type: "toggle", dflt: true } ] },
            titleSection("Habit"),
            about("Track a daily, weekday, weekend or custom schedule. Pause without deleting history, or hide streaks for a low-pressure check-in.") ] }

        // The three E5 wellness widgets deliberately expose a SMALL surface. The
        // best-supported finding in the neurodivergent-UI literature is "make it
        // adjustable, default to the OS, keep the adjustment surface small" - not
        // "add a calm mode". So each gets the one field that changes behaviour and
        // nothing decorative; there is no "hide the red" toggle because there is no
        // red to hide.
        case "meds": return { sections: [
            { title: "Doses", cols: 1, fields: [
                { key: "scheduleItems", label: "", type: "medSchedule", dflt: [],
                  legacyKey: "schedule",
                  migrationMarker: "scheduleFormat",
                  help: "Add each dose, choose a valid time, and select the weekdays on "
                        + "which it should appear. Existing text schedules are migrated "
                        + "when you first edit them." } ] },
            { title: "Timing", cols: 1, fields: [
                { key: "dueWindowMin", label: "Stays “due” for", type: "slider",
                  min: 15, max: 240, step: 15, suffix: " min", dflt: 60,
                  help: "After this long, a dose you haven't marked simply goes quiet. "
                        + "It is never shown as missed or overdue." },
                { key: "notifyWhenHidden", label: "Notify when a dose becomes due",
                  type: "toggle", dflt: false,
                  help: "Shows a persistent Hub alert and high-priority desktop notification while this Hub screen is not visible." },
                { key: "notificationDetails", label: "Include the dose name in notifications",
                  type: "toggle", dflt: false,
                  visibleWhen: { key: "notifyWhenHidden", equals: true },
                  help: "Off keeps lock-screen notifications private. On may expose the "
                        + "dose name to desktop notification history." } ] },
            titleSection("Meds"),
            about("A reminder of what you take and when, and a one-tap record of what you've "
                  + "marked as taken today. It resets each morning.\n\n"
                  + "It only knows what you tap - it cannot know what you actually took, so it "
                  + "never nags, never turns red and never counts a dose as missed. Tap again "
                  + "to undo a mistaken mark. This is not medical software: don't rely on it "
                  + "as your only record, and never use it to decide whether to re-dose. "
                  + "Medication names and marks are stored locally in plaintext and may be "
                  + "included in device backups. Diagnostics redact medication settings.") ] }

        case "braindump": return { sections: [
            { title: "Display", cols: 1, fields: [
                { key: "showTimes", label: "Show the time each thought arrived", type: "toggle", dflt: true,
                  help: "Turn off for a plain list." } ] },
            titleSection("Braindump"),
            about("A place to offload a thought in one line so you can stop holding it. Type "
                  + "and press Enter - newest first. Different from Quick Note: that is one "
                  + "page you keep, this is a queue you empty. The newest 100 are kept. "
                  + "Expanded mode lets you edit or remove individual thoughts. Clear All "
                  + "requires confirmation, and the last capture, edit, removal, or clear can "
                  + "be undone from either the Hub or Manager.") ] }

        case "routine": return { sections: [
            { title: "Steps", cols: 1, fields: [
                { key: "routineItems", label: "", type: "routineSteps", dflt: [],
                  legacyKey: "steps", migrationMarker: "routineFormat",
                  help: "Add, rename, remove, and reorder steps with the controls below. "
                        + "Existing line-based routines migrate on the first edit." },
                { key: "activeDays", label: "Active weekdays", type: "weekdays",
                  dflt: "0,1,2,3,4,5,6",
                  help: "Choose the days on which this routine is active. Other days are calm rest days." } ] },
            titleSection("Routine"),
            about("A schedule-aware checklist. Everything unticks itself at midnight.\n\n"
                  + "Nothing is remembered from one day to the next - no streak, no history, "
                  + "no score. A skipped day costs you nothing, because there is nothing to "
                  + "lose. If you do want a streak, use the Habit widget instead.") ] }

        case "nownext": return { sections: [
            { title: "Subscription", cols: 1, fields: [
                { key: "url", label: "ICS calendar URL", type: "secret", placeholder: "https://…/basic.ics",
                  help: "This URL can grant access to private calendar data. Prefer ${env:CALENDAR_ICS_URL} or file:/run/secrets/calendar-url so only a reference is stored. Legacy literal URLs remain supported in the private 0600 config file." },
                { type: "info", text: "Use the same secret reference as Calendar to share one in-memory provider result and avoid duplicate polling." } ] },
            { title: "Meeting context", cols: 1, fields: [
                { key: "bufferMin", label: "Starts soon window", type: "slider",
                  min: 0, max: 120, step: 5, suffix: " min", dflt: 10,
                  help: "Upcoming events inside this window use a calm Starts soon label." } ] },
            titleSection("Now / Next"),
            about("Just two things: what's on now, and what's next. Reads the same ICS feed as "
                  + "the Calendar widget and refreshes every 15 minutes through the app's "
                  + "egress gate. HTTPS meeting links from URL or location fields get a Join action.") ] }

        case "rightnow": return { sections: [
            { title: "Your one thing", cols: 1, fields: [
                { key: "text", label: "", type: "text", placeholder: "Finish the report" },
                { key: "completionStyle", label: "When finished", type: "segmented", dflt: "celebrate", options: [
                    { value: "calm", label: "Calm" }, { value: "celebrate", label: "Celebrate" } ] } ] },
            titleSection("Right Now"),
            about("The single most important thing you're doing right now, with optional elapsed context and a calm completion style.") ] }

        case "notes": return { sections: [
            titleSection("Quick Note"),
            about("Edit directly in the live widget preview. This local scratchpad has debounced autosave, visible save state, ten-step text recovery and confirmation before clearing.") ] }

        case "httpjson": return { sections: [
            { title: "Data source", cols: 1, fields: [
                { key: "url", label: "URL", type: "text", placeholder: "https://api.example.com/status",
                  help: "An endpoint that returns JSON. Polled on the interval below." },
                { key: "jsonPath", label: "JSON path", type: "text", placeholder: "data.value  ·  items[0].name",
                  help: "Dot/bracket path to the value inside the response. Blank = the whole body." },
                { key: "authToken", label: "Bearer token", type: "secret", placeholder: "(optional)", dflt: "",
                  help: "Sent as “Authorization: Bearer …”. Leave blank if the endpoint is public. " +
                        "A token typed here is stored in plain text in config.toml - prefer a reference: " +
                        "${env:MY_TOKEN} reads an environment variable, file:/path/to/token reads a file. " +
                        "Either is resolved only when the request is made and never written to disk." },
                { type: "action", actionLabel: "Test connection", action: "testConnection",
                  help: "Checks network policy, HTTP status, response size, JSON parsing and the configured path without changing the saved reading." } ] },
            { title: "Display", cols: 1, fields: [
                { key: "mode", label: "Show as", type: "segmented", dflt: "value", options: [
                    { value: "value", label: "Value" },
                    { value: "gauge", label: "Gauge" },
                    { value: "list",  label: "List" } ] },
                { key: "unit", label: "Unit", type: "text", placeholder: "ms · % · req/s", dflt: "",
                  visibleWhen: { key: "mode", notEquals: "list", dflt: "value" } },
                { key: "decimals", label: "Decimal places", type: "number", min: 0, max: 6, step: 1, dflt: 1,
                  visibleWhen: { key: "mode", notEquals: "list", dflt: "value" },
                  help: "Applies to numeric value and gauge readings." },
                { key: "gaugeMax", label: "Gauge maximum", type: "number", min: 1, max: 1000000, step: 1, dflt: 100,
                  visibleWhen: { key: "mode", equals: "gauge", dflt: "value" },
                  help: "Full-scale value for the gauge ring." },
                { key: "listMax", label: "List rows", type: "number", min: 1, max: 12, step: 1, dflt: 5,
                  visibleWhen: { key: "mode", equals: "list", dflt: "value" },
                  help: "At most this many. A smaller tile shows fewer - it never overflows, and never shows more than you ask for." },
                graphStyleField({ key: "mode", notEquals: "list", dflt: "value" }),
                graphScaleField({ key: "mode", notEquals: "list", dflt: "value" }) ] },
            { title: "Thresholds (colour)", cols: 2,
              desc: "Colour the value amber at “Warn” and red at “Critical”. Leave blank to disable.", fields: [
                { key: "warnAt", label: "Warn ≥", type: "text", placeholder: "80", dflt: "",
                  visibleWhen: { key: "mode", notEquals: "list", dflt: "value" } },
                { key: "critAt", label: "Critical ≥", type: "text", placeholder: "95", dflt: "",
                  visibleWhen: { key: "mode", notEquals: "list", dflt: "value" } } ] },
            { title: "Polling", cols: 1, fields: [
                { key: "pollSec", label: "Refresh every", type: "slider", min: 5, max: 3600, step: 5, suffix: " s", dflt: 60 } ] },
            titleSection("HTTP / JSON"),
            about("Connect any JSON endpoint. Pull one value out by path and show it as a number, gauge or list. All requests go through the app's egress gate - nothing else phones home.") ] }

        case "kpi": return { sections: [
            { title: "Source", cols: 1, fields: [
                { key: "source", label: "Read from", type: "segmented", dflt: "http", options: [
                    { value: "http", label: "URL" },
                    { value: "file", label: "Local file" } ] },
                { key: "url", label: "URL", type: "text", placeholder: "https://api.example.com/metric",
                  visibleWhen: { key: "source", equals: "http", dflt: "http" },
                  help: "Used when the source is “URL”. Returns JSON or a bare number." },
                { key: "filePath", label: "File path", type: "text", placeholder: "/run/metrics/queue_depth",
                  visibleWhen: { key: "source", equals: "file", dflt: "http" },
                  help: "Used when the source is “Local file”. For safety, files must be under /run, /var/run, /proc or /sys. Responses are bounded to 1 MiB." },
                { key: "jsonPath", label: "JSON path", type: "text", placeholder: "stats.count", dflt: "",
                  help: "Path to the number inside a JSON response. Blank if the body is already just a number." },
                { key: "authToken", label: "Bearer token", type: "secret", placeholder: "(optional)", dflt: "",
                  visibleWhen: { key: "source", equals: "http", dflt: "http" },
                  help: "Used with the “URL” source. A token typed here is stored in plain text in " +
                        "config.toml - prefer ${env:MY_TOKEN} or file:/path/to/token, which are read " +
                        "only when the request is made and never written to disk." },
                { type: "action", actionLabel: "Test source", action: "testConnection",
                  help: "Checks the network policy or secure local-file boundary, parses the configured path, and previews formatting and threshold state without replacing the saved reading." } ] },
            { title: "Presentation", cols: 1, fields: [
                { key: "label", label: "Label", type: "text", placeholder: "Queue depth", dflt: "" },
                { key: "prefix", label: "Prefix", type: "text", placeholder: "$", dflt: "" },
                { key: "unit", label: "Suffix / unit", type: "text", placeholder: "ms · %", dflt: "" },
                { key: "decimals", label: "Decimal places", type: "number", min: 0, max: 6, step: 1, dflt: 1 },
                { key: "target", label: "Target", type: "text", placeholder: "(optional)", dflt: "",
                  help: "Shows the current difference from this target." },
                graphStyleField(),
                graphScaleField() ] },
            { title: "Thresholds (colour)", cols: 1,
              desc: "The widget shows Normal, Warning, or Critical text as well as colour. Warning must come before Critical in the selected direction.", fields: [
                { key: "invert", label: "Lower is worse", type: "toggle", dflt: false,
                  help: "For uptime, budget or headroom - turns the colour on when the value drops BELOW the thresholds." },
                { key: "warnAt", label: "Warn", type: "text", placeholder: "80", dflt: "" },
                { key: "critAt", label: "Critical", type: "text", placeholder: "95", dflt: "" } ] },
            { title: "Polling", cols: 1, fields: [
                { key: "pollSec", label: "Refresh every", type: "slider", min: 5, max: 3600, step: 5, suffix: " s", dflt: 60 } ] },
            titleSection("KPI"),
            about("One number that matters - from a URL or a local file - with a label, unit and colour-coded thresholds. A local file reads without any network access.") ] }

        case "calendar": return { sections: [
            { title: "Subscription", cols: 1, fields: [
                { key: "url", label: "ICS calendar URL", type: "secret", placeholder: "https://…/basic.ics",
                  help: "This URL can grant access to private calendar data. Prefer ${env:CALENDAR_ICS_URL} or file:/run/secrets/calendar-url so only a reference is stored. Legacy literal URLs remain supported in the private 0600 config file." },
                { type: "info", text: "Use the secret iCal/ICS subscription URL from Google, Outlook or Nextcloud. The resolved value is used only inside the network request and is omitted from diagnostics." } ] },
            { title: "Display", cols: 1, fields: [
                { key: "maxEvents", label: "Events to show", type: "number", min: 1, max: 12, step: 1, dflt: 5,
                  help: "At most this many. A smaller tile shows fewer - it never overflows, and never shows more than you ask for." } ] },
            titleSection("Calendar"),
            about("Upcoming events from a calendar you subscribe to. Requests use the shared egress gate. The active widget reports freshness and any unsupported timezone or recurrence rules instead of silently claiming complete coverage.") ] }

        case "media": return { sections: [
            { title: "Player", cols: 1, fields: [
                { key: "preferredPlayer", label: "Preferred MPRIS player", type: "text",
                  placeholder: "Auto (currently playing)",
                  help: "Leave blank to follow whichever player is active. Enter the player identity shown in the widget status, such as spotify or vlc, to keep this widget attached to it." },
                { type: "info", text: "The Hub discovers players through the local MPRIS session bus. If your preferred player is unavailable, the currently playing player is used." } ] },
            titleSection("Now Playing"),
            about("Controls a local MPRIS player. It reports discovery, connection and empty-track states separately, shows elapsed and total time, and only enables transport or seeking when the player supports them. Remote artwork remains blocked until it can use the shared network policy.") ] }

        case "quote": return { sections: [
            { title: "Source", cols: 1, fields: [
                { key: "category", label: "Category", type: "segmented", dflt: "focus", options: [
                    { value: "focus", label: "Focus" },
                    { value: "stoic", label: "Stoic" },
                    { value: "humor", label: "Humour" },
                    { value: "kindness", label: "Kindness" },
                    { value: "custom", label: "My own" } ] },
                { key: "customText", label: "Your own quotes", type: "textarea",
                  visibleWhen: { key: "category", equals: "custom", dflt: "focus" },
                  placeholder: "One per line; use Quote | Author for attribution",
                  help: "Used when the category is My own. Blank or malformed libraries are shown as configuration issues and never replaced by bundled quotes. Only add text you have permission to display." } ] },
            { title: "Attribution", cols: 1, fields: [
                { key: "authorDisplay", label: "Author line", type: "segmented", dflt: "auto",
                  options: [
                    { value: "auto", label: "When provided" },
                    { value: "always", label: "Always" },
                    { value: "hide", label: "Hide" } ],
                  help: "Always uses Unknown author when a custom quote has no attribution. Micro tiles keep the author hidden to protect quote legibility." } ] },
            titleSection("Daily Quote"),
            about("A fresh local quote each day. Every bundled entry carries its source and rights status; Shuffle picks another without network access.") ] }

        default: return { sections: [ titleSection(type) ] }
        }
    }
}
