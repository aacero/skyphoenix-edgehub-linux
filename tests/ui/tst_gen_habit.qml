import QtQuick
import QtTest


// ─────────────────────────────────────────────────────────────────────────
// Comprehensive coverage for the Habit streak widget
// (ui/qml/widgets/HabitWidget.qml).
//
// Exercises: streak maths (grace day, gaps, DST-spanning consecutive runs),
// the 28-day heatmap mapping, check-in toggling, milestone celebration
// (including the "re-check re-fires" bug), pluralisation, best-streak
// persistence, checkins-array growth, reactivity through store.revision,
// per-instance accent, custom name / title override, compact-tile layout,
// and the store==null no-op path.
//
// Several assertions encode behaviour an earlier audit flagged as broken. Every
// one of those defects has since been fixed (verified 2026-08-03); the
// assertions remain as the regression guards that keep them fixed.
// ─────────────────────────────────────────────────────────────────────────
Item {
    id: root
    width: 480; height: 900

    // Non-overlapping layout so mouseClick() hit-testing reaches each harness's
    // own widget (a topmost sibling at the same origin would swallow the click).
    WidgetHarness { id: hHabit;   anchors.fill: parent; widgetFile: "HabitWidget.qml"; expanded: true }
    // A 1x1-sized compact tile to reproduce the clipped check-in button.
    WidgetHarness { id: hCompact; x: 280; y: 0;   width: 150; height: 150; widgetFile: "HabitWidget.qml"; expanded: false }
    // A widget whose store is forcibly nulled to test the guard path.
    WidgetHarness { id: hNull;    x: 280; y: 200; width: 200; height: 200; widgetFile: "HabitWidget.qml"; expanded: false }

    // Recursively collect nodes matching a predicate.
    function findAll(node, pred, acc) {
        if (!node) return acc
        if (pred(node)) acc.push(node)
        var kids = node.children
        for (var i = 0; kids && i < kids.length; i++) findAll(kids[i], pred, acc)
        return acc
    }
    function findPill(item) {
        return findAll(item, function (n) {
            return n.hasOwnProperty("label") && n.hasOwnProperty("primary") && n.hasOwnProperty("glyph")
        }, [])[0] || null
    }
    function findCells(item) {
        return findAll(item, function (n) {
            return n.hasOwnProperty("dk") && n.hasOwnProperty("on")
        }, [])
    }

    // A run of `count` calendar-consecutive local dates ending `endOffset` days
    // before today. Built with setDate() (true calendar stepping) so the TEST
    // DATA is DST-correct even where the widget's fixed-ms stepping is not.
    function consecutiveDays(w, count, endOffset) {
        var arr = []
        var d = new Date(); d.setHours(12, 0, 0, 0); d.setDate(d.getDate() - (endOffset || 0))
        for (var i = 0; i < count; i++) { arr.push(w.key(d)); d.setDate(d.getDate() - 1) }
        return arr
    }
    function clearSettings(h) {
        var s = h.storeCtl.settingsFor("test-instance")
        for (var k in s) delete s[k]
        h.storeCtl._touchSettings()
    }
    function occurrences(arr, val) {
        var n = 0
        for (var i = 0; i < arr.length; i++) if (arr[i] === val) n++
        return n
    }

    // ── Core streak + check-in logic ───────────────────────────────────────
    TestCase {
        name: "HabitCore"
        when: windowShown
        function init() {
            tryVerify(function () { return hHabit.ready }, 3000)
            clearSettings(hHabit)
        }
        function cfg() { return hHabit.storeCtl.settingsFor("test-instance") }

        function test_streak_of_basics() {
            var w = hHabit.item
            compare(w.streakOf([]), 0, "empty list → 0")
            var today = w.key(new Date())
            var yest = w.key(new Date(Date.now() - 86400000))
            var three = w.key(new Date(Date.now() - 3 * 86400000))
            compare(w.streakOf([today]), 1, "today only → 1")
            compare(w.streakOf([today, yest]), 2, "today+yesterday → 2")
            compare(w.streakOf([today, three]), 1, "a gap breaks the streak")
        }

        function test_grace_day_counts_run_ending_yesterday() {
            var w = hHabit.item
            // Two consecutive days ending yesterday; today NOT checked in.
            hHabit.storeCtl.patchSettings("test-instance", { checkins: consecutiveDays(w, 2, 1) })
            compare(w.doneToday, false, "today is not checked")
            compare(w.streak, 2, "grace day: a run ending yesterday still counts")
        }
        function test_streak_zero_when_today_and_yesterday_missing() {
            var w = hHabit.item
            // A single check-in 3 days ago; both today and yesterday missing.
            hHabit.storeCtl.patchSettings("test-instance", { checkins: consecutiveDays(w, 1, 3) })
            compare(w.streak, 0, "no run touching today/yesterday → 0")
        }

        function test_checkin_adds_today_once() {
            var w = hHabit.item
            hHabit.storeCtl.patchSettings("test-instance", { checkins: [] })
            compare(w.doneToday, false)
            w.toggleToday()
            compare(w.doneToday, true, "checked in")
            compare(w.streak, 1)
            compare(occurrences(cfg().checkins, w.todayKey), 1, "today's key stored exactly once")
        }
        function test_uncheck_removes_and_lowers_streak_but_keeps_best() {
            var w = hHabit.item
            // 3-day run incl today, with a stored best of 3.
            hHabit.storeCtl.patchSettings("test-instance",
                { checkins: consecutiveDays(w, 3, 0), bestStreak: 3 })
            compare(w.streak, 3)
            w.toggleToday()   // uncheck today
            compare(w.doneToday, false, "today removed")
            compare(w.streak, 2, "streak drops (grace day keeps the ending-yesterday run)")
            compare(w.bestStreak, 3, "best streak stays at prior max")
            compare(occurrences(cfg().checkins, w.todayKey), 0, "today's key gone from storage")
        }

        function test_status_compact_shows_current_state() {
            var w = hHabit.item
            hHabit.storeCtl.patchSettings("test-instance", { checkins: consecutiveDays(w, 4, 0) })
            // In expanded mode status is blank; drive the compact instance.
            compare(hCompact.item.status, hCompact.item.doneToday ? "Checked in" : "Ready",
                    "compact status reports today's state instead of duplicating the streak")
        }

        function test_weekday_and_weekend_schedules() {
            var w = hHabit.item
            hHabit.storeCtl.setSetting("test-instance", "cadence", "weekdays")
            verify(w.scheduled(new Date(2026, 6, 20, 12)), "Monday is scheduled")
            verify(!w.scheduled(new Date(2026, 6, 19, 12)), "Sunday is a rest day")
            hHabit.storeCtl.setSetting("test-instance", "cadence", "weekends")
            verify(w.scheduled(new Date(2026, 6, 19, 12)), "Sunday is scheduled")
        }

        function test_custom_schedule_blocks_unscheduled_checkin() {
            var w = hHabit.item
            var today = new Date().getDay(), excluded = (today + 1) % 7
            hHabit.storeCtl.patchSettings("test-instance", { cadence: "custom", activeDays: String(excluded), checkins: [] })
            compare(w.scheduledToday, false)
            w.toggleToday(); compare(w.checkins.length, 0)
            hHabit.storeCtl.setSetting("test-instance", "activeDays", String(today))
            compare(w.scheduledToday, true)
            w.toggleToday(); compare(w.doneToday, true)
        }

        function test_empty_custom_schedule_has_no_accidental_sunday() {
            var w = hHabit.item
            hHabit.storeCtl.patchSettings("test-instance",
                { cadence: "custom", activeDays: "", checkins: [] })
            for (var day = 0; day < 7; day++)
                verify(!w.scheduled(new Date(2026, 6, 19 + day, 12)),
                       "empty custom schedule excludes weekday " + day)
        }

        function test_pause_and_streak_free_modes() {
            var w = hHabit.item
            hHabit.storeCtl.patchSettings("test-instance", { paused: true, showStreak: false, checkins: [] })
            compare(w.status, "")
            w.toggleToday(); compare(w.checkins.length, 0)
            compare(w.showStreak, false)
        }
    }

    // ── Milestones + celebration ───────────────────────────────────────────
    TestCase {
        name: "HabitMilestones"
        when: windowShown
        function init() {
            tryVerify(function () { return hHabit.ready }, 3000)
            clearSettings(hHabit)
            hHabit.item.celebrateMsg = ""
        }

        function test_milestone_message_formatting() {
            var w = hHabit.item
            compare(w.milestoneMsg(7), "7-day milestone!", "7 is a milestone")
            compare(w.milestoneMsg(365), "365-day milestone!", "365 is a milestone")
            compare(w.milestoneMsg(1), "1 day complete!", "singular day")
            compare(w.milestoneMsg(2), "2 days complete!", "plural days")
            compare(w.milestoneMsg(8), "8 days complete!", "non-milestone plural")
        }

        function test_checkin_fires_singular_message() {
            var w = hHabit.item
            hHabit.storeCtl.patchSettings("test-instance", { checkins: [] })
            w.celebrateMsg = ""
            w.toggleToday()
            compare(w.celebrateMsg, "1 day complete!", "first check-in has deterministic feedback")
        }
        function test_checkin_fires_plural_message() {
            var w = hHabit.item
            // One day ending yesterday; checking in today → ns == 2.
            hHabit.storeCtl.patchSettings("test-instance", { checkins: consecutiveDays(w, 1, 1) })
            w.celebrateMsg = ""
            w.toggleToday()
            compare(w.celebrateMsg, "2 days complete!", "second consecutive day has plural feedback")
        }
        function test_milestone_fires_on_crossing_seven() {
            var w = hHabit.item
            // 6 consecutive ending yesterday; checking in today → ns == 7.
            hHabit.storeCtl.patchSettings("test-instance", { checkins: consecutiveDays(w, 6, 1) })
            w.celebrateMsg = ""
            w.toggleToday()
            compare(w.streak, 7, "crossed into a 7-day run")
            compare(w.celebrateMsg, "7-day milestone!", "milestone popup on crossing 7")
        }

        // FIXED, and this test pins it (audit line 58). The defect was: re-
        // checking the same already-milestone day re-fires the milestone
        // celebration. Correct behaviour: no milestone message on a plain re-
        // check.
        function test_recheck_same_day_should_not_refire_milestone() {
            var w = hHabit.item
            hHabit.storeCtl.patchSettings("test-instance", { checkins: consecutiveDays(w, 7, 0) })
            compare(w.streak, 7, "already at a 7-day milestone (today included)")
            w.toggleToday()          // uncheck today → streak 6, no celebration
            w.celebrateMsg = ""      // clear before the re-check
            w.toggleToday()          // re-check today → streak back to 7
            verify(w.celebrateMsg.indexOf("milestone") < 0,
                   "re-checking an already-reached milestone should NOT re-announce it (got '"
                   + w.celebrateMsg + "')")
        }
    }

    // ── Best streak + reactivity ───────────────────────────────────────────
    TestCase {
        name: "HabitReactivity"
        when: windowShown
        function init() {
            tryVerify(function () { return hHabit.ready }, 3000)
            clearSettings(hHabit)
        }
        function cfg() { return hHabit.storeCtl.settingsFor("test-instance") }

        function test_best_streak_never_below_current() {
            var w = hHabit.item
            hHabit.storeCtl.patchSettings("test-instance", { checkins: [], bestStreak: 5 })
            compare(w.bestStreak, 5, "persisted best survives a lapsed current streak")
            hHabit.storeCtl.patchSettings("test-instance",
                { checkins: consecutiveDays(w, 9, 0), bestStreak: 5 })
            compare(w.bestStreak, 9, "live max wins when current run exceeds stored best")
        }

        function test_reactive_to_store_revision() {
            var w = hHabit.item
            hHabit.storeCtl.patchSettings("test-instance", { name: "Read", checkins: [] })
            compare(w.name, "Read", "name reads through revision")
            compare(w.streak, 0)
            // External patch (mirrors a Manager setUiState → revision bump).
            hHabit.storeCtl.patchSettings("test-instance",
                { name: "Run", checkins: consecutiveDays(w, 3, 0), bestStreak: 12 })
            compare(w.name, "Run", "name updates reactively")
            compare(w.streak, 3, "streak recomputes reactively")
            compare(w.bestStreak, 12, "bestStreak updates reactively")
            compare(w.doneToday, true, "doneToday updates reactively")
        }

        function test_tick_drives_today_recompute() {
            var w = hHabit.item
            hHabit.storeCtl.patchSettings("test-instance", { checkins: [w.key(new Date())] })
            var before = w.todayKey
            w.tick++
            compare(w.todayKey, before, "todayKey stable across tick (same wall day)")
            compare(w.doneToday, true, "doneToday still reflects today's check-in after tick")
        }

        // FIXED, and this test pins it (audit line 55). The defect was: checkins
        // is never pruned, so long-term use bloats the persisted array (only 28
        // days are ever displayed). Correct behaviour: bounded storage.
        function test_checkins_storage_is_bounded() {
            var w = hHabit.item
            hHabit.storeCtl.patchSettings("test-instance", { checkins: consecutiveDays(w, 40, 1) })
            w.toggleToday()   // add today → 41 entries and counting
            verify(cfg().checkins.length <= 30,
                   "checkins should be pruned to the displayable window (got "
                   + cfg().checkins.length + ")")
        }
    }

    // ── DST-spanning streak + heatmap mapping ──────────────────────────────
    TestCase {
        name: "HabitDST"
        when: windowShown
        function init() {
            tryVerify(function () { return hHabit.ready }, 3000)
            clearSettings(hHabit)
        }

        // FIXED, and this test pins it (audit line 37). The defect was:
        // streakOf() steps days with a fixed 86400000ms, which skips/duplicates
        // a calendar date across a DST boundary when the walk crosses one near
        // local midnight. A fully-consecutive run must count to its exact
        // length. (Passes in non-DST zones / away from midnight; fails when the
        // DST skip lands inside the run.)
        function test_consecutive_run_counts_across_dst() {
            var w = hHabit.item
            // 400 days spans at least one spring-forward and one fall-back.
            var run = consecutiveDays(w, 400, 0)
            compare(w.streakOf(run), run.length,
                    "an unbroken daily run must count every calendar day (DST-safe)")
        }

        // FIXED, and this test pins it (audit line 122). The defect was: the
        // heatmap cells use (27-index)*86400000 and can collapse two cells onto
        // one calendar date across a DST boundary. All 28 cells must map to
        // distinct consecutive dates, and exactly one cell (todayKey) carries
        // the "today" border.
        function test_heatmap_28_distinct_days_and_one_today() {
            var w = hHabit.item
            hHabit.storeCtl.patchSettings("test-instance", { checkins: [] })
            wait(0)
            var cells = findCells(w)
            compare(cells.length, 28, "28 heatmap cells rendered")
            var seen = {}, distinct = 0, todayBorders = 0
            for (var i = 0; i < cells.length; i++) {
                if (!seen[cells[i].dk]) { seen[cells[i].dk] = true; distinct++ }
                if (cells[i].dk === w.todayKey && cells[i].border.width >= 2) todayBorders++
            }
            compare(distinct, 28, "all 28 cells map to distinct calendar dates (no DST collision)")
            compare(todayBorders, 1, "exactly one cell carries the today border")
        }

        function test_heatmap_today_cell_reflects_checkin() {
            var w = hHabit.item
            hHabit.storeCtl.patchSettings("test-instance", { checkins: [w.key(new Date())] })
            wait(0)
            var cells = findCells(w)
            var todayCell = null
            for (var i = 0; i < cells.length; i++)
                if (cells[i].dk === w.todayKey) todayCell = cells[i]
            verify(todayCell !== null, "today's cell exists in the grid")
            compare(todayCell.on, true, "today's cell is filled after a check-in")
        }
    }

    // ── Appearance, name, title override ───────────────────────────────────
    TestCase {
        name: "HabitAppearance"
        when: windowShown
        function init() {
            tryVerify(function () { return hHabit.ready }, 3000)
            clearSettings(hHabit)
            hHabit.item.accentName = ""
            hHabit.item.titleOverride = ""
        }

        function test_accent_name_recolors() {
            var w = hHabit.item
            verify(Qt.colorEqual(w.effAccent, hHabit.theme.catProductivity),
                   "defaults to the productivity category accent")
            w.accentName = "green"
            verify(Qt.colorEqual(w.effAccent, hHabit.theme.accentPresets["green"].a),
                   "accentName overrides the effective accent")
            verify(!Qt.colorEqual(w.effAccent, hHabit.theme.catProductivity),
                   "no longer the default accent")
        }

        function test_custom_name_in_header() {
            var w = hHabit.item
            hHabit.storeCtl.setSetting("test-instance", "name", "Meditate")
            compare(w.name, "Meditate")
            compare(w.title, "Meditate", "custom name becomes the header title")
        }
        function test_empty_name_falls_back() {
            var w = hHabit.item
            hHabit.storeCtl.setSetting("test-instance", "name", "")
            compare(w.name, "")
            compare(w.title, "Habit", "empty name falls back to 'Habit'")
        }
        function test_title_override_wins() {
            var w = hHabit.item
            hHabit.storeCtl.setSetting("test-instance", "name", "Meditate")
            w.titleOverride = "Morning Ritual"
            compare(w.title, "Meditate", "widget title still tracks the name")
            // WidgetChrome renders titleOverride when present.
            var texts = root.findAll(w, function (n) {
                return n.hasOwnProperty("text") && String(n.text) === "Morning Ritual"
            }, [])
            verify(texts.length >= 1, "the override string is what actually renders in the header")
        }
    }

    // ── Compact-tile layout (1x1) ──────────────────────────────────────────
    TestCase {
        name: "HabitCompactTile"
        when: windowShown
        function init() {
            tryVerify(function () { return hCompact.ready }, 3000)
            var s = hCompact.storeCtl.settingsFor("test-instance")
            for (var k in s) delete s[k]
            hCompact.storeCtl._touchSettings()
        }

        // FIXED, and this test pins it (audit line 96). The defect was: compact
        // content is centerIn:parent inside a clipped body, so on a 1x1 tile the
        // check-in PillButton overflows and is clipped/untappable. It should
        // stay fully within the tile and be touch-sized.
        function test_checkin_button_visible_and_tappable() {
            var w = hCompact.item
            var pill = root.findPill(w)
            verify(pill !== null, "check-in pill exists")
            verify(pill.height >= 44, "pill meets the 44px touch minimum (" + pill.height + ")")
            var p = pill.mapToItem(w, 0, 0)
            verify(p.y >= 0 && (p.y + pill.height) <= w.height,
                   "pill fits within the tile (top=" + p.y.toFixed(1)
                   + " bottom=" + (p.y + pill.height).toFixed(1) + " tileH=" + w.height + ")")
        }

        function test_pill_click_checks_in() {
            var w = hCompact.item
            hCompact.storeCtl.patchSettings("test-instance", { checkins: [] })
            compare(w.doneToday, false)
            var pill = root.findPill(w)
            verify(pill !== null)
            mouseClick(pill)
            compare(w.doneToday, true, "tapping the pill records a check-in")
        }
    }

    // ── P1: streak persists past the 28-day heatmap window ─────────────────
    // The streak is a stored NUMBER, decoupled from the pruned `checkins` array,
    // so long runs report their true length and milestones past 14 can fire.
    TestCase {
        name: "HabitLongStreak"
        when: windowShown
        function init() {
            tryVerify(function () { return hHabit.ready }, 3000)
            clearSettings(hHabit)
            hHabit.item.celebrateMsg = ""
            // Reset any overridden today key from a prior test (rebind to now).
            hHabit.item.todayKey = Qt.binding(function () {
                return (hHabit.item.tick, hHabit.item.key(new Date()))
            })
        }
        function cfg() { return hHabit.storeCtl.settingsFor("test-instance") }

        // (a) A 40-consecutive-day streak, accrued via daily check-ins, reports
        // 40 (NOT capped at 28) while the heatmap array stays pruned; best ≥ 40.
        // Days are advanced deterministically by overriding todayKey, never the
        // wall clock.
        function test_forty_day_streak_reports_40_not_28() {
            var w = hHabit.item
            hHabit.storeCtl.patchSettings("test-instance", { checkins: [] })
            // Walk from 39 days ago up to today, checking in each calendar day.
            var d = new Date(); d.setHours(12, 0, 0, 0); d.setDate(d.getDate() - 39)
            for (var i = 0; i < 40; i++) {
                w.todayKey = w.key(d)
                w.toggleToday()
                d.setDate(d.getDate() + 1)
            }
            compare(w.streak, 40, "40 consecutive check-ins report a 40-day streak")
            verify(w.bestStreak >= 40, "bestStreak tracks the full run (got " + w.bestStreak + ")")
            verify(cfg().checkins.length <= 28,
                   "heatmap array is still pruned to its window (got " + cfg().checkins.length + ")")
            compare(cfg().streak, 40, "the streak number is persisted independently")
        }

        // (b) A milestone past 14 (30) is reachable - impossible while the streak
        // was capped at ~28.
        function test_milestone_30_is_reachable() {
            var w = hHabit.item
            var today = w.key(new Date())
            var yesterday = w.prevDayKey(today)
            // Seed a maintained 29-run ending yesterday; today not yet checked.
            hHabit.storeCtl.patchSettings("test-instance",
                { checkins: [], streak: 29, lastCheckinDay: yesterday, bestStreak: 29 })
            compare(w.streak, 29, "grace day: a 29-run ending yesterday still counts")
            w.celebrateMsg = ""
            w.toggleToday()   // check in today → 30
            compare(w.streak, 30, "crossed into a 30-day run")
            compare(w.celebrateMsg, "30-day milestone!", "30-day milestone celebration fires")
        }

        // (c) A gap (last check-in older than the grace day) resets the streak to
        // 1 on the next check-in, while the best-ever is preserved.
        function test_gap_resets_streak_to_one() {
            var w = hHabit.item
            var d = new Date(); d.setHours(12, 0, 0, 0); d.setDate(d.getDate() - 3)
            var threeAgo = w.key(d)
            hHabit.storeCtl.patchSettings("test-instance",
                { checkins: [threeAgo], streak: 20, lastCheckinDay: threeAgo, bestStreak: 20 })
            compare(w.streak, 0, "a lapsed streak (gap beyond the grace day) reads 0")
            w.celebrateMsg = ""
            w.toggleToday()   // check in today after the gap
            compare(w.streak, 1, "the gap starts a fresh 1-day streak")
            compare(w.bestStreak, 20, "the best-ever streak is preserved across the gap")
            compare(w.celebrateMsg, "1 day complete!", "no false milestone on the reset")
        }

        // (d) Checking in when today is already counted is idempotent - it must
        // not double-increment the stored number.
        function test_same_day_checkin_is_idempotent() {
            var w = hHabit.item
            var today = w.key(new Date())
            // Defensive state: streak recorded for today, but today's key absent
            // from the (pruned) array - the check-in branch must still not bump.
            hHabit.storeCtl.patchSettings("test-instance",
                { checkins: [], streak: 5, lastCheckinDay: today, bestStreak: 5 })
            w.toggleToday()   // check-in branch, but today is already the last day
            compare(w.streak, 5, "re-checking the same day does not double-increment")
            compare(w.bestStreak, 5, "best-ever unchanged by an idempotent check-in")
            compare(cfg().streak, 5, "persisted number unchanged")
        }

        // (e) A legacy config that only has a long `checkins` array (no stored
        // streak/lastCheckinDay) derives a sensible initial streak and then keeps
        // maintaining the number forward - no crash, no reset.
        function test_legacy_config_derives_then_maintains() {
            var w = hHabit.item
            // 25-day consecutive run ending today; ONLY the array is stored.
            hHabit.storeCtl.patchSettings("test-instance", { checkins: consecutiveDays(w, 25, 0) })
            verify(cfg().streak === undefined, "legacy: no stored streak number yet")
            compare(w.streak, 25, "legacy streak is derived from the check-in array")
            // Un-check then re-check today: the number is maintained forward.
            w.toggleToday()   // uncheck today → 24
            compare(w.streak, 24, "maintained down to 24 after un-checking today")
            w.toggleToday()   // recheck today → 25
            compare(w.streak, 25, "maintained back to 25, no legacy-derivation reset")
            compare(cfg().streak, 25, "the number is now persisted")
        }

        function test_uncheck_preserves_streak_beyond_pruned_heatmap() {
            var w = hHabit.item
            var today = w.key(new Date())
            var visibleWindow = consecutiveDays(w, 28, 0)
            hHabit.storeCtl.patchSettings("test-instance", {
                checkins: visibleWindow,
                streak: 100,
                lastCheckinDay: today,
                bestStreak: 100
            })
            compare(w.streak, 100, "precondition: maintained 100-day streak")
            w.toggleToday()
            compare(cfg().streak, 99,
                    "removing one day removes exactly one day from a long streak")
            compare(w.streak, 99,
                    "the live streak does not collapse to the pruned heatmap length")
            compare(cfg().lastCheckinDay, w.prevDayKey(today),
                    "the maintained run now ends on the previous scheduled day")
            compare(cfg().bestStreak, 100, "the historical best remains intact")
        }
    }

    // ── store == null guard ────────────────────────────────────────────────
    TestCase {
        name: "HabitNullStore"
        when: windowShown
        function init() { tryVerify(function () { return hNull.ready }, 3000) }

        function test_toggle_is_safe_noop_without_store() {
            var w = hNull.item
            w.store = null
            w.celebrateMsg = ""
            compare(w.streak, 0, "no store → empty streak")
            compare(w.doneToday, false)
            w.toggleToday()   // must not throw and must not celebrate
            compare(w.celebrateMsg, "", "no celebration fired without a store")
            compare(w.doneToday, false, "nothing persisted")
            verify(true, "toggleToday did not crash without a store")
        }
    }

    // ── Per-sizeClass structure (W1 wave 2b) ────────────────────────────────
    // Fixed-size hosts at the real projected cell footprints.
    Item { width: 348; height: 409
        WidgetHarness { id: bMicro; anchors.fill: parent; widgetFile: "HabitWidget.qml"; expanded: false } }
    Item { width: 696; height: 819
        WidgetHarness { id: bBase; anchors.fill: parent; widgetFile: "HabitWidget.qml"; expanded: false } }
    Item { id: bWideWrap; width: 696; height: 409
        WidgetHarness { id: bWide; anchors.fill: parent; widgetFile: "HabitWidget.qml"; expanded: false } }
    // 1x1.5 - a half screen, at BOTH of its real projections.
    Item { width: 696; height: 1229
        WidgetHarness { id: bRoomyP; anchors.fill: parent; widgetFile: "HabitWidget.qml"; expanded: false } }
    Item { width: 1269; height: 612
        WidgetHarness { id: bRoomyL; anchors.fill: parent; widgetFile: "HabitWidget.qml"; expanded: false } }
    // Exact matrix footprints for the compressed responsive paths.
    Item { width: 278; height: 327
        WidgetHarness { id: bMatrixMicro; anchors.fill: parent; widgetFile: "HabitWidget.qml"; expanded: false } }
    Item { width: 278; height: 654
        WidgetHarness { id: bMatrixNarrow; anchors.fill: parent; widgetFile: "HabitWidget.qml"; expanded: false } }
    Item { width: 677; height: 245
        WidgetHarness { id: bMatrixShallow; anchors.fill: parent; widgetFile: "HabitWidget.qml"; expanded: false } }
    Item { width: 338; height: 490
        WidgetHarness { id: bMatrixCompressed; anchors.fill: parent; widgetFile: "HabitWidget.qml"; expanded: false } }
    Item { width: 557; height: 982
        WidgetHarness { id: bMatrixRoomy; anchors.fill: parent; widgetFile: "HabitWidget.qml"; expanded: false } }

    // The OVERLAY, at the two boxes Dashboard actually gives it. `expanded: true`
    // and sizeClass "full" - the real pairing - because a mode-keyed literal can
    // only be caught with the mode switched ON. These are the live-preview pane
    // beside the config form (Dashboard: 38% of the width in landscape, a <=46%-
    // tall band stacked in portrait), NOT a 2560x720 screen.
    Item { width: 941; height: 456
        WidgetHarness { id: bOvlL; anchors.fill: parent; widgetFile: "HabitWidget.qml"; expanded: true } }
    Item { width: 656; height: 980
        WidgetHarness { id: bOvlP; anchors.fill: parent; widgetFile: "HabitWidget.qml"; expanded: true } }

    TestCase {
        name: "HabitSizes"
        when: windowShown

        function seed(host) {
            var d = new Date(); d.setHours(12, 0, 0, 0)
            var arr = []
            for (var i = 0; i < 5; i++) {
                var x = new Date(d); x.setDate(x.getDate() - i)
                arr.push(Qt.formatDate(x, "yyyy-MM-dd"))
            }
            host.storeCtl.patchSettings(host.instanceId,
                { checkins: arr, streak: 5, lastCheckinDay: arr[0], bestStreak: 9 })
        }
        function findAll(node, pred, acc) {
            if (!node) return acc
            if (pred(node)) acc.push(node)
            var kids = node.children
            for (var i = 0; kids && i < kids.length; i++) findAll(kids[i], pred, acc)
            return acc
        }
        // The heatmap: the GridLayout whose columns === 7.
        function heat(host) {
            return findAll(host.item, function (n) {
                return n.hasOwnProperty("columns") && n.columns === 7
                       && n.hasOwnProperty("rowSpacing") }, [])[0]
        }
        function pill(host) {
            return findAll(host.item, function (n) {
                return n.hasOwnProperty("label") && n.hasOwnProperty("glyph")
                       && n.hasOwnProperty("primary") }, [])[0]
        }
        function named(host, name) {
            return findAll(host.item, function (n) {
                return n.objectName === name
            }, [])[0]
        }
        function seedMatrix(host, habitName, checked) {
            var d = new Date(); d.setHours(12, 0, 0, 0)
            var arr = []
            for (var i = 0; i < 28; i++) {
                var x = new Date(d); x.setDate(x.getDate() - i)
                if (checked)
                    arr.push(Qt.formatDate(x, "yyyy-MM-dd"))
            }
            host.storeCtl.patchSettings(host.instanceId, {
                name: habitName,
                checkins: arr,
                streak: checked ? 9999 : 0,
                bestStreak: checked ? 99999 : 0,
                lastCheckinDay: checked ? Qt.formatDate(d, "yyyy-MM-dd") : ""
            })
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

        // 0.5x0.5 - the streak and the tap. 28 cells are not legible here.
        function test_micro_is_streak_plus_checkin() {
            tryVerify(function () { return bMicro.ready }, 3000)
            var b = bMicro.item
            b.sizeClass = "compact"
            seed(bMicro)
            compare(b.micro, true, "a 348x409 compact box is the micro tile")
            compare(b.showHeader, false, "micro drops the chrome header")
            compare(b.showHeatmap, false, "micro drops the heatmap")
            verify(b.streakPx >= 18, "the streak stays a readout ("
                   + b.streakPx.toFixed(0) + "px)")
            var p = pill(bMicro)
            verify(p.visible, "micro keeps the check-in button")
            verify(p.height >= bMicro.theme.touchTertiary,
                   "…at >= touchTertiary (" + p.height + ") - never shrunk to fit")
        }

        // 1x1 - the heatmap is EARNED (it used to be overlay-only).
        function test_baseline_earns_the_heatmap() {
            tryVerify(function () { return bBase.ready }, 3000)
            var b = bBase.item
            b.sizeClass = "compact"
            seed(bBase)
            compare(b.micro, false, "a 696x819 baseline tile is not micro")
            compare(b.showHeatmap, true,
                    "the baseline tile earns the 28-day heatmap without expanding")
            var g = heat(bBase)
            verify(g.visible, "…and it is actually visible")
            compare(g.columns, 7, "the heatmap stays 7 wide")
            verify(b.heatCell > 12, "cells scale to the box, past the old fixed 12px ("
                   + b.heatCell.toFixed(0) + ")")
            // 28 cells, all live.
            var cells = findAll(g, function (n) { return n.hasOwnProperty("dk") }, [])
            compare(cells.length, 28, "all 28 days are rendered")
        }

        function test_heatmap_has_non_color_state_and_date_context() {
            var b = bBase.item
            b.sizeClass = "compact"
            seed(bBase)
            wait(0)
            var cells = findAll(b, function (n) {
                return n.objectName && String(n.objectName).indexOf("habitDay-") === 0
            }, [])
            compare(cells.length, 28, "all day cells expose stable semantic identities")
            for (var i = 0; i < cells.length; i++) {
                verify(cells[i].stateLabel.length > 0, "day " + i + " has a textual state")
                var marks = findAll(cells[i], function (n) {
                    return n.hasOwnProperty("text")
                        && ["✓", "○", "−"].indexOf(String(n.text)) >= 0
                }, [])
                compare(marks.length, 1, "day " + i + " has one non-color state mark")
            }
            var ranges = findAll(b, function (n) {
                return n.objectName === "habitHeatmapRange" && n.visible
            }, [])
            var legends = findAll(b, function (n) {
                return n.objectName === "habitHeatmapLegend" && n.visible
            }, [])
            compare(ranges.length, 1, "the visible heatmap includes its date range")
            compare(legends.length, 1, "the visible heatmap includes its state legend")
            verify(b.heatmapSummary.indexOf("scheduled check-ins completed") >= 0,
                   "assistive summary explains completion rather than only color")
        }

        // wide - the streak/button column moves beside the heatmap; the cells are
        // the SAME objects (the literal-28 model never rebuilds).
        function test_wide_puts_streak_beside_heatmap() {
            tryVerify(function () { return bWide.ready }, 3000)
            var b = bWide.item
            b.sizeClass = "compact"
            seed(bWide)
            var outer = heat(bWide).parent.parent
            compare(outer.columns, 1, "a stacked box is one column")
            var cellBefore = findAll(b, function (n) { return n.hasOwnProperty("dk") }, [])[0]
            b.sizeClass = "wide"
            compare(b.horiz, true, "wide is the horizontal shape")
            compare(outer.columns, 2, "wide puts the streak beside the heatmap")
            var cellAfter = findAll(b, function (n) { return n.hasOwnProperty("dk") }, [])[0]
            verify(cellAfter === cellBefore,
                   "the same heatmap cell survives the class flip (no rebuild)")
            b.sizeClass = "compact"
        }

        function test_matrix_micro_uses_a_complete_compact_streak_label() {
            tryVerify(function () { return bMatrixMicro.ready }, 3000)
            var host = bMatrixMicro
            host.item.sizeClass = "compact"
            host.theme.textScale = 1.15
            host.theme.fontChoice = "hyperlegible"
            seedMatrix(host, "Daily movement", true)
            wait(32)

            verify(host.item.micro, "the exact 278x327 projection is micro")
            var value = named(host, "habitStreakValue")
            verify(value && value.visible)
            compare(value.text, "9999d", "micro uses the unambiguous compact unit")
            compare(value.Accessible.name, "9999 days",
                    "assistive output retains the spoken long form")
            verify(!value.truncated, "the maximum streak is not ellipsized")
            assertInside(value, value.parent, "micro streak")
        }

        function test_matrix_narrow_copy_wraps_and_remains_complete() {
            tryVerify(function () { return bMatrixNarrow.ready }, 3000)
            var host = bMatrixNarrow
            host.item.sizeClass = "tall"
            host.theme.textScale = 1.45
            host.theme.fontChoice = "lexend"
            seedMatrix(host, "Complete the daily movement practice", true)
            wait(32)

            verify(host.item.compactNameLayout)
            var bodyName = named(host, "habitBodyName")
            var range = named(host, "habitHeatmapRange")
            var legend = named(host, "habitHeatmapLegend")
            var feedback = named(host, "habitTodayFeedback")
            verify(bodyName && range && legend && feedback)
            verify(bodyName.visible && !bodyName.truncated,
                   "the user habit name wraps in the body without ellipsis")
            verify(String(range.text).indexOf("28D") === 0,
                   "narrow range copy keeps the window and dates")
            compare(legend.text, "✓ Done   ○ Due   − Rest",
                    "narrow legend keeps all three states")
            compare(feedback.text, "Today: Checked in",
                    "narrow feedback keeps the current state")
            verify(!range.truncated && !legend.truncated && !feedback.truncated)
            assertInside(named(host, "habitLayout"),
                         named(host, "habitLayout").parent,
                         "narrow habit layout")
        }

        function test_scaled_day_marks_use_the_active_type_floor() {
            tryVerify(function () {
                return bMatrixNarrow.ready && bMatrixShallow.ready
            }, 3000)
            var cases = [
                { host: bMatrixNarrow, cls: "tall", scale: 1.45 },
                { host: bMatrixShallow, cls: "wide", scale: 1.3 }
            ]
            for (var c = 0; c < cases.length; c++) {
                var host = cases[c].host
                host.item.sizeClass = cases[c].cls
                host.theme.textScale = cases[c].scale
                host.theme.fontChoice = "lexend"
                seedMatrix(host, "Daily movement", true)
                wait(32)
                var marks = findAll(host.item, function (n) {
                    return String(n.objectName).indexOf("habitDayMark-") === 0
                           && n.visible
                }, [])
                compare(marks.length, 28, "all 28 state marks render")
                for (var i = 0; i < marks.length; i++) {
                    verify(marks[i].font.pixelSize >= host.theme.fontMinimum,
                           "day mark " + i + " respects the "
                           + host.theme.fontMinimum + "px floor")
                    assertInside(marks[i], marks[i].parent,
                                 "day mark " + i)
                }
            }
        }

        function test_shallow_and_compressed_projections_fit_their_body() {
            tryVerify(function () {
                return bMatrixShallow.ready && bMatrixCompressed.ready
            }, 3000)
            var cases = [
                { host: bMatrixShallow, cls: "wide", scale: 1.3,
                  shallow: true, compressed: false },
                { host: bMatrixCompressed, cls: "tall", scale: 1.45,
                  shallow: false, compressed: true }
            ]
            for (var i = 0; i < cases.length; i++) {
                var host = cases[i].host
                host.item.sizeClass = cases[i].cls
                host.theme.textScale = cases[i].scale
                seedMatrix(host, "Daily movement", false)
                wait(32)
                compare(host.item.shallowWide, cases[i].shallow)
                compare(host.item.compressedTall, cases[i].compressed)
                var legend = named(host, "habitHeatmapLegend")
                compare(legend.visible, false,
                        "duplicate legend yields to the complete 28-day grid")
                if (cases[i].compressed)
                    compare(named(host, "habitTodayFeedback").visible, false,
                            "the button carries today's action in the compressed stack")
                assertInside(named(host, "habitLayout"),
                             named(host, "habitLayout").parent,
                             cases[i].cls + " habit layout")
            }
        }

        function test_scaled_roomy_portrait_keeps_range_and_action_inside() {
            tryVerify(function () { return bMatrixRoomy.ready }, 3000)
            var host = bMatrixRoomy
            host.item.sizeClass = "tall"
            host.theme.textScale = 1.45
            host.theme.fontChoice = "lexend"
            seedMatrix(host, "Daily movement", false)
            wait(32)

            verify(host.item.roomy)
            var layout = named(host, "habitLayout")
            var range = named(host, "habitHeatmapRange")
            var button = named(host, "habitCheckinButton")
            verify(layout && range && button)
            verify(!range.truncated)
            assertInside(layout, layout.parent, "scaled roomy layout")
            assertInside(button, button.parent, "scaled roomy check-in action")
        }
    }

    // ── 1x1.5 (W1 wave 2c) ─────────────────────────────────────────────────
    // A half screen. It projects to 696x1229 "tall" in portrait and 1269x612
    // "wide" in landscape, and the bar is that BOTH are designed - not one
    // layout stretched to fill whichever box turns up.
    TestCase {
        name: "HabitRoomy"
        when: windowShown

        function seed(host) {
            var d = new Date(); d.setHours(12, 0, 0, 0)
            var arr = []
            for (var i = 0; i < 5; i++) {
                var x = new Date(d); x.setDate(x.getDate() - i)
                arr.push(Qt.formatDate(x, "yyyy-MM-dd"))
            }
            host.storeCtl.patchSettings(host.instanceId,
                { checkins: arr, streak: 5, lastCheckinDay: arr[0], bestStreak: 9 })
        }
        // The INNER grid - the one whose DIRECT children are the day cells. The
        // outer grid also has columns/rowSpacing and also contains all 28 cells
        // (via the inner one), so a descendant-based predicate matches it first
        // and silently reads the wrong `columns`. The sibling helper above gets
        // away with `columns === 7` only because the map no longer always is.
        function heat(host) {
            return root.findAll(host.item, function (n) {
                if (!n.hasOwnProperty("columns") || !n.hasOwnProperty("rowSpacing")) return false
                var kids = n.children || []
                for (var i = 0; i < kids.length; i++)
                    if (kids[i].hasOwnProperty("dk")) return true
                return false
            }, [])[0]
        }
        function pill(host) { return root.findPill(host.item) }
        function bestLine(host) {
            return root.findAll(host.item, function (n) {
                return n.hasOwnProperty("text") && String(n.text).indexOf("Best:") === 0
            }, [])[0]
        }
        function init() {
            tryVerify(function () { return bRoomyP.ready && bRoomyL.ready && bBase.ready }, 3000)
        }

        // The size is offered at all - a widget that renders it but never declares
        // it is unreachable, and one that declares it without rendering it is the
        // W1 failure.
        function test_catalog_offers_1x1_5_for_habit() {
            var cat = Qt.createQmlObject('import QtQuick; import "../../ui/qml"; WidgetCatalog {}', root)
            var sizes = cat.sizesFor("habit")
            verify(sizes.indexOf("1x1.5") >= 0,
                   "habit declares 1x1.5 (got " + JSON.stringify(sizes) + ")")
            verify(sizes.indexOf("1x2") < 0 && sizes.indexOf("1x3") < 0,
                   "…and stops there - the history is pruned to 28 days, so a bigger "
                   + "tile would only inflate the map (got " + JSON.stringify(sizes) + ")")
            cat.destroy()
        }

        // Portrait: the map TRANSPOSES to fit a 0.57-aspect box.
        function test_roomy_portrait_transposes_the_map() {
            var b = bRoomyP.item
            b.sizeClass = "tall"
            seed(bRoomyP)
            wait(0)
            compare(b.roomy, true, "696x1229 is a half-screen tile, not a half-cell")
            compare(b.tallBox, true, "…and it is the tall projection")
            var g = heat(bRoomyP)
            compare(g.columns, 4, "the map runs 4 wide x 7 down for a tall box")
            compare(b.heatRows, 7, "…7 rows")
            var cells = root.findAll(g, function (n) { return n.hasOwnProperty("dk") }, [])
            compare(cells.length, 28, "still all 28 days")
        }

        // Landscape: the SAME size is a different card - the wide one.
        function test_roomy_landscape_is_the_wide_card() {
            var b = bRoomyL.item
            b.sizeClass = "wide"
            seed(bRoomyL)
            wait(0)
            compare(b.roomy, true, "1269x612 is a half-screen tile")
            compare(b.horiz, true, "…and it is the wide projection")
            compare(b.tallBox, false, "…so it is NOT the tall layout")
            var g = heat(bRoomyL)
            compare(g.columns, 7, "the map stays 7 wide beside the streak column")
            compare(g.parent.parent.columns, 2, "the streak column sits BESIDE the map")
        }

        // The record is earned by ROOM. This is the assertion that would have
        // caught the original `visible: w.expanded`.
        function test_record_line_is_earned_by_room_not_by_expanded() {
            var roomy = bRoomyP.item
            roomy.sizeClass = "tall"
            seed(bRoomyP)
            wait(0)
            compare(roomy.expanded, false, "the 1x1.5 tile is NOT the overlay")
            compare(roomy.showBest, true, "…yet it shows the best-ever record")
            var line = bestLine(bRoomyP)
            verify(line && line.visible,
                   "the record line actually renders on a 1x1.5 tile")

            // …and the baseline third, with genuinely less room, does not - so the
            // line is a size difference rather than something shown everywhere.
            var base = bBase.item
            base.sizeClass = "compact"
            seed(bBase)
            wait(0)
            compare(base.showBest, false,
                    "the 1x1 baseline does not claim the record line")
            var baseLine = bestLine(bBase)
            verify(!baseLine || !baseLine.visible,
                   "…and does not render it")
        }

        function test_roomy_card_adds_consistency_and_next_goal_insights() {
            var roomy = bRoomyP.item
            roomy.sizeClass = "tall"
            seed(bRoomyP)
            wait(16)
            var panel = root.findAll(roomy, function (n) {
                return n.objectName === "habitInsightPanel" && n.visible
            }, [])
            compare(panel.length, 1, "the half-screen habit card renders its insight panel")
            compare(roomy.recentStats.done, 5)
            compare(roomy.recentStats.total, 28)
            compare(roomy.nextMilestone, 7)
            verify(root.findAll(panel[0], function (n) {
                return n.hasOwnProperty("text") && String(n.text) === "2 days"
            }, []).length === 1, "the next milestone is turned into an actionable distance")

            var base = bBase.item
            base.sizeClass = "compact"
            seed(bBase)
            wait(16)
            panel = root.findAll(base, function (n) {
                return n.objectName === "habitInsightPanel" && n.visible
            }, [])
            compare(panel.length, 0, "the baseline card keeps the simpler streak and heatmap")
        }

        // 1x1.5 must differ from 1x1 in more than pixels: the map is genuinely
        // bigger AND the card carries content the baseline does not.
        function test_roomy_is_not_the_baseline_stretched() {
            var roomy = bRoomyP.item; roomy.sizeClass = "tall"
            var base = bBase.item;    base.sizeClass = "compact"
            seed(bRoomyP); seed(bBase)
            wait(0)
            verify(roomy.heatCell > base.heatCell * 1.5,
                   "the map is genuinely bigger, not the same 34px cells in a taller box ("
                   + roomy.heatCell.toFixed(0) + " vs " + base.heatCell.toFixed(0) + ")")
            verify(roomy.heatCols !== base.heatCols,
                   "…and it is a different arrangement, not the same grid scaled ("
                   + roomy.heatCols + " vs " + base.heatCols + " columns)")
            verify(roomy.showBest && !base.showBest,
                   "…and it carries content the baseline does not")
        }

        // Whatever the arrangement, the map still has to mean something: 28
        // distinct consecutive days, today last, and cells a week apart sharing a
        // weekday (the structure that makes a habit map readable at a glance).
        function test_transposed_map_keeps_28_distinct_days_and_weekday_structure() {
            var b = bRoomyP.item
            b.sizeClass = "tall"
            seed(bRoomyP)
            wait(0)
            compare(b.heatCols, 4, "precondition: the transposed grid")

            var seen = {}, n = 0
            for (var i = 0; i < 28; i++) {
                var da = b.daysAgoFor(i)
                verify(da >= 0 && da <= 27, "cell " + i + " maps inside the window (" + da + ")")
                if (!seen[da]) { seen[da] = true; n++ }
            }
            compare(n, 28, "all 28 cells map to distinct days")

            // Today is the LAST cell in reading order either way.
            compare(b.daysAgoFor(27), 0, "the final cell is today")

            // A week runs DOWN a column: consecutive rows in one column are
            // consecutive days.
            for (var c = 0; c < 4; c++)
                for (var r = 0; r < 6; r++)
                    compare(b.daysAgoFor((r + 1) * 4 + c) + 1, b.daysAgoFor(r * 4 + c),
                            "col " + c + ": row " + (r + 1) + " is the day after row " + r)

            // …so a ROW is a weekday: neighbours across a row are 7 days apart.
            for (var rr = 0; rr < 7; rr++)
                for (var cc = 0; cc < 3; cc++)
                    compare(b.daysAgoFor(rr * 4 + cc) - b.daysAgoFor(rr * 4 + cc + 1), 7,
                            "row " + rr + " keeps one weekday across its 4 weeks")
        }

        // The 7-col arrangement's own structure, for contrast: there the WEEK runs
        // across a row and the COLUMN is the weekday.
        function test_square_map_keeps_the_original_mapping() {
            var b = bBase.item
            b.sizeClass = "compact"
            wait(0)
            compare(b.heatCols, 7, "precondition: the 7-wide grid")
            compare(b.daysAgoFor(27), 0, "the final cell is today")
            compare(b.daysAgoFor(0), 27, "the first cell is 27 days ago")
            for (var i = 0; i < 21; i++)
                compare(b.daysAgoFor(i) - b.daysAgoFor(i + 7), 7,
                        "column " + (i % 7) + " keeps one weekday down the weeks")
        }

        // ── size, not mode ──────────────────────────────────────────────────
        // The record line was fixed in the previous pass; streakPx, heatCell, the
        // two spacings and the celebration banner were still keyed off `expanded`.
        // The test that catches that class has to hold `expanded` FIXED and move
        // only the room: anything that changes is genuinely sized by its box, and
        // anything that does not is still reading the mode.
        //
        // Every host below is expanded:false, so a surviving `w.expanded ? …`
        // branch is pinned to its else-value and cannot follow the box at all.
        function test_sizing_follows_the_room_while_the_mode_is_held_fixed() {
            var base = bBase.item;    base.sizeClass = "compact"
            var roomy = bRoomyP.item; roomy.sizeClass = "tall"
            seed(bBase); seed(bRoomyP)
            wait(0)
            compare(base.expanded, false, "precondition: neither host is the overlay")
            compare(roomy.expanded, false, "…including the roomy one")

            verify(roomy.streakPx > base.streakPx,
                   "the streak number follows the room (" + roomy.streakPx.toFixed(0)
                   + " on a half screen vs " + base.streakPx.toFixed(0)
                   + " on the baseline third)")
            // (The celebration banner is NOT asserted here: both these boxes are
            // wide enough to reach its 34px ceiling, so the comparison would be
            // 34 > 34 dressed up as a guard. It gets its own test below, against
            // two boxes that genuinely differ.)

            // The spacings, read off the LIVE layout items rather than off the
            // properties that feed them: a GridLayout that ignored the binding and
            // kept a literal would sail through a property-only check.
            var g = heat(bRoomyP)
            var outerRoomy = g.parent.parent
            var outerBase = heat(bBase).parent.parent
            verify(outerRoomy.rowSpacing > outerBase.rowSpacing,
                   "the rendered grid gives a half screen more air between the map "
                   + "and the streak (" + outerRoomy.rowSpacing + " vs "
                   + outerBase.rowSpacing + ")")

            // The streak column's own spacing, likewise from the rendered item.
            function streakColOf(host) {
                var line = bestLine(host) || root.findPill(host.item)
                return line ? line.parent : null
            }
            var colRoomy = streakColOf(bRoomyP)
            var colBase = streakColOf(bBase)
            verify(colRoomy && colBase, "both streak columns resolve")
            verify(colRoomy.spacing > colBase.spacing,
                   "…and the column stacks its readouts with more air too ("
                   + colRoomy.spacing + " vs " + colBase.spacing + ")")
        }

        // The overlay is a size class like any other, and its box is the one it is
        // actually given. This is the test that catches a mode-keyed literal, and
        // the ONLY shape that can: the sibling test above holds the mode fixed at
        // false, where a surviving `w.expanded ? 40 : <derived>` never fires its
        // literal at all and the derived branch keeps the assertion green. (That
        // is not hypothetical - this test was written second, after restoring the
        // literal left the room test passing.)
        //
        // Both hosts are expanded AND "full"; only the BOX differs. A literal
        // returns one number for both, so any assertion that the two differ is
        // exactly the mode/size conflation, caught.
        function test_overlay_is_sized_by_its_pane_not_by_a_mode_literal() {
            tryVerify(function () { return bOvlL.ready && bOvlP.ready }, 3000)
            var land = bOvlL.item; land.sizeClass = "full"
            var port = bOvlP.item; port.sizeClass = "full"
            seed(bOvlL); seed(bOvlP)
            // A real event-loop turn, not wait(0). These hosts default to
            // sizeClass "tall" (height > 240) and only become "full" on the line
            // above; wait(0) returns BEFORE the layout re-polishes, so a rendered
            // read then still reports the tall map's 69px cells against the
            // freshly-recomputed heatCell of 58.8 - a failure that says nothing
            // about the widget. Caught here as a genuine flake: the same
            // assertion passed and failed on consecutive runs.
            // waitForRendering is not the tool - offscreen never swaps a frame.
            wait(16)
            compare(land.expanded, true, "precondition: this IS the overlay")
            compare(port.expanded, true, "…and so is this one")
            compare(land.roomy, true, "…and 'full' is roomy")

            verify(land.streakPx !== port.streakPx,
                   "the overlay's streak number is sized by the pane it is given, "
                   + "not by one literal for 'the overlay' (941x456 -> "
                   + land.streakPx.toFixed(1) + ", 656x980 -> "
                   + port.streakPx.toFixed(1) + ")")
            verify(land.heatCell !== port.heatCell,
                   "…and so is the heatmap cell (941x456 -> "
                   + land.heatCell.toFixed(1) + ", 656x980 -> "
                   + port.heatCell.toFixed(1) + ")")
            // The taller pane is the roomier one for both readouts - direction,
            // not just difference, so a scrambled binding cannot pass.
            verify(port.streakPx > land.streakPx,
                   "the 980-tall pane earns the bigger number ("
                   + port.streakPx.toFixed(1) + " > " + land.streakPx.toFixed(1) + ")")
            verify(port.heatCell > land.heatCell,
                   "…and the bigger cells (" + port.heatCell.toFixed(1) + " > "
                   + land.heatCell.toFixed(1) + ")")

            // Rendered, not just derived: the cell Rectangles actually carry it.
            var cell = root.findAll(port, function (n) {
                return n.hasOwnProperty("dk") && n.hasOwnProperty("on") }, [])[0]
            verify(cell, "a day cell resolves in the portrait pane")
            // The cell's RENDERED width - not its Layout.preferredWidth, which is
            // merely the hint that feeds it and would stay green if the grid
            // ignored it.
            compare(cell.width, Math.round(port.heatCell),
                    "the rendered cell is actually the derived size, not a re-frozen literal")

            // And it still fits the pane it was sized for.
            var g = heat(bOvlP)
            verify(g.width <= port.width + 0.51 && g.height <= port.height + 0.51,
                   "the map stays inside the portrait pane (" + g.width.toFixed(0)
                   + "x" + g.height.toFixed(0) + " in " + port.width + "x" + port.height + ")")
            var gl = heat(bOvlL)
            verify(gl.width <= land.width + 0.51 && gl.height <= land.height + 0.51,
                   "…and inside the landscape one (" + gl.width.toFixed(0)
                   + "x" + gl.height.toFixed(0) + " in " + land.width + "x" + land.height + ")")
        }

        // The celebration banner is sized by the CARD. Asserted on the rendered
        // Text's own font.pixelSize, not on w.celebratePx: checking the property
        // only proves the arithmetic, and a Text that ignored it and re-froze a
        // literal would pass that untouched.
        function test_celebration_banner_is_sized_by_the_card_not_the_mode() {
            var base = bBase.item;   base.sizeClass = "compact"
            var micro = bMicro.item; micro.sizeClass = "compact"
            wait(0)
            function banner(host) {
                return root.findAll(host.item, function (n) {
                    return n.hasOwnProperty("maximumLineCount") && n.maximumLineCount === 2
                           && n.hasOwnProperty("font")
                }, [])[0]
            }
            var bBanner = banner(bBase)
            var mBanner = banner(bMicro)
            verify(bBanner && mBanner, "both banners resolve")
            compare(bBanner.font.pixelSize, Math.round(base.celebratePx),
                    "the rendered banner actually uses the derived size on a 1x1 tile")
            compare(mBanner.font.pixelSize, Math.round(micro.celebratePx),
                    "…and on a micro tile")
            verify(bBanner.font.pixelSize > mBanner.font.pixelSize,
                   "a 696x819 tile pops bigger than a 348x409 one - the banner reads "
                   + "the card, not the mode (" + bBanner.font.pixelSize + " vs "
                   + mBanner.font.pixelSize + ")")
            // It still has to FIT: it wraps to at most 2 lines inside the card.
            verify(bBanner.width <= base.width + 0.51,
                   "the banner stays inside the card (" + bBanner.width.toFixed(1)
                   + " in " + base.width + ")")
        }

        // The interaction survives the new size, at both projections.
        function test_checkin_button_stays_touch_sized_and_inside_both_projections() {
            var cases = [ { h: bRoomyP, sc: "tall", n: "1x1.5 portrait" },
                          { h: bRoomyL, sc: "wide", n: "1x1.5 landscape" } ]
            for (var i = 0; i < cases.length; i++) {
                var host = cases[i].h
                host.item.sizeClass = cases[i].sc
                seed(host)
                wait(16)
                var p = pill(host)
                verify(p && p.visible, cases[i].n + ": the check-in pill is present")
                verify(p.height >= host.theme.touchTertiary,
                       cases[i].n + ": …and touch-sized (" + p.height + ")")
                var pos = p.mapToItem(host.item, 0, 0)
                verify(pos.x >= 0 && pos.y >= 0
                       && pos.x + p.width <= host.item.width + 0.5
                       && pos.y + p.height <= host.item.height + 0.5,
                       cases[i].n + ": …and fully inside the tile (x=" + pos.x.toFixed(0)
                       + " y=" + pos.y.toFixed(0) + " in " + host.item.width
                       + "x" + host.item.height + ")")
            }
        }
    }
}
