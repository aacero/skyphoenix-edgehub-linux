import QtQuick
import QtTest
import "../ui" as UI
import "GuiUtil.js" as G

// All HydrationWidget compositor coverage lives in this fresh QuickTest process.
// Qt 6.11.1's QV4 engine can segfault in Object::insertMember when these Loader
// cases run after the large focus/habits suite has already churned through many
// widget shapes. This process boundary preserves the complete behavioral matrix
// and all visual evidence without discarding earlier test results on a runner
// crash.
Item {
    id: root
    width: 1400
    height: 760

    UI.WidgetHarness {
        id: wh
        x: 0
        y: 0
        width: 696
        height: 612
        widgetFile: ""
    }

    TestCase {
        id: tc
        name: "GuiWHydration"
        when: windowShown
        visible: true

        // Unicode MINUS SIGN (U+2212), matching the widget's pill label.
        readonly property string minusSign: "−"

        function snap(item, n) {
            var img = grabImage(item)
            img.save("gui-evidence/" + n + ".png")
            return img
        }

        function loadWidget() {
            wh.expanded = false
            wh.widgetFile = "HydrationWidget.qml"
            tryVerify(function () {
                return wh.ready && wh.item && wh.item.glassCols !== undefined
            }, 6000, "loaded HydrationWidget.qml")
        }
        function resetInst() {
            wh.storeCtl.resetSettings(wh.instanceId, {})
            wait(60)
        }
        function seed(obj) {
            wh.storeCtl.patchSettings(wh.instanceId, obj)
            wait(120)
        }
        function settings() {
            return wh.storeCtl.settingsFor(wh.instanceId)
        }
        function setSize(cls, w, h) {
            wh.width = w
            wh.height = h
            wh.item.sizeClass = cls
            wait(220)
        }

        function isPill(n) {
            try {
                return n && n.label !== undefined && n.glyph !== undefined
                       && n.clicked !== undefined
            } catch (e) {
                return false
            }
        }
        function pills(sub, exact) {
            return G.collectPred(wh.item, function (n) {
                if (!isPill(n) || !G.isLive(n))
                    return false
                var label = "" + n.label
                return exact ? label === sub : label.indexOf(sub) >= 0
            })
        }
        function pill(sub, exact) {
            var matches = pills(sub, exact)
            return matches.length ? matches[0] : null
        }
        function clickPill(sub, exact) {
            var target = pill(sub, exact)
            verify(target !== null, "found live pill '" + sub + "'")
            mouseClick(target, target.width / 2, target.height / 2)
            wait(220)
            return target
        }
        function vtext(sub) {
            return G.byText(wh.item, sub)
        }
        function backdrop() {
            return G.findPred(wh.item, function (n) {
                try {
                    return n && n.style !== undefined && n.accent !== undefined
                           && n.running !== undefined
                } catch (e) {
                    return false
                }
            })
        }
        function dropletCount() {
            return G.collectPred(wh.item, function (n) {
                try {
                    return n && n.objectName === "hydrationGlassIcon"
                           && n.visible && G.isLive(n)
                } catch (e) {
                    return false
                }
            }).length
        }
        function cornerPix(img) {
            return "" + img.pixel(20, Math.floor(img.height / 2))
        }
        function accentCheck(mode) {
            wh.item.cardBackdrop = "none"
            wh.item.accentName = ""
            wait(160)
            var base = cornerPix(snap(wh, "hyd_accent_base"))
            wh.item.accentName = "red"
            wait(160)
            var red = cornerPix(snap(wh, "hyd_accent_red"))
            if (mode === "override") {
                var distance = G.colorDist(base, red)
                verify(distance > 6,
                       "hyd: accent override tints card (dist "
                       + distance.toFixed(1) + ")")
                wh.item.accentName = ""
                return
            }
            wh.item.accentName = ""
            wait(160)
            var auto = cornerPix(snap(wh, "hyd_accent_auto"))
            var away = G.colorDist(auto, red)
            var back = G.colorDist(auto, base)
            verify(away > 6 && back < 6,
                   "hyd: accent Auto restores category colour (from red "
                   + away.toFixed(1) + ", to base " + back.toFixed(1) + ")")
        }
        function backdropCheck(style) {
            wh.item.accentName = ""
            wh.item.cardBackdrop = style
            wait(200)
            var layer = backdrop()
            verify(layer !== null, "hyd: BackdropLayer present")
            compare(layer.visible, style !== "none",
                    "hyd: backdrop '" + style + "' visible == "
                    + (style !== "none"))
            var img = snap(wh, "hyd_backdrop_" + style)
            verify(G.looksRendered(img),
                   "hyd: renders with backdrop " + style)
            wh.item.cardBackdrop = "none"
        }
        readonly property var backdropStyles: [
            "none", "orbs", "mesh", "aurora", "waves", "stars", "bokeh", "grid"
        ]

        function test_hydration_sizes_data() {
            return [
                { tag: "portrait-0.5x0.5",  cls: "compact", w: 348, h: 409 },
                { tag: "landscape-0.5x0.5", cls: "compact", w: 423, h: 306 },
                { tag: "portrait-0.5x1",    cls: "tall",    w: 348, h: 818 },
                { tag: "landscape-0.5x1",   cls: "wide",    w: 846, h: 306 },
                { tag: "portrait-1x0.5",    cls: "wide",    w: 696, h: 409 },
                { tag: "landscape-1x0.5",   cls: "tall",    w: 423, h: 612 },
                { tag: "portrait-1x1",      cls: "compact", w: 696, h: 818 },
                { tag: "landscape-1x1",     cls: "compact", w: 846, h: 612 }
            ]
        }
        function test_hydration_sizes(r) {
            loadWidget()
            resetInst()
            seed({ goal: 8, count: 3, day: wh.item.todayKey,
                   glassMl: 300, streak: 3, lastGoalDay: wh.item.todayKey })
            setSize(r.cls, r.w, r.h)
            var img = snap(wh, "hyd_size_" + r.tag)
            verify(G.looksRendered(img),
                   "hydration " + r.tag + " renders content")
            compare(wh.item.width, r.w, "hydration " + r.tag + " width")
            compare(wh.item.height, r.h, "hydration " + r.tag + " height")
            compare(dropletCount(), r.tag.indexOf("0.5x0.5") >= 0 ? 0 : 3,
                    "filled-glass grid is reserved for non-micro tiles")
            var details = G.byObjName(wh.item, "hydrationDetails")
            verify(details !== null, "hydration volume detail card exists")
            compare(details.visible, r.tag.indexOf("1x1") >= 0,
                    "1x1 earns volume consumed and remaining")
            verify(pill("Add", false) !== null || pill("+ ", false) !== null,
                   "one-tap serving logging remains available")
            var serving = G.byObjName(wh.item, "hydrationServing")
            verify(serving !== null && serving.visible,
                   "configured serving volume remains visible")
        }

        function test_hydration_config_goal() {
            var rows = [
                { tag: "6", goal: 6, expect: "of 6 glasses" },
                { tag: "3", goal: 3, expect: "of 3 glasses" }
            ]
            loadWidget()
            setSize("compact", 696, 612)
            for (var i = 0; i < rows.length; i++) {
                var r = rows[i]
                resetInst()
                seed({ goal: 8, count: 0, day: wh.item.todayKey })
                wh.storeCtl.setSetting(wh.instanceId, "goal", r.goal)
                wait(200)
                compare(wh.item.goal, r.goal, "goal setting reaches widget")
                verify(vtext(r.expect) !== null,
                       "count line reflects '" + r.expect + "'")
                snap(wh, "hyd_goal_" + r.tag)
            }
        }
        function test_hydration_config_title() {
            loadWidget()
            resetInst()
            seed({ goal: 8, count: 0, day: wh.item.todayKey })
            setSize("compact", 696, 612)
            wh.item.titleOverride = "Water"
            wait(160)
            verify(vtext("Water") !== null, "custom title renders in header")
            snap(wh, "hyd_title")
        }

        function test_hydration_body_plus() {
            loadWidget()
            resetInst()
            seed({ goal: 8, count: 2, day: wh.item.todayKey })
            setSize("compact", 696, 612)
            snap(wh, "hyd_plus_before")
            clickPill("Add", false)
            compare(settings().count, 3, "Add serving raises count to 3")
            snap(wh, "hyd_plus_after")
        }
        function test_hydration_body_undo() {
            loadWidget()
            resetInst()
            seed({ goal: 8, count: 2, previousCount: 1,
                   countUndoAvailable: true, day: wh.item.todayKey })
            setSize("compact", 696, 612)
            clickPill("Undo", true)
            compare(settings().count, 1, "Undo restores the previous count")
            snap(wh, "hyd_undo_after")
        }
        function test_hydration_body_overlay_glass() {
            loadWidget()
            resetInst()
            seed({ goal: 8, count: 0, day: wh.item.todayKey })
            setSize("compact", 696, 612)
            wh.expanded = true
            wait(220)
            var glasses = G.collectPred(wh.item, function (n) {
                try {
                    return n && n.bonus !== undefined && n.filled !== undefined
                           && G.isLive(n)
                } catch (e) {
                    return false
                }
            })
            verify(glasses.length >= 4,
                   "overlay renders tappable glasses (" + glasses.length + ")")
            var glass = glasses[3]
            mouseClick(glass, glass.width / 2, glass.height / 2)
            wait(220)
            compare(settings().count, 4,
                    "tapping the 4th glass sets count to 4")
            snap(wh, "hyd_overlay_glass")
        }
        function test_hydration_body_overlay_goal_minus() {
            loadWidget()
            resetInst()
            seed({ goal: 8, count: 0, day: wh.item.todayKey })
            setSize("compact", 696, 612)
            wh.expanded = true
            wait(220)
            clickPill(minusSign, true)
            compare(settings().goal, 7, "overlay goal − lowers goal to 7")
            snap(wh, "hyd_overlay_goal_minus")
        }
        function test_hydration_body_overlay_goal_plus() {
            loadWidget()
            resetInst()
            seed({ goal: 8, count: 0, day: wh.item.todayKey })
            setSize("compact", 696, 612)
            wh.expanded = true
            wait(220)
            clickPill("+", true)
            compare(settings().goal, 9, "overlay goal + raises goal to 9")
            snap(wh, "hyd_overlay_goal_plus")
        }

        function test_hydration_state_count_readout() {
            loadWidget()
            resetInst()
            seed({ goal: 8, count: 3, day: wh.item.todayKey })
            setSize("compact", 696, 612)
            verify(vtext("3 of 8 glasses") !== null,
                   "count/goal readout shown")
            snap(wh, "hyd_st_readout")
        }
        function test_hydration_state_grid_fill() {
            loadWidget()
            resetInst()
            seed({ goal: 6, count: 3, day: wh.item.todayKey })
            setSize("compact", 696, 612)
            compare(dropletCount(), 3, "3 filled droplets for count 3")
            snap(wh, "hyd_st_grid")
        }
        function test_hydration_state_goal_reached() {
            loadWidget()
            resetInst()
            seed({ goal: 2, count: 1, day: wh.item.todayKey })
            setSize("compact", 696, 612)
            snap(wh, "hyd_st_goal_before")
            clickPill("Add", false)
            compare(settings().count, 2, "reached goal")
            verify(vtext("Goal reached") !== null,
                   "goal-reached celebration fires")
            snap(wh, "hyd_st_goal_after")
        }
        function test_hydration_state_streak_line() {
            loadWidget()
            resetInst()
            seed({ goal: 8, count: 1, day: wh.item.todayKey,
                   streak: 3, lastGoalDay: wh.item.todayKey })
            setSize("compact", 696, 612)
            compare(wh.item.streakDisplay, 3,
                    "streak display resolves to 3")
            verify(vtext("3-day goal streak") !== null, "goal streak line shown")
            snap(wh, "hyd_st_streak")
        }
        function test_hydration_state_micro_number() {
            loadWidget()
            resetInst()
            seed({ goal: 8, count: 2, day: wh.item.todayKey })
            setSize("compact", 348, 306)
            verify(wh.item.micro === true, "micro at 0.5x0.5")
            verify(vtext("2/8") !== null, "micro shows compact count/goal")
            compare(dropletCount(), 0, "micro drops the glass grid")
            snap(wh, "hyd_st_micro")
        }
        function test_hydration_micro_celebration_does_not_cover_count() {
            loadWidget()
            resetInst()
            seed({ goal: 2, count: 1, day: wh.item.todayKey })
            setSize("compact", 348, 306)
            clickPill("+ ", false)
            var banner = G.byObjName(wh.item, "hydrationCelebration")
            var count = G.byObjName(wh.item, "hydrationCount")
            verify(banner !== null && banner.opacity > 0,
                   "micro celebration is currently visible")
            verify(count !== null && count.visible, "micro count is visible")
            var bp = banner.mapToItem(wh.item, 0, 0)
            var cp = count.mapToItem(wh.item, 0, 0)
            var separated = bp.y + banner.height <= cp.y
                            || cp.y + count.height <= bp.y
            verify(separated,
                   "celebration and primary count do not overlap (banner "
                   + Math.round(bp.y) + ".." + Math.round(bp.y + banner.height)
                   + ", count " + Math.round(cp.y) + ".."
                   + Math.round(cp.y + count.height) + ")")
            snap(wh, "hyd_st_micro_celebration")
        }
        function test_hydration_state_overfill() {
            loadWidget()
            resetInst()
            seed({ goal: 2, count: 3, day: wh.item.todayKey })
            setSize("compact", 696, 612)
            wh.expanded = true
            wait(220)
            verify(vtext("Goal exceeded") !== null,
                   "overfill bonus message shown")
            snap(wh, "hyd_st_overfill")
        }

        function test_hydration_chrome_accent_override() {
            loadWidget()
            resetInst()
            seed({ goal: 8, count: 3, day: wh.item.todayKey })
            setSize("compact", 696, 612)
            accentCheck("override")
        }
        function test_hydration_chrome_accent_auto() {
            loadWidget()
            resetInst()
            seed({ goal: 8, count: 3, day: wh.item.todayKey })
            setSize("compact", 696, 612)
            accentCheck("auto")
        }
        function test_hydration_chrome_backdrop_data() {
            return backdropStyles.map(function (style) {
                return { tag: style, style: style }
            })
        }
        function test_hydration_chrome_backdrop(r) {
            loadWidget()
            resetInst()
            seed({ goal: 8, count: 3, day: wh.item.todayKey })
            setSize("compact", 696, 612)
            backdropCheck(r.style)
        }

        function test_hydration_config_glass_ml() {
            var rows = [
                { tag: "300", ml: 300, count: 2, expect: "600 ml" },
                { tag: "500", ml: 500, count: 2, expect: "1.0 L" }
            ]
            loadWidget()
            setSize("compact", 696, 612)
            for (var i = 0; i < rows.length; i++) {
                var r = rows[i]
                wh.expanded = false
                resetInst()
                seed({ goal: 8, count: r.count, day: wh.item.todayKey,
                       glassMl: r.ml })
                wh.expanded = true
                wait(250)
                verify(vtext(r.expect) !== null,
                       "overlay volume shows '" + r.expect + "'")
                snap(wh, "hyd_glassml_" + r.tag)
                wh.expanded = false
                wait(180)
            }
        }
    }
}
