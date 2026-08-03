import QtQuick
import QtTest


// ─────────────────────────────────────────────────────────────────────────
// Comprehensive coverage for widget:rightnow (ui/qml/widgets/RightNowWidget.qml)
//
// Drives config through the store (setSetting / patchSettings) exactly the way
// the Manager/Dashboard do, and asserts on the widget's derived state and its
// rendered content. Two harnesses are used because a couple of behaviours only
// exist in one mode: the expanded editor (TextField, Save/Done pills, the
// "finished today" label) and the compact hero display.
//
// Some assertions intentionally encode the DESIGN CONTRACT / INTENDED behaviour
// and therefore fail against the current code - those pin the audit's bugs
// (frozen todayKey, dead pluralization ternary, un-accented hero text, Done!
// discarding unsaved edits). Test-side mistakes are fixed; genuine code defects
// are left failing on purpose.
// ─────────────────────────────────────────────────────────────────────────
Item {
    id: root
    width: 480; height: 900

    WidgetHarness { id: hRN;      anchors.fill: parent; widgetFile: "RightNowWidget.qml"; expanded: true  }
    WidgetHarness { id: hCompact; anchors.fill: parent; widgetFile: "RightNowWidget.qml"; expanded: false }

    // Fixed-size hosts for the per-sizeClass structure tests (W1) - real
    // projected cell footprints (half-cell ≈ 344x416, full cell ≈ 696x840).
    Item { id: rMicroWrap; width: 344; height: 416
        WidgetHarness { id: hRMicro; anchors.fill: parent; widgetFile: "RightNowWidget.qml"; expanded: false } }
    Item { id: rBaseWrap; width: 696; height: 840
        WidgetHarness { id: hRBase; anchors.fill: parent; widgetFile: "RightNowWidget.qml"; expanded: false } }
    Item { id: rWideWrap; width: 696; height: 416
        WidgetHarness { id: hRWide; anchors.fill: parent; widgetFile: "RightNowWidget.qml"; expanded: false } }
    Item { id: rTallWrap; width: 344; height: 840
        WidgetHarness { id: hRTall; anchors.fill: parent; widgetFile: "RightNowWidget.qml"; expanded: false } }
    // The OVERLAY, at the two boxes Dashboard actually gives it: the live-preview
    // pane beside the config form, ~941x456 landscape and ~656x980 portrait.
    // `expanded: true` AND sizeClass "full" - the real pairing - because a
    // mode-keyed literal can only be caught with the mode switched ON.
    Item { width: 941; height: 456
        WidgetHarness { id: hOvlL; anchors.fill: parent; widgetFile: "RightNowWidget.qml"; expanded: true } }
    Item { width: 656; height: 980
        WidgetHarness { id: hOvlP; anchors.fill: parent; widgetFile: "RightNowWidget.qml"; expanded: true } }

    // ── traversal helpers (mirrors tst_touch_targets / tst_clicks) ──────────
    function findAll(node, pred, acc) {
        if (!node) return acc
        if (pred(node)) acc.push(node)
        var kids = node.children
        for (var i = 0; kids && i < kids.length; i++) findAll(kids[i], pred, acc)
        return acc
    }
    // Plain Text items expose `elide`; TextField/TextInput/TextArea do not.
    function isText(n) { return n.hasOwnProperty("elide") && n.hasOwnProperty("text") && n.hasOwnProperty("wrapMode") }
    function texts(node) { return findAll(node, isText, []) }
    function textWith(node, needle) {
        var ts = texts(node)
        for (var i = 0; i < ts.length; i++)
            if (typeof ts[i].text === "string" && ts[i].text.indexOf(needle) !== -1) return ts[i]
        return null
    }
    function textEq(node, exact) {
        var ts = texts(node)
        for (var i = 0; i < ts.length; i++)
            if (ts[i].text === exact) return ts[i]
        return null
    }
    function findByProp(node, prop, val) {
        if (!node) return null
        if (node[prop] !== undefined && node[prop] === val) return node
        var kids = node.children
        for (var i = 0; kids && i < kids.length; i++) {
            var r = findByProp(kids[i], prop, val); if (r) return r
        }
        return null
    }
    function findTextField(node) {
        if (!node) return null
        if (node.hasOwnProperty("placeholderText") && node.hasOwnProperty("text")) return node
        var kids = node.children
        for (var i = 0; kids && i < kids.length; i++) {
            var r = findTextField(kids[i]); if (r) return r
        }
        return null
    }
    // Collect QtQuick animation objects (have both `easing` and `property`).
    function collectAnims(node, acc, seen) {
        if (!node) return acc
        for (var s = 0; s < seen.length; s++) if (seen[s] === node) return acc
        seen.push(node)
        if (node.hasOwnProperty && node.hasOwnProperty("easing") && node.hasOwnProperty("property"))
            acc.push(node)
        var kids = node.children
        for (var i = 0; kids && i < kids.length; i++) collectAnims(kids[i], acc, seen)
        try { var d = node.data; for (var j = 0; d && j < d.length; j++) collectAnims(d[j], acc, seen) } catch (e) {}
        try { var a = node.animations; for (var k = 0; a && k < a.length; k++) collectAnims(a[k], acc, seen) } catch (e2) {}
        return acc
    }

    function pad(n) { return (n < 10 ? "0" : "") + n }
    function keyOf(d) { return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate()) }
    function clear(h) {
        var s = h.storeCtl.settingsFor("test-instance")
        for (var k in s) delete s[k]
        h.storeCtl._touchSettings()
    }

    // ── Expanded editor: config, logic, reactivity ─────────────────────────
    TestCase {
        name: "RightNowExpanded"
        when: windowShown
        function initTestCase() { tryVerify(function () { return hRN.ready }, 3000) }
        function init() { clear(hRN); hRN.item.celebrateMsg = "" }
        function set(k, v) { hRN.storeCtl.setSetting("test-instance", k, v) }
        function patch(o) { hRN.storeCtl.patchSettings("test-instance", o) }
        function cfg() { return hRN.storeCtl.settingsFor("test-instance") }

        // setText persists and w.current tracks store.revision bumps.
        // elapsedLabel() is a four-branch ladder and startedLabel() a two-branch
        // one; between them they are everything the card says about WHEN. Only
        // one branch was ever named in a test. Driving startedAt directly pins
        // each without waiting out real minutes.
        function test_elapsed_label_reads_naturally_at_every_scale_data() {
            return [
                { tag: "under-a-minute", secs: 30,          want: "Started just now" },
                { tag: "one-minute",     secs: 60,          want: "Focused for 1 min" },
                { tag: "under-an-hour",  secs: 45 * 60,     want: "Focused for 45 min" },
                { tag: "exactly-an-hour", secs: 60 * 60,    want: "Focused for 1h" },
                { tag: "hours-and-mins", secs: 2 * 3600 + 20 * 60, want: "Focused for 2h 20m" },
                // A whole number of hours must not read "2h 0m".
                { tag: "whole-hours",    secs: 3 * 3600,    want: "Focused for 3h" }
            ]
        }
        function test_elapsed_label_reads_naturally_at_every_scale(data) {
            var w = hRN.item
            w.setText("write the report")
            hRN.storeCtl.patchSettings("test-instance",
                                       { startedAt: Date.now() - data.secs * 1000 })
            verify(w.hasFocus, "precondition: a focus is running")
            compare(w.elapsedLabel(), data.want,
                    data.secs + "s in reads as '" + data.want + "'")
        }

        // With nothing running there is no start time to show, and inventing one
        // (a formatted epoch, or "00:00") would be worse than saying so.
        function test_started_label_says_not_started_when_nothing_is_running() {
            var w = hRN.item
            w.clearFocus()
            compare(w.startedAt, 0, "precondition: nothing running")
            compare(w.startedLabel(), "Not started")

            w.setText("write the report")
            verify(w.startedAt > 0, "starting records a time")
            var shown = w.startedLabel()
            verify(shown !== "Not started", "and the label stops saying otherwise")
            verify(/^\d{2}:\d{2}$/.test(shown),
                   "showing a wall-clock start time (got '" + shown + "')")
        }

        function test_setText_persists_and_reactive() {
            var w = hRN.item
            w.setText("Finish the report")
            compare(cfg().text, "Finish the report", "setText writes the config")
            compare(w.current, "Finish the report", "current reflects the saved value")
            verify(w.startedAt > 0, "a new focus records when it started")
            // External write (as the Manager would do) must flow through via revision.
            patch({ text: "External focus" })
            compare(w.current, "External focus", "current reacts to an external setSetting")
            tryVerify(function () { return w.startedAt > 0 }, 1000,
                      "a Manager text edit starts the focus timer lifecycle")
            patch({ text: "" })
            tryCompare(w, "startedAt", 0, 1000)
        }

        function test_calm_completion_counts_without_celebration() {
            var w = hRN.item
            patch({ text: "Quiet work", startedAt: Date.now() - 60000, completionStyle: "calm" })
            w.finish()
            compare(w.finishedToday, 1)
            compare(w.celebrateMsg, "")
            compare(cfg().startedAt, 0)
        }

        function test_clear_focus_does_not_count_completion() {
            var w = hRN.item
            patch({ text: "Replace me", startedAt: Date.now() - 5000 })
            w.clearFocus()
            compare(w.current, "")
            compare(w.finishedToday, 0)
            compare(cfg().startedAt, 0)
        }

        function test_clear_requires_a_second_deliberate_tap() {
            var w = hRN.item
            var field = findTextField(w)
            patch({ text: "Keep this focus", startedAt: Date.now() })
            compare(field.text, "Keep this focus")
            var clearButton = findByProp(w, "label", "Clear")
            verify(clearButton !== null)
            mouseClick(clearButton)
            compare(w.current, "Keep this focus",
                    "the first Clear tap changes no data")
            compare(clearButton.label, "Confirm")
            verify(w.clearArmed)
            mouseClick(clearButton)
            compare(w.current, "")
            compare(field.text, "")
            compare(w.clearArmed, false)
        }

        // finish() counts a win, clears the text and fires the celebration.
        function test_finish_counts_clears_celebrates() {
            var w = hRN.item
            set("text", "Ship the build")
            compare(w.finishedToday, 0, "starts at 0")
            w.finish()
            compare(w.finishedToday, 1, "finishing increments today's counter")
            compare(w.current, "", "the focus is cleared after finishing")
            compare(cfg().day, w.todayKey, "the day bucket is stamped with today")
            verify(w.celebrateMsg.length > 0, "a celebration message is shown")
        }

        // finish() is a no-op when there is no real focus (empty / whitespace).
        function test_finish_noop_when_empty_or_whitespace() {
            var w = hRN.item
            w.finish()
            compare(w.finishedToday, 0, "empty focus: nothing counted")
            compare(w.celebrateMsg, "", "empty focus: no celebration")
            set("text", "   ")
            w.finish()
            compare(w.finishedToday, 0, "whitespace-only focus: nothing counted")
            compare(w.celebrateMsg, "", "whitespace-only focus: no celebration")
        }

        // Day-comparison rollover: a stale bucket from another calendar day reads 0.
        function test_counter_resets_for_a_different_stored_day() {
            var w = hRN.item
            patch({ day: "2000-01-01", finishedToday: 7 })
            compare(w.finishedToday, 0, "a bucket from another day does not count as today")
            patch({ day: w.todayKey, finishedToday: 4 })
            compare(w.finishedToday, 4, "today's bucket is preserved")
        }

        // BUG (frozen todayKey): after midnight, with the widget still alive, the
        // 'today' bucket must reset. todayKey is a plain, non-reactive property set
        // once at load, so a widget created 'yesterday' keeps a stale key. We
        // emulate that stale-at-load state and assert the count resets for the real
        // current day - a correct widget would recompute todayKey and read 0.
        function test_frozen_todayKey_never_rolls_over_midnight() {
            var w = hRN.item
            var yesterday = keyOf(new Date(Date.now() - 86400000))
            w.todayKey = yesterday                       // widget was loaded 'yesterday'
            patch({ day: yesterday, finishedToday: 3 })  // 3 finished yesterday
            // It is now really a new day; the count for 'today' should be 0.
            compare(w.finishedToday, 0,
                    "count must reset on the new calendar day (frozen todayKey stays " + w.todayKey + ")")
            w.todayKey = keyOf(new Date())               // restore for later tests
        }

        // BUG (dead pluralization ternary): the '✓ N finished today' label uses a
        // ternary whose branches are identical, so 1 vs N never differ in wording.
        function test_finished_label_pluralizes_for_one_vs_many() {
            var w = hRN.item
            patch({ day: w.todayKey, finishedToday: 1 })
            var one = textWith(w, "finished today")
            verify(one !== null, "found the finished-today label")
            var s1 = one.text.replace(/[0-9✓\s]/g, "")   // strip count + tick + spaces
            patch({ day: w.todayKey, finishedToday: 3 })
            var many = textWith(w, "finished today")
            var s3 = many.text.replace(/[0-9✓\s]/g, "")
            verify(s1 !== s3, "singular and plural wording must differ (1='" + one.text + "' N='" + many.text + "')")
        }

        // A custom title from config is shown in the expanded header.
        function test_custom_title_shown_in_header() {
            var w = hRN.item
            w.titleOverride = "My One Thing"             // Dashboard injects this from cfg.title
            var t = textEq(w, "My One Thing")
            verify(t !== null, "the expanded header shows the custom title")
            w.titleOverride = ""
        }

        // An external write updates the (unfocused) TextField, not just w.current.
        function test_external_write_updates_unfocused_field() {
            var w = hRN.item
            var field = findTextField(w)
            verify(field !== null, "found the editor field")
            field.focus = false                          // a prior test may have focused it
            verify(!field.activeFocus, "field is not focused")
            patch({ text: "From the Manager" })
            compare(w.current, "From the Manager", "current updated")
            compare(field.text, "From the Manager", "the unfocused field resynced to the new value")
        }

        // A single Save should be exactly one store write (one revision bump).
        // Audit bug: Save also blurs the field (onEditingFinished) → two writes.
        function test_single_save_is_one_write() {
            var w = hRN.item
            var field = findTextField(w)
            var save = findByProp(w, "label", "Save")
            verify(save !== null, "found the Save pill")
            mouseClick(field)
            field.text = "Save exactly once"
            var before = hRN.storeCtl.revision
            mouseClick(save)
            var delta = hRN.storeCtl.revision - before
            compare(w.current, "Save exactly once", "the value is saved")
            compare(delta, 1, "one Save = one revision bump (got " + delta + ")")
        }

        // BUG (Done! discards unsaved edits): Done! completes the previously-saved
        // focus (w.current) while any text typed but not yet saved is thrown away.
        function test_done_operates_on_visible_text_not_stale_saved() {
            var w = hRN.item
            // Original assertion (w.current === field.text with no Done! click) was
            // self-contradictory with its own prior compare; drive Done! and assert the
            // real contract: it completes the visible/typed focus, not the saved value.
            var field = findTextField(w)
            var done = findByProp(w, "label", "Done!")
            verify(done !== null, "found the Done pill")
            mouseClick(field)                            // focus so the resync won't overwrite
            field.text = "Focus B (unsaved)"             // user edits without pressing Save
            compare(w.current, "", "nothing has been saved yet")
            mouseClick(done)                             // complete the visible focus
            compare(w.finishedToday, 1,
                    "Done! counted the visible focus, not the empty saved value")
            compare(w.current, "", "the focus is cleared after finishing")
        }
    }

    // ── Compact hero display: accent, placeholder, whitespace, tap handling ──
    TestCase {
        name: "RightNowCompact"
        when: windowShown
        function initTestCase() { tryVerify(function () { return hCompact.ready }, 3000) }
        function init() { clear(hCompact); hCompact.item.accentName = "" }
        function set(k, v) { hCompact.storeCtl.setSetting("test-instance", k, v) }

        // Placeholder prompt when no focus is set.
        function test_placeholder_when_no_focus() {
            var w = hCompact.item
            var t = textEq(w, "Tap to set your one focus")
            verify(t !== null, "placeholder prompt is shown when empty")
            verify(t.visible, "placeholder is visible")
        }

        // BUG (hero text ignores per-instance accent): the most prominent content
        // stays theme.textPrimary even when the instance accent is set.
        function test_hero_text_honours_accent() {
            var w = hCompact.item
            w.accentName = "red"
            set("text", "Recolour me")
            var hero = textEq(w, "Recolour me")
            verify(hero !== null, "found the hero focus text")
            compare(String(w.effAccent).toLowerCase(), String(hCompact.theme.accentPresets["red"].a).toLowerCase(),
                    "effAccent resolved to red")
            compare(String(hero.color).toLowerCase(), String(w.effAccent).toLowerCase(),
                    "the hero focus text should adopt the per-instance accent (is " + hero.color + ")")
        }

        // Whitespace-only text should read as 'no focus' (placeholder), matching the
        // trim() logic Done!/finish() already use. Currently the raw whitespace is
        // shown as bold content instead.
        function test_whitespace_reads_as_no_focus() {
            var w = hCompact.item
            set("text", "     ")
            var placeholder = textEq(w, "Tap to set your one focus")
            verify(placeholder !== null && placeholder.visible,
                   "whitespace-only focus should fall back to the placeholder")
        }

        // No full-tile MouseArea should swallow the tap that opens the editor (the
        // tile host handles the tap). The only widget-fill MouseArea is the chrome
        // hover ring, which accepts Qt.NoButton.
        function test_no_full_tile_mousearea_swallows_taps() {
            var w = hCompact.item
            var areas = findAll(w, function (n) {
                return n.hasOwnProperty("pressed") && n.hasOwnProperty("containsMouse")
            }, [])
            for (var i = 0; i < areas.length; i++) {
                var a = areas[i]
                var fillsTile = a.width >= w.width * 0.9 && a.height >= w.height * 0.9
                if (fillsTile)
                    compare(a.acceptedButtons, Qt.NoButton,
                            "a tile-filling MouseArea must not accept taps (would swallow the open gesture)")
            }
            verify(true, "checked " + areas.length + " mouse areas")
        }

        // Celebration honours reduceMotion: the scale pop drops the OutBack overshoot
        // for a linear ease.
        function test_celebration_honours_reduce_motion() {
            var w = hCompact.item
            var anims = collectAnims(w, [], [])
            var scaleAnim = null
            for (var i = 0; i < anims.length; i++)
                if (anims[i].property === "scale") { scaleAnim = anims[i]; break }
            verify(scaleAnim !== null, "found the celebration scale animation")
            hCompact.theme.reduceMotion = false
            compare(scaleAnim.easing.type, Easing.OutBack, "full motion uses OutBack overshoot")
            hCompact.theme.reduceMotion = true
            compare(scaleAnim.easing.type, Easing.Linear, "reduced motion uses a linear ease")
            hCompact.theme.reduceMotion = false
        }
    }

    // ── Per-sizeClass structure (W1) ─────────────────────────────────────────
    // The Dashboard injects sizeClass; the tests assign it the same way and pin
    // what each size shows - a future edit can't silently collapse the sizes
    // back into one stretched hero line.
    TestCase {
        name: "RightNowSizes"
        when: windowShown

        function seed(hh, text, finished) {
            var s = hh.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            hh.storeCtl._touchSettings()
            var patch = { text: text }
            if (finished !== undefined) {
                patch.finishedToday = finished
                patch.day = Qt.formatDate(new Date(), "yyyy-MM-dd")
            }
            hh.storeCtl.patchSettings("test-instance", patch)
        }

        // 0.5x0.5 - the focus text alone: no eyebrow, no button, no counter.
        function test_micro_is_a_pure_cue() {
            tryVerify(function () { return hRMicro.ready }, 3000)
            seed(hRMicro, "Ship it", 2)
            var w = hRMicro.item
            w.sizeClass = "compact"
            compare(w.micro, true, "a 344x416 compact box is the micro tile")
            compare(w.showEyebrow, false, "micro drops the eyebrow")
            compare(w.showDoneTile, false, "micro has no Done button")
            compare(w.showCount, false, "micro drops the momentum line")
            var hero = textWith(w, "Ship it")
            verify(hero !== null && hero.visible, "the focus text is the whole tile")
            verify(hero.font.pixelSize >= 36,
                   "short micro focus text is glanceable (" + hero.font.pixelSize + "px)")
        }

        function test_micro_long_focus_uses_a_complete_excerpt_and_continuation() {
            tryVerify(function () { return hRMicro.ready }, 3000)
            var full = "Finish the release readiness review with the whole team"
            seed(hRMicro, full, 0)
            hRMicro.theme.textScale = 1.45
            var w = hRMicro.item
            w.sizeClass = "compact"
            wait(32)
            compare(w.focusIsExcerpted, true,
                    "micro reports when the full focus needs a continuation")
            verify(w.displayedFocus.length < full.length
                   && w.displayedFocus.charAt(w.displayedFocus.length - 1) === "…",
                   "the visible micro cue is a bounded, explicit excerpt")
            var hero = findByProp(w, "objectName", "rightNowHero")
            verify(hero && hero.visible, "the focus excerpt is rendered")
            compare(hero.truncated, false,
                    "the excerpt itself is complete rather than silently elided")
            verify(hero.font.pixelSize >= hRMicro.theme.fontTitle,
                   "the long micro cue retains the active title-size floor")
            var continuation = findByProp(w, "objectName", "rightNowContinuation")
            verify(continuation && continuation.visible
                   && continuation.text === "Tap to read all",
                   "the tile tells the user how to reach the complete focus")
            verify(continuation.font.pixelSize >= hRMicro.theme.fontMinimum,
                   "the continuation meets the active minimum type size")
            hRMicro.theme.textScale = 1.15
        }

        function test_focus_text_wraps_before_eliding_and_keeps_a_legible_floor() {
            tryVerify(function () { return hRBase.ready }, 3000)
            seed(hRBase,
                 "Prepare the release notes and verify every package checksum",
                 0)
            var w = hRBase.item
            w.sizeClass = "compact"
            wait(16)
            var hero = findByProp(w, "objectName", "rightNowHero")
            verify(hero !== null && hero.visible)
            verify(hero.lineCount > 1,
                   "long focus uses available lines before eliding")
            verify(hero.lineCount <= hero.maximumLineCount)
            verify(hero.font.pixelSize >= hRBase.theme.fontTitle,
                   "long focus remains at the title legibility floor")
        }

        // 1x1 - eyebrow + hero + Done + momentum: the tile earns real actions.
        function test_baseline_has_eyebrow_done_and_count() {
            tryVerify(function () { return hRBase.ready }, 3000)
            seed(hRBase, "Ship it", 2)
            var w = hRBase.item
            w.sizeClass = "compact"
            compare(w.micro, false, "696x840 compact is the baseline, not micro")
            compare(w.showEyebrow, true, "the baseline shows the identity eyebrow")
            var eyebrow = textWith(w, "RIGHT NOW")
            verify(eyebrow !== null && eyebrow.visible, "the eyebrow is rendered")
            compare(w.showDoneTile, true, "a set focus gets a Done button on the tile")
            var done = findByProp(w, "label", "Done")
            verify(done !== null && done.visible, "the Done pill is rendered")
            verify(done.height >= 44, "the Done pill is touch sized (got " + done.height + ")")
            compare(w.showCount, true, "the momentum line shows with finished > 0")
            verify(textWith(w, "✓ 2 today") !== null, "the momentum line is rendered")
            var labelledEyebrow = findByProp(w, "objectName", "rightNowEyebrow")
            verify(labelledEyebrow.font.pixelSize >= hRBase.theme.fontLabel)
            var count = findByProp(w, "objectName", "rightNowCount")
            verify(count.font.pixelSize >= hRBase.theme.fontLabel)
        }

        function test_baseline_earns_readable_elapsed_context() {
            tryVerify(function () { return hRBase.ready }, 3000)
            seed(hRBase, "Review the release", 0)
            hRBase.storeCtl.setSetting("test-instance", "startedAt",
                                       Date.now() - 7 * 60000)
            var w = hRBase.item
            w.sizeClass = "compact"
            wait(16)
            compare(w.showElapsed, true,
                    "every non-micro focus tile reports elapsed time")
            var elapsed = findByProp(w, "objectName", "rightNowElapsed")
            verify(elapsed !== null && elapsed.visible)
            verify(elapsed.text.indexOf("7 min") >= 0)
            verify(elapsed.font.pixelSize >= hRBase.theme.fontLabel)
        }

        // The tile Done button IS the real action: it finishes the focus.
        function test_tile_done_finishes_the_focus() {
            tryVerify(function () { return hRBase.ready }, 3000)
            seed(hRBase, "Ship it", 0)
            var w = hRBase.item
            w.sizeClass = "compact"
            var done = findByProp(w, "label", "Done")
            verify(done !== null && done.visible, "the Done pill is there")
            done.clicked()
            var c = hRBase.storeCtl.settingsFor("test-instance")
            compare(c.text, "", "Done clears the focus")
            compare(c.finishedToday, 1, "and counts the win")
            compare(w.showDoneTile, false, "with no focus left, the button retires")
        }

        // Placeholder state: no Done button to press on an empty focus.
        function test_no_done_without_focus() {
            tryVerify(function () { return hRBase.ready }, 3000)
            seed(hRBase, "")
            var w = hRBase.item
            w.sizeClass = "compact"
            compare(w.showDoneTile, false, "no focus → no Done button")
            var ph = textWith(w, "Tap to set your one focus")
            verify(ph !== null && ph.visible, "the placeholder cue is shown")
        }

        // wide - hero beside the action column, in BOTH projections of the class
        // (1x0.5 portrait 696x416, 0.5x1 landscape 840x344).
        function test_wide_hero_beside_action_both_orientations() {
            tryVerify(function () { return hRWide.ready }, 3000)
            seed(hRWide, "Ship it", 1)
            var w = hRWide.item
            w.sizeClass = "wide"
            compare(w.horiz, true, "wide puts the action column beside the hero")
            compare(w.showDoneTile, true, "wide keeps the Done button")
            compare(w.showCount, true, "wide keeps the momentum line")
            rWideWrap.width = 840; rWideWrap.height = 344
            compare(w.showDoneTile, true, "the landscape projection keeps the action column")
            rWideWrap.width = 696; rWideWrap.height = 416
        }

        // tall - stacked, with more hero lines than the short classes.
        function test_tall_stacks_and_earns_lines() {
            tryVerify(function () { return hRTall.ready }, 3000)
            seed(hRTall, "Ship it", 0)
            var w = hRTall.item
            w.sizeClass = "tall"
            compare(w.horiz, false, "tall stacks vertically")
            compare(w.showEyebrow, true, "tall shows the eyebrow")
            var hero = textWith(w, "Ship it")
            verify(hero !== null && hero.visible, "the hero is rendered")
            compare(hero.maximumLineCount, 5, "tall earns the most hero lines")
            hRTall.storeCtl.setSetting("test-instance", "startedAt", Date.now() - 5 * 60000)
            compare(w.showElapsed, true, "the larger tile earns elapsed focus context")
            verify(w.elapsedLabel().indexOf("5 min") >= 0)
        }

        function test_hero_tall_adds_focus_context_instead_of_blank_space() {
            tryVerify(function () { return hRTall.ready }, 3000)
            rTallWrap.width = 696; rTallWrap.height = 1228
            seed(hRTall, "Finish the release notes", 2)
            hRTall.storeCtl.setSetting("test-instance", "startedAt", Date.now() - 12 * 60000)
            var w = hRTall.item
            w.sizeClass = "tall"
            wait(32)
            compare(w.heroRoomy, true, "the 1x1.5 portrait card earns the rich context")
            var context = findByProp(w, "objectName", "rightNowFocusContext")
            verify(context !== null && context.visible, "the context panel is rendered")
            verify(textWith(context, "12 min") !== null, "elapsed flow time is visible")
            verify(textWith(context, "2 today") !== null, "today's momentum is visible")
            var started = textWith(context, "STARTED")
            var flow = textWith(context, "IN FLOW")
            var finished = textWith(context, "FINISHED")
            verify(started.font.pixelSize >= hRTall.theme.fontLabel
                   && flow.font.pixelSize >= hRTall.theme.fontLabel
                   && finished.font.pixelSize >= hRTall.theme.fontLabel,
                   "rich context headings use the readable label floor")

            rTallWrap.width = 344; rTallWrap.height = 840
            wait(16)
            compare(w.heroRoomy, false, "the narrow tall card stays visually focused")
        }

        // ── size, not mode ──────────────────────────────────────────────────
        // The celebration banner was `expanded ? 40 : 22`. It spans the whole
        // CARD, so the card is what sizes it. Asserted on the rendered Text's own
        // font.pixelSize, not on w.celebratePx: checking the property only proves
        // the arithmetic, and a Text that ignored it and re-froze a literal would
        // pass that untouched.
        function banner(host) {
            return findAll(host.item, function (n) {
                return n.hasOwnProperty("text") && n.hasOwnProperty("font")
                       && n.text === host.item.celebrateMsg
                       && n.hasOwnProperty("opacity") && n.z === 20 }, [])[0]
        }

        // The mode held FIXED at false while only the room moves: a surviving
        // `w.expanded ? 40 : 22` is pinned to 22 on BOTH hosts and cannot follow
        // the box at all.
        function test_celebration_banner_is_sized_by_the_card_not_the_mode() {
            tryVerify(function () { return hRBase.ready && hRMicro.ready }, 3000)
            var base = hRBase.item;   base.sizeClass = "compact"
            var micro = hRMicro.item; micro.sizeClass = "compact"
            base.celebrateNow("🎉 Done!"); micro.celebrateNow("🎉 Done!")
            wait(16)
            compare(base.expanded, false, "precondition: neither host is the overlay")
            compare(micro.expanded, false, "…including the roomy one")

            var bB = banner(hRBase), bM = banner(hRMicro)
            verify(bB && bM, "both banners resolve")
            compare(bB.font.pixelSize, Math.round(base.celebratePx),
                    "the rendered banner actually uses the derived size on a 1x1 tile")
            compare(bM.font.pixelSize, Math.round(micro.celebratePx),
                    "…and on a micro tile")
            verify(bB.font.pixelSize > bM.font.pixelSize,
                   "a 696x840 tile pops bigger than a 344x416 one - the banner reads "
                   + "the card, not the mode (" + bB.font.pixelSize + " vs "
                   + bM.font.pixelSize + ")")
        }

        // The overlay is a size class like any other, and its box is the one it is
        // actually given. This is the shape that catches a mode-keyed literal: the
        // test above holds the mode fixed at false, where a surviving
        // `w.expanded ? 40 : <derived>` never fires its literal at all.
        // Both hosts are expanded AND "full"; only the BOX differs - the real
        // live-preview panes beside the config form, NOT a 2560x720 screen.
        function test_overlay_banner_is_sized_by_its_pane_not_by_a_mode_literal() {
            tryVerify(function () { return hOvlL.ready && hOvlP.ready }, 3000)
            var land = hOvlL.item; land.sizeClass = "full"
            var port = hOvlP.item; port.sizeClass = "full"
            land.celebrateNow("🎉 Done!"); port.celebrateNow("🎉 Done!")
            // A real event-loop turn, not wait(0) - these hosts default to "tall"
            // (height > 240) and only become "full" on the lines above, and a
            // wait(0) read reports pre-change geometry. waitForRendering is not
            // the tool: offscreen never swaps a frame.
            wait(16)
            compare(land.expanded, true, "precondition: this IS the overlay")
            compare(port.expanded, true, "…and so is this one")

            verify(land.celebratePx !== port.celebratePx,
                   "the overlay's banner is sized by the pane it is given, not by one "
                   + "literal for 'the overlay' (941x456 -> " + land.celebratePx.toFixed(1)
                   + ", 656x980 -> " + port.celebratePx.toFixed(1) + ")")
            var bL = banner(hOvlL), bP = banner(hOvlP)
            verify(bL && bP, "both overlay banners resolve")
            compare(bL.font.pixelSize, Math.round(land.celebratePx),
                    "the rendered landscape banner is the derived size, not a literal")
            verify(bP.font.pixelSize > bL.font.pixelSize,
                   "the 980-tall pane earns the bigger pop (" + bP.font.pixelSize
                   + " vs " + bL.font.pixelSize + ")")
        }
    }
}
