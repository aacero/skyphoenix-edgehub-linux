import QtQuick

// Theme - THE single source of design-system tokens (colors, category tones,
// spacing, radii, touch targets, icon sizes, typography, motion) + the
// theme/accent appliers. Consumed by BOTH the Edge hub (main.qml) and the
// companion Manager (clone preview) and the QML test harness, so the two apps
// can never visually drift. The four runtime knobs (glass/glow/reduceMotion/
// accent) are own-properties here; the hub aliases its persisted values onto them.
QtObject {
    id: t

    property real glassOpacity: 0.55
    property bool showWidgetGlow: false
    property bool reduceMotion: false
    property string accentName: "blue"
    // Transient background-style preview (Manager only): when non-empty, the
    // Manager's EdgeClone renders this animated style instead of the stored one, so
    // hovering a background chip previews it live without committing. Never
    // persisted, never set by the hub (defaults empty).
    property string previewBgStyle: ""

    // ── Reduce motion: OS signal vs. explicit choice ─────────────────────────
    // `reduceMotion` above is the PERSISTED config flag. Two more inputs decide
    // what actually renders; `effectiveReduceMotion` is what the motion tokens
    // consume. Kept separate (rather than folded into `reduceMotion`) because
    // main.qml aliases `reduceMotion` onto the persisted value - collapsing them
    // would let an OS signal write itself back into the user's config.
    //
    // Qt cannot report the OS setting: there is NO reduce-motion style hint in
    // Qt 6 - verified on 6.11 (`Qt.styleHints.useReducedMotion === undefined`;
    // the only a11y hint is `accessibility.contrastPreference`, itself 6.10+),
    // and 6.7 (CI) exposes strictly fewer hints. So the platform read (GNOME
    // `enable-animations`, XDG desktop-portal) must be injected here by the host
    // app. Default false = "no OS signal", which is also the safe CI value.
    property bool systemReduceMotion: false

    // "auto" (default) | "on" | "off" - an EXPLICIT choice, and it beats the OS.
    // Precedence: explicit > OS > legacy flag.
    //   "auto" → no explicit choice yet, so the OS signal (or the persisted
    //            `reduceMotion` flag) may turn motion off.
    //   "off"  → motion stays ON even when the OS asks to reduce it.
    // "off" deliberately overrides the OS because this hub is a dedicated
    // appliance, not a desktop window: a user who re-enabled motion *on this
    // device* must not have that silently undone by an unrelated global desktop
    // a11y setting. Mirrors the web, where prefers-reduced-motion is a default
    // an app-level setting is allowed to override.
    property string reduceMotionPreference: "auto"

    readonly property bool effectiveReduceMotion:
        reduceMotionPreference === "on" ? true
      : reduceMotionPreference === "off" ? false
      : (reduceMotion || systemReduceMotion)

    property color backgroundColor: "#0D1117"
    property color backgroundColor2: "#0A0E14"
    property color backgroundColor3: "#0A0E14"
    property color cardBackground: "#161B22"
    property color cardBackgroundAlt: "#1C222B"
    property color cardBorder: "#30363D"
    property color textPrimary: "#E6EDF3"
    property color textSecondary: "#8B949E"
    property color textTertiary: "#6E7681"
    property color accent: "#58A6FF"
    property color accent2: "#7EE787"
    property color warning: "#D29922"
    property color error: "#F85149"
    property color success: "#3FB950"

    property color catSystem: "#58A6FF"
    property color catProductivity: "#A371F7"
    property color catInfo: "#3FB950"
    property color catEntertainment: "#F778BA"
    property color catGaming: "#F0883E"
    property color catServices: "#56D4DD"

    readonly property var accentPresets: ({
        "blue":    { a: "#58A6FF", b: "#79C0FF" }, "purple":  { a: "#A371F7", b: "#D2A8FF" },
        "green":   { a: "#3FB950", b: "#7EE787" }, "orange":  { a: "#F0883E", b: "#FFA657" },
        "pink":    { a: "#F778BA", b: "#FF9BCE" }, "teal":    { a: "#56D4DD", b: "#76E3EA" },
        "red":     { a: "#F85149", b: "#FF7B72" }, "gold":    { a: "#E3B341", b: "#F2CC60" },
        "cyan":    { a: "#22D3EE", b: "#67E8F9" }, "indigo":  { a: "#818CF8", b: "#A5B4FC" },
        "mint":    { a: "#34D399", b: "#6EE7B7" }, "coral":   { a: "#FB7185", b: "#FDA4AF" },
        "amber":   { a: "#FBBF24", b: "#FCD34D" }, "magenta": { a: "#E879F9", b: "#F0ABFC" },

        // Okabe–Ito: the published Color Universal Design palette, chosen to stay
        // mutually distinguishable under protanopia/deuteranopia/tritanopia.
        // Okabe & Ito (2008), "Color Universal Design (CUD)" - https://jfly.uni-koeln.de/color/
        // The `a` tones are the canonical hexes and must NOT be hand-tuned: the
        // set's guarantee is a property of the 8 colours *together*. `b` is a 35%
        // tint toward white, matching the lighter-second-tone rule above.
        // Namespaced `oi_*` so they ADD to the table - the 14 names above are
        // referenced by name in saved configs and must keep resolving unchanged.
        "oi_black":          { a: "#000000", b: "#595959" },
        "oi_orange":         { a: "#E69F00", b: "#EFC159" },
        "oi_sky_blue":       { a: "#56B4E9", b: "#91CEF1" },
        "oi_bluish_green":   { a: "#009E73", b: "#59C0A4" },
        "oi_yellow":         { a: "#F0E442", b: "#F5ED84" },
        "oi_blue":           { a: "#0072B2", b: "#59A3CD" },
        "oi_vermillion":     { a: "#D55E00", b: "#E49659" },
        "oi_reddish_purple": { a: "#CC79A7", b: "#DEA8C6" },

        // Accents that complete the distro-evoking theme modes (see applyTheme).
        // Colour is not protectable subject matter, so a palette may evoke a
        // familiar look - a logo never may, and none is shipped. The last two are
        // named for their colours ONLY; see the note in applyTheme before renaming
        // them. Separate from the theme modes on purpose: applyTheme re-applies the
        // user's accent rather than forcing one, so pairing these is the user's
        // choice. All clear 3:1 on their theme's card fill (WCAG non-text).
        "arch":      { a: "#1FA8DF", b: "#6BC5EA" },
        "cachyos":   { a: "#3DD68C", b: "#7FE5B5" },
        "debian":    { a: "#D70A53", b: "#E55D8A" },
        "fedora":    { a: "#3C6EB4", b: "#7FA3D3" },
        // The only pair where `b` is a different hue rather than a lighter tint of
        // `a`: the teal/amber *pairing* is the whole identity being evoked, and
        // accent→accent2 renders as a gradient, so the two-hue ramp is the point.
        "popos":     { a: "#48B9C7", b: "#FFAF33" },
        "aubergine": { a: "#E8642A", b: "#F09A6B" },
        "crimson":   { a: "#DC3B33", b: "#E87C76" }
    })

    property int spacingXs: 4
    property int spacingSm: 8
    property int spacingMd: 12
    property int spacingLg: 16
    property int spacingXl: 24

    property int radiusSm: 8
    property int radiusMd: 12
    property int radiusLg: 16
    property int radiusXl: 22

    property int cardBorderWidth: 1
    property bool decorative: true

    property int touchPrimary: 76
    property int touchSecondary: 60
    property int touchTertiary: 52
    property int iconLg: 34
    property int iconMd: 28
    property int iconSm: 22

    // Global text-size multiplier. Every font token below is derived from it, so
    // call sites keep reading `theme.fontLabel` and scale for free.
    // Clamped, not free-form: under 0.8 the captions stop being legible at the
    // Edge's viewing distance, and over 1.6 the 40–48px data readouts overflow
    // the narrow panel's tiles. An out-of-range value is a bug, not a taste -
    // clamp rather than let it break the layout.
    // The Edge is normally read at arm's length, not like a phone held close.
    // 1.15 is the legible default; users can still choose 1.0 for dense layouts.
    property real textScale: 1.15
    readonly property real textScaleEff: Math.max(0.8, Math.min(1.6, textScale))

    property int fontMinimum: Math.round(13 * textScaleEff)
    property int fontData: Math.round(40 * textScaleEff)
    property int fontDataLarge: Math.round(48 * textScaleEff)
    property int fontTitle: Math.round(17 * textScaleEff)
    property int fontLabel: Math.round(15 * textScaleEff)
    property int fontCaption: Math.round(13 * textScaleEff)
    // Fixed-pitch face for tabular data readouts (timers, metric values, the
    // Focus countdown). This was the string "JetBrains Mono, Fira Code,
    // monospace" - which reads like a CSS stack but is NOT one: Qt does not
    // split a comma-separated `font.family`, so the whole thing was matched as a
    // single family name and fontconfig picked whatever it liked. It liked
    // different things on different machines. Proven 2026-08-02 by the
    // visual-baseline comparison the first time it could run in CI: the
    // committed baseline renders the Focus timer in real monospace (slashed
    // zeros, uniform digit widths) and the runner rendered the identical widget
    // in a PROPORTIONAL sans. A countdown whose digits change width jitters on
    // every tick - exactly what this token exists to prevent.
    //
    // Resolve through the bundled face, exactly as the a11y families do. The
    // literal name is only reached if the resource is somehow missing, and
    // "monospace" is kept as the final fallback so text is never left to a
    // proportional default.
    readonly property string fontMono:
        monoLoader.status === FontLoader.Ready
            ? monoLoader.name : "JetBrains Mono, monospace"

    // ── Bundled a11y fonts (SIL OFL 1.1, unmodified; assets/fonts/) ──────────
    // Loaded HERE so both apps and the test harness get them from the single
    // token source. URL resolution: Theme.qml is loaded from qrc:/qml/ (hub),
    // qrc:/manager/ (Manager) and the plain filesystem (qmltestrunner), so the
    // qrc case uses the absolute resource path assets/fonts.qrc puts the files
    // at, and the filesystem case walks to <repo>/assets/fonts/ - same bytes.
    readonly property string _fontsDir:
        Qt.resolvedUrl(".").toString().indexOf("qrc:") === 0
            ? "qrc:/assets/fonts/"
            : Qt.resolvedUrl("../../assets/fonts/").toString()
    readonly property FontLoader hyperlegibleLoader:
        FontLoader { source: t._fontsDir + "AtkinsonHyperlegible-Regular.ttf" }
    readonly property FontLoader hyperlegibleBoldLoader:
        FontLoader { source: t._fontsDir + "AtkinsonHyperlegible-Bold.ttf" }
    readonly property FontLoader lexendLoader:
        FontLoader { source: t._fontsDir + "Lexend-Regular.ttf" }
    readonly property FontLoader lexendBoldLoader:
        FontLoader { source: t._fontsDir + "Lexend-Bold.ttf" }
    // Tabular readout face, bundled for the same reason the a11y faces are: so
    // every machine renders the same glyphs. See fontMono below.
    readonly property FontLoader monoLoader:
        FontLoader { source: t._fontsDir + "JetBrainsMono-Regular.ttf" }
    readonly property FontLoader monoBoldLoader:
        FontLoader { source: t._fontsDir + "JetBrainsMono-Bold.ttf" }
    // The product's own UI face. See _fontDisplaySystem below.
    readonly property FontLoader interLoader:
        FontLoader { source: t._fontsDir + "Inter-Regular.ttf" }
    readonly property FontLoader interBoldLoader:
        FontLoader { source: t._fontsDir + "Inter-Bold.ttf" }
    // Brand wordmark face (Chakra Petch, OFL) - close free stand-in for the
    // SKYPhoenix IT logo lettering. Used only for the "EdgeHub" lockup.
    readonly property FontLoader brandLoader:
        FontLoader { source: t._fontsDir + "ChakraPetch-SemiBold.ttf" }
    readonly property FontLoader brandBoldLoader:
        FontLoader { source: t._fontsDir + "ChakraPetch-Bold.ttf" }

    // Family tokens resolve through the loaders so a widget gets the REAL
    // loaded family name; the literal-name fallback only matters if the
    // resource is somehow missing (then fontconfig falls back to system).
    readonly property string fontFamilyHyperlegible:
        hyperlegibleLoader.status === FontLoader.Ready
            ? hyperlegibleLoader.name : "Atkinson Hyperlegible"
    readonly property string fontFamilyLexend:
        lexendLoader.status === FontLoader.Ready
            ? lexendLoader.name : "Lexend"
    // The brand wordmark family. Falls back to the geometric system stack if the
    // bundled face is somehow missing, so the lockup never renders in a serif.
    readonly property string fontBrand:
        brandLoader.status === FontLoader.Ready
            ? brandLoader.name : "Chakra Petch, Rajdhani, Saira, sans-serif"

    // User-facing font preference: "system" (default - the product's look) |
    // "hyperlegible" | "lexend". Wires the UI family token (fontDisplay) so
    // every widget follows for free; fontMono stays mono on purpose (tabular
    // data readouts need fixed-pitch digits). Unknown values fall through to
    // system, so a config from a newer build degrades safely.
    property string fontChoice: "hyperlegible"
    // The "system" font choice - which has always meant "the product's own
    // look", not "whatever this machine defaults to".
    //
    // It was the string "Inter, Segoe UI, Roboto, sans-serif". That reads like a
    // CSS stack, but Qt does not split a comma-separated `font.family`: the
    // whole thing was matched as a single family name, failed, and fell back to
    // the machine's default sans. Measured with Inter installed - the exact
    // package CI installs - "CPU" at pixelSize 20: `"Inter"` renders 42.25x25,
    // while `"Inter, sans-serif"` and the full stack both render 39.33x28,
    // identical to plain `"sans-serif"`. So NO user has ever seen Inter, on any
    // machine, no matter what they had installed; and what they saw instead
    // varied per distro. Same defect as fontMono above, and it was found the
    // same way.
    //
    // Resolve through the bundled face, exactly as the a11y and mono families
    // do. Bundling rather than merely fixing the lookup is deliberate: a name
    // list would still render differently on every machine that lacks Inter,
    // which is most of them. The literal stack survives only as the
    // resource-missing fallback.
    readonly property string _fontDisplaySystem:
        interLoader.status === FontLoader.Ready
            ? interLoader.name : "Inter, sans-serif"
    property string fontDisplay:
        fontChoice === "hyperlegible" ? fontFamilyHyperlegible
      : fontChoice === "lexend" ? fontFamilyLexend
      : _fontDisplaySystem

    property real glass: glassOpacity
    property bool glow: showWidgetGlow
    // Widget-card FILL, as a NOTIFIABLE property so every card repaints the instant
    // glassOpacity changes. (The old cardFill() was a plain function; a
    // function-call binding is the one appearance token whose re-evaluation on
    // change isn't guaranteed - this removes that doubt.) Higher glassOpacity →
    // more translucent so a wallpaper / animated backdrop reads THROUGH the cards
    // (frosted-glass look). Range ~0.22 (max glass) .. 0.84 (opaque). The RGB is
    // deliberately left at cardBackground: lightening the fill to make glass
    // "visible" on a flat dark page would close the gap to mid-tone accents (e.g.
    // Fedora's navy) below the 3:1 WCAG non-text bar. The VISIBLE glassiness cue
    // lives on the border + sheen instead (see cardBorderGlass and WidgetChrome),
    // which no contrast gate constrains. High-contrast forces fully opaque cards.
    readonly property color cardFillColor:
        !decorative
            ? cardBackground
            : Qt.rgba(cardBackground.r, cardBackground.g, cardBackground.b,
                      0.22 + (1.0 - glassOpacity) * 0.62)
    // Back-compat shim: existing call sites use cardFill(); both resolve here.
    function cardFill() { return cardFillColor }

    // Card BORDER, pushed toward the text colour with glassOpacity - this is what
    // makes the slider visibly DO something on the common flat-dark case, where the
    // fill alone couldn't change perceptibly without breaking accent contrast. More
    // glass → a stronger "rim light" edge (up to ~40% toward textPrimary), the
    // hallmark of a glass surface. Blending toward textPrimary (not a fixed white)
    // keeps the edge visible on BOTH light and dark themes: it brightens a dark
    // card's border and darkens a light card's, since textPrimary always contrasts
    // the card. Decoupled from every legibility gate (nothing measures contrast
    // against the border). High-contrast keeps its solid border.
    readonly property color cardBorderGlass:
        !decorative
            ? cardBorder
            : Qt.rgba(cardBorder.r + (textPrimary.r - cardBorder.r) * glassOpacity * 0.62,
                      cardBorder.g + (textPrimary.g - cardBorder.g) * glassOpacity * 0.62,
                      cardBorder.b + (textPrimary.b - cardBorder.b) * glassOpacity * 0.62, 1)
    // Strength of the card's top-edge frosted highlight, also scaling with glass
    // (~0.03 → ~0.26 white). A second visible cue that reads as "more glass" - with
    // a wider range for more pezazz between low and high glass.
    readonly property real cardSheen: decorative ? (0.02 + glassOpacity * 0.08) : 0.0
    readonly property real widgetBackdropOpacity: decorative ? 0.10 : 0.0

    property int motionPage: effectiveReduceMotion ? 0 : 250
    property int motionAdd: effectiveReduceMotion ? 0 : 200
    property int motionRemove: effectiveReduceMotion ? 0 : 150
    property int motionEdit: effectiveReduceMotion ? 0 : 200
    property int motionFast: effectiveReduceMotion ? 0 : 150
    property int motionSlow: effectiveReduceMotion ? 0 : 500
    // Continuous VALUE tracking (bar lengths, gauge sweeps, live readouts): long
    // enough that a 2s metrics tick reads as one smooth glide instead of a cut,
    // short enough that the display never lags the data by a readable amount.
    // Every widget that eases a data value must use THIS token (not a literal),
    // so reduce-motion collapses them all to an instant jump in one place.
    property int motionValue: effectiveReduceMotion ? 0 : 400

    // ── Theme catalogue - the ONE source of the selectable theme list ─────────
    // key, display name, two preview-gradient colours, whether it needs Pro, and a
    // group for the pickers to section by. Both the hub's SettingsPanel and the
    // Manager's theme dropdown read THIS, so the list, the Pro flags and the preview
    // swatches can never drift between the two surfaces (they used to be maintained
    // in three separate places). The token mapping still lives in applyTheme(); this
    // is only the catalogue the pickers present.
    readonly property var themeCatalog: [
        { k: "dark",          n: "Dark",       c1: "#161B22", c2: "#0A0E14", group: "Standard" },
        { k: "midnight",      n: "Midnight",   c1: "#1B1247", c2: "#070A1C", group: "Standard" },
        { k: "aurora",        n: "Aurora",     c1: "#0C2E3A", c2: "#111C40", group: "Standard" },
        { k: "sunset",        n: "Sunset",     c1: "#3A1230", c2: "#40161C", group: "Standard" },
        { k: "nebula",        n: "Nebula",     c1: "#2A1048", c2: "#120A2E", group: "Standard" },
        { k: "deep_forest",   n: "Forest",     c1: "#143021", c2: "#06120A", group: "Standard" },
        { k: "deep_ocean",    n: "Ocean",      c1: "#0A2A3F", c2: "#020A14", group: "Standard" },
        { k: "ember",         n: "Ember",      c1: "#3A1509", c2: "#0F0705", group: "Standard" },
        { k: "rose_gold",     n: "Rose Gold",  c1: "#3A1E2C", c2: "#170C12", group: "Standard" },
        { k: "nord",          n: "Nord",       c1: "#3B4252", c2: "#272B35", group: "Standard" },
        { k: "dracula",       n: "Dracula",    c1: "#343746", c2: "#21222C", group: "Standard" },
        { k: "solarized",     n: "Solarized",  c1: "#073642", c2: "#00212B", group: "Standard" },
        { k: "gruvbox",       n: "Gruvbox",    c1: "#32302F", c2: "#1D2021", group: "Standard" },
        { k: "catppuccin",    n: "Catppuccin", c1: "#181825", c2: "#11111B", group: "Standard" },
        { k: "tokyonight",    n: "Tokyo Night",c1: "#24283B", c2: "#16161E", group: "Standard" },
        { k: "aubergine",     n: "Aubergine",  c1: "#3A0F2A", c2: "#2C0A20", group: "Standard" },
        { k: "crimson",       n: "Crimson",    c1: "#16080B", c2: "#0B0507", group: "Standard" },
        { k: "oled",          n: "OLED",       c1: "#0A0A0A", c2: "#000000", group: "Standard" },
        { k: "light",         n: "Light",      c1: "#F6F8FA", c2: "#E4E9F0", group: "Standard" },
        { k: "synthwave",     n: "Synthwave",  c1: "#2D0B45", c2: "#0F0524", pro: true, group: "Premium" },
        { k: "cyberpunk",     n: "Cyberpunk",  c1: "#0A2A26", c2: "#020A08", pro: true, group: "Premium" },
        { k: "vaporwave",     n: "Vaporwave",  c1: "#3A1A52", c2: "#140A20", pro: true, group: "Premium" },
        { k: "matrix",        n: "Matrix",     c1: "#0A160A", c2: "#000000", pro: true, group: "Premium" },
        { k: "arch",          n: "Keystone",   c1: "#1B2129", c2: "#14181D", pro: true, group: "Inspired" },
        { k: "cachyos",       n: "Cascade",    c1: "#1C221A", c2: "#131611", pro: true, group: "Inspired" },
        { k: "debian",        n: "Swirl",      c1: "#1F1922", c2: "#16121A", pro: true, group: "Inspired" },
        { k: "fedora",        n: "Trilby",     c1: "#152034", c2: "#0E1626", pro: true, group: "Inspired" },
        { k: "popos",         n: "Fizz",       c1: "#262322", c2: "#1E1C1B", pro: true, group: "Inspired" },
        { k: "high_contrast", n: "Contrast",   c1: "#1A1A1A", c2: "#000000", group: "Accessibility" }
    ]
    // Group order for the pickers (only groups that exist are shown).
    // The shipped default theme key. MUST track default_theme_mode() in
    // core/src/config.rs - the Rust side is authoritative for a fresh config;
    // this is the fallback for an appearance blob that predates the key or has
    // it missing. Two hardcoded "dark" fallbacks in Manager.qml used to drift
    // from it, which showed the Manager a different theme than the Hub.
    readonly property string defaultThemeKey: "nord"

    readonly property var themeGroupOrder: ["Standard", "Premium", "Inspired", "Accessibility"]
    function themeDef(key) {
        for (var i = 0; i < themeCatalog.length; i++)
            if (themeCatalog[i].k === key) return themeCatalog[i]
        return null
    }
    function themesInGroup(group) {
        return themeCatalog.filter(function (t) { return t.group === group })
    }
    // Is `key` a Pro-only theme? (Reads the catalogue's pro flag.)
    function themeIsPro(key) { var d = themeDef(key); return !!(d && d.pro) }

    function applyAccent(name) {
        var p = accentPresets[name] || accentPresets["blue"]
        accent = p.a; accent2 = p.b; accentName = name
    }

    // Keep stored and swatch colours canonical while deriving a rendered tone
    // that remains visible on every page gradient stop and at both glass
    // extremes. WidgetChrome uses this seam for global, category, and per-widget
    // accents. A failing hue is moved only as far toward black or white as the
    // 3:1 non-text threshold requires.
    function _colorValue(value) {
        if (typeof value !== "string")
            return value
        var h = value.replace("#", "")
        if (h.length !== 6)
            return Qt.rgba(0, 0, 0, 1)
        return Qt.rgba(parseInt(h.substr(0, 2), 16) / 255,
                       parseInt(h.substr(2, 2), 16) / 255,
                       parseInt(h.substr(4, 2), 16) / 255, 1)
    }
    function _relativeLuminance(color) {
        function linear(value) {
            return value <= 0.03928
                    ? value / 12.92
                    : Math.pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.r)
             + 0.7152 * linear(color.g)
             + 0.0722 * linear(color.b)
    }
    function contrastRatio(first, second) {
        var a = _relativeLuminance(_colorValue(first))
        var b = _relativeLuminance(_colorValue(second))
        return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05)
    }
    function _overColor(foreground, background) {
        return Qt.rgba(foreground.a * foreground.r + (1 - foreground.a) * background.r,
                       foreground.a * foreground.g + (1 - foreground.a) * background.g,
                       foreground.a * foreground.b + (1 - foreground.a) * background.b, 1)
    }
    function _minimumCardContrast(color) {
        var pages = [backgroundColor, backgroundColor2, backgroundColor3]
        var glasses = [0.0, 1.0]
        var minimum = 21.0
        for (var p = 0; p < pages.length; p++) {
            for (var g = 0; g < glasses.length; g++) {
                var alpha = decorative ? 0.22 + (1.0 - glasses[g]) * 0.62 : 1.0
                var fill = Qt.rgba(cardBackground.r, cardBackground.g, cardBackground.b, alpha)
                minimum = Math.min(minimum,
                                   contrastRatio(color, _overColor(fill, pages[p])))
            }
        }
        return minimum
    }
    function _minimumTextSurfaceContrast(color) {
        var pages = [backgroundColor, backgroundColor2, backgroundColor3]
        var minimum = _minimumCardContrast(color)
        for (var p = 0; p < pages.length; p++)
            minimum = Math.min(minimum, contrastRatio(color, pages[p]))
        return minimum
    }
    function _blendColor(from, to, amount) {
        return Qt.rgba(from.r + (to.r - from.r) * amount,
                       from.g + (to.g - from.g) * amount,
                       from.b + (to.b - from.b) * amount, 1)
    }
    function ensureNonTextContrast(value) {
        var source = _colorValue(value)
        if (_minimumCardContrast(source) >= 3.0)
            return source
        var black = Qt.rgba(0, 0, 0, 1)
        var white = Qt.rgba(1, 1, 1, 1)
        var target = _minimumCardContrast(black) >= _minimumCardContrast(white)
                ? black : white
        var low = 0.0
        var high = 1.0
        for (var i = 0; i < 14; i++) {
            var middle = (low + high) / 2
            if (_minimumCardContrast(_blendColor(source, target, middle)) >= 3.0)
                high = middle
            else
                low = middle
        }
        return _blendColor(source, target, high)
    }
    function ensureTextContrast(value, minimum) {
        var source = _colorValue(value)
        if (_minimumTextSurfaceContrast(source) >= minimum)
            return source
        var black = Qt.rgba(0, 0, 0, 1)
        var white = Qt.rgba(1, 1, 1, 1)
        var target = _minimumTextSurfaceContrast(black) >= _minimumTextSurfaceContrast(white)
                ? black : white
        var low = 0.0
        var high = 1.0
        for (var i = 0; i < 14; i++) {
            var middle = (low + high) / 2
            if (_minimumTextSurfaceContrast(_blendColor(source, target, middle)) >= minimum)
                high = middle
            else
                low = middle
        }
        return _blendColor(source, target, high)
    }
    function readableAccentFor(name) {
        var preset = accentPresets[name] || accentPresets["blue"]
        return ensureNonTextContrast(preset.a)
    }
    readonly property color accentReadable: ensureNonTextContrast(accent)

    function applyTheme(mode) {
        switch (mode) {
        case "light":
            backgroundColor = "#FFFFFF"; backgroundColor2 = "#EEF1F5"; backgroundColor3 = "#E4E9F0"
            cardBackground = "#F6F8FA"; cardBackgroundAlt = "#ECEFF3"; cardBorder = "#D0D7DE"
            textPrimary = "#1F2328"; textSecondary = "#59616B"; textTertiary = "#8C959F"
            radiusSm = 6; radiusMd = 9; radiusLg = 12; radiusXl = 16; decorative = true; cardBorderWidth = 1; break
        case "oled":
            backgroundColor = "#000000"; backgroundColor2 = "#000000"; backgroundColor3 = "#000000"
            cardBackground = "#0A0A0A"; cardBackgroundAlt = "#121212"; cardBorder = "#1A1A1A"
            textPrimary = "#E0E0E0"; textSecondary = "#808080"; textTertiary = "#5A5A5A"
            radiusSm = 8; radiusMd = 12; radiusLg = 16; radiusXl = 22; decorative = true; cardBorderWidth = 1; break
        case "high_contrast":
            backgroundColor = "#000000"; backgroundColor2 = "#000000"; backgroundColor3 = "#000000"
            cardBackground = "#1A1A1A"; cardBackgroundAlt = "#242424"; cardBorder = "#FFFFFF"
            textPrimary = "#FFFFFF"; textSecondary = "#CCCCCC"; textTertiary = "#AAAAAA"
            radiusSm = 2; radiusMd = 3; radiusLg = 4; radiusXl = 6; decorative = false; cardBorderWidth = 2; break
        case "midnight":
            backgroundColor = "#0B1026"; backgroundColor2 = "#1B1247"; backgroundColor3 = "#070A1C"
            cardBackground = "#16192E"; cardBackgroundAlt = "#232748"; cardBorder = "#33385F"
            textPrimary = "#EDEFFF"; textSecondary = "#A6ABD6"; textTertiary = "#71769E"
            radiusSm = 10; radiusMd = 16; radiusLg = 22; radiusXl = 28; decorative = true; cardBorderWidth = 1; break
        case "aurora":
            backgroundColor = "#04140F"; backgroundColor2 = "#0C2E3A"; backgroundColor3 = "#111C40"
            cardBackground = "#0E1E24"; cardBackgroundAlt = "#16303A"; cardBorder = "#25505A"
            textPrimary = "#EAFBF4"; textSecondary = "#9FC9C4"; textTertiary = "#6C918E"
            radiusSm = 10; radiusMd = 16; radiusLg = 22; radiusXl = 28; decorative = true; cardBorderWidth = 1; break
        case "sunset":
            backgroundColor = "#1B0A20"; backgroundColor2 = "#3A1230"; backgroundColor3 = "#40161C"
            cardBackground = "#26132A"; cardBackgroundAlt = "#38203C"; cardBorder = "#5A3355"
            textPrimary = "#FFEFF6"; textSecondary = "#D6A9C4"; textTertiary = "#9E7690"
            radiusSm = 10; radiusMd = 16; radiusLg = 22; radiusXl = 28; decorative = true; cardBorderWidth = 1; break
        case "nebula":
            backgroundColor = "#0E0722"; backgroundColor2 = "#2A1048"; backgroundColor3 = "#120A2E"
            cardBackground = "#1A1132"; cardBackgroundAlt = "#2A1D48"; cardBorder = "#413063"
            textPrimary = "#F1EBFF"; textSecondary = "#B7A9D6"; textTertiary = "#8276A0"
            radiusSm = 10; radiusMd = 16; radiusLg = 22; radiusXl = 28; decorative = true; cardBorderWidth = 1; break
        case "synthwave":
            backgroundColor = "#1A0B2E"; backgroundColor2 = "#2D0B45"; backgroundColor3 = "#0F0524"
            cardBackground = "#241141"; cardBackgroundAlt = "#34195C"; cardBorder = "#5B2A8C"
            textPrimary = "#FCEEFF"; textSecondary = "#C89BE0"; textTertiary = "#9070B0"
            radiusSm = 10; radiusMd = 16; radiusLg = 22; radiusXl = 28; decorative = true; cardBorderWidth = 1; break
        case "cyberpunk":
            backgroundColor = "#04110F"; backgroundColor2 = "#0A2A26"; backgroundColor3 = "#020A08"
            cardBackground = "#0A1A18"; cardBackgroundAlt = "#12302B"; cardBorder = "#1C4A42"
            textPrimary = "#EAFFF9"; textSecondary = "#7FD8C8"; textTertiary = "#559488"
            radiusSm = 6; radiusMd = 9; radiusLg = 12; radiusXl = 16; decorative = true; cardBorderWidth = 1; break
        case "deep_forest":
            backgroundColor = "#0A1A0E"; backgroundColor2 = "#143021"; backgroundColor3 = "#06120A"
            cardBackground = "#12251A"; cardBackgroundAlt = "#1B3626"; cardBorder = "#2E5238"
            textPrimary = "#EAF7EC"; textSecondary = "#A8C9AE"; textTertiary = "#75997C"
            radiusSm = 10; radiusMd = 16; radiusLg = 22; radiusXl = 28; decorative = true; cardBorderWidth = 1; break
        case "deep_ocean":
            backgroundColor = "#04121F"; backgroundColor2 = "#0A2A3F"; backgroundColor3 = "#020A14"
            cardBackground = "#0A1E2E"; cardBackgroundAlt = "#12324A"; cardBorder = "#1E4A63"
            textPrimary = "#E6F6FF"; textSecondary = "#9BC4DC"; textTertiary = "#6689A0"
            radiusSm = 10; radiusMd = 16; radiusLg = 22; radiusXl = 28; decorative = true; cardBorderWidth = 1; break
        case "ember":
            backgroundColor = "#1A0E0A"; backgroundColor2 = "#3A1509"; backgroundColor3 = "#0F0705"
            cardBackground = "#241310"; cardBackgroundAlt = "#38201A"; cardBorder = "#5C3324"
            textPrimary = "#FFEFE6"; textSecondary = "#DDA989"; textTertiary = "#A67A61"
            radiusSm = 10; radiusMd = 16; radiusLg = 22; radiusXl = 28; decorative = true; cardBorderWidth = 1; break
        case "vaporwave":
            backgroundColor = "#1E0F2E"; backgroundColor2 = "#3A1A52"; backgroundColor3 = "#140A20"
            cardBackground = "#281640"; cardBackgroundAlt = "#382058"; cardBorder = "#563A78"
            textPrimary = "#FBEEFF"; textSecondary = "#CBB0E6"; textTertiary = "#9986B8"
            radiusSm = 12; radiusMd = 18; radiusLg = 24; radiusXl = 30; decorative = true; cardBorderWidth = 1; break
        case "rose_gold":
            backgroundColor = "#21121A"; backgroundColor2 = "#3A1E2C"; backgroundColor3 = "#170C12"
            cardBackground = "#2A1721"; cardBackgroundAlt = "#3D2431"; cardBorder = "#5E3A4A"
            textPrimary = "#FDEEF3"; textSecondary = "#D9AEBB"; textTertiary = "#A67E8B"
            radiusSm = 12; radiusMd = 18; radiusLg = 24; radiusXl = 30; decorative = true; cardBorderWidth = 1; break
        case "matrix":
            backgroundColor = "#000000"; backgroundColor2 = "#030A03"; backgroundColor3 = "#000000"
            cardBackground = "#050D05"; cardBackgroundAlt = "#0A160A"; cardBorder = "#164016"
            textPrimary = "#B6FFB6"; textSecondary = "#5FCF5F"; textTertiary = "#3E8F3E"
            radiusSm = 4; radiusMd = 6; radiusLg = 9; radiusXl = 12; decorative = true; cardBorderWidth = 1; break
        case "nord":
            backgroundColor = "#2E3440"; backgroundColor2 = "#3B4252"; backgroundColor3 = "#272B35"
            cardBackground = "#3B4252"; cardBackgroundAlt = "#434C5E"; cardBorder = "#4C566A"
            textPrimary = "#ECEFF4"; textSecondary = "#D8DEE9"; textTertiary = "#7B8494"
            radiusSm = 10; radiusMd = 16; radiusLg = 22; radiusXl = 28; decorative = true; cardBorderWidth = 1; break
        case "dracula":
            backgroundColor = "#282A36"; backgroundColor2 = "#343746"; backgroundColor3 = "#21222C"
            cardBackground = "#343746"; cardBackgroundAlt = "#3C3F51"; cardBorder = "#44475A"
            textPrimary = "#F8F8F2"; textSecondary = "#BFBFD0"; textTertiary = "#6272A4"
            radiusSm = 10; radiusMd = 16; radiusLg = 22; radiusXl = 28; decorative = true; cardBorderWidth = 1; break
        case "solarized":
            backgroundColor = "#002B36"; backgroundColor2 = "#073642"; backgroundColor3 = "#00212B"
            cardBackground = "#073642"; cardBackgroundAlt = "#0E4B59"; cardBorder = "#17616B"
            textPrimary = "#EEE8D5"; textSecondary = "#93A1A1"; textTertiary = "#657B83"
            radiusSm = 10; radiusMd = 16; radiusLg = 22; radiusXl = 28; decorative = true; cardBorderWidth = 1; break
        case "gruvbox":
            backgroundColor = "#282828"; backgroundColor2 = "#32302F"; backgroundColor3 = "#1D2021"
            cardBackground = "#3C3836"; cardBackgroundAlt = "#504945"; cardBorder = "#665C54"
            textPrimary = "#EBDBB2"; textSecondary = "#D5C4A1"; textTertiary = "#A89984"
            radiusSm = 10; radiusMd = 16; radiusLg = 22; radiusXl = 28; decorative = true; cardBorderWidth = 1; break
        case "catppuccin":
            backgroundColor = "#1E1E2E"; backgroundColor2 = "#181825"; backgroundColor3 = "#11111B"
            cardBackground = "#313244"; cardBackgroundAlt = "#45475A"; cardBorder = "#585B70"
            textPrimary = "#CDD6F4"; textSecondary = "#A6ADC8"; textTertiary = "#7F849C"
            radiusSm = 10; radiusMd = 16; radiusLg = 22; radiusXl = 28; decorative = true; cardBorderWidth = 1; break
        case "tokyonight":
            backgroundColor = "#1A1B26"; backgroundColor2 = "#24283B"; backgroundColor3 = "#16161E"
            cardBackground = "#24283B"; cardBackgroundAlt = "#2F344D"; cardBorder = "#3B4261"
            textPrimary = "#C0CAF5"; textSecondary = "#A9B1D6"; textTertiary = "#565F89"
            radiusSm = 10; radiusMd = 16; radiusLg = 22; radiusXl = 28; decorative = true; cardBorderWidth = 1; break

        // ── Palettes evoking familiar Linux distributions ────────────────────
        // COLOUR ONLY. This product is sold, and distro logos/wordmarks are
        // trademarks that our own MIT/Apache licensing does nothing about - but a
        // colour palette is not protectable subject matter. So these cases ship a
        // *palette inspired by* a look and nothing else: no logo, no glyph, no
        // traced or approximated mark, anywhere in the theme or its assets.
        //
        // NAMING POLICY (owner decision, 2026-07-19) - no project name is used as
        // a user-visible label, for ANY of these, regardless of how permissive
        // that project's guidelines are. Nominative use is probably defensible;
        // it is not worth defending. Instead each display name LEANS ON THE
        // NAMING SCHEME the project itself used, without borrowing the name:
        //
        //    key       shown as    the scheme it leans on
        //    fedora    Trilby      a fedora is a hat; a trilby is a different hat
        //    arch      Keystone    an arch is architecture; so is a keystone
        //    debian    Swirl       names the visual motif, not the project
        //    cachyos   Cascade     evokes cache/flow, not the project
        //    popos     Fizz        evokes "pop", not the project
        //
        // `aubergine` and `crimson` were already named for their colours because
        // their owners actively enforce against commercial use. Same rule, and it
        // now applies uniformly: do not reintroduce ANY project name into a case
        // label, a UI string, or a comment presented to the user. The colour is
        // the whole point; the name would be the whole liability.
        //
        // The `k:` KEYS deliberately keep their original spelling. They are
        // internal identifiers only - persisted in config.toml and switched on
        // below - never rendered. Renaming them would break every existing user's
        // saved theme for zero legal benefit.
        //
        // Each carries its hue in the SURFACES (backgrounds, card fills, borders)
        // rather than in `accent` - applyTheme deliberately ends by re-applying
        // the user's own accent, so a theme must never clobber it. The matching
        // accents live in `accentPresets` for users who want the full look.

        // Cyan-tinted graphite.
        case "arch":
            backgroundColor = "#14181D"; backgroundColor2 = "#1B2229"; backgroundColor3 = "#0E1216"
            cardBackground = "#1B2129"; cardBackgroundAlt = "#232B35"; cardBorder = "#2C4453"
            textPrimary = "#E4EEF5"; textSecondary = "#9FB6C4"; textTertiary = "#6E8291"
            radiusSm = 10; radiusMd = 16; radiusLg = 22; radiusXl = 28; decorative = true; cardBorderWidth = 1; break
        // Spring green on a near-neutral dark.
        case "cachyos":
            backgroundColor = "#131611"; backgroundColor2 = "#1D2419"; backgroundColor3 = "#0C0E0A"
            cardBackground = "#1C221A"; cardBackgroundAlt = "#26301F"; cardBorder = "#35492E"
            textPrimary = "#EAF7E4"; textSecondary = "#AEC9A6"; textTertiary = "#7C9276"
            radiusSm = 10; radiusMd = 16; radiusLg = 22; radiusXl = 28; decorative = true; cardBorderWidth = 1; break
        // Magenta-red on a dark neutral.
        case "debian":
            backgroundColor = "#16121A"; backgroundColor2 = "#241823"; backgroundColor3 = "#0F0C12"
            cardBackground = "#1F1922"; cardBackgroundAlt = "#2A212D"; cardBorder = "#4A2C3C"
            textPrimary = "#F5EAF0"; textSecondary = "#C4A8B8"; textTertiary = "#8E7684"
            radiusSm = 10; radiusMd = 16; radiusLg = 22; radiusXl = 28; decorative = true; cardBorderWidth = 1; break
        // Deep navy-blue surfaces.
        case "fedora":
            backgroundColor = "#0E1626"; backgroundColor2 = "#17284A"; backgroundColor3 = "#080E1A"
            cardBackground = "#152034"; cardBackgroundAlt = "#1D2C48"; cardBorder = "#2C4270"
            textPrimary = "#E8F0FB"; textSecondary = "#A6BCDA"; textTertiary = "#728CAB"
            radiusSm = 10; radiusMd = 16; radiusLg = 22; radiusXl = 28; decorative = true; cardBorderWidth = 1; break
        // Warm graphite; the teal/amber pairing it evokes lives in the accent.
        case "popos":
            backgroundColor = "#1E1C1B"; backgroundColor2 = "#2B2827"; backgroundColor3 = "#141312"
            cardBackground = "#262322"; cardBackgroundAlt = "#33302E"; cardBorder = "#48423F"
            textPrimary = "#F2EFEC"; textSecondary = "#BDB5AE"; textTertiary = "#8A827B"
            radiusSm = 10; radiusMd = 16; radiusLg = 22; radiusXl = 28; decorative = true; cardBorderWidth = 1; break
        // Deep purple; pairs with a warm orange accent.
        case "aubergine":
            backgroundColor = "#2C0A20"; backgroundColor2 = "#46102F"; backgroundColor3 = "#1D0616"
            cardBackground = "#3A0F2A"; cardBackgroundAlt = "#4C1738"; cardBorder = "#6B2650"
            textPrimary = "#FBECF5"; textSecondary = "#D5AAC4"; textTertiary = "#A47C93"
            radiusSm = 10; radiusMd = 16; radiusLg = 22; radiusXl = 28; decorative = true; cardBorderWidth = 1; break
        // Deep red on near-black.
        case "crimson":
            backgroundColor = "#0B0507"; backgroundColor2 = "#1E070B"; backgroundColor3 = "#050203"
            cardBackground = "#16080B"; cardBackgroundAlt = "#230E12"; cardBorder = "#3E1A20"
            textPrimary = "#FBE9EA"; textSecondary = "#D0A2A6"; textTertiary = "#996E73"
            radiusSm = 10; radiusMd = 16; radiusLg = 22; radiusXl = 28; decorative = true; cardBorderWidth = 1; break
        default:
            backgroundColor = "#0D1117"; backgroundColor2 = "#0A0E14"; backgroundColor3 = "#0A0E14"
            cardBackground = "#161B22"; cardBackgroundAlt = "#1C222B"; cardBorder = "#30363D"
            textPrimary = "#E6EDF3"; textSecondary = "#8B949E"; textTertiary = "#6E7681"
            radiusSm = 8; radiusMd = 12; radiusLg = 16; radiusXl = 22; decorative = true; cardBorderWidth = 1; break
        }
        // Secondary text carries real labels and units throughout every widget.
        // Give it margin above AA so decorative pixels can vary without pushing
        // the final composed contrast below 4.5:1.
        textSecondary = ensureTextContrast(textSecondary, 7.0)
        applyAccent(accentName)
    }
}
