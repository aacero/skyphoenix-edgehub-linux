import QtQuick
import QtTest
import "../../ui/qml" as App

// Theme (ui/qml/Theme.qml) - the design-token source + accent/theme appliers.
// Pure logic (a QtObject), so we assert the derived values directly.
Item {
    id: root
    width: 100; height: 100
    App.Theme { id: theme }

    // A pristine Theme, to assert the untouched defaults a pre-existing config
    // would land on (the shared `theme` above is mutated by other tests).
    Component { id: freshTheme; App.Theme {} }

    TestCase {
        name: "Theme"
        when: windowShown

        function init() {
            theme.applyTheme("dark"); theme.applyAccent("blue"); theme.glassOpacity = 0.6
            theme.reduceMotion = false; theme.systemReduceMotion = false
            theme.reduceMotionPreference = "auto"; theme.textScale = 1.0
            theme.fontChoice = "system"
        }

        // ── accentPresets ────────────────────────────────────────────────────
        function test_accent_presets_complete() {
            var names = ["blue","purple","green","orange","pink","teal","red","gold",
                         "cyan","indigo","mint","coral","amber","magenta"]
            compare(Object.keys(theme.accentPresets).length, 29,
                    "fourteen house + eight Okabe–Ito + seven distro-evoking accents")
            for (var i = 0; i < names.length; i++) {
                var p = theme.accentPresets[names[i]]
                verify(p && p.a !== undefined && p.b !== undefined, names[i] + " has a+b tones")
            }
        }

        // ── BACKWARD COMPATIBILITY ───────────────────────────────────────────
        // Accents are referenced BY NAME in saved configs (Dashboard.applyAppearance
        // → applyAccent(a.accent)), so adding names cannot shift an index - but it
        // could still silently retune a tone. These are the literal hexes shipped
        // before the Okabe–Ito set landed: an existing user's stored accent must
        // resolve to the SAME colour. Pinned as literals on purpose - comparing
        // against theme.accentPresets would just compare the table to itself.
        function test_existing_accents_resolve_unchanged() {
            var legacy = { "blue": "#58A6FF", "purple": "#A371F7", "green": "#3FB950",
                           "orange": "#F0883E", "pink": "#F778BA", "teal": "#56D4DD",
                           "red": "#F85149", "gold": "#E3B341", "cyan": "#22D3EE",
                           "indigo": "#818CF8", "mint": "#34D399", "coral": "#FB7185",
                           "amber": "#FBBF24", "magenta": "#E879F9" }
            for (var name in legacy) {
                theme.applyAccent(name)
                compare(theme.accentName, name, name + " still applies")
                verify(Qt.colorEqual(theme.accent, legacy[name]),
                       "stored accent '" + name + "' resolves to its original colour " + legacy[name])
            }
        }

        // A stored theme mode must keep painting the same surfaces too.
        function test_existing_theme_modes_resolve_unchanged() {
            theme.applyTheme("dark")
            verify(Qt.colorEqual(theme.backgroundColor, "#0D1117"), "dark background unchanged")
            verify(Qt.colorEqual(theme.cardBackground, "#161B22"), "dark card unchanged")
            verify(Qt.colorEqual(theme.textPrimary, "#E6EDF3"), "dark text unchanged")
            theme.applyTheme("nord")
            verify(Qt.colorEqual(theme.backgroundColor, "#2E3440"), "nord background unchanged")
        }

        // A config without a textScale gets the viewing-distance default.
        function test_defaults_are_legible_at_viewing_distance() {
            var fresh = freshTheme.createObject(root)
            compare(fresh.textScale, 1.15, "text scale defaults to Comfortable")
            compare(fresh.fontMinimum, 15, "minimum readable token is 15px")
            compare(fresh.fontData, 46, "data token grows for viewing distance")
            compare(fresh.fontDataLarge, 55, "large data token grows for viewing distance")
            compare(fresh.fontTitle, 20, "title token grows for viewing distance")
            compare(fresh.fontLabel, 17, "label token grows for viewing distance")
            compare(fresh.fontCaption, 15, "caption token grows for viewing distance")
            compare(fresh.reduceMotionPreference, "auto", "preference defaults to auto")
            compare(fresh.systemReduceMotion, false, "no OS signal by default")
            compare(fresh.effectiveReduceMotion, false, "motion stays on by default")
            compare(fresh.motionPage, 250, "motionPage default unchanged")
            compare(fresh.motionValue, 400, "motionValue (data-value easing) defaults to 400ms")
            fresh.destroy()
        }

        // ── Okabe–Ito colour-blind-safe accents ──────────────────────────────
        // Canonical CUD hexes - the palette's guarantee holds for the 8 together,
        // so a "close enough" tone silently breaks it. Pinned exactly.
        function test_okabe_ito_canonical_hexes() {
            var oi = { "oi_black": "#000000", "oi_orange": "#E69F00",
                       "oi_sky_blue": "#56B4E9", "oi_bluish_green": "#009E73",
                       "oi_yellow": "#F0E442", "oi_blue": "#0072B2",
                       "oi_vermillion": "#D55E00", "oi_reddish_purple": "#CC79A7" }
            var count = 0
            for (var name in oi) {
                var p = theme.accentPresets[name]
                verify(p && p.a !== undefined && p.b !== undefined, name + " has a+b tones")
                verify(Qt.colorEqual(p.a, oi[name]), name + " uses the canonical hex " + oi[name])
                theme.applyAccent(name)
                compare(theme.accentName, name, name + " applies")
                verify(Qt.colorEqual(theme.accent, oi[name]), name + " primary set")
                verify(Qt.colorEqual(theme.accent2, p.b), name + " secondary set")
                count++
            }
            compare(count, 8, "all eight Okabe–Ito accents present")
        }

        function test_okabe_ito_accents_are_mutually_distinct() {
            var names = ["oi_black","oi_orange","oi_sky_blue","oi_bluish_green",
                         "oi_yellow","oi_blue","oi_vermillion","oi_reddish_purple"]
            for (var i = 0; i < names.length; i++)
                for (var j = i + 1; j < names.length; j++)
                    verify(!Qt.colorEqual(theme.accentPresets[names[i]].a, theme.accentPresets[names[j]].a),
                           names[i] + " differs from " + names[j])
        }

        function test_okabe_ito_survives_theme_switch() {
            theme.applyAccent("oi_vermillion")
            theme.applyTheme("light")
            verify(Qt.colorEqual(theme.accent, "#D55E00"), "an Okabe–Ito accent survives a theme switch")
        }

        // ── applyAccent ──────────────────────────────────────────────────────
        function test_applyAccent_sets_primary_secondary_and_name() {
            theme.applyAccent("green")
            compare(theme.accentName, "green", "accentName updated")
            verify(Qt.colorEqual(theme.accent, theme.accentPresets["green"].a), "primary accent set")
            verify(Qt.colorEqual(theme.accent2, theme.accentPresets["green"].b), "secondary accent set")
        }

        function test_applyAccent_unknown_falls_back_to_blue() {
            theme.applyAccent("chartreuse")
            verify(Qt.colorEqual(theme.accent, theme.accentPresets["blue"].a),
                   "an unknown accent name falls back to blue")
        }

        // ── applyTheme ───────────────────────────────────────────────────────
        function test_applyTheme_light() {
            theme.applyTheme("light")
            verify(Qt.colorEqual(theme.backgroundColor, "#FFFFFF"), "light background")
            verify(Qt.colorEqual(theme.textPrimary, "#1F2328"), "light text")
            compare(theme.decorative, true, "light keeps decoration on")
            compare(theme.cardBorderWidth, 1, "light border width")
        }

        function test_applyTheme_dark_default() {
            theme.applyTheme("dark")
            verify(Qt.colorEqual(theme.backgroundColor, "#0D1117"), "dark background")
            compare(theme.decorative, true, "dark keeps decoration on")
        }

        function test_applyTheme_high_contrast_disables_decoration() {
            theme.applyTheme("high_contrast")
            compare(theme.decorative, false, "high-contrast turns decoration off")
            compare(theme.cardBorderWidth, 2, "high-contrast thickens the border")
            verify(Qt.colorEqual(theme.cardBorder, "#FFFFFF"), "high-contrast uses a white border")
        }

        function test_applyTheme_reapplies_accent() {
            theme.applyAccent("red")
            theme.applyTheme("midnight")   // ends with applyAccent(accentName)
            verify(Qt.colorEqual(theme.accent, theme.accentPresets["red"].a),
                   "applyTheme re-applies the current accent so it survives a mode switch")
        }

        function test_unknown_mode_uses_dark_default() {
            theme.applyTheme("banana")
            verify(Qt.colorEqual(theme.backgroundColor, "#0D1117"), "an unknown mode falls back to the dark default")
        }

        // ── New Phase-2 theme modes ──────────────────────────────────────────
        // Shared assertions: every token the appliers set is populated, the
        // theme is decorative (all 8 new modes are lush gradients), and the
        // primary text is legibly distinct from the background.
        function _assertThemeCoherent(mode, expectBg, expectDecorative) {
            theme.applyTheme(mode)
            verify(Qt.colorEqual(theme.backgroundColor, expectBg), mode + " sets its backgroundColor")
            // All colour tokens set (non-empty).
            verify(theme.backgroundColor2 != "" && theme.backgroundColor3 != "", mode + " sets bg2/bg3")
            verify(theme.cardBackground != "" && theme.cardBackgroundAlt != "" && theme.cardBorder != "",
                   mode + " sets card tokens")
            verify(theme.textPrimary != "" && theme.textSecondary != "" && theme.textTertiary != "",
                   mode + " sets text tokens")
            // Radii + border width set to sane positive values.
            verify(theme.radiusSm > 0 && theme.radiusMd > 0 && theme.radiusLg > 0 && theme.radiusXl > 0,
                   mode + " sets all radii")
            verify(theme.cardBorderWidth >= 1, mode + " sets a border width")
            compare(theme.decorative, expectDecorative, mode + " decorative flag")
            // Contrast: primary text must differ from the background.
            verify(!Qt.colorEqual(theme.textPrimary, theme.backgroundColor),
                   mode + " has text distinct from background")
        }

        function test_applyTheme_synthwave()   { _assertThemeCoherent("synthwave",   "#1A0B2E", true) }
        function test_applyTheme_cyberpunk()   { _assertThemeCoherent("cyberpunk",   "#04110F", true) }
        function test_applyTheme_deep_forest() { _assertThemeCoherent("deep_forest", "#0A1A0E", true) }
        function test_applyTheme_deep_ocean()  { _assertThemeCoherent("deep_ocean",  "#04121F", true) }
        function test_applyTheme_ember()       { _assertThemeCoherent("ember",       "#1A0E0A", true) }
        function test_applyTheme_vaporwave()   { _assertThemeCoherent("vaporwave",   "#1E0F2E", true) }
        function test_applyTheme_rose_gold()   { _assertThemeCoherent("rose_gold",   "#21121A", true) }
        function test_applyTheme_matrix()      { _assertThemeCoherent("matrix",      "#000000", true) }

        // ── Well-loved developer palettes (all dark, all decorative) ─────────
        function test_applyTheme_nord()        { _assertThemeCoherent("nord",        "#2E3440", true) }
        function test_applyTheme_dracula()     { _assertThemeCoherent("dracula",     "#282A36", true) }
        function test_applyTheme_solarized()   { _assertThemeCoherent("solarized",   "#002B36", true) }
        function test_applyTheme_gruvbox()     { _assertThemeCoherent("gruvbox",     "#282828", true) }
        function test_applyTheme_catppuccin()  { _assertThemeCoherent("catppuccin",  "#1E1E2E", true) }
        function test_applyTheme_tokyonight()  { _assertThemeCoherent("tokyonight",  "#1A1B26", true) }

        function test_new_accents_have_tones() {
            var names = ["cyan","indigo","mint","coral","amber","magenta"]
            for (var i = 0; i < names.length; i++) {
                var p = theme.accentPresets[names[i]]
                verify(p && p.a !== undefined && p.b !== undefined, names[i] + " has a+b tones")
                theme.applyAccent(names[i])
                compare(theme.accentName, names[i], names[i] + " applied")
                verify(Qt.colorEqual(theme.accent, p.a), names[i] + " primary set")
            }
        }

        // ── cardFill derivation ──────────────────────────────────────────────
        function test_cardFill_translucency_scales_with_glass() {
            theme.applyTheme("dark")   // decorative
            theme.glassOpacity = 0.0
            var opaqueA = theme.cardFill().a
            theme.glassOpacity = 1.0
            var glassA = theme.cardFill().a
            fuzzyCompare(opaqueA, 0.84, 0.001, "glass 0 → ~0.84 alpha (near opaque)")
            fuzzyCompare(glassA, 0.22, 0.001, "glass 1 → ~0.22 alpha (most translucent)")
            verify(opaqueA > glassA, "more glass means a more translucent card")
        }

        function test_cardFill_preserves_card_rgb() {
            theme.applyTheme("dark")
            var f = theme.cardFill()
            verify(Qt.colorEqual(Qt.rgba(f.r, f.g, f.b, 1), Qt.rgba(theme.cardBackground.r, theme.cardBackground.g, theme.cardBackground.b, 1)),
                   "cardFill keeps the cardBackground RGB, varying only alpha")
        }

        function test_cardFill_opaque_when_not_decorative() {
            theme.applyTheme("high_contrast")   // decorative false
            var f = theme.cardFill()
            verify(Qt.colorEqual(f, theme.cardBackground), "non-decorative themes use fully-opaque cards")
        }

        // The Glassiness slider must VISIBLY do something even with no wallpaper -
        // the long-standing "slider does nothing" report. The fill can't carry it
        // (lightening a dark card breaks accent contrast; see the WCAG gates), so
        // the visible cue is the border rim-light + top sheen, which more glass
        // brightens. Guards that regression.
        function test_glass_brightens_border_and_sheen() {
            theme.applyTheme("dark")   // decorative, flat dark page
            theme.glassOpacity = 0.0
            var b0 = _snap(theme.cardBorderGlass); var s0 = theme.cardSheen
            theme.glassOpacity = 1.0
            var b1 = _snap(theme.cardBorderGlass); var s1 = theme.cardSheen
            function lum(c) { return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b }
            verify(lum(b1) > lum(b0) + 0.05, "more glass → a visibly brighter card border")
            verify(s1 > s0 + 0.05, "more glass → a stronger top sheen")
            // The fill still frosts (alpha drops) so a wallpaper reads through.
            theme.glassOpacity = 0.0; var a0 = theme.cardFillColor.a
            theme.glassOpacity = 1.0; var a1 = theme.cardFillColor.a
            verify(a1 < a0, "more glass → a more translucent fill")
            theme.glassOpacity = 0.55
        }

        function test_glass_border_solid_when_not_decorative() {
            theme.applyTheme("high_contrast")
            verify(Qt.colorEqual(theme.cardBorderGlass, theme.cardBorder),
                   "high contrast keeps its solid border regardless of glass")
        }

        // ── Category colours are stable across theme switches ────────────────
        function test_category_colors_stable() {
            var before = [theme.catSystem, theme.catProductivity, theme.catInfo,
                          theme.catEntertainment, theme.catGaming, theme.catServices]
            theme.applyTheme("light"); theme.applyTheme("nebula"); theme.applyTheme("dark")
            var after = [theme.catSystem, theme.catProductivity, theme.catInfo,
                         theme.catEntertainment, theme.catGaming, theme.catServices]
            for (var i = 0; i < before.length; i++)
                verify(Qt.colorEqual(before[i], after[i]), "category colour " + i + " is stable across theme switches")
        }

        function test_category_colors_known_values() {
            verify(Qt.colorEqual(theme.catSystem, "#58A6FF"), "catSystem tone")
            verify(Qt.colorEqual(theme.catGaming, "#F0883E"), "catGaming tone")
        }

        // ── glass / glow aliases + motion tokens ─────────────────────────────
        function test_glass_glow_aliases() {
            theme.glassOpacity = 0.33
            fuzzyCompare(theme.glass, 0.33, 1e-9, "glass mirrors glassOpacity")
            theme.showWidgetGlow = false
            compare(theme.glow, false, "glow mirrors showWidgetGlow")
            theme.showWidgetGlow = true
        }

        function test_reduce_motion_zeroes_motion_tokens() {
            theme.reduceMotion = false
            verify(theme.motionPage > 0 && theme.motionFast > 0, "non-zero when motion allowed")
            theme.reduceMotion = true
            compare(theme.motionPage, 0, "motionPage zeroed")
            compare(theme.motionAdd, 0, "motionAdd zeroed")
            compare(theme.motionFast, 0, "motionFast zeroed")
            // The value-tracking token every bar/gauge Behavior rides on: this
            // zero is what collapses ALL of them to an instant jump at once.
            compare(theme.motionValue, 0, "motionValue zeroed")
            theme.reduceMotion = false
            compare(theme.motionValue, 400, "motionValue restored with motion on")
        }

        // ── Reduce-motion precedence: explicit > OS > legacy flag ────────────
        // The whole matrix is pinned, because the interesting cases are the
        // conflicts and a regression here is silent (motion just stops, or
        // doesn't). `data` rows: [preference, osSignal, configFlag, expected].
        function test_reduce_motion_precedence_data() {
            return [
                // No explicit choice → the OS signal decides.
                { tag: "auto/os-off/cfg-off", pref: "auto", os: false, cfg: false, expect: false },
                { tag: "auto/os-ON/cfg-off",  pref: "auto", os: true,  cfg: false, expect: true },
                // Legacy persisted flag still reduces motion on its own.
                { tag: "auto/os-off/cfg-ON",  pref: "auto", os: false, cfg: true,  expect: true },
                { tag: "auto/os-ON/cfg-ON",   pref: "auto", os: true,  cfg: true,  expect: true },
                // THE precedence case: the OS asks to reduce motion, the user has
                // explicitly said "off" on this device → the user wins, motion RUNS.
                { tag: "off/os-ON  (user beats OS)", pref: "off", os: true,  cfg: true,  expect: false },
                { tag: "off/os-off",                pref: "off", os: false, cfg: false, expect: false },
                // Explicit "on" reduces motion even with no OS signal at all.
                { tag: "on/os-off (user beats OS)",  pref: "on",  os: false, cfg: false, expect: true },
                { tag: "on/os-ON",                   pref: "on",  os: true,  cfg: true,  expect: true },
                // An unrecognised preference must degrade to "auto", never throw.
                { tag: "garbage → auto/os-ON",       pref: "zzz", os: true,  cfg: false, expect: true }
            ]
        }

        function test_reduce_motion_precedence(d) {
            theme.reduceMotionPreference = d.pref
            theme.systemReduceMotion = d.os
            theme.reduceMotion = d.cfg
            compare(theme.effectiveReduceMotion, d.expect, d.tag)
            compare(theme.motionPage, d.expect ? 0 : 250, d.tag + " → motionPage")
            compare(theme.motionFast, d.expect ? 0 : 150, d.tag + " → motionFast")
        }

        // The OS signal must never leak back into the persisted config flag -
        // main.qml aliases `reduceMotion` onto the saved value, so a write here
        // would rewrite the user's config from an unrelated desktop setting.
        function test_os_signal_does_not_mutate_config_flag() {
            theme.reduceMotion = false
            theme.systemReduceMotion = true
            compare(theme.effectiveReduceMotion, true, "OS signal reduces motion")
            compare(theme.reduceMotion, false, "…without touching the persisted flag")
        }

        function test_effective_reduce_motion_is_reactive() {
            theme.reduceMotionPreference = "auto"
            theme.systemReduceMotion = false
            compare(theme.motionPage, 250, "motion running")
            theme.systemReduceMotion = true   // e.g. the OS setting flips at runtime
            compare(theme.motionPage, 0, "motion tokens react to a live OS change")
        }

        // ── Text scale ───────────────────────────────────────────────────────
        function test_text_scale_multiplies_font_tokens() {
            theme.textScale = 1.5
            compare(theme.fontData, 60, "fontData scales (40 × 1.5)")
            compare(theme.fontDataLarge, 72, "fontDataLarge scales (48 × 1.5)")
            compare(theme.fontTitle, 26, "fontTitle scales (17 × 1.5 → 26)")
            compare(theme.fontLabel, 23, "fontLabel scales (15 × 1.5 → 23)")
            compare(theme.fontCaption, 20, "fontCaption scales (13 × 1.5 → 20)")
        }

        function test_text_scale_is_clamped() {
            theme.textScale = 99.0
            compare(theme.textScaleEff, 1.6, "absurdly large scale clamps to 1.6")
            compare(theme.fontData, 64, "…and the token follows the clamp (40 × 1.6)")
            theme.textScale = 0.0
            compare(theme.textScaleEff, 0.8, "zero/negative scale clamps to 0.8")
            compare(theme.fontData, 32, "…and the token follows the clamp (40 × 0.8)")
        }

        function test_text_scale_tokens_stay_whole_pixels() {
            theme.textScale = 1.13   // deliberately awkward multiplier
            compare(theme.fontLabel, Math.round(theme.fontLabel), "fontLabel is a whole pixel size")
            compare(theme.fontCaption, Math.round(theme.fontCaption), "fontCaption is a whole pixel size")
            verify(theme.fontCaption > 0, "fontCaption stays positive")
        }

        function test_text_scale_survives_theme_switch() {
            theme.textScale = 1.4
            theme.applyTheme("light")
            compare(theme.fontData, 56, "text scale is independent of the theme mode (40 × 1.4)")
        }

        // ── Distro-evoking palettes ──────────────────────────────────────────
        // Colour-only palettes; there is no mark to assert on. What CAN regress is
        // the thing they were added for: a new `case` silently falling through to
        // the dark default, or a hand-tuned hex quietly making text unreadable.

        readonly property var distroModes: ["arch", "cachyos", "debian", "fedora",
                                            "popos", "aubergine", "crimson"]

        // WCAG 2.1 relative luminance. Qt colour components are sRGB in 0..1, so
        // they go straight into the transfer function without a /255 step.
        function _relLum(c) {
            function lin(v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
        }

        function _contrast(fg, bg) {
            var a = _relLum(fg), b = _relLum(bg)
            return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05)
        }

        // Flatten a translucent fill onto an opaque backdrop - cardFill() is
        // alpha-blended over the page background, so the surface actually under
        // the text is the composite, not cardBackground itself.
        function _over(fg, bg) {
            return Qt.rgba(fg.a * fg.r + (1 - fg.a) * bg.r,
                           fg.a * fg.g + (1 - fg.a) * bg.g,
                           fg.a * fg.b + (1 - fg.a) * bg.b, 1)
        }

        // A hex string is only coerced to a `color` on assignment to a colour
        // property, not when passed to a JS function - the maths helpers above
        // would see a bare string with no .r/.g/.b. Parse it instead of bouncing
        // it through a scratch colour property: a `color` read out of a property
        // is a live handle onto that property, so a scratch one would make every
        // literal in an expression collapse onto the last value written.
        function _c(hex) {
            var h = hex.replace("#", "")
            return Qt.rgba(parseInt(h.substr(0, 2), 16) / 255, parseInt(h.substr(2, 2), 16) / 255,
                           parseInt(h.substr(4, 2), 16) / 255, 1)
        }

        // Detach a colour from the property it was read from - see above. Storing
        // `theme.backgroundColor` in an array keeps a handle onto the property, so
        // the next applyTheme() would silently rewrite everything already stored.
        function _snap(c) { return Qt.rgba(c.r, c.g, c.b, c.a) }

        function _themeModes() {
            return theme.themeCatalog.map(function (entry) { return entry.k })
        }

        function _pageSurfaces() {
            return [
                { name: "backgroundColor", color: _snap(theme.backgroundColor) },
                { name: "backgroundColor2", color: _snap(theme.backgroundColor2) },
                { name: "backgroundColor3", color: _snap(theme.backgroundColor3) }
            ]
        }

        // Sanity-check the contrast maths itself against known-exact endpoints,
        // so a broken formula cannot silently pass every legibility test below.
        function test_contrast_helper_is_correct() {
            fuzzyCompare(_contrast(_c("#FFFFFF"), _c("#000000")), 21.0, 0.01, "white on black is 21:1")
            fuzzyCompare(_contrast(_c("#FFFFFF"), _c("#FFFFFF")), 1.0, 0.01, "a colour on itself is 1:1")
            // #767676 on white is the WCAG reference boundary case (≈4.54:1).
            fuzzyCompare(_contrast(_c("#767676"), _c("#FFFFFF")), 4.54, 0.02, "grey 0x76 on white ≈ 4.54:1")
            // Contrast is symmetric: the ratio does not depend on which is on top.
            fuzzyCompare(_contrast(_c("#000000"), _c("#FFFFFF")), 21.0, 0.01, "…and is order-independent")
            fuzzyCompare(_over(Qt.rgba(1, 0, 0, 0.5), _c("#000000")).r, 0.5, 0.001,
                         "50% red over black flattens to half-intensity red")
            fuzzyCompare(_over(Qt.rgba(1, 0, 0, 0.5), _c("#000000")).a, 1.0, 0.001,
                         "…and the composite is opaque")
        }

        // Systemic numeric legibility gate. It is tied to the selectable
        // catalogues rather than a hand-maintained theme subset, so a newly
        // added mode or accent enters the matrix automatically.
        function test_all_catalog_text_tokens_meet_wcag_aa() {
            var modes = _themeModes()
            compare(modes.length, 29, "all selectable themes enter the contrast matrix")
            for (var m = 0; m < modes.length; m++) {
                var mode = modes[m]
                theme.applyTheme(mode)
                var pages = _pageSurfaces()
                for (var p = 0; p < pages.length; p++) {
                    var page = pages[p]
                    var pagePrimary = _contrast(theme.textPrimary, page.color)
                    var pageSecondary = _contrast(theme.textSecondary, page.color)
                    verify(pagePrimary >= 4.5,
                           mode + "." + page.name + " primary=" + pagePrimary.toFixed(2)
                           + ":1, needs 4.5:1")
                    verify(pageSecondary >= 7.0,
                           mode + "." + page.name + " secondary=" + pageSecondary.toFixed(2)
                           + ":1, needs 7:1 decoration margin")
                    var glassValues = [0.0, 1.0]
                    for (var g = 0; g < glassValues.length; g++) {
                        theme.glassOpacity = glassValues[g]
                        var card = _over(theme.cardFill(), page.color)
                        var cardPrimary = _contrast(theme.textPrimary, card)
                        var cardSecondary = _contrast(theme.textSecondary, card)
                        verify(cardPrimary >= 4.5,
                               mode + "." + page.name + " card primary at glass="
                               + glassValues[g] + " is " + cardPrimary.toFixed(2)
                               + ":1, needs 4.5:1")
                        verify(cardSecondary >= 7.0,
                               mode + "." + page.name + " card secondary at glass="
                               + glassValues[g] + " is " + cardSecondary.toFixed(2)
                               + ":1, needs 7:1 decoration margin")
                    }
                }
            }
        }

        function test_all_catalog_accents_meet_nontext_contrast() {
            var modes = _themeModes()
            var accents = Object.keys(theme.accentPresets).sort()
            compare(accents.length, 29, "all selectable accents enter the contrast matrix")
            for (var m = 0; m < modes.length; m++) {
                var mode = modes[m]
                theme.applyTheme(mode)
                var pages = _pageSurfaces()
                for (var a = 0; a < accents.length; a++) {
                    var accentName = accents[a]
                    theme.applyAccent(accentName)
                    for (var p = 0; p < pages.length; p++) {
                        var page = pages[p]
                        var glassValues = [0.0, 1.0]
                        for (var g = 0; g < glassValues.length; g++) {
                            theme.glassOpacity = glassValues[g]
                            var card = _over(theme.cardFill(), page.color)
                            var renderedAccent = theme.readableAccentFor(accentName)
                            var ratio = _contrast(renderedAccent, card)
                            verify(ratio >= 3.0,
                                   mode + "/" + accentName + " on " + page.name
                                   + " at glass=" + glassValues[g] + " is "
                                   + ratio.toFixed(2) + ":1, needs 3:1")
                        }
                    }
                }
            }
        }

        // Each mode must paint its OWN background - the dark default (#0D1117) is
        // what a missing `case` produces, so this is the fall-through guard.
        function test_distro_modes_resolve_data() {
            return [
                { tag: "arch",      mode: "arch",      bg: "#14181D", card: "#1B2129" },
                { tag: "cachyos",   mode: "cachyos",   bg: "#131611", card: "#1C221A" },
                { tag: "debian",    mode: "debian",    bg: "#16121A", card: "#1F1922" },
                { tag: "fedora",    mode: "fedora",    bg: "#0E1626", card: "#152034" },
                { tag: "popos",     mode: "popos",     bg: "#1E1C1B", card: "#262322" },
                { tag: "aubergine", mode: "aubergine", bg: "#2C0A20", card: "#3A0F2A" },
                { tag: "crimson",   mode: "crimson",   bg: "#0B0507", card: "#16080B" }
            ]
        }

        function test_distro_modes_resolve(d) {
            _assertThemeCoherent(d.mode, d.bg, true)
            verify(Qt.colorEqual(theme.cardBackground, d.card), d.mode + " sets its card surface")
            verify(!Qt.colorEqual(theme.backgroundColor, "#0D1117"),
                   d.mode + " is a real case, not a fall-through to the dark default")
        }

        // Every colour token must be fully opaque: these tokens are painted as
        // solid surfaces, and cardFill() derives its alpha from glassOpacity - a
        // token that arrived translucent would double-dip and wash the card out.
        function test_distro_tokens_are_opaque() {
            for (var i = 0; i < distroModes.length; i++) {
                var mode = distroModes[i]
                theme.applyTheme(mode)
                var tokens = { backgroundColor: _snap(theme.backgroundColor),
                               backgroundColor2: _snap(theme.backgroundColor2),
                               backgroundColor3: _snap(theme.backgroundColor3),
                               cardBackground: _snap(theme.cardBackground),
                               cardBackgroundAlt: _snap(theme.cardBackgroundAlt),
                               cardBorder: _snap(theme.cardBorder),
                               textPrimary: _snap(theme.textPrimary),
                               textSecondary: _snap(theme.textSecondary),
                               textTertiary: _snap(theme.textTertiary) }
                for (var name in tokens)
                    compare(tokens[name].a, 1.0, mode + "." + name + " is fully opaque")
            }
        }

        // Seven palettes that render the same would be six wasted menu entries.
        function test_distro_palettes_are_mutually_distinct() {
            var seen = []
            for (var i = 0; i < distroModes.length; i++) {
                theme.applyTheme(distroModes[i])
                seen.push({ mode: distroModes[i], bg: _snap(theme.backgroundColor),
                            card: _snap(theme.cardBackground), border: _snap(theme.cardBorder) })
            }
            for (var a = 0; a < seen.length; a++) {
                // Within one palette the surfaces must form tiers, not one flat colour.
                verify(!Qt.colorEqual(seen[a].bg, seen[a].card),
                       seen[a].mode + " separates its card from its page background")
                verify(!Qt.colorEqual(seen[a].card, seen[a].border),
                       seen[a].mode + " separates its border from its card")
                for (var b = a + 1; b < seen.length; b++)
                    verify(!Qt.colorEqual(seen[a].bg, seen[b].bg) || !Qt.colorEqual(seen[a].card, seen[b].card),
                           seen[a].mode + " is a different palette from " + seen[b].mode)
            }
        }

        // THE legibility gate, computed rather than eyeballed. Text sits on
        // cardFill(), whose alpha sweeps with glassOpacity, so check BOTH ends of
        // the range: at max glass the card thins toward the page background, which
        // is where a palette with too little page/card separation would fail.
        function test_distro_text_on_cardfill_meets_wcag_aa() {
            for (var i = 0; i < distroModes.length; i++) {
                var mode = distroModes[i]
                theme.applyTheme(mode)
                var glassValues = [0.0, 1.0]
                for (var g = 0; g < glassValues.length; g++) {
                    theme.glassOpacity = glassValues[g]
                    var surface = _over(theme.cardFill(), theme.backgroundColor)
                    var primary = _contrast(theme.textPrimary, surface)
                    verify(primary >= 4.5, mode + " textPrimary on cardFill @ glass=" + glassValues[g]
                           + " is " + primary.toFixed(2) + ":1 (needs ≥ 4.5)")
                    // Secondary carries real content (labels, units), so it takes
                    // the same bar. Tertiary is decorative de-emphasis and does not.
                    var secondary = _contrast(theme.textSecondary, surface)
                    verify(secondary >= 4.5, mode + " textSecondary on cardFill @ glass=" + glassValues[g]
                           + " is " + secondary.toFixed(2) + ":1 (needs ≥ 4.5)")
                }
                theme.glassOpacity = 0.6
            }
        }

        // The matching accents are drawn as fills/gradients on the card, so they
        // take the WCAG non-text bar (3:1) rather than the text one.
        function test_distro_accents_separate_from_their_card() {
            for (var i = 0; i < distroModes.length; i++) {
                var mode = distroModes[i]
                theme.applyTheme(mode)
                theme.applyAccent(mode)      // accent shares the theme's name
                var surface = _over(theme.cardFill(), theme.backgroundColor)
                var ra = _contrast(theme.accent, surface)
                var rb = _contrast(theme.accent2, surface)
                verify(ra >= 3.0, mode + " accent on cardFill is " + ra.toFixed(2) + ":1 (needs ≥ 3.0)")
                verify(rb >= 3.0, mode + " accent2 on cardFill is " + rb.toFixed(2) + ":1 (needs ≥ 3.0)")
            }
        }

        // A distro theme must not hijack the accent the user picked: applyTheme
        // ends with applyAccent(accentName), and these modes deliberately do not
        // touch it. The paired accent is opt-in, by name.
        function test_distro_theme_does_not_clobber_user_accent() {
            theme.applyAccent("oi_bluish_green")
            theme.applyTheme("debian")
            verify(Qt.colorEqual(theme.accent, "#009E73"),
                   "a distro theme leaves the user's chosen accent alone")
            compare(theme.accentName, "oi_bluish_green", "…and its name")
        }

        // ── BACKWARD COMPATIBILITY ───────────────────────────────────────────
        // Theme modes are stored BY NAME in config (Dashboard.applyAppearance →
        // applyTheme(a.theme)), so an existing user's saved mode must keep
        // painting the exact surfaces it painted before the distro palettes
        // landed. Literals on purpose: reading these from theme.applyTheme's own
        // output would just compare the table to itself and pass unconditionally.
        function test_legacy_theme_palettes_unchanged_data() {
            return [
                { tag: "dark",          mode: "dark",          bg: "#0D1117", card: "#161B22", text: "#E6EDF3", border: "#30363D" },
                { tag: "light",         mode: "light",         bg: "#FFFFFF", card: "#F6F8FA", text: "#1F2328", border: "#D0D7DE" },
                { tag: "oled",          mode: "oled",          bg: "#000000", card: "#0A0A0A", text: "#E0E0E0", border: "#1A1A1A" },
                { tag: "high_contrast", mode: "high_contrast", bg: "#000000", card: "#1A1A1A", text: "#FFFFFF", border: "#FFFFFF" },
                { tag: "midnight",      mode: "midnight",      bg: "#0B1026", card: "#16192E", text: "#EDEFFF", border: "#33385F" },
                { tag: "aurora",        mode: "aurora",        bg: "#04140F", card: "#0E1E24", text: "#EAFBF4", border: "#25505A" },
                { tag: "sunset",        mode: "sunset",        bg: "#1B0A20", card: "#26132A", text: "#FFEFF6", border: "#5A3355" },
                { tag: "nebula",        mode: "nebula",        bg: "#0E0722", card: "#1A1132", text: "#F1EBFF", border: "#413063" },
                { tag: "synthwave",     mode: "synthwave",     bg: "#1A0B2E", card: "#241141", text: "#FCEEFF", border: "#5B2A8C" },
                { tag: "cyberpunk",     mode: "cyberpunk",     bg: "#04110F", card: "#0A1A18", text: "#EAFFF9", border: "#1C4A42" },
                { tag: "deep_forest",   mode: "deep_forest",   bg: "#0A1A0E", card: "#12251A", text: "#EAF7EC", border: "#2E5238" },
                { tag: "deep_ocean",    mode: "deep_ocean",    bg: "#04121F", card: "#0A1E2E", text: "#E6F6FF", border: "#1E4A63" },
                { tag: "ember",         mode: "ember",         bg: "#1A0E0A", card: "#241310", text: "#FFEFE6", border: "#5C3324" },
                { tag: "vaporwave",     mode: "vaporwave",     bg: "#1E0F2E", card: "#281640", text: "#FBEEFF", border: "#563A78" },
                { tag: "rose_gold",     mode: "rose_gold",     bg: "#21121A", card: "#2A1721", text: "#FDEEF3", border: "#5E3A4A" },
                { tag: "matrix",        mode: "matrix",        bg: "#000000", card: "#050D05", text: "#B6FFB6", border: "#164016" },
                { tag: "nord",          mode: "nord",          bg: "#2E3440", card: "#3B4252", text: "#ECEFF4", border: "#4C566A" },
                { tag: "dracula",       mode: "dracula",       bg: "#282A36", card: "#343746", text: "#F8F8F2", border: "#44475A" },
                { tag: "solarized",     mode: "solarized",     bg: "#002B36", card: "#073642", text: "#EEE8D5", border: "#17616B" },
                { tag: "gruvbox",       mode: "gruvbox",       bg: "#282828", card: "#3C3836", text: "#EBDBB2", border: "#665C54" },
                { tag: "catppuccin",    mode: "catppuccin",    bg: "#1E1E2E", card: "#313244", text: "#CDD6F4", border: "#585B70" },
                { tag: "tokyonight",    mode: "tokyonight",    bg: "#1A1B26", card: "#24283B", text: "#C0CAF5", border: "#3B4261" }
            ]
        }

        function test_legacy_theme_palettes_unchanged(d) {
            theme.applyTheme(d.mode)
            verify(Qt.colorEqual(theme.backgroundColor, d.bg), d.mode + " background is still " + d.bg)
            verify(Qt.colorEqual(theme.cardBackground, d.card), d.mode + " card is still " + d.card)
            verify(Qt.colorEqual(theme.textPrimary, d.text), d.mode + " textPrimary is still " + d.text)
            verify(Qt.colorEqual(theme.cardBorder, d.border), d.mode + " cardBorder is still " + d.border)
        }

        // Adding names to accentPresets must not retune the ones already stored in
        // users' configs. (test_existing_accents_resolve_unchanged pins the 14
        // house tones; this pins the Okabe–Ito set's `b` tints, which nothing else
        // pins as literals.)
        function test_legacy_accent_secondary_tones_unchanged() {
            var legacyB = { "blue": "#79C0FF", "green": "#7EE787", "red": "#FF7B72",
                            "oi_orange": "#EFC159", "oi_blue": "#59A3CD",
                            "oi_vermillion": "#E49659" }
            for (var name in legacyB) {
                theme.applyAccent(name)
                verify(Qt.colorEqual(theme.accent2, legacyB[name]),
                       "stored accent '" + name + "' keeps its secondary tone " + legacyB[name])
            }
        }

        // ── Bundled a11y fonts (E4) ──────────────────────────────────────────
        // Proof the TTFs ACTUALLY load - status must reach Ready and the family
        // must resolve to the real name, not silently fall back to a system
        // font. If the wrong file loads, the name assertion catches it (proven
        // 2026-08-04 by giving Atkinson's filename Lexend's bytes).
        //
        // What this does NOT cover, despite an earlier comment here claiming it
        // did: the **qrc wiring**. This file imports "../../ui/qml" as a
        // FILESYSTEM path, so Theme.qml takes the non-qrc branch of `_fontsDir`
        // and these loaders read assets/fonts/ off disk. Repointing an alias in
        // assets/fonts.qrc leaves every assertion here green - measured, same
        // day. The qrc side is covered statically by
        // scripts/check_bundled_fonts.py instead.
        function test_bundled_fonts_actually_load() {
            tryCompare(theme.hyperlegibleLoader, "status", FontLoader.Ready)
            tryCompare(theme.hyperlegibleBoldLoader, "status", FontLoader.Ready)
            tryCompare(theme.lexendLoader, "status", FontLoader.Ready)
            tryCompare(theme.lexendBoldLoader, "status", FontLoader.Ready)
            compare(theme.hyperlegibleLoader.name, "Atkinson Hyperlegible",
                    "regular TTF resolves to its real family name")
            compare(theme.lexendLoader.name, "Lexend",
                    "Lexend TTF resolves to its real family name")
        }

        function test_font_family_tokens_resolve_to_loaded_families() {
            tryCompare(theme.hyperlegibleLoader, "status", FontLoader.Ready)
            tryCompare(theme.lexendLoader, "status", FontLoader.Ready)
            compare(theme.fontFamilyHyperlegible, "Atkinson Hyperlegible")
            compare(theme.fontFamilyLexend, "Lexend")
        }

        // Changing the default look is a product decision (D2, decided
        // 2026-08-04: Atkinson Hyperlegible, the accessibility-forward pick).
        // The comment here used to say the default MUST stay the system font
        // stack, which the body already contradicted - it was left behind when
        // the default moved.
        function test_font_choice_defaults_to_hyperlegible() {
            // A fresh Theme with no config picks it up, and fontDisplay resolves
            // to the LOADED Atkinson family rather than a literal family string.
            var fresh = freshTheme.createObject(root)
            compare(fresh.fontChoice, "hyperlegible")
            compare(fresh.fontDisplay, fresh.fontFamilyHyperlegible)
            // Assert the family by name. This used to be
            //   indexOf("atkinson") >= 0 || fontDisplay.length > 0
            // whose right-hand clause is true for ANY non-empty string, so the
            // whole verify passed for every possible font - it could not fail.
            compare(fresh.fontDisplay.toLowerCase().indexOf("atkinson") >= 0, true,
                    "the default resolves to Atkinson, not a fallback face")
            fresh.destroy()
        }

        // D1 (decided 2026-08-04: the calm palette). Rust pins the same value -
        // `config::tests::test_default_config` asserts `theme.mode == "nord"`.
        // These are two independent literals in two languages that must agree,
        // and nothing links them, so each side pins its own.
        function test_default_theme_key_is_the_calm_palette() {
            compare(theme.defaultThemeKey, "nord",
                    "a fresh install opens on the calm palette (D1)")
            // ...and the key must name a theme that actually exists, or every
            // fresh install falls through applyTheme's default branch.
            var fresh = freshTheme.createObject(root)
            fresh.applyTheme(fresh.defaultThemeKey)
            var calm = fresh.bg
            fresh.applyTheme("nord")
            compare(String(fresh.bg), String(calm),
                    "defaultThemeKey resolves to the real nord palette")
            fresh.destroy()
        }

        function test_a_fresh_install_is_calm_and_quiet() {
            // The beta ships "Calm by default": a fresh Theme has widget glow OFF.
            // (The animated background lives on main.qml, not Theme, so it is
            // guarded where the harness can see it - this pins the half Theme owns.)
            // Quiet-by-default means the distracting ambient effects are off out of
            // the box; the user opts INTO them via Appearance.
            var fresh = freshTheme.createObject(root)
            compare(fresh.showWidgetGlow, false, "glow is off on a fresh install (calm)")
            compare(fresh.glow, false, "the derived glow token follows")
            fresh.destroy()
        }

        function test_font_choice_wires_font_display() {
            theme.fontChoice = "hyperlegible"
            compare(theme.fontDisplay, theme.fontFamilyHyperlegible)
            theme.fontChoice = "lexend"
            compare(theme.fontDisplay, theme.fontFamilyLexend)
            // "system" means the product's OWN face, and it must resolve to a
            // real loaded family. Comparing against the old literal
            // "Inter, Segoe UI, Roboto, sans-serif" passed happily while Qt was
            // matching that whole string as one family name and rendering the
            // machine's default sans instead - a test can only see that if it
            // asserts the resolution, not the spelling.
            theme.fontChoice = "system"
            compare(theme.interLoader.status, FontLoader.Ready,
                    "the bundled UI face is loaded")
            compare(theme.fontDisplay, theme.interLoader.name)
        }

        // A fontChoice value from a newer build must degrade to system, never
        // to a broken family string.
        function test_font_choice_unknown_value_falls_back_to_system() {
            theme.fontChoice = "papyrus"
            compare(theme.fontDisplay, theme.interLoader.name)
        }

        // fontMono is exempt on purpose: tabular readouts need fixed pitch.
        //
        // Assert the INTENT, not a literal family string. This used to compare
        // against "JetBrains Mono, Fira Code, monospace", which looked like a
        // CSS stack but was matched by Qt as ONE family name - so the assertion
        // passed while the rendered face was whatever the local fontconfig
        // happened to choose, and it chose differently on CI (a proportional
        // sans) than here. A test that pins the string cannot see that.
        function test_font_choice_does_not_touch_mono() {
            var before = theme.fontMono
            theme.fontChoice = "lexend"
            compare(theme.fontMono, before,
                    "fontChoice must not touch the tabular-readout face")
            compare(theme.monoLoader.status, FontLoader.Ready,
                    "the bundled fixed-pitch face is loaded")
            compare(theme.fontMono, theme.monoLoader.name,
                    "fontMono resolves through the bundled face, not fontconfig")
        }
    }
}
