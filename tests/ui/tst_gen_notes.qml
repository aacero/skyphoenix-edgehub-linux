import QtQuick
import QtQuick.Controls
import QtTest
import "../../ui/qml" as App


// ─────────────────────────────────────────────────────────────────────────
// Comprehensive coverage for area "widget:notes" (ui/qml/widgets/NotesWidget.qml).
//
// Exercises: the `text` config option + reactivity, the debounce/flush save
// path, close/destroy semantics, external (Manager) update handling, the
// compact-preview placeholder, the char/word counter, per-widget chrome
// (title/accent/backdrop), cursor-follow on long notes, tap-fallthrough, and
// reset-to-defaults isolation.
//
// Several assertions here intentionally fail because they document REAL bugs
// flagged in the audit (save-on-close loss, external-overwrite, no cursor
// follow, whitespace placeholder, revision churn). Those failures are the
// point - do not "fix" the test to make them pass.
// ─────────────────────────────────────────────────────────────────────────
Item {
    id: root
    width: 480; height: 900

    // Context surface required when the keyboard safety test instantiates the
    // real main.qml shell. These mirror app/src/main.cpp, as in tst_main.qml.
    // Load the lightweight wizard page rather than a whole dashboard: this test
    // targets the shell transform, not widget/resource rendering.
    property bool _isFirstRun: true
    property string _screens: "[]"
    property string _metricsJson: "{}"
    property string _themeMode: "dark"
    property string _targetEdidHash: ""
    property string _targetConnector: ""
    property string _targetModel: ""
    property string _configDir: "/tmp"
    property bool _safeMode: false
    property bool _startInDiagnostics: false
    property bool _windowedMode: true
    property int _targetScreenX: 0
    property int _targetScreenY: 0
    property int _targetScreenWidth: 1920
    property int _targetScreenHeight: 1080

    // Expanded editor instance.
    WidgetHarness { id: hNotes;   anchors.fill: parent; widgetFile: "NotesWidget.qml"; expanded: true }
    // Compact-tile instance (preview + placeholder logic).
    WidgetHarness { id: hCompact; anchors.fill: parent; widgetFile: "NotesWidget.qml"; expanded: false }

    // A NotesWidget hosted in a Loader WE control, so a test can DESTROY the
    // widget item exactly the way Dashboard.closeExpanded() destroys the shared
    // overlay Loader item (active → false). The store lives OUTSIDE the Loader,
    // so it survives the destruction and can be inspected afterwards.
    // `theme` lives on the FILE ROOT, not on destroyHost.
    //
    // The two deliberate-destroy tests below deactivate a Loader, and every
    // binding in the dying NotesWidget/WidgetChrome subtree re-evaluates once
    // during teardown. When `theme` was resolved through destroyHost's scope,
    // those late re-evaluations hit an invalidated context and produced 52
    // "TypeError: Cannot read property 'X' of undefined" diagnostics per run -
    // enough to fail the whole offscreen tier on a gate that exists to catch
    // real product errors.
    //
    // It is a harness artifact, not a product defect, and the discriminator is
    // measurable: tst_dashboard exercises the PRODUCT's real destroy path
    // (Dashboard.closeExpanded -> overlay Loader inactive) and reports fatal=0.
    // The product resolves `theme` from the window-level scope in main.qml,
    // which outlives the Loader's context. Matching that here removes the noise
    // WITHOUT masking anything: no allowlist, no filter, and no defensive
    // guards sprayed across WidgetChrome's bindings for a case the shipped app
    // never hits.
    property alias theme: rootTheme
    App.Theme { id: rootTheme }
    App.WidgetConfigSchema { id: schemaReg }

    Item {
        id: destroyHost
        anchors.fill: parent
        App.DashboardStore { id: dStore }
        property bool hostActive: true
        Component.onCompleted: dStore.load("blank")
        Loader {
            id: dLoader
            anchors.fill: parent
            active: destroyHost.hostActive
            source: "../../ui/qml/widgets/NotesWidget.qml"
            onLoaded: {
                if (!item) return
                dStore.ensureSettings("dnote", {})
                item.instanceId = "dnote"
                item.store = dStore
                item.expanded = true
            }
        }
    }

    // ── Visual-tree helpers ──────────────────────────────────────────────────
    // Recurse over children AND a Flickable's contentItem (which is where its
    // declared children - e.g. the editor - actually live).
    // The `seen` set is a correctness requirement, not an optimisation: a
    // Control's `contentItem` is ALSO one of its `children`, so every
    // contentItem subtree is reachable by two paths. Without memoing, each such
    // subtree is re-walked once per path - 2^k for k nested contentItem-bearing
    // ancestors (Pane > ScrollView > Flickable > TextArea nests several here).
    // Two sibling copies of this bug reached 18.8 GB and 20 GB RSS and caused a
    // system-wide OOM on 2026-07-19. It also inflated collect() results, so any
    // count assertion below was measuring duplicates. Keep the set.
    function walk(node, fn) { _walkSeen(node, fn, new Set()) }
    function _walkSeen(node, fn, seen) {
        if (!node || seen.has(node)) return
        seen.add(node)
        fn(node)
        var kids = node.children
        for (var i = 0; kids && i < kids.length; i++) _walkSeen(kids[i], fn, seen)
        if (node.contentItem && node.contentItem !== node) {
            var ck = node.contentItem.children
            for (var j = 0; ck && j < ck.length; j++) _walkSeen(ck[j], fn, seen)
        }
    }
    function findOne(node, test) {
        var found = null
        walk(node, function (n) { if (!found && test(n)) found = n })
        return found
    }
    function collect(node, test) {
        var out = []
        walk(node, function (n) { if (test(n)) out.push(n) })
        return out
    }
    // TextEdit has persistentSelection; Text does not.
    function findEditor(w) {
        return findOne(w, function (n) {
            return n.hasOwnProperty("persistentSelection") && n.hasOwnProperty("wrapMode")
        })
    }
    // The tile preview is also a Flickable now, so select the expanded editor's
    // named viewport rather than relying on declaration order.
    function findFlickable(w) {
        return findOne(w, function (n) {
            return n.objectName === "notesEditorViewport"
        })
    }
    // All Text nodes (have elide; TextEdit does not).
    function texts(w) {
        return collect(w, function (n) {
            return n.hasOwnProperty("elide") && n.hasOwnProperty("text") && !n.hasOwnProperty("persistentSelection")
        })
    }
    function hasTextEqual(w, s) {
        return texts(w).some(function (t) { return t.text === s })
    }
    // MouseAreas have containsMouse + acceptedButtons.
    function mouseAreas(w) {
        return collect(w, function (n) {
            if (!n.hasOwnProperty("containsMouse") || !n.hasOwnProperty("acceptedButtons"))
                return false
            var cur = n
            while (cur) {
                if (cur.visible !== undefined && !cur.visible)
                    return false
                cur = cur.parent
            }
            return true
        })
    }
    function clearStore(h) {
        // Recreate the bucket as well as clearing it. A preceding authoritative
        // Manager document can legitimately remove the instance entirely, and
        // mutating settingsFor() would then only mutate its detached empty value.
        h.storeCtl.resetSettings("test-instance", {})
    }

    // ── Config: the `text` option + reactivity ───────────────────────────────
    TestCase {
        name: "NotesConfig"
        when: windowShown
        function init() { tryVerify(function () { return hNotes.ready }, 3000); clearStore(hNotes) }

        // Identical shape to the tasks finding: the two-tap clear is covered, its
        // EXPIRY is not. NotesWidget's clear destroys the note outright (there
        // is one note, not a list), so an arm that never expires turns a stray
        // second tap minutes later into a silent wipe.
        function findData(node, pred) {
            if (!node) return null
            if (pred(node)) return node
            var kids = node.data
            for (var i = 0; kids && i < kids.length; i++) {
                var hit = findData(kids[i], pred)
                if (hit) return hit
            }
            return null
        }

        function test_an_armed_clear_disarms_itself_without_clearing() {
            var w = hNotes.item
            w.save("keep me")
            var timer = findData(w, function (n) {
                return n.interval === 4000 && n.running !== undefined
                       && n.triggered !== undefined
            })
            verify(timer !== null, "the arm has a disarm timer")
            verify(timer.interval >= 1500 && timer.interval <= 10000,
                   "and a deliberate confirm window (got " + timer.interval + "ms)")

            w.requestClear()
            compare(w.clearArmed, true, "armed")
            timer.interval = 30
            timer.restart()
            tryCompare(w, "clearArmed", false, 2000, "the arm expires on its own")
            compare(w.current, "keep me",
                    "and expiring must NOT clear the note - the user never confirmed")
            timer.interval = 4000
        }

        // The label is the only signal that the next tap destroys the note.
        function test_the_clear_button_says_it_is_armed() {
            var w = hNotes.item
            w.save("keep me")
            var button = findData(w, function (n) {
                return n.label !== undefined && String(n.label).indexOf("Clear") === 0
            })
            verify(button !== null, "found the clear control")
            compare(String(button.label), "Clear", "at rest it just says Clear")
            w.requestClear()
            compare(String(button.label), "Confirm clear",
                    "armed, it asks for a second deliberate tap")
            w.clearArmed = false
        }

        function test_default_is_empty() {
            var w = hNotes.item
            compare(w.current, "", "a fresh note is empty")
            compare(w.title, "Quick Note", "default title")
            compare(w.iconName, "notes", "notes icon")
        }
        function test_settings_form_does_not_duplicate_the_note_editor() {
            var schema = schemaReg.schemaFor("notes")
            var textFields = 0
            for (var s = 0; s < schema.sections.length; s++) {
                var fields = schema.sections[s].fields || []
                for (var f = 0; f < fields.length; f++)
                    if (fields[f].key === "text") textFields++
            }
            compare(textFields, 0,
                    "the expanded live widget is the single note editor")
        }
        function test_text_config_honored() {
            var w = hNotes.item
            hNotes.storeCtl.patchSettings("test-instance", { text: "hello world" })
            compare(w.current, "hello world", "current reflects settings.text")
        }
        function test_current_reacts_to_setSetting() {
            var w = hNotes.item
            hNotes.storeCtl.setSetting("test-instance", "text", "first")
            compare(w.current, "first")
            hNotes.storeCtl.setSetting("test-instance", "text", "second")
            compare(w.current, "second", "current re-reads on revision bump")
        }
        function test_cfg_is_defensive_clone() {
            var w = hNotes.item
            hNotes.storeCtl.setSetting("test-instance", "text", "orig")
            var c = w.cfg
            c.text = "mutated"   // mutating the returned clone must not affect the store
            compare(hNotes.storeCtl.settingsFor("test-instance").text, "orig",
                    "cfg is a defensive JSON clone, not the live settings object")
        }
    }

    // ── Public save/flush API ────────────────────────────────────────────────
    TestCase {
        name: "NotesSaveApi"
        when: windowShown
        function init() { tryVerify(function () { return hNotes.ready }, 3000); clearStore(hNotes) }

        function test_save_roundtrip() {
            var w = hNotes.item
            w.save("remember the milk")
            compare(w.current, "remember the milk")
            w.save("")
            compare(w.current, "", "saving empty clears the note")
        }
        function test_flush_persists_pending_immediately() {
            var w = hNotes.item
            var ed = findEditor(w)
            verify(ed !== null, "found the TextEdit")
            ed.text = "typed but not idle yet"     // starts the 400ms debounce
            compare(w.hasPendingChanges(), true,
                    "the editor exposes an unflushed local change")
            compare(w.current, "", "debounced write has NOT landed yet")
            verify(w.flush(), "an explicit flush reports success")
            compare(w.current, "typed but not idle yet", "flush persists the pending text now")
            compare(w.hasPendingChanges(), false,
                    "the successful flush retires the local buffer")
        }
        function test_programmatic_sync_does_not_create_a_false_pending_edit() {
            var w = hNotes.item
            hNotes.storeCtl.setSetting("test-instance", "text", "stored text")
            var ed = findEditor(w)
            compare(ed.text, "stored text")
            compare(w.hasPendingChanges(), false,
                    "syncing the editor from stored state is not a user edit")
        }
        function test_debounce_eventually_saves() {
            var w = hNotes.item
            var ed = findEditor(w)
            ed.text = "idle save"
            tryVerify(function () { return w.current === "idle save" }, 2000,
                      "the 400ms debounce eventually persists the text")
        }
        function test_save_state_tracks_debounce() {
            var w = hNotes.item, ed = findEditor(w)
            ed.text = "status check"
            compare(w.saveState, "saving")
            w.flush()
            compare(w.saveState, "saved")
            compare(w.current, "status check")
        }
        function test_history_and_undo_restore_prior_text() {
            var w = hNotes.item
            w.save("first"); w.save("second")
            compare(w.history.length, 1)
            w.undoLast()
            compare(w.current, "first")
            compare(w.history.length, 0)
        }
        function test_manager_text_edit_enters_the_same_undo_history() {
            var w = hNotes.item
            w.save("before Manager")
            hNotes.storeCtl.setSetting("test-instance", "text", "after Manager")
            tryVerify(function () {
                var hist = hNotes.storeCtl.settingsFor("test-instance").history || []
                return hist.length > 0 && hist[hist.length - 1] === "before Manager"
            }, 1000)
            w.undoLast()
            compare(w.current, "before Manager")
        }
        function test_note_size_is_bounded_and_disclosed() {
            var w = hNotes.item
            var body = new Array(w.maxNoteLength + 12).join("x")
            w.save(body)
            compare(w.current.length, w.maxNoteLength)
            verify(w.noteNotice.indexOf("" + w.maxNoteLength) >= 0)
        }
        function test_clear_requires_confirmation() {
            var w = hNotes.item, ed = findEditor(w)
            w.save("keep me"); ed.text = "keep me"
            w.requestClear(); compare(w.current, "keep me"); compare(w.clearArmed, true)
            w.requestClear(); compare(w.current, ""); compare(w.clearArmed, false)
        }
    }

    // ── Close/destroy semantics (audit critical bug) ─────────────────────────
    // Reproduces Dashboard.closeExpanded(): the overlay Loader item is destroyed
    // outright - `expanded` never transitions true→false - so nothing relying on
    // onExpandedChanged runs. Any un-flushed (still-debouncing) text is lost.
    TestCase {
        name: "NotesCloseFlush"
        when: windowShown
        // Force a clean, freshly-loaded item for every destroy test: tear the
        // current one down, clear state, then reload. This makes the destroy
        // observable and independent of what the previous test left behind.
        function init() {
            destroyHost.hostActive = false
            tryVerify(function () { return dLoader.item === null }, 3000)
            var s = dStore.settingsFor("dnote")
            for (var k in s) delete s[k]
            dStore._touchSettings()
            destroyHost.hostActive = true
            tryVerify(function () { return dLoader.item !== null }, 3000)
        }

        function test_destroy_flushes_short_note() {
            var w = dLoader.item
            var ed = findEditor(w)
            ed.text = "buy milk"                 // typed within 400ms of "Done"
            destroyHost.hostActive = false       // closeExpanded → destroy the overlay item
            tryVerify(function () { return dLoader.item === null }, 2000, "widget item destroyed")
            compare(dStore.settingsFor("dnote").text, "buy milk",
                    "closing the overlay must persist the in-progress note")
        }
        function test_destroy_flushes_full_sentence() {
            var w = dLoader.item
            var ed = findEditor(w)
            ed.text = "pick up the dry cleaning and call the dentist"
            destroyHost.hostActive = false
            tryVerify(function () { return dLoader.item === null }, 2000)
            compare(dStore.settingsFor("dnote").text, "pick up the dry cleaning and call the dentist",
                    "a whole note typed with no pause survives a bottom-bar Done close")
        }
    }

    // ── External (Manager) updates while the editor is open (audit high bug) ──
    TestCase {
        name: "NotesExternalUpdate"
        when: windowShown
        function init() { tryVerify(function () { return hNotes.ready }, 3000); clearStore(hNotes) }

        // Re-open sync works via onExpandedChanged when expanded toggles.
        function test_reopen_syncs_editor() {
            var w = hNotes.item
            hNotes.storeCtl.setSetting("test-instance", "text", "stored")
            hNotes.expanded = false
            hNotes.expanded = true
            var ed = findEditor(w)
            compare(ed.text, "stored", "re-opening the editor loads the stored text")
        }
        function test_open_editor_resyncs_on_external_push() {
            var w = hNotes.item
            var ed = findEditor(w)
            ed.text = "aaa"                          // local edit breaks the text binding
            // Manager pushes a new value (applyExternal bumps revision).
            hNotes.storeCtl.settingsFor("test-instance").text = "server text"
            hNotes.storeCtl.revision++
            compare(ed.text, "server text",
                    "an open editor should re-sync to an external update (not keep stale local text)")
        }
        function test_pending_flush_does_not_clobber_external() {
            var w = hNotes.item
            var ed = findEditor(w)
            ed.text = "aaa"
            hNotes.storeCtl.settingsFor("test-instance").text = "server text"
            hNotes.storeCtl.revision++
            w.flush()                                // the still-pending local write lands
            compare(hNotes.storeCtl.settingsFor("test-instance").text, "server text",
                    "a stale local edit must not overwrite the Manager's pushed value")
        }
        function test_authoritative_external_remove_does_not_recreate_note_history() {
            var w = hNotes.item
            w.save("local body")
            verify(hNotes.storeCtl.applyExternal(JSON.stringify({
                version: 1,
                appearance: {},
                settings: {},
                pages: [ { name: "Manager", tiles: [] } ]
            })))
            wait(50)
            compare(Object.keys(hNotes.storeCtl.settingsFor("test-instance")).length, 0,
                    "external removal does not recreate an orphan history bucket")
            compare(w.hasPendingChanges(), false,
                    "the authoritative external sync leaves no stale editor buffer")
            verify(w.flush())
            compare(Object.keys(hNotes.storeCtl.settingsFor("test-instance")).length, 0,
                    "destroy or flush cannot resurrect the removed note")
        }
        // Compact preview DOES react to external revision bumps - this passes.
        function test_compact_reacts_to_external_bump() {
            var w = hCompact.item
            clearStore(hCompact)
            hCompact.storeCtl.setSetting("test-instance", "text", "first")
            compare(w.current, "first")
            hCompact.storeCtl.settingsFor("test-instance").text = "server text"
            hCompact.storeCtl.revision++
            compare(w.current, "server text", "compact preview reflects the external update")
        }
    }

    // ── Compact preview + placeholder + counter (audit low/medium bugs) ──────
    TestCase {
        name: "NotesPreview"
        when: windowShown
        function init() { tryVerify(function () { return hCompact.ready }, 3000); clearStore(hCompact) }

        function test_empty_shows_placeholder() {
            var w = hCompact.item
            verify(hasTextEqual(w, "Tap to jot a note…"), "empty note shows the compact placeholder")
        }
        function test_text_shows_in_preview() {
            var w = hCompact.item
            hCompact.storeCtl.setSetting("test-instance", "text", "groceries list")
            verify(hasTextEqual(w, "groceries list"), "preview renders the stored note")
        }
        function test_whitespace_only_shows_placeholder() {
            var w = hCompact.item
            hCompact.storeCtl.setSetting("test-instance", "text", "   ")
            verify(hasTextEqual(w, "Tap to jot a note…"),
                   "a whitespace-only note should still show the placeholder prompt")
        }
    }

    // ── Char/word counter (audit low bug) ────────────────────────────────────
    TestCase {
        name: "NotesCounter"
        when: windowShown
        function init() { tryVerify(function () { return hNotes.ready }, 3000); clearStore(hNotes) }
        // The counter Text contains the word "chars".
        function counter(w) {
            return findOne(w, function (n) {
                return n.hasOwnProperty("elide") && typeof n.text === "string" && n.text.indexOf("chars") >= 0
            })
        }

        function test_counter_reports_words() {
            var w = hNotes.item
            var ed = findEditor(w)
            ed.text = "one two three"
            var c = counter(w)
            verify(c !== null && c.visible, "counter is visible with content")
            compare(c.text, "13 chars · 3 words", "reports chars and words")
        }
        function test_counter_hidden_for_whitespace_only() {
            var w = hNotes.item
            var ed = findEditor(w)
            ed.text = "   "
            var c = counter(w)
            // A whitespace-only note has 0 words; the counter should not claim content.
            verify(!c || !c.visible,
                   "the counter should be hidden for a whitespace-only note (0 words)")
        }

        function test_editor_footer_never_overlaps_the_note() {
            var w = hNotes.item
            var ed = findEditor(w)
            var flick = findFlickable(w)
            var footer = findOne(w, function (n) {
                return n.objectName === "notesEditorFooter"
            })
            verify(ed && flick && footer && footer.visible)
            verify(ed.font.pixelSize >= hNotes.theme.fontTitle,
                   "editor uses at least title-size reading text")
            verify(flick.y + flick.height <= footer.y + 0.51,
                   "the editor viewport ends before the footer begins")
            verify(footer.height >= hNotes.theme.touchTertiary,
                   "the consolidated footer preserves touch targets")
        }
    }

    // ── No-op typing should not churn the store (audit low bug) ──────────────
    TestCase {
        name: "NotesNoChurn"
        when: windowShown
        function init() { tryVerify(function () { return hNotes.ready }, 3000); clearStore(hNotes) }

        function test_type_and_delete_no_net_write() {
            var w = hNotes.item
            var ed = findEditor(w)
            hNotes.storeCtl.setSetting("test-instance", "text", "base")
            ed.text = "base"                 // sync editor to the saved base
            var rev0 = hNotes.storeCtl.revision
            ed.text = "basex"                // type a char
            ed.text = "base"                 // delete it - net unchanged
            w.flush()                        // land the debounced write
            compare(hNotes.storeCtl.settingsFor("test-instance").text, "base", "text unchanged")
            compare(hNotes.storeCtl.revision, rev0,
                    "a net no-op edit must not bump revision / re-persist / re-broadcast")
        }
    }

    // ── Cursor follow on long notes (audit medium bug) ───────────────────────
    TestCase {
        name: "NotesCursorFollow"
        when: windowShown
        function init() { tryVerify(function () { return hNotes.ready }, 3000); clearStore(hNotes) }

        function test_flickable_scrolls_to_caret() {
            var w = hNotes.item
            var ed = findEditor(w)
            var flick = findFlickable(w)
            verify(ed !== null && flick !== null, "found editor + flickable")
            var lines = ""
            // Deliberately exceed even the tallest supported editor viewport so
            // this remains an overflow test on every runner and screen geometry.
            for (var i = 0; i < 500; i++) lines += "line number " + i + "\n"
            ed.text = lines
            ed.cursorPosition = ed.text.length          // caret at the very end
            tryVerify(function () { return flick.contentHeight > flick.height }, 2000,
                      "the oversized fixture must overflow the editor viewport")
            var caretBottom = ed.cursorRectangle.y + ed.cursorRectangle.height
            verify(caretBottom - flick.contentY <= flick.height + 2,
                   "the Flickable should scroll so the caret stays visible (caretBottom=" +
                   caretBottom + " contentY=" + flick.contentY + " h=" + flick.height + ")")
        }

        // The release deliberately has no embedded keyboard. A desktop input
        // method may still be used, but the shell must not retain the removed
        // panel's content translation.
        function test_shell_has_no_embedded_keyboard_lift() {
            var component = Qt.createComponent("../../ui/qml/main.qml")
            tryVerify(function () { return component.status !== Component.Loading }, 5000)
            compare(component.status, Component.Ready, "main.qml compiles: " + component.errorString())
            var win = component.createObject(root)
            verify(win !== null, "main.qml instantiated with the test shell context")

            var stack = findOne(win.contentItem, function (n) {
                return n.objectName === "mainStack"
            })
            verify(stack !== null, "found the real main.qml StackView")
            compare(Qt.inputMethod.visible, false, "offscreen input method starts inactive")
            compare(stack.transform.length, 0,
                    "the removed embedded keyboard leaves no content lift behind")
            win.destroy()
        }
    }

    // ── Per-widget chrome: title / accent / backdrop (audit testCases) ───────
    TestCase {
        name: "NotesChrome"
        when: windowShown
        function init() { tryVerify(function () { return hNotes.ready }, 3000); clearStore(hNotes) }

        function test_custom_title_overrides_default() {
            var w = hNotes.item
            w.titleOverride = "Groceries"        // Dashboard binds this from settings.title
            verify(hasTextEqual(w, "Groceries"), "header shows the custom title")
            verify(!hasTextEqual(w, "Quick Note"), "the default title is replaced")
            w.titleOverride = ""                 // reset
        }
        function test_accent_preset_honored() {
            var w = hNotes.item
            compare(String(w.effAccent), String(w.accentColor),
                    "no override → the widget's category accent (catInfo)")
            w.accentName = "red"
            compare(String(w.effAccent).toLowerCase(), String(hNotes.theme.accentPresets["red"].a).toLowerCase(),
                    "a per-widget accent preset overrides the category accent")
            w.accentName = ""
        }
        function test_card_backdrop_honored() {
            var w = hNotes.item
            compare(w.cardBackdrop, "none", "default is no backdrop")
            w.cardBackdrop = "aurora"
            compare(w.cardBackdrop, "aurora", "per-widget card backdrop is applied")
            var layer = findOne(w, function (n) {
                return n.hasOwnProperty("style") && n.hasOwnProperty("running") && n.hasOwnProperty("visible")
            })
            verify(layer !== null && layer.style === "aurora", "BackdropLayer picks up the backdrop style")
            w.cardBackdrop = "none"
        }
    }

    // ── Tap fallthrough on the compact tile (audit testCase) ─────────────────
    TestCase {
        name: "NotesTapFallthrough"
        when: windowShown
        function init() { tryVerify(function () { return hCompact.ready }, 3000); clearStore(hCompact) }

        function test_no_mousearea_swallows_taps() {
            var w = hCompact.item
            var mas = mouseAreas(w)
            // The widget must not host a tap-eating MouseArea; the only chrome
            // MouseArea is a hover ring with acceptedButtons: Qt.NoButton, so
            // taps fall through to the Dashboard's tapMA to expand the tile.
            for (var i = 0; i < mas.length; i++)
                compare(mas[i].acceptedButtons, Qt.NoButton,
                        "compact notes tile has no tap-swallowing MouseArea")
        }
    }

    // ── Reset to defaults is isolated per instance (audit testCase) ──────────
    TestCase {
        name: "NotesReset"
        when: windowShown
        function init() { tryVerify(function () { return hNotes.ready }, 3000); clearStore(hNotes) }

        function test_reset_clears_text_without_leaking() {
            var st = hNotes.storeCtl
            st.setSetting("test-instance", "text", "abc")
            st.setSetting("other-note", "text", "keep me")
            st.resetSettings("test-instance", { text: "" })
            compare(st.settingsFor("test-instance").text, "", "reset clears the note to empty")
            compare(st.settingsFor("other-note").text, "keep me",
                    "reset does not leak/clear another instance's note")
        }
    }

    // ── Per-sizeClass structure (W1 wave 2b) ────────────────────────────────
    // Fixed-size hosts at the real projected cell footprints.
    Item { id: qMicroWrap; width: 348; height: 409
        WidgetHarness { id: qMicro; anchors.fill: parent; widgetFile: "NotesWidget.qml"; expanded: false } }
    Item { id: qBaseWrap; width: 696; height: 819
        WidgetHarness { id: qBase; anchors.fill: parent; widgetFile: "NotesWidget.qml"; expanded: false } }
    // 1x3 portrait - the whole panel.
    Item { id: qBoardWrap; width: 696; height: 2459
        WidgetHarness { id: qBoard; anchors.fill: parent; widgetFile: "NotesWidget.qml"; expanded: false } }

    TestCase {
        name: "NotesSizes"
        when: windowShown

        function findAll(node, pred, acc) {
            acc = acc || []
            if (!node) return acc
            if (pred(node)) acc.push(node)
            var kids = node.children
            for (var i = 0; kids && i < kids.length; i++) findAll(kids[i], pred, acc)
            return acc
        }
        function seed(host) {
            host.storeCtl.setSetting(host.instanceId, "text",
                "Pick up the dry cleaning before six, and ask Ana whether the "
                + "invoice for March ever went out. Also: the boiler service is due.")
        }
        // Every Text has a wrapMode property (the chrome header's title matches a
        // naive predicate), so identify the preview by the note it is showing.
        function preview(host) {
            return findAll(host.item, function (n) {
                return n.hasOwnProperty("wrapMode") && n.hasOwnProperty("elide")
                       && n.visible && String(n.text).indexOf("Pick up the dry") === 0 }, [])[0]
        }
        function previewViewport(host) {
            return findAll(host.item, function (n) {
                return n.objectName === "notesPreviewViewport"
            }, [])[0]
        }

        // 0.5x0.5 - the note IS the tile; 36px of chrome is a line you cannot spare.
        function test_micro_drops_the_header_for_a_line_of_note() {
            tryVerify(function () { return qMicro.ready }, 3000)
            var q = qMicro.item
            q.sizeClass = "compact"
            seed(qMicro)
            wait(32)
            compare(q.micro, true, "a 348x409 compact box is the micro tile")
            compare(q.showHeader, false, "micro drops the chrome header")
            verify(preview(qMicro) !== null, "the note still renders")
            verify(preview(qMicro).font.pixelSize >= qMicro.theme.fontTitle,
                   "micro preview keeps the reading-size floor")
        }

        // The preview is sized off the BOX, not off `expanded` - the wave-2b bug.
        function test_the_preview_scales_with_the_tile() {
            tryVerify(function () { return qBase.ready }, 3000)
            tryVerify(function () { return qMicro.ready }, 3000)
            qMicro.item.sizeClass = "compact"; seed(qMicro)
            var q = qBase.item
            q.sizeClass = "compact"
            seed(qBase)
            wait(32)
            verify(q.previewPx > 13,
                   "a 696x819 tile reads past the old flat 13px (" + q.previewPx.toFixed(0) + ")")
            verify(q.previewPx > qMicro.item.previewPx,
                   "…and bigger than a 348x409 tile's (" + q.previewPx.toFixed(0)
                   + " vs " + qMicro.item.previewPx.toFixed(0) + ")")
            verify(preview(qBase).font.pixelSize >= qBase.theme.fontTitle,
                   "baseline preview keeps the reading-size floor")
        }

        function test_roomy_preview_adds_context_and_a_designed_empty_state() {
            tryVerify(function () { return qBase.ready }, 3000)
            var q = qBase.item
            q.sizeClass = "compact"
            seed(qBase)
            wait(32)
            compare(q.roomyPreview, true, "the real 1x1 card earns preview context")
            var meta = findAll(q, function (n) {
                return n.objectName === "notesPreviewMeta" && n.visible
            }, [])
            compare(meta.length, 1, "the note preview uses its footer for useful metadata")
            var previewItem = findAll(q, function (n) {
                return n.objectName === "notesPreviewText"
            }, [])[0]
            verify(previewItem !== null)
            verify(findAll(meta[0], function (n) {
                return n.hasOwnProperty("text") && String(n.text).indexOf("words") >= 0
            }, []).length === 1, "word count is visible")
            verify(findAll(meta[0], function (n) {
                return n.hasOwnProperty("text")
                    && String(n.text).indexOf("Tap anywhere to edit") >= 0
            }, []).length === 1, "the short-note footer makes edit mode discoverable")
            verify(String(meta[0].Accessible.name).indexOf("Tap anywhere to edit") >= 0)

            var longNote = ""
            for (var n = 0; n < 90; n++) longNote += "important detail " + n + " "
            qBase.storeCtl.setSetting(qBase.instanceId, "text", longNote)
            wait(16)
            compare(meta[0].visible, false,
                    "long notes spend the footer space on reading content")
            compare(previewViewport(qBase).anchors.bottomMargin,
                    qBase.theme.spacingSm,
                    "a hidden footer reserves no blank line")

            qBase.storeCtl.setSetting(qBase.instanceId, "text", "")
            wait(16)
            var empty = findAll(q, function (n) {
                return n.objectName === "notesRichEmptyState" && n.visible
            }, [])
            compare(empty.length, 1, "an empty roomy note gets a designed capture prompt")
            verify(findAll(empty[0], function (n) {
                return n.hasOwnProperty("text")
                    && String(n.text) === "Capture it before it disappears"
            }, []).length === 1, "the empty state explains the widget's purpose")
        }

        function test_long_preview_is_complete_and_vertically_scrollable() {
            tryVerify(function () { return qMicro.ready }, 3000)
            var oldScale = qMicro.theme.textScale
            var oldFont = qMicro.theme.fontChoice
            var longNote = new Array(120).join(
                "Release note content stays readable and scrollable. ")
            try {
                qMicroWrap.z = 100
                qMicroWrap.width = 278
                qMicroWrap.height = 327
                qMicro.item.sizeClass = "compact"
                qMicro.theme.textScale = 1.45
                qMicro.theme.fontChoice = "hyperlegible"
                qMicro.storeCtl.setSetting(qMicro.instanceId, "text", longNote)
                wait(32)

                var viewport = previewViewport(qMicro)
                var body = findAll(qMicro.item, function(node) {
                    return node.objectName === "notesPreviewText"
                }, [])[0]
                var scrollBar = findAll(qMicro.item, function(node) {
                    return node.objectName === "notesPreviewScrollBar"
                }, [])[0]
                verify(viewport && body && scrollBar)
                compare(body.text, longNote,
                        "the tile retains the complete maximum-content fixture")
                compare(body.elide, Text.ElideNone)
                compare(body.truncated, false)
                verify(body.font.pixelSize >= qMicro.theme.fontMinimum)
                verify(body.height >= body.contentHeight)
                verify(viewport.contentHeight > viewport.height)
                compare(viewport.interactive, true)
                compare(viewport.flickableDirection, Flickable.VerticalFlick,
                        "vertical reading leaves horizontal page navigation free")
                compare(scrollBar.policy, ScrollBar.AlwaysOn,
                        "overflow is visibly disclosed before the first swipe")
                compare(scrollBar.interactive, false,
                        "the narrow indicator is not presented as a touch target")

                viewport.contentY = 0
                mouseDrag(viewport, viewport.width / 2,
                          viewport.height - qMicro.theme.spacingLg,
                          0, -Math.min(120, viewport.height / 2),
                          Qt.LeftButton)
                tryVerify(function () { return viewport.contentY > 0 }, 1000,
                          "a vertical drag reveals later note content")

                qMicro.storeCtl.setSetting(qMicro.instanceId, "text", "Short note")
                tryVerify(function () { return !viewport.interactive }, 1000)
                compare(viewport.contentY, 0,
                        "short content returns the preview to its beginning")
                compare(scrollBar.policy, ScrollBar.AlwaysOff)
            } finally {
                qMicro.theme.textScale = oldScale
                qMicro.theme.fontChoice = oldFont
                qMicroWrap.width = 348
                qMicroWrap.height = 409
                qMicroWrap.z = 0
            }
        }

        // 1x3 earns more LINES, not bigger type: a note is one body of text.
        function test_the_full_panel_earns_lines_not_bigger_type() {
            tryVerify(function () { return qBoard.ready }, 3000)
            tryVerify(function () { return qBase.ready }, 3000)
            qBase.item.sizeClass = "compact"; seed(qBase)
            var q = qBoard.item
            q.sizeClass = "large"
            seed(qBoard)
            wait(32)
            compare(q.previewPx, qBase.item.previewPx,
                    "a 696x2459 panel uses the SAME type size as a 696x819 tile - "
                    + "the same column width carries the same line length")
            verify(preview(qBoard).height > preview(qBase).height * 2,
                   "…it just has room for far more lines")
        }
    }
}
