import QtQuick
import QtTest
import "../../ui/qml" as App


// ─────────────────────────────────────────────────────────────────────────
// Comprehensive coverage for area "widget:tasks" (ui/qml/widgets/TasksWidget.qml).
//
// Drives the widget through its real config surface (store.setSetting /
// patchSettings / applyExternal keyed on "test-instance") and asserts on the
// widget's derived properties and functions: items / visibleItems / doneCount /
// status / toggle / remove / add / clearCompleted / celebrate.
//
// Several assertions intentionally document REAL bugs called out in the audit
// (stale/out-of-range storage index, dropped item fields, undefined text,
// empty-state shown while completed tasks exist, celebration re-firing, scroll
// reset). Those failures are the point - they are NOT test mistakes.
// ─────────────────────────────────────────────────────────────────────────
Item {
    id: root
    width: 520; height: 940

    // Expanded instance - the interactive editor surface.
    WidgetHarness { id: hTasks;   anchors.fill: parent; widgetFile: "TasksWidget.qml"; expanded: true }
    // Compact instance - tile mode (taps must fall through to the host).
    WidgetHarness { id: hCompact; anchors.fill: parent; widgetFile: "TasksWidget.qml"; expanded: false }

    // Schema is a shared area; instantiate it directly (as the config tests do).
    App.WidgetConfigSchema { id: sc }

    // ── helpers ──────────────────────────────────────────────────────────
    // Recursively find the first descendant whose `text` contains `sub`.
    function findText(node, sub) {
        if (!node || node.children === undefined) return null
        for (var i = 0; i < node.children.length; i++) {
            var c = node.children[i]
            if (c && typeof c.text === "string" && c.text.indexOf(sub) >= 0) return c
            var r = findText(c, sub)
            if (r) return r
        }
        return null
    }
    // Recursively find the first ListView descendant (duck-typed).
    function findListView(node) {
        if (!node || node.children === undefined) return null
        for (var i = 0; i < node.children.length; i++) {
            var c = node.children[i]
            if (c && c.contentY !== undefined && typeof c.positionViewAtEnd === "function") return c
            var r = findListView(c)
            if (r) return r
        }
        return null
    }
    function findObject(node, name) {
        if (!node) return null
        if (node.objectName === name) return node
        var kids = node.children || []
        for (var i = 0; i < kids.length; i++) {
            var found = findObject(kids[i], name)
            if (found) return found
        }
        return null
    }
    // Find a schema field by key across all sections of a schema.
    function fieldByKey(schema, key) {
        for (var j = 0; j < schema.sections.length; j++) {
            var fs = schema.sections[j].fields || []
            for (var k = 0; k < fs.length; k++)
                if (fs[k].key === key) return fs[k]
        }
        return null
    }

    // ── Main widget behaviour ────────────────────────────────────────────
    TestCase {
        name: "TasksWidget"
        when: windowShown

        function init() {
            tryVerify(function () { return hTasks.ready }, 3000)
            var s = hTasks.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            hTasks.storeCtl._touchSettings()
            hTasks.item.celebrateMsg = ""
        }
        function cfg() { return hTasks.storeCtl.settingsFor("test-instance") }
        function setItems(a) { hTasks.storeCtl.setSetting("test-instance", "items", a) }

        // ---- schema-matching defaults ------------------------------------
        function test_defaults_match_schema() {
            var w = hTasks.item
            // With no config the widget uses schema defaults: items [], hideCompleted
            // false, celebrate true.
            compare(w.items.length, 0, "no items by default")
            compare(w.hideCompleted, false, "hideCompleted defaults false")
            compare(w.celebrate, true, "celebrate defaults true")
            compare(w.doneCount, 0)
            compare(w.status, "", "no status string when list empty")

            var s = sc.schemaFor("tasks")
            compare(fieldByKey(s, "hideCompleted").dflt, false, "schema hideCompleted dflt false")
            compare(fieldByKey(s, "celebrate").dflt, true, "schema celebrate dflt true")
            compare(fieldByKey(s, "items"), null,
                    "content editing is not duplicated in the settings form")
        }

        // ---- add() -------------------------------------------------------
        function test_add_appends_and_persists() {
            var w = hTasks.item
            w.add("Write report")
            w.add("Email team")
            compare(w.items.length, 2)
            compare(cfg().items.length, 2, "add persists through the store")
            compare(w.items[1].text, "Email team")
            compare(w.items[1].done, false, "new tasks start not-done")
            verify(String(w.items[1].id).indexOf("task-") === 0, "new tasks receive a stable id")
        }
        function test_add_rejects_empty_whitespace_null_and_trims() {
            var w = hTasks.item
            w.add(""); w.add("   "); w.add(null)
            compare(w.items.length, 0, "empty/whitespace/null rejected")
            w.add("  spaced  ")
            compare(w.items.length, 1)
            compare(w.items[0].text, "spaced", "surrounding whitespace trimmed")
        }

        function test_task_storage_is_bounded_by_count_and_text_length() {
            var w = hTasks.item
            var oversized = []
            for (var i = 0; i < w.maxTasks + 25; i++)
                oversized.push({ id: "task-" + i, text: "x".repeat(w.maxTaskLength + 20),
                                 done: i % 2 === 0 })
            setItems(oversized)
            compare(w.items.length, w.maxTasks,
                    "only the documented maximum number of delegates is created")
            compare(w.items[0].text.length, w.maxTaskLength,
                    "task text is bounded before rendering")
            verify(w.taskLimitReached)
            compare(w.add("one more"), false, "the full list rejects another task")
            compare(w.items.length, w.maxTasks)

            w.toggle(0)
            var stored = cfg().items
            compare(stored.length, w.maxTasks + 25,
                    "an unrelated toggle preserves the hidden legacy tail")
            compare(stored[stored.length - 1].id,
                    "task-" + (w.maxTasks + 24),
                    "the last hidden task remains intact")
            compare(stored[0].text.length, w.maxTaskLength + 20,
                    "toggling completion does not truncate the original text")
            compare(stored[0].done, false,
                    "the requested completion field still changes")
        }

        function test_malformed_entries_do_not_count_as_tasks_or_block_add() {
            var w = hTasks.item
            setItems([null, "legacy", { id: "valid", text: "Visible", done: true }])
            compare(w.items.length, 1, "only a valid task counts")
            compare(w.doneCount, 1)
            compare(w.openCount, 0)
            compare(w.completionPercent, 100)
            compare(w.status, "1/1")
            compare(w.storageHiddenCount, 2,
                    "malformed stored entries are disclosed as hidden")
            verify(!w.taskLimitReached,
                   "malformed entries do not consume the rendered task limit")

            verify(w.add("New visible task"))
            var stored = cfg().items
            compare(stored.length, 4, "adding preserves every legacy entry")
            compare(stored[0].text, "New visible task",
                    "a new task is inserted before hidden entries so it remains visible")
            compare(stored[1], null)
            compare(stored[2], "legacy")
        }

        function test_task_scan_is_bounded_and_hidden_tail_is_disclosed() {
            var w = hTasks.item
            var hostile = []
            for (var i = 0; i < w.maxTaskScanEntries; i++)
                hostile.push(null)
            hostile.push({ id: "after-scan", text: "Must stay stored", done: false })
            setItems(hostile)

            compare(w.items.length, 0,
                    "render projection stops at the documented scan boundary")
            compare(w.storageHiddenCount, hostile.length)
            verify(!w.taskLimitReached)
            var footer = findObject(w, "tasksOverflowFooter")
            verify(footer && footer.visible,
                   "expanded view discloses entries hidden by safety limits")
            verify(String(footer.Accessible.name).indexOf("stored entries") >= 0)

            verify(w.add("Reachable"))
            compare(cfg().items.length, hostile.length + 1)
            compare(cfg().items[0].text, "Reachable")
            compare(cfg().items[cfg().items.length - 1].id, "after-scan",
                    "the unscanned tail remains byte-for-byte represented")
        }

        function test_expanded_view_discloses_over_cap_preserved_tasks() {
            var w = hTasks.item
            var oversized = []
            for (var i = 0; i < w.maxTasks + 25; i++)
                oversized.push({ id: "task-" + i, text: "Task " + i, done: false })
            setItems(oversized)
            compare(w.storageHiddenCount, 25)
            var footer = findObject(w, "tasksOverflowFooter")
            verify(footer && footer.visible)
            verify(String(footer.Accessible.name).indexOf(
                       "25 stored entries are hidden by safety limits") >= 0)
        }

        function test_add_and_edit_bound_programmatic_text() {
            var w = hTasks.item
            var longText = "z".repeat(w.maxTaskLength + 30)
            verify(w.add(longText))
            compare(w.items[0].text.length, w.maxTaskLength)
            verify(w.edit(0, longText + "again"))
            compare(w.items[0].text.length, w.maxTaskLength)
        }

        function test_edit_and_reorder_preserve_identity() {
            var w = hTasks.item
            setItems([{ id: "a", text: "First", done: false }, { id: "b", text: "Second", done: false }])
            w.edit(0, "Renamed")
            compare(w.items[0].text, "Renamed"); compare(w.items[0].id, "a")
            w.move(0, 1)
            compare(w.items[1].id, "a"); compare(w.items[0].id, "b")
        }

        function test_top3_and_calm_profile() {
            var w = hTasks.item
            hTasks.storeCtl.patchSettings("test-instance", { displayMode: "top3", behaviorProfile: "calm",
                items: [{text:"1"},{text:"2"},{text:"3"},{text:"4"}] })
            compare(w.visibleItems.length, 3)
            compare(w.celebrate, false)
        }

        function test_clear_completed_requires_two_requests() {
            var w = hTasks.item
            setItems([{ text: "done", done: true }, { text: "open", done: false }])
            w.requestClearCompleted(); compare(w.items.length, 2); compare(w.clearArmed, true)
            w.requestClearCompleted(); compare(w.items.length, 1); compare(w.clearArmed, false)
        }

        // Timers are resources, not visual children; `data` is the union.
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

        // The two-tap confirm is covered above; its EXPIRY was not. An armed
        // state that never disarms turns a stray second tap minutes later into a
        // silent bulk delete - the confirm would still "work", just not mean
        // anything. The timer is driven with a shortened interval rather than by
        // waiting out the real one.
        function test_an_armed_clear_disarms_itself() {
            var w = hTasks.item
            setItems([{ text: "done", done: true }, { text: "open", done: false }])
            var timer = findData(w, function (n) {
                return n.interval === 4000 && n.triggered !== undefined
                       && n.running !== undefined
            })
            verify(timer !== null, "the arm has a disarm timer at all")
            verify(timer.interval >= 1500 && timer.interval <= 10000,
                   "and the confirm window is a deliberate few seconds, not a "
                   + "flicker or a minute (got " + timer.interval + "ms)")

            w.requestClearCompleted()
            compare(w.clearArmed, true, "armed")
            verify(timer.running, "and the disarm clock started")

            timer.interval = 30
            timer.restart()
            tryCompare(w, "clearArmed", false, 2000,
                       "the arm expires on its own rather than waiting forever")
            compare(w.items.length, 2, "and expiring does NOT delete anything")
            timer.interval = 4000
        }

        // The armed state must be visible, not just internal: the button is the
        // only thing telling the user the next tap is destructive.
        function test_the_clear_button_says_it_is_armed() {
            var w = hTasks.item
            setItems([{ text: "done", done: true }, { text: "open", done: false }])
            var button = findData(w, function (n) {
                return n.objectName === "tasksClearCompleted"
            })
            verify(button !== null, "the clear control exists when there is something to clear")
            var idle = String(button.label)
            verify(idle.indexOf("Clear") >= 0 && idle.indexOf(String(w.doneCount)) >= 0,
                   "at rest it says what it would clear (got '" + idle + "')")

            w.requestClearCompleted()
            var armed = String(button.label)
            verify(armed !== idle, "the label changes once armed")
            verify(armed.toLowerCase().indexOf("clear") >= 0,
                   "and still names the action (got '" + armed + "')")
            verify(armed.toLowerCase().indexOf("again") >= 0
                   || armed.toLowerCase().indexOf("confirm") >= 0,
                   "asking for a second, deliberate tap (got '" + armed + "')")
            w.clearArmed = false
        }

        function test_clear_completed_can_be_undone_once() {
            var w = hTasks.item
            setItems([{ id: "done", text: "done", done: true },
                      { id: "open", text: "open", done: false }])
            w.clearCompleted()
            compare(w.items.length, 1)
            verify(w.canUndo)
            verify(w.undoMessage.indexOf("Cleared 1 completed task") >= 0)
            verify(w.undoLast())
            compare(w.items.length, 2)
            compare(w.items[0].id, "done", "undo restores stable identity")
            compare(w.undoLast(), false, "the undo is one-shot")
        }

        // ---- toggle() ----------------------------------------------------
        function test_toggle_flips_only_target_and_persists() {
            var w = hTasks.item
            setItems([{ text: "a", done: false }, { text: "b", done: false }, { text: "c", done: false }])
            w.toggle(1)
            compare(w.items[1].done, true, "target flipped")
            compare(w.items[0].done, false, "sibling untouched")
            compare(w.items[2].done, false, "sibling untouched")
            compare(cfg().items[1].done, true, "toggle persisted via setSetting")
            compare(w.doneCount, 1)
        }

        function test_completion_can_be_undone_with_stable_identity() {
            var w = hTasks.item
            setItems([{ id: "keep-id", text: "Write report", done: false }])
            w.toggle(0)
            verify(w.canUndo)
            compare(w.items[0].done, true)
            verify(w.undoMessage.indexOf("Completed Write report") >= 0)
            verify(w.undoLast())
            compare(w.items[0].id, "keep-id")
            compare(w.items[0].done, false)
            compare(w.canUndo, false)
        }

        // ---- remove() ----------------------------------------------------
        function test_remove_deletes_correct_index() {
            var w = hTasks.item
            setItems([{ text: "a", done: false }, { text: "b", done: false }, { text: "c", done: false }])
            w.remove(0)
            compare(w.items.length, 2)
            compare(w.items[0].text, "b")
            compare(w.items[1].text, "c")
        }
        function test_remove_can_be_undone_with_original_order() {
            var w = hTasks.item
            setItems([{ id: "a", text: "a", done: false },
                      { id: "b", text: "b", done: false },
                      { id: "c", text: "c", done: false }])
            w.remove(1)
            compare(w.items.length, 2)
            verify(w.canUndo)
            verify(w.undoMessage.indexOf("Removed b") >= 0)
            verify(w.undoLast())
            compare(w.items.length, 3)
            compare(w.items[1].id, "b")
        }
        function test_remove_out_of_range_is_safe_noop() {
            var w = hTasks.item
            setItems([{ text: "a", done: false }, { text: "b", done: false }])
            w.remove(5)   // splice(5,1) on len-2 removes nothing
            compare(w.items.length, 2, "out-of-range remove must not delete anything")
            compare(w.items[0].text, "a")
            compare(w.items[1].text, "b")
        }

        // ---- status + reactivity ----------------------------------------
        function test_status_is_done_over_total_and_reactive() {
            var w = hTasks.item
            setItems([{ text: "a", done: true }, { text: "b", done: false }, { text: "c", done: true }])
            compare(w.status, "2/3", "status is doneCount/total")
            w.toggle(1)
            compare(w.status, "3/3", "status updates reactively on revision bump")
        }

        // ---- external (Manager) push updates the tile live ---------------
        function test_external_setUiState_updates_live() {
            var w = hTasks.item
            var doc = {
                version: 1, appearance: {},
                pages: [ { name: "Home", tiles: [ { id: "test-instance", type: "tasks" } ] } ],
                settings: { "test-instance": { items: [ { text: "live", done: false } ] } }
            }
            verify(hTasks.storeCtl.applyExternal(JSON.stringify(doc)), "applyExternal accepts the doc")
            compare(w.items.length, 1, "Manager push reflected live")
            compare(w.items[0].text, "live")
        }

        // ---- hideCompleted + visibleItems idx mapping --------------------
        function test_hidecompleted_false_shows_all() {
            var w = hTasks.item
            hTasks.storeCtl.patchSettings("test-instance", {
                hideCompleted: false,
                items: [{ text: "a", done: true }, { text: "b", done: false }] })
            compare(w.visibleItems.length, 2, "completed tasks visible when hideCompleted off")
        }
        function test_hidecompleted_true_hides_done_but_idx_maps() {
            var w = hTasks.item
            // First item done + hidden; visible list must still map to storage idx.
            hTasks.storeCtl.patchSettings("test-instance", {
                hideCompleted: true,
                items: [{ text: "done0", done: true },
                        { text: "open1", done: false },
                        { text: "open2", done: false }] })
            compare(w.visibleItems.length, 2, "the done item is hidden")
            compare(w.visibleItems[0].text, "open1")
            compare(w.visibleItems[0].idx, 1, "visible row 0 maps to storage index 1")
            compare(w.visibleItems[1].idx, 2, "visible row 1 maps to storage index 2")
            // Toggle the FIRST visible row via its mapped idx → must hit storage[1].
            w.toggle(w.visibleItems[0].idx)
            compare(w.items[1].done, true, "correct storage entry toggled")
            compare(w.items[0].done, true, "the pre-existing done item unchanged")
            compare(w.items[2].done, false, "the other open item unchanged")
        }

        // ---- BUG: stale idx after external shrink -------------------------
        // A row was rendered with idx=1, then the list shrank to length 1
        // (Manager push / config edit). Tapping that row calls toggle(1) with a
        // now out-of-range index. It must be a safe no-op, not a crash or a
        // wrong-entry mutation.  (audit: stale storage-index)
        function test_toggle_stale_idx_after_shrink_is_safe() {
            var w = hTasks.item
            setItems([{ text: "only", done: false }])
            w.toggle(1)   // stale idx from a 2-item render
            compare(w.items.length, 1, "no entry created/destroyed")
            compare(w.items[0].text, "only", "surviving item unchanged")
            compare(w.items[0].done, false, "stale toggle did not flip anything")
        }

        // ---- BUG: extra item fields dropped on toggle --------------------
        // (audit: toggle rebuilds each item as {text,done})
        function test_toggle_preserves_extra_fields() {
            var w = hTasks.item
            setItems([{ text: "x", done: false, id: "u1" }])
            w.toggle(0)
            compare(w.items[0].done, true, "toggle still flips done")
            compare(w.items[0].id, "u1", "external id must survive an on-device toggle")
        }

        // ---- BUG: undefined text propagated ------------------------------
        // (audit: undefined/absent item.text silently propagated)
        function test_toggle_malformed_item_missing_text() {
            var w = hTasks.item
            setItems([{ done: false }])   // no text key
            w.toggle(0)
            verify(w.items[0].text !== undefined,
                   "a malformed item must not be re-persisted with text:undefined")
        }

        // ---- empty-state placeholder -------------------------------------
        function test_empty_state_visible_when_truly_empty() {
            var w = hTasks.item
            setItems([])
            var ph = findText(hTasks.item, "No tasks")
            verify(ph !== null, "placeholder element exists")
            compare(ph.visible, true, "placeholder shows when there are genuinely no tasks")
        }
        // ---- BUG: empty-state shown while completed tasks exist ----------
        // (audit: 'No tasks' empty state shown while completed tasks exist under
        //  hideCompleted=true, contradicting status + Clear button)
        function test_empty_state_hidden_when_completed_tasks_exist() {
            var w = hTasks.item
            hTasks.storeCtl.patchSettings("test-instance", {
                hideCompleted: true,
                items: [{ text: "a", done: true }, { text: "b", done: true }, { text: "c", done: true }] })
            compare(w.status, "3/3", "header still reports 3/3")
            compare(w.doneCount, 3, "Clear-N button would show 3")
            var ph = findText(hTasks.item, "No tasks")
            verify(ph !== null, "placeholder element exists")
            compare(ph.visible, false,
                    "must NOT claim 'no tasks' while 3 completed tasks exist")
            var filtered = findObject(hTasks.item, "tasksFilteredState")
            verify(filtered !== null && filtered.visible,
                   "a completed-and-hidden list explains why it is empty")
            verify(findText(filtered, "All 3 tasks completed") !== null)
        }

        function test_expanded_task_actions_have_explicit_accessibility() {
            var w = hTasks.item
            setItems([{ id: "a", text: "First", done: false },
                      { id: "b", text: "Second", done: false }])
            wait(16)
            var toggle = findObject(w, "taskToggle-0")
            var down = findObject(w, "taskMoveDown-0")
            var remove = findObject(w, "taskRemove-0")
            verify(toggle && down && remove)
            compare(toggle.Accessible.role, Accessible.CheckBox)
            verify(String(toggle.Accessible.name).indexOf("First") >= 0)
            compare(down.Accessible.role, Accessible.Button)
            verify(String(down.Accessible.name).indexOf("Move First down") >= 0)
            compare(remove.Accessible.role, Accessible.Button)
            verify(String(remove.Accessible.name).indexOf("Remove task: First") >= 0)
        }

        // ---- celebration -------------------------------------------------
        function test_celebrate_fires_when_list_becomes_all_done() {
            var w = hTasks.item
            setItems([{ text: "a", done: false }, { text: "b", done: false }])
            w.celebrateMsg = ""
            w.toggle(0)
            compare(w.celebrateMsg, "", "no celebration until the LAST task is done")
            w.toggle(1)
            compare(w.celebrateMsg, "🎉 All done!", "celebration fires as the list completes")
        }
        function test_celebrate_false_suppresses_burst() {
            var w = hTasks.item
            hTasks.storeCtl.patchSettings("test-instance", {
                celebrate: false,
                items: [{ text: "a", done: false }] })
            w.celebrateMsg = ""
            w.toggle(0)
            compare(w.celebrateMsg, "", "celebrate=false suppresses the burst entirely")
        }
        // ---- BUG: celebration re-fires on re-completing an all-done list --
        // (audit: 'All done' celebration re-fires every time)
        function test_celebrate_does_not_refire_on_recomplete() {
            var w = hTasks.item
            setItems([{ text: "a", done: false }])
            w.toggle(0)                    // completes → fires once (expected)
            w.toggle(0)                    // un-complete
            w.celebrateMsg = ""            // reset our probe
            w.toggle(0)                    // re-complete an already-seen full list
            compare(w.celebrateMsg, "",
                    "re-completing an already-complete list must not re-fire the celebration")
        }

        // ---- clearCompleted ---------------------------------------------
        function test_clear_completed_keeps_only_open_in_order() {
            var w = hTasks.item
            setItems([{ text: "a", done: true }, { text: "b", done: false },
                      { text: "c", done: true }, { text: "d", done: false }])
            w.clearCompleted()
            compare(w.items.length, 2, "only the open tasks remain")
            compare(w.items[0].text, "b", "order preserved")
            compare(w.items[1].text, "d", "order preserved")
        }

        // ---- progress fraction math -------------------------------------
        function test_progress_fraction_and_zero_clamp() {
            var w = hTasks.item
            setItems([{ text: "a", done: true }, { text: "b", done: false },
                      { text: "c", done: false }, { text: "d", done: false }])
            compare(w.doneCount / w.items.length, 0.25, "fraction is doneCount/total")
            setItems([])
            compare(w.items.length, 0, "empty list: no divide-by-zero (guarded)")
            compare(w.doneCount, 0)
        }

        // ---- effAccent recolouring hook ----------------------------------
        // Every accented element (checkbox fill/border, progress bar, flash,
        // celebrate label, input focus ring, Add button) binds to effAccent, so
        // verifying effAccent tracks the per-widget accent preset covers them all.
        function test_effaccent_tracks_accent_preset() {
            var w = hTasks.item
            var base = String(w.effAccent).toLowerCase()
            compare(base, String(hTasks.theme.catProductivity).toLowerCase(),
                    "defaults to the productivity category accent")
            w.accentName = "teal"
            compare(String(w.effAccent).toLowerCase(),
                    String(hTasks.theme.accentPresets["teal"].a).toLowerCase(),
                    "per-widget accent recolours effAccent")
            w.accentName = ""   // restore
        }

        // ---- touch targets ----------------------------------------------
        function test_touch_cells_are_large_enough() {
            verify(hTasks.theme.touchTertiary >= 44,
                   "expanded checkbox/remove cells use touchTertiary (>=44px)")
        }

        // ---- BUG: scroll position resets on every revision bump ----------
        // (audit: ListView scroll resets to top after each add)
        function test_scroll_position_survives_add() {
            var w = hTasks.item
            var big = []
            for (var i = 0; i < 30; i++) big.push({ text: "task " + i, done: false })
            setItems(big)
            var lv = findListView(hTasks.item)
            verify(lv !== null, "found the ListView")
            tryVerify(function () { return lv.contentHeight > lv.height + 50 }, 2000,
                      "list is tall enough to scroll")
            lv.contentY = 150
            tryVerify(function () { return lv.contentY > 100 }, 1000, "scrolled down")
            w.add("appended")
            // The model is rebuilt as a fresh array on the revision bump, which
            // discards contentY. A well-behaved list keeps the user's position.
            verify(lv.contentY > 100,
                   "scroll position should survive an add (was reset to " + lv.contentY + ")")
        }
    }

    // ── Compact tile: taps fall through, list inert ──────────────────────
    TestCase {
        name: "TasksCompact"
        when: windowShown
        function init() {
            tryVerify(function () { return hCompact.ready }, 3000)
            var s = hCompact.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            hCompact.storeCtl._touchSettings()
        }

        function test_compact_listview_is_not_interactive() {
            var w = hCompact.item
            hCompact.storeCtl.setSetting("test-instance",
                "items", [{ text: "a", done: false }, { text: "b", done: false }])
            compare(w.expanded, false, "compact instance is not expanded")
            var lv = root.findListView(hCompact.item)
            verify(lv !== null, "found the compact ListView")
            compare(lv.interactive, false,
                    "compact list is inert so a tap reaches the host tapMA and expands the tile")
        }
        function test_compact_status_is_the_only_hint() {
            var w = hCompact.item
            hCompact.storeCtl.setSetting("test-instance",
                "items", [{ text: "a", done: true }, { text: "b", done: false }])
            compare(w.status, "1/2", "compact tile still shows the count summary")
        }

        function test_task_text_is_not_a_completion_control() {
            hCompact.storeCtl.setSetting("test-instance",
                "items", [{ text: "Read the specification", done: false }])
            wait(16)
            var label = root.findObject(hCompact.item, "taskLabel-0")
            var toggle = root.findObject(hCompact.item, "taskToggle-0")
            verify(label !== null && toggle !== null, "label and explicit checkbox render")
            compare(label.children.length, 0,
                    "the task label has no whole-row pointer handler")
            compare(toggle.Accessible.role, Accessible.CheckBox,
                    "the explicit control exposes checkbox semantics")
            verify(String(toggle.Accessible.name).indexOf("Read the specification") >= 0,
                   "the completion control names its task")
        }
    }

    // ── Per-sizeClass structure (W1 wave 2b) ────────────────────────────────
    // Fixed-size hosts at the real projected cell footprints. tasks declares no
    // 0.5x0.5, so there is no micro case.
    Item { id: tTallWrap; width: 348; height: 819
        WidgetHarness { id: tTall; anchors.fill: parent; widgetFile: "TasksWidget.qml"; expanded: false } }
    Item { id: tWideWrap; width: 696; height: 409
        WidgetHarness { id: tWide; anchors.fill: parent; widgetFile: "TasksWidget.qml"; expanded: false } }
    // 1x3 portrait - the whole panel.
    Item { width: 696; height: 2459
        WidgetHarness { id: tBoard; anchors.fill: parent; widgetFile: "TasksWidget.qml"; expanded: false } }
    // Exact legibility-matrix projections for the two responsive regressions:
    // 0.5x1 portrait at native output, and 1x0.5 portrait at 125 percent.
    Item { width: 348; height: 818
        WidgetHarness { id: tMatrixNarrow; anchors.fill: parent; widgetFile: "TasksWidget.qml"; expanded: false } }
    Item { width: 557; height: 327
        WidgetHarness { id: tMatrixWide; anchors.fill: parent; widgetFile: "TasksWidget.qml"; expanded: false } }

    // The OVERLAY, at the two boxes Dashboard actually gives it. `expanded: true`
    // AND sizeClass "full" - the real pairing - because a mode-keyed literal can
    // only be caught with the mode switched ON. These are the live-preview pane
    // beside the config form (Dashboard: 38% of the width in landscape, a <=46%-
    // tall band stacked in portrait), NOT a 2560x720 screen.
    Item { width: 941; height: 456
        WidgetHarness { id: tOvlL; anchors.fill: parent; widgetFile: "TasksWidget.qml"; expanded: true } }
    Item { width: 656; height: 980
        WidgetHarness { id: tOvlP; anchors.fill: parent; widgetFile: "TasksWidget.qml"; expanded: true } }

    TestCase {
        name: "TasksSizes"
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
            host.storeCtl.setSetting(host.instanceId, "items", [
                { text: "Renew the domain", done: true },
                { text: "Send the invoice", done: false },
                { text: "Book the dentist", done: false },
                { text: "Water the plants", done: false }])
        }
        function rows(host) {
            return findAll(host.item, function (n) {
                return n.objectName !== undefined
                       && String(n.objectName).indexOf("taskRow-") === 0 }, [])
        }
        function listOf(host) {
            return findAll(host.item, function (n) {
                return n.hasOwnProperty("contentY") && n.hasOwnProperty("model") }, [])[0]
        }
        function field(host) {
            return findAll(host.item, function (n) {
                return n.objectName === "tasksAddField" }, [])[0]
        }
        function maximumTasks() {
            var result = []
            for (var i = 0; i < 100; i++)
                result.push({ id: "matrix-" + i,
                              text: "Release check " + (i + 1),
                              done: i % 3 === 0 })
            return result
        }
        function longTasks() {
            var result = []
            for (var i = 0; i < 6; i++)
                result.push({ id: "long-" + i,
                              text: "Review release checkpoint " + (i + 1),
                              done: i % 3 === 0 })
            return result
        }
        function assertInside(item, ancestor, label) {
            var p = item.mapToItem(ancestor, 0, 0)
            verify(p.x >= -1 && p.y >= -1
                   && p.x + item.width <= ancestor.width + 1
                   && p.y + item.height <= ancestor.height + 1,
                   label + " stays inside its container: "
                   + p.x.toFixed(1) + "," + p.y.toFixed(1) + " "
                   + item.width.toFixed(1) + "x" + item.height.toFixed(1)
                   + " in " + ancestor.width.toFixed(1) + "x"
                   + ancestor.height.toFixed(1))
        }

        function test_hero_tile_turns_empty_space_into_guidance_and_progress() {
            tryVerify(function () { return tTall.ready }, 3000)
            tTallWrap.width = 696; tTallWrap.height = 1228
            tTall.item.sizeClass = "tall"
            tTall.storeCtl.setSetting(tTall.instanceId, "items", [])
            wait(32)
            compare(tTall.item.roomy, true, "the real 1x1.5 portrait footprint is roomy")
            var empty = findAll(tTall.item, function (n) {
                return n.objectName === "tasksEmptyState" && n.visible
            }, [])
            compare(empty.length, 1, "the hero empty state is visible")
            var prompts = findAll(empty[0], function (n) {
                return String(n.objectName).indexOf("taskPrompt-") === 0 && n.visible
            }, [])
            compare(prompts.length, 3, "the unused space offers three useful starting prompts")
            verify(prompts[0].width >= 120 && prompts[0].height >= tTall.theme.touchTertiary,
                   "the starting prompt is a real touch target (" + prompts[0].width
                   + "x" + prompts[0].height + ")")
            // This size host shares the test scene with the full-screen editor,
            // which owns the physical mouse position. Invoke the prompt's same
            // activation path after asserting its rendered touch geometry.
            prompts[0].activate()
            compare(tTall.item.items.length, 1, "a prompt creates a real task")
            compare(tTall.item.items[0].text, "Plan today")

            var summary = findAll(tTall.item, function (n) {
                return n.objectName === "tasksProgressSummary" && n.visible
            }, [])
            compare(summary.length, 1, "the populated hero card replaces guidance with progress")
            compare(tTall.item.openCount, 1)
            compare(tTall.item.completionPercent, 0)

            tTallWrap.width = 348; tTallWrap.height = 819
            tTall.item.sizeClass = "tall"
            wait(16)
            compare(tTall.item.roomy, false, "the narrow tile keeps the restrained empty state")
        }

        // The row AND its checkbox cell are real touch targets at every size.
        // The checkbox cell used to be 18px wide on a tile, in a 24px row.
        function test_checking_a_task_off_is_a_real_touch_target() {
            tryVerify(function () { return tTall.ready }, 3000)
            tryVerify(function () { return tWide.ready }, 3000)
            var hosts = [tTall, tWide]
            var classes = ["tall", "wide"]
            for (var i = 0; i < hosts.length; i++) {
                hosts[i].item.sizeClass = classes[i]
                seed(hosts[i])
                wait(32)
                var rr = rows(hosts[i])
                verify(rr.length > 0, classes[i] + ": rows render")
                var minT = hosts[i].theme.touchTertiary
                for (var j = 0; j < rr.length; j++) {
                    verify(rr[j].height >= minT,
                           classes[i] + " row " + j + " is >= touchTertiary (" + rr[j].height + ")")
                    // The checkbox cell is the first child: it holds the MouseArea.
                    var cell = rr[j].children[0]
                    verify(cell.width >= minT && cell.height >= minT,
                           classes[i] + " row " + j + " checkbox cell is >= touchTertiary ("
                           + cell.width + "x" + cell.height + ") - it was 18x24")
                }
            }
        }

        function test_task_rows_use_the_readable_label_floor() {
            tryVerify(function () { return tTall.ready && tWide.ready }, 3000)
            var hosts = [tTall, tWide]
            var classes = ["tall", "wide"]
            for (var i = 0; i < hosts.length; i++) {
                hosts[i].item.sizeClass = classes[i]
                seed(hosts[i])
                wait(16)
                var label = rowTextOf(hosts[i])
                verify(label !== null)
                verify(label.font.pixelSize >= hosts[i].theme.fontLabel,
                       classes[i] + " task text uses at least fontLabel")
            }
        }

        function test_scaled_completion_marks_respect_the_active_type_floor() {
            tryVerify(function () {
                return tMatrixNarrow.ready && tMatrixWide.ready
            }, 3000)
            var hosts = [tMatrixNarrow, tMatrixWide]
            var classes = ["tall", "wide"]
            var scales = [1.3, 1.45]
            for (var i = 0; i < hosts.length; i++) {
                hosts[i].item.sizeClass = classes[i]
                hosts[i].theme.textScale = scales[i]
                hosts[i].theme.fontChoice = "lexend"
                hosts[i].storeCtl.setSetting(hosts[i].instanceId, "items",
                                             longTasks())
                wait(32)
                var marks = findAll(hosts[i].item, function (n) {
                    return String(n.objectName).indexOf("taskCheckmark-") === 0
                           && n.visible
                }, [])
                verify(marks.length > 0, classes[i] + " renders completed marks")
                for (var j = 0; j < marks.length; j++) {
                    verify(marks[j].font.pixelSize >= hosts[i].theme.fontMinimum,
                           classes[i] + " mark " + j + " uses the "
                           + hosts[i].theme.fontMinimum + "px type floor")
                    assertInside(marks[j], marks[j].parent,
                                 classes[i] + " mark " + j)
                }
            }
        }

        function test_narrow_tall_long_tasks_wrap_without_truncation() {
            tryVerify(function () { return tMatrixNarrow.ready }, 3000)
            var host = tMatrixNarrow
            host.item.sizeClass = "tall"
            host.theme.textScale = 1.3
            host.theme.fontChoice = "lexend"
            host.storeCtl.setSetting(host.instanceId, "items", longTasks())
            wait(32)

            var labels = findAll(host.item, function (n) {
                return String(n.objectName).indexOf("taskLabel-") === 0
                       && n.visible
            }, [])
            compare(labels.length, 6, "all six long matrix labels render")
            for (var i = 0; i < labels.length; i++) {
                verify(!labels[i].truncated,
                       "long task " + i + " is complete rather than ellipsized")
                verify(labels[i].lineCount <= 2,
                       "long task " + i + " stays within the two-line hierarchy")
                verify(labels[i].contentHeight <= labels[i].height + 1,
                       "long task " + i + " fits its scaled row")
            }
            verify(host.item.rowH >= Math.ceil(host.theme.fontLabel * 3),
                   "the scaled row reserves two-line room")
        }

        function test_scaled_wide_half_tile_keeps_actions_and_footer_inside() {
            tryVerify(function () { return tMatrixWide.ready }, 3000)
            var host = tMatrixWide
            var widget = host.item
            widget.sizeClass = "wide"
            host.theme.textScale = 1.45
            host.theme.fontChoice = "lexend"
            host.storeCtl.setSetting(host.instanceId, "items", maximumTasks())
            wait(32)
            field(host).text =
                "Validate the longest supported field value before the production release"
            wait(32)

            verify(widget.compactHorizontalActions,
                   "the compressed action column selects concise labels")
            var pane = findAll(widget, function (n) {
                return n.objectName === "tasksControlPane"
            }, [])[0]
            var addButton = findAll(widget, function (n) {
                return n.objectName === "tasksAddButton"
            }, [])[0]
            var clearButton = findAll(widget, function (n) {
                return n.objectName === "tasksClearCompleted"
            }, [])[0]
            var footer = findAll(widget, function (n) {
                return n.objectName === "tasksOverflowFooter"
            }, [])[0]
            var footerText = findAll(widget, function (n) {
                return n.objectName === "tasksOverflowFooterText"
            }, [])[0]
            verify(pane && addButton && clearButton && footer && footerText)
            compare(clearButton.label, "Clear 34",
                    "the concise action retains the affected count")
            assertInside(addButton, pane, "add button")
            assertInside(clearButton, pane, "clear-completed button")
            assertInside(footerText, footer, "overflow footer text")
            verify(!footerText.truncated,
                   "the concise overflow message is not ellipsized")
            verify(footerText.contentWidth <= footerText.width + 1
                   && footerText.contentHeight <= footerText.height + 1,
                   "the overflow message fits its assigned text box")
            var clearLabel = findText(clearButton, clearButton.label)
            verify(clearLabel !== null && !clearLabel.truncated,
                   "the concise clear action remains fully readable")
        }

        function test_tile_reports_tasks_hidden_by_height_or_first3() {
            tryVerify(function () { return tTall.ready }, 3000)
            tTallWrap.width = 348
            tTallWrap.height = 819
            tTall.item.sizeClass = "tall"
            var many = []
            for (var i = 0; i < 20; i++)
                many.push({ id: "t" + i, text: "Task " + i, done: false })
            tTall.storeCtl.patchSettings(tTall.instanceId, {
                items: many, displayMode: "all"
            })
            wait(32)
            var footer = findAll(tTall.item, function (n) {
                return n.objectName === "tasksOverflowFooter"
            }, [])[0]
            verify(footer && footer.visible, "clipped tile reports hidden tasks")
            verify(String(footer.Accessible.name).indexOf("more tasks") >= 0)

            tTall.storeCtl.setSetting(tTall.instanceId, "displayMode", "top3")
            wait(16)
            verify(footer.visible, "First 3 reports tasks outside the focused view")
            verify(tTall.item.modeHiddenCount > 0)
        }

        // The add field is a real target too (it was a fixed 40px on tiles).
        function test_the_add_field_is_a_real_touch_target() {
            tryVerify(function () { return tTall.ready }, 3000)
            tTall.item.sizeClass = "tall"
            seed(tTall)
            wait(32)
            var f = field(tTall)
            verify(f.height >= tTall.theme.touchTertiary,
                   "the add field is >= touchTertiary (" + f.height + ")")
        }

        // 1x3 - the whole panel is just MORE ROWS, not bigger ones.
        function test_the_full_panel_earns_rows_not_bulk() {
            tryVerify(function () { return tBoard.ready }, 3000)
            tryVerify(function () { return tTall.ready }, 3000)
            tTall.item.sizeClass = "tall"; seed(tTall)
            tBoard.item.sizeClass = "large"; seed(tBoard)
            wait(32)
            compare(tBoard.item.rowH, tTall.item.rowH,
                    "a 696x2459 panel uses the SAME row height as a 348x819 sliver")
            verify(listOf(tBoard).height > listOf(tTall).height * 2,
                   "…it just shows far more of them ("
                   + listOf(tBoard).height.toFixed(0) + " vs "
                   + listOf(tTall).height.toFixed(0) + "px of list)")
        }

        // wide - the controls move BESIDE the list.
        function test_wide_puts_the_controls_beside_the_list() {
            tryVerify(function () { return tWide.ready }, 3000)
            var t = tWide.item
            t.sizeClass = "tall"
            seed(tWide)
            wait(32)
            var outer = listOf(tWide).parent.parent
            compare(outer.columns, 1, "a tall box stacks the add row under the list")
            t.sizeClass = "wide"
            wait(32)
            compare(t.horiz, true, "wide is the horizontal shape")
            compare(outer.columns, 2, "wide puts the controls beside the list")
            t.sizeClass = "tall"
        }

        // ── size, not mode ──────────────────────────────────────────────────
        function banner(host) {
            return findAll(host.item, function (n) {
                return n.hasOwnProperty("maximumLineCount") && n.maximumLineCount === 2
                       && n.hasOwnProperty("font") }, [])[0] || null
        }
        function emptyLabel(host) {
            return findAll(host.item, function (n) {
                return n.hasOwnProperty("text") && String(n.text).indexOf("No tasks") === 0
            }, [])[0] || null
        }
        // The visible checkbox Rectangle inside a row's first (touch) cell.
        function checkboxOf(host) {
            var rr = rows(host)
            if (!rr.length) return null
            var cell = rr[0].children[0]
            return cell ? cell.children[0] : null
        }
        function rowTextOf(host) {
            var rr = rows(host)
            if (!rr.length) return null
            return findAll(rr[0], function (n) {
                return n.hasOwnProperty("strikeout") || (n.hasOwnProperty("elide")
                       && String(n.text) === "Renew the domain") }, [])[0] || null
        }

        // The overlay is a size class like any other, sized by the pane it is
        // actually given. Both hosts are expanded AND "full"; only the BOX
        // differs, so a literal returning one number for both is caught.
        //
        // The add FIELD carries this one. Deliberately not rowFont or the banner:
        // both reach their designed ceilings (18 / 34) in BOTH panes, so asserting
        // they differ would be "18 !== 18" dressed up as a guard. They get their
        // own tests below, against boxes that genuinely differ.
        function test_overlay_is_sized_by_its_pane_not_by_a_mode_literal() {
            tryVerify(function () { return tOvlL.ready && tOvlP.ready }, 3000)
            var land = tOvlL.item; land.sizeClass = "full"
            var port = tOvlP.item; port.sizeClass = "full"
            seed(tOvlL); seed(tOvlP)
            // A real event-loop turn, not wait(0): these hosts default to
            // sizeClass "tall" and only become "full" on the lines above, so
            // wait(0) reads PRE-change geometry. waitForRendering is wrong
            // offscreen - no frame is ever swapped, so it just burns its timeout.
            wait(16)
            compare(land.expanded, true, "precondition: this IS the overlay")
            compare(port.expanded, true, "…and so is this one")
            compare(land.roomy, true, "…and 'full' is roomy")

            var lf = field(tOvlL), pf = field(tOvlP)
            verify(lf && pf, "both add fields resolve")
            // Both panes may now land on the shared legibility floor. The rendered
            // controls must never shrink beneath it merely to create a difference.
            verify(lf.font.pixelSize >= tOvlL.theme.fontMinimum
                   && pf.font.pixelSize >= tOvlP.theme.fontMinimum,
                   "both add fields keep the legibility floor ("
                   + lf.font.pixelSize + " and " + pf.font.pixelSize + ")")
            // The field is a constant touchSecondary tall at BOTH panes: the room
            // moves the text, never the target.
            compare(lf.height, pf.height,
                    "…while the TARGET stays identical at both panes (" + lf.height + ")")
            verify(lf.height >= tOvlL.theme.touchTertiary,
                   "…and is still a real touch target (" + lf.height + ")")
        }

        // The checkbox is sized by its ROW, and the row is theme.touchTertiary at
        // every size by design - so the box is a CONSTANT, and `expanded ? 30` was
        // a mode-keyed exception to it. Rendered sizes, not the property.
        function test_the_checkbox_is_a_constant_because_its_row_is() {
            tryVerify(function () { return tOvlL.ready && tTall.ready }, 3000)
            tOvlL.item.sizeClass = "full"; seed(tOvlL)
            tTall.item.sizeClass = "tall"; seed(tTall)
            wait(16)
            compare(tOvlL.item.expanded, true, "precondition: one host IS the overlay")
            compare(tTall.item.expanded, false, "…and the other is a tile")
            compare(tOvlL.item.rowH, tTall.item.rowH,
                    "precondition: the rows are the same height at both")
            var ov = checkboxOf(tOvlL), ti = checkboxOf(tTall)
            verify(ov && ti, "both checkboxes resolve")
            compare(ov.width, ti.width,
                    "the overlay's checkbox is the SAME size as a tile's - its row is, "
                    + "so it is (overlay " + ov.width + " vs tile " + ti.width + ")")
            compare(ov.width, ov.height, "…and it is square")
        }

        // The banner is sized by the CARD. Asserted on the rendered Text's own
        // font.pixelSize, not on w.celebratePx: checking the property only proves
        // the arithmetic, and a Text that ignored it and re-froze a literal would
        // pass that untouched.
        function test_celebration_banner_is_sized_by_the_card_not_the_mode() {
            tryVerify(function () { return tBoard.ready && tTall.ready }, 3000)
            var board = tBoard.item; board.sizeClass = "large"   // 696x2459
            var tall = tTall.item;   tall.sizeClass = "tall"     // 348x819
            wait(16)
            compare(board.expanded, false, "precondition: neither host is the overlay")
            compare(tall.expanded, false, "…including the roomy one")
            var bb = banner(tBoard), tb = banner(tTall)
            verify(bb && tb, "both banners resolve")
            compare(bb.font.pixelSize, Math.round(board.celebratePx),
                    "the rendered banner actually uses the derived size on the 1x3 panel")
            compare(tb.font.pixelSize, Math.round(tall.celebratePx),
                    "…and on a 0.5x1 sliver")
            verify(bb.font.pixelSize > tb.font.pixelSize,
                   "a 696x2459 panel pops bigger than a 348x819 sliver - the banner "
                   + "reads the card, not the mode (" + bb.font.pixelSize + " vs "
                   + tb.font.pixelSize + ")")
        }

        // The banner had NO width, no wrapMode and no elide, so a message longer
        // than the card spilled out of both edges. Structural: the box is bounded
        // by the card and the text wraps to at most 2 lines. Never glyph ink -
        // paintedWidth is meaningless headless.
        function test_a_long_celebration_stays_inside_the_card() {
            tryVerify(function () { return tTall.ready }, 3000)
            var t = tTall.item; t.sizeClass = "tall"
            wait(16)
            var b = banner(tTall)
            verify(b !== null, "the banner resolves")
            // Deliberately FAR longer than could conceivably fit: ~330 characters
            // into two ~320px lines at a ~19px font. No font makes that fit, so
            // `lineCount`/`truncated` below are structural here rather than a
            // claim about DejaVu's metrics - the margin, not the measurement, is
            // what keeps them font-independent.
            t.celebrateMsg = "🎉 Every single task on the entire list is finally done, "
                           + "including the ones you have been quietly avoiding since "
                           + "March, the ones you added twice by mistake, and the one "
                           + "you were fairly sure you had already finished but had "
                           + "not, so here is a congratulation long enough that nobody "
                           + "could possibly miss it on their way past the screen!"
            wait(16)
            verify(b.width <= t.width + 0.51,
                   "the banner stays inside the card (" + b.width.toFixed(1)
                   + " in " + t.width + ") - it had no width at all and simply spilled")
            compare(b.lineCount, 2,
                    "…it WRAPS (so wrapMode is live) and stops at 2 lines")
            verify(b.truncated,
                   "…and elides the remainder instead of running past the card")
            t.celebrateMsg = ""
        }

        // The empty-state line follows the room. (rowFont is NOT asserted here:
        // dropping its `w.expanded ? 18` changed nothing - both overlay panes
        // already drove the derived branch into the same 18 cap the literal
        // hardcoded - so any guard for it would be green either way. Documented
        // rather than faked.)
        function test_the_empty_state_line_follows_the_room() {
            tryVerify(function () { return tBoard.ready && tTall.ready }, 3000)
            var board = tBoard.item; board.sizeClass = "large"
            var tall = tTall.item;   tall.sizeClass = "tall"
            tBoard.storeCtl.setSetting(tBoard.instanceId, "items", [])
            tTall.storeCtl.setSetting(tTall.instanceId, "items", [])
            wait(16)
            var be = emptyLabel(tBoard), te = emptyLabel(tTall)
            verify(be && te, "both empty-state lines resolve")
            verify(be.font.pixelSize > te.font.pixelSize,
                   "a 696-wide panel reads its empty state larger than a 348-wide "
                   + "sliver (" + be.font.pixelSize + " vs " + te.font.pixelSize + ")")
            verify(be.width <= board.width + 0.51,
                   "…and it stays inside the card (" + be.width.toFixed(1)
                   + " in " + board.width + ")")
        }
    }
}
