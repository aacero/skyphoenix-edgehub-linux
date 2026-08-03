import QtQuick
import QtTest


// ─────────────────────────────────────────────────────────────────────────
// tst_routine - ui/qml/widgets/RoutineWidget.qml.
//
// Two requirements, both asserted rather than reviewed:
//   1. It resets each day. Yesterday's ticks must not read as today's, and the
//      reset must need no timer (it is a read-time decision, so a device that was
//      asleep at midnight still wakes up to a clean list).
//   2. It does not punish. The "no shaming" rule is enforced STRUCTURALLY: the
//      widget must persist no cross-day state at all, so there is nothing a bad
//      day can decrement. That is a stronger, testable claim than "we picked calm
//      colours" - so the test asserts the absence of streak-shaped keys on disk,
//      not just the absence of red.
// ─────────────────────────────────────────────────────────────────────────
Item {
    id: root
    width: 1000; height: 720

    WidgetHarness {
        id: h; x: 0; y: 0; width: 620; height: parent.height
        widgetFile: "RoutineWidget.qml"; expanded: true
    }
    WidgetHarness {
        id: hc; x: 640; y: 0; width: 340; height: 420
        widgetFile: "RoutineWidget.qml"; expanded: false
    }

    function clearSettings(harness) {
        var s = harness.storeCtl.settingsFor("test-instance")
        for (var k in s) delete s[k]
        harness.storeCtl._touchSettings()
    }
    function todayKey() { return Qt.formatDate(new Date(), "yyyy-MM-dd") }
    // A round-trip must go through a doc that OWNS the settings bucket: the store
    // prunes settings whose id no tile claims (an orphan bucket is a leak), so a
    // harness instance with no tile is dropped on reload - correctly. Give the
    // document the tile a real config.toml would have, then reload it.
    function reloadWith(harness, doc, type) {
        doc.pages = [ { name: "Test", tiles: [ { id: "test-instance", type: type, size: "1x1" } ] } ]
        return harness.storeCtl.applyExternal(JSON.stringify(doc))
    }
    function findAll(node, pred, acc) {
        acc = acc || []
        if (!node) return acc
        if (pred(node)) acc.push(node)
        var kids = node.children
        for (var i = 0; kids && i < kids.length; i++) findAll(kids[i], pred, acc)
        return acc
    }

    // ── Steps ────────────────────────────────────────────────────────────
    TestCase {
        name: "RoutineSteps"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000); clearSettings(h) }

        // routineSummaryText is the one line the card shows about today. The
        // suite located it only to check its font size; its CONTENT - a
        // three-way ladder - was never asserted, so a rest day could have read
        // "0 of 3 done" (a nag on a day nothing was scheduled) with nothing to
        // catch it.
        function findNamed(name) {
            var hits = root.findAll(h.item, function (n) {
                return n.objectName === name
            }, [])
            return hits.length ? hits[0] : null
        }

        function test_summary_says_which_of_the_three_days_this_is_data() {
            return [
                { tag: "rest-day", steps: "Meds\nPack bag", days: "",
                  want: "Rest day, nothing scheduled" },
                { tag: "partway", steps: "Meds\nPack bag", days: "0,1,2,3,4,5,6",
                  done: 1, want: "1 of 2 done" },
                { tag: "none-done", steps: "Meds\nPack bag", days: "0,1,2,3,4,5,6",
                  done: 0, want: "0 of 2 done" },
                { tag: "all-done", steps: "Meds\nPack bag", days: "0,1,2,3,4,5,6",
                  done: 2, want: "All done for today ✓" }
            ]
        }
        function test_summary_says_which_of_the_three_days_this_is(data) {
            var w = h.item
            h.storeCtl.patchSettings("test-instance",
                                     { steps: data.steps, activeDays: data.days })
            for (var i = 0; i < (data.done || 0); i++) w.toggle(w.stepList[i])
            var summary = findNamed("routineSummaryText")
            verify(summary !== null, "the card has a summary line")
            compare(String(summary.text), data.want,
                    data.tag + " reads as '" + data.want + "'")
        }

        // A rest day is not a failure to complete anything.
        function test_a_rest_day_does_not_count_undone_steps() {
            h.storeCtl.patchSettings("test-instance",
                                     { steps: "Meds\nPack bag", activeDays: "" })
            compare(h.item.isActiveToday(), false, "precondition: not scheduled today")
            var summary = findNamed("routineSummaryText")
            verify(String(summary.text).indexOf("of 2") < 0,
                   "it does not report progress against steps that were never due "
                   + "(got '" + summary.text + "')")
        }

        function test_steps_parse_one_per_line_in_order() {
            h.storeCtl.patchSettings("test-instance", { steps: "Meds\nBrush teeth\nPack bag" })
            compare(h.item.steps, "Meds\nBrush teeth\nPack bag",
                    "the steps setting is read back off the store")
            var s = h.item.stepList
            compare(s.length, 3)
            compare(s[0], "Meds"); compare(s[1], "Brush teeth"); compare(s[2], "Pack bag")
        }

        function test_blank_lines_and_padding_are_ignored() {
            h.storeCtl.patchSettings("test-instance", { steps: "\n  Meds  \n\n\nPack bag\n  \n" })
            var s = h.item.stepList
            compare(s.length, 2, "blank lines never become empty steps")
            compare(s[0], "Meds"); compare(s[1], "Pack bag")
        }

        function test_no_steps_means_no_progress_and_not_allDone() {
            h.storeCtl.patchSettings("test-instance", { steps: "" })
            compare(h.item.stepList.length, 0)
            compare(h.item.doneCount, 0)
            compare(h.item.allDone, false, "an empty routine is not 'all done'")
        }

        function test_structured_step_keeps_completion_after_rename_and_reorder() {
            h.storeCtl.patchSettings("test-instance", {
                routineFormat: "structured",
                routineItems: [
                    { id: "pack", text: "Pack bag" },
                    { id: "water", text: "Water plants" }
                ]
            })
            h.item.toggle(h.item.stepItems[0])
            compare(h.storeCtl.settingsFor("test-instance").done[0], "pack")
            h.storeCtl.patchSettings("test-instance", {
                routineItems: [
                    { id: "water", text: "Water plants" },
                    { id: "pack", text: "Pack work bag" }
                ]
            })
            compare(h.item.stepItems[1].text, "Pack work bag")
            compare(h.item.stepItems[1].key, "pack")
            compare(h.item.isDone(h.item.stepItems[1]), true,
                    "completion follows immutable ID through rename and reorder")
            compare(h.item.doneCount, 1)
        }

        function test_cleared_structured_steps_do_not_fall_back_to_legacy_text() {
            h.storeCtl.patchSettings("test-instance", {
                steps: "Old step",
                routineItems: [],
                routineFormat: "structured"
            })
            compare(h.item.stepItems.length, 0)
            compare(h.item.stepList.length, 0)
        }

        function test_duplicate_steps_have_independent_identity() {
            h.storeCtl.patchSettings("test-instance", { steps: "Stretch\nStretch" })
            var w = h.item
            compare(w.stepItems.length, 2)
            verify(w.stepItems[0].key !== w.stepItems[1].key)
            w.toggle(w.stepItems[0])
            compare(w.isDone(w.stepItems[0]), true)
            compare(w.isDone(w.stepItems[1]), false)
        }
    }

    // ── Ticking ──────────────────────────────────────────────────────────
    TestCase {
        name: "RoutineTicking"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000); clearSettings(h) }

        function test_toggle_marks_and_persists_with_todays_day() {
            h.storeCtl.patchSettings("test-instance", { steps: "Meds\nPack bag" })
            h.item.toggle("Meds")
            compare(h.item.isDone("Meds"), true)
            compare(h.item.isDone("Pack bag"), false)
            compare(h.item.doneCount, 1)
            var saved = h.storeCtl.settingsFor("test-instance")
            compare(saved.day, root.todayKey(), "the day is stamped")
            compare(saved.done.length, 1); compare(saved.done[0], "Meds")
        }

        function test_toggle_is_reversible() {
            h.storeCtl.patchSettings("test-instance", { steps: "Meds" })
            h.item.toggle("Meds"); compare(h.item.isDone("Meds"), true)
            h.item.toggle("Meds"); compare(h.item.isDone("Meds"), false, "un-ticking works")
            compare(h.item.doneCount, 0)
        }

        function test_allDone_when_every_step_is_ticked() {
            h.storeCtl.patchSettings("test-instance", { steps: "A\nB" })
            h.item.toggle("A")
            compare(h.item.allDone, false)
            h.item.toggle("B")
            compare(h.item.allDone, true)
            compare(h.item.doneCount, 2)
        }

        function test_ticks_survive_a_store_round_trip() {
            h.storeCtl.patchSettings("test-instance", { steps: "Meds\nPack bag" })
            h.item.toggle("Meds")
            var onDisk = JSON.parse(JSON.stringify(h.storeCtl._persistableData()))
            compare(onDisk.settings["test-instance"].done[0], "Meds", "persistable, not ephemeral")
            // applyExternal() is the real reload path - the same one the hub and the
            // Manager push a document through - and it forces the doc back through
            // JSON, so this exercises the serialization config.toml actually uses.
            compare(root.reloadWith(h, onDisk, "routine"), true, "the document reloads")
            compare(h.item.isDone("Meds"), true, "still ticked after a reload")
        }

        // Identity is the step text, not the index - inserting a line above must
        // not silently move a tick onto a different step.
        function test_ticks_survive_inserting_a_step_above() {
            h.storeCtl.patchSettings("test-instance", { steps: "Pack bag" })
            h.item.toggle("Pack bag")
            h.storeCtl.patchSettings("test-instance", { steps: "Meds\nPack bag" })
            compare(h.item.stepList[0], "Meds")
            compare(h.item.isDone("Meds"), false, "the newly inserted step is NOT ticked")
            compare(h.item.isDone("Pack bag"), true, "the originally ticked step still is")
            compare(h.item.doneCount, 1)
        }
    }

    // ── The daily reset ──────────────────────────────────────────────────
    TestCase {
        name: "RoutineReset"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000); clearSettings(h) }

        function test_a_previous_days_ticks_do_not_count_today() {
            h.storeCtl.patchSettings("test-instance",
                { steps: "Meds\nPack bag", day: "2020-01-01", done: ["Meds", "Pack bag"] })
            var w = h.item
            compare(w.doneToday.length, 0, "yesterday's ticks read as nothing")
            compare(w.isDone("Meds"), false)
            compare(w.doneCount, 0)
            compare(w.allDone, false, "the day starts clean, not finished")
        }

        // No timer, no midnight write: the rollover is decided when read, so a
        // device asleep at midnight still wakes to a clean list.
        function test_the_reset_needs_no_timer_and_writes_nothing() {
            h.storeCtl.patchSettings("test-instance",
                { steps: "Meds", day: "2020-01-01", done: ["Meds"] })
            compare(h.item.isDone("Meds"), false, "already reset on read alone")
            var saved = h.storeCtl.settingsFor("test-instance")
            compare(saved.day, "2020-01-01", "reading did not rewrite the stored day…")
            compare(saved.done.length, 1, "…nor the stored list")
        }

        function test_ticking_after_a_rollover_restamps_the_day() {
            h.storeCtl.patchSettings("test-instance",
                { steps: "Meds\nPack bag", day: "2020-01-01", done: ["Meds", "Pack bag"] })
            h.item.toggle("Meds")
            var saved = h.storeCtl.settingsFor("test-instance")
            compare(saved.day, root.todayKey(), "the day is re-stamped")
            compare(saved.done.length, 1, "yesterday's list is replaced, not appended to")
            compare(saved.done[0], "Meds")
            compare(h.item.doneCount, 1, "and only today's tick counts")
        }

        function test_inactive_weekday_is_a_rest_day_and_cannot_be_ticked() {
            var w = h.item
            w.dayOfWeekOverride = 0
            h.storeCtl.patchSettings("test-instance", { steps: "Work", activeDays: "1,2,3,4,5" })
            compare(w.isActiveToday(), false)
            w.toggle("Work")
            compare(w.doneCount, 0)
            compare(h.storeCtl.settingsFor("test-instance").done, undefined)
            w.dayOfWeekOverride = 1
            compare(w.isActiveToday(), true)
            w.toggle("Work")
            compare(w.doneCount, 1)
            w.dayOfWeekOverride = -1
        }
    }

    // ── No shaming ───────────────────────────────────────────────────────
    TestCase {
        name: "RoutineDoesNotPunish"
        when: windowShown
        function init() { tryVerify(function () { return h.ready }, 3000); clearSettings(h) }

        // The structural guarantee. If someone adds a streak later, this fails.
        function test_nothing_is_remembered_across_days() {
            h.storeCtl.patchSettings("test-instance", { steps: "A\nB" })
            h.item.toggle("A"); h.item.toggle("B")
            compare(h.item.allDone, true)
            var saved = JSON.parse(JSON.stringify(h.storeCtl._persistableData()))
                            .settings["test-instance"]
            // Only today's ticks + the day stamp + config may be stored.
            var allowed = ["steps", "day", "done"]
            for (var k in saved)
                verify(allowed.indexOf(k) >= 0,
                       "routine persists no '" + k + "' - nothing to lose by skipping a day")
            verify(saved.streak === undefined, "no streak is kept")
            verify(saved.bestStreak === undefined, "no personal best to fall short of")
            verify(saved.history === undefined, "no history of bad days")
            verify(saved.lastCompletedDay === undefined, "no record of when you last managed it")
        }

        // A skipped day must cost nothing: state after a gap is identical to state
        // after a fresh start.
        function test_a_skipped_day_costs_nothing() {
            h.storeCtl.patchSettings("test-instance",
                { steps: "A\nB", day: "2019-05-05", done: ["A", "B"] })
            var afterGap = { done: h.item.doneCount, all: h.item.allDone }
            clearSettings(h)
            h.storeCtl.patchSettings("test-instance", { steps: "A\nB" })
            compare(afterGap.done, h.item.doneCount,
                    "a 5-year gap leaves you exactly where a brand-new routine does")
            compare(afterGap.all, h.item.allDone)
        }

        // An unticked step is a normal thing you might do - not an error.
        function test_an_unticked_step_is_not_rendered_as_an_error() {
            h.storeCtl.patchSettings("test-instance", { steps: "Meds\nPack bag" })
            h.item.toggle("Meds")
            var labels = root.findAll(h.item, function (n) {
                return n.hasOwnProperty("text") && n.hasOwnProperty("color")
                       && (n.text === "Meds" || n.text === "Pack bag")
            }, [])
            verify(labels.length >= 2, "both step labels are rendered")
            for (var i = 0; i < labels.length; i++) {
                var c = String(labels[i].color)
                verify(c !== String(h.theme.error), labels[i].text + " is not error-coloured")
                verify(c !== String(h.theme.warning), labels[i].text + " is not warning-coloured")
            }
            var undone = null
            for (var j = 0; j < labels.length; j++) if (labels[j].text === "Pack bag") undone = labels[j]
            verify(undone !== null)
            compare(String(undone.color), String(h.theme.textPrimary),
                    "an undone step is just normal text")
        }

        // The visible progress copy must never scold.
        function test_progress_copy_states_a_fact_and_nothing_more() {
            h.storeCtl.patchSettings("test-instance", { steps: "A\nB\nC" })
            h.item.toggle("A")
            var texts = root.findAll(h.item, function (n) {
                return n.hasOwnProperty("text") && n.visible && String(n.text).length > 0
            }, []).map(function (n) { return String(n.text).toLowerCase() }).join(" | ")
            compare(texts.indexOf("1 of 3") >= 0, true, "it says where you are")
            var banned = ["missed", "failed", "fail", "behind", "streak", "lost",
                          "don't break", "overdue", "you should", "again!"]
            for (var i = 0; i < banned.length; i++)
                verify(texts.indexOf(banned[i]) < 0, "never says '" + banned[i] + "'")
        }
    }

    // ── Real input on the tile ───────────────────────────────────────────
    TestCase {
        name: "RoutineTileInput"
        when: windowShown
        function init() { tryVerify(function () { return hc.ready }, 3000); clearSettings(hc) }

        function test_tapping_the_explicit_checkbox_ticks_and_persists() {
            hc.storeCtl.patchSettings("test-instance", { steps: "Meds\nPack bag" })
            wait(32)
            var rows = root.findAll(hc.item, function (n) {
                return n.hasOwnProperty("done") && n.hasOwnProperty("modelData")
            }, [])
            var actions = root.findAll(hc.item, function (n) {
                return String(n.objectName).indexOf("routineStepAction-") === 0
            }, [])
            verify(rows.length >= 1, "step rows are rendered on the tile (" + rows.length + ")")
            verify(actions.length >= 1, "each row has an explicit completion action")
            verify(actions[0].width >= hc.theme.touchTertiary
                   && actions[0].height >= hc.theme.touchTertiary,
                   "the completion action is a full touch target")
            compare(actions[0].Accessible.role, Accessible.CheckBox)
            verify(String(actions[0].Accessible.name).indexOf("Meds") >= 0,
                   "the action names the affected step")
            mouseClick(actions[0])
            compare(hc.item.isDone("Meds"), true, "a tap on the checkbox ticks the step")
            compare(hc.storeCtl.settingsFor("test-instance").done[0], "Meds", "and it persisted")
        }

        function test_step_text_is_not_a_completion_control() {
            hc.storeCtl.patchSettings("test-instance", { steps: "Meds" })
            wait(16)
            var labels = root.findAll(hc.item, function (n) {
                return String(n.objectName).indexOf("routineStepLabel-") === 0
            }, [])
            compare(labels.length, 1)
            compare(labels[0].children.length, 0,
                    "the descriptive text does not carry a whole-row pointer handler")
        }
    }

    // ── Per-sizeClass structure (W1 wave 2b) ────────────────────────────────
    // Fixed-size hosts at the real projected cell footprints. routine declares no
    // 0.5x0.5, so there is no micro case.
    Item { width: 348; height: 819
        WidgetHarness { id: rTall; anchors.fill: parent; widgetFile: "RoutineWidget.qml"; expanded: false } }
    Item { id: rWideWrap; width: 696; height: 409
        WidgetHarness { id: rWide; anchors.fill: parent; widgetFile: "RoutineWidget.qml"; expanded: false } }
    Item { width: 696; height: 1639
        WidgetHarness { id: rLarge; anchors.fill: parent; widgetFile: "RoutineWidget.qml"; expanded: false } }

    TestCase {
        name: "RoutineSizes"
        when: windowShown

        function seed(host) {
            host.storeCtl.patchSettings(host.instanceId,
                { steps: "Meds\nPack bag\nStretch\nWater plants\nInbox zero" })
        }
        function rowsOf(host) {
            return root.findAll(host.item, function (n) {
                return n.hasOwnProperty("done") && n.hasOwnProperty("modelData") }, [])
        }
        function listOf(host) {
            return root.findAll(host.item, function (n) {
                return n.hasOwnProperty("contentY") && n.hasOwnProperty("model") }, [])[0]
        }

        // The row is a real touch target at EVERY size - it was 22px on a tile.
        function test_every_tile_row_is_a_real_touch_target() {
            tryVerify(function () { return rTall.ready }, 3000)
            tryVerify(function () { return rWide.ready }, 3000)
            var hosts = [rTall, rWide]
            var classes = ["tall", "wide"]
            for (var i = 0; i < hosts.length; i++) {
                hosts[i].item.sizeClass = classes[i]
                seed(hosts[i])
                wait(32)
                var rows = rowsOf(hosts[i])
                verify(rows.length > 0, classes[i] + ": rows render")
                for (var j = 0; j < rows.length; j++)
                    verify(rows[j].height >= hosts[i].theme.touchTertiary,
                           classes[i] + " row " + j + " is >= touchTertiary ("
                           + rows[j].height + " >= " + hosts[i].theme.touchTertiary
                           + ") - a tick is never a 22px target")
            }
        }

        // A taller box earns MORE ROWS, not bigger ones.
        function test_a_taller_box_earns_more_rows_not_bigger_ones() {
            tryVerify(function () { return rLarge.ready }, 3000)
            tryVerify(function () { return rWide.ready }, 3000)
            rWide.item.sizeClass = "wide"; seed(rWide)
            rLarge.item.sizeClass = "large"; seed(rLarge)
            wait(32)
            compare(rLarge.item.rowH, rWide.item.rowH,
                    "the row height is the same at both sizes")
            verify(listOf(rLarge).height > listOf(rWide).height,
                   "…the taller box just shows more of them ("
                   + listOf(rLarge).height.toFixed(0) + " vs "
                   + listOf(rWide).height.toFixed(0) + "px of list)")
        }

        // wide - the summary moves BESIDE the list.
        function test_wide_puts_the_summary_beside_the_list() {
            tryVerify(function () { return rWide.ready }, 3000)
            var r = rWide.item
            r.sizeClass = "tall"
            seed(rWide)
            var outer = listOf(rWide).parent.parent
            compare(outer.columns, 1, "a tall box stacks")
            r.sizeClass = "wide"
            compare(r.horiz, true, "wide is the horizontal shape")
            compare(outer.columns, 2, "wide puts the summary beside the list")
            compare(r.showSummary, true, "…and the summary is shown")
            r.sizeClass = "tall"
        }

        // The summary is earned by room - and it still never scolds.
        function test_the_summary_is_earned_and_still_states_a_fact() {
            tryVerify(function () { return rLarge.ready }, 3000)
            var r = rLarge.item
            r.sizeClass = "large"
            seed(rLarge)
            r.toggle("Meds")
            compare(r.showSummary, true, "a large tile earns the summary bar")
            var texts = root.findAll(r, function (n) {
                return n.hasOwnProperty("text") && n.visible && String(n.text).length > 0
            }, []).map(function (n) { return String(n.text).toLowerCase() }).join(" | ")
            verify(texts.indexOf("1 of 5") >= 0, "it says where you are")
            var banned = ["missed", "failed", "behind", "streak", "overdue"]
            for (var i = 0; i < banned.length; i++)
                verify(texts.indexOf(banned[i]) < 0,
                       "the earned summary never says '" + banned[i] + "'")
        }

        function test_hidden_steps_are_disclosed_and_text_is_legible() {
            tryVerify(function () { return rWide.ready }, 3000)
            var r = rWide.item
            r.sizeClass = "wide"
            var lines = []
            for (var i = 0; i < 30; i++) lines.push("step " + i)
            rWide.storeCtl.setSetting(rWide.instanceId, "steps", lines.join("\n"))
            wait(32)
            verify(r.rowFont >= 17)
            var overflow = root.findAll(r, function(n) {
                return n.objectName === "routineOverflow"
            }, [])[0]
            verify(overflow !== null && overflow.visible)
            verify(overflow.Accessible.name.indexOf("more routine steps") >= 0)
        }

        function test_narrow_maximum_type_keeps_labels_and_state_complete() {
            tryVerify(function () { return rTall.ready }, 3000)
            rTall.theme.textScale = 1.45
            var r = rTall.item
            r.sizeClass = "tall"
            var lines = []
            for (var i = 1; i <= 7; i++)
                lines.push("Complete morning preparation step " + i)
            rTall.storeCtl.patchSettings(rTall.instanceId, {
                steps: lines.join("\n"),
                day: r.dayKey,
                done: [lines[0], lines[1]]
            })
            wait(32)
            verify(r.rowFont >= rTall.theme.fontMinimum,
                   "row labels follow the active minimum type token")
            var labels = root.findAll(r, function (n) {
                return String(n.objectName).indexOf("routineStepLabel-") === 0
            }, [])
            verify(labels.length >= 7, "all seven narrow rows are instantiated")
            for (var l = 0; l < labels.length; l++) {
                verify(labels[l].font.pixelSize >= rTall.theme.fontMinimum)
                compare(labels[l].truncated, false,
                        labels[l].text + " remains complete")
                verify(labels[l].lineCount <= r.rowLabelLines,
                       labels[l].text + " stays within the responsive row budget")
            }
            var checks = root.findAll(r, function (n) {
                return String(n.objectName).indexOf("routineStepCheck-") === 0
                       && n.visible
            }, [])
            compare(checks.length, 2, "two completed steps render two state marks")
            for (var c = 0; c < checks.length; c++)
                verify(checks[c].font.pixelSize >= rTall.theme.fontMinimum,
                       "completed-state marks meet the active type floor")
            var summary = root.findAll(r, function (n) {
                return n.objectName === "routineSummaryText"
            }, [])[0]
            verify(summary && summary.font.pixelSize >= rTall.theme.fontMinimum,
                   "summary text meets the active type floor")
            rTall.theme.textScale = 1.15
        }
    }
}
