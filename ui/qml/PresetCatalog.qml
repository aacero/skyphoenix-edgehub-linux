import QtQuick

// ─────────────────────────────────────────────────────────────────────────
// PresetCatalog - the curated library of ready-made "screens".
//
// EACH PRESET IS ONE SCREEN = EXACTLY ONE PAGE, designed for a single workflow.
// A "screen" is applied by ADDING it as one new page (DashboardStore.appendPreset)
// - it never overwrites the user's other pages. (The first-run wizard and
// "reset to default" still compose a few screens into a fresh document via
// DashboardStore.seed()/buildBundle().) Each preset is a small, purposeful set of
// widgets (never overloaded), with a fitting background/motion character and
// (optionally) which widget categories to feature in the add-picker.
// `buildDoc(id)` materializes a full ui_state document (with fresh tile ids).
//
// A tile spec is { type, size?, settings? }. `size` is a name from WidgetSizes and
// MUST be one the type declares in WidgetCatalog; omit it for the type's default.
// Appearance only sets the preset's *character* (bgStyle / animatedBg / glow),
// never themeMode, accent, or accessibility preferences, so applying a preset preserves the user's
// chosen colours; appendPreset carries the character as a per-page background so it
// rides on the page, not the global look. Every tile `type` MUST exist in
// WidgetCatalog (a QML test asserts both).
//
// THE ONE PAGE FITS ON ONE SCREEN. Its tiles may not exceed WidgetSizes.longHalves
// (6 half-cells) along the long axis - three `1x1` fill a screen exactly, and a
// hero `1x1.5` plus a `1x1.5` companion does too. Hard product constraint, asserted
// by tst_preset_catalog against the real WidgetPacker: the scroll axis follows the
// long axis, which in landscape is the SwipeView's own swipe axis, so an overflowing
// page would fight the page swipe. A page that fits never scrolls.
//
// Data-connected screens (developer, homelab, trading-desk, analyst, enterprise)
// carry HTTP/JSON + KPI tiles with a purposeful `title` but a BLANK url/filePath:
// the endpoint is the one thing only the user can supply, so the tile ships as a
// labelled, self-explaining slot ("CI status" → "Add a URL in settings") rather
// than a wrong guess. Nothing polls until it is connected.
// ─────────────────────────────────────────────────────────────────────────
QtObject {
    id: presets

    // Character presets kept DRY.
    readonly property var _calm:  ({ bgStyle: "none",  animatedBg: false, glow: false })
    readonly property var _ambient: ({ bgStyle: "orbs",  animatedBg: true,  glow: true })
    readonly property var _tech:  ({ bgStyle: "grid",  animatedBg: true,  glow: true })
    readonly property var _soft:  ({ bgStyle: "orbs",  animatedBg: false, glow: true })

    property var items: [
        // ── Local, no online config needed ──────────────────────────────────
        // `focus` tops out at 1x1.5 - the hero timer is the largest it renders.
        { id: "calm-focus", title: "Calm Focus", icon: "flower-lotus",
          blurb: "Deep work, quietly. A big timer beside your one thing.",
          purpose: "Protect a deep-work block while keeping the single intention that matters visible.",
          setup: "Ready immediately. Choose a timer profile or write your current focus when you want to personalize it.",
          appearance: _calm, surfaced: ["Focus"],
          pages: [ { name: "Focus", tiles: [
              { type: "focus", size: "1x1.5" }, { type: "rightnow", size: "1x1.5" } ] } ] },

        { id: "notes-streak", title: "Notes & Streak", icon: "note-pencil",
          blurb: "A scratchpad that saves itself, next to your daily streak.",
          purpose: "Capture thoughts without leaving the flow and keep one daily habit visible beside them.",
          setup: "Ready immediately. Name the habit in its widget settings when you are ready.",
          appearance: _calm, surfaced: ["Focus"],
          pages: [ { name: "Notes", tiles: [
              { type: "notes", size: "1x1.5" }, { type: "habit", size: "1x1.5" } ] } ] },

        { id: "home-ambient", title: "Home", icon: "house",
          blurb: "A beautiful desk companion - the time and the weather, up front.",
          purpose: "Turn the Edge into an everyday desk companion with the current time and local conditions.",
          setup: "Set your weather location once. The clock works immediately.",
          appearance: _ambient, surfaced: ["Time", "Info"],
          pages: [ { name: "Home", tiles: [
              { type: "clock", size: "1x1.5" }, { type: "weather", size: "1x1.5" } ] } ] },

        { id: "ambient", title: "Ambient", icon: "moon-stars",
          blurb: "When it's not working hard - what's playing and tonight's moon.",
          purpose: "Give idle desk time a calm now-playing view with tonight's moon phase beside it.",
          setup: "Moon phase works immediately. Start any MPRIS-compatible media player for live playback details.",
          appearance: _ambient, surfaced: ["Media", "Time"],
          pages: [ { name: "Ambient", tiles: [
              { type: "media", size: "1x1.5" }, { type: "moon", size: "1x1" } ] } ] },

        { id: "minimal", title: "Minimalist", icon: "sparkle",
          blurb: "Almost nothing. A beautiful clock, the weather, and the moon.",
          purpose: "Keep only the three quiet facts that matter at a glance: time, local weather, and moon phase.",
          setup: "Set your weather location once. Time and moon phase work immediately.",
          appearance: _calm, surfaced: ["Time"],
          pages: [ { name: "Home", tiles: [
              { type: "clock", size: "1x1.5" },
              { type: "weather", size: "0.5x1" }, { type: "moon", size: "0.5x1" } ] } ] },

        { id: "health", title: "Health & Routine", icon: "heartbeat",
          blurb: "Gentle nudges toward a good day - water, breaks, and a daily streak.",
          purpose: "Keep small wellbeing intentions visible without turning them into a noisy productivity dashboard.",
          setup: "Ready immediately. Adjust water, break, and habit goals to match your routine.",
          appearance: _soft, surfaced: ["Focus"],
          pages: [ { name: "Health", tiles: [
              { type: "hydration", size: "1x1" }, { type: "break", size: "1x1" },
              { type: "habit", size: "1x1" } ] } ] },

        { id: "creator", title: "Creator / Media", icon: "film-slate",
          blurb: "For making things - now-playing front and centre, and a focus timer.",
          purpose: "Keep the soundtrack and a protected creative work block together in one studio screen.",
          setup: "The timer works immediately. Start an MPRIS-compatible media player for live playback details.",
          appearance: _ambient, surfaced: ["Media", "Focus"],
          pages: [ { name: "Studio", tiles: [
              { type: "media", size: "1x1.5" }, { type: "focus", size: "1x1.5" } ] } ] },

        { id: "study", title: "Student / Study", icon: "books",
          blurb: "Study sessions that stick with a focus timer, today's tasks, and an exam countdown.",
          purpose: "Plan a study session, keep the next tasks visible, and maintain awareness of the exam date.",
          setup: "Set the exam date in Countdown. The focus timer and tasks are ready immediately.",
          appearance: _soft, surfaced: ["Focus", "Info"],
          pages: [ { name: "Study", tiles: [
              { type: "focus", size: "1x1" }, { type: "tasks", size: "1x1" },
              { type: "countdown", size: "1x1", settings: { label: "Exam", date: "", repeatYearly: false } } ] } ] },

        { id: "productivity", title: "Productivity", icon: "check-circle",
          blurb: "Get things done - a focus timer beside today's tasks.",
          purpose: "Run a focused work block while keeping the concrete task list visible beside it.",
          setup: "Ready immediately. Add tasks and start the timer directly on the Edge.",
          appearance: _soft, surfaced: ["Focus", "Time"],
          pages: [ { name: "Focus", tiles: [
              { type: "focus", size: "1x1.5" }, { type: "tasks", size: "1x1.5" } ] } ] },

        { id: "remote-work", title: "Remote Work", icon: "briefcase",
          blurb: "The working day - today's tasks and how much of the workday is left.",
          purpose: "Anchor a remote workday around today's commitments and a calm view of remaining work time.",
          setup: "Ready with a 09:00 to 17:00 workday. Adjust work hours and weekdays if needed.",
          appearance: _calm, surfaced: ["Focus", "Info"],
          pages: [ { name: "Day", tiles: [
              { type: "tasks", size: "1x1.5" },
              { type: "eod", size: "1x1.5", settings: { startHour: 9, endHour: 17, progressStyle: "bar" } } ] } ] },

        { id: "gaming", title: "Gaming Cockpit", icon: "game-controller",
          blurb: "Rig telemetry beside your game - the GPU front and centre, CPU and memory.",
          purpose: "Keep the graphics card prominent while retaining compact CPU and memory context during play.",
          setup: "Uses local Linux telemetry immediately. Available GPU details depend on what the active driver exposes.",
          appearance: _tech, surfaced: ["System", "Media"],
          pages: [ { name: "GPU", tiles: [
              { type: "gpu", size: "1x1.5" },
              { type: "cpu", size: "0.5x1" }, { type: "ram", size: "0.5x1" } ] } ] },

        { id: "system-monitor", title: "System Core", icon: "gauge",
          blurb: "The classic - CPU, GPU and memory at a glance.",
          purpose: "Provide a balanced health overview of the three core compute resources.",
          setup: "Ready immediately using local Linux metrics. No network connection is required.",
          appearance: _tech, surfaced: ["System"],
          pages: [ { name: "Core", tiles: [
              { type: "cpu", size: "1x1" }, { type: "gpu", size: "1x1" },
              { type: "ram", size: "1x1" } ] } ] },

        { id: "system-io", title: "System I/O", icon: "compass",
          blurb: "The other half - network, disk, and temperatures.",
          purpose: "Show movement and thermal context that complements the core CPU, GPU, and memory screen.",
          setup: "Ready immediately using local Linux metrics. Sensor rows depend on available hardware sources.",
          appearance: _tech, surfaced: ["System"],
          pages: [ { name: "I/O", tiles: [
              { type: "net", size: "1x1" }, { type: "disk", size: "1x1" },
              { type: "sensors", size: "1x1" } ] } ] },

        // ── Screens with a labelled online slot (blank endpoint → self-explains) ─
        { id: "day-plan", title: "Day Plan", icon: "calendar-dots",
          blurb: "The time and your agenda - connect a calendar (ICS URL) in settings.",
          purpose: "Keep the current time beside the upcoming agenda so the shape of the day stays visible.",
          setup: "Connect an ICS calendar URL in Calendar settings. The clock works immediately.",
          appearance: _calm, surfaced: ["Time", "Info"],
          pages: [ { name: "Agenda", tiles: [
              { type: "clock", size: "1x1" }, { type: "calendar", size: "1x2" } ] } ] },

        { id: "developer", title: "Developer", icon: "code",
          blurb: "Your build and a number you watch - CI status and open PRs. Add your URLs.",
          purpose: "Turn build status and one engineering delivery number into a focused development signal board.",
          setup: "Connect your CI feed and pull-request KPI endpoints. Nothing polls until you add those URLs.",
          appearance: _tech, surfaced: ["Data", "System"],
          pages: [ { name: "Dev", tiles: [
              { type: "httpjson", size: "1x1.5", settings: { title: "CI status", mode: "list", listMax: 5, pollSec: 120 } },
              { type: "kpi", size: "1x1.5", settings: { title: "Open PRs", label: "Open PRs", pollSec: 300 } } ] } ] },

        { id: "homelab", title: "Homelab Ops", icon: "hard-drives",
          blurb: "Watch the lab - service uptime and container health. Add your endpoints.",
          purpose: "Keep service availability and container health visible without opening the full monitoring stack.",
          setup: "Connect your uptime and container endpoints. Nothing polls until you add those URLs.",
          appearance: _tech, surfaced: ["Data", "System"],
          pages: [ { name: "Services", tiles: [
              { type: "httpjson", size: "1x1.5", settings: { title: "Uptime", mode: "list", listMax: 6, pollSec: 60 } },
              { type: "httpjson", size: "1x1.5", settings: { title: "Containers", mode: "list", listMax: 6, pollSec: 60 } } ] } ] },

        { id: "trading-desk", title: "Trading Desk", icon: "chart-line-up",
          blurb: "Two clocks and your P&L - local and New York, beside one headline number.",
          purpose: "Keep local and New York market time beside the one portfolio number you monitor most closely.",
          setup: "Connect the P&L KPI endpoint. Both clocks work immediately.",
          appearance: _calm, surfaced: ["Time", "Data"],
          pages: [ { name: "Desk", tiles: [
              // The two zones sit side by side - one glance, two clocks.
              { type: "clock", size: "0.5x1" },
              { type: "clock", size: "0.5x1", settings: { title: "New York", customZone: true, zoneId: "America/New_York" } },
              { type: "kpi", size: "1x1.5", settings: { title: "P&L", label: "P&L", unit: "%", pollSec: 60 } } ] } ] },

        { id: "analyst", title: "Analyst / Data", icon: "chart-line-down",
          blurb: "A calm data corner - two headline numbers (one from a local file) and a feed.",
          purpose: "Combine two headline measures with one monitoring feed for a compact analytical overview.",
          setup: "Connect the HTTP KPI and monitoring feed, then choose a local file for the daily total.",
          appearance: _calm, surfaced: ["Data", "Time"],
          pages: [ { name: "Data", tiles: [
              { type: "kpi", size: "1x1.5", settings: { title: "Headline metric", label: "Headline metric", source: "http", pollSec: 300 } },
              // The file source reads a local path - a fully offline KPI (no egress).
              { type: "kpi", size: "0.5x1", settings: { title: "Daily total", label: "Daily total", source: "file", pollSec: 60 } },
              { type: "httpjson", size: "0.5x1", settings: { title: "Monitoring", mode: "value", pollSec: 120 } } ] } ] },

        { id: "enterprise", title: "Team / Enterprise", icon: "buildings",
          blurb: "A clean managed baseline - your workday and one approved team number.",
          purpose: "Provide a restrained team baseline with workday progress and one organization-approved measure.",
          setup: "Connect the approved team KPI endpoint. Workday progress is ready with default office hours.",
          appearance: _calm, surfaced: ["Info", "Data"],
          pages: [ { name: "Team", tiles: [
              { type: "eod", size: "1x1.5" },
              // "Approved KPI/monitoring tiles only" - a KPI the org points at its
              // own endpoint. The egress primitives stay governed by NetHub's allowlist.
              { type: "kpi", size: "1x1.5", settings: { title: "Team KPI", label: "Team KPI", pollSec: 300 } } ] } ] }
    ]

    // ── API (mirrors WidgetCatalog) ─────────────────────────────────────────
    function list() { return items }
    function def(id) {
        for (var i = 0; i < items.length; i++) if (items[i].id === id) return items[i]
        return null
    }
    function has(id) { return def(id) !== null }

    // Materialize a preset into a full ui_state document with fresh, unique tile
    // ids. Appearance is the preset's character + a `presetSurface` hint; per-tile
    // `settings` are copied under the generated id. The store's _normaliseDoc
    // hardens the result, so a malformed preset can never corrupt the dashboard.
    //
    // A tile carries its `size` straight through. Presets used to emit the old
    // {w,h} spans and lean on the store's migration to name them, which is lossy by
    // construction (old `h` was a ratio against siblings, a size is a fraction of
    // the screen) - it mapped `h:2` to `1x2` and, for a type that does not declare
    // it, dropped the tile to its default. A preset is authored, not migrated: it
    // names the size it means, and the test asserts the type declares it.
    function buildDoc(id) {
        var p = def(id)
        if (!p) return null
        var seq = 0
        var pages = []
        var settings = ({})
        for (var pi = 0; pi < p.pages.length; pi++) {
            var src = p.pages[pi]
            var tiles = []
            for (var ti = 0; ti < src.tiles.length; ti++) {
                var t = src.tiles[ti]
                var tid = t.type + "-" + (++seq)
                var tile = { "id": tid, "type": t.type }
                if (t.size) tile.size = t.size
                tiles.push(tile)
                if (t.settings) settings[tid] = JSON.parse(JSON.stringify(t.settings))
            }
            pages.push({ "name": src.name, "tiles": tiles })
        }
        var appearance = p.appearance ? JSON.parse(JSON.stringify(p.appearance)) : ({})
        if (p.surfaced && p.surfaced.length) appearance.presetSurface = p.surfaced.slice()
        return { "version": 1, "appearance": appearance, "settings": settings, "pages": pages }
    }

    // Compose several single-page presets into ONE document - the "a few starter
    // screens" a fresh install / wizard begins with. Each preset contributes its
    // one page (with its character as a per-page background so the pages differ),
    // tile ids stay unique across the bundle, and per-tile settings are merged. The
    // document's global appearance is left EMPTY: a bundle spans characters, so the
    // user's/global look governs the whole Edge, not any one screen's character.
    function buildBundle(ids) {
        var seq = 0
        var pages = []
        var settings = ({})
        for (var b = 0; b < ids.length; b++) {
            var p = def(ids[b])
            if (!p) continue
            for (var pi = 0; pi < p.pages.length; pi++) {
                var src = p.pages[pi]
                var tiles = []
                for (var ti = 0; ti < src.tiles.length; ti++) {
                    var t = src.tiles[ti]
                    var tid = t.type + "-" + (++seq)
                    var tile = { "id": tid, "type": t.type }
                    if (t.size) tile.size = t.size
                    tiles.push(tile)
                    if (t.settings) settings[tid] = JSON.parse(JSON.stringify(t.settings))
                }
                var page = { "name": src.name, "tiles": tiles }
                if (p.appearance && p.appearance.bgStyle)
                    page.bg = { "style": p.appearance.bgStyle }
                pages.push(page)
            }
        }
        if (!pages.length) return null
        return { "version": 1, "appearance": ({}), "settings": settings, "pages": pages }
    }
}
