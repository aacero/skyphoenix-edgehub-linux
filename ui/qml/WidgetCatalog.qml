import QtQuick

// ─────────────────────────────────────────────────────────────────────────
// WidgetCatalog - the registry of available widgets.
//
// Each entry is defined ONCE here and reused everywhere: the dashboard grid,
// the expanded overlay, and the edit-mode "add widget" picker. `source` is the
// qrc path to the widget's QML file (all widgets live under qrc:/qml/ via
// qml.qrc aliases). `defaults` seeds a fresh instance's persisted settings.
//
// SIZES - `sizes` lists the sizes (names from WidgetSizes) a widget can honestly
// render, and `dflt` is what a fresh instance gets. Every entry declares the `1x1`
// baseline: a widget that cannot do the default size is a bug. The list is a
// CAPABILITY claim, not a menu of everything that would technically lay out, and it
// is judged against two hard facts:
//   • The screen ROTATES. A size is (short × long), so declaring one means the
//     widget works in BOTH of its shapes - `0.5x1` is a ~348x853 column in portrait
//     and a ~853x306 banner in landscape.
//   • Bigger is not better. `1x3` is the WHOLE screen (~770x2560): only content that
//     actually grows into it earns it. Almost nothing here does - a lone ring or a
//     glyph at full screen is a stretched card, not a feature. Likewise `0.5x0.5`
//     (1/12, ~348x409 portrait / ~423x306 landscape) is where the 36px chrome header
//     and any fixed control row stop fitting.
// Comments below explain the non-obvious ABSENCES only.
// ─────────────────────────────────────────────────────────────────────────
QtObject {
    id: catalog

    // `category` groups the picker; icons are SVGs resolved by `type` via AppIcon.
    property var items: [
        // System / hardware (real metrics from the Rust core)
        // The gauge tiles are a ring + a 48-sample sparkline: real content up to half
        // the screen, nothing that fills two thirds of it.
        { type: "cpu",     title: "CPU",      category: "System", source: "qrc:/qml/CpuWidget.qml",     defaults: {},
          sizes: ["0.5x0.5", "0.5x1", "1x0.5", "1x1", "1x1.5"], dflt: "1x1" },
        { type: "gpu",     title: "GPU",      category: "System", source: "qrc:/qml/GpuWidget.qml",     defaults: {},
          sizes: ["0.5x0.5", "0.5x1", "1x0.5", "1x1", "1x1.5"], dflt: "1x1" },
        { type: "ram",     title: "Memory",   category: "System", source: "qrc:/qml/RamWidget.qml",     defaults: {},
          sizes: ["0.5x0.5", "0.5x1", "1x0.5", "1x1", "1x1.5"], dflt: "1x1" },
        { type: "net",     title: "Network",  category: "System", source: "qrc:/qml/NetWidget.qml",     defaults: {},
          sizes: ["0.5x0.5", "0.5x1", "1x0.5", "1x1", "1x1.5"], dflt: "1x1" },
        { type: "disk",    title: "Disk",     category: "System", source: "qrc:/qml/DiskWidget.qml",    defaults: {},
          sizes: ["0.5x0.5", "0.5x1", "1x0.5", "1x1", "1x1.5"], dflt: "1x1" },
        // The sensor board starts at half-screen sizes. Its shortest projection
        // prioritizes four rows and discloses the hidden count; larger footprints
        // add temperature, power, fan, source, and semantic-state context.
        { type: "sensors", title: "Sensors",  category: "System", source: "qrc:/qml/SensorsWidget.qml", defaults: {},
          sizes: ["0.5x1", "1x0.5", "1x1", "1x1.5"], dflt: "1x1" },

        // Installed-package count + system age, read from the package manager's
        // own database (never mutated). Both are ONE number plus a caption - the
        // same content shape as `countdown`, so the same sizes: they read fine
        // down to 1/12 of the screen and have nothing to grow into past half of
        // it (a lone number at 1x2 is a stretched card, not more information).
        { type: "packages",     title: "Packages",   category: "System", source: "qrc:/qml/PackagesWidget.qml",
          defaults: { showDistro: true },
          sizes: ["0.5x0.5", "0.5x1", "1x0.5", "1x1"], dflt: "1x1" },
        { type: "sinceinstall", title: "System Age", category: "System", source: "qrc:/qml/SinceInstallWidget.qml",
          defaults: { ageUnit: "auto", showDate: true },
          sizes: ["0.5x0.5", "0.5x1", "1x0.5", "1x1"], dflt: "1x1" },
        { type: "systems",      title: "Systems",    category: "System", source: "qrc:/qml/SystemsWidget.qml",
          defaults: { hosts: "localhost:9100", defaultPort: 9100, pollSec: 10, warnCpu: 85, warnRam: 85, warnDisk: 90 },
          sizes: ["0.5x0.5", "0.5x1", "1x0.5", "1x1", "1x1.5", "1x2", "1x3"], dflt: "1x1" },

        // Time / ambient
        { type: "clock",   title: "Clock",       category: "Time", source: "qrc:/qml/ClockWidget.qml",   defaults: {},
          sizes: ["0.5x0.5", "0.5x1", "1x0.5", "1x1", "1x1.5"], dflt: "1x1" },
        { type: "analog",  title: "Analog Clock",category: "Time", source: "qrc:/qml/AnalogClockWidget.qml", defaults: {},
          sizes: ["0.5x0.5", "0.5x1", "1x0.5", "1x1", "1x1.5"], dflt: "1x1" },
        // Rich Moon layouts add the cycle position, next phase dates, and optional
        // local rise/set context, so 1x1.5 has distinct useful content.
        { type: "moon",    title: "Moon Phase",  category: "Time", source: "qrc:/qml/MoonWidget.qml",    defaults: {},
          sizes: ["0.5x0.5", "0.5x1", "1x0.5", "1x1", "1x1.5"], dflt: "1x1" },

        // Focus / productivity (persisted user data)
        // The ring is min(w,h)-scaled with the Start/Skip row anchored over its
        // bottom, so it needs a roughly SQUARE box; every half size is a wide-short
        // or narrow-tall shape in one orientation, which collides the two.
        { type: "focus",    title: "Focus Timer", category: "Focus", source: "qrc:/qml/FocusWidget.qml",    defaults: { preset: "classic", phase: "work", running: false, endEpoch: 0, pausedRemaining: 1500, doneToday: 0, day: "" },
          sizes: ["1x1", "1x1.5"], dflt: "1x1" },
        // Unbounded list → genuinely fills any height. Not 1/12: the 40px add-field +
        // ＋ button would leave ~2 visible rows.
        { type: "tasks",    title: "Tasks",       category: "Focus", source: "qrc:/qml/TasksWidget.qml",    defaults: { items: [] },
          sizes: ["0.5x1", "1x0.5", "1x1", "1x1.5", "1x2", "1x3"], dflt: "1x1" },
        // One focus, capped at 3 lines.
        { type: "rightnow", title: "Right Now",   category: "Focus", source: "qrc:/qml/RightNowWidget.qml", defaults: { text: "" },
          sizes: ["0.5x0.5", "0.5x1", "1x0.5", "1x1", "1x1.5"], dflt: "1x1" },
        { type: "notes",    title: "Quick Note",  category: "Focus", source: "qrc:/qml/NotesWidget.qml",    defaults: { text: "" },
          sizes: ["0.5x0.5", "0.5x1", "1x0.5", "1x1", "1x1.5", "1x2", "1x3"], dflt: "1x1" },
        // Was "the heatmap is expanded-only … a tile shows a streak number + one
        // button, whatever room it is given" - untrue since wave 2b: the 28-day map
        // is earned by any tile but the 1/12. 1x1.5 (wave 2c) goes further and is a
        // genuinely different card, not the baseline stretched: it earns the
        // best-ever record line, and its map transposes to 4x7 to fit the tall
        // 696x1229 projection (7x4 beside the streak column at 1269x612 landscape).
        // Not 1x2/1x3: the history is pruned to 28 days, so past a half screen there
        // is nothing further to grow into and the map would just inflate.
        { type: "habit",    title: "Habit Streak",category: "Focus", source: "qrc:/qml/HabitWidget.qml",     defaults: { checkins: [] },
          sizes: ["0.5x0.5", "0.5x1", "1x0.5", "1x1", "1x1.5"], dflt: "1x1" },
        // Today's glasses only - no history is kept, so there is nothing to grow into.
        { type: "hydration",title: "Hydration",   category: "Focus", source: "qrc:/qml/HydrationWidget.qml", defaults: { goal: 8, count: 0, day: "" },
          sizes: ["0.5x0.5", "0.5x1", "1x0.5", "1x1"], dflt: "1x1" },
        // A countdown + two buttons.
        { type: "break",    title: "Break Reminder", category: "Focus", source: "qrc:/qml/BreakWidget.qml",  defaults: { intervalMin: 30 },
          sizes: ["0.5x0.5", "0.5x1", "1x0.5", "1x1"], dflt: "1x1" },

        // Everyday / wellness (E5). All three are user-data widgets whose content
        // is a LIST that genuinely grows with height, and all three are control
        // surfaces you tap - so they share a size story: no 1/12 tile (the chrome
        // header plus a real ≥52px touch row does not fit one), and no full screen
        // (they are meant to be short; a 12-line routine at 1x3 is a wall, which is
        // the thing these widgets exist to avoid).
        // Doses + a "mark taken" target. Half sizes carry the one focused dose, the
        // taller ones carry the day's schedule.
        { type: "meds",     title: "Meds",        category: "Focus", source: "qrc:/qml/MedsWidget.qml",
          defaults: { schedule: "", scheduleItems: [], dueWindowMin: 60,
                      notifyWhenHidden: false, notificationDetails: false,
                      taken: [], takenDay: "", notified: [], notifiedDay: "" },
          sizes: ["0.5x1", "1x0.5", "1x1", "1x1.5", "1x2"], dflt: "1x1" },
        // Capture queue. The add field + ＋ button is a fixed ~40px row in both
        // orientations of every declared size, which is what rules out 0.5x0.5.
        { type: "braindump",title: "Braindump",   category: "Focus", source: "qrc:/qml/BraindumpWidget.qml",
          defaults: { entries: [], showTimes: true },
          sizes: ["0.5x1", "1x0.5", "1x1", "1x1.5", "1x2"], dflt: "1x1" },
        // Daily checklist. Same shape as meds: a list of tappable rows.
        { type: "routine",  title: "Routine",     category: "Focus", source: "qrc:/qml/RoutineWidget.qml",
          defaults: { steps: "", routineItems: [], done: [], day: "" },
          sizes: ["0.5x1", "1x0.5", "1x1", "1x1.5", "1x2"], dflt: "1x1" },

        // Media
        // Art + title/artist + transport; the compact row keeps a 52px play target.
        { type: "media",    title: "Now Playing", category: "Media", source: "qrc:/qml/MediaWidget.qml", defaults: {},
          sizes: ["0.5x0.5", "0.5x1", "1x0.5", "1x1", "1x1.5"], dflt: "1x1" },

        // Data (generic, connect-anything primitives - devs, homelab, enterprise)
        // Value/gauge/list. Its largest mode is hard-capped at 12 list rows, which
        // stops short of filling the whole screen.
        { type: "httpjson", title: "HTTP / JSON", category: "Data", source: "qrc:/qml/HttpJsonWidget.qml",
          defaults: { url: "", jsonPath: "", pollSec: 60, mode: "value", unit: "", gaugeMax: 100, listMax: 5, authToken: "", warnAt: "", critAt: "" },
          sizes: ["0.5x0.5", "0.5x1", "1x0.5", "1x1", "1x1.5", "1x2"], dflt: "1x1" },
        // The one widget whose POINT is a single number read across a room, so the
        // full screen is the intent rather than a stretch.
        { type: "kpi",      title: "KPI",         category: "Data", source: "qrc:/qml/KpiWidget.qml",
          defaults: { source: "http", url: "", filePath: "", jsonPath: "", label: "", unit: "", pollSec: 60, authToken: "", invert: false, warnAt: "", critAt: "" },
          sizes: ["0.5x0.5", "0.5x1", "1x0.5", "1x1", "1x1.5", "1x2", "1x3"], dflt: "1x1" },
        { type: "grafana",  title: "Grafana / Metrics", category: "Data", source: "qrc:/qml/GrafanaWidget.qml",
          defaults: { url: "http://localhost:9090", query: "node_load1", rangeSec: 3600, pollSec: 15, chartType: "area", unit: "", unitScale: "auto", fillGlow: true, showMinMax: true, warnAt: "", critAt: "", authToken: "" },
          sizes: ["0.5x0.5", "0.5x1", "1x0.5", "1x1", "1x1.5", "1x2", "1x3"], dflt: "1x1" },

        // Info
        // An agenda grows with height, but maxEvents caps at 12 - enough for two
        // thirds, not the whole screen. Not 1/12: "Up next" + the event rows.
        { type: "calendar", title: "Calendar",    category: "Info", source: "qrc:/qml/CalendarWidget.qml",  defaults: { url: "" },
          sizes: ["0.5x1", "1x0.5", "1x1", "1x1.5", "1x2"], dflt: "1x1" },
        // Exactly TWO events, ever - so unlike `calendar` it has nothing to grow
        // into past half the screen: 1x2 would be two lines of text and a lot of
        // air. Not 1/12 either: NOW and NEXT are two labelled blocks, and dropping
        // one to fit would make it a worse `calendar` rather than a Now/Next.
        { type: "nownext",  title: "Now / Next",  category: "Info", source: "qrc:/qml/NowNextWidget.qml",  defaults: { url: "" },
          sizes: ["0.5x1", "1x0.5", "1x1"], dflt: "1x1" },
        // The forecast request asks for `current` + `daily` only (never `hourly`) and
        // forecastDays caps at 7, so the content is a reading plus a few day columns.
        { type: "weather",  title: "Weather",     category: "Info", source: "qrc:/qml/WeatherWidget.qml",  defaults: {},
          sizes: ["0.5x0.5", "0.5x1", "1x0.5", "1x1", "1x1.5"], dflt: "1x1" },
        { type: "countdown",title: "Countdown",   category: "Info", source: "qrc:/qml/CountdownWidget.qml", defaults: { label: "", date: "", repeatYearly: false },
          sizes: ["0.5x0.5", "0.5x1", "1x0.5", "1x1"], dflt: "1x1" },
        { type: "eod",      title: "End of Day",  category: "Info", source: "qrc:/qml/EndOfDayWidget.qml",  defaults: { startHour: 9, endHour: 17, progressStyle: "bar" },
          sizes: ["0.5x0.5", "0.5x1", "1x0.5", "1x1", "1x1.5"], dflt: "1x1" },
        // One quote, capped at 4 lines collapsed.
        { type: "quote",    title: "Daily Quote", category: "Info", source: "qrc:/qml/QuoteWidget.qml",    defaults: { category: "focus", customText: "" },
          sizes: ["0.5x0.5", "0.5x1", "1x0.5", "1x1"], dflt: "1x1" }
    ]

    // One-line descriptions shown in the expanded (full-screen) view header.
    readonly property var _desc: ({
        "cpu": "Live processor load and temperature, straight from the kernel.",
        "gpu": "Discrete GPU utilization and temperature (AMD Radeon).",
        "ram": "How much system memory is in use right now.",
        "net": "Live upload and download throughput across your network interfaces.",
        "disk": "How full your root filesystem is.",
        "sensors": "CPU, GPU, memory, disk and temperatures together at a glance.",
        "packages": "How many packages are installed, counted from your package manager's own database. Read-only - nothing here installs, removes or updates anything.",
        "sinceinstall": "System age from a confirmed installer record or the earliest visible package-history record, with source and confidence shown.",
        "clock": "A locale-aware digital clock with DST-correct IANA zones, fixed offsets, and up to three additional world clocks.",
        "analog": "A classic analog clock face.",
        "moon": "A deterministic moon phase, illumination, cycle position, and optional local rise and set times.",
        "focus": "A Pomodoro focus timer with work and break cycles. Pick a preset and press Start - it keeps running even if you close this view.",
        "tasks": "A simple checklist. Type a task and press Add; tap the circle to complete, ✕ to remove.",
        "rightnow": "The single most important thing you're doing right now. Type it and press Save.",
        "notes": "A quick scratchpad - type anything and it saves automatically.",
        "habit": "Build a daily streak. Press Check in each day you do the habit.",
        "hydration": "Count glasses of water toward a daily goal; use − / + to adjust.",
        "break": "A schedule-aware break timer with snooze, weekday controls, and optional off-page notifications.",
        "meds": "Your weekday-aware dose schedule and the entries you've marked as taken today. Optional private-by-default reminders can notify you when this Hub screen is hidden. It tracks taps, not pills, so an unmarked dose stays neutral.",
        "braindump": "Capture a thought immediately, keep the newest at the top, and edit, remove, clear, or undo from any connected Hub or Manager view. The bounded queue always discloses its 100-item limit.",
        "routine": "A calm daily checklist with reorderable, rename-safe steps and structured active weekdays. It resets each morning, exposes hidden rows, and keeps no cross-day score.",
        "nownext": "What's on right now and what's coming up next, from an ICS calendar you subscribe to.",
        "httpjson": "Poll any URL and show a value from its JSON - as a number, a gauge, or a list. Colour-codes against thresholds.",
        "kpi": "One headline number from a URL or a local file, with a label, unit and colour-coded thresholds.",
        "calendar": "Upcoming events from a calendar you subscribe to. Paste an ICS URL to connect it.",
        "weather": "Current conditions and a multi-day forecast. Type a city and look up its coordinates.",
        "countdown": "Counts the days to a date you choose. Set a label and date below.",
        "eod": "How much of your workday is left. Adjust your start and end hours.",
        "media": "Now Playing - controls Spotify, YouTube Music, or any player on this machine.",
        "quote": "A fresh bit of motivation each day.",
        "systems": "Live CPU, memory, disk, load, uptime and network throughput across your systems via Prometheus node_exporter."
    })

    // LOSS-001: content and progress that must survive a configuration reset.
    // These keys may only be removed through the separately confirmed personal-
    // data action. Labels are deliberately concrete so confirmation copy states
    // exactly what will be erased instead of using a vague "all data" warning.
    readonly property var _personalData: ({
        "focus": { keys: ["phase", "running", "endEpoch", "pausedRemaining", "doneToday", "day", "points"],
                   label: "timer state, today's completed sessions, and points" },
        "tasks": { keys: ["items", "nextId"], label: "tasks and their ordering" },
        "rightnow": { keys: ["text", "startedAt", "finishedToday", "day"],
                      label: "current focus and today's completion count" },
        "notes": { keys: ["text", "history"], label: "note text and recovery history" },
        "habit": { keys: ["checkins", "streak", "bestStreak", "lastCheckinDay"],
                   label: "check-ins and streak history" },
        "hydration": { keys: ["count", "day", "streak", "lastGoalDay", "previousCount"],
                       label: "today's hydration record and streak history" },
        "break": { keys: ["running", "endEpoch", "pausedRemaining", "scheduleSuspended",
                           "snoozed", "due", "breaksToday", "day"],
                   label: "timer state and today's acknowledged breaks" },
        "meds": { keys: ["schedule", "scheduleItems", "scheduleFormat", "taken", "takenDay",
                          "notified", "notifiedDay"],
                  label: "medication schedule and user-marked records" },
        "braindump": { keys: ["entries", "undoEntries", "undoLabel"],
                       label: "captured thoughts and their undo recovery state" },
        "routine": { keys: ["steps", "routineItems", "routineFormat", "done", "day"],
                     label: "routine steps and today's marks" }
    })

    // ── Tier-0 user widgets (E3) ─────────────────────────────────────────────
    // Validated user-widget entries (same shape as `items`), registered at
    // runtime by the hub's UserWidgetCatalog loader. Default EMPTY: the Manager
    // and the test harness never set it, so this registry stays a plain data
    // table everywhere else. def() consults shipped `items` FIRST, so a user
    // entry can never shadow a shipped type - shipped always wins.
    property var userItems: []

    function def(type) {
        for (var i = 0; i < items.length; i++)
            if (items[i].type === type) return items[i]
        for (var u = 0; u < userItems.length; u++)
            if (userItems[u].type === type) return userItems[u]
        return null
    }
    // Widget QML lives at ui/qml/widgets/ in the tree, but qml.qrc aliases it
    // FLAT into the bundle (alias="qml/CpuWidget.qml" -> qml/widgets/CpuWidget.qml).
    // Under qmltestrunner there is no bundle at all, so every "qrc:/qml/*.qml"
    // in the table above resolved to nothing and EVERY TILE SILENTLY FAILED TO
    // LOAD. Both QML suites were asserting over empty Loaders: the offscreen
    // tier could not see widget rendering, and tst_gui_shell_nav_edit.qml says
    // so outright ("Widget TILES do not render ... never widget pixels").
    //
    // Consequence: widgets were tested ONLY in isolation, at a sizeClass the
    // test supplied by hand, and the shell was tested with NO widgets in it.
    // Nothing rendered a widget inside the real shell at a size the real layout
    // computed - which is exactly the seam the Manager/hub sizeClassFor
    // divergence lived in, and why it could only ever be found by eye.
    //
    // Same resolution rule as Theme._fontsDir: bundle when bundled, tree when
    // running from the tree. Same bytes either way.
    readonly property bool _fromBundle:
        Qt.resolvedUrl(".").toString().indexOf("qrc:") === 0

    function source(type) {
        var d = def(type)
        if (!d || !d.source) return ""
        var s = "" + d.source
        // User widgets carry their own file: URL - never rewrite those.
        if (_fromBundle || s.indexOf("qrc:/qml/") !== 0) return s
        return Qt.resolvedUrl("widgets/" + s.substring(s.lastIndexOf("/") + 1)).toString()
    }
    function title(type)  { var d = def(type); return d ? d.title : type }
    function desc(type) {
        // typeof guard (not truthiness): a hostile/odd type like "constructor"
        // must resolve to "", never to something inherited from the prototype.
        var s = _desc[type]
        if (typeof s === "string") return s
        var d = def(type)
        return (d && typeof d.description === "string") ? d.description : ""
    }
    // Picker/header icon for a type. Shipped entries resolve by TYPE from the
    // bundled qrc set; user entries carry their own file (`source`, untinted)
    // or a bundled fallback glyph (`name`) - never a blank tile, because the
    // shipped-icon lint cannot see user directories.
    function iconFor(type) {
        var d = def(type)
        if (d && d.iconSource) return { name: "", source: d.iconSource }
        if (d && d.iconName)   return { name: d.iconName, source: "" }
        return { name: type, source: "" }
    }
    // Deep clone so callers can freely mutate the seed without aliasing the
    // catalog's live object (or every future instance seeded from it).
    function defaults(type) { var d = def(type); return d ? JSON.parse(JSON.stringify(d.defaults)) : ({}) }

    // ── Sizes ────────────────────────────────────────────────────────────────
    // All three route through def(), which SCANS `items` rather than indexing an
    // object: layouts arrive from config.toml and the Manager socket, so a type of
    // "constructor"/"__proto__" must resolve to "unknown", never to something
    // inherited from Object.prototype.

    // The sizes this type can render, smallest → largest. [] for an unknown type -
    // callers must treat that as "no such widget", not as "any size is fine".
    // Copied so a caller cannot mutate the catalog's live list (cf. defaults()).
    function sizesFor(type) { var d = def(type); return (d && d.sizes) ? d.sizes.slice() : [] }

    function supports(type, size) { return sizesFor(type).indexOf(size) >= 0 }

    // What a fresh instance gets. Falls back to the baseline for an unknown type so
    // a bad type still lands on a placeable tile rather than a sizeless one. The
    // literal keeps this registry free of any dependency on WidgetSizes (it is a
    // plain data table, reused as-is by the Manager); tst_widget_catalog asserts it
    // equals WidgetSizes.baseline, so the two cannot drift apart unnoticed.
    function defaultSize(type) { var d = def(type); return (d && d.dflt) ? d.dflt : "1x1" }

    function personalDataKeys(type) {
        var d = _personalData[type]
        return d && d.keys ? d.keys.slice() : []
    }
    function personalDataLabel(type) {
        var d = _personalData[type]
        return d && d.label ? d.label : ""
    }
    function hasPersonalData(type) { return personalDataKeys(type).length > 0 }

    // Distinct category names, in declaration order - shipped first, then any
    // categories only user widgets introduce.
    function categories() {
        var seen = [], out = []
        var all = items.concat(userItems)
        for (var i = 0; i < all.length; i++) {
            if (seen.indexOf(all[i].category) === -1) { seen.push(all[i].category); out.push(all[i].category) }
        }
        return out
    }
    function inCategory(cat) {
        var out = []
        var all = items.concat(userItems)
        for (var i = 0; i < all.length; i++) if (all[i].category === cat) out.push(all[i])
        return out
    }
}
