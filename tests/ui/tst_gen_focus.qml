import QtQuick
import QtTest
import "../../ui/qml" as App


// ─────────────────────────────────────────────────────────────────────────
// Comprehensive tests for widget:focus - ui/qml/widgets/FocusWidget.qml
// (the Focus / Pomodoro timer).
//
// Drives config through the shared DashboardStore (setSetting/patchSettings on
// "test-instance") exactly the way the live dashboard does, and asserts on the
// widget's derived properties + functions (cfg, phase, completedWork, remaining,
// ringValue, points, effAccent, advance()/skip()/reset()/applyPreset()/addFive()).
//
// Everything lives in ONE TestCase: this widget draws a per-second Canvas ring
// and restarts flash/celebration animations on every completion, and the
// offscreen scenegraph crashes at a TestCase boundary once enough of that state
// has accumulated - a single TestCase has no mid-run boundaries. active:false
// also keeps the widget's 1-second driving Timer OFF so it never auto-advances
// between assertions; every completion is driven by calling advance()/skip()
// directly, and `remaining` is derived from the absolute endEpoch (read on
// demand), so results stay correct.
//
// Some assertions encode the INTENDED behaviour and currently FAIL because of
// real bugs in the widget (skip counting as a completed session, Reset/preset
// wiping the daily count, custom accent not reaching the content, addFive NaN).
// Those failures are the point - they are left in. (The former ">= goal"
// re-celebration bug is now fixed: the bonus fires once, on the crossing session.)
// ─────────────────────────────────────────────────────────────────────────
Item {
    id: root
    width: 480; height: 820
    property int notificationCalls: 0
    property string notificationSummary: ""
    property string notificationBody: ""

    QtObject {
        id: fakeNotifier
        function send(summary, body) {
            root.notificationCalls++
            root.notificationSummary = summary
            root.notificationBody = body
            return true
        }
    }
    App.WidgetConfigSchema { id: schemaRegistry }

    WidgetHarness {
        id: hFocus; anchors.fill: parent
        widgetFile: "FocusWidget.qml"; expanded: true; active: false
    }

    // Fixed-size hosts for the per-sizeClass structure tests (W1 wave 3) - the
    // REAL projected footprints of the two sizes focus declares (half-cell ≈
    // 348x409 portrait / 423x306 landscape, per WidgetSizes):
    //   1x1    → 696x819 portrait · 846x612 landscape   (compact in BOTH: the
    //            class comes from half-cells, not from the pixel aspect)
    //   1x1.5  → 696x1228 portrait (tall) · 1269x612 landscape (wide)
    // They live in this file's ONE TestCase on purpose (see the header note on
    // the scenegraph crash at TestCase boundaries).
    Item { id: sizeWrap; width: 696; height: 819
        WidgetHarness { id: hSize; anchors.fill: parent
            widgetFile: "FocusWidget.qml"; expanded: false; active: false } }
    // The OVERLAY host, resized between the two boxes Dashboard actually gives it:
    // the live-preview pane beside the config form, ~941x456 landscape and
    // ~656x980 portrait. `expanded: true` AND sizeClass "full" - the real pairing
    // Dashboard produces - because a mode-keyed literal can only be caught with
    // the mode switched ON. One host, resized, rather than two: this widget's
    // per-second Canvas ring is exactly the state the header warns about.
    Item { id: ovlWrap; width: 941; height: 456
        WidgetHarness { id: hOvl; anchors.fill: parent
            widgetFile: "FocusWidget.qml"; expanded: true; active: false } }

    function findAll(node, pred, acc) {
        if (!node) return acc
        if (pred(node)) acc.push(node)
        var kids = node.children
        for (var i = 0; kids && i < kids.length; i++) root.findAll(kids[i], pred, acc)
        return acc
    }
    // PillButtons that are actually on screen (the tile's control row).
    function visiblePills(item) {
        return root.findAll(item, function (n) {
            return n.hasOwnProperty("label") && n.hasOwnProperty("glyph")
                   && n.hasOwnProperty("primary") && n.visible && n.width > 0
        }, [])
    }
    function pillLabels(item) {
        var ps = root.visiblePills(item), out = []
        for (var i = 0; i < ps.length; i++) out.push(ps[i].label)
        return out
    }
    // The tile's ring (RingProgress carries progressColor + thickness).
    function tileRing(item) {
        var rs = root.findAll(item, function (n) {
            return n.hasOwnProperty("progressColor") && n.hasOwnProperty("thickness")
                   && n.visible && n.width > 0
        }, [])
        return rs.length ? rs[0] : null
    }

    function pad(n) { return (n < 10 ? "0" : "") + n }
    function dayString(d) { return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate()) }
    function todayStr() { return dayString(new Date()) }
    function offsetDay(n) { var d = new Date(); d.setDate(d.getDate() + n); return dayString(d) }

    TestCase {
        name: "Focus"
        when: windowShown

        function initTestCase() { tryVerify(function () { return hFocus.ready }, 3000) }

        // Fresh, known state before every test.
        function init() {
            // Replace the settings bucket instead of repeatedly deleting and
            // reinserting differently shaped members on one QV4 object. Keep
            // the full production shape stable too: Qt 6.11 corrupts its
            // property cache after enough differently shaped replacements.
            hFocus.storeCtl.resetSettings("test-instance", {
                preset: "classic",
                workMin: 25,
                breakMin: 5,
                longBreakMin: 15,
                longBreakEvery: 4,
                behaviorProfile: "custom",
                autoStartBreak: false,
                autoStartFocus: false,
                notifyWhenHidden: false,
                dailyGoal: 4,
                celebrate: true,
                rewardPoints: true,
                showNudges: true,
                breakSuggestions: true,
                phase: "work",
                running: false,
                endEpoch: 0,
                pausedRemaining: 1500,
                doneToday: 0,
                day: "",
                points: 0
            })
            hFocus.item.accentName = ""
            hFocus.item.celebrateMsg = ""
            hFocus.item.foreground = true
            hFocus.item.notificationBridge = fakeNotifier
            root.notificationCalls = 0
            root.notificationSummary = ""
            root.notificationBody = ""
        }

        // ── Per-sizeClass structure (W1 wave 3) ────────────────────────────
        // Dashboard injects sizeClass; the widget must key layout off it and
        // must not collapse the two declared sizes into one stretched layout.
        function shape(w, h, cls) {
            tryVerify(function () { return hSize.ready }, 3000)
            sizeWrap.width = w; sizeWrap.height = h
            hSize.item.sizeClass = cls
            wait(32)
            return hSize.item
        }

        // 1x1 - the ring + a real control row, and NOTHING else: no room is
        // left over to earn the stats block.
        function test_1x1_is_ring_plus_controls_only() {
            var w = shape(696, 819, "compact")
            compare(w.micro, false, "a 696x819 compact box is the baseline third, not the half-cell")
            compare(w.showHeader, false, "the tile stays headerless - the ring is the content")
            compare(w.horiz, false, "stacked")
            compare(w.showMomentum, false, "1x1 does not pretend to have room for the stats block")
            compare(root.pillLabels(w).sort(), ["Skip", "Start"],
                    "1x1 offers exactly Start + Skip - no third button squeezed in")
        }

        // The clock is sized from the RING, not a 34px cap floating in the box.
        function test_1x1_clock_is_sized_from_the_ring_not_a_fixed_cap() {
            var w = shape(696, 819, "compact")
            var ring = root.tileRing(w)
            verify(ring !== null, "the tile draws a ring")
            verify(ring.width > 400, "the ring fills the baseline box (" + ring.width + "px)")
            var clock = root.findAll(w, function (n) {
                return n.hasOwnProperty("font") && String(n.text) === w.fmt(w.remaining) && n.visible
            }, [])
            verify(clock.length >= 1, "the clock is rendered")
            verify(clock[0].font.pixelSize > 34,
                   "the clock scales with the ring (" + clock[0].font.pixelSize
                   + "px), it does not cap at the old 34px")
        }

        // ── size, not mode ──────────────────────────────────────────────────
        // The celebration banner was `expanded ? 34 : 18`. It spans the whole
        // CARD, so the card is what sizes it.
        //
        // This widget gets ONLY the overlay-pane test, not the usual "hold the
        // mode fixed and move the room" sibling, and that is a real gap rather
        // than an oversight: focus declares 1x1 and 1x1.5, whose four projections
        // (696x819, 846x612, 696x1228, 1269x612) ALL reach the 34px ceiling, so a
        // tile-vs-tile comparison would be 34 > 34 dressed up as a guard. The
        // panes below are the boxes where the term genuinely binds.
        //
        // Both reads are expanded AND "full"; only the BOX differs - the real
        // live-preview panes beside the config form, NOT a 2560x720 screen. A
        // literal returns one number for both, so asserting the two differ is
        // exactly the mode/size conflation, caught. (Holding the mode at false
        // instead would NOT catch it: a surviving `w.expanded ? 34 : 18` never
        // fires its literal there and the else-branch keeps the assertion green.)
        function test_overlay_banner_is_sized_by_its_pane_not_by_a_mode_literal() {
            tryVerify(function () { return hOvl.ready }, 3000)
            var w = hOvl.item
            w.sizeClass = "full"
            w.celebrateMsg = "🎉 Session done!"
            function banner() {
                return root.findAll(w, function (n) {
                    return n.hasOwnProperty("font") && String(n.text) === w.celebrateMsg
                           && n.z === 20 }, [])[0]
            }
            // A real event-loop turn, not wait(0): this host defaults to "tall"
            // (height > 240) and only becomes "full" above, and a wait(0) read
            // reports pre-change geometry. waitForRendering is not the tool -
            // offscreen never swaps a frame.
            ovlWrap.width = 941; ovlWrap.height = 456
            wait(16)
            compare(w.expanded, true, "precondition: this IS the overlay")
            var landPx = w.celebratePx
            var landRendered = banner().font.pixelSize
            // RENDERED, not merely derived: a Text that ignored celebratePx and
            // re-froze a literal would pass a property-only check untouched.
            compare(landRendered, Math.round(landPx),
                    "the rendered landscape banner is the derived size, not a literal")

            ovlWrap.width = 656; ovlWrap.height = 980
            wait(16)
            var portPx = w.celebratePx
            var portRendered = banner().font.pixelSize
            compare(portRendered, Math.round(portPx),
                    "…and so is the portrait one")

            verify(landPx !== portPx,
                   "the overlay's banner is sized by the pane it is given, not by one "
                   + "literal for 'the overlay' (941x456 -> " + landPx.toFixed(1)
                   + ", 656x980 -> " + portPx.toFixed(1) + ")")
            verify(portRendered > landRendered,
                   "the 980-tall pane earns the bigger pop (" + portRendered
                   + " vs " + landRendered + ")")
            ovlWrap.width = 941; ovlWrap.height = 456
        }

        // The audit's collision: the ring must stop ABOVE the control row rather
        // than run under buttons anchored over its bottom arc.
        function test_1x1_ring_does_not_run_under_the_control_row() {
            var sizes = [[696, 819], [846, 612]]   // portrait · landscape
            for (var i = 0; i < sizes.length; i++) {
                var w = shape(sizes[i][0], sizes[i][1], "compact")
                var ring = root.tileRing(w)
                var pills = root.visiblePills(w)
                verify(pills.length >= 2, "controls are on the tile")
                var ringBottom = w.mapFromItem(ring, 0, ring.height).y
                var pillTop = w.mapFromItem(pills[0], 0, 0).y
                verify(ringBottom <= pillTop + 1,
                       sizes[i][0] + "x" + sizes[i][1] + ": ring ends at " + ringBottom
                       + ", controls start at " + pillTop + " - no overlap")
            }
        }

        // The stacked control row sits under the MIDDLE of the ring, not hugged
        // against the left edge (a Layout.alignment on the stats column would
        // cancel its fillWidth and collapse it - caught on the real panel).
        function test_stacked_controls_are_centred_under_the_ring() {
            var cases = [[696, 819, "compact"], [696, 1228, "tall"]]
            for (var i = 0; i < cases.length; i++) {
                var w = shape(cases[i][0], cases[i][1], cases[i][2])
                var pills = root.visiblePills(w)
                var left = w.mapFromItem(pills[0], 0, 0).x
                var last = pills[pills.length - 1]
                var right = w.mapFromItem(last, last.width, 0).x
                var mid = (left + right) / 2
                verify(Math.abs(mid - w.width / 2) < 24,
                       cases[i][2] + ": control row centres at " + mid
                       + ", tile centre is " + (w.width / 2))
            }
        }

        // Every tile control stays a real touch target (the old compact row
        // forced implicitHeight: 36, under the token).
        function test_tile_controls_meet_the_touch_minimum() {
            var cases = [[696, 819, "compact"], [696, 1228, "tall"], [1269, 612, "wide"]]
            for (var i = 0; i < cases.length; i++) {
                var w = shape(cases[i][0], cases[i][1], cases[i][2])
                var pills = root.visiblePills(w)
                verify(pills.length >= 2, cases[i][2] + " has controls")
                for (var j = 0; j < pills.length; j++)
                    verify(pills[j].height >= hSize.theme.touchTertiary,
                           cases[i][2] + " control '" + pills[j].label + "' is "
                           + pills[j].height + "px >= " + hSize.theme.touchTertiary)
            }
        }

        // 1x1.5 portrait - the extra half-third buys the overlay's momentum
        // readout for the tile, plus the +5 control.
        function test_1x1_5_tall_earns_the_momentum_readout() {
            // hSize is its own harness with its own store - patch THAT one.
            hSize.storeCtl.patchSettings("test-instance",
                { doneToday: 2, day: root.todayStr(), points: 30, dailyGoal: 4 })
            var w = shape(696, 1228, "tall")
            compare(w.tallish, true)
            compare(w.horiz, false, "portrait 1x1.5 stacks")
            compare(w.showMomentum, true, "tall earns the stats block")
            compare(root.pillLabels(w).sort(), ["+5", "Skip", "Start"],
                    "tall has the width for the +5 a running timer reaches for")
            var stats = root.findAll(w, function (n) {
                return n.hasOwnProperty("text") && String(n.text) === "2 / 4 today" && n.visible
            }, [])
            compare(stats.length, 1, "the sessions/goal line is on the TILE, not only the overlay")
        }

        function test_1x1_5_adds_a_session_runway_not_only_empty_space() {
            hSize.storeCtl.patchSettings("test-instance",
                { phase: "work", doneToday: 0, day: root.todayStr(), preset: "classic",
                  running: false, pausedRemaining: 1500 })
            var w = shape(696, 1228, "tall")
            var runway = root.findAll(w, function (n) {
                return n.objectName === "focusRunway" && n.visible
            }, [])
            compare(runway.length, 1, "the hero tile uses its extra room for a visible session runway")
            verify(root.findAll(runway[0], function (n) {
                return n.hasOwnProperty("text") && String(n.text) === "Short break"
            }, []).length === 1, "the runway previews what comes next")
            verify(root.findAll(runway[0], function (n) {
                return n.hasOwnProperty("text") && String(n.text) === "Session 1 / 4"
            }, []).length === 1, "the runway places this focus inside its Pomodoro cycle")

            w = shape(696, 819, "compact")
            runway = root.findAll(w, function (n) {
                return n.objectName === "focusRunway" && n.visible
            }, [])
            compare(runway.length, 0, "the baseline tile keeps the simpler ring and controls")
        }

        // The stats must stay ATTACHED to the ring they describe: the tall box
        // has ~450px the width-bound ring cannot spend, and that slack belongs
        // above/below the group, not between the ring and its own caption.
        function test_1x1_5_tall_keeps_the_stats_attached_to_the_ring() {
            var w = shape(696, 1228, "tall")
            var ring = root.tileRing(w)
            var pills = root.visiblePills(w)
            var ringBottom = w.mapFromItem(ring, 0, ring.height).y
            var last = pills[pills.length - 1]
            var controlsBottom = w.mapFromItem(last, 0, last.height).y
            // The gap the ring leaves under itself is real air, not a void: the
            // whole group is centred, so there is slack left BELOW the controls.
            verify(w.height - controlsBottom > 40,
                   "the group is centred, not dropped on the bottom edge (slack below: "
                   + (w.height - controlsBottom) + "px)")
            verify(controlsBottom - ringBottom < 260,
                   "stats+controls stay under the ring (gap " + (controlsBottom - ringBottom) + "px)")
        }

        // 1x1.5 landscape - the SAME content, laid beside the ring instead of a
        // centred ring with ~350px of air either side.
        function test_1x1_5_wide_puts_the_stats_beside_the_ring() {
            var w = shape(1269, 612, "wide")
            compare(w.horiz, true, "landscape 1x1.5 goes side-by-side")
            compare(w.showMomentum, true, "the same content the tall projection earns")
            var ring = root.tileRing(w)
            var pills = root.visiblePills(w)
            // Beside, not below: the controls start to the RIGHT of the ring.
            var ringRight = w.mapFromItem(ring, ring.width, 0).x
            var pillLeft = w.mapFromItem(pills[0], 0, 0).x
            verify(pillLeft >= ringRight - 1,
                   "controls sit right of the ring (ring ends " + ringRight
                   + ", controls start " + pillLeft + ")")
            verify(ring.width <= 612, "the ring keeps a square cell bounded by the box height")
        }

        function patch(o) { hFocus.storeCtl.patchSettings("test-instance", o) }
        function cfg() { return hFocus.storeCtl.settingsFor("test-instance") }

        // ── Pure helpers / formatting ──────────────────────────────────────
        function test_fmt_pads_minutes_seconds() {
            var w = hFocus.item
            compare(w.fmt(0), "00:00")
            compare(w.fmt(90), "01:30")
            compare(w.fmt(1500), "25:00")
            compare(w.fmt(5), "00:05")
        }
        function test_phase_labels() {
            var w = hFocus.item
            patch({ phase: "work" });  compare(w.phaseLabel(), "Focus")
            patch({ phase: "short" }); compare(w.phaseLabel(), "Short Break")
            patch({ phase: "long" });  compare(w.phaseLabel(), "Long Break")
        }
        function test_classic_preset_durations() {
            var w = hFocus.item
            patch({ preset: "classic" })
            compare(w.phaseSeconds("work"), 25 * 60)
            compare(w.phaseSeconds("short"), 5 * 60)
            compare(w.phaseSeconds("long"), 15 * 60)
        }
        function test_today_matches_local_date() {
            compare(hFocus.item.today(), todayStr())
        }

        // ── Skip vs natural completion (advance's `natural` flag) ──────────
        // BUG (high): skip() during a focus phase counts as a completed session.
        function test_skip_focus_does_not_count_or_reward() {
            var w = hFocus.item
            patch({ phase: "work", day: todayStr(), doneToday: 0, points: 0,
                    celebrate: true, rewardPoints: true })
            w.celebrateMsg = ""
            w.skip()
            compare(cfg().doneToday, 0, "Skip must NOT increment the completed-session count")
            compare(cfg().points || 0, 0, "Skip must NOT award points")
            compare(w.celebrateMsg, "", "Skip must NOT fire a celebration")
        }
        function test_skip_requires_a_second_tap() {
            var w = hFocus.item
            patch({ phase: "work", day: todayStr(), doneToday: 0 })
            w.requestSkip()
            compare(w.skipArmed, true, "first tap arms the guarded action")
            compare(cfg().phase, "work", "first tap does not change phase")
            w.requestSkip()
            compare(w.skipArmed, false, "confirmation disarms the action")
            compare(cfg().phase, "short", "second tap advances to the break")
        }
        // Natural completion of a focus phase (advance(true)) is the correct path.
        function test_natural_focus_completion_counts_once() {
            var w = hFocus.item
            patch({ phase: "work", day: todayStr(), doneToday: 0, points: 0,
                    rewardPoints: true })
            w.advance(true)
            compare(cfg().doneToday, 1, "one natural completion → exactly +1")
            compare(cfg().points, 10, "one natural completion → +10 points")
        }
        // Skip during a break must move to work WITHOUT awarding points.
        function test_skip_break_advances_without_reward() {
            var w = hFocus.item
            patch({ phase: "short", day: todayStr(), doneToday: 2, points: 20,
                    rewardPoints: true })
            w.skip()
            compare(cfg().phase, "work", "break → work")
            compare(cfg().points, 20, "no points for leaving a break")
            compare(cfg().doneToday, 2, "count unchanged leaving a break")
        }

        // ── Reset / preset switch must preserve the daily count ────────────
        // BUG (medium): Reset zeroes doneToday.
        function test_reset_keeps_daily_count() {
            var w = hFocus.item
            patch({ phase: "work", day: todayStr(), doneToday: 3, points: 30 })
            w.reset()
            compare(cfg().doneToday, 3, "Reset restarts the timer, not the day's session count")
        }
        function test_reset_restarts_timer_to_work() {
            var w = hFocus.item
            patch({ phase: "short", day: todayStr(), running: true,
                    endEpoch: Date.now() + 100000 })
            w.reset()
            compare(cfg().phase, "work", "Reset returns to a work phase")
            compare(cfg().running, false, "Reset leaves the timer paused")
        }
        // BUG (medium): switching preset zeroes doneToday.
        function test_preset_switch_keeps_daily_count() {
            var w = hFocus.item
            patch({ phase: "work", day: todayStr(), doneToday: 2 })
            w.applyPreset("deep")
            compare(cfg().preset, "deep", "preset was applied")
            compare(cfg().doneToday, 2, "changing preset must preserve today's count")
        }
        // BUG (low): reset() zeroes doneToday but leaves points → inconsistent
        // momentum state. If doneToday is reset, points should be too.
        function test_reset_leaves_points_and_count_consistent() {
            var w = hFocus.item
            patch({ phase: "work", day: todayStr(), doneToday: 3, points: 30 })
            w.reset()
            if ((cfg().doneToday || 0) === 0)
                compare(cfg().points || 0, 0,
                        "if Reset clears the count it must also clear points")
        }

        // ── Date / midnight math ────────────────────────────────────────────
        function test_completedWork_zero_on_stale_day() {
            var w = hFocus.item
            patch({ day: offsetDay(-1), doneToday: 4 })
            compare(w.completedWork, 0, "yesterday's count does not count as today's")
        }
        function test_completedWork_reflects_today() {
            var w = hFocus.item
            patch({ day: todayStr(), doneToday: 3 })
            compare(w.completedWork, 3)
        }
        // Completing after the day has rolled restarts the count at 1, not +1.
        function test_new_day_completion_resets_to_one() {
            var w = hFocus.item
            patch({ phase: "work", day: offsetDay(-1), doneToday: 4, points: 0,
                    rewardPoints: true, celebrate: false })
            w.advance(true)
            compare(cfg().doneToday, 1, "post-midnight completion restarts at 1")
            compare(cfg().day, todayStr(), "day rolls forward to today")
        }

        // ── Reward points + goal celebration ────────────────────────────────
        function test_reaching_goal_awards_bonus() {
            var w = hFocus.item
            // doneToday 3, goal 4 → this completion is #4, exactly the goal.
            patch({ phase: "work", day: todayStr(), doneToday: 3, points: 0,
                    dailyGoal: 4, rewardPoints: true, celebrate: true })
            w.celebrateMsg = ""
            w.advance(true)
            compare(cfg().points, 60, "goal session awards +10 and +50 bonus")
            verify(w.celebrateMsg.indexOf("Goal") >= 0, "goal celebration fired")
        }
        // The goal bonus/celebration is ONE-TIME: it fires only on the session
        // that crosses the goal (done === dailyGoal). A session that merely
        // exceeds an already-reached goal earns the ordinary +10, no second +50
        // and no "Goal reached!" re-celebration.
        function test_goal_bonus_does_not_refire_when_exceeding() {
            var w = hFocus.item
            patch({ phase: "work", day: todayStr(), doneToday: 4, points: 0,
                    dailyGoal: 3, rewardPoints: true, celebrate: true })
            w.celebrateMsg = ""
            w.advance(true)   // done becomes 5 (already past goal 3) → +10 only
            compare(cfg().points, 10, "a session past the goal earns +10, not another +50")
            verify(w.celebrateMsg.indexOf("Goal") < 0, "no goal re-celebration past the goal")
        }
        // rewardPoints=false → no accumulation.
        function test_reward_points_off_stops_accumulation() {
            var w = hFocus.item
            patch({ phase: "work", day: todayStr(), doneToday: 0, points: 0,
                    rewardPoints: false })
            w.advance(true)
            compare(cfg().points || 0, 0, "no points accrue when rewards are disabled")
            compare(w.rewardPoints, false, "points display is gated off too")
        }

        function test_calm_profile_disables_momentum_features() {
            var w = hFocus.item
            patch({ behaviorProfile: "calm", celebrate: true, rewardPoints: true, showNudges: true })
            compare(w.celebrate, false)
            compare(w.rewardPoints, false)
            compare(w.showNudges, false)
        }

        function test_momentum_profile_enables_momentum_features() {
            var w = hFocus.item
            patch({ behaviorProfile: "momentum", celebrate: false, rewardPoints: false, showNudges: false })
            compare(w.celebrate, true)
            compare(w.rewardPoints, true)
            compare(w.showNudges, true)
        }

        function test_effective_reduce_motion_disables_celebration_motion() {
            var w = hFocus.item
            hFocus.theme.reduceMotionPreference = "on"
            compare(w.celebrationMotionEnabled, false)
            compare(hFocus.theme.motionFast, 0)
            compare(hFocus.theme.motionPage, 0)
            hFocus.theme.reduceMotionPreference = "auto"
        }
        // celebrate=false → no celebration message on completion.
        function test_celebrate_off_suppresses_message() {
            var w = hFocus.item
            patch({ phase: "work", day: todayStr(), doneToday: 0, celebrate: false })
            w.celebrateMsg = ""
            w.advance(true)
            compare(w.celebrateMsg, "", "no celebration when celebrate is disabled")
        }

        function test_hidden_focus_completion_notifies_when_enabled() {
            var w = hFocus.item
            patch({ phase: "work", notifyWhenHidden: true, day: todayStr(), doneToday: 0 })
            w.foreground = false
            w.advance(true)
            compare(root.notificationCalls, 1)
            compare(root.notificationSummary, "Focus session complete")
            compare(root.notificationBody, "Your short break is ready.")
        }
        function test_visible_completion_does_not_notify() {
            var w = hFocus.item
            patch({ phase: "work", notifyWhenHidden: true, day: todayStr(), doneToday: 0 })
            w.foreground = true
            w.advance(true)
            compare(root.notificationCalls, 0, "visible Hub screen does not duplicate feedback")
        }
        function test_hidden_notification_is_opt_in() {
            var w = hFocus.item
            patch({ phase: "work", notifyWhenHidden: false, day: todayStr(), doneToday: 0 })
            w.foreground = false
            w.advance(true)
            compare(root.notificationCalls, 0)
        }
        function test_hidden_break_completion_announces_focus() {
            var w = hFocus.item
            patch({ phase: "short", notifyWhenHidden: true, day: todayStr(), doneToday: 1 })
            w.foreground = false
            w.advance(true)
            compare(root.notificationCalls, 1)
            compare(root.notificationSummary, "Break complete")
            compare(root.notificationBody, "Ready for another focus session.")
        }

        // ── Per-instance accent override reaches the content ────────────────
        // BUG (medium): the highlight content (ring/digits/label/Start) is
        // coloured by phaseColor()==catProductivity, NOT effAccent, so a custom
        // per-instance accent recolours only the chrome header.
        function test_custom_accent_recolours_focus_content() {
            var w = hFocus.item
            patch({ phase: "work" })
            w.accentName = "pink"
            compare(w.effAccent.toString().toLowerCase(),
                    hFocus.theme.accentPresets["pink"].a.toString().toLowerCase(),
                    "effAccent picks up the custom preset")
            compare(w.phaseColor().toString().toLowerCase(), w.effAccent.toString().toLowerCase(),
                    "focus highlight content should follow the custom accent")
        }

        // ── addFive: paused vs running, NaN guard, ring underflow ───────────
        function test_addfive_paused_extends_by_300() {
            var w = hFocus.item
            patch({ preset: "classic", phase: "work", running: false })
            wait(60)   // let any idle-duration sync settle
            patch({ pausedRemaining: 600 })
            compare(w.remaining, 600)
            w.addFive()
            compare(w.remaining, 900, "paused +5 extends remaining by exactly 300s")
        }
        function test_addfive_running_extends_by_300() {
            var w = hFocus.item
            patch({ preset: "classic", phase: "work", running: true,
                    endEpoch: Date.now() + 600 * 1000 })
            var before = w.remaining
            w.addFive()
            var delta = w.remaining - before
            verify(delta >= 298 && delta <= 302,
                   "running +5 extends remaining by ~300s (got " + delta + ")")
        }
        // BUG (low): addFive while running with a missing endEpoch → NaN/null.
        function test_addfive_running_without_endEpoch_no_nan() {
            var w = hFocus.item
            patch({ preset: "classic", phase: "work", running: true, pausedRemaining: 600 })
            delete hFocus.storeCtl.settingsFor("test-instance").endEpoch
            hFocus.storeCtl._touchSettings()
            w.addFive()
            var e = cfg().endEpoch
            verify(e !== null && e !== undefined && !isNaN(e),
                   "endEpoch stays a valid number after +5 (got " + e + ")")
        }
        // ringValue must never go below 0 even when +5 pushes remaining past the
        // phase's nominal length (denominator grows via Math.max).
        function test_ringvalue_never_underflows() {
            var w = hFocus.item
            patch({ preset: "custom", workMin: 1, phase: "work", running: false })
            wait(60)   // idle sync sets pausedRemaining to the 60s phase length
            compare(w.phaseTotal, 60)
            compare(w.remaining, 60)
            w.addFive()
            compare(w.remaining, 360, "+5 pushes remaining well past the 60s phase")
            verify(w.ringValue >= 0, "ringValue is clamped at/above 0 (got " + w.ringValue + ")")
            compare(w.ringValue, 0, "ring reads full-remaining (0 elapsed), not negative")
        }

        // ── autoStartBreak + phase progression ──────────────────────────────
        function test_autostart_break_off_pauses_at_break() {
            var w = hFocus.item
            patch({ preset: "classic", phase: "work", day: todayStr(),
                    doneToday: 0, autoStartBreak: false })
            w.advance(true)
            compare(cfg().phase, "short", "1st completion → short break")
            compare(cfg().running, false, "break waits to be started")
        }
        function test_autostart_break_on_runs_break() {
            var w = hFocus.item
            patch({ preset: "classic", phase: "work", day: todayStr(),
                    doneToday: 0, autoStartBreak: true })
            w.advance(true)
            compare(cfg().phase, "short", "1st completion → short break")
            compare(cfg().running, true, "break auto-starts")
        }
        function test_every_fourth_is_long_break() {
            var w = hFocus.item
            // classic every=4: 4th completed work session → long break.
            patch({ preset: "classic", phase: "work", day: todayStr(),
                    doneToday: 3, autoStartBreak: false })
            w.advance(true)
            compare(cfg().phase, "long", "4th session leads into a long break")
        }

        function test_custom_long_break_duration_and_cadence() {
            var w = hFocus.item
            patch({ preset: "custom", workMin: 20, breakMin: 4, longBreakMin: 12,
                    longBreakEvery: 2, phase: "work", day: todayStr(), doneToday: 1 })
            compare(w.phaseSeconds("long"), 12 * 60)
            w.advance(true)
            compare(cfg().phase, "long")
        }

        function test_autostart_focus_is_independent() {
            var w = hFocus.item
            patch({ phase: "short", autoStartFocus: true, running: false })
            w.advance(true)
            compare(cfg().phase, "work")
            compare(cfg().running, true)
        }
        function test_break_completion_returns_to_work_paused() {
            var w = hFocus.item
            patch({ preset: "classic", phase: "short", day: todayStr(),
                    doneToday: 1, autoStartBreak: true })
            w.advance(true)
            compare(cfg().phase, "work", "break → work")
            compare(cfg().running, false, "work phase never auto-starts after a break")
        }

        // ── Every schema key changes observable behaviour ───────────────────
        function test_workMin_drives_custom_focus_length() {
            var w = hFocus.item
            patch({ preset: "custom", workMin: 30, breakMin: 5 })
            compare(w.phaseSeconds("work"), 30 * 60)
        }
        function test_breakMin_and_longBreakMin_drive_custom_breaks() {
            var w = hFocus.item
            patch({ preset: "custom", workMin: 40, breakMin: 8, longBreakMin: 12 })
            compare(w.phaseSeconds("short"), 8 * 60, "short break uses breakMin")
            compare(w.phaseSeconds("long"), 12 * 60, "long break uses longBreakMin")
            compare(w.phaseSeconds("work"), 40 * 60, "focus uses workMin")
        }
        function test_dailyGoal_honored() {
            var w = hFocus.item
            patch({ dailyGoal: 7 })
            compare(w.dailyGoal, 7)
        }
        function test_showNudges_honored() {
            var w = hFocus.item
            patch({ showNudges: false })
            compare(w.showNudges, false)
            patch({ showNudges: true })
            compare(w.showNudges, true)
        }
        function test_breakSuggestions_honored() {
            var w = hFocus.item
            patch({ breakSuggestions: false })
            compare(w.breakSuggestions, false)
        }
        function test_autoStartBreak_honored() {
            var w = hFocus.item
            patch({ autoStartBreak: true })
            compare(w.autoStartBreak, true)
        }
        function test_custom_duration_schema_is_conditional() {
            var schema = schemaRegistry.schemaFor("focus")
            var keys = ["workMin", "breakMin", "longBreakMin", "longBreakEvery"]
            for (var i = 0; i < keys.length; i++) {
                var found = null
                for (var s = 0; s < schema.sections.length; s++) {
                    var fields = schema.sections[s].fields || []
                    for (var f = 0; f < fields.length; f++)
                        if (fields[f].key === keys[i]) found = fields[f]
                }
                verify(found !== null, keys[i] + " exists")
                compare(found.visibleWhen.key, "preset")
                compare(found.visibleWhen.equals, "custom")
            }
        }
        function test_preset_selection_changes_durations() {
            var w = hFocus.item
            patch({ preset: "deep" })
            compare(w.p.work, 50, "deep focus is 50 min")
            compare(w.phaseSeconds("work"), 50 * 60)
            patch({ preset: "sprint" })
            compare(w.p.work, 15, "sprint focus is 15 min")
        }

        // ── Persistence / reactivity of the running timer ───────────────────
        // remaining is derived from an absolute endEpoch, so it is correct across
        // a long background gap (past-due session reads 0, not negative).
        function test_remaining_from_absolute_endEpoch() {
            var w = hFocus.item
            patch({ phase: "work", running: true, endEpoch: Date.now() + 100 * 1000 })
            verify(w.remaining >= 98 && w.remaining <= 100,
                   "remaining tracks endEpoch (got " + w.remaining + ")")
        }
        function test_remaining_clamps_to_zero_after_gap() {
            var w = hFocus.item
            patch({ phase: "work", running: true, endEpoch: Date.now() - 5000 })
            compare(w.remaining, 0, "a session whose end is in the past reads 0, never negative")
        }
        function test_running_state_survives_expand_toggle() {
            var w = hFocus.item
            patch({ phase: "work", running: true, endEpoch: Date.now() + 200 * 1000 })
            var before = w.remaining
            hFocus.expanded = false
            hFocus.expanded = true
            verify(Math.abs(w.remaining - before) <= 2,
                   "collapsing/expanding does not disturb the running timer")
            compare(cfg().running, true)
        }
        function test_start_pause_toggle() {
            var w = hFocus.item
            patch({ phase: "work", running: false, pausedRemaining: 300 })
            w.toggle()   // start
            compare(cfg().running, true, "toggle from paused starts")
            verify(cfg().endEpoch > Date.now(), "start sets an endEpoch in the future")
            w.toggle()   // pause
            compare(cfg().running, false, "toggle again pauses")
            verify(cfg().pausedRemaining > 0, "pause snapshots remaining")
        }
    }
}
