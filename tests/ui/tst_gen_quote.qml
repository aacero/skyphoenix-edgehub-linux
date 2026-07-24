import QtQuick
import QtTest
import "../../ui/qml" as App


// ─────────────────────────────────────────────────────────────────────────
// Comprehensive tests for widget:quote - ui/qml/widgets/QuoteWidget.qml
// (the "Daily Quote" rotating-quote widget).
//
// Drives config through the shared DashboardStore (setSetting/patchSettings on
// "test-instance") exactly the way the live dashboard does, and asserts on the
// widget's derived properties + functions (cfg, category, customText,
// parseCustom(), pool, dailyIdx, manualIdx, idx, q, shuffle(), effAccent).
//
// ─────────────────────────────────────────────────────────────────────────
Item {
    id: root
    width: 480; height: 640

    WidgetHarness {
        id: hQuote; anchors.fill: parent
        widgetFile: "QuoteWidget.qml"; expanded: true
    }
    App.WidgetConfigSchema { id: schema }
    WidgetHarness {
        id: hQuoteMirror
        x: 0; y: 0; width: 320; height: 320
        widgetFile: "QuoteWidget.qml"; expanded: false; active: false
        visible: false
    }

    // Wipe per-instance settings and reset transient widget state so each test
    // starts from the widget's documented defaults (category "focus", no manual
    // pick, no per-instance appearance overrides).
    function reset() {
        var s = hQuote.storeCtl.settingsFor("test-instance")
        for (var k in s) delete s[k]
        hQuote.storeCtl._touchSettings()
        var w = hQuote.item
        w.manualIdx = -1
        w.accentName = ""
        w.titleOverride = ""
        w.cardBackdrop = "none"
    }
    function patch(o) { hQuote.storeCtl.patchSettings("test-instance", o) }
    function set(k, v) { hQuote.storeCtl.setSetting("test-instance", k, v) }
    function cfg() { return hQuote.storeCtl.settingsFor("test-instance") }

    // Recursively find the first descendant whose `prop` equals `val`.
    function findByProp(node, prop, val) {
        if (!node || !node.children) return null
        for (var i = 0; i < node.children.length; i++) {
            var c = node.children[i]
            if (c[prop] !== undefined && c[prop] === val) return c
            var r = findByProp(c, prop, val)
            if (r) return r
        }
        return null
    }

    // ── Config: category / customText / pool selection + reactivity ─────────
    TestCase {
        name: "QuoteConfig"
        when: windowShown
        function init() { tryVerify(function () { return hQuote.ready }, 3000); reset() }

        function test_default_category_is_focus() {
            var w = hQuote.item
            compare(w.category, "focus", "default category is focus")
            compare(w.customText, "", "default customText is empty")
            compare(w.pool[0].t, w.library["focus"][0].t, "pool is the focus library")
        }

        function test_category_selects_matching_library() {
            var w = hQuote.item
            set("category", "stoic")
            compare(w.category, "stoic")
            compare(w.pool[0].t, w.library["stoic"][0].t, "stoic library selected")
            set("category", "humor")
            compare(w.pool[0].t, w.library["humor"][0].t, "humor library selected")
            set("category", "kindness")
            compare(w.pool[0].t, w.library["kindness"][0].t, "kindness library selected")
        }

        function test_every_bundled_quote_has_provenance_and_rights() {
            var w = hQuote.item
            for (var category in w.library) {
                var entries = w.library[category]
                verify(entries.length > 0, category + " has bundled entries")
                for (var i = 0; i < entries.length; i++) {
                    verify(entries[i].t.length > 0, category + " entry " + i + " has text")
                    verify(entries[i].a.length > 0, category + " entry " + i + " has attribution")
                    verify(entries[i].s.length > 0, category + " entry " + i + " has a source")
                    verify(entries[i].r.length > 0, category + " entry " + i + " has rights status")
                }
            }
        }

        function test_unknown_category_falls_back_to_focus() {
            var w = hQuote.item
            set("category", "does-not-exist")
            compare(w.pool[0].t, w.library["focus"][0].t, "unknown category → focus fallback")
        }

        function test_custom_empty_is_explicit_and_never_changes_source() {
            var w = hQuote.item
            patch({ category: "custom", customText: "" })
            compare(w.pool.length, 0, "empty custom mode has no bundled fallback")
            compare(w.customLibraryEmpty, true)
            compare(w.customIssue, "Add at least one custom quote in settings")
            compare(w.displayQuoteText, w.customIssue)
            compare(w.showGlyph, false, "empty state does not decorate guidance as a quote")
        }

        function test_custom_whitespace_is_explicit() {
            var w = hQuote.item
            patch({ category: "custom", customText: "   \n  \n\t" })
            compare(w.pool.length, 0)
            compare(w.customLibraryEmpty, true)
            compare(w.customIssue, "Add at least one custom quote in settings")
        }

        function test_custom_valid_lines_used() {
            var w = hQuote.item
            patch({ category: "custom", customText: "Alpha\nBeta" })
            compare(w.pool.length, 2, "two custom quotes")
            compare(w.pool[0].t, "Alpha")
            compare(w.pool[1].t, "Beta")
            compare(w.pool[0].s, "Custom text")
            compare(w.pool[0].r, "User supplied")
        }

        function test_bundled_categories_are_large_enough_to_avoid_repetition() {
            var w = hQuote.item
            for (var category in w.library)
                verify(w.library[category].length >= 8,
                       category + " has at least eight locally authored entries")
        }

        function test_author_display_modes_are_reactive() {
            var w = hQuote.item
            patch({ category: "custom", customText: "Words without a named author" })
            compare(w.showAuthor, false, "auto hides a missing attribution")
            set("authorDisplay", "always")
            compare(w.showAuthor, true)
            compare(w.authorText, "Unknown author")
            set("authorDisplay", "hide")
            compare(w.showAuthor, false)
        }

        // cfg re-reads on store.revision, so editing category/customText in the
        // Manager updates the displayed quote without a reload.
        function test_reacts_to_store_revision() {
            var w = hQuote.item
            patch({ category: "custom", customText: "First line only" })
            compare(w.q.t, "First line only", "initial custom quote shown")
            set("customText", "Edited line")
            compare(w.q.t, "Edited line", "editing customText updates the quote reactively")
            set("category", "stoic")
            compare(w.pool[0].t, w.library["stoic"][0].t, "switching category updates reactively")
        }
    }

    // ── parseCustom: separators, trimming, blank lines, CRLF ────────────────
    TestCase {
        name: "QuoteParse"
        when: windowShown
        function init() { tryVerify(function () { return hQuote.ready }, 3000); reset() }

        function test_emdash_separator() {
            var w = hQuote.item
            var separator = String.fromCharCode(0x2014)
            patch({ category: "custom", customText: "Stay hungry " + separator + " Steve Jobs" })
            compare(w.pool[0].t, "Stay hungry", "text before typographic separator")
            compare(w.pool[0].a, "Steve Jobs", "author after typographic separator")
        }

        function test_double_hyphen_separator() {
            var w = hQuote.item
            patch({ category: "custom", customText: "Be brave -- Someone" })
            compare(w.pool[0].t, "Be brave")
            compare(w.pool[0].a, "Someone")
        }

        function test_pipe_separator() {
            var w = hQuote.item
            patch({ category: "custom", customText: "Onward | Captain" })
            compare(w.pool[0].t, "Onward")
            compare(w.pool[0].a, "Captain")
        }

        function test_ascii_hyphen_separator() {
            var w = hQuote.item
            patch({ category: "custom", customText: "Stay hungry - Steve Jobs" })
            compare(w.pool[0].t, "Stay hungry",
                    "'Text - Author' should split the text before the hyphen")
            compare(w.pool[0].a, "Steve Jobs",
                    "'Text - Author' should attribute the author after the hyphen")
        }

        function test_no_separator_gives_empty_author() {
            var w = hQuote.item
            patch({ category: "custom", customText: "A line with no author" })
            compare(w.pool[0].t, "A line with no author")
            compare(w.pool[0].a, "", "no separator → empty author")
        }

        function test_trims_and_skips_blank_lines() {
            var w = hQuote.item
            patch({ category: "custom", customText: "  padded quote  \n\n   \nSecond" })
            compare(w.pool.length, 2, "blank/whitespace lines are skipped")
            compare(w.pool[0].t, "padded quote", "leading/trailing space trimmed")
            compare(w.pool[1].t, "Second")
        }

        function test_handles_crlf_line_endings() {
            var w = hQuote.item
            patch({ category: "custom", customText: "One\r\nTwo\r\nThree" })
            compare(w.pool.length, 3, "CRLF-separated lines parse into three quotes")
            compare(w.pool[0].t, "One", "no stray carriage return on the text")
            compare(w.pool[2].t, "Three")
        }

        function test_empty_quote_before_separator_reports_line_number() {
            var w = hQuote.item
            patch({ category: "custom", customText: " | Nobody" })
            compare(w.pool.length, 0)
            compare(w.customErrors, ["Line 1: quote text is empty"])
            compare(w.customIssue, "Line 1: quote text is empty")
        }

        function test_empty_author_after_separator_reports_line_number() {
            var w = hQuote.item
            patch({ category: "custom", customText: "Useful words | " })
            compare(w.pool.length, 0)
            compare(w.customErrors, ["Line 1: author is empty"])
        }

        function test_valid_lines_survive_beside_reported_invalid_lines() {
            var w = hQuote.item
            patch({ category: "custom", customText: "Good words | Author\nBroken | \nPlain" })
            compare(w.pool.length, 2)
            compare(w.pool[0].a, "Author")
            compare(w.pool[1].t, "Plain")
            compare(w.customErrors, ["Line 2: author is empty"])
            compare(w.customIssue, "1 custom line was skipped")
        }
    }

    // ── Daily rotation: dailyIdx mapping, idx, q safety ─────────────────────
    TestCase {
        name: "QuoteDaily"
        when: windowShown
        function init() { tryVerify(function () { return hQuote.ready }, 3000); reset() }

        function test_dailyIdx_matches_day_of_year_mod_pool() {
            var w = hQuote.item
            var n = new Date()
            // DST-safe day-of-year (UTC calendar midnights) - matches the widget's
            // fixed computation; a raw local ms delta drifts an hour across DST.
            var doy = Math.round((Date.UTC(n.getFullYear(), n.getMonth(), n.getDate())
                                  - Date.UTC(n.getFullYear(), 0, 0)) / 86400000)
            var expected = doy % Math.max(1, w.pool.length)
            compare(w.dailyIdx, expected, "dailyIdx = day-of-year % pool.length")
        }

        function test_idx_follows_dailyIdx_without_manual() {
            var w = hQuote.item
            compare(w.manualIdx, -1, "no manual pick by default")
            compare(w.idx, w.dailyIdx, "idx uses the daily pick when no shuffle is active")
        }

        function test_q_is_always_defined() {
            var w = hQuote.item
            verify(w.q !== undefined && w.q !== null, "q is never undefined")
            compare(typeof w.q.t, "string", "q.t is a string")
            compare(typeof w.q.a, "string", "q.a is a string")
        }

        function test_q_reflects_current_index() {
            var w = hQuote.item
            compare(w.q.t, w.pool[w.idx].t, "q is pool[idx]")
        }
    }

    // ── Shuffle + manual override semantics ─────────────────────────────────
    TestCase {
        name: "QuoteShuffle"
        when: windowShown
        function init() { tryVerify(function () { return hQuote.ready }, 3000); reset() }

        function test_shuffle_sets_manual_and_moves_idx() {
            var w = hQuote.item                 // focus pool (7 items)
            var before = w.idx
            w.shuffle()
            verify(w.manualIdx >= 0, "shuffle records a manual pick")
            verify(w.idx !== before, "shuffle moves to a different quote")
            compare(w.idx, w.manualIdx, "idx follows the manual pick")
        }

        function test_shuffle_never_returns_current_index() {
            var w = hQuote.item
            for (var i = 0; i < 25; i++) {
                var before = w.idx
                w.shuffle()
                verify(w.idx !== before, "each shuffle changes the quote (iter " + i + ")")
                verify(w.idx >= 0 && w.idx < w.pool.length, "idx stays in range")
            }
        }

        function test_shuffle_noop_when_pool_has_one() {
            var w = hQuote.item
            patch({ category: "custom", customText: "The only quote" })
            compare(w.pool.length, 1, "single-line custom pool")
            var before = w.idx
            w.shuffle()
            compare(w.manualIdx, -1, "shuffle is a no-op with pool length 1")
            compare(w.idx, before, "idx unchanged")
        }

        // onCategoryChanged clears the manual pick so a category switch resumes
        // the daily rotation.
        function test_category_change_clears_manual() {
            var w = hQuote.item
            w.shuffle()
            verify(w.manualIdx >= 0, "manual pick active before switch")
            set("category", "stoic")
            compare(w.manualIdx, -1, "changing category resets manualIdx to -1")
            compare(w.idx, w.dailyIdx, "daily rotation resumes after category switch")
        }

        function test_edit_after_shuffle_keeps_pinned_quote() {
            var w = hQuote.item
            patch({ category: "custom", customText: "L1\nL2\nL3\nL4\nL5" })
            w.manualIdx = 3                     // pin to "L4" (as a shuffle would)
            compare(w.q.t, "L4", "pinned to the fourth quote")
            var pinned = w.q.t
            // User deletes the first line; the pool reindexes.
            set("customText", "L2\nL3\nL4\nL5")
            compare(w.q.t, pinned,
                    "editing the list must not silently repoint the pinned quote")
        }

        function test_shuffle_is_shared_with_a_second_widget_host() {
            var w = hQuote.item
            tryVerify(function () { return hQuoteMirror.ready }, 3000)
            hQuoteMirror.item.store = hQuote.storeCtl
            hQuoteMirror.item.instanceId = "test-instance"
            hQuoteMirror.item.active = false
            var before = w.q.t
            w.shuffle()
            verify(w.q.t !== before)
            wait(1)
            hQuoteMirror.item._restoreManual()
            compare(hQuoteMirror.item.q.t, w.q.t,
                    "tile, overlay, and Manager resolve the same shuffled quote")
            compare(cfg().quotePinnedText, w.q.t,
                    "the shared state stores quote identity, not only a fragile index")
        }
    }

    TestCase {
        name: "QuoteRights"
        when: windowShown
        function init() { tryVerify(function () { return hQuote.ready }, 3000); reset() }

        function test_expanded_bundled_quote_discloses_source_and_rights() {
            var w = hQuote.item
            compare(w.provenanceText, "Source: EdgeHub built-in library")
            compare(w.rightsText, "Rights: Bundled project copy")
            var source = findByProp(w, "objectName", "quoteProvenance")
            verify(source !== null && source.visible)
            verify(source.text.indexOf(w.provenanceText) >= 0)
            verify(source.text.indexOf(w.rightsText) >= 0)
        }

        function test_custom_mode_discloses_user_responsibility() {
            var w = hQuote.item
            patch({ category: "custom", customText: "My permitted words" })
            compare(w.provenanceText, "Source: Custom text")
            compare(w.rightsText, "Rights: User supplied")
            var notice = findByProp(w, "objectName", "quoteCustomRightsNotice")
            verify(notice !== null && notice.visible)
            verify(notice.text.indexOf("permission") >= 0)
        }
    }

    // ── Per-instance appearance: accent / title / backdrop via WidgetChrome ──
    TestCase {
        name: "QuoteAppearance"
        when: windowShown
        function init() { tryVerify(function () { return hQuote.ready }, 3000); reset() }

        function test_accent_preset_drives_effAccent() {
            var w = hQuote.item
            compare(w.effAccent.toString(), w.accentColor.toString(),
                    "no preset → effAccent equals the default accentColor")
            w.accentName = "pink"
            compare(w.effAccent.toString(), Qt.color(hQuote.theme.accentPresets["pink"].a).toString(),
                    "an accent preset overrides effAccent")
        }

        function test_effAccent_recolours_quote_glyph() {
            var w = hQuote.item
            w.accentName = "pink"
            var glyph = findByProp(w, "text", "“")
            verify(glyph !== null, "the decorative opening-quote glyph exists")
            compare(glyph.color.toString(), w.effAccent.toString(),
                    "the quote glyph follows the custom accent")
        }

        function test_effAccent_tints_shuffle_button() {
            var w = hQuote.item
            w.accentName = "gold"
            var pill = findByProp(w, "objectName", "quoteExpandedShuffle")
            verify(pill !== null, "the quote action exists when expanded")
            compare(pill.tint.toString(), w.effAccent.toString(),
                    "the quote action is tinted with the custom accent")
            compare(pill.accessibleName, "Show another quote")
        }

        function test_title_override_honored() {
            var w = hQuote.item
            w.titleOverride = "My Quotes"
            var t = findByProp(w, "text", "My Quotes")
            verify(t !== null, "titleOverride replaces the header title text")
        }

        function test_card_backdrop_honored() {
            var w = hQuote.item
            w.cardBackdrop = "orbs"
            compare(w.cardBackdrop, "orbs", "cardBackdrop config key is honored by WidgetChrome")
        }
    }

    // ── Collapsed mode: Shuffle button is hidden ────────────────────────────
    TestCase {
        name: "QuoteCollapsed"
        when: windowShown
        function init() { tryVerify(function () { return hQuote.ready }, 3000); reset() }

        function test_shuffle_hidden_when_collapsed() {
            var w = hQuote.item
            var pill = findByProp(w, "objectName", "quoteExpandedShuffle")
            verify(pill !== null, "expanded quote action object exists")
            hQuote.expanded = true
            compare(pill.visible, true, "Shuffle is visible when expanded (multi-quote pool)")
            hQuote.expanded = false
            compare(pill.visible, false, "Shuffle is hidden in collapsed mode")
            hQuote.expanded = true       // restore for later tests
        }
    }

    // ── Per-sizeClass structure (W1) ─────────────────────────────────────────
    // Fixed-size hosts at real projected cell footprints; the Dashboard injects
    // sizeClass, so the tests assign it the same way and pin what each size
    // shows - a future edit can't silently collapse the sizes back into one
    // stretched layout.
    Item { id: qMicroWrap; width: 344; height: 416
        WidgetHarness { id: hQMicro; anchors.fill: parent; widgetFile: "QuoteWidget.qml"; expanded: false } }
    Item { id: qBaseWrap; width: 696; height: 840
        WidgetHarness { id: hQBase; anchors.fill: parent; widgetFile: "QuoteWidget.qml"; expanded: false } }
    Item { id: qWideWrap; width: 696; height: 416
        WidgetHarness { id: hQWide; anchors.fill: parent; widgetFile: "QuoteWidget.qml"; expanded: false } }
    Item { id: qTallWrap; width: 344; height: 840
        WidgetHarness { id: hQTall; anchors.fill: parent; widgetFile: "QuoteWidget.qml"; expanded: false } }

    TestCase {
        name: "QuoteSizes"
        when: windowShown

        // 0.5x0.5 - the quote text alone: no glyph, no author, no controls
        // competing for a twelfth of the screen.
        function test_micro_is_text_only() {
            tryVerify(function () { return hQMicro.ready }, 3000)
            var w = hQMicro.item
            w.sizeClass = "compact"
            compare(w.micro, true, "a 344x416 compact box is the micro tile")
            compare(w.showGlyph, false, "micro drops the decorative glyph")
            compare(w.showAuthor, false, "micro drops the author line")
            compare(w.showShuffleTile, false, "micro has no shuffle control")
            var glyph = findByProp(w, "text", "“")
            verify(glyph === null || !glyph.visible, "the glyph is not rendered at micro")
        }

        // 1x1 - glyph + quote + author + a touch-token shuffle.
        function test_baseline_full_quote_card() {
            tryVerify(function () { return hQBase.ready }, 3000)
            var w = hQBase.item
            w.sizeClass = "compact"
            compare(w.micro, false, "696x840 compact is the baseline, not micro")
            compare(w.showGlyph, true, "the baseline shows the glyph")
            verify(w.q.a.length > 0, "the built-in pool always carries an author")
            compare(w.showAuthor, true, "the baseline shows the author")
            compare(w.showShuffleTile, true, "the baseline has the tile shuffle")
            var action = findByProp(w, "objectName", "quoteTileShuffle")
            verify(action !== null, "the tile quote action exists")
            verify(action.width >= hQBase.theme.touchTertiary - 1,
                   "the tile action is touch-token sized (got " + action.width + ")")
            verify(action.height >= hQBase.theme.touchTertiary - 1)
            compare(action.accessibleName, "Show another quote")
            verify(action.activeFocusOnTab, "the action supports keyboard focus")
            verify(action.visible, "and is visible")
        }

        // wide - glyph beside a left-aligned quote column, in BOTH projections
        // of the class (1x0.5 portrait 696x416, 0.5x1 landscape 840x344).
        function test_wide_lays_glyph_beside_text_both_orientations() {
            tryVerify(function () { return hQWide.ready }, 3000)
            var w = hQWide.item
            w.sizeClass = "wide"
            compare(w.horiz, true, "wide is the side-by-side layout")
            compare(w.showGlyph, true, "wide shows the glyph")
            compare(w.showShuffleTile, true, "wide keeps the shuffle")
            verify(w.quoteLines <= 3, "a short wide box caps the line count")
            qWideWrap.width = 840; qWideWrap.height = 344
            compare(w.showGlyph, true, "the landscape projection keeps the layout")
            qWideWrap.width = 1100; qWideWrap.height = 696
            verify(w.quoteLines >= 5, "the big wide box earns more lines")
            qWideWrap.width = 696; qWideWrap.height = 416
        }

        // tall - the roomiest tile reading: most lines, bigger type than micro.
        function test_tall_earns_more_lines() {
            tryVerify(function () { return hQTall.ready }, 3000)
            var w = hQTall.item
            w.sizeClass = "tall"
            compare(w.quoteLines, 6, "tall allows the most lines")
            compare(w.showAuthor, true, "tall shows the author")
            tryVerify(function () { return hQMicro.ready }, 3000)
            hQMicro.item.sizeClass = "compact"
            verify(w.quotePx > hQMicro.item.quotePx,
                   "tall type is larger than micro type (" + w.quotePx + " vs " + hQMicro.item.quotePx + ")")
        }
    }

    TestCase {
        name: "QuoteSchema"
        when: windowShown

        function field(key) {
            var s = schema.schemaFor("quote")
            for (var i = 0; i < s.sections.length; i++)
                for (var j = 0; j < (s.sections[i].fields || []).length; j++)
                    if (s.sections[i].fields[j].key === key)
                        return s.sections[i].fields[j]
            return null
        }

        function test_author_display_has_three_explicit_modes() {
            var f = field("authorDisplay")
            verify(f !== null)
            compare(f.type, "segmented")
            compare(f.options.map(function(option) { return option.value }),
                    ["auto", "always", "hide"])
        }
    }
}
