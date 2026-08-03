import QtQuick
import QtTest
import "../../ui/qml" as App


// Comprehensive coverage for area "widget:hydration" - HydrationWidget.qml.
//
// Exercises every config knob (goal, glassMl), the daily reset / midnight
// projection, streak + goal-crossing maths, celebration replay, colour reward
// logic, clamping, reactivity to store.revision (Manager round-trip), and the
// hydration config schema. Some assertions intentionally encode the CORRECT
// behaviour and therefore FAIL on real bugs flagged in the widget audit
// (streak not credited when the goal is lowered; celebration replays on
// re-cross; the goal-reached colour is invisible with the default accent).
Item {
    id: root
    width: 640; height: 900

    WidgetHarness { id: h; anchors.fill: parent; widgetFile: "HydrationWidget.qml"; expanded: true }

    // Direct schema instance for the shared config-schema area.
    App.WidgetConfigSchema { id: schema }

    // Date helpers, mirroring the widget's yyyy-MM-dd keying.
    function dayKey(d) { return Qt.formatDate(d, "yyyy-MM-dd") }
    function daysAgoKey(n) { var d = new Date(); d.setDate(d.getDate() - n); return dayKey(d) }

    // ── Widget behaviour ─────────────────────────────────────────────────────
    TestCase {
        name: "HydrationWidget"
        when: windowShown

        function cfg() { return h.storeCtl.settingsFor("test-instance") }

        function init() {
            tryVerify(function () { return h.ready }, 3000)
            // Reset accent override + reduceMotion left over from prior tests.
            h.item.accentName = ""
            h.theme.reduceMotion = false
            // Clear all persisted settings for a clean slate.
            var s = cfg()
            for (var k in s) delete s[k]
            h.storeCtl._touchSettings()
        }

        // Convenience: seed a fresh "today, N glasses, goal G" starting state.
        function seed(count, goal) {
            var patch = { day: h.item.todayKey, count: count }
            if (goal !== undefined) patch.goal = goal
            h.storeCtl.patchSettings("test-instance", patch)
        }

        // - Defaults ----------------------------------------------------
        function test_defaults() {
            var w = h.item
            compare(w.goal, 8, "default goal 8")
            compare(w.glassMl, 250, "default glass size 250 ml")
            compare(w.count, 0, "no settings → 0 glasses today")
            compare(w.streakDisplay, 0, "no streak yet")
        }

        // - Config option: goal honoured + reactive ------------------------
        function test_goal_config_honored_and_reactive() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { goal: 12 })
            compare(w.goal, 12, "goal config applied")
            // Manager setUiState round-trip: bumping revision re-reads live.
            h.storeCtl.patchSettings("test-instance", { goal: 5 })
            compare(w.goal, 5, "goal re-applies live on revision bump")
        }

        // - Config option: glassMl honoured in volumeText --------------------
        function test_glassml_config_honored() {
            var w = h.item
            seed(6)
            h.storeCtl.patchSettings("test-instance", { glassMl: 300 })
            compare(w.glassMl, 300, "glassMl config applied")
            compare(w.volumeText(), "1.8 L", "6 × 300 ml → 1.8 L")
        }

        // - volumeText ml↔L boundary at 1000 ml --------------------------
        function test_volume_text_liter_boundary() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { glassMl: 250 })
            seed(3)
            compare(w.volumeText(), "750 ml", "750 ml stays ml (< 1000)")
            seed(4)
            compare(w.volumeText(), "1.0 L", "exactly 1000 ml switches to L")
            seed(6)
            compare(w.volumeText(), "1.5 L", "1500 ml → 1.5 L")
        }

        function test_glassml_reactive() {
            var w = h.item
            seed(4)
            h.storeCtl.patchSettings("test-instance", { glassMl: 500 })
            compare(w.volumeText(), "2.0 L", "glassMl change re-applies live")
        }

        function test_fluid_ounce_display() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { glassMl: 250, unit: "oz" })
            seed(2)
            compare(w.volumeText(), "16.9 fl oz")
        }

        function test_undo_restores_previous_count() {
            var w = h.item
            seed(2, 8)
            w.set(3); compare(w.count, 3); compare(cfg().previousCount, 2)
            w.undoLast(); compare(w.count, 2)
            compare(w.undoAvailable, false, "undo is consumed after one use")
            w.undoLast(); compare(w.count, 2,
                                  "a second press cannot toggle back to the newer count")
        }

        function test_manager_goal_edit_uses_the_goal_lifecycle() {
            var w = h.item
            seed(6, 8)
            compare(cfg().lastGoalDay, undefined)
            h.storeCtl.setSetting("test-instance", "goal", 5)
            tryCompare(cfg(), "lastGoalDay", w.todayKey, 1000)
            compare(cfg().streak, 1,
                    "a direct Manager setting edit credits the reached goal")
        }

        function test_motivation_can_be_disabled() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { celebrate: false, showStreak: false,
                goal: 2, day: w.todayKey, count: 1, streak: 3, lastGoalDay: w._yesterdayKey() })
            w.celebrateMsg = ""
            w.set(2)
            compare(w.celebrateMsg, "")
            compare(w.showStreak, false)
        }

        // - status string -------------------------------------------------
        function test_status_string() {
            var w = h.item
            seed(3, 8)
            compare(w.status, "3/8", "status is count/goal")
        }

        // - Clamping ----------------------------------------------------
        function test_count_clamped_0_to_50() {
            var w = h.item
            w.set(100)
            compare(w.count, 50, "count capped at 50")
            w.set(-5)
            compare(w.count, 0, "count floored at 0")
        }
        function test_goal_clamped_1_to_20() {
            var w = h.item
            w.setGoal(0)
            compare(w.goal, 1, "goal min 1")
            w.setGoal(99)
            compare(w.goal, 20, "goal max 20")
        }

        // - Increment / decrement via set() --------------------------------
        function test_increment_decrement() {
            var w = h.item
            seed(0, 8)
            w.set(w.count + 1); w.set(w.count + 1); w.set(w.count + 1)
            compare(w.count, 3)
            w.set(w.count - 1)
            compare(w.count, 2)
        }

        // - Daily reset: displayed count resets at midnight, stored stays ------
        function test_midnight_display_reset_keeps_stored() {
            var w = h.item
            // Yesterday's document: 5 glasses on the previous day key.
            h.storeCtl.patchSettings("test-instance", { day: daysAgoKey(1), count: 5, goal: 8 })
            compare(w.count, 0, "displayed count resets when stored day ≠ today")
            // Stored raw settings still hold yesterday's values (display-only reset).
            compare(cfg().count, 5, "stored count still 5 until next interaction")
            compare(cfg().day, daysAgoKey(1), "stored day still yesterday")
        }

        // - First tap after midnight writes today/1, not stored+1 ------------
        function test_first_tap_after_midnight() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { day: daysAgoKey(1), count: 5, goal: 8 })
            compare(w.count, 0, "starts projected at 0")
            w.set(w.count + 1)   // +1 glass tap
            compare(cfg().count, 1, "first glass writes count=1, not 6")
            compare(cfg().day, w.todayKey, "day rewritten to today")
            compare(w.count, 1)
        }

        // - Streak: fresh goal hit bumps to 1 + sets lastGoalDay ------------
        function test_fresh_goal_hit_bumps_streak() {
            var w = h.item
            seed(0, 8)
            w.set(8)
            compare(cfg().streak, 1, "fresh goal hit → streak 1")
            compare(cfg().lastGoalDay, w.todayKey, "lastGoalDay set to today")
            compare(w.streakDisplay, 1, "streakDisplay reflects it")
        }

        // - Streak: re-crossing same day does NOT double-increment ----------
        function test_recross_same_day_no_double_increment() {
            var w = h.item
            seed(0, 8)
            w.set(8)
            compare(cfg().streak, 1)
            w.set(7)   // drop below goal
            w.set(8)   // re-cross
            compare(cfg().streak, 1, "streak stays 1 on same-day re-cross")
        }

        // - Streak: consecutive-day (lastGoalDay===yesterday) increments ------
        function test_consecutive_day_increments_streak() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance",
                { day: w.todayKey, count: 0, goal: 8, streak: 3, lastGoalDay: w._yesterdayKey() })
            w.set(8)
            compare(cfg().streak, 4, "yesterday+today → streak 3→4")
            compare(cfg().lastGoalDay, w.todayKey)
        }

        // - Streak: a one-day gap resets to 1 ----------------------------
        function test_gap_resets_streak_to_1() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance",
                { day: w.todayKey, count: 0, goal: 8, streak: 5, lastGoalDay: daysAgoKey(2) })
            w.set(8)
            compare(cfg().streak, 1, "gap (2 days ago) resets streak to 1")
        }

        // - streakDisplay lapses to 0 when lastGoalDay is stale ------------
        function test_streak_display_lapses() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { streak: 9, lastGoalDay: daysAgoKey(3) })
            compare(w.streakDisplay, 0, "stale-high streak shows 0 when lapsed")
            // But raw stored streak is unchanged.
            compare(cfg().streak, 9, "stored streak untouched by the display projection")
        }
        function test_streak_display_valid_yesterday() {
            var w = h.item
            h.storeCtl.patchSettings("test-instance", { streak: 4, lastGoalDay: w._yesterdayKey() })
            compare(w.streakDisplay, 4, "yesterday counts as still-alive streak")
        }

        // - set(count) on the highest-filled glass is a no-op (dead tap) --------
        function test_tapping_highest_glass_is_noop() {
            var w = h.item
            seed(5, 8)
            w.set(5)   // tapping the 5th (index 4) glass → set(index+1)=set(5)
            compare(w.count, 5, "re-setting to the current count changes nothing")
        }

        // - Expanded glass grid: set(i+1) sets count to i+1 ----------------
        function test_glass_tap_sets_count() {
            var w = h.item
            seed(2, 8)
            w.set(3 + 1)   // tapping the 4th glass (index 3)
            compare(w.count, 4, "tapping glass index i sets count=i+1")
        }

        // - Overfill allowed past goal ------------------------------------
        function test_overfill_allowed() {
            var w = h.item
            seed(0, 8)
            w.set(12)
            compare(w.count, 12, "overfilling past goal is allowed (extra credit)")
        }

        // - accentName override recolours effAccent ------------------------
        function test_accent_name_override() {
            var w = h.item
            w.accentName = "purple"
            compare(String(w.effAccent).toLowerCase(),
                    String(h.theme.accentPresets["purple"].a).toLowerCase(),
                    "accentName override drives effAccent")
            w.accentName = ""
        }

        // - With an accent override, goal-reached colour is visibly different --
        function test_goal_color_change_visible_with_override() {
            var w = h.item
            w.accentName = "red"
            verify(String(w.effAccent) !== String(h.theme.success),
                   "below goal (effAccent) differs from at-goal (success) with a red accent")
            w.accentName = ""
        }

        // FIXED, and this test pins it (audit #4). The defect was: default
        // accent makes the goal-reached colour invisible. Correct behaviour is
        // that effAccent and success differ so the reward colour change is
        // perceptible. With the default accent they are the same byte value, so
        // this fails.
        function test_goal_color_change_visible_by_default() {
            var w = h.item
            verify(String(w.effAccent) !== String(h.theme.success),
                   "default accent must differ from success so hitting the goal recolours the count")
        }

        // FIXED, and this test pins it (audit line 49/58). The defect was:
        // lowering the goal below the current count should credit the streak /
        // mark the goal reached, but setGoal() only writes goal and never re-
        // evaluates attainment.
        function test_lowering_goal_credits_streak() {
            var w = h.item
            seed(6, 8)          // 6 glasses, goal 8 (not yet reached, no streak)
            compare(w.streakDisplay, 0, "precondition: no streak yet")
            w.setGoal(5)        // now 6 >= 5 - the goal is met by lowering it
            compare(w.count, 6, "count unchanged")
            compare(w.goal, 5, "goal lowered")
            compare(cfg().lastGoalDay, w.todayKey,
                    "meeting the goal by lowering it should credit lastGoalDay=today")
            compare(w.streakDisplay, 1, "and bump the streak")
        }

        // FIXED, and this test pins it (audit line 54). The defect was: re-
        // crossing the goal the same day replays the celebration. Correct
        // behaviour: the celebration should not re-fire (the streak is correctly
        // guarded, but the flash/label are not).
        function test_recross_does_not_replay_celebration() {
            var w = h.item
            seed(0, 8)
            w.set(8)                    // first cross → celebration fires
            w.celebrateMsg = ""         // clear so we can detect a re-fire
            w.set(7)                    // drop below goal (no celebrate)
            w.set(8)                    // re-cross same day
            compare(w.celebrateMsg, "", "re-crossing the goal should not replay the celebration")
        }

        // - reduceMotion path does not break goal crossing (smoke) ------------
        function test_reduce_motion_smoke() {
            var w = h.item
            h.theme.reduceMotion = true
            seed(0, 8)
            w.set(8)
            compare(cfg().streak, 1, "goal crossing still works with reduceMotion on")
            h.theme.reduceMotion = false
        }

        // - _yesterdayKey is exactly one calendar day before today -------------
        function test_yesterday_key() {
            var w = h.item
            compare(w._yesterdayKey(), daysAgoKey(1), "yesterday key = today − 1 day")
            verify(w._yesterdayKey() !== w.todayKey, "yesterday differs from today")
            // Well-formed yyyy-MM-dd.
            verify(/^\d{4}-\d{2}-\d{2}$/.test(w._yesterdayKey()), "yesterday key is yyyy-MM-dd")
        }

        // - resetSettings restores catalog defaults + clears streak/glassMl ----
        function test_reset_settings_restores_defaults() {
            var w = h.item
            // Dirty everything.
            h.storeCtl.patchSettings("test-instance",
                { goal: 15, count: 12, day: w.todayKey, glassMl: 500, streak: 7, lastGoalDay: w.todayKey })
            // Reset to the catalog defaults for hydration.
            h.storeCtl.resetSettings("test-instance", { goal: 8, count: 0, day: "" })
            compare(cfg().goal, 8, "goal reset to 8")
            compare(cfg().count, 0, "count reset to 0")
            compare(cfg().day, "", "day reset to empty")
            verify(cfg().streak === undefined, "stale streak dropped")
            verify(cfg().lastGoalDay === undefined, "stale lastGoalDay dropped")
            verify(cfg().glassMl === undefined, "stale glassMl dropped")
            compare(w.goal, 8, "widget reflects reset goal")
            compare(w.glassMl, 250, "glassMl falls back to default 250")
            compare(w.count, 0, "widget reflects reset count (day empty → 0)")
            compare(w.streakDisplay, 0, "streak display cleared")
        }
    }

    // ── Hydration config schema (shared config area, instantiated directly) ────
    TestCase {
        name: "HydrationSchema"
        when: windowShown

        function test_hydration_schema_fields() {
            var s = schema.schemaFor("hydration")
            verify(s && s.sections && s.sections.length > 0, "hydration has sections")
            var goal = null, glassMl = null
            for (var i = 0; i < s.sections.length; i++)
                for (var j = 0; j < (s.sections[i].fields || []).length; j++) {
                    var f = s.sections[i].fields[j]
                    if (f.key === "goal") goal = f
                    if (f.key === "glassMl") glassMl = f
                }
            verify(goal !== null, "schema exposes a goal field")
            compare(goal.type, "number", "goal is a number field")
            compare(goal.min, 1, "goal min 1 matches setGoal clamp")
            compare(goal.max, 20, "goal max 20 matches setGoal clamp")
            compare(goal.dflt, 8, "goal default 8 matches widget default")

            verify(glassMl !== null, "schema exposes a glassMl field")
            compare(glassMl.type, "number", "glassMl is a number field")
            compare(glassMl.dflt, 250, "glassMl default 250 matches widget default")
        }
    }

    // ── Per-sizeClass structure (W1 wave 2b) ────────────────────────────────
    // Fixed-size hosts at the real projected cell footprints.
    Item { width: 348; height: 409
        WidgetHarness { id: yMicro; anchors.fill: parent; widgetFile: "HydrationWidget.qml"; expanded: false } }
    Item { width: 696; height: 819
        WidgetHarness { id: yBase; anchors.fill: parent; widgetFile: "HydrationWidget.qml"; expanded: false } }
    Item { id: yWideWrap; width: 696; height: 409
        WidgetHarness { id: yWide; anchors.fill: parent; widgetFile: "HydrationWidget.qml"; expanded: false } }
    Item { width: 278; height: 654
        WidgetHarness { id: yTightTall; anchors.fill: parent; widgetFile: "HydrationWidget.qml"; expanded: false } }
    Item { width: 557; height: 327
        WidgetHarness { id: yTightWide; anchors.fill: parent; widgetFile: "HydrationWidget.qml"; expanded: false } }
    Item { width: 557; height: 654
        WidgetHarness { id: yTightBase; anchors.fill: parent; widgetFile: "HydrationWidget.qml"; expanded: false } }
    Item { width: 677; height: 490
        WidgetHarness { id: yTightLandscape; anchors.fill: parent; widgetFile: "HydrationWidget.qml"; expanded: false } }

    // The OVERLAY, at the two boxes Dashboard actually gives it. `expanded: true`
    // AND sizeClass "full" - the real pairing - because a mode-keyed literal can
    // only be caught with the mode switched ON. These are the live-preview pane
    // beside the config form (Dashboard: 38% of the width in landscape, a <=46%-
    // tall band stacked in portrait), NOT a 2560x720 screen.
    Item { width: 941; height: 456
        WidgetHarness { id: yOvlL; anchors.fill: parent; widgetFile: "HydrationWidget.qml"; expanded: true } }
    Item { width: 656; height: 980
        WidgetHarness { id: yOvlP; anchors.fill: parent; widgetFile: "HydrationWidget.qml"; expanded: true } }
    // A dedicated host for the glassPx dead-branch probe, so a failure there
    // cannot leak `expanded: true` into another test's host. Same box as yBase.
    Item { width: 696; height: 819
        WidgetHarness { id: yProbe; anchors.fill: parent; widgetFile: "HydrationWidget.qml"; expanded: false } }

    // ── Overlay-fit hosts ───────────────────────────────────────────────────
    // The overlay column must FIT the pane it is given - count clipping off the
    // top and the goal controls off the bottom (unreachable) was the bug. These
    // are the real boxes Dashboard hosts the overlay in: the 456-tall landscape
    // preview pane, the 2560x720 real device, and the 656x980 portrait pane. Each
    // is a fresh host so a goal/count seeded here cannot leak into another test.
    Item { id: fLandWrap; width: 941; height: 456
        WidgetHarness { id: fLand; anchors.fill: parent; widgetFile: "HydrationWidget.qml"; expanded: true } }
    Item { id: fDevWrap; width: 2560; height: 720
        WidgetHarness { id: fDev; anchors.fill: parent; widgetFile: "HydrationWidget.qml"; expanded: true } }
    Item { id: fPortWrap; width: 656; height: 980
        WidgetHarness { id: fPort; anchors.fill: parent; widgetFile: "HydrationWidget.qml"; expanded: true } }

    TestCase {
        name: "HydrationSizes"
        when: windowShown

        function seed(host) {
            host.storeCtl.patchSettings(host.instanceId,
                { goal: 8, count: 3, day: Qt.formatDate(new Date(), "yyyy-MM-dd") })
        }
        function findAll(node, pred, acc) {
            if (!node) return acc
            if (pred(node)) acc.push(node)
            var kids = node.children
            for (var i = 0; kids && i < kids.length; i++) findAll(kids[i], pred, acc)
            return acc
        }
        // Every PillButton holds exactly one MouseArea; the button is its parent.
        function pills(host) {
            return findAll(host.item, function (n) {
                return n.hasOwnProperty("label") && n.hasOwnProperty("glyph")
                       && n.hasOwnProperty("primary") && n.visible
            }, [])
        }

        // 0.5x0.5 - the count, and the one tap that matters. Nothing else.
        function test_micro_is_count_plus_one_tap() {
            tryVerify(function () { return yMicro.ready }, 3000)
            var y = yMicro.item
            y.sizeClass = "compact"
            seed(yMicro)
            compare(y.micro, true, "a 348x409 compact box is the micro tile")
            compare(y.showHeader, false, "micro drops the chrome header")
            compare(y.showGrid, false, "micro drops the glass grid - 8 droplets there are mush")
            compare(y.showStreak, false, "…and the streak line")
            verify(y.countPx >= 20, "the count is a readout, not a caption ("
                   + y.countPx.toFixed(0) + "px)")
            // The one-tap serving action survives, at a real touch size.
            var p = pills(yMicro)
            compare(p.length, 1, "micro keeps exactly one serving control")
            compare(p[0].label, "+ 250 ml", "the action states the configured serving")
            compare(p[0].glyphIcon, "hydration", "the action uses the bundled hydration icon")
            verify(p[0].height >= yMicro.theme.touchTertiary,
                   "the add action is >= touchTertiary (" + p[0].height + " >= "
                   + yMicro.theme.touchTertiary + ") - never shrunk to fit")
        }

        // 1x1 - the grid comes back and scales to the box.
        function test_baseline_earns_the_grid() {
            tryVerify(function () { return yBase.ready }, 3000)
            tryVerify(function () { return yMicro.ready }, 3000)
            yMicro.item.sizeClass = "compact"; seed(yMicro)
            var y = yBase.item
            y.sizeClass = "compact"
            seed(yBase)
            compare(y.micro, false, "a 696x819 baseline tile is not micro")
            compare(y.showGrid, true, "the baseline earns the glass grid")
            verify(y.glassPx > 16, "the droplets scale to the box, past the old fixed 16px ("
                   + y.glassPx.toFixed(0) + ")")
            var icons = findAll(y, function (n) {
                return n.objectName === "hydrationGlassIcon" && n.visible
            }, [])
            compare(icons.length, 3, "logged servings use three bundled hydration icons")
            var emoji = findAll(y, function (n) {
                return n.hasOwnProperty("text")
                    && ["💧", "🎉", "💪", "🔥"].indexOf(String(n.text)) >= 0
            }, [])
            compare(emoji.length, 0, "no functional state or action depends on emoji rendering")
            // Both controls, both real targets.
            var p = pills(yBase)
            compare(p.length, 2, "the baseline carries Undo and the serving action")
            for (var i = 0; i < p.length; i++)
                verify(p[i].height >= yBase.theme.touchTertiary,
                       p[i].label + " is >= touchTertiary (" + p[i].height + ")")
        }

        function test_baseline_uses_its_room_for_volume_and_remaining_context() {
            tryVerify(function () { return yBase.ready }, 3000)
            var y = yBase.item
            y.sizeClass = "compact"
            seed(yBase)
            wait(32)
            compare(y.showDetails, true, "the 1x1 card earns hydration context")
            compare(y.volumeText(), "750 ml")
            compare(y.servingText(), "250 ml")
            compare(y.remainingText(), "1.3 L")
            var details = findAll(y, function (n) {
                return n.objectName === "hydrationDetails" && n.visible
            }, [])
            compare(details.length, 1, "today, serving, and remaining volume are rendered")
            var serving = findAll(y, function (n) {
                return n.objectName === "hydrationServing" && n.visible
            }, [])
            compare(serving.length, 1, "serving size remains visible outside the detail card")
            compare(serving[0].text, "250 ml per glass")

            var micro = yMicro.item
            micro.sizeClass = "compact"
            seed(yMicro)
            wait(16)
            compare(micro.showDetails, false, "the micro card keeps only the count and action")
        }

        // wide - the grid moves BESIDE the count/controls; same delegates.
        function test_wide_puts_the_grid_beside_the_controls() {
            tryVerify(function () { return yWide.ready }, 3000)
            var y = yWide.item
            y.sizeClass = "compact"
            seed(yWide)
            var grid = gridOf(yWide)
            compare(grid.columns, 1, "a stacked box is one column")
            var dropBefore = findAll(y, function (n) {
                return n.objectName === "hydrationGlass-0" }, [])[0]
            y.sizeClass = "wide"
            compare(y.horiz, true, "wide is the horizontal shape")
            compare(grid.columns, 2, "wide flows the grid beside the controls")
            var dropAfter = findAll(y, function (n) {
                return n.objectName === "hydrationGlass-0" }, [])[0]
            verify(dropAfter === dropBefore,
                   "the same droplet object survives the class flip (no rebuild)")
            y.sizeClass = "compact"
        }

        function test_constrained_tiles_keep_grid_and_actions_inside_the_body() {
            tryVerify(function () {
                return yTightTall.ready && yTightWide.ready
                       && yTightBase.ready && yTightLandscape.ready
            }, 3000)
            var cases = [
                { host: yTightTall, cls: "tall", scale: 1.45 },
                { host: yTightWide, cls: "wide", scale: 1.45 },
                { host: yTightBase, cls: "compact", scale: 1.45 },
                { host: yTightLandscape, cls: "compact", scale: 1.3 }
            ]
            for (var c = 0; c < cases.length; c++) {
                var host = cases[c].host
                host.theme.textScale = cases[c].scale
                host.storeCtl.patchSettings(host.instanceId, {
                    goal: 50,
                    count: 0,
                    glassMl: 1250,
                    day: Qt.formatDate(new Date(), "yyyy-MM-dd")
                })
                var widget = host.item
                widget.sizeClass = cases[c].cls
                wait(32)
                compare(widget.goal, 20,
                        "external goals use the same maximum as the UI")
                compare(widget.glassMl, 1000,
                        "external serving sizes use the same maximum as the UI")

                var tile = findAll(widget, function (n) {
                    return n.objectName === "hydrationTileLayout"
                }, [])[0]
                var grid = findAll(widget, function (n) {
                    return n.objectName === "hydrationGlassGrid"
                }, [])[0]
                var actions = findAll(widget, function (n) {
                    return n.objectName === "hydrationTileActions"
                }, [])[0]
                verify(tile && grid && actions, "responsive tile sections resolve")
                var body = tile.parent
                var sections = [tile, grid, actions]
                for (var s = 0; s < sections.length; s++) {
                    var section = sections[s]
                    var point = section.mapToItem(body, 0, 0)
                    verify(point.x >= -1 && point.y >= -1
                           && point.x + section.width <= body.width + 1
                           && point.y + section.height <= body.height + 1,
                           section.objectName + " stays inside " + cases[c].cls
                           + " body at text scale " + cases[c].scale)
                }
                verify(grid.width <= widget.tileColumnWidth + 1,
                       "glass grid respects its actual layout column")
                var controls = pills(host)
                for (var p = 0; p < controls.length; p++) {
                    var controlPoint = controls[p].mapToItem(body, 0, 0)
                    verify(controlPoint.x >= -1 && controlPoint.y >= -1
                           && controlPoint.x + controls[p].width <= body.width + 1
                           && controlPoint.y + controls[p].height <= body.height + 1,
                           controls[p].label + " remains visible and reachable")
                    verify(controls[p].height >= host.theme.touchTertiary,
                           controls[p].label + " retains its touch-target floor")
                }
                host.theme.textScale = 1.15
            }
        }

        // ── size, not mode ──────────────────────────────────────────────────
        function banner(host) {
            return findAll(host.item, function (n) {
                return n.hasOwnProperty("maximumLineCount") && n.maximumLineCount === 2
                       && n.hasOwnProperty("font") }, [])[0] || null
        }

        // The overlay is a size class like any other, sized by the pane it is
        // actually given. Both hosts are expanded AND "full"; only the BOX
        // differs, so a literal returning one number for both is caught. This is
        // the ONLY shape that catches a mode-keyed literal - a test that holds the
        // mode at false never fires the literal branch at all.
        function test_overlay_banner_is_sized_by_its_pane_not_by_a_mode_literal() {
            tryVerify(function () { return yOvlL.ready && yOvlP.ready }, 3000)
            var land = yOvlL.item; land.sizeClass = "full"
            var port = yOvlP.item; port.sizeClass = "full"
            seed(yOvlL); seed(yOvlP)
            // A real event-loop turn, not wait(0): these hosts default to
            // sizeClass "tall" and only become "full" on the lines above, so
            // wait(0) reads PRE-change geometry. waitForRendering is wrong
            // offscreen - no frame is ever swapped, so it just burns its timeout.
            wait(16)
            compare(land.expanded, true, "precondition: this IS the overlay")
            compare(port.expanded, true, "…and so is this one")

            var lb = banner(yOvlL), pb = banner(yOvlP)
            verify(lb && pb, "both banners resolve")
            // The RENDERED Text's own font.pixelSize, not w.celebratePx: checking
            // the property only proves the arithmetic, and a Text that ignored it
            // and re-froze a literal would pass that untouched.
            compare(lb.font.pixelSize, Math.round(land.celebratePx),
                    "the landscape pane's banner uses the derived size")
            compare(pb.font.pixelSize, Math.round(port.celebratePx),
                    "…and the portrait pane's does too")
            verify(lb.font.pixelSize !== pb.font.pixelSize,
                   "the overlay's banner is sized by the pane it is given, not by one "
                   + "literal for 'the overlay' (941x456 -> " + lb.font.pixelSize
                   + ", 656x980 -> " + pb.font.pixelSize + ")")
            // Direction, not just difference: the 456-tall landscape pane is the
            // SHORT one, and the banner wraps to 2 lines, so height must hold it
            // back there. A scrambled binding cannot pass this.
            verify(pb.font.pixelSize > lb.font.pixelSize,
                   "the 980-tall pane earns the bigger pop (" + pb.font.pixelSize
                   + " > " + lb.font.pixelSize + ")")
        }

        // The banner is sized by the CARD, at tile classes too.
        function test_celebration_banner_is_sized_by_the_card_not_the_mode() {
            tryVerify(function () { return yBase.ready && yMicro.ready }, 3000)
            var base = yBase.item;   base.sizeClass = "compact"   // 696x819
            var micro = yMicro.item; micro.sizeClass = "compact"  // 348x409
            seed(yBase); seed(yMicro)
            wait(16)
            compare(base.expanded, false, "precondition: neither host is the overlay")
            compare(micro.expanded, false, "…including the roomier one")
            var bb = banner(yBase), mb = banner(yMicro)
            verify(bb && mb, "both banners resolve")
            compare(bb.font.pixelSize, Math.round(base.celebratePx),
                    "the rendered banner uses the derived size on a 1x1 tile")
            compare(mb.font.pixelSize, Math.round(micro.celebratePx),
                    "…and on a micro tile")
            verify(bb.font.pixelSize > mb.font.pixelSize,
                   "a 696x819 tile pops bigger than a 348x409 one - the banner reads "
                   + "the card, not the mode (" + bb.font.pixelSize + " vs "
                   + mb.font.pixelSize + ")")
        }

        // The banner had NO width, no wrapMode and no elide, so a message longer
        // than the card had nowhere to go and spilled out of both edges.
        // Structural: bounded by the card, wrapped to at most 2 lines. Never glyph
        // ink - paintedWidth is meaningless headless.
        function test_a_long_celebration_stays_inside_the_card() {
            tryVerify(function () { return yBase.ready }, 3000)
            var y = yBase.item; y.sizeClass = "compact"
            seed(yBase)
            wait(16)
            var b = banner(yBase)
            verify(b !== null, "the banner resolves")
            // Deliberately FAR longer than could conceivably fit: ~330 characters
            // into two ~660px lines is ~4px per glyph at a ~40px font. No font
            // makes that fit, so `lineCount`/`truncated` below are structural here
            // rather than a claim about DejaVu's metrics - the margin, not the
            // measurement, is what keeps them font-independent.
            y.celebrateMsg = "🎉 Das tägliche Trinkziel ist erreicht - hervorragend "
                           + "gemacht, und das schon den dritten Tag in Folge, was "
                           + "wirklich bemerkenswert ist, wenn man bedenkt wie oft "
                           + "das Glas Wasser sonst einfach vergessen wird, und "
                           + "deshalb gibt es hier einen ausführlichen Glückwunsch "
                           + "in voller Länge, damit auch niemand ihn übersieht!"
            wait(16)
            verify(b.width <= y.width + 0.51,
                   "the banner stays inside the card (" + b.width.toFixed(1)
                   + " in " + y.width + ") - it had no width at all and simply spilled")
            compare(b.lineCount, 2,
                    "…it WRAPS (so wrapMode is live) and stops at 2 lines")
            verify(b.truncated,
                   "…and elides the remainder instead of running past the card")
            y.celebrateMsg = ""
        }

        // `glassPx` opened with `w.expanded ? 42`, which never rendered: glassPx
        // feeds only the tile Grid (and its cell/column arithmetic), and that
        // layout is `visible: !w.expanded`. Two halves - the deadness, then the
        // removal - because either alone proves little.
        //
        // NOTE: unlike every other guard here this one asserts the PROPERTY, and
        // it has to: the branch's whole defect is that it has no rendered value in
        // the overlay to assert. The first half pins exactly that.
        function test_glass_size_never_read_the_mode() {
            tryVerify(function () { return yProbe.ready && yOvlP.ready }, 3000)
            var ovl = yOvlP.item; ovl.sizeClass = "full"
            seed(yOvlP)
            wait(16)
            // Half one: glassPx's only consumer is invisible in the overlay, so
            // the 42 it used to return could never have been drawn.
            var tileGrid = gridOf(yOvlP)
            verify(tileGrid !== null, "the tile layout resolves in the overlay")
            compare(tileGrid.visible, false,
                    "the tile layout - glassPx's ONLY consumer - is not drawn in the "
                    + "overlay, so `expanded ? 42` was dead, not merely mode-keyed")

            // Half two, and the half that bites: same box, opposite modes. A
            // surviving `expanded ? 42` returns 42 for one and the derived size
            // for the other.
            var probe = yProbe.item; probe.sizeClass = "compact"
            var base = yBase.item;   base.sizeClass = "compact"
            seed(yProbe); seed(yBase)
            yProbe.expanded = true
            wait(16)
            compare(probe.expanded, true, "precondition: the mode is ON")
            compare(base.expanded, false, "…and OFF on an identically-sized host")
            compare(probe.width, base.width, "precondition: the two boxes match")
            compare(probe.height, base.height, "…on both axes")
            compare(probe.glassPx, base.glassPx,
                    "the droplet size is decided by the box alone - flipping the mode "
                    + "on an identical box moves nothing (" + probe.glassPx.toFixed(1)
                    + " vs " + base.glassPx.toFixed(1) + ")")
        }

        // The content GridLayout: the glass Grid's parent.
        function gridOf(host) {
            var g = findAll(host.item, function (n) {
                return n.hasOwnProperty("horizontalItemAlignment")
                       && n.hasOwnProperty("columns") }, [])[0]
            return g ? g.parent : null
        }
    }

    // ── The overlay's hero actions ──────────────────────────────────────────
    // Remove / Add a glass are deliberately far wider than their text - this is
    // the full-screen view of a one-tap widget. That was written as
    // `implicitWidth: 170` / `240`, i.e. as the BOX rather than as a MINIMUM, so
    // the pill could never grow past it and a longer label would elide inside a
    // button with no reason to be narrow. They are floors now; these assertions
    // pin down BOTH halves of that, because the generosity alone is equally true
    // of the literal it replaced.
    TestCase {
        name: "HydrationOverlayActions"
        when: windowShown

        function initTestCase() { tryVerify(function () { return h.ready }, 3000) }
        function init() { h.theme.textScale = 1.0; settle() }
        // Restore in cleanup(), not inline at the end of the test: a failing
        // verify() aborts the function on the spot, so an inline restore is
        // skipped exactly when it is needed and the relabelled pill leaks into
        // the next test as a second, bogus failure. cleanup() always runs.
        function cleanup() {
            h.theme.textScale = 1.0
            var p = findAll(h.item, function (n) {
                return n.hasOwnProperty("minWidth") && n.hasOwnProperty("glyph")
                       && n.visible && n.minWidth === 170
            }, [])[0]
            if (p) p.label = "Remove " + h.item.servingText()
            settle()
        }
        // A real event-loop turn: a textScale change re-polishes the layout, and
        // wait(0) returns before the new geometry lands. waitForRendering is the
        // wrong tool offscreen - no frame is ever swapped, so it just burns its
        // timeout.
        function settle() { wait(16) }

        function findAll(node, pred, acc) {
            if (!node) return acc
            if (pred(node)) acc.push(node)
            var kids = node.children
            for (var i = 0; kids && i < kids.length; i++) findAll(kids[i], pred, acc)
            return acc
        }
        // The VISIBLE pill carrying a given label - the tile layout's own pills
        // exist alongside these but are hidden while expanded.
        function pillNamed(label) {
            return findAll(h.item, function (n) {
                return n.hasOwnProperty("minWidth") && n.hasOwnProperty("glyph")
                       && n.visible && String(n.label) === label
            }, [])[0] || null
        }
        function labelRun(p) {
            return findAll(p, function (n) {
                return n.hasOwnProperty("elide") && n.hasOwnProperty("baselineOffset")
                       && String(n.text) === String(p.label)
            }, [])[0] || null
        }

        // Half one: the generosity is intact - the pills are still much larger
        // than their text at every reachable text size.
        function test_hero_actions_keep_their_generous_floor() {
            var cases = [ { l: "Remove " + h.item.servingText(), w: 170 },
                          { l: "Add " + h.item.servingText(), w: 240 } ]
            var scales = [0.8, 1.0, 1.3, 1.6]
            for (var s = 0; s < scales.length; s++) {
                h.theme.textScale = scales[s]
                settle()
                for (var i = 0; i < cases.length; i++) {
                    var p = pillNamed(cases[i].l)
                    verify(p !== null, cases[i].l + " is present in the overlay")
                    compare(p.minWidth, cases[i].w,
                            cases[i].l + " declares its designed floor")
                    // The RENDERED width, not the implicit hint behind it.
                    verify(p.width >= cases[i].w,
                           cases[i].l + " renders at least its floor at textScale "
                           + scales[s] + " (w=" + p.width.toFixed(1) + ")")
                }
            }
        }

        // Half two, and the half that actually distinguishes the fix: a floor
        // YIELDS to bigger content; `implicitWidth: 170` cannot. The reachable
        // textScale range can never show this - at 1.6 "Remove" wants ~141px and
        // "Add a glass" ~193px, both still under their floors, which is exactly
        // why the literal survived this long. Give the pill a genuinely longer
        // label (what a translation or a relabel does) and the difference is the
        // whole widget.
        function test_hero_actions_grow_for_a_longer_label_instead_of_eliding() {
            h.theme.textScale = 1.6
            settle()
            var p = pillNamed("Remove " + h.item.servingText())
            verify(p !== null, "precondition: the Remove pill")
            // Deliberately NOT "p.width <= minWidth" - that would assert that
            // "Remove" measures under 170px, which is a claim about the font. It
            // holds locally (~141px at textScale 1.6) and almost certainly on CI's
            // DejaVu, but it is exactly the kind of assertion that means two
            // different things on the two machines. The floor holding is
            // font-independent and is all this precondition needs to establish.
            verify(p.width >= p.minWidth,
                   "precondition: the floor is intact at the pill's own label (w="
                   + p.width.toFixed(1) + " floor=" + p.minWidth + ")")

            // A label no reachable textScale can produce from "Remove".
            p.label = "Ein Glas Wasser entfernen"
            settle()
            var row = p.children[0]
            verify(row.implicitWidth + 2 * p._padH > p.minWidth,
                   "precondition: the longer label genuinely outgrows the floor ("
                   + (row.implicitWidth + 2 * p._padH).toFixed(1) + " > " + p.minWidth + ")")
            verify(p.width >= row.implicitWidth + 2 * p._padH - 0.51,
                   "the pill GROWS past its floor to hold the label - the floor is a "
                   + "minimum, not the box (w=" + p.width.toFixed(1) + " content+pad="
                   + (row.implicitWidth + 2 * p._padH).toFixed(1) + ")")
            var lr = labelRun(p)
            verify(lr !== null, "the label run resolves")
            verify(lr.width >= lr.implicitWidth - 0.51,
                   "…so the label renders in full rather than eliding inside a "
                   + "button pinned narrower than its own text (" + lr.width.toFixed(1)
                   + " vs " + lr.implicitWidth.toFixed(1) + ")")
            // (the label is restored by cleanup(), which runs even on failure)
        }
    }

    // ── The overlay column FITS its pane ────────────────────────────────────
    // The bug: the expanded ColumnLayout was built from literals (110px count,
    // 88px glass cells, spacingXl between ~6 rows) sized for a tall screen that
    // does not exist. At goal 8 it summed to ~612px and at goal 20 to ~812px, so
    // inside the 456-tall landscape preview pane the count clipped off the TOP
    // and the "Daily goal −N+" controls - the overlay's whole point - clipped off
    // the BOTTOM, unreachable, at any goal past ~12. This guard maps the overlay
    // column's top and bottom into the host box and asserts the STRUCTURAL fit
    // (top >= 0, bottom <= boxH, small tolerance) - never glyph ink, which is
    // meaningless headless. It is proved to go RED when the old literals are
    // restored (the column then spills the 456 and 720 landscape boxes).
    TestCase {
        name: "HydrationOverlayFit"
        when: windowShown

        function findAll(node, pred, acc) {
            if (!node) return acc
            if (pred(node)) acc.push(node)
            var kids = node.children
            for (var i = 0; kids && i < kids.length; i++) findAll(kids[i], pred, acc)
            return acc
        }
        // The overlay column is the PARENT of the big "N / N" count Text - the one
        // Text in the tree whose content carries a slash at a hero size. (The tile
        // has a "N of N glasses" line with no slash; micro's "N/N" lives in the
        // hidden, non-micro tile here.) Anchoring on the count and taking .parent
        // is exactly how the bug was measured.
        function overlayColumn(host) {
            var best = null
            var counts = findAll(host.item, function (n) {
                return n.hasOwnProperty("font") && n.font.pixelSize >= 40
                       && String(n.text).indexOf("/") >= 0 }, [])
            for (var i = 0; i < counts.length; i++)
                if (!best || counts[i].font.pixelSize > best.font.pixelSize) best = counts[i]
            return best ? best.parent : null
        }

        // Assert the column fits `box` (the wrapping Item) at the given goal/count.
        // Returns the measured [top, bottom, colH] so the caller can log them.
        function assertFits(host, box, goal, count, label) {
            // The real Dashboard overlay sets showHeader=false (Dashboard.qml) and
            // sizeClass "full"; reproduce BOTH so the column has the room it truly
            // has on device, not a phantom header the harness would otherwise draw.
            host.item.sizeClass = "full"
            host.item.showHeader = false
            host.storeCtl.patchSettings(host.instanceId,
                { goal: goal, count: count, day: Qt.formatDate(new Date(), "yyyy-MM-dd") })
            // A real event-loop turn: these hosts default to sizeClass "tall" and
            // only become "full"/headerless on the lines above, and the seed bumps
            // the store revision. wait(0) reads PRE-change geometry; waitForRendering
            // is wrong offscreen (no frame is ever swapped, so it burns its timeout).
            wait(16)
            var col = overlayColumn(host)
            verify(col !== null, label + ": the overlay column resolves")
            var top = col.mapToItem(box, 0, 0).y
            var bot = top + col.height
            // A small tolerance for sub-pixel layout rounding; the real spills the
            // literals produce are tens of pixels (top −53, −153; bottom +135),
            // far past any 1px slack, so the tolerance cannot mask the bug.
            var tol = 1.0
            verify(top >= -tol,
                   label + ": the count does not clip off the TOP (top=" + top.toFixed(1)
                   + " >= 0, colH=" + col.height.toFixed(0) + " in " + box.height + ")")
            verify(bot <= box.height + tol,
                   label + ": the goal controls do not clip off the BOTTOM (bot="
                   + bot.toFixed(1) + " <= " + box.height + ", colH=" + col.height.toFixed(0) + ")")
        }

        // Goal 8 AND goal 20 (the widget lets the user raise the goal to 20), in a
        // landscape pane AND the real landscape device AND a portrait pane. The
        // landscape boxes are what the literals overran; portrait is asserted so a
        // fix that only shrank landscape and broke portrait would be caught too.
        function test_overlay_column_fits_landscape_preview_pane() {
            tryVerify(function () { return fLand.ready }, 3000)
            compare(fLand.item.expanded, true, "precondition: this IS the overlay")
            assertFits(fLand, fLandWrap, 8, 8, "941x456 g8")
            assertFits(fLand, fLandWrap, 20, 20, "941x456 g20")
        }
        function test_overlay_column_fits_real_device_landscape() {
            tryVerify(function () { return fDev.ready }, 3000)
            compare(fDev.item.expanded, true, "precondition: this IS the overlay")
            assertFits(fDev, fDevWrap, 8, 8, "2560x720 g8")
            assertFits(fDev, fDevWrap, 20, 20, "2560x720 g20")
        }
        function test_overlay_column_fits_portrait_pane() {
            tryVerify(function () { return fPort.ready }, 3000)
            compare(fPort.item.expanded, true, "precondition: this IS the overlay")
            assertFits(fPort, fPortWrap, 8, 8, "656x980 g8")
            assertFits(fPort, fPortWrap, 20, 20, "656x980 g20")
        }
    }
}
