import QtQuick
import QtTest
import "../../ui/qml" as App

// COVERS: fn:Dashboard._tileExists, fn:Dashboard.applyAppearance, fn:Dashboard.applyExternalState, fn:Dashboard.cfgAction, fn:Dashboard.closeExpanded
// COVERS: fn:Dashboard.onAccentNameChanged, fn:Dashboard.onAnimatedBackgroundChanged, fn:Dashboard.onGlassOpacityChanged, fn:Dashboard.onOrientationModeChanged, fn:Dashboard.onReduceMotionChanged, fn:Dashboard.onShowWidgetGlowChanged
// COVERS: fn:Dashboard.onThemeModeChanged, fn:Dashboard.onTextScaleChanged, fn:Dashboard.onFontChoiceChanged, fn:Dashboard.applyPreset, fn:Dashboard.appendPreset
// COVERS: fn:Dashboard.requestPageRemoval, fn:Dashboard.confirmPageRemoval
// COVERS: fn:Dashboard.requestWidgetRemoval, fn:Dashboard.confirmWidgetRemoval
// COVERS: fn:Dashboard.requestWidgetDataAction, fn:Dashboard.confirmWidgetDataAction
// COVERS: fn:Dashboard.showPriorityAlert, fn:Dashboard.dismissPriorityAlert, fn:Dashboard.triggerPriorityAlertAction
// COVERS: fn:Dashboard._openPriorityAlertWidget, fn:Dashboard._priorityAlertWidget, fn:Dashboard._invokePriorityAlertWidget, fn:Dashboard.prunePriorityAlerts
// COVERS: fn:Dashboard._sweepStaleDying
//
// ui/qml/Dashboard.qml -
//   • cfgAction: geocode-with-place, empty-place, non-geocode action, no overlay
//   • closeExpanded: clears all overlay state, idempotent
//   • applyExternalState: valid doc updates the store + re-applies appearance;
//     malformed doc is ignored (no throw); a live push that drops the expanded
//     tile closes the overlay
//   • _tileExists: present id / unknown id / empty id
//   • applyAppearance: pushes accent/glass/glow/reduceMotion/themeMode/animatedBg/
//     orientation to the shell (root) + theme
//   • WidgetHost: tile/overlay bindings track the store + shell, and exactly one
//     Hub view is the active state driver
//   • the 7 appearance→store Connections handlers (root change → store.setAppearance)
//
// Dashboard resolves the shell (`root`), `theme`, and `metricsJson` through the
// context scope - we provide them here exactly as main.qml does, then load the
// REAL Dashboard.qml via a Loader (as the app's StackView does). We reach its
// private DashboardStore by duck-typing the object graph. Assertions target the
// driving properties/store, never rendered pixels.
Item {
    id: root
    width: 900; height: 600

    // Shell (main.qml root) surface Dashboard binds to.
    property alias theme: _theme
    App.Theme { id: _theme }
    App.WidgetSizes { id: _sizes }
    App.WidgetCatalog { id: _catalog }
    property string accentName: "blue"
    property real glassOpacity: 0.5
    property bool showWidgetGlow: true
    property bool reduceMotion: false
    property string themeMode: "dark"
    property bool animatedBackground: true
    property string orientationMode: "auto"
    property real textScale: 1.15
    property string fontChoice: "hyperlegible"
    property string metricsJson: "{}"
    property string screensData: "[]"

    // Recorder for the geocode delegate handed to cfgAction.
    property string geocodedPlace: ""

    Loader {
        id: ld
        anchors.fill: parent
        source: "../../ui/qml/Dashboard.qml"
    }

    // ── tree helpers ─────────────────────────────────────────────────────────
    function eachItem(node, fn) {
        if (!node) return
        fn(node)
        var kids = node.children
        if (kids) for (var i = 0; i < kids.length; i++) eachItem(kids[i], fn)
    }
    function findPred(n, pred) {
        var f = null
        eachItem(n, function (x) { if (!f && pred(x)) f = x })
        return f
    }
    property var _store: null
    function store() {
        if (!_store)
            _store = findPred(ld.item, function (x) {
                return x && x.applyExternal !== undefined && x.structureRevision !== undefined
            })
        return _store
    }

    function makeDoc(tileList) {
        return JSON.stringify({ version: 1, appearance: {}, settings: {},
            pages: [ { name: "P1", tiles: tileList } ] })
    }

    // ── Layout probes ────────────────────────────────────────────────────────
    // The page delegates (each carries its page's packing) and the tile delegates
    // (each carries the placement it was positioned from), duck-typed out of the
    // object graph. Note EVERY page is instantiated by the SwipeView, so tileCells()
    // spans the whole document, not just the current page.
    function pageItems() {
        var out = []
        eachItem(ld.item, function (x) {
            if (x && x.placements !== undefined && x.longExtent !== undefined
                  && x.addPlacement !== undefined) out.push(x)
        })
        return out
    }
    function pageItem() { var ps = pageItems(); return ps.length ? ps[0] : null }
    function pageFlick() {
        return findPred(ld.item, function (x) { return x && x.cellShort !== undefined && x.cellLong !== undefined })
    }
    function tileCells() {
        var out = []
        eachItem(ld.item, function (x) {
            if (x && x._r !== undefined && x.tileId !== undefined
                  && x.tileSize !== undefined && x.ps !== undefined) out.push(x)
        })
        return out
    }
    function cellFor(id) {
        var cs = tileCells()
        for (var i = 0; i < cs.length; i++) if (cs[i].tileId === id) return cs[i]
        return null
    }
    function widgetHostsFor(id) {
        var out = []
        eachItem(ld.item, function (x) {
            if (x && x.widgetId !== undefined && x.driverActive !== undefined
                    && x.widgetId === id) out.push(x)
        })
        return out
    }
    // The edit-mode "Add widget" slot: the one placed box on a page that is not a
    // tile, so it carries the eased slot mirror but none of the tile roles. (Its
    // Loader exists whether or not edit mode is open; only its content is gated.)
    function addSlot() {
        return findPred(ld.item, function (x) {
            return x && x.animL !== undefined && x.tileId === undefined
        })
    }
    // A cell's placement, reassembled from the roles it is built from - the shape
    // WidgetPacker speaks, which is what the slot assertions below compare in.
    function slotOf(c) {
        return ({ id: c.tileId, type: c.tileType, size: c.tileSize, idx: c.tileIdx,
                  s: c.ps, l: c.pl, es: c.pes, el: c.pel })
    }
    // True once the page has laid out N tiles with real geometry, in `portrait`,
    // and every one of them has SETTLED.
    //
    // "Settled" is load-bearing, and it is why the geometry tests below can trust
    // a pixel. A tile now MOVES to its slot and fades in or out around it, so a
    // page can satisfy "N tiles with real geometry" while every one of them is
    // still in flight - and a tile measured mid-glide is a third of the screen
    // only by luck. (These tests reuse ids across documents: `init()` drops the
    // previous page and the test re-adds `a`/`b`/`c` in the same event, which the
    // model correctly reads as those tiles MOVING, not as new ones appearing.)
    // A tile is settled when its eased mirror has reached the slot it mirrors and
    // it is at full opacity - i.e. when the pixels mean what the packing says.
    function laidOut(n, portrait) {
        var f = pageFlick()
        if (!f || !(f.cellLong > 0)) return false
        if ((f.height > f.width) !== portrait) return false
        var cs = tileCells()
        if (cs.length !== n) return false
        for (var i = 0; i < n; i++) {
            var c = cs[i]
            if (!(c.width > 0 && c.height > 0)) return false
            if (c.animS !== c.ps || c.animL !== c.pl
                || c.animEs !== c.pes || c.animEl !== c.pel) return false   // still moving
            if (c.opacity !== 1) return false                               // still fading
        }
        return true
    }
    // Make the dashboard PORTRAIT (tall: the 720x2560 reflow) or LANDSCAPE (the
    // 2560x720 strip). Dashboard reads its own width/height - exactly as main.qml's
    // contentRoot hands it over on a rotation.
    function orient(portrait) {
        root.width = portrait ? 720 : 2560
        root.height = portrait ? 2560 : 720
    }

    TestCase {
        name: "Dashboard"
        when: windowShown

        function initTestCase() {
            tryVerify(function () { return ld.status === Loader.Ready && ld.item !== null }, 5000)
            verify(root.store() !== null, "found Dashboard's private DashboardStore")
        }

        function init() {
            var d = ld.item
            root.store().load("blank")
            d.closeExpanded()
            d.cfgStatus = ""
            if (d.pageDeleteDialog.visible) d.pageDeleteDialog.close()
            if (d.widgetRemoveDialog.visible) d.widgetRemoveDialog.close()
            if (d.widgetDataDialog.visible) d.widgetDataDialog.close()
            while (d.dismissPriorityAlert()) {}
        }

        function childInsideSurface(child, surface) {
            var p = child.mapToItem(surface, 0, 0)
            return p.x >= 0 && p.y >= 0
                    && p.x + child.width <= surface.width + 1
                    && p.y + child.height <= surface.height + 1
        }

        function waitForChildInsideSurface(child, surface, timeoutMs) {
            var deadline = Date.now() + timeoutMs
            while (Date.now() < deadline) {
                if (childInsideSurface(child, surface))
                    return true
                wait(20)
            }
            return childInsideSurface(child, surface)
        }

        function containmentDiagnostic(label, child, surface) {
            var p = child.mapToItem(surface, 0, 0)
            return label + " mapped=(" + p.x + "," + p.y + ")"
                    + " size=(" + child.width + "x" + child.height + ")"
                    + " surface=(" + surface.width + "x" + surface.height + ")"
        }

        function test_save_failure_banner_is_visible_and_touch_safe() {
            var banner = findPred(ld.item, function (x) {
                return x && x.objectName === "saveFailureBanner"
            })
            var retry = findPred(ld.item, function (x) {
                return x && x.objectName === "retryFailedSaveButton"
            })
            var discard = findPred(ld.item, function (x) {
                return x && x.objectName === "discardFailedSaveButton"
            })
            var messageScroll = findPred(ld.item, function (x) {
                return x && x.objectName === "saveFailureMessageScroll"
            })
            var message = findPred(ld.item, function (x) {
                return x && x.objectName === "saveFailureMessage"
            })
            verify(banner, "the Hub save-failure banner exists")
            verify(retry, "the Hub save-failure banner exposes Retry")
            verify(discard, "the Hub save-failure banner exposes Discard")
            verify(messageScroll, "the Hub save-failure message is scrollable")
            verify(message, "the Hub save-failure message exists")

            var orientations = [
                { portrait: false, width: 2560, height: 720 },
                { portrait: true, width: 720, height: 2560 }
            ]
            for (var i = 0; i < orientations.length; i++) {
                root.width = orientations[i].width
                root.height = orientations[i].height
                root.store().markSaveFailed(
                    "The latest dashboard changes could not be saved.")
                tryVerify(function () {
                    return banner.visible
                           && retry.width >= 52 && retry.height >= 52
                           && discard.width >= 52 && discard.height >= 52
                           && banner.x >= 0 && banner.y >= 0
                           && banner.x + banner.width <= ld.item.width + 1
                           && banner.y + banner.height <= ld.item.height + 1
                }, 1000)
                verify(waitForChildInsideSurface(retry, banner, 1000),
                       containmentDiagnostic(
                           "Retry must stay fully inside the warning surface.",
                           retry, banner))
                verify(waitForChildInsideSurface(discard, banner, 1000),
                       containmentDiagnostic(
                           "Discard must stay fully inside the warning surface.",
                           discard, banner))
                verify(retry.visible && discard.visible,
                        "both recovery actions remain visible in either orientation")
                root.store().saveFailed = false
            }

            var longFailure = Array(121).join(
                "The save destination rejected this dashboard change. ")
            for (var longIndex = 0; longIndex < orientations.length; longIndex++) {
                root.width = orientations[longIndex].width
                root.height = orientations[longIndex].height
                root.store().markSaveFailed(longFailure)
                tryVerify(function () {
                    return banner.visible
                           && message.implicitHeight > messageScroll.height
                           && banner.y + banner.height <= ld.item.height + 1
                }, 1000)
                verify(waitForChildInsideSurface(messageScroll, banner, 1000),
                       containmentDiagnostic(
                           "Long save details stay inside a scrollable viewport.",
                           messageScroll, banner))
                verify(waitForChildInsideSurface(retry, banner, 1000),
                       containmentDiagnostic(
                           "Retry stays reachable with long save details.",
                           retry, banner))
                verify(waitForChildInsideSurface(discard, banner, 1000),
                       containmentDiagnostic(
                           "Discard stays reachable with long save details.",
                           discard, banner))
                root.store().saveFailed = false
            }

            root.width = 900
            root.height = 600
            root.store().markSaveFailed("Retry this change.")
            tryVerify(function () { return banner.visible }, 1000)
            retry.clicked()
            compare(root.store().dirty, false,
                    "a successful Hub retry clears the dirty state")
            compare(root.store().saveFailed, false,
                    "a successful Hub retry hides the banner")

            root.store().markSaveFailed("Discard this change.")
            tryVerify(function () { return banner.visible }, 1000)
            discard.clicked()
            compare(root.store().dirty, false)
            compare(root.store().saveFailed, false,
                    "discard reloads the committed/default layout and hides the banner")
        }

        function test_priority_alert_is_persistent_deduplicated_and_actionable() {
            var d = ld.item
            verify(d.showPriorityAlert({
                key: "break:one",
                title: "Time to take a real break",
                body: "Step away for a moment.",
                detail: "Try: Stand up and stretch",
                iconName: "break",
                primaryLabel: "I took a break",
                secondaryLabel: "Snooze 5 min",
                primaryAction: "dismiss"
            }))
            tryVerify(function () { return d.priorityAlertSurface.shown }, 1000)
            compare(d.priorityAlertQueue.length, 1)
            verify(d.showPriorityAlert({
                key: "break:one", title: "Duplicate", body: "Ignored"
            }))
            compare(d.priorityAlertQueue.length, 1,
                    "the same reminder cannot stack duplicate alerts")
            wait(600)
            compare(d.priorityAlertSurface.shown, true,
                    "there is no auto-dismiss timer")
            compare(d.priorityAlertPrimaryButton.label, "I took a break")
            compare(d.priorityAlertSecondaryButton.label, "Snooze 5 min")
            verify(d.priorityAlertPrimaryButton.height >= 52)
            verify(d.priorityAlertSecondaryButton.height >= 52)
            verify(d.priorityAlertDismissButton.height >= 52)

            verify(d.triggerPriorityAlertAction("primary"))
            compare(d.priorityAlertQueue.length, 0)
        }

        function test_priority_alert_fits_portrait_and_landscape() {
            var d = ld.item
            var card = findPred(d, function(item) {
                return item && item.objectName === "priorityAlertCard"
            })
            verify(card !== null)
            var cases = [
                { portrait: true },
                { portrait: false }
            ]
            for (var i = 0; i < cases.length; i++) {
                orient(cases[i].portrait)
                verify(d.showPriorityAlert({
                    key: "visual-" + i,
                    title: "Time to take a real break",
                    body: "Step away for a moment. This reminder stays visible until you choose.",
                    detail: "Try: Stand up and stretch",
                    iconName: "break",
                    primaryLabel: "I took a break",
                    secondaryLabel: "Snooze 5 min"
                }))
                tryVerify(function() {
                    return d.priorityAlertSurface.shown
                           && card.width > 0 && card.height > 0
                }, 1000)
                verify(card.x >= 0 && card.y >= 0)
                verify(card.x + card.width <= d.width + 1)
                verify(card.y + card.height <= d.height + 1)
                var primaryPoint = d.priorityAlertPrimaryButton.mapToItem(
                    card, 0, 0)
                var dismissPoint = d.priorityAlertDismissButton.mapToItem(
                    card, 0, 0)
                verify(primaryPoint.x >= 0 && primaryPoint.y >= 0)
                verify(primaryPoint.x + d.priorityAlertPrimaryButton.width
                       <= card.width + 1)
                verify(primaryPoint.y + d.priorityAlertPrimaryButton.height
                       <= card.height + 1)
                verify(dismissPoint.x >= 0 && dismissPoint.y >= 0)
                verify(dismissPoint.x + d.priorityAlertDismissButton.width
                       <= card.width + 1)
                verify(d.dismissPriorityAlert())
            }
            root.width = 900
            root.height = 600
        }

        function test_priority_alert_queue_keeps_the_next_reminder() {
            var d = ld.item
            verify(d.showPriorityAlert({
                key: "first", title: "First reminder", body: "First body"
            }))
            verify(d.showPriorityAlert({
                key: "second", title: "Second reminder", body: "Second body"
            }))
            compare(d.priorityAlertQueue.length, 2)
            compare(d.currentPriorityAlert.title, "First reminder")
            verify(d.dismissPriorityAlert())
            compare(d.priorityAlertQueue.length, 1)
            compare(d.currentPriorityAlert.title, "Second reminder")
            compare(d.priorityAlertSurface.shownAlert.title, "Second reminder",
                    "the visible card advances with the queue")
            verify(d.dismissPriorityAlert())
            compare(d.currentPriorityAlert, null)
        }

        function test_priority_alert_queue_is_bounded_and_keeps_oldest() {
            var d = ld.item
            for (var i = 0; i < d.maxPriorityAlerts; i++) {
                verify(d.showPriorityAlert({
                    key: "bounded-" + i,
                    title: "Reminder " + i,
                    body: "Pending action " + i
                }))
            }
            compare(d.priorityAlertQueue.length, d.maxPriorityAlerts)
            compare(d.currentPriorityAlert.key, "bounded-0")
            verify(!d.showPriorityAlert({
                key: "bounded-overflow",
                title: "Overflow",
                body: "Use the desktop fallback"
            }))
            compare(d.priorityAlertQueue.length, d.maxPriorityAlerts)
            compare(d.currentPriorityAlert.key, "bounded-0",
                    "new arrivals cannot displace an unacknowledged reminder")
            while (d.dismissPriorityAlert()) {}
        }

        function test_priority_alert_can_open_its_source_widget() {
            var d = ld.item
            var s = root.store()
            var id = s.addTile(0, "focus")
            verify(id !== null)
            verify(d._openPriorityAlertWidget({
                sourceId: id,
                widgetType: "focus"
            }), "_openPriorityAlertWidget opens a valid source")
            d.closeExpanded()
            verify(d.showPriorityAlert({
                key: "focus:" + id,
                sourceId: id,
                widgetType: "focus",
                title: "Focus session complete",
                body: "Your break is ready.",
                primaryLabel: "Open timer",
                primaryAction: "openWidget"
            }))
            verify(d.triggerPriorityAlertAction("primary"))
            compare(d.expandedId, id)
            compare(d.expandedType, "focus")
            compare(d.priorityAlertQueue.length, 0)
            d.closeExpanded()
        }

        function test_break_alert_action_targets_the_current_widget_after_rebuild() {
            var d = ld.item
            var first = JSON.stringify({
                version: 1,
                appearance: {},
                settings: {
                    "break-live": {
                        due: true,
                        running: true,
                        breaksToday: 0,
                        priorityAlertEnabled: true
                    }
                },
                pages: [ {
                    name: "First",
                    tiles: [
                        { id: "break-live", type: "break", size: "1x1" }
                    ]
                } ]
            })
            d.applyExternalState(first)
            var originalHost = null
            tryVerify(function () {
                var hosts = root.widgetHostsFor("break-live")
                for (var i = 0; i < hosts.length; i++) {
                    if (hosts[i].driverActive && hosts[i].item) {
                        originalHost = hosts[i]
                        break
                    }
                }
                return originalHost !== null
            }, 3000)
            compare(d._priorityAlertWidget({
                        sourceId: "break-live", widgetType: "break"
                    }), originalHost.item,
                    "_priorityAlertWidget selects the active source instance")
            verify(originalHost.item.showPriorityAlert())
            compare(d.priorityAlertQueue.length, 1)
            compare(d.currentPriorityAlert.primaryAction, "breakTake")
            compare(d.currentPriorityAlert.primaryCallback, undefined,
                    "the persistent queue stores no widget-bound closure")

            var rebuilt = JSON.stringify({
                version: 1,
                appearance: {},
                settings: {
                    "break-live": {
                        due: true,
                        running: true,
                        breaksToday: 0,
                        priorityAlertEnabled: true
                    }
                },
                pages: [ {
                    name: "Rebuilt",
                    tiles: [
                        { id: "clock-new", type: "clock", size: "1x1" },
                        { id: "break-live", type: "break", size: "1x1" }
                    ]
                } ]
            })
            d.applyExternalState(rebuilt)
            var replacementHost = null
            tryVerify(function () {
                var hosts = root.widgetHostsFor("break-live")
                for (var i = 0; i < hosts.length; i++) {
                    if (hosts[i].driverActive && hosts[i].item) {
                        replacementHost = hosts[i]
                        break
                    }
                }
                return replacementHost !== null
            }, 3000)
            compare(d.priorityAlertQueue.length, 1,
                    "a retained source keeps its persistent reminder")
            compare(d._priorityAlertWidget({
                        sourceId: "break-live", widgetType: "break"
                    }), replacementHost.item,
                    "_priorityAlertWidget follows the current rebuilt instance")
            verify(d.triggerPriorityAlertAction("primary"), "_invokePriorityAlertWidget routes the real break action to the current widget")
            compare(d.priorityAlertQueue.length, 0,
                    "a handled break action dismisses its persistent reminder")
            var saved = root.store().settingsFor("break-live")
            compare(saved.due, false)
            compare(saved.breaksToday, 1,
                    "the action reached the replacement widget, not a stale closure")
        }

        function test_priority_alert_prunes_a_removed_source() {
            var d = ld.item
            var s = root.store()
            var id = s.addTile(0, "break")
            verify(d.showPriorityAlert({
                key: "break:" + id,
                sourceId: id,
                widgetType: "break",
                title: "Break reminder",
                body: "Take a break."
            }))
            compare(d.priorityAlertQueue.length, 1)
            s.removeTile(0, id)
            tryVerify(function () { return d.priorityAlertQueue.length === 0 }, 1000)
            compare(d.prunePriorityAlerts(), 0,
                    "prunePriorityAlerts reports the remaining queue size")
        }

        function test_configuration_reset_keeps_personal_content() {
            var d = ld.item, s = root.store()
            var id = s.addTile(0, "tasks")
            s.patchSettings(id, {
                items: [ { id: "task-1", text: "Keep me", done: false } ],
                nextId: 2,
                celebrate: false,
                accent: "gold"
            })
            d.expandedId = id
            d.expandedType = "tasks"
            verify(d.requestWidgetDataAction("reset"))
            verify(d.widgetDataDialog.visible)
            verify(d.widgetDataSummary.text.indexOf("tasks and their ordering will be kept") >= 0)
            verify(d.widgetDataCancelButton.height >= 48)
            verify(d.widgetDataConfirmButton.height >= 48)
            verify(d.confirmWidgetDataAction())
            var got = s.settingsFor(id)
            compare(got.items.length, 1)
            compare(got.items[0].text, "Keep me")
            compare(got.nextId, 2)
            compare(got.celebrate, undefined, "configuration was reset")
            compare(got.accent, undefined, "appearance override was reset")
            d.widgetDataDialog.close()
        }

        function test_personal_erase_keeps_widget_configuration() {
            var d = ld.item, s = root.store()
            var id = s.addTile(0, "tasks")
            s.patchSettings(id, {
                items: [ { id: "task-1", text: "Erase me", done: false } ],
                nextId: 2,
                celebrate: false,
                accent: "gold"
            })
            d.expandedId = id
            d.expandedType = "tasks"
            verify(d.requestWidgetDataAction("erase"))
            verify(d.widgetDataSummary.text.indexOf("This cannot be undone") >= 0)
            verify(d.confirmWidgetDataAction())
            var got = s.settingsFor(id)
            compare(got.items, undefined)
            compare(got.nextId, undefined)
            compare(got.celebrate, false, "configuration was kept")
            compare(got.accent, "gold", "appearance was kept")
            d.widgetDataDialog.close()
        }

        function test_personal_erase_is_unavailable_for_stateless_widget() {
            var d = ld.item, s = root.store()
            var id = s.addTile(0, "cpu")
            d.expandedId = id
            d.expandedType = "cpu"
            compare(d.requestWidgetDataAction("erase"), false)
            compare(d.widgetDataDialog.visible, false)
        }

        function test_widget_removal_requires_an_exact_named_confirmation() {
            var d = ld.item, s = root.store()
            var id = s.addTile(0, "tasks")
            s.setSetting(id, "items", [
                { id: "task-1", text: "Do not remove by accident", done: false }
            ])

            verify(d.requestWidgetRemoval(0, id, "tasks"))
            verify(d.widgetRemoveDialog.visible)
            verify(d.widgetRemoveSummary.text.indexOf("Tasks") >= 0)
            verify(d.widgetRemoveSummary.text.indexOf("tasks and their ordering") >= 0)
            verify(d.widgetRemoveSummary.text.indexOf("unsaved text") >= 0)
            verify(d.widgetRemoveCancelButton.height >= 48)
            verify(d.widgetRemoveConfirmButton.height >= 48)
            verify(d._tileExists(id), "requesting removal changes nothing")

            verify(d.confirmWidgetRemoval())
            verify(!d._tileExists(id))
            compare(s.settingsFor(id).items, undefined,
                    "confirmed removal deletes the widget settings bucket")
            d.widgetRemoveDialog.close()
        }

        function test_widget_removal_refuses_a_stale_confirmation() {
            var d = ld.item, s = root.store()
            var id = s.addTile(0, "notes")
            verify(d.requestWidgetRemoval(0, id, "notes"))
            s.addTile(0, "clock")

            verify(!d.confirmWidgetRemoval())
            verify(d._tileExists(id), "a changed screen keeps the reviewed widget")
            verify(d.widgetRemovalError.indexOf("changed") >= 0)
            d.widgetRemoveDialog.close()
        }

        function test_page_removal_requires_named_confirmation() {
            var d = ld.item, s = root.store()
            s.renamePage(0, "Home")
            s.addPage("Ops")
            var widgetId = s.addTile(1, "cpu")
            verify(widgetId !== null)
            s.setSetting(widgetId, "goal", 99)
            compare(s.pageCount(), 2)

            verify(d.requestPageRemoval(1), "a removable screen opens confirmation")
            compare(s.pageCount(), 2, "requesting removal changes nothing")
            compare(d.pendingPageRemovalName, "Ops")
            compare(d.pendingPageRemovalWidgetCount, 1)
            verify(d.pageDeleteDialog.visible, "confirmation is visible")
            var summary = d.pageDeleteSummary
            verify(summary.text.indexOf("Ops") >= 0, "screen name is stated")
            verify(summary.text.indexOf("1 widget") >= 0, "widget count is stated")

            verify(d.confirmPageRemoval(), "reviewed screen is removed")
            compare(s.pageCount(), 1)
            compare(s.settingsFor(widgetId).goal, undefined,
                    "the removed widget bucket is no longer addressable")
            d.pageDeleteDialog.close()
        }

        function test_page_removal_refuses_stale_confirmation() {
            var d = ld.item, s = root.store()
            s.addPage("Ops")
            verify(d.requestPageRemoval(1))
            s.addTile(1, "cpu")
            compare(d.confirmPageRemoval(), false,
                    "a changed layout cannot delete the formerly reviewed screen")
            compare(s.pageCount(), 2)
            verify(d.pageRemovalError.indexOf("changed") >= 0)
            d.pageDeleteDialog.close()
        }

        function test_last_screen_cannot_request_removal() {
            var d = ld.item, s = root.store()
            compare(s.pageCount(), 1)
            compare(d.requestPageRemoval(0), false)
            compare(d.pageDeleteDialog.visible, false)
        }

        function test_page_removal_buttons_are_touch_sized() {
            var d = ld.item, s = root.store()
            s.addPage("Ops")
            verify(d.requestPageRemoval(1))
            var cancel = d.pageDeleteCancelButton
            var confirm = d.pageDeleteConfirmButton
            verify(cancel !== null && confirm !== null)
            verify(cancel.height >= 48, "Cancel is at least 48 pixels tall")
            verify(confirm.height >= 48, "Remove is at least 48 pixels tall")
            d.pageDeleteDialog.close()
        }

        // Wallpaper rendering must not become an uncounted network client. Remote,
        // protocol-relative, data and custom schemes are rejected; local and qrc
        // sources remain available.
        function test_wallpaper_source_is_local_only() {
            var d = ld.item
            root.store().setAppearance("wallpaper", "https://tracker.example/pixel.png")
            compare(d.wallpaperSource, "", "https wallpaper cannot bypass NetHub")
            root.store().setAppearance("wallpaper", "//tracker.example/pixel.png")
            compare(d.wallpaperSource, "", "protocol-relative wallpaper is remote too")
            root.store().setAppearance("wallpaper", "data:image/png;base64,AAAA")
            compare(d.wallpaperSource, "", "data URLs are not accepted from config")
            var local = Qt.resolvedUrl("../../assets/wallpapers/aurora.png")
            root.store().setAppearance("wallpaper", local)
            compare(d.wallpaperSource, local, "an existing local file remains valid")
        }

        // ── cfgAction ─────────────────────────────────────────────────────────
        function test_cfgAction_geocode_with_place() {
            var d = ld.item
            root.geocodedPlace = ""
            d.expandedId = "wx"
            root.store().setSetting("wx", "place", "Paris")
            d.overlayLoaderItem = ({ geocode: function (p) { root.geocodedPlace = p } })
            d.cfgAction("geocode")
            compare(root.geocodedPlace, "Paris", "cfgAction invoked the geocode delegate with the place")
            compare(d.cfgStatus.indexOf("Searching"), 0, "status shows the search is running")
        }

        function test_cfgAction_empty_place_prompts() {
            var d = ld.item
            d.expandedId = "wx"
            root.store().setSetting("wx", "place", "   ")     // whitespace → empty
            d.overlayLoaderItem = ({ geocode: function (p) { root.geocodedPlace = p } })
            root.geocodedPlace = "SENTINEL"
            d.cfgAction("geocode")
            compare(d.cfgStatus, "Type a place name first.", "empty place is rejected")
            compare(root.geocodedPlace, "SENTINEL", "geocode was NOT called")
        }

        function test_cfgAction_non_geocode_is_noop() {
            var d = ld.item
            d.cfgStatus = ""
            d.expandedId = "wx"
            d.overlayLoaderItem = ({ geocode: function (p) { root.geocodedPlace = p } })
            d.cfgAction("save")           // not the geocode branch
            compare(d.cfgStatus, "", "a non-geocode action changes nothing")
        }

        function test_cfgAction_without_overlay_is_noop() {
            var d = ld.item
            d.cfgStatus = ""
            d.overlayLoaderItem = null
            d.cfgAction("geocode")        // no overlay item → guarded out
            compare(d.cfgStatus, "", "geocode with no overlay does nothing")
        }

        // ── expanded overlay: content is retained through the close fade (W3) ──
        // closeExpanded() clears the STATE immediately, but the overlay's widget,
        // title and icon must keep rendering while the card fades out - keyed off
        // the retained shownType/shownId - or the close pops to an empty card on
        // frame 1. The retained pair clears only once the overlay is fully hidden.
        function test_overlay_content_survives_the_close_fade() {
            var d = ld.item
            _theme.reduceMotion = false
            d.applyExternalState(root.makeDoc([ { id: "ov1", type: "cpu" } ]))
            d.expandedId = "ov1"; d.expandedType = "cpu"
            compare(d.shownType, "cpu", "opening synced the retained type")
            compare(d.shownId, "ov1", "opening synced the retained id")
            // Let the overlay genuinely fade IN before closing - closing within
            // the same event-loop turn would find opacity still at 0 (no frame
            // has run), which is not a state a user can ever produce.
            var ovl = root.findPred(ld.item, function (x) { return x && x.ovlWide !== undefined })
            verify(ovl !== null, "found the expanded overlay")
            tryCompare(ovl, "opacity", 1.0, 2000, "overlay fully shown")
            d.closeExpanded()
            verify(!d.hasExpanded, "the state machine closed immediately")
            compare(d.shownType, "cpu", "…but the overlay CONTENT is retained for the fade")
            compare(d.shownId, "ov1", "id retained with it")
            tryCompare(d, "shownType", "", 2000, "retained type drops once the fade completes")
            compare(d.shownId, "", "retained id drops with it")
        }

        function test_overlay_retained_state_clears_instantly_under_reduce_motion() {
            var d = ld.item
            _theme.reduceMotion = true
            d.expandedId = "rm1"; d.expandedType = "cpu"
            compare(d.shownType, "cpu", "opened")
            d.closeExpanded()
            // 100ms < the 150ms motion-on fade: only a genuinely collapsed
            // transition can pass this window.
            tryCompare(d, "shownType", "", 100, "reduce-motion: no fade, cleared at once")
            _theme.reduceMotion = false
        }

        // ── edit mode: the tile scrim eases in/out instead of hard-cutting ─────
        function test_edit_scrim_fades_in_and_out() {
            var d = ld.item
            _theme.reduceMotion = false
            d.applyExternalState(root.makeDoc([ { id: "e1", type: "cpu" } ]))
            tryVerify(function () { return root.tileCells().length === 1 }, 4000, "tile laid out")
            var cell = root.tileCells()[0]
            var scrim = null
            for (var i = 0; i < cell.children.length; i++)
                if (cell.children[i].z === 30) scrim = cell.children[i]
            verify(scrim !== null, "found the per-tile edit scrim")
            compare(scrim.visible, false, "hidden outside edit mode")

            d.editMode = true
            // Sampled synchronously on the mode flip: the ease has only just
            // started, so anything < 1.0 proves it is a fade, not a hard cut.
            verify(scrim.opacity < 1.0, "easing in, not a hard cut (opacity " + scrim.opacity + ")")
            tryCompare(scrim, "opacity", 1.0, 2000, "…and settles fully shown")
            verify(scrim.visible, "fully visible in edit mode")

            d.editMode = false
            verify(scrim.visible, "still rendering while it fades back out")
            tryCompare(scrim, "visible", false, 2000, "gone once the fade completes")
        }

        // ── closeExpanded ─────────────────────────────────────────────────────
        function test_closeExpanded_clears_and_is_idempotent() {
            var d = ld.item
            d.expandedType = "cpu"; d.expandedId = "x1"
            d.cfgStatus = "busy"; d.overlayLoaderItem = ({ geocode: function () {} })
            verify(d.hasExpanded, "precondition: overlay open")
            d.closeExpanded()
            compare(d.expandedType, "", "type cleared")
            compare(d.expandedId, "", "id cleared")
            compare(d.cfgStatus, "", "status cleared")
            compare(d.overlayLoaderItem, null, "overlay item cleared")
            verify(!d.hasExpanded, "closeExpanded cleared the expanded state")
            d.closeExpanded()             // second call must not throw
            verify(!d.hasExpanded, "closeExpanded is idempotent (still closed after a second call)")
        }

        function test_closeExpanded_keeps_a_failed_editor_live_for_retry() {
            var d = ld.item
            d.applyExternalState(root.makeDoc([
                { id: "draft1", type: "braindump", size: "1x1" }
            ]))
            d.expandedId = "draft1"
            d.expandedType = "braindump"

            var overlayHost = null
            tryVerify(function () {
                var hosts = root.widgetHostsFor("draft1")
                for (var i = 0; i < hosts.length; i++) {
                    if (hosts[i].expanded && hosts[i].item) {
                        overlayHost = hosts[i]
                        break
                    }
                }
                return overlayHost !== null
            }, 3000)
            var capture = root.findPred(overlayHost.item, function (node) {
                return node && node.objectName === "braindumpCaptureField"
            })
            verify(capture !== null)

            // Break only this loaded editor's store binding to inject the same
            // failure a rejected backend save exposes. The close action must not
            // destroy the only copy of the typed draft.
            overlayHost.item.store = null
            capture.text = "keep this exact unsaved thought"
            verify(overlayHost.hasPendingState())
            verify(!d.closeExpanded(), "close refuses to destroy a failed editor")
            compare(d.expandedType, "braindump")
            compare(d.expandedId, "draft1")
            compare(capture.text, "keep this exact unsaved thought")
            verify(d.cfgStatus.indexOf("remains open") >= 0)

            // Restore the live store and prove the same close path can be retried
            // without retyping or losing the draft.
            overlayHost.item.store = root.store()
            verify(d.closeExpanded())
            compare(d.expandedType, "")
            compare(root.store().settingsFor("draft1").entries[0].text,
                    "keep this exact unsaved thought")
        }

        // ── _tileExists ───────────────────────────────────────────────────────
        // COVERS: fn:Dashboard.sizeClassFor
        // A named size -> how much ROOM the widget has. Named, so widgets ask "have I
        // got room?" rather than re-deriving it from geometry they shouldn't know.
        // Judged on the PROJECTED half-cells, so the same size honestly reports "tall"
        // in portrait and "wide" in landscape - which is the whole point of a panel
        // that rotates.
        function test_sizeClassFor_maps_sizes_to_room() {
            var d = ld.item
            compare(d.sizeClassFor("1x1", false), "compact", "the baseline third is the reference shape")
            compare(d.sizeClassFor("1x1", true), "compact", "and it is that shape in BOTH orientations")
            compare(d.sizeClassFor("0.5x0.5", false), "compact", "a twelfth is square-ish too, just small")

            // The rotating pair: ONE size, two honest answers.
            compare(d.sizeClassFor("1x0.5", false), "wide", "portrait: full width, half a third tall")
            compare(d.sizeClassFor("1x0.5", true), "tall", "landscape: the SAME size is now tall")
            compare(d.sizeClassFor("0.5x1", false), "tall", "portrait: half width, a third tall")
            compare(d.sizeClassFor("0.5x1", true), "wide", "landscape: and now it is wide")

            // "large" had to be REDEFINED. It meant "doubled on both axes" on the old
            // span grid; the size model has no such shape (the short axis stops at 1),
            // so that rule would have made it unreachable. It now means what it always
            // implied: two thirds of the screen or more.
            compare(d.sizeClassFor("1x2", false), "large", "two thirds of the screen is real room")
            compare(d.sizeClassFor("1x3", true), "large", "and the whole screen certainly is")
            compare(d.sizeClassFor("1x1.5", false), "tall", "half the screen is not yet 'large'")

            // A bad size must claim the LEAST room, never silently the baseline's.
            compare(d.sizeClassFor("2x2", false), "compact", "the dead span vocabulary is not a size")
            compare(d.sizeClassFor(undefined, false), "compact", "and neither is nothing at all")
        }

        // The hub's half of the WYSIWYG parity contract. `sizeClassFor` is a named
        // seam, but the DERIVATION must stay in WidgetSizes.classFor - that is the
        // only file the Manager's preview also instantiates, and therefore the only
        // place the two can be made to agree. The clone once carried its own copy
        // with `landscape` hardcoded false; this fails if the hub grows one back.
        // (tests/ui/tst_edgeclone.qml holds the preview's half.)
        function test_sizeClassFor_delegates_to_the_shared_derivation() {
            var d = ld.item
            var all = _sizes.all()
            verify(all.length >= 7, "precondition: the size vocabulary is populated")
            for (var o = 0; o < 2; o++) {
                var land = (o === 1)
                for (var i = 0; i < all.length; i++)
                    compare(d.sizeClassFor(all[i], land), _sizes.classFor(all[i], land),
                            (land ? "landscape " : "portrait ") + all[i] + ": hub delegates, never re-derives")
            }
            compare(d.sizeClassFor("2x2", true), _sizes.classFor("2x2", true), "including the unknown-size path")
        }

        // COVERS: fn:Dashboard.nextSize
        // The edit-mode resize button. The old fixed 1x1->2x1->1x2->2x2 cycle has NO
        // equivalent - those spans aren't sizes - so the cycle is the widget TYPE's own
        // declared list, or it would offer shapes the widget was never built for.
        function test_nextSize_cycles_the_types_own_legal_sizes() {
            var d = ld.item
            var cpu = _catalog.sizesFor("cpu")
            compare(cpu.indexOf("1x3"), -1, "precondition: cpu does not declare the full screen")
            // Walk a full cycle and prove it visits cpu's list exactly, and nothing else.
            var seen = [], cur = _catalog.defaultSize("cpu")
            for (var i = 0; i < cpu.length; i++) { cur = d.nextSize("cpu", cur); seen.push(cur) }
            seen.sort()
            var expect = cpu.slice(); expect.sort()
            compare(seen.join(","), expect.join(","),
                    "one full cycle visits every size cpu declares, and nothing else")
            compare(d.nextSize("cpu", "1x1"), d.nextSize("cpu", "1x1"), "and it is deterministic")

            // It wraps rather than running off the end.
            compare(d.nextSize("cpu", cpu[cpu.length - 1]), cpu[0], "the last size wraps to the first")
            // A tile whose stored size is not in the list (a type whose declarations
            // changed under it) must still land somewhere sane, not on undefined.
            compare(d.nextSize("cpu", "1x3"), cpu[0], "an off-list size restarts the cycle")
            compare(d.nextSize("no-such-type", "1x1"), "", "an unknown type offers no next size")
        }

        // COVERS: fn:Dashboard._msToNextSecond
        // REGRESSION: the shared tick was `interval: 1000; repeat: true`, which
        // re-arms 1000ms after each HANDLING - so hitches accumulate into the phase
        // and it is never aligned to the wall-clock second anyway. Widgets format
        // `new Date()` on the tick, so a drifted tick shows a second twice (stall)
        // then skips one (jump). This asserts the property that makes the error
        // non-cumulative: the next wait is always the time REMAINING to the next
        // boundary, so a late fire waits less rather than staying late forever.
        function test_tick_reaims_at_the_next_second_boundary() {
            var d = ld.item
            // Always a real, bounded wait: never 0 (a busy-loop) and never longer
            // than a second plus the small past-the-boundary nudge.
            verify(d._msToNextSecond() >= 1, "never schedules a zero-delay tick")
            verify(d._msToNextSecond() <= 1005, "never waits more than one second")

            // The defining property: it is a REMAINING time, not a constant. Landing
            // just after a boundary must ask for ~a full second; landing just before
            // one must ask for only the remainder. A fixed 1000ms timer returns the
            // same number in both cases and fails this.
            var atBoundary = 1000 - (0 % 1000) + 5          // now = x.000 -> ~1005
            var lateInSecond = 1000 - (900 % 1000) + 5      // now = x.900 -> ~105
            verify(atBoundary > lateInSecond,
                   "the wait shrinks the later in the second we fire (" +
                   atBoundary + " vs " + lateInSecond + ")")
            compare(lateInSecond, 105, "900ms into the second -> 105ms left, not 1000")
        }

        // ── applyPreset (the post-setup Screens picker, W5 finding 3) ─────────
        function test_applyPreset_seeds_layout_and_keeps_user_appearance() {
            var d = ld.item
            var s = root.store()
            s.load("blank")
            // The user's own choices, made post-setup - none of these are
            // preset "character" keys and every one must survive the apply.
            s.setAppearance("themeMode", "nord")
            s.setAppearance("accent", "green")
            s.setAppearance("glass", 0.31)
            s.setAppearance("netOffline", true)
            // Accessibility is explicit and never belongs to a screen preset.
            s.setAppearance("reduceMotion", true)

            verify(d.applyPreset("developer"), "applyPreset accepts a known preset id")
            var pages = s.pages()
            compare(pages.length, 1, "the developer screen's single page was seeded")
            compare(pages[0].tiles[0].type, "httpjson", "…with its designed tiles (CI status slot)")
            compare(s.settingsFor(pages[0].tiles[0].id).title, "CI status", "and the authored per-tile settings")

            var a = s.appearance()
            compare(a.themeMode, "nord", "the user's theme survives the apply - the confirm copy's promise")
            compare(a.accent, "green", "accent survives")
            compare(a.glass, 0.31, "glass survives")
            compare(a.netOffline, true, "the egress kill switch is NEVER silently re-enabled by a preset")
            compare(a.reduceMotion, true, "the explicit reduce-motion choice survives unchanged")
            compare(a.bgStyle, "grid", "the preset's character still lands where the user made no choice (bgStyle)")
            compare(a.animatedBg, true, "…and animatedBg comes from the preset's character")

            compare(root.themeMode, "nord", "applyPreset re-applied appearance to the live shell")
        }

        function test_applyPreset_blank_and_bad_ids() {
            var d = ld.item
            var s = root.store()
            s.load("developer")
            verify(d.applyPreset("blank"), "applyPreset accepts the blank slate")
            compare(s.pages().length, 1, "blank → one empty page")
            compare(s.pages()[0].tiles.length, 0, "…with no tiles")
            var before = JSON.stringify(s.pages())
            verify(!d.applyPreset("no-such-preset"), "an unknown id is refused")
            verify(!d.applyPreset(""), "an empty id is refused")
            verify(!d.applyPreset(null), "null is refused")
            compare(JSON.stringify(s.pages()), before, "refused ids change nothing")
        }

        function test_applyPreset_respects_the_org_policy_lock() {
            var d = ld.item
            var s = root.store()
            s.lockToPreset("health")
            var before = JSON.stringify(s.pages())
            verify(!d.applyPreset("developer"), "applyPreset refuses under an org-forced preset (E9)")
            compare(JSON.stringify(s.pages()), before, "the forced layout is untouched")
            s.policyLockedPreset = ""          // release the lock for later tests
            s.load("blank")
        }

        // ── appendPreset (post-setup Screens picker): ADD a screen as a new page ──
        function test_appendPreset_adds_a_page_without_replacing() {
            var d = ld.item
            var s = root.store()
            s.load("blank")                       // one "Home" page
            s.setAppearance("themeMode", "nord")  // a user choice that must survive
            var before = s.pageCount()
            verify(d.appendPreset("system-monitor"), "appendPreset adds a known screen")
            compare(s.pageCount(), before + 1, "exactly one page was added, not a replace")
            compare(s.pages()[0].name, "Home", "the user's existing page survives")
            compare(s.appearance().themeMode, "nord", "appending a screen keeps the global theme")
            verify(!d.appendPreset("no-such-preset"), "an unknown id is refused")
            s.load("blank")
        }

        // ── Adding a page LANDS on it (was: snapped back to page 0) ──────────
        // The SwipeView's int-model Repeater resets currentIndex to 0 as the model
        // grows, so a synchronous (or single-callLater) index set was lost. goToPage
        // remembers the target and applies it when `count` catches up.
        function test_adding_pages_lands_on_the_new_page() {
            var s = root.store()
            s.load("blank")                        // one page
            var sw = findPred(ld.item, function (x) { return x && x.objectName === "pageSwipe" })
            verify(sw, "found the page SwipeView")
            // Add several pages in a row, exactly as the edit-toolbar button does.
            for (var n = 0; n < 3; n++) {
                s.addPage("")
                sw.goToPage(s.pageCount() - 1)
                var want = s.pageCount() - 1
                tryVerify(function () { return sw.currentIndex === want }, 4000,
                          "landed on the newly added page " + want + " (got " + sw.currentIndex + ")")
            }
            // The additive preset path lands on its new page too.
            var appendWant = s.pageCount()
            verify(ld.item.appendPreset("system-monitor"), "appendPreset adds a screen")
            tryVerify(function () { return sw.currentIndex === appendWant }, 4000,
                      "landed on the appended preset screen " + appendWant)
            s.load("blank")
        }

        // ── netGate (W5 finding 6): the egress gate exposed for Diagnostics ──
        function test_netGate_exposes_the_app_global_nethub() {
            var d = ld.item
            verify(d.netGate !== null && d.netGate !== undefined, "netGate is exposed")
            compare(typeof d.netGate.request, "function", "netGate IS the NetHub (has request())")
            compare(typeof d.netGate.requests, "number", "…with the sent counter")
            compare(typeof d.netGate.blocked, "number", "…and the blocked counter")
            verify(d.netGate.byHost !== undefined, "…and the per-host tally Diagnostics renders")
        }

        function test_tileExists() {
            var d = ld.item
            d.applyExternalState(root.makeDoc([ { id: "t1", type: "clock" }, { id: "t2", type: "cpu" } ]))
            verify(d._tileExists("t1"), "existing tile found")
            verify(d._tileExists("t2"), "second existing tile found")
            verify(!d._tileExists("nope"), "unknown id is absent")
            verify(!d._tileExists(""), "empty id is never present")
        }

        // ── applyExternalState ────────────────────────────────────────────────
        function test_applyExternalState_valid_updates_store() {
            var d = ld.item
            d.applyExternalState(root.makeDoc([ { id: "a", type: "clock" } ]))
            var pages = root.store().pages()
            compare(pages.length, 1, "one page applied")
            compare(pages[0].tiles.length, 1, "one tile applied")
            compare(pages[0].tiles[0].id, "a", "applyExternalState round-trips the tile id into the store")
        }

        function test_applyExternalState_malformed_ignored() {
            var d = ld.item
            d.applyExternalState(root.makeDoc([ { id: "keep", type: "clock" } ]))
            var before = root.store().pages().length
            d.applyExternalState("{ this is not json")     // must not throw / must not apply
            compare(root.store().pages().length, before, "malformed push left the store intact")
            verify(d._tileExists("keep"), "prior tile still present")
        }

        function test_applyExternalState_closes_orphaned_overlay() {
            var d = ld.item
            d.applyExternalState(root.makeDoc([ { id: "gone", type: "clock" } ]))
            d.expandedId = "gone"; d.expandedType = "clock"
            verify(d.hasExpanded, "precondition: expanded on 'gone'")
            // A push that no longer contains 'gone' must close the overlay.
            d.applyExternalState(root.makeDoc([ { id: "other", type: "cpu" } ]))
            verify(!d._tileExists("gone"), "the expanded tile was removed")
            verify(!d.hasExpanded, "overlay auto-closed for the orphaned tile")
        }

        // ── applyAppearance ───────────────────────────────────────────────────
        function test_immersive_mode_hides_only_the_hub_bar_and_keeps_an_edit_escape() {
            var d = ld.item, s = root.store()
            var bar = root.findPred(d, function (x) {
                return x && x.objectName === "hubBottomBar"
            })
            verify(bar !== null, "the Hub navigation bar is present")
            compare(d.showHubBar, true, "an unset appearance keeps the bar by default")
            compare(bar.visible, true)

            s.setAppearance("hubControlsMode", "invalid")
            compare(s.appearance().hubControlsMode, "standard",
                    "an invalid mode normalizes to the safe Standard mode")
            compare(bar.visible, true)

            s.setAppearance("hubControlsMode", "immersive")
            compare(d.showHubBar, false, "the immersive preference reacts live")
            compare(bar.visible, false, "immersive mode removes the Hub navigation bar")

            var id = s.addTile(0, "clock")
            var cfg = null
            tryVerify(function () {
                cfg = root.findPred(d, function (x) {
                    return x && x.objectName === "widgetConfigButton-" + id
                })
                return cfg !== null && cfg.visible
            }, 3000, "the widget-specific configuration corner remains visible")
            var cfgTap = root.findPred(cfg, function (x) {
                return x && x.hoverEnabled !== undefined && x.enabled !== undefined
            })
            verify(cfgTap !== null && cfgTap.enabled,
                    "immersive mode keeps widget-specific configuration interactive")

            d.editMode = true
            compare(bar.visible, true,
                    "an edit already in progress keeps a visible Done escape")
            d.editMode = false
            compare(bar.visible, false, "leaving edit mode completes the immersive transition")
            s.setAppearance("hubControlsMode", "standard")
            compare(bar.visible, true, "Manager can restore the bar live")
        }

        function test_applyAppearance_pushes_all_keys() {
            var d = ld.item
            var s = root.store()
            s.setAppearance("themeMode", "light")
            s.setAppearance("accent", "green")
            s.setAppearance("glass", 0.33)
            s.setAppearance("glow", false)
            s.setAppearance("reduceMotion", true)
            s.setAppearance("textScale", 1.3)
            s.setAppearance("fontChoice", "lexend")
            s.setAppearance("animatedBg", false)
            s.setAppearance("orientation", "landscape")
            d.applyAppearance()
            compare(root.themeMode, "light", "applyAppearance pushed themeMode to the shell")
            compare(root.glassOpacity, 0.33, "glass pushed to shell")
            compare(root.showWidgetGlow, false, "glow pushed to shell")
            compare(root.reduceMotion, true, "reduceMotion pushed to shell")
            compare(_theme.textScale, 1.3, "textScale pushed to the theme")
            compare(_theme.fontChoice, "lexend", "fontChoice pushed to the theme")
            compare(root.animatedBackground, false, "animatedBg pushed to shell")
            compare(root.orientationMode, "landscape", "orientation pushed to shell")
            verify(Qt.colorEqual(_theme.accent, _theme.accentPresets["green"].a),
                   "accent applied to the theme")
        }

        // ── the 7 appearance→store Connections handlers ───────────────────────
        function test_appearance_connections_persist_each_key() {
            var s = root.store()
            root.accentName = (root.accentName === "purple") ? "teal" : "purple"
            compare(s.appearance().accent, root.accentName, "onAccentNameChanged persisted accent → store")

            root.glassOpacity = (root.glassOpacity === 0.42) ? 0.63 : 0.42
            compare(s.appearance().glass, root.glassOpacity, "onGlassOpacityChanged persisted glass → store")

            root.showWidgetGlow = !root.showWidgetGlow
            compare(s.appearance().glow, root.showWidgetGlow, "onShowWidgetGlowChanged persisted glow → store")

            root.reduceMotion = !root.reduceMotion
            compare(s.appearance().reduceMotion, root.reduceMotion, "onReduceMotionChanged persisted reduceMotion → store")

            root.textScale = root.textScale === 1.3 ? 1.4 : 1.3
            compare(s.appearance().textScale, root.textScale, "onTextScaleChanged persisted textScale → store")

            root.fontChoice = root.fontChoice === "lexend" ? "hyperlegible" : "lexend"
            compare(s.appearance().fontChoice, root.fontChoice, "onFontChoiceChanged persisted fontChoice → store")

            root.themeMode = (root.themeMode === "oled") ? "dark" : "oled"
            compare(s.appearance().themeMode, root.themeMode, "onThemeModeChanged persisted themeMode → store")

            root.animatedBackground = !root.animatedBackground
            compare(s.appearance().animatedBg, root.animatedBackground, "onAnimatedBackgroundChanged persisted animatedBg → store")

            root.orientationMode = (root.orientationMode === "portrait") ? "landscape" : "portrait"
            compare(s.appearance().orientation, root.orientationMode, "onOrientationModeChanged persisted orientation → store")
        }

        // ── shared WidgetHost and one-driver election ────────────────────────
        function test_widget_host_binds_and_elects_one_active_hub_view() {
            var d = ld.item
            var s = root.store()
            s.addPage("Other")
            var id = s.addTile(0, "clock")
            var tileHost = null
            tryVerify(function () {
                var hs = root.widgetHostsFor(id)
                for (var i = 0; i < hs.length; i++)
                    if (!hs[i].expanded && hs[i].item) tileHost = hs[i]
                return tileHost !== null
            }, 3000)
            var w = tileHost.item
            compare(w.instanceId, id, "host set the instanceId")
            compare(w.store, s, "store injected (the Dashboard's own store)")
            compare(w.expanded, false, "tile is not expanded")
            compare(tileHost.driverActive, true, "visible Hub tile is the driver")
            compare(tileHost.foreground, true, "current Hub page is in the foreground")
            compare(w.active, true, "widget receives the elected state")

            // Per-instance appearance bindings track the store live.
            s.setSetting(id, "title", "Hello")
            compare(w.titleOverride, "Hello", "titleOverride binding follows the store")
            s.setSetting(id, "accent", "green")
            compare(w.accentName, "green", "accentName binding follows the store")
            s.setSetting(id, "cardBackdrop", "aurora")
            compare(w.cardBackdrop, "aurora", "cardBackdrop binding follows the store")

            d._tick = 42
            compare(w.tick, 42, "tick binding follows the dashboard tick")

            d.editMode = true
            compare(tileHost.driverActive, false, "editing pauses the tile driver")
            compare(w.active, false)
            d.editMode = false

            var sw = root.findPred(d, function (x) {
                return x && x.objectName === "pageSwipe"
            })
            verify(sw !== null, "found the page SwipeView")
            sw.goToPage(1)
            tryVerify(function () { return sw.currentIndex === 1 }, 4000,
                      "landed on the other Hub page")
            compare(tileHost.driverActive, true,
                    "an off-page timer remains an elected state driver")
            compare(tileHost.foreground, false,
                    "an off-page widget is not considered foreground content")
            sw.goToPage(0)
            tryVerify(function () { return sw.currentIndex === 0 }, 4000,
                      "returned to the widget page")
            compare(tileHost.foreground, true,
                    "returning to the page restores foreground state")

            d.expandedId = id
            d.expandedType = "clock"
            var overlayHost = null
            tryVerify(function () {
                var hs = root.widgetHostsFor(id)
                for (var i = 0; i < hs.length; i++)
                    if (hs[i].expanded && hs[i].item) overlayHost = hs[i]
                return overlayHost !== null
            }, 3000)
            compare(tileHost.driverActive, false, "tile yields while overlay is open")
            compare(overlayHost.driverActive, true, "expanded Hub view is sole driver")
            compare(overlayHost.foreground, true, "expanded Hub view is foreground content")
            compare(overlayHost.item.active, true)

            d.closeExpanded()
            compare(overlayHost.driverActive, false, "closing deactivates overlay immediately")
            compare(tileHost.driverActive, true, "tile resumes during overlay close fade")
        }
    }

    // ── The layout itself, measured in pixels on the REAL Dashboard ──────────
    // Everything above drives properties. This drives the renderer: GridLayout was
    // replaced because of what it DREW, so the replacement has to be proved the same
    // way.
    TestCase {
        name: "DashboardLayout"
        when: windowShown

        function initTestCase() {
            tryVerify(function () { return ld.status === Loader.Ready && ld.item !== null }, 5000)
        }
        function init() { root.store().load("blank"); ld.item.editMode = false }
        function cleanupTestCase() { root.width = 900; root.height = 600 }

        // THE BUG THIS EPIC EXISTS FOR.
        // Measured on the old GridLayout: three 1x1 tiles on a 1200px page rendered at
        // exactly 400px each (correct - which is why nothing LOOKED broken), but a
        // 0.5x0.5 beside a 1x1 rendered at 600px: HALF the page, when it must be a
        // twelfth of the screen. GridLayout sizes a row by what is IN it and collapses
        // span-only rows, so a tile's size depended on what else was on the page. A size
        // is a fraction of the SCREEN, so it may not. This is that exact page.
        function test_a_half_by_half_beside_a_baseline_is_a_twelfth_not_a_half() {
            root.orient(true)                       // 720x2560 - the portrait reflow
            ld.item.applyExternalState(root.makeDoc([ { id: "small", type: "cpu", size: "0.5x0.5" },
                                                      { id: "big", type: "cpu", size: "1x1" } ]))
            tryVerify(function () { return root.laidOut(2, true) }, 4000, "the two tiles laid out in portrait")
            var f = root.pageFlick()
            var gap = _theme.spacingMd
            var pageShort = f.width, pageLong = f.height
            verify(pageLong > pageShort, "precondition: the page really is portrait")

            var small = root.cellFor("small"), big = root.cellFor("big")
            // Add the gap back: it is inset OUT of the tile, so tile + gap is the cell.
            fuzzyCompare(small.width + gap, pageShort / 2, 0.51,
                         "0.5 of the short axis: " + small.width + " on a " + pageShort + "px page")
            fuzzyCompare(small.height + gap, pageLong / 6, 0.51,
                         "and half a third of the long axis: " + small.height +
                         " on a " + pageLong + "px page")

            // THE REGRESSION, stated as the number GridLayout produced. On the old grid
            // this tile measured HALF the long axis, because its row held nothing bigger.
            verify(small.height + gap < pageLong / 2 * 0.9,
                   "BUG GUARD: the 0.5x0.5 is NOT half the page (GridLayout drew it at " +
                   (pageLong / 2) + "px; it is " + small.height + "px)")
            fuzzyCompare((small.height + gap) / (pageLong / 2), 1 / 3, 0.005,
                         "it is a THIRD of what GridLayout gave it along the long axis")
            // 0.5 of the short axis x 1/6 of the long axis = a twelfth of the SCREEN.
            fuzzyCompare(((small.width + gap) * (small.height + gap)) / (pageShort * pageLong),
                         1 / 12, 0.005, "a twelfth of the screen - the size's whole definition")

            // And its neighbour is untouched: a third, whatever else is on the page.
            fuzzyCompare(big.width + gap, pageShort, 0.51, "the 1x1 keeps the full short axis")
            fuzzyCompare(big.height + gap, pageLong / 3, 0.51, "and exactly a third of the long axis")
            fuzzyCompare(((big.width + gap) * (big.height + gap)) / (pageShort * pageLong),
                         1 / 3, 0.005, "a third of the screen - unaffected by what sits beside it")
        }

        // The case that ALWAYS worked, kept honest: three baselines still fill the
        // screen exactly, and each is a third - the default dashboard.
        function test_three_baselines_still_measure_a_third_each() {
            root.orient(true)
            ld.item.applyExternalState(root.makeDoc([ { id: "a", type: "cpu", size: "1x1" },
                                                      { id: "b", type: "cpu", size: "1x1" },
                                                      { id: "c", type: "cpu", size: "1x1" } ]))
            tryVerify(function () { return root.laidOut(3, true) }, 4000, "three tiles laid out in portrait")
            var f = root.pageFlick()
            var gap = _theme.spacingMd
            var third = f.height / 3
            var ids = ["a", "b", "c"]
            for (var i = 0; i < 3; i++) {
                var c = root.cellFor(ids[i])
                fuzzyCompare(c.height + gap, third, 0.51, ids[i] + " is a third of the page tall")
                fuzzyCompare(c.y - gap / 2, i * third, 0.51, ids[i] + " starts exactly where the last ended")
            }
            compare(root.pageItem().longExtent, _sizes.longHalves, "the three of them fill the screen")
            verify(!f.interactive, "a page that fits does not scroll (so it cannot fight the page swipe)")
        }

        // ROTATION STABILITY.
        // The same page, packed for portrait and for landscape, puts every tile in the
        // same SEMANTIC slot. Packing in physical coordinates scrambled 99.2% of 5-tile
        // pages here; packing semantically makes rotation a pure projection.
        function test_rotation_keeps_every_tile_in_the_same_semantic_slot() {
            var doc = root.makeDoc([ { id: "a", type: "cpu", size: "0.5x1" },
                                     { id: "b", type: "cpu", size: "0.5x0.5" },
                                     { id: "c", type: "cpu", size: "1x1" },
                                     { id: "d", type: "cpu", size: "0.5x0.5" },
                                     { id: "e", type: "cpu", size: "1x0.5" } ])
            var ids = ["a", "b", "c", "d", "e"]

            root.orient(true)
            ld.item.applyExternalState(doc)
            tryVerify(function () { return root.laidOut(5, true) }, 4000, "five tiles laid out in portrait")
            var portraitSlots = {}, portraitPx = {}
            for (var i = 0; i < 5; i++) {
                var c = root.cellFor(ids[i])
                var m = root.slotOf(c)
                portraitSlots[ids[i]] = m.s + "," + m.l + "," + m.es + "," + m.el
                portraitPx[ids[i]] = { x: c.x, y: c.y }
            }

            // Turn the panel. Nothing else changes - same document, same store.
            root.orient(false)
            tryVerify(function () { return root.laidOut(5, false) }, 4000,
                      "the dashboard reflowed to the landscape strip")
            var f2 = root.pageFlick()
            var cellS = f2.cellShort, cellL = f2.cellLong
            for (var j = 0; j < 5; j++) {
                var c2 = root.cellFor(ids[j])
                var m2 = root.slotOf(c2)
                compare(m2.s + "," + m2.l + "," + m2.es + "," + m2.el, portraitSlots[ids[j]],
                        ids[j] + ": the rotation did not move it out of its semantic slot")
                // …and the pixels are that slot PROJECTED: the long axis moved from y to
                // x. A re-pack would have put it somewhere unrelated.
                fuzzyCompare(c2.x - _theme.spacingMd / 2, m2.l * cellL, 0.51,
                             ids[j] + ": its long coordinate is now the X axis")
                fuzzyCompare(c2.y - _theme.spacingMd / 2, m2.s * cellS, 0.51,
                             ids[j] + ": and its short coordinate is the Y axis")
            }
            // Rotating BACK restores the original pixels exactly - no drift, no reshuffle.
            root.orient(true)
            tryVerify(function () { return root.laidOut(5, true) }, 4000, "and turned back")
            for (var k = 0; k < 5; k++) {
                var c3 = root.cellFor(ids[k])
                fuzzyCompare(c3.x, portraitPx[ids[k]].x, 0.51, ids[k] + " came back to the same x")
                fuzzyCompare(c3.y, portraitPx[ids[k]].y, 0.51, ids[k] + " came back to the same y")
            }
        }

        // CAPACITY.
        // The 2x6 grid sizes the CELL, not the page. A page longer than the screen is
        // placed IN FULL and scrolls - no tile is refused, capped or dropped. This is
        // the policy that keeps the over-long shipped presets renderable.
        function test_an_overlong_page_keeps_every_tile_and_scrolls() {
            root.orient(true)
            var tiles = []
            for (var i = 0; i < 6; i++) tiles.push({ id: "t" + i, type: "cpu", size: "1x1" })
            ld.item.applyExternalState(root.makeDoc(tiles))   // 6 x 1x1 = 12 half-cells = 2 screens
            tryVerify(function () { return root.laidOut(6, true) }, 4000, "six tiles laid out in portrait")

            var p = root.pageItem(), f = root.pageFlick()
            compare(root.tileCells().length, 6, "every tile is placed - none refused, none dropped")
            compare(p.longExtent, 12, "the page is exactly two screens long")
            verify(f.interactive, "so it SCROLLS - the 7th half-unit overflows, it is not refused")
            fuzzyCompare(f.contentHeight, 12 * f.cellLong, 0.51, "and the scrollable content is that long")

            // The decisive part: overflowing does NOT shrink anyone. Each tile is still a
            // third of the SCREEN - which is the entire reason GridLayout had to go.
            for (var j = 0; j < 6; j++)
                fuzzyCompare(root.cellFor("t" + j).height + _theme.spacingMd, f.height / 3, 0.51,
                             "t" + j + " is still a third of the SCREEN on a 2-screen page")
        }

        // ── W3: a structure edit MOVES tiles, it does not rebuild them ───────
        // THE OWNER-REPORTED CLUNK, one level up from the sensors bar: reordering
        // a tile made it TELEPORT. Two Repeaters were handed a fresh JS array on
        // every structure edit - the pages one (`store.pages()` returns freshly
        // cloned pages) and the tiles one (`placements` re-packs) - and a Repeater
        // given a new array resets its whole delegate model. Every delegate was
        // destroyed and rebuilt, so there was nothing left alive to animate and
        // the new one was simply already at the destination.
        //
        // These pin the same principle tst_gen_sensors pins for metric ticks:
        // object IDENTITY survives, and only bound values move.

        // Three baselines down a portrait page; returns their cells once laid out.
        function _threeTilePage() {
            root.orient(true)
            ld.item.applyExternalState(root.makeDoc([
                { id: "a", type: "cpu", size: "1x0.5" },
                { id: "b", type: "ram", size: "1x0.5" },
                { id: "c", type: "gpu", size: "1x0.5" } ]))
            tryVerify(function () { return root.laidOut(3, true) }, 4000, "three tiles laid out")
        }

        // The two halves of the sync, asserted directly: `_row` maps one packer
        // placement onto the model's roles, and `_syncPlacements` reconciles the
        // whole model to the current packing - idempotently, because the rows ARE
        // the delegates' identity and re-running it must churn nothing.
        // COVERS: fn:Dashboard._syncPlacements, fn:Dashboard._row
        function test_placement_row_and_sync_map_the_packing_onto_the_model() {
            _threeTilePage()
            var p = root.pageItem()
            var placement = { id: "z", type: "cpu", size: "1x1", idx: 2, s: 0, l: 3, es: 2, el: 2 }
            compare(p._row(placement).tileId, "z", "_row carries the tile id")
            compare(p._row(placement).tileType, "cpu", "_row carries the type")
            compare(p._row(placement).tileSize, "1x1", "_row carries the size")
            compare(p._row(placement).tileIdx, 2, "_row carries the STORE tile index, not a row number")
            var r = p._row(placement)
            compare([r.ps, r.pl, r.pes, r.pel].join(","), "0,3,2,2", "_row carries the semantic slot")

            var a = root.cellFor("a")
            compare(p._syncPlacements(), 3, "_syncPlacements holds one row per placed tile")
            compare(p._syncPlacements(), 3, "_syncPlacements is idempotent - no duplicate rows")
            verify(root.cellFor("a") === a, "and it rebuilt nothing: same delegate after two syncs")
        }

        function test_reorder_moves_the_same_delegate_instead_of_rebuilding_it() {
            _theme.reduceMotionPreference = "off"
            _threeTilePage()
            var a = root.cellFor("a"), b = root.cellFor("b"), c = root.cellFor("c")
            verify(a && b && c, "all three cells found")
            compare(root.slotOf(a).l, 0, "precondition: a is first down the long axis")
            compare(root.slotOf(b).l, 1, "precondition: b is second")
            // b's tile Loader - the object that OWNS the widget instance's lifetime.
            // (The widget itself cannot be asserted on here: every catalog source is a
            // `qrc:` path and this harness has no compiled resources, so no tile widget
            // ever instantiates offscreen. The Loader surviving with an unchanged `wId`
            // is exactly the condition under which its widget survives - a reload needs
            // either the Loader to be destroyed or its source key to change.)
            var bLoader = root.findPred(b, function (x) { return x && x.wId === "b" })
            verify(bLoader !== null, "found b's tile Loader")

            // Swap the first two tiles.
            root.store().moveTile(0, 1, 0)
            tryVerify(function () { return root.slotOf(root.cellFor("b")).l === 0 }, 4000,
                      "b's placement moved to the first slot")

            // IDENTITY: a rebuilt delegate would be a different object.
            verify(root.cellFor("b") === b, "b's tile is the SAME object after the reorder")
            verify(root.cellFor("a") === a, "a's tile is the SAME object after the reorder")
            verify(root.cellFor("c") === c, "the untouched tile c is the SAME object too")
            var bLoader2 = root.findPred(root.cellFor("b"), function (x) { return x && x.wId === "b" })
            verify(bLoader2 === bLoader, "b's tile Loader is the SAME object - its widget was never torn down")
            compare(bLoader2.wId, "b", "and its source key never changed, so it never reloaded")
            compare(root.tileCells().length, 3, "still exactly three tiles")
            // …and the surviving delegate's store-addressing index followed the move.
            compare(root.slotOf(root.cellFor("b")).idx, 0, "b's tile index tracked the reorder")
        }

        // A move EASES: the surviving delegate leaves its old pixels behind
        // gradually and arrives at the new ones. (The eye can only follow a tile
        // it can see travelling - that is the whole fix.)
        function test_reorder_eases_the_tile_to_its_new_slot() {
            _theme.reduceMotionPreference = "off"
            compare(_theme.motionPage, 250, "precondition: move easing enabled")
            _threeTilePage()
            var b = root.cellFor("b")
            var startY = b.y
            var startL = b.animL
            compare(startL, 1, "precondition: b's eased mirror sits at its real slot")

            root.store().moveTile(0, 1, 0)

            // Frame 0 of the transition: the TARGET slot is already the new one,
            // but the eased mirror - and therefore the pixels - have not jumped.
            compare(b.pl, 0, "b's target slot updated immediately")
            verify(b.animL > 0, "but it has NOT teleported: the eased mirror is still en route")
            fuzzyCompare(b.y, startY, 1.0, "and its pixels are still at the old slot on frame 0")

            // …and it does arrive.
            tryVerify(function () { return b.animL === 0 }, 4000, "the eased mirror lands on the new slot")
            verify(b.y < startY - 1, "b ended up further up the page than it started")
        }

        // REDUCE MOTION: smooth is not more motion. The move must be INSTANT -
        // not a 0ms animation that still lands a frame late.
        function test_reduce_motion_makes_a_reorder_instant() {
            _theme.reduceMotionPreference = "on"
            compare(_theme.motionPage, 0, "precondition: reduce-motion collapses the move token")
            _threeTilePage()
            var b = root.cellFor("b")
            var startY = b.y

            root.store().moveTile(0, 1, 0)

            // No tryVerify: with the Behavior disabled the write is direct, so the
            // new slot is already in the pixels on this very line.
            compare(b.pl, 0, "b's target slot updated")
            compare(b.animL, 0, "and the mirror is ALREADY there - no animation ran")
            verify(b.y < startY - 1, "b's pixels moved instantly, in the same event")
            verify(root.cellFor("b") === b, "instant, but still the same delegate - not a rebuild")
            _theme.reduceMotionPreference = "auto"
        }

        // ADD / REMOVE reuse the same machinery: the tiles that stay are moved,
        // not rebuilt. (A removed tile's own delegate goes, of course.)
        function test_add_and_remove_keep_the_surviving_delegates() {
            _theme.reduceMotionPreference = "off"
            _threeTilePage()
            var a = root.cellFor("a"), c = root.cellFor("c")

            // Remove the MIDDLE tile - c must slide up, not be reborn there.
            root.store().removeTile(0, "b")
            tryVerify(function () { return root.tileCells().length === 2 }, 4000, "b's tile is gone")
            verify(root.cellFor("b") === null, "b really is removed")
            verify(root.cellFor("a") === a, "a survived the removal")
            verify(root.cellFor("c") === c, "c MOVED into the freed slot - same object, not a rebuild")
            tryVerify(function () { return root.slotOf(root.cellFor("c")).l === 1 }, 4000,
                      "c's placement closed the gap")

            // Add a tile - the incumbents keep their delegates.
            root.store().addTile(0, "disk")
            tryVerify(function () { return root.tileCells().length === 3 }, 4000, "the new tile is placed")
            verify(root.cellFor("a") === a, "a survived the add")
            verify(root.cellFor("c") === c, "and so did c")
        }

        // ── W3: a removed tile FADES; an added tile ARRIVES ──────────────────
        // The gap the reorder fix left. A tile that was removed blinked out of
        // existence while its neighbours glided into the space it left: the only
        // motion on screen belonged to everything EXCEPT the thing the user acted
        // on. `motionRemove` was defined for exactly this and used by nothing.
        //
        // The delegate has to OUTLIVE its removal from the packing for there to be
        // anything left to fade, so the row is what is held open (`dying`), and the
        // cell reaps its own row when its fade ends.

        // COVERS: fn:Dashboard._reapRow
        function test_removing_a_tile_fades_it_out_instead_of_blinking_it_away() {
            _theme.reduceMotionPreference = "off"
            compare(_theme.motionRemove, 150, "precondition: the exit token is live")
            _threeTilePage()
            var b = root.cellFor("b"), c = root.cellFor("c")

            root.store().removeTile(0, "b")

            // THE GUARD: the delegate outlives its removal from the packing. With
            // the row dropped the instant the packer stopped mentioning it - what
            // it used to do - there is no delegate left on screen to fade at all.
            verify(root.cellFor("b") === b, "b's delegate outlived the removal - and is the SAME object")
            compare(b.dying, true, "its row is held open for one reason only: the fade")
            compare(b.opacity, 1, "which starts from where the tile actually was")
            verify(!b.enabled, "but it is a ghost, not a tile: it can no longer be tapped or edited")
            compare(root.store().pages()[0].tiles.length, 2,
                    "…and the STORE has already let it go: the ghost is presentation, not data")

            // It really fades, and then it really goes. A delegate kept alive by a
            // fade nobody finishes is a leak.
            tryVerify(function () { return b.opacity < 1 }, 4000, "the exit fade is running")
            tryVerify(function () { return root.cellFor("b") === null }, 4000,
                      "and the cell reaps its own row when the fade ends")
            compare(root.tileCells().length, 2, "exactly the two survivors remain - no ghost left behind")
            verify(root.cellFor("c") === c, "c MOVED into the freed slot - same object, not a rebuild")

            // The reap only ever takes a row that is genuinely DYING: it is a fade
            // closing the row it opened, not a general-purpose delete. (`a` is
            // alive and on screen - reaping it here would delete a tile the store
            // still has, which is precisely what a resurrected row must survive.)
            compare(root.pageItem()._reapRow("a"), false, "_reapRow refuses a row that is not dying")
            compare(root.tileCells().length, 2, "…and really did not remove it")
            compare(root.pageItem()._reapRow("no-such-tile"), false,
                    "and an id it has never heard of is a no-op")
        }

        // REDUCE MOTION: instant, not a fast fade - and not a 0ms animation that
        // still reaps a frame late. The token is the mechanism: at motionRemove 0
        // the row is never marked dying at all.
        function test_reduce_motion_removes_a_tile_instantly() {
            _theme.reduceMotionPreference = "on"
            compare(_theme.motionRemove, 0, "precondition: reduce-motion collapses the exit token")
            _threeTilePage()
            var c = root.cellFor("c")

            root.store().removeTile(0, "b")

            // No tryVerify: gone in THIS event.
            compare(root.cellFor("b"), null, "b is gone immediately - no ghost, not even for a frame")
            compare(root.tileCells().length, 2, "two tiles remain")
            verify(root.cellFor("c") === c, "and c is still the same delegate - instant is not a rebuild")
            _theme.reduceMotionPreference = "auto"
        }

        // The dangerous edge of keeping a delegate alive past its removal: the id
        // comes BACK inside the fade window (an undo, or a Manager push that
        // re-adds it). The tile exists again, so the fade that was reaping it must
        // not be allowed to finish the job.
        function test_a_tile_that_comes_back_inside_its_own_fade_survives_it() {
            _theme.reduceMotionPreference = "off"
            _threeTilePage()
            var b = root.cellFor("b")
            root.store().removeTile(0, "b")
            compare(b.dying, true, "precondition: b is mid-exit")

            // Back, while the fade still runs.
            ld.item.applyExternalState(root.makeDoc([ { id: "a", type: "cpu", size: "1x0.5" },
                                                      { id: "b", type: "ram", size: "1x0.5" },
                                                      { id: "c", type: "gpu", size: "1x0.5" } ]))
            verify(root.cellFor("b") === b, "the row was reused: it never got as far as being reaped")
            compare(b.dying, false, "the row is live again")
            compare(b.opacity, 1, "and the tile is whole again, not stuck at whatever the fade reached")

            // THE GUARD: wait out the fade that was already running. A reap firing
            // now would delete a tile the store still has.
            wait(_theme.motionRemove * 2 + 50)
            verify(root.cellFor("b") !== null, "b is STILL there once the old fade's window has passed")
            compare(root.store().pages()[0].tiles.length, 3, "…and the store agrees it exists")
            compare(root.tileCells().length, 3, "three tiles - the resurrected id did not fork a second row")
        }

        // A destroyed/interrupted exit animation cannot strand its model row
        // forever. Age a real dying row beyond the generous grace period, then
        // drive the watchdog directly and prove only the two live rows remain.
        function test_stale_dying_sweep_reaps_a_stranded_exit_row() {
            _theme.reduceMotionPreference = "off"
            _threeTilePage()
            var p = root.pageItem()
            var b = root.cellFor("b")

            root.store().removeTile(0, "b")
            compare(b.dying, true, "precondition: b is held as a dying presentation row")
            p._dyingSince["b"] = Date.now() - 10000

            compare(p._sweepStaleDying(), undefined,
                    "_sweepStaleDying completes after removing an over-age dying row")
            tryVerify(function () { return root.cellFor("b") === null }, 3000,
                      "the stale presentation row was destroyed")
            compare(root.tileCells().length, 2, "only the two live store tiles remain")
            compare(root.store().pages()[0].tiles.length, 2,
                    "the watchdog changed presentation bookkeeping, not store data")
            _theme.reduceMotionPreference = "auto"
        }

        // THE ENTRANCE. An added tile is the one thing on screen the user just
        // asked for, so it arrives in its own right instead of merely already
        // being there. It fades in AT its slot - the packer put it where it
        // belongs, so there is no truthful place to fly in from.
        function test_adding_a_tile_fades_it_in_at_its_final_slot() {
            _theme.reduceMotionPreference = "off"
            compare(_theme.motionAdd, 200, "precondition: the entrance token is live")
            _threeTilePage()
            var a = root.cellFor("a")

            var id = root.store().addTile(0, "disk")
            var n = root.cellFor(id)
            verify(n !== null, "the new tile's delegate exists in the same event")
            compare(n.entering, true, "the page GREW this tile - that is what an entrance is")
            compare(n.opacity, 0, "so it starts invisible…")
            // …at its destination: an entrance is not a move.
            compare(n.animS, n.ps, "its eased mirror was BORN at its final slot (short axis)")
            compare(n.animL, n.pl, "…and at its final slot down the long axis")
            verify(root.cellFor("a") === a, "and the incumbent kept its delegate")
            compare(a.opacity, 1, "the incumbent did not fade with it - only the new tile arrives")

            tryVerify(function () { return n.opacity === 1 }, 4000, "the new tile fades in to full strength")
        }

        function test_reduce_motion_adds_a_tile_instantly() {
            _theme.reduceMotionPreference = "on"
            compare(_theme.motionAdd, 0, "precondition: reduce-motion collapses the entrance token")
            _threeTilePage()
            var id = root.store().addTile(0, "disk")
            var n = root.cellFor(id)
            verify(n !== null, "the new tile is placed")
            compare(n.entering, false, "no entrance is even scheduled")
            compare(n.opacity, 1, "it is simply THERE, at full strength, in the same event")
            _theme.reduceMotionPreference = "auto"
        }

        // The other half of the entrance, and the reason it needs `_live`: the
        // rows a page is BORN with are its starting state, not an add. Without
        // that distinction every tile would fade in on every app start.
        // A page that arrives already holding tiles is exactly that case.
        function test_a_page_born_with_tiles_does_not_fade_them_in() {
            _theme.reduceMotionPreference = "off"
            root.orient(true)
            ld.item.applyExternalState(root.makeDoc([ { id: "a", type: "cpu", size: "1x0.5" } ]))
            tryVerify(function () { return root.pageItems().length === 1 && root.laidOut(1, true) },
                      4000, "precondition: one page, one tile")

            // A SECOND page that arrives with its tiles already on it: its delegate
            // is created around them, exactly as page 1's is at app start.
            ld.item.applyExternalState(JSON.stringify({ version: 1, appearance: {}, settings: {}, pages: [
                { name: "P1", tiles: [ { id: "a", type: "cpu", size: "1x0.5" } ] },
                { name: "P2", tiles: [ { id: "n1", type: "ram", size: "1x0.5" },
                                       { id: "n2", type: "gpu", size: "1x0.5" } ] } ] }))
            tryVerify(function () { return root.pageItems().length === 2
                                        && root.cellFor("n1") !== null && root.cellFor("n2") !== null },
                      4000, "the second page and its tiles exist")

            verify(root.pageItems()[1]._live, "the new page finished being born")
            compare(root.cellFor("n1").entering, false,
                    "a tile the page was BORN with is not an entrance - it was always there")
            compare(root.cellFor("n1").opacity, 1, "…so it was never faded in")
            compare(root.cellFor("n2").entering, false, "…and neither was its neighbour")
        }

        // ── W3: the edit-mode "Add widget" slot moves like a tile ────────────
        // It is a real packed placement - the same packer, as a real baseline tile
        // - so an edit re-packs it too: remove a widget and the slot the next one
        // lands in closes up behind it. It was the one box on an edit-mode page
        // that still teleported while everything around it glided.
        function test_the_add_slot_eases_to_its_new_place_like_a_tile() {
            _theme.reduceMotionPreference = "off"
            _threeTilePage()
            ld.item.editMode = true
            var slot = root.addSlot()
            verify(slot !== null, "found the edit-mode add slot")
            var p = root.pageItem()
            // The add slot has its own mirror, so `laidOut` (which only settles the
            // TILES) does not speak for it: settle it explicitly before measuring.
            tryVerify(function () { return slot.animL === p.addPlacement.l }, 4000,
                      "precondition: its mirror settles where the packer put it")
            var startL = slot.animL, startY = slot.y
            verify(startL > 0, "precondition: the add slot sits after the three tiles")

            root.store().removeTile(0, "a")

            // Frame 0: the target has moved up the page, the slot itself has not.
            verify(p.addPlacement.l < startL, "the slot the next widget lands in really did move")
            verify(slot.animL > p.addPlacement.l, "but it has NOT jumped: its mirror is still en route")
            fuzzyCompare(slot.y, startY, 1.0, "and its pixels are still at the old slot on frame 0")

            tryVerify(function () { return slot.animL === p.addPlacement.l }, 4000,
                      "it arrives at the new slot")
            verify(slot.y < startY - 1, "…which is further up the page than it started")

            // And a ROTATION still re-projects it instantly: the ease is on the
            // SEMANTIC slot, which a rotation does not touch.
            var settled = slot.animL
            root.orient(false)
            compare(slot.animL, settled, "the rotation did not disturb the add slot's semantic mirror")
            root.orient(true)
            ld.item.editMode = false
        }

        function test_reduce_motion_moves_the_add_slot_instantly() {
            _theme.reduceMotionPreference = "on"
            compare(_theme.motionPage, 0, "precondition: reduce-motion collapses the move token")
            _threeTilePage()
            ld.item.editMode = true
            var slot = root.addSlot()
            var p = root.pageItem()
            var startY = slot.y

            root.store().removeTile(0, "a")

            compare(slot.animL, p.addPlacement.l, "the mirror is ALREADY at the new slot - nothing animated")
            verify(slot.y < startY - 1, "its pixels moved in the same event")
            ld.item.editMode = false
            _theme.reduceMotionPreference = "auto"
        }

        // A ROTATION must stay instant even though a reorder now eases. The two
        // are separated structurally - easing lives on the SEMANTIC slot, which a
        // rotation does not touch (it only re-projects it) - so this is the guard
        // that the smoothness work did not slow the panel turning down.
        function test_rotation_is_still_instant_not_eased() {
            _theme.reduceMotionPreference = "off"
            _threeTilePage()
            var b = root.cellFor("b")
            compare(b.animL, 1, "precondition: b's mirror is settled at its slot")

            root.orient(false)                       // turn the panel
            // THE GUARD: a rotation does not touch the semantic slot at all, so there
            // is structurally nothing for the ease to act on - it re-projects. (The
            // pixels themselves settle on the next layout pass, as they always did:
            // the SwipeView/Layout chain polishes deferred.)
            compare(b.animL, 1, "the rotation did not disturb the semantic slot")
            tryVerify(function () { return root.laidOut(3, false) }, 4000, "reflowed to the landscape strip")
            compare(b.animL, 1, "…and still hasn't after the reflow: nothing eased")
            var f = root.pageFlick()
            fuzzyCompare(b.x - _theme.spacingMd / 2, 1 * f.cellLong, 0.51,
                         "b's long coordinate is the projected X exactly - not a value in flight")
            root.orient(true)
        }

        // ── W5 BLOCKER (finding 2): the expanded overlay in LANDSCAPE ─────────
        // On the 2560x720 strip the config form used to collapse to a ~10px
        // sliver (both overlay columns declared fillWidth; GridLayout stretches
        // in proportion to preferred widths, and the panel's implicit width is
        // ~0), so "connect CI to a URL" was impossible on-device. Assert the
        // landscape split structurally: the form gets AT LEAST half the
        // overlay, renders real scrollable content, and the preview keeps a
        // sane share - and portrait still gives the form the full width.
        function overlayOf() {
            return root.findPred(ld.item, function (x) { return x && x.ovlWide !== undefined })
        }
        function configPanelOf() {
            return root.findPred(ld.item, function (x) {
                return x && x.schema !== undefined && x.st !== undefined
                         && x.instanceId !== undefined && x.statusText !== undefined
            })
        }
        function test_landscape_expanded_overlay_shows_a_usable_form() {
            root.orient(false)                                  // 2560x720
            var d = ld.item
            d.applyExternalState(root.makeDoc([ { id: "ci", type: "httpjson" } ]))
            tryVerify(function () { return root.laidOut(1, false) }, 4000, "tile laid out in landscape")
            d.cfgStatus = ""; d.expandedId = "ci"; d.expandedType = "httpjson"
            var ovl = overlayOf()
            verify(ovl !== null, "found the expanded overlay")
            tryCompare(ovl, "opacity", 1.0, 2000, "overlay shown")
            verify(ovl.ovlWide, "2560x720 puts the overlay in its wide (landscape) layout")

            var panel = configPanelOf()
            verify(panel !== null, "found the WidgetConfigPanel")
            tryVerify(function () { return panel.width >= ovl.width * 0.5 }, 4000,
                      "the FORM gets at least half the overlay width (got " +
                      panel.width + " of " + ovl.width + ") - the W5 sliver regression")
            verify(panel.height > 200, "the form has real height (" + panel.height + "px)")
            verify(panel.schema.sections.length > 0, "httpjson exposes a real config schema")

            // The form renders actual fields: its scroller carries real content
            // taller than a bare margin, i.e. the URL/token/poll controls exist.
            var scroll = root.findPred(panel, function (x) { return x && x.objectName === "cfgScroll" })
            verify(scroll !== null, "found the form's scroller")
            tryVerify(function () { return scroll.contentHeight > 200 }, 4000,
                      "the form laid out real fields (contentHeight " + scroll.contentHeight + ")")

            // And the preview did not silently vanish either: it keeps a fixed,
            // bounded share beside the form.
            var preview = root.findPred(ld.item, function (x) {
                return x && x.parent === panel.parent && x !== panel && x.width > 0
            })
            verify(preview !== null, "the widget preview column is present")
            verify(preview.width <= ovl.width * 0.42 + 1,
                   "the preview is capped (got " + preview.width + ") so it can never starve the form")
            d.closeExpanded()
        }

        function test_portrait_expanded_overlay_keeps_the_full_width_form() {
            root.orient(true)                                   // 720x2560
            var d = ld.item
            d.applyExternalState(root.makeDoc([ { id: "ci2", type: "httpjson" } ]))
            tryVerify(function () { return root.laidOut(1, true) }, 4000, "tile laid out in portrait")
            d.expandedId = "ci2"; d.expandedType = "httpjson"
            var ovl = overlayOf()
            tryCompare(ovl, "opacity", 1.0, 2000, "overlay shown")
            verify(!ovl.ovlWide, "720x2560 keeps the stacked portrait layout")
            var panel = configPanelOf()
            verify(panel !== null, "found the WidgetConfigPanel")
            tryVerify(function () { return panel.width >= ovl.width * 0.8 }, 4000,
                      "portrait: the form still spans the width (" + panel.width + " of " + ovl.width + ")")
            d.closeExpanded()
        }

        // A page that fits must never become scrollable - an inert Flickable is what
        // keeps the page swipe usable (they share an axis in landscape).
        function test_a_page_that_fits_is_not_scrollable() {
            root.orient(false)
            ld.item.applyExternalState(root.makeDoc([ { id: "a", type: "cpu", size: "1x1" } ]))
            tryVerify(function () { return root.laidOut(1, false) }, 4000, "one tile laid out in landscape")
            var f = root.pageFlick()
            verify(!f.interactive, "one tile does not scroll")
            compare(root.pageItem().longExtent, 2, "it reaches 2 of the screen's 6 half-cells")
            fuzzyCompare(f.contentWidth, f.width, 0.51,
                         "landscape: the content is exactly one screen along the long (X) axis")
        }

        // THE SHIPPED PRESETS, on the real Dashboard.
        //
        // tst_preset_catalog asserts the budget against WidgetPacker directly; this
        // asserts the same property survives all the way to rendered geometry -
        // every tile placed, every page one screen or less, nothing scrolling.
        //
        // It used to pin the OPPOSITE (14 of 17 pages over capacity, worst 2.0x) as
        // the measured, deliberate state of a library that had not yet been
        // re-authored. It is re-authored now: pages that fit never scroll, so the
        // landscape Flickable can never steal the page swipe.
        function test_every_shipped_preset_renders_without_losing_a_tile() {
            root.orient(true)
            var cat = presetCat
            verify(cat.items.length > 0, "the preset library is present")
            var checkedPages = 0, overCapacity = 0, worst = 0, over = []
            for (var i = 0; i < cat.items.length; i++) {
                var id = cat.items[i].id
                root.store().load(id)
                var pages = root.store().pages()
                // Every page is instantiated by the SwipeView, so every tile of every
                // page must be placed - the count is the document's, not page 1's.
                var want = 0
                for (var p = 0; p < pages.length; p++) want += pages[p].tiles.length
                tryVerify(function () { return root.laidOut(want, true) }, 4000,
                          id + ": all " + want + " tiles across " + pages.length + " page(s) are placed")

                var pis = root.pageItems()
                compare(pis.length, pages.length, id + ": one delegate per page")
                for (var q = 0; q < pis.length; q++) {
                    var ratio = pis[q].longExtent / _sizes.longHalves
                    compare(pis[q].placements.length, pages[q].tiles.length,
                            id + "/" + pages[q].name + ": no tile went missing in the packing")
                    if (ratio > 1) {
                        overCapacity++; worst = Math.max(worst, ratio)
                        over.push(id + "/" + pages[q].name + " " + ratio.toFixed(2) + "x")
                    }
                    checkedPages++
                }
                var cs = root.tileCells()
                for (var j = 0; j < cs.length; j++)
                    verify(cs[j].width > 0 && cs[j].height > 0,
                           id + ": tile " + j + " has real geometry, not a collapsed box")
            }
            verify(checkedPages >= cat.items.length,
                   "every preset contributed at least one rendered page, got " + checkedPages)
            compare(overCapacity, 0,
                    "NO shipped preset page runs past one screen - over: [" + over.join(", ") + "]")
            compare(worst, 0, "so there is no worst case to report")
        }
    }

    // ── Auto-cycle through screens ───────────────────────────────────────────
    // Timers are resources, not visual children, so the tree walks above cannot
    // see one. `data` is the union of both.
    function findData(node, name) {
        if (!node) return null
        if (node.objectName === name) return node
        var kids = node.data
        for (var i = 0; kids && i < kids.length; i++) {
            var hit = findData(kids[i], name)
            if (hit) return hit
        }
        return null
    }

    TestCase {
        name: "DashboardAutoCycle"
        when: windowShown

        function initTestCase() {
            tryVerify(function () { return ld.status === Loader.Ready && ld.item !== null }, 5000)
        }

        function init() {
            var d = ld.item
            root.store().load("blank")
            d.closeExpanded()
            d.editMode = false
            root.store().setAppearance("pageCycleSec", 0)
            // Land on page 0 explicitly. Earlier this happened as a side effect
            // of advanceCycle() going through goToPage(), which commits the
            // scroll position - a test must not depend on which navigation path
            // the product happens to use, so the precondition is set here.
            d.goToPageExternal(0)
            tryCompare(d, "currentPageIndex", 0, 3000)
        }
        function cleanup() {
            ld.item.editMode = false
            root.store().setAppearance("pageCycleSec", 0)
        }

        function seedPages(tileCounts) {
            var s = root.store(), pages = []
            for (var i = 0; i < tileCounts.length; i++) {
                var tiles = []
                for (var j = 0; j < tileCounts[i]; j++)
                    tiles.push({ id: "p" + i + "t" + j, type: "clock", size: "1x1" })
                pages.push({ name: "P" + i, tiles: tiles })
            }
            s.applyExternal(JSON.stringify({ version: 1, appearance: {}, settings: {},
                                             pages: pages }))
            return s
        }

        // Default OFF. A display that starts moving by itself after an update is
        // a surprise, and this ships B2B.
        function test_cycling_is_off_until_it_is_asked_for() {
            var d = ld.item
            seedPages([1, 1, 1])
            compare(d.pageCycleSec, 0, "no dwell configured means off")
            compare(d.cycleRunning, false)
            compare(root.findData(d, "cycleDwellTimer").running, false,
                    "and nothing is armed")
        }

        // The ladder predicate itself: the single place that decides what a
        // legal dwell is, used by both the write path and the load path.
        // COVERS: fn:DashboardStore.isPageCycleChoice
        function test_isPageCycleChoice_accepts_exactly_the_offered_ladder() {
            var s = root.store()
            var ladder = s.pageCycleChoices
            for (var i = 0; i < ladder.length; i++)
                verify(s.isPageCycleChoice(ladder[i]),
                       "isPageCycleChoice accepts the offered value " + ladder[i])
            var junk = [7, 0.5, -30, 86400, "soon", undefined, NaN, {}]
            for (var j = 0; j < junk.length; j++)
                verify(!s.isPageCycleChoice(junk[j]), "isPageCycleChoice rejects " + JSON.stringify(junk[j]))

            // The predicate judges the COERCED number, which is what lets the
            // string "60" from a hand-edited config work. The values that coerce
            // to 0 are therefore accepted - and 0 is "off", so an empty or null
            // dwell means the panel holds still rather than failing validation.
            var emptyish = [null, "", []]
            for (var k = 0; k < emptyish.length; k++) {
                verify(s.isPageCycleChoice(emptyish[k]), "isPageCycleChoice reads " + JSON.stringify(emptyish[k]) + " as a number")
                s.setAppearance("pageCycleSec", emptyish[k])
                compare(s.appearance().pageCycleSec, 0, JSON.stringify(emptyish[k]) + " is stored as off, not as itself")
            }
        }

        // Only the offered ladder is honoured: an arbitrary persisted number
        // would be a dwell nobody can reproduce from the UI.
        function test_only_offered_dwell_values_are_honoured_data() {
            return [
                { tag: "off", set: 0, want: 0 },
                { tag: "15s", set: 15, want: 15 },
                { tag: "60s", set: 60, want: 60 },
                { tag: "5min", set: 300, want: 300 },
                { tag: "not-on-ladder", set: 7, want: 0 },
                { tag: "fractional", set: 0.5, want: 0 },
                { tag: "absurd", set: 86400, want: 0 },
                { tag: "negative", set: -30, want: 0 },
                { tag: "text", set: "60", want: 60 },
                { tag: "junk", set: "soon", want: 0 }
            ]
        }
        function test_only_offered_dwell_values_are_honoured(data) {
            var d = ld.item
            seedPages([1, 1])
            var s = root.store()
            s.setAppearance("pageCycleSec", data.set)
            // The STORE value is what reaches config.toml and what the Manager
            // reads back over the control socket, so it must be clean at the
            // source - not merely tidied up by whoever renders it. Asserting
            // only d.pageCycleSec passes with the store's validation deleted,
            // because the Dashboard coerces a second time (measured).
            compare(s.appearance().pageCycleSec, data.want,
                    JSON.stringify(data.set) + " must be PERSISTED as " + data.want)
            compare(d.pageCycleSec, data.want,
                    JSON.stringify(data.set) + " must resolve to " + data.want)
        }

        // A hand-edited config.toml is not a reason to render a dwell the UI
        // cannot express.
        function test_a_junk_dwell_in_a_loaded_document_is_coerced_off() {
            var s = root.store()
            s.applyExternal(JSON.stringify({
                version: 1, appearance: { pageCycleSec: 7 }, settings: {},
                pages: [ { name: "A", tiles: [] }, { name: "B", tiles: [] } ] }))
            compare(s.appearance().pageCycleSec, 0, "7 is not on the ladder")
            compare(ld.item.pageCycleSec, 0)
        }

        // Idle-gated: configuring a dwell does NOT start rotating while someone
        // is using the panel.
        // COVERS: fn:Dashboard.noteActivity
        function test_activity_holds_the_current_screen() {
            var d = ld.item
            seedPages([1, 1, 1])
            root.store().setAppearance("pageCycleSec", 60)
            d.noteActivity()
            compare(d.cycleIdle, false, "noteActivity means someone is here")
            compare(d.cycleRunning, false, "so nothing rotates")
            compare(root.findData(d, "cycleIdleTimer").running, true,
                    "the grace period is counting instead")

            d.cycleIdle = true      // grace elapsed
            compare(d.cycleRunning, true)
            compare(root.findData(d, "cycleDwellTimer").running, true)

            d.noteActivity()        // touched again mid-rotation
            compare(d.cycleRunning, false, "a second noteActivity stops the rotation")
        }

        // One number drives both halves, so they cannot drift apart.
        function test_dwell_and_grace_use_the_configured_interval() {
            var d = ld.item
            seedPages([1, 1])
            root.store().setAppearance("pageCycleSec", 90)
            compare(root.findData(d, "cycleDwellTimer").interval, 90000)
            compare(root.findData(d, "cycleIdleTimer").interval, 90000)
        }

        function test_suppressed_while_editing_or_expanded_data() {
            return [ { tag: "edit-mode" }, { tag: "expanded-overlay" } ]
        }
        function test_suppressed_while_editing_or_expanded(data) {
            var d = ld.item
            seedPages([1, 1, 1])
            root.store().setAppearance("pageCycleSec", 60)
            d.cycleIdle = true
            compare(d.cycleRunning, true, "precondition: rotating")

            if (data.tag === "edit-mode") d.editMode = true
            else { d.expandedType = "clock"; d.expandedId = "p0t0" }

            compare(d.cycleSuppressed, true)
            compare(d.cycleRunning, false,
                    "the screen must hold still while the user is working on it")
            compare(root.findData(d, "cycleDwellTimer").running, false)

            if (data.tag === "edit-mode") d.editMode = false
            else d.closeExpanded()
            compare(d.cycleSuppressed, false)
            compare(d.cycleIdle, false,
                    "and coming back out starts the grace period, not the rotation")
        }

        // Nowhere to go is not a rotation.
        function test_a_single_page_never_rotates() {
            var d = ld.item
            seedPages([2])
            root.store().setAppearance("pageCycleSec", 15)
            d.cycleIdle = true
            compare(d.cycleSuppressed, true)
            compare(d.cycleRunning, false)
        }

        // An empty screen is not worth a dwell.
        function test_empty_pages_are_skipped() {
            var d = ld.item
            seedPages([1, 0, 1, 0, 2])
            compare(JSON.stringify(d.cyclablePages), JSON.stringify([0, 2, 4]),
                    "pages 1 and 3 have nothing on them")
        }

        // ...but never the one being looked at: rotating away because the user
        // just emptied the page they are on would be its own surprise.
        function test_the_current_page_counts_even_when_empty() {
            var d = ld.item
            seedPages([0, 1, 1])
            compare(d.currentPageIndex, 0, "precondition: on the empty page")
            verify(d.cyclablePages.indexOf(0) >= 0,
                   "the page under the user is always a place to be")
        }

        // COVERS: fn:Dashboard.advanceCycle
        function test_rotation_visits_every_non_empty_page_in_order() {
            var d = ld.item
            seedPages([1, 0, 1, 1])
            root.store().setAppearance("pageCycleSec", 15)
            var order = d.cyclablePages
            compare(JSON.stringify(order), JSON.stringify([0, 2, 3]))

            var seen = [d.currentPageIndex]
            for (var i = 0; i < 3; i++) {
                d.advanceCycle()
                tryCompare(d, "currentPageIndex", order[(i + 1) % order.length], 2000)
                seen.push(d.currentPageIndex)
            }
            compare(JSON.stringify(seen), JSON.stringify([0, 2, 3, 0]), "advanceCycle skips the empty page and wraps")
        }

        function test_advancing_from_a_page_that_left_the_rotation_recovers() {
            var d = ld.item
            seedPages([1, 1, 1])
            d.goToPageExternal(2)
            tryCompare(d, "currentPageIndex", 2, 2000)
            // Page 2 empties underneath the rotation.
            var s = root.store()
            s.applyExternal(JSON.stringify({ version: 1, appearance: {}, settings: {},
                pages: [ { name: "P0", tiles: [ { id: "a", type: "clock", size: "1x1" } ] },
                         { name: "P1", tiles: [ { id: "b", type: "clock", size: "1x1" } ] },
                         { name: "P2", tiles: [] } ] }))
            d.advanceCycle()
            tryCompare(d, "currentPageIndex", 0, 2000)
            verify(d.currentPageIndex !== 2, "advanceCycle is not trapped on a page that left the rotation")
        }
    }

    App.PresetCatalog { id: presetCat }
}
