import QtQuick
import QtTest


// ─────────────────────────────────────────────────────────────────────────
// tst_braindump - ui/qml/widgets/BraindumpWidget.qml.
//
// What must hold: capture is one line and one key, the newest entry is the one
// you see, entries survive a store round-trip, and the list cannot grow the
// config without bound. The ordering assertion is not cosmetic - an entry that
// lands off-screen is an entry the user believes was lost.
// ─────────────────────────────────────────────────────────────────────────
Item {
    id: root
    width: 1000; height: 720

    WidgetHarness {
        id: h; x: 0; y: 0; width: 620; height: parent.height
        widgetFile: "BraindumpWidget.qml"; expanded: true
    }
    WidgetHarness {
        id: hc; x: 640; y: 0; width: 340; height: 380
        widgetFile: "BraindumpWidget.qml"; expanded: false
    }

    function clearSettings(harness) {
        var s = harness.storeCtl.settingsFor("test-instance")
        for (var k in s) delete s[k]
        harness.storeCtl._touchSettings()
    }
    function findAll(node, pred, acc) {
        acc = acc || []
        if (!node) return acc
        if (pred(node)) acc.push(node)
        var kids = node.children
        for (var i = 0; kids && i < kids.length; i++) findAll(kids[i], pred, acc)
        return acc
    }
    // A round-trip must go through a doc that OWNS the settings bucket: the store
    // prunes settings whose id no tile claims (an orphan bucket is a leak), so a
    // harness instance with no tile is dropped on reload - correctly. Give the
    // document the tile a real config.toml would have, then reload it.
    function reloadWith(harness, doc, type) {
        doc.pages = [ { name: "Test", tiles: [ { id: "test-instance", type: type, size: "1x1" } ] } ]
        return harness.storeCtl.applyExternal(JSON.stringify(doc))
    }
    function fieldIn(w) {
        var f = root.findAll(w, function (n) {
            return n.objectName === "braindumpCaptureField"
        }, [])
        return f.length ? f[0] : null
    }

    // ── Capture ──────────────────────────────────────────────────────────
    TestCase {
        name: "BraindumpCapture"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000); clearSettings(h) }

        function test_add_stores_text_and_a_timestamp() {
            var before = Date.now()
            h.item.add("call the dentist")
            var e = h.item.entries
            compare(e.length, 1)
            compare(e[0].text, "call the dentist")
            verify(e[0].at >= before && e[0].at <= Date.now(), "stamped with the time it arrived")
            verify(h.item.undoSnapshot !== null)
            compare(h.item.undoSnapshot.label, "Undo captured thought")
            h.item.undoLastChange()
            compare(h.item.entries.length, 0, "capture itself is undoable")
        }

        function test_add_trims_and_ignores_empty() {
            h.item.add("   spaced out   ")
            compare(h.item.entries.length, 1)
            compare(h.item.entries[0].text, "spaced out", "leading/trailing space is trimmed")
            h.item.add("")
            h.item.add("    ")
            h.item.add(null)
            compare(h.item.entries.length, 1, "blank captures are ignored, not stored as empty rows")
        }

        // Newest first: the thing you just typed must be the thing you can see.
        function test_newest_entry_is_first() {
            h.item.add("first")
            h.item.add("second")
            h.item.add("third")
            var e = h.item.entries
            compare(e.length, 3)
            compare(e[0].text, "third", "the newest capture leads the list")
            compare(e[1].text, "second")
            compare(e[2].text, "first")
        }

        function test_remove_takes_out_the_right_entry() {
            h.item.add("a"); h.item.add("b"); h.item.add("c")   // → c, b, a
            h.item.remove(1)
            var e = h.item.entries
            compare(e.length, 2)
            compare(e[0].text, "c"); compare(e[1].text, "a", "'b' is the one that went")
        }

        function test_edit_preserves_identity_and_timestamp_and_can_be_undone() {
            h.item.add("draft")
            var original = h.item.entries[0]
            h.item.beginEdit(0)
            h.item.commitEdit("finished")
            compare(h.item.entries[0].text, "finished")
            compare(h.item.entries[0].id, original.id)
            compare(h.item.entries[0].at, original.at)
            h.item.undoLastChange()
            compare(h.item.entries[0].text, "draft")
        }

        function test_remove_ignores_an_out_of_range_index() {
            h.item.add("only")
            h.item.remove(5); h.item.remove(-1)
            compare(h.item.entries.length, 1, "a stale index is ignored, not a crash or a wrong delete")
        }

        function test_clear_all_empties_the_list() {
            h.item.add("a"); h.item.add("b")
            h.item.clearAll()
            compare(h.item.entries.length, 2, "the first request only arms confirmation")
            compare(h.item.clearArmed, true)
            h.item.clearAll()
            compare(h.item.entries.length, 0)
            compare(h.storeCtl.settingsFor("test-instance").entries.length, 0, "and it persisted")
            h.item.undoLastChange()
            compare(h.item.entries.length, 2, "the confirmed clear can be undone")
        }

        function test_remove_can_be_undone() {
            h.item.add("keep me")
            h.item.remove(0)
            compare(h.item.entries.length, 0)
            h.item.undoLastChange()
            compare(h.item.entries.length, 1)
            compare(h.item.entries[0].text, "keep me")
        }

        function test_legacy_entries_receive_stable_ids_on_the_first_mutation() {
            h.storeCtl.setSetting("test-instance", "entries", [
                { text: "older", at: 1000 },
                { text: "newer", at: 2000 }
            ])
            h.item.remove(1)
            compare(h.item.entries.length, 1)
            verify(String(h.item.entries[0].id).indexOf("dump-legacy-1000-0") === 0)
            h.item.undoLastChange()
            compare(h.item.entries.length, 2)
            verify(String(h.item.entries[1].id).length > 0,
                   "the restored snapshot keeps immutable IDs")
        }

        // An unbounded array here would grow config.toml forever - this is the
        // widget you dump into without thinking.
        function test_list_is_capped_and_drops_the_oldest() {
            var w = h.item
            for (var i = 0; i < w.maxEntries + 10; i++) w.add("entry " + i)
            compare(w.entries.length, w.maxEntries, "the list is capped")
            compare(w.entries[0].text, "entry " + (w.maxEntries + 9), "newest kept")
            compare(w.entries[w.entries.length - 1].text, "entry 10", "the oldest were dropped")
            verify(w.captureNotice.indexOf("oldest thought") >= 0,
                   "eviction is disclosed instead of silently losing the oldest item")
        }

        function test_entry_truncation_is_disclosed() {
            var w = h.item
            var longText = new Array(w.maxEntryLength + 12).join("x")
            w.add(longText)
            compare(w.entries[0].text.length, w.maxEntryLength)
            verify(w.captureNotice.indexOf("" + w.maxEntryLength) >= 0,
                   "the visible notice states the persisted limit")
        }
    }

    // ── Persistence ──────────────────────────────────────────────────────
    TestCase {
        name: "BraindumpPersistence"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000); clearSettings(h) }

        function test_entries_survive_a_store_round_trip() {
            h.item.add("remember the milk")
            h.item.add("email Dana")
            var onDisk = JSON.parse(JSON.stringify(h.storeCtl._persistableData()))
            var saved = onDisk.settings["test-instance"]
            verify(saved !== undefined, "the instance reaches disk")
            compare(saved.entries.length, 2, "entries are persistable, not ephemeral")
            compare(saved.entries[0].text, "email Dana")
            verify(saved.entries[0].at > 0, "the timestamp is persisted too")
            // applyExternal() is the real reload path - the same one the hub and the
            // Manager push a document through - and it forces the doc back through
            // JSON, so this exercises the serialization config.toml actually uses.
            compare(root.reloadWith(h, onDisk, "braindump"), true, "the document reloads")
            var e = h.item.entries
            compare(e.length, 2, "the dump is still there after a reload")
            compare(e[0].text, "email Dana")
            compare(e[1].text, "remember the milk")
        }

        function test_undo_snapshot_survives_round_trip_for_another_host() {
            h.item.add("shared thought")
            h.item.remove(0)
            compare(h.item.entries.length, 0)
            var onDisk = JSON.parse(JSON.stringify(h.storeCtl._persistableData()))
            compare(onDisk.settings["test-instance"].undoEntries.length, 1,
                    "undo state is shared data, not local component state")
            compare(root.reloadWith(h, onDisk, "braindump"), true)
            verify(h.item.undoSnapshot !== null,
                   "a newly loaded host sees the same undo action")
            h.item.undoLastChange()
            compare(h.item.entries.length, 1)
            compare(h.item.entries[0].text, "shared thought")
        }
    }

    // ── Timestamp rendering ──────────────────────────────────────────────
    TestCase {
        name: "BraindumpStamps"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000); clearSettings(h) }

        function test_todays_stamp_is_just_a_time() {
            var now = new Date()
            compare(h.item.stampOf({ text: "x", at: now.getTime() }),
                    Qt.formatTime(now, "HH:mm"), "today → time only")
        }

        function test_an_older_stamp_carries_the_weekday() {
            var then = new Date(Date.now() - 3 * 86400000)
            compare(h.item.stampOf({ text: "x", at: then.getTime() }),
                    Qt.formatDateTime(then, "ddd HH:mm"), "older → weekday + time")
        }

        // A hand-edited config must not render "Invalid Date" next to real text.
        function test_a_missing_or_broken_stamp_renders_blank() {
            compare(h.item.stampOf({ text: "x" }), "", "no stamp → blank, not 'Invalid Date'")
            compare(h.item.stampOf({ text: "x", at: "nonsense" }), "")
            compare(h.item.stampOf(null), "")
        }

        function test_showTimes_hides_the_stamp_column() {
            h.item.add("a thought")
            compare(h.item.showTimes, true, "stamps show by default")
            var stamp = Qt.formatTime(new Date(), "HH:mm")
            var shown = root.findAll(h.item, function (n) {
                return n.hasOwnProperty("text") && n.text === stamp && n.hasOwnProperty("font")
            }, [])
            verify(shown.length > 0 && shown[0].visible, "the stamp is rendered")
            h.storeCtl.patchSettings("test-instance", { showTimes: false })
            compare(h.item.showTimes, false)
            verify(!shown[0].visible, "turning showTimes off actually hides it")
        }
    }

    // ── Real typing on the tile ──────────────────────────────────────────
    TestCase {
        name: "BraindumpTileInput"
        when: windowShown
        function init() { tryVerify(function () { return hc.ready }, 3000); clearSettings(hc) }

        // Capture supports real multiline text. Ctrl+Enter commits while plain
        // Enter remains available for a newline.
        function test_multiline_capture_and_ctrl_enter_from_the_tile() {
            var f = root.fieldIn(hc.item)
            verify(f !== null, "the tile carries the capture field")
            f.forceActiveFocus()
            keyClick(Qt.Key_B); keyClick(Qt.Key_U); keyClick(Qt.Key_Y)
            keyClick(Qt.Key_Return)
            keyClick(Qt.Key_N); keyClick(Qt.Key_O); keyClick(Qt.Key_W)
            compare(f.text, "buy\nnow", "plain Enter inserts a newline")
            keyClick(Qt.Key_Return, Qt.ControlModifier)
            compare(hc.item.entries.length, 1, "Enter commits the capture")
            compare(hc.item.entries[0].text, "buy\nnow")
            compare(f.text, "", "and the field is cleared, ready for the next thought")
            compare(hc.storeCtl.settingsFor("test-instance").entries[0].text, "buy\nnow", "persisted")
        }
    }

    TestCase {
        name: "BraindumpAccessibility"
        when: windowShown
        function init() {
            tryVerify(function () { return h.ready }, 3000)
            clearSettings(h)
            h.storeCtl.setSetting("test-instance", "entries", [
                { id: "one", text: "first thought", at: Date.now() }
            ])
            wait(32)
        }

        function test_edit_and_remove_are_explicit_named_keyboard_actions() {
            var edits = root.findAll(h.item, function(n) {
                return String(n.objectName).indexOf("braindumpEdit-") === 0
            }, [])
            var removes = root.findAll(h.item, function(n) {
                return String(n.objectName).indexOf("braindumpRemove-") === 0
            }, [])
            compare(edits.length, 1)
            compare(removes.length, 1)
            compare(edits[0].Accessible.role, Accessible.Button)
            compare(removes[0].Accessible.role, Accessible.Button)
            compare(edits[0].Accessible.name, "Edit thought 1")
            compare(removes[0].Accessible.name, "Remove thought 1")
            verify(edits[0].width >= h.theme.touchTertiary
                   && edits[0].height >= h.theme.touchTertiary)
            verify(removes[0].width >= h.theme.touchTertiary
                   && removes[0].height >= h.theme.touchTertiary)
        }

        function test_content_typography_leads_timestamp_typography() {
            verify(h.item.rowFont >= 17)
            verify(h.item.stampFont < h.item.rowFont)
            var notice = root.findAll(h.item, function(n) {
                return n.objectName === "braindumpActionNotice"
            }, [])[0]
            verify(notice !== null)
            h.item.remove(0)
            compare(notice.text, "Thought removed")
            compare(notice.Accessible.name, "Thought removed")
        }
    }

    // ── Delegate survival (W1 wave 2b) ──────────────────────────────────────
    // store.revision is GLOBAL: every widget's setting write bumps it, and the
    // metric tiles write their sparkline `hist` every ~2s. `entries` is derived
    // off `cfg`, so it IS a brand-new array roughly every two seconds - which
    // looks like the SensorsWidget clunk (a model rebuilt on every tick).
    //
    // Measured, it is not: a ListView fed a JS array diffs it and reuses the
    // delegates when the content is equal. That is the property the user actually
    // feels, so it is pinned HERE rather than left to a comment - if a future
    // change starts genuinely rebuilding the queue while someone is reading it,
    // this fails.
    TestCase {
        name: "BraindumpIdentity"
        when: windowShown
        function init() { tryVerify(function () { return hc.ready }, 3000); clearSettings(hc) }

        function rows() {
            return root.findAll(hc.item, function (n) {
                return n.hasOwnProperty("modelData") && n.hasOwnProperty("index") }, [])
        }

        function test_an_unrelated_write_does_not_rebuild_the_list() {
            // A REALISTIC queue: with only one or two entries the delegates get
            // recycled out of the pool either way and the test cannot see a rebuild.
            var a = []
            for (var i = 0; i < 40; i++) a.push({ text: "thought " + i, at: Date.now() - i * 1000 })
            hc.storeCtl.setSetting("test-instance", "entries", a)
            wait(50)
            var before = rows()
            verify(before.length > 5, "a realistic queue realises many delegates ("
                   + before.length + ")")

            // Exactly what a CPU/NET tile does every ~2s: an ephemeral write on a
            // DIFFERENT instance. It must not disturb this widget's list.
            var revBefore = hc.storeCtl.revision
            hc.storeCtl.setSetting("cpu-somewhere-else", "hist", [0.1, 0.2, 0.3])
            verify(hc.storeCtl.revision > revBefore, "the global revision did bump")
            wait(50)

            // Set membership, not index order: a ListView hands back its children
            // in recycling order, so comparing index-wise reports false churn.
            var after = rows()
            var survived = 0
            for (var j = 0; j < before.length; j++)
                if (after.indexOf(before[j]) >= 0) survived++
            compare(survived, before.length,
                    "every realised delegate survives an unrelated sparkline tick ("
                    + survived + "/" + before.length + ") - the queue is not rebuilt "
                    + "under the reader every 2s")
        }

        // A genuine edit MUST still refresh the list.
        function test_a_real_edit_still_updates_the_list() {
            hc.storeCtl.setSetting("test-instance", "entries",
                [{ text: "first", at: Date.now() }])
            wait(32)
            compare(hc.item.entries.length, 1)
            hc.item.add("second")
            wait(32)
            compare(hc.item.entries.length, 2, "a real add re-derives the list")
            compare(hc.item.entries[0].text, "second", "newest first")
        }
    }

    // ── Per-sizeClass structure (W1 wave 2b) ────────────────────────────────
    Item { width: 348; height: 819
        WidgetHarness { id: dTall; anchors.fill: parent; widgetFile: "BraindumpWidget.qml"; expanded: false } }
    Item { id: dWideWrap; width: 696; height: 409
        WidgetHarness { id: dWide; anchors.fill: parent; widgetFile: "BraindumpWidget.qml"; expanded: false } }
    Item { width: 696; height: 1639
        WidgetHarness { id: dLarge; anchors.fill: parent; widgetFile: "BraindumpWidget.qml"; expanded: false } }

    TestCase {
        name: "BraindumpSizes"
        when: windowShown

        function seed(host) {
            var now = Date.now(), a = []
            for (var i = 0; i < 6; i++) a.push({ text: "thought " + i, at: now - i * 600000 })
            host.storeCtl.setSetting(host.instanceId, "entries", a)
        }
        function field(host) {
            return root.findAll(host.item, function (n) {
                return n.objectName === "braindumpCaptureField" }, [])[0]
        }
        function listOf(host) {
            return root.findAll(host.item, function (n) {
                return n.hasOwnProperty("contentY") && n.hasOwnProperty("model") }, [])[0]
        }

        // The capture row is a real touch target at every size - it was a fixed
        // 40px, under theme.touchTertiary (52), and capture is the whole product.
        function test_the_capture_row_is_a_real_touch_target() {
            tryVerify(function () { return dTall.ready }, 3000)
            tryVerify(function () { return dWide.ready }, 3000)
            var hosts = [dTall, dWide]
            var classes = ["tall", "wide"]
            for (var i = 0; i < hosts.length; i++) {
                hosts[i].item.sizeClass = classes[i]
                seed(hosts[i])
                wait(32)
                var f = field(hosts[i])
                verify(f.height >= hosts[i].theme.touchTertiary,
                       classes[i] + ": the capture field is >= touchTertiary ("
                       + f.height + " >= " + hosts[i].theme.touchTertiary + ")")
            }
        }

        // A taller box earns MORE ROWS, not bigger ones.
        function test_a_taller_box_earns_more_rows() {
            tryVerify(function () { return dLarge.ready }, 3000)
            tryVerify(function () { return dTall.ready }, 3000)
            dTall.item.sizeClass = "tall"; seed(dTall)
            dLarge.item.sizeClass = "large"; seed(dLarge)
            wait(32)
            verify(listOf(dLarge).height > listOf(dTall).height,
                   "the larger box shows more of the queue ("
                   + listOf(dLarge).height.toFixed(0) + " vs "
                   + listOf(dTall).height.toFixed(0) + "px)")
        }

        // wide - the capture column moves BESIDE the queue.
        function test_wide_puts_capture_beside_the_queue() {
            tryVerify(function () { return dWide.ready }, 3000)
            var d = dWide.item
            d.sizeClass = "tall"
            seed(dWide)
            wait(32)
            var outer = listOf(dWide).parent.parent
            compare(outer.columns, 1, "a tall box stacks the capture row under the queue")
            d.sizeClass = "wide"
            wait(32)
            compare(d.horiz, true, "wide is the horizontal shape")
            compare(outer.columns, 2, "wide puts the capture column beside the queue")
            d.sizeClass = "tall"
        }

        function test_hidden_queue_rows_are_disclosed() {
            tryVerify(function () { return dWide.ready }, 3000)
            var d = dWide.item
            d.sizeClass = "wide"
            var many = []
            for (var i = 0; i < 30; i++)
                many.push({ id: "row-" + i, text: "thought " + i,
                              at: Date.now() - i * 1000 })
            dWide.storeCtl.setSetting(dWide.instanceId, "entries", many)
            wait(32)
            var overflow = root.findAll(d, function(n) {
                return n.objectName === "braindumpOverflow"
            }, [])[0]
            verify(overflow !== null && overflow.visible)
            verify(overflow.Accessible.name.indexOf("more thoughts") >= 0)
        }
    }
}
