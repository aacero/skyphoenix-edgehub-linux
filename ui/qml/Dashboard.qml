import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// ─────────────────────────────────────────────────────────────────────────
// Dashboard - registry-driven, persistent, touch-editable widget canvas for
// the Xeneon Edge (2560×720).
//
//   • Layout + per-widget state live in DashboardStore (persisted via config).
//   • Each widget is a file registered in WidgetCatalog and loaded into a tile.
//     The SAME widget file + SAME persisted settings object back both the tile
//     and its full-screen expanded view, so their state is shared.
//   • Edit mode: add (catalog picker), remove, reorder, and add/remove pages.
//   • A single-driver rule (`active`) stops background tiles' timers while the
//     expanded overlay is open, so shared countdowns never double-run.
// ─────────────────────────────────────────────────────────────────────────
Item {
    id: dashboard
    // NO `anchors.fill: parent` here. This item is a StackView PAGE (main.qml
    // pushes it), and StackView sets its pages' x/y/width/height itself. Anchoring
    // as well produced, on every launch:
    //     QML StackView: StackView has detected conflicting anchors.
    //     Transitions may not execute properly.
    // i.e. Qt telling us the push/pop transitions may not run. Every other host
    // sizes this item too: the tests' Loaders are `anchors.fill: parent`, and a
    // Loader resizes its loaded item to itself. A host that does NEITHER must set
    // width/height explicitly.

    property int _tick: 0
    property var metrics: {
        try { return JSON.parse(metricsJson || "{}") } catch (e) { return {} }
    }
    readonly property var availableTimeZones: (typeof timeZones !== "undefined") ? timeZones : null
    property bool editMode: false
    // Process-local safe mode. This never edits the persisted document: it
    // prevents every WidgetHost from constructing a widget and prevents the
    // optional user-widget directory scan from entering the recovery path.
    readonly property bool sessionWidgetsEnabled: {
        if (typeof _widgetsEnabled !== "undefined") return _widgetsEnabled
        if (typeof _safeMode !== "undefined") return !_safeMode
        return true
    }
    readonly property bool showHubBar: {
        store.revision
        return store.appearance().hubControlsMode !== "immersive"
    }

    // ── Auto-cycle through screens ───────────────────────────────────────────
    // The screens that go unseen are the ones nobody is touching the panel for,
    // so rotation is IDLE-GATED rather than unconditional: a timer that rotates
    // regardless also rotates out from under a hand mid-read, and every fix for
    // that is another pause/resume special case. Gating on idle removes the
    // class instead of handling it.
    //
    // One number controls both halves: the dwell between screens, and the grace
    // after an interaction before rotation resumes. "Cycle every 60s when I'm
    // not using it, and after I touch it wait 60s before starting again."
    readonly property int pageCycleSec: {
        store.revision
        var v = Number(store.appearance().pageCycleSec)
        return store.isPageCycleChoice(v) ? v : 0
    }

    // Everything that must hold the current screen still. Editing and the
    // expanded overlay are direct interactions; a single page has nowhere to go;
    // and one non-empty page means the rotation would land right back here.
    readonly property bool cycleSuppressed: dashboard.editMode
                                            || dashboard.hasExpanded
                                            || dashboard.cyclablePages.length <= 1

    // Pages worth landing on. An empty screen is not worth a dwell, but the one
    // the user is LOOKING at always counts - silently rotating away from a page
    // because they just emptied it would be its own surprise.
    readonly property var cyclablePages: {
        store.revision
        var ps = store.pages(), out = []
        for (var i = 0; i < ps.length; i++) {
            var tiles = ps[i] && ps[i].tiles
            if ((tiles && tiles.length > 0) || i === dashboard.currentPageIndex)
                out.push(i)
        }
        return out
    }

    // False while the user is (or has recently been) touching the panel.
    property bool cycleIdle: false
    readonly property bool cycleRunning: dashboard.pageCycleSec > 0
                                         && !dashboard.cycleSuppressed
                                         && dashboard.cycleIdle

    // Any input anywhere restarts the grace period. Called from the passive
    // pointer/key probes below, which observe without consuming - a probe that
    // stole events would break every control underneath it.
    // Wall-clock of the last input. HoverHandler fires on every pointer move, so
    // this must stay cheap: restarting a Timer per event (the first version)
    // meant thousands of timer restarts for one sweep of the mouse. Writing a
    // number is free, and the grace period is judged by comparing against it.
    property double _lastActivityMs: 0
    function noteActivity() {
        dashboard._lastActivityMs = Date.now()
        if (dashboard.cycleIdle) dashboard.cycleIdle = false
        if (dashboard.pageCycleSec > 0 && !dashboard.cycleSuppressed) {
            if (!cycleIdleTimer.running) cycleIdleTimer.start()
        } else {
            cycleIdleTimer.stop()
        }
    }

    function advanceCycle() {
        var order = dashboard.cyclablePages
        if (order.length <= 1) return
        var at = order.indexOf(dashboard.currentPageIndex)
        // Not on a cyclable page (it just emptied) - start the rotation from the
        // beginning rather than refusing to move.
        var next = at < 0 ? order[0] : order[(at + 1) % order.length]
        // Deliberately NOT goToPage(). That path exists for landing on a
        // JUST-ADDED page: it commits the scroll position with
        // positionViewAtIndex() and then re-asserts on a 50 ms timer for up to
        // 2.5 s, to beat a deferred relayout that would otherwise snap the view
        // back. Committing the position is precisely what removes the slide, so
        // every cycle arrived as a hard cut; the re-assert churn is what the
        // panel feels as a stutter once a dwell (measured offscreen: peak CPU
        // 5% with cycling off vs 15% with it on, same layout, same binary).
        //
        // Cycling only ever moves between pages that ALREADY exist, so there is
        // no relayout race to defend against. Setting currentIndex lets SwipeView
        // run its own transition - the same one a finger swipe produces.
        swipeView.currentIndex = next
    }

    // Polls once per dwell rather than being restarted per input event, and
    // decides on the timestamp: if the last input is still inside the grace
    // window it simply keeps ticking, so a stream of hover events costs one
    // number write each instead of a timer restart each.
    Timer {
        id: cycleIdleTimer
        objectName: "cycleIdleTimer"
        interval: Math.max(1, dashboard.pageCycleSec * 1000)
        repeat: true
        onTriggered: {
            if (Date.now() - dashboard._lastActivityMs >= cycleIdleTimer.interval) {
                dashboard.cycleIdle = true
                cycleIdleTimer.stop()
            }
        }
    }
    Timer {
        id: cycleDwellTimer
        objectName: "cycleDwellTimer"
        interval: Math.max(1, dashboard.pageCycleSec * 1000)
        repeat: true
        running: dashboard.cycleRunning
        onTriggered: dashboard.advanceCycle()
    }
    // Turning the feature on (or leaving edit mode / closing an overlay) must
    // start the grace period; turning it off must not leave a timer armed.
    onCycleSuppressedChanged: dashboard.noteActivity()
    onPageCycleSecChanged: dashboard.noteActivity()

    // Passive input probes. A PointHandler takes a PASSIVE grab: it sees every
    // press in the dashboard and steals none of them, so buttons, drags and the
    // SwipeView keep working exactly as before. An overlaid MouseArea would have
    // had to consume-and-replay, which is how input eaters get written.
    PointHandler {
        id: cycleActivityProbe
        enabled: dashboard.pageCycleSec > 0
        acceptedDevices: PointerDevice.AllPointerTypes
        grabPermissions: PointerHandler.TakeOverForbidden
        onActiveChanged: if (active) dashboard.noteActivity()
    }
    // Hovering counts as presence for a mouse user, who may never click.
    HoverHandler {
        enabled: dashboard.pageCycleSec > 0
        onPointChanged: dashboard.noteActivity()
    }
    Keys.onPressed: function (event) {
        dashboard.noteActivity()
        event.accepted = false   // observe only
    }

    // Reminder-class events are not ordinary toasts. Widgets enqueue them here
    // so an off-page timer or schedule can claim a persistent, unmistakable Hub
    // surface until the user chooses an action. A queue prevents two reminders
    // arriving together from silently replacing each other.
    property var priorityAlertQueue: []
    readonly property int maxPriorityAlerts: 16
    readonly property var currentPriorityAlert:
        priorityAlertQueue.length ? priorityAlertQueue[0] : null
    onCurrentPriorityAlertChanged: {
        if (currentPriorityAlert)
            priorityAlertLayer.shownAlert = currentPriorityAlert
    }
    readonly property alias priorityAlertSurface: priorityAlertLayer
    readonly property alias priorityAlertPrimaryButton: priorityPrimaryButton
    readonly property alias priorityAlertSecondaryButton: prioritySecondaryButton
    readonly property alias priorityAlertDismissButton: priorityDismissButton

    function showPriorityAlert(request) {
        if (!request || typeof request !== "object") return false
        var title = String(request.title || "").trim()
        var body = String(request.body || "").trim()
        if (!title.length || !body.length) return false

        var key = String(request.key || (request.sourceId || "") + ":" + title)
        for (var i = 0; i < priorityAlertQueue.length; i++)
            if (priorityAlertQueue[i].key === key) return true
        // Preserve the oldest unacknowledged reminders. Returning false lets the
        // widget fall back to its desktop-notification path without allowing an
        // unattended repeating timer to grow this process-local queue forever.
        if (priorityAlertQueue.length >= maxPriorityAlerts)
            return false

        var next = priorityAlertQueue.slice()
        next.push({
            key: key,
            sourceId: String(request.sourceId || ""),
            widgetType: String(request.widgetType || ""),
            eyebrow: String(request.eyebrow || "IMPORTANT REMINDER"),
            title: title,
            body: body,
            detail: String(request.detail || ""),
            iconName: String(request.iconName || "ui-warning"),
            accent: request.accent || theme.warning,
            primaryLabel: String(request.primaryLabel || "Got it"),
            secondaryLabel: String(request.secondaryLabel || ""),
            primaryAction: String(request.primaryAction || "dismiss"),
            secondaryAction: String(request.secondaryAction || "")
        })
        priorityAlertQueue = next
        return true
    }

    function dismissPriorityAlert() {
        if (!priorityAlertQueue.length) return false
        priorityAlertQueue = priorityAlertQueue.slice(1)
        return true
    }

    function _openPriorityAlertWidget(alert) {
        if (!alert || !alert.sourceId || !alert.widgetType) return false
        var pageIndex = store.pageIndexForTile(alert.sourceId)
        if (pageIndex < 0) return false
        swipeView.goToPage(pageIndex)
        dashboard.expandedId = alert.sourceId
        dashboard.expandedType = alert.widgetType
        return true
    }

    function _priorityAlertWidget(alert) {
        if (!alert || !alert.sourceId || !alert.widgetType) return null
        var pending = [dashboard]
        var fallback = null
        while (pending.length > 0) {
            var node = pending.pop()
            if (node !== dashboard
                    && node.widgetId === alert.sourceId
                    && node.widgetType === alert.widgetType
                    && node.item) {
                if (node.driverActive)
                    return node.item
                fallback = node.item
            }
            var children = node.children || []
            for (var i = 0; i < children.length; i++)
                pending.push(children[i])
        }
        return fallback
    }

    function _invokePriorityAlertWidget(alert, method) {
        var widget = dashboard._priorityAlertWidget(alert)
        if (!widget || typeof widget[method] !== "function")
            return false
        return widget[method]() !== false
    }

    function triggerPriorityAlertAction(which) {
        var alert = currentPriorityAlert
        if (!alert) return false
        var action = which === "secondary" ? alert.secondaryAction
                                           : alert.primaryAction
        var handled = false
        if (action === "openWidget")
            handled = dashboard._openPriorityAlertWidget(alert)
        else if (action === "breakTake")
            handled = dashboard._invokePriorityAlertWidget(alert, "takeBreak")
        else if (action === "breakSnooze")
            handled = dashboard._invokePriorityAlertWidget(alert, "snooze")
        else if (action === "dismiss" || action === "")
            handled = true
        if (!handled)
            return false
        return dashboard.dismissPriorityAlert()
    }

    function prunePriorityAlerts() {
        var kept = []
        for (var i = 0; i < priorityAlertQueue.length; i++) {
            var alert = priorityAlertQueue[i]
            if (!alert.sourceId || dashboard._tileExists(alert.sourceId))
                kept.push(alert)
        }
        if (kept.length !== priorityAlertQueue.length)
            priorityAlertQueue = kept
        return priorityAlertQueue.length
    }

    // Synchronous preflight for a Manager document. The C++ control path calls
    // this on the GUI thread before it persists the incoming document. If a
    // widget or the shared store has unfinished local work, commit that work and
    // reject this push as a conflict. A later retry is therefore an explicit
    // choice to replace the now-saved Hub state, never a silent overwrite.
    //
    // Result contract:
    //   ready        incoming state can be persisted and applied now
    //   conflict     local state was saved; this incoming request must be rejected
    //   flush-failed local state remains live/recoverable; reject the request
    //   rejected     incoming state is invalid or blocked by policy
    function preflightExternalState(json) {
        if (!store.canApplyExternal(json))
            return "rejected"

        var nodes = [dashboard]
        var pendingHosts = []
        while (nodes.length > 0) {
            var node = nodes.pop()
            if (node !== dashboard
                    && typeof node.hasPendingState === "function"
                    && node.hasPendingState())
                pendingHosts.push(node)
            var children = node.children || []
            for (var i = 0; i < children.length; i++)
                nodes.push(children[i])
        }

        var hadLocalState = store.dirty || store._savePending
                                || pendingHosts.length > 0
        var widgetFlushFailed = false
        for (var h = 0; h < pendingHosts.length; h++) {
            if (!pendingHosts[h].flushPendingState())
                widgetFlushFailed = true
        }
        if (!hadLocalState)
            return "ready"
        var storeFlushOk = store.flushNow()
        if (widgetFlushFailed || !storeFlushOk)
            return "flush-failed"
        return "conflict"
    }

    // Commit widget-local editor debounces first, then synchronously persist the
    // shared store. Called by main.qml during clean shutdown while configBridge
    // is still attached.
    function flushPendingUiState() {
        var pending = [dashboard]
        var widgetFlushOk = true
        while (pending.length > 0) {
            var node = pending.pop()
            if (node !== dashboard && typeof node.flushPendingState === "function"
                    && node.flushPendingState() === false)
                widgetFlushOk = false
            var children = node.children || []
            for (var i = 0; i < children.length; i++)
                pending.push(children[i])
        }
        return store.flushNow() && widgetFlushOk
    }

    // LOSS-001: screen deletion is destructive because removing a screen also
    // removes every widget settings bucket on it. Capture the exact screen the
    // user reviewed and refuse the action if the layout changes before confirm.
    property int pendingPageRemovalIndex: -1
    property int pendingPageRemovalRevision: -1
    property string pendingPageRemovalName: ""
    property int pendingPageRemovalWidgetCount: 0
    property string pageRemovalError: ""
    readonly property alias pageDeleteDialog: pageDeleteConfirm
    readonly property alias pageDeleteSummary: pageDeleteSummaryText
    readonly property alias pageDeleteCancelButton: cancelPageDelete
    readonly property alias pageDeleteConfirmButton: confirmPageDelete

    property int pendingWidgetRemovalPage: -1
    property int pendingWidgetRemovalRevision: -1
    property string pendingWidgetRemovalId: ""
    property string pendingWidgetRemovalType: ""
    property string pendingWidgetRemovalLabel: ""
    property string widgetRemovalError: ""
    readonly property alias widgetRemoveDialog: widgetRemoveConfirm
    readonly property alias widgetRemoveSummary: widgetRemoveSummaryText
    readonly property alias widgetRemoveCancelButton: cancelWidgetRemove
    readonly property alias widgetRemoveConfirmButton: confirmWidgetRemove

    property string pendingWidgetDataAction: ""
    property string pendingWidgetDataId: ""
    property string pendingWidgetDataType: ""
    property string pendingWidgetDataLabel: ""
    readonly property alias widgetDataDialog: widgetDataConfirm
    readonly property alias widgetDataSummary: widgetDataSummaryText
    readonly property alias widgetDataCancelButton: cancelWidgetDataAction
    readonly property alias widgetDataConfirmButton: confirmWidgetDataActionButton

    function requestPageRemoval(index) {
        var ps = store.pages()
        if (store.pageCount() <= 1 || index < 0 || index >= ps.length) return false
        var p = ps[index]
        dashboard.pendingPageRemovalIndex = index
        dashboard.pendingPageRemovalRevision = store.structureRevision
        dashboard.pendingPageRemovalName = p.name || ("Screen " + (index + 1))
        dashboard.pendingPageRemovalWidgetCount = (p.tiles || []).length
        dashboard.pageRemovalError = ""
        pageDeleteConfirm.open()
        return true
    }

    function confirmPageRemoval() {
        var i = dashboard.pendingPageRemovalIndex
        var ps = store.pages()
        if (store.structureRevision !== dashboard.pendingPageRemovalRevision
                || i < 0 || i >= ps.length || store.pageCount() <= 1) {
            dashboard.pageRemovalError = "The screen changed. Review it again before removing it."
            return false
        }
        store.removePage(i)
        swipeView.goToPage(Math.max(0, Math.min(i, store.pageCount() - 1)))
        dashboard.pendingPageRemovalIndex = -1
        dashboard.pendingPageRemovalRevision = -1
        dashboard.pageRemovalError = ""
        return true
    }

    function requestWidgetRemoval(pageIndex, tileId, tileType) {
        var pages = store.pages()
        if (pageIndex < 0 || pageIndex >= pages.length
                || !tileId || !tileType)
            return false
        var tiles = pages[pageIndex].tiles || []
        var found = false
        for (var i = 0; i < tiles.length; i++) {
            if (tiles[i].id === tileId && tiles[i].type === tileType) {
                found = true
                break
            }
        }
        if (!found) return false
        dashboard.pendingWidgetRemovalPage = pageIndex
        dashboard.pendingWidgetRemovalRevision = store.structureRevision
        dashboard.pendingWidgetRemovalId = tileId
        dashboard.pendingWidgetRemovalType = tileType
        dashboard.pendingWidgetRemovalLabel = catalog.personalDataLabel(tileType)
        dashboard.widgetRemovalError = ""
        widgetRemoveConfirm.open()
        return true
    }

    function confirmWidgetRemoval() {
        var pageIndex = dashboard.pendingWidgetRemovalPage
        var pages = store.pages()
        if (store.structureRevision !== dashboard.pendingWidgetRemovalRevision
                || pageIndex < 0 || pageIndex >= pages.length) {
            dashboard.widgetRemovalError =
                "The screen changed. Review this widget again before removing it."
            return false
        }
        var tiles = pages[pageIndex].tiles || []
        var exact = false
        for (var i = 0; i < tiles.length; i++) {
            if (tiles[i].id === dashboard.pendingWidgetRemovalId
                    && tiles[i].type === dashboard.pendingWidgetRemovalType) {
                exact = true
                break
            }
        }
        if (!exact
                || !store.removeTile(
                    pageIndex, dashboard.pendingWidgetRemovalId)) {
            dashboard.widgetRemovalError =
                "This widget is no longer on the reviewed screen."
            return false
        }
        dashboard.pendingWidgetRemovalPage = -1
        dashboard.pendingWidgetRemovalRevision = -1
        dashboard.pendingWidgetRemovalId = ""
        dashboard.pendingWidgetRemovalType = ""
        dashboard.pendingWidgetRemovalLabel = ""
        dashboard.widgetRemovalError = ""
        return true
    }

    function requestWidgetDataAction(action) {
        if (dashboard.shownId === "" || dashboard.shownType === "") return false
        if (action !== "reset" && action !== "erase") return false
        var keys = catalog.personalDataKeys(dashboard.shownType)
        if (action === "erase" && keys.length === 0) return false
        dashboard.pendingWidgetDataAction = action
        dashboard.pendingWidgetDataId = dashboard.shownId
        dashboard.pendingWidgetDataType = dashboard.shownType
        dashboard.pendingWidgetDataLabel = catalog.personalDataLabel(dashboard.shownType)
        widgetDataConfirm.open()
        return true
    }

    function confirmWidgetDataAction() {
        var id = dashboard.pendingWidgetDataId
        var type = dashboard.pendingWidgetDataType
        if (id === "" || type === "" || !dashboard._tileExists(id)) return false
        var keys = catalog.personalDataKeys(type)
        if (dashboard.pendingWidgetDataAction === "reset")
            store.resetConfiguration(id, catalog.defaults(type), keys)
        else if (dashboard.pendingWidgetDataAction === "erase") {
            if (keys.length === 0) return false
            store.erasePersonalData(id, keys)
        } else return false
        dashboard.cfgStatus = dashboard.pendingWidgetDataAction === "reset"
            ? "Configuration reset. Personal content was kept."
            : "Personal data erased. Configuration was kept."
        dashboard.pendingWidgetDataAction = ""
        dashboard.pendingWidgetDataId = ""
        dashboard.pendingWidgetDataType = ""
        dashboard.pendingWidgetDataLabel = ""
        return true
    }

    // Expanded overlay state (empty type = nothing expanded).
    property string expandedType: ""
    property string expandedId: ""
    // RETAINED copies of the expanded type/id that hold the overlay's CONTENT
    // through the close fade. closeExpanded() clears expandedType immediately
    // (that is the state machine), but if the loader/header keyed off it, the
    // widget, title and icon would vanish on frame 1 while the empty overlay
    // card was still fading out - a visible pop. These clear only once the
    // overlay is fully hidden (see the overlay's onVisibleChanged); under
    // reduce-motion the fade is 0ms, so they clear in the same event.
    property string shownType: ""
    property string shownId: ""
    onExpandedTypeChanged: {
        if (expandedType === "") return
        shownType = expandedType
        shownId = expandedId
        // Reopened while the previous overlay content was still fading (same
        // type → the Loader never reloads, so onLoaded will not refire):
        // re-inject so the live item is bound to the CURRENT instance id and
        // re-registered as the overlay item.
        if (ovlLoader.item) dashboard.overlayLoaderItem = ovlLoader.item
    }
    // Per-widget accent of the expanded tile (S7): resolve the instance's own
    // accent name to a colour, reactive to store.revision so an accent edit in
    // the config panel recolours the overlay live. Falls back to the theme
    // accent when the tile has no per-widget accent.
    property color  expandedColor: {
        store.revision
        // Keyed off the RETAINED id so the overlay's accent wash holds through
        // the close fade instead of snapping back to the theme accent.
        if (dashboard.shownId === "") return theme.accent
        var s = store.settingsFor(dashboard.shownId)
        var name = (s && s.accent) ? s.accent : ""
        return (name !== "" && theme.accentPresets[name])
               ? theme.accentPresets[name].a : theme.accent
    }
    property bool hasExpanded: expandedType !== ""

    property var host: StackView.view
    property bool _applyingAppearance: false

    // The app-global egress gate, exposed for Diagnostics' Network tab (W5
    // finding 6). One NetHub exists per app and it lives here - main.qml's
    // bindStackItem finds this property on the stack when Diagnostics is
    // opened via Ctrl+D / --diagnostics rather than the ⚙ push below.
    readonly property var netGate: netHub

    // ── Managed / org policy (E9) ────────────────────────────────────────────
    // Read ONCE at creation: the policy file is root-owned and static for the
    // life of the process (ConfigBridge caches it too). No bridge (QML test
    // harness, Manager) or no policy file ⇒ inactive ⇒ behaviour is
    // byte-for-byte the unmanaged default.
    readonly property var orgPolicy: (typeof configBridge !== "undefined" && configBridge
                                      && configBridge.policy)
                                     ? configBridge.policy() : ({ "active": false })
    readonly property bool managed: orgPolicy && orgPolicy.active === true

    // False only when an ACTIVE policy disables this widget type. Consulted by
    // the tile loaders (a disabled type renders the fallback card, never the
    // widget), the expanded overlay, and the picker filter below.
    function policyAllowsWidget(type) {
        if (!dashboard.managed) return true
        var dis = dashboard.orgPolicy.disabledWidgetTypes
        return !(dis && dis.length && dis.indexOf(type) >= 0)
    }
    // The add-picker's model for one category, with policy-disabled types
    // removed - "hidden from picker", not greyed out: an option the user can
    // never have should not be advertised.
    function policyFilteredWidgets(category) {
        var all = catalog.inCategory(category)
        if (!dashboard.managed) return all
        var out = []
        for (var i = 0; i < all.length; i++)
            if (policyAllowsWidget(all[i].type)) out.push(all[i])
        return out
    }

    // Resolved background for the CURRENT page. A background is ONE coherent
    // choice - either a wallpaper image OR an animated style - resolved per page
    // then falling back to the global appearance. A per-page choice fully wins:
    // a page that picks an animated style suppresses any GLOBAL wallpaper on that
    // page (and vice-versa), so switching styles/wallpapers always takes effect.
    property var pageBg: {
        store.revision
        var idx = 0
        try { idx = swipeView.currentIndex } catch (e) { idx = 0 }
        var pages = store.pages()
        var p = (idx >= 0 && idx < pages.length) ? pages[idx] : ({})
        var pbg = p.bg || ({})
        var a = store.appearance() || ({})
        // Per-page override present? Honour exactly what the page chose.
        if (pbg.wallpaper) return { wallpaper: pbg.wallpaper, style: pbg.style || a.bgStyle || "orbs" }
        if (pbg.style)     return { wallpaper: "", style: pbg.style }
        // No per-page override → inherit the global choice.
        return { wallpaper: a.wallpaper || "", style: a.bgStyle || "orbs" }
    }
    // Wallpaper image path. Only bundled resources and local files are renderable:
    // handing an http(s)/data/custom URL to Image.source would create a second,
    // uncounted egress path that bypasses NetHub's offline/allowlist policy. A local
    // file (absolute path or bare name in the images dir) is resolved through the
    // C++ configBridge.imageUrl() helper so paths containing spaces or '#' are
    // percent-encoded - naive "file://"+path concatenation produces a malformed
    // URL that fails to load for those characters. (The hub exposes configBridge,
    // not the Manager's `backend`.) Falls back to concatenation if absent.
    property string wallpaperSource: {
        var wp = dashboard.pageBg.wallpaper
        if (wp === null || wp === undefined) return ""
        wp = String(wp)
        if (!wp.length) return ""
        if (/^qrc:\//i.test(wp) || /^file:\//i.test(wp)) return wp
        if (/^[a-z][a-z0-9+.-]*:/i.test(wp) || wp.indexOf("//") === 0) return ""
        if (typeof configBridge !== "undefined" && configBridge && configBridge.imageUrl)
            return configBridge.imageUrl(wp)
        return wp.charAt(0) === "/" ? "file://" + wp : wp
    }
    // Master "animate the backdrop" toggle (persisted via appearance).
    property bool animatedBg: root.animatedBackground

    // ── Background ─────────────────────────────────────────────────────────
    // Rich 3-stop gradient (theme-driven - vivid for the "fancy" themes).
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            orientation: Gradient.Vertical
            GradientStop { position: 0.0; color: theme.backgroundColor }
            GradientStop { position: 0.55; color: theme.backgroundColor2 }
            GradientStop { position: 1.0; color: theme.backgroundColor3 }
        }
    }
    // Animated backdrop for the current page (orbs / waves / stars / none),
    // shown when no wallpaper image is set. Motion honours the animate toggle
    // and reduce-motion; the style resolves per-page → global default.
    BackdropLayer {
        anchors.fill: parent
        // "Animated background" OFF now genuinely removes the backdrop (plain
        // gradient shows) rather than leaving it frozen - that's what the toggle
        // reads as. Reduce-motion, by contrast, KEEPS the backdrop but stops its
        // motion. Gating visible unloads the component entirely (zero cost) when a
        // wallpaper is set, in High-Contrast, or with the animation switched off.
        visible: dashboard.wallpaperSource === "" && theme.decorative && dashboard.animatedBg
        style: dashboard.pageBg.style
        accent: theme.accent
        // effectiveReduceMotion, not the raw persisted flag: the OS reduce-motion
        // signal and the explicit on/off preference must stop the backdrop too.
        running: !theme.effectiveReduceMotion
    }
    // Optional wallpaper image (uploaded + assigned via the Manager). Sits over
    // the gradient with a scrim so cards and text stay legible.
    Image {
        id: wallpaper
        anchors.fill: parent
        source: dashboard.wallpaperSource
        visible: source != ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true; cache: true
        // Async decode means the image lands a beat after the page shows -
        // fade it over the gradient instead of letting it pop in fully formed.
        // (Instant under reduce-motion; a cached source skips Loading entirely.)
        opacity: status === Image.Ready ? 1.0 : 0.0
        Behavior on opacity { NumberAnimation { duration: theme.motionSlow } }
    }
    Rectangle {
        anchors.fill: parent; visible: wallpaper.visible
        // Ride the wallpaper's own fade so the scrim can't darken the plain
        // gradient before the image has arrived.
        opacity: wallpaper.opacity
        // Light scrim only - enough to keep out-of-card text legible without
        // washing the wallpaper out. Card legibility comes from the frosted glass.
        color: Qt.rgba(theme.backgroundColor.r, theme.backgroundColor.g, theme.backgroundColor.b, 0.28)
    }
    // Accent glow wash - subtle vibrancy/depth (skipped in high-contrast).
    Rectangle {
        anchors.fill: parent
        opacity: theme.decorative ? 0.10 : 0.0
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: theme.accent }
            GradientStop { position: 0.5; color: "transparent" }
            GradientStop { position: 1.0; color: theme.accent2 }
        }
    }

    // Drive time-based widgets once per second. Runs unconditionally: this is an
    // always-on secondary-display dashboard that is rarely the "active" window, and
    // gating on Qt.application.active previously froze updates (and, since the scene
    // then never changed, the compositor stopped presenting frames - which made
    // taps appear to do nothing for seconds).
    // SELF-CORRECTING, and it has to be: a plain `interval: 1000; repeat: true`
    // re-arms 1000ms after each HANDLING, so every frame hitch, GC pause or load
    // spike is added to the phase and never given back. It is also never aligned to
    // the wall-clock second to begin with. Widgets format `new Date()` when this
    // fires, so a drifting tick renders the same second twice (the clock appears to
    // stall) and then skips one (it appears to jump two). Re-aiming at the next real
    // boundary every tick makes the error non-cumulative: a late fire simply shortens
    // the next wait. The +5ms lands us just PAST the boundary - Qt may fire a hair
    // early, and formatting at 999.7ms would show the second we just left.
    function _msToNextSecond() { return Math.max(1, 1000 - (Date.now() % 1000) + 5) }
    Timer {
        id: secondTick
        repeat: false
        running: false
        onTriggered: { dashboard._tick++; interval = dashboard._msToNextSecond(); start() }
        Component.onCompleted: { interval = dashboard._msToNextSecond(); start() }
    }

    DashboardStore {
        id: store
        preserveUnknownTileSizes: !dashboard.sessionWidgetsEnabled
        persistenceEnabled: dashboard.sessionWidgetsEnabled
    }
    Rectangle {
        id: saveFailureBanner
        objectName: "saveFailureBanner"
        z: 10000
        visible: store.saveFailed
        readonly property bool stackActions: width < 760
        readonly property real maximumHeight:
            Math.max(theme.touchTertiary + theme.spacingMd * 2,
                     parent.height - anchors.topMargin * 2)
        readonly property real desiredMessageHeight:
            saveFailureTitle.implicitHeight + 4
            + saveFailureMessage.implicitHeight
        readonly property real requiredContentHeight:
            stackActions
            ? desiredMessageHeight + theme.spacingMd
              + theme.touchTertiary
            : Math.max(desiredMessageHeight,
                       theme.touchTertiary)
        anchors.top: parent.top
        anchors.topMargin: theme.spacingSm
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(parent.width - theme.spacingLg * 2, 1120)
        height: Math.min(maximumHeight,
                         Math.ceil(requiredContentHeight + theme.spacingMd * 2))
        radius: theme.radiusMd
        color: "#2B1717"
        border.width: 2
        border.color: "#F85149"

        GridLayout {
            id: saveFailureContent
            anchors.fill: parent
            anchors.margins: theme.spacingMd
            columns: saveFailureBanner.stackActions ? 1 : 2
            columnSpacing: theme.spacingMd
            rowSpacing: theme.spacingMd

            ColumnLayout {
                id: saveFailureMessageColumn
                Layout.row: 0
                Layout.column: 0
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.minimumWidth: 0
                spacing: 4
                Text {
                    id: saveFailureTitle
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                    text: "Changes are not saved"
                    color: "#FFFFFF"
                    font.pixelSize: 20
                    font.bold: true
                }
                ScrollView {
                    id: saveFailureMessageScroll
                    objectName: "saveFailureMessageScroll"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.minimumWidth: 0
                    Layout.minimumHeight: 24
                    clip: true
                    ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                    Text {
                        id: saveFailureMessage
                        objectName: "saveFailureMessage"
                        width: saveFailureMessageScroll.availableWidth
                        text: store.saveFailureMessage
                              + (store.recoveryPath !== ""
                                 ? "\nRecovery copy: " + store.recoveryPath : "")
                        color: "#F4D7D7"
                        font.pixelSize: 17
                        wrapMode: Text.Wrap
                    }
                }
            }
            RowLayout {
                id: saveFailureActions
                Layout.row: saveFailureBanner.stackActions ? 1 : 0
                Layout.column: saveFailureBanner.stackActions ? 0 : 1
                Layout.fillWidth: saveFailureBanner.stackActions
                Layout.preferredHeight: theme.touchTertiary
                Layout.minimumHeight: theme.touchTertiary
                Layout.maximumHeight: theme.touchTertiary
                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                spacing: theme.spacingMd

                Item {
                    visible: saveFailureBanner.stackActions
                    Layout.fillWidth: saveFailureBanner.stackActions
                }
                Button {
                    objectName: "retryFailedSaveButton"
                    text: "Retry"
                    Layout.preferredWidth: 104
                    Layout.minimumWidth: 104
                    Layout.preferredHeight: theme.touchTertiary
                    Layout.minimumHeight: theme.touchTertiary
                    Layout.maximumHeight: theme.touchTertiary
                    Layout.alignment: Qt.AlignVCenter
                    onClicked: store.retrySave()
                }
                Button {
                    objectName: "discardFailedSaveButton"
                    text: "Discard"
                    Layout.preferredWidth: 112
                    Layout.minimumWidth: 112
                    Layout.preferredHeight: theme.touchTertiary
                    Layout.minimumHeight: theme.touchTertiary
                    Layout.maximumHeight: theme.touchTertiary
                    Layout.alignment: Qt.AlignVCenter
                    onClicked: store.discardUnsaved(
                        typeof configBridge !== "undefined" && configBridge
                            ? configBridge.starterLayout() : "")
                }
            }
        }
    }
    readonly property int observedStoreStructureRevision: store.structureRevision
    onObservedStoreStructureRevisionChanged: dashboard.prunePriorityAlerts()
    WidgetCatalog { id: catalog }
    readonly property alias widgetStore: store
    readonly property alias widgetCatalog: catalog
    WidgetSizes { id: sizes }
    WidgetPacker { id: packer }
    // The curated screen library - consumed post-setup by the PresetPicker
    // below (W5 finding 3: it used to have no consumer outside the wizard).
    PresetCatalog { id: presetLib }
    // The single app-global egress gate. Every net widget routes through this one
    // instance (injected below), so the offline switch + host allowlist + request
    // counters are global. `offline` is driven by an appearance flag (set by a
    // future global toggle / managed config); default off.
    NetHub {
        id: netHub
        // POLICY PIN (E9): an active org policy with net_offline=true holds the
        // kill switch ON no matter what the user's appearance flag says - this
        // is what makes the no-egress attestation enforceable rather than
        // advisory. Without a policy, the user's own flag governs, exactly as
        // before.
        offline: {
            var _ = store.revision
            if (dashboard.managed && dashboard.orgPolicy.netOffline === true) return true
            return store.appearance().netOffline === true
        }
        // POLICY PIN (E9): allowHosts comes from the org policy and nowhere
        // else - no user-config path assigns this property, so the binding IS
        // the pin and user config cannot widen it. (NetHub.request()'s
        // per-request opts.allow would take precedence over this list; no
        // shipped widget passes it - see docs/security/managed-config.md.)
        allowHosts: (dashboard.managed && dashboard.orgPolicy.allowedHosts)
                    ? dashboard.orgPolicy.allowedHosts : []
        // E7: the hub's ConfigBridge resolves ${env:}/file: credential refs. The
        // Manager has no configBridge (and does no egress), and the QML test
        // harness has none either - NetHub fails a ref closed when it is absent
        // rather than sending the reference as a token.
        secretResolver: (typeof configBridge !== "undefined") ? configBridge : null
    }
    // E10: the opt-in update check. OFF by default (the `updateCheck` appearance
    // flag is written by SettingsPanel); with a default config this constructs
    // no request - the no-egress attestation depends on that. When enabled, its
    // single GET rides the same NetHub gate as every widget.
    UpdateChecker {
        id: updateChecker
        netHub: netHub
        enabled: { var _ = store.revision; return store.appearance().updateCheck === true }
        currentVersion: (typeof configBridge !== "undefined" && configBridge && configBridge.appVersion)
                        ? configBridge.appVersion() : ""
        envResolver: (typeof configBridge !== "undefined") ? configBridge : null
    }
    // Re-check daily while opted in. The Timer lives here (an Item can host
    // children on every Qt 6) rather than inside the QtObject service.
    Timer {
        interval: 24 * 60 * 60 * 1000; repeat: true
        running: updateChecker.enabled
        onTriggered: updateChecker.check()
    }
    WidgetConfigSchema { id: cfgSchema }

    // ── Tier-0 user widgets (E3) ─────────────────────────────────────────────
    // Validates manifests scanned from $XDG_DATA_HOME/xeneon-edge-hub/widgets
    // and feeds WidgetCatalog.userItems (see docs/widgets/manifest-spec.md).
    // Gated by the `enableUserWidgets` appearance flag, DEFAULT OFF - the
    // attested default configuration never scans the directory.
    UserWidgetCatalog {
        id: userCatalog
        sizesModel: sizes
        shippedTypes: {
            var out = []
            for (var i = 0; i < catalog.items.length; i++) out.push(catalog.items[i].type)
            return out
        }
        urlResolver: (typeof configBridge !== "undefined" && configBridge && configBridge.imageUrl)
                     ? function (p) { return configBridge.imageUrl(p) } : null
    }
    // Test seam: replaces ConfigBridge.listUserWidgets as the scan source, so
    // the offscreen suite can both feed fixtures and PROVE the flag-off path
    // performs no scan at all (the provider is never invoked).
    property var userWidgetProvider: null

    // Whether Tier-0 user widgets are enabled. A plain config read (managed
    // config can pin it), default FALSE. Registration must happen BEFORE the
    // store loads - persisted tile sizes validate against declared `sizes` -
    // so before the store is loaded this peeks at the same persisted document
    // store.load() is about to read.
    function _userWidgetsFlag() {
        if (!dashboard.sessionWidgetsEnabled)
            return false
        // The org policy vetoes user widgets OUTRIGHT - before the user's own
        // preference is even consulted. Policy beating preference is the
        // definition of a managed session, and putting the veto here (not at a
        // call site) means every present and future load path inherits it.
        if (dashboard.managed && dashboard.orgPolicy.disableUserWidgets === true)
            return false
        if (store.loaded) return store.appearance().enableUserWidgets === true
        if (typeof configBridge !== "undefined" && configBridge && configBridge.uiState) {
            try {
                var doc = JSON.parse(configBridge.uiState() || "{}")
                return !!(doc && doc.appearance && doc.appearance.enableUserWidgets === true)
            } catch (e) { return false }
        }
        return false
    }

    // (Re)load user widgets into BOTH catalog instances - the dashboard's own
    // (tiles, picker, overlay) and the store's private one (size validation on
    // addTile/setTileSize/load). Flag off → everything cleared and NO scan
    // happens. Returns how many user widgets are registered.
    function _loadUserWidgets() {
        if (!dashboard._userWidgetsFlag()) {
            userCatalog.clear()
        } else {
            var raw = dashboard.userWidgetProvider ? dashboard.userWidgetProvider()
                    : ((typeof configBridge !== "undefined" && configBridge && configBridge.listUserWidgets)
                       ? configBridge.listUserWidgets() : [])
            userCatalog.load(raw)
        }
        catalog.userItems = userCatalog.items
        store._catalog.userItems = userCatalog.items
        return userCatalog.items.length
    }

    // Colour + sizing tokens for the shared ConfigField / WidgetConfigPanel,
    // derived from the theme (re-evaluates when the theme changes) and sized for
    // touch (larger controls than the desktop Manager).
    property var cfgCol: ({
        textPrimary: theme.textPrimary, textSecondary: theme.textSecondary,
        bg: theme.backgroundColor, accent: theme.accent, border: theme.cardBorder,
        panel: theme.cardBackground, panelAlt: theme.cardBackgroundAlt,
        radius: theme.radiusMd, ctlH: theme.touchSecondary, fontBase: theme.fontLabel
    })

    // Geocode status shown in the weather config panel.
    property string cfgStatus: ""
    function cfgAction(action) {
        if (action === "geocode" && overlayLoaderItem && overlayLoaderItem.hasOwnProperty("geocode")) {
            var place = store.settingsFor(expandedId).place || ""
            if (!place.trim().length) { cfgStatus = "Type a place name first."; return }
            cfgStatus = "Searching for “" + place + "”…"
            overlayLoaderItem.geocode(place)
        } else if (action === "testConnection" && overlayLoaderItem
                   && overlayLoaderItem.hasOwnProperty("testConnection")) {
            cfgStatus = ""
            overlayLoaderItem.testConnection(netHub)
        }
    }
    property var overlayLoaderItem: null

    // Apply a preset from the post-setup Screens picker (W5 finding 3): the
    // store's normal seed path (resetTo), with two deliberate twists.
    //
    //  • POLICY (E9): an org-forced preset wins over any interactive choice.
    //    The picker surface is already absent under the lock, but the guard
    //    lives HERE so no other caller can ever bypass the policy.
    //  • "Your theme stays" - and it must stay across RESTART, not just live.
    //    A preset document carries only its character keys (bgStyle/
    //    animatedBg/glow/presetSurface), so resetTo() would drop
    //    every other persisted appearance key: themeMode/accent would fall
    //    back to the stale legacy [theme] values on the next launch (W5
    //    finding 15), and - worse - a user's netOffline/updateCheck/
    //    enableUserWidgets choices would silently revert to defaults. So every
    //    prior appearance key the preset does not define is carried over.
    //  • Accessibility is never preset character. Reduced motion is an explicit
    //    user or OS preference and no screen is allowed to set it implicitly.
    //
    // Returns whether the preset was applied.
    function applyPreset(presetId) {
        if (store.policyLockedPreset !== "") return false
        var id = String(presetId || "")
        if (id === "") return false
        if (id !== "blank" && !presetLib.has(id)) return false
        var prev = store.appearance()
        var keep = {}
        for (var k in prev) keep[k] = prev[k]
        store.resetTo(id)
        for (var kk in keep)
            if (store.appearance()[kk] === undefined)
                store.setAppearance(kk, keep[kk])
        applyAppearance()
        // Land the user on the new layout's first page, not an out-of-range
        // index left over from a longer document.
        swipeView.currentIndex = 0
        return true
    }

    // Add a curated screen as a NEW page (additive) and swipe to it. Unlike
    // applyPreset (wizard/reset - full replace), this never disturbs the user's
    // other pages or the global appearance. Returns whether a page was added.
    function appendPreset(presetId) {
        var idx = store.appendPreset(presetId)   // -1 when managed/locked or unknown id
        if (idx < 0) return false
        swipeView.goToPage(idx)                  // lands once the SwipeView grows to fit
        return true
    }

    // Close the expanded overlay + clear its transient state (shared by the
    // header back button and the reachable bottom "Done" bar).
    function closeExpanded() {
        // The expanded widget can own an editor buffer that is not yet in the
        // shared store. Commit that buffer and the resulting store mutation
        // before destroying the overlay. If either step fails, leave the live
        // editor on screen so its text remains recoverable.
        var widgetFlushOk = !ovlLoader.hasPendingState()
                            || ovlLoader.flushPendingState()
        var storeFlushOk = widgetFlushOk && store.flushNow()
        if (!widgetFlushOk || !storeFlushOk) {
            dashboard.cfgStatus =
                "Could not save these changes. The editor remains open so you can retry."
            return false
        }
        dashboard.expandedType = ""
        dashboard.expandedId = ""
        dashboard.cfgStatus = ""
        dashboard.overlayLoaderItem = null
        return true
    }

    Component.onCompleted: {
        // User widgets FIRST: load() coerces every persisted tile size against
        // the type's declared sizes, so user types must already be registered
        // or their tiles would be coerced to the baseline as "unknown".
        // (_userWidgetsFlag itself honours the org policy's veto.)
        _loadUserWidgets()
        // E9: an org-forced preset replaces the saved layout for this session
        // (the store's lock also stops every disk write, so the user's own
        // layout survives underneath and comes back if the policy is removed).
        if (dashboard.managed && dashboard.orgPolicy.forcePreset)
            store.lockToPreset(dashboard.orgPolicy.forcePreset)
        else
            store.load(typeof configBridge !== "undefined" && configBridge ? configBridge.starterLayout() : "")
        applyAppearance()
        // QA: auto-open a widget's expanded config view (XENEON_EXPAND=<type>).
        if (typeof _expandType !== "undefined" && _expandType) {
            var pages = store.pages()
            for (var p = 0; p < pages.length; p++)
                for (var t = 0; t < (pages[p].tiles || []).length; t++)
                    if (pages[p].tiles[t].type === _expandType) {
                        dashboard.expandedId = pages[p].tiles[t].id
                        dashboard.expandedType = _expandType
                        return
                    }
        }
        // QA: reproduce/verify add-page navigation against the REAL stack
        // (XENEON_QA_ADDPAGES=n). A qmltestrunner can't load main.qml's qrc: Dashboard,
        // so this is how the snap-back is exercised end-to-end.
        if (typeof _qaAddPages !== "undefined" && _qaAddPages > 0) {
            dashboard.editMode = true
            qaAddTimer.remaining = _qaAddPages
            qaAddTimer.start()
        }
    }

    // QA add-page driver (compiled behaviour only meaningful under XENEON_QA_HOOKS).
    Timer {
        id: qaAddTimer
        property int remaining: 0
        interval: 450; repeat: true
        onTriggered: {
            store.addPage("")
            swipeView.goToPage(store.pageCount() - 1)
            remaining--
            console.warn("QA_ADDPAGE count=" + store.pageCount()
                        + " currentIndex=" + swipeView.currentIndex)
            if (remaining <= 0) { stop(); qaFinalTimer.start() }
        }
    }
    Timer {
        id: qaFinalTimer; interval: 1500; repeat: false
        onTriggered: console.warn("QA_ADDPAGE_FINAL count=" + swipeView.count
                                 + " currentIndex=" + swipeView.currentIndex
                                 + " expected=" + (swipeView.count - 1))
    }


    // Apply a UI-state document pushed live from the companion Manager app.
    // Called by main.qml when the C++ ControlServer receives a new layout.
    // The screen the panel is currently showing (0-based). Read by main.qml so
    // the hub can report it over the control socket (getUiState -> currentPage),
    // letting the Manager confirm the panel mirrored its selected screen.
    readonly property int currentPageIndex: swipeView.currentIndex

    // Show a specific screen, on request from the Manager (setActivePage). Uses
    // the same robust landing as preset/append (goToPage re-asserts once the
    // SwipeView has grown to fit), so a page request that arrives right after a
    // structure change - e.g. the Manager added a screen and selected it - still
    // lands instead of being clobbered by the model reset to page 0.
    function goToPageExternal(idx) {
        if (idx >= 0)
            swipeView.goToPage(idx)
    }

    function applyExternalState(json) {
        if (!store.applyExternal(json)) return false
        applyAppearance()
        // The pushed appearance may have flipped `enableUserWidgets` (e.g.
        // a managed config forcing it off): re-run the loader so the flag
        // takes effect live - off clears the registry without any scan.
        _loadUserWidgets()
        // A live push may have removed (or replaced) the tile we're currently
        // expanded on. Leaving the overlay open would let its config panel keep
        // writing to an instanceId that no longer exists on any page - an orphan
        // settings entry. Close the overlay when its tile is gone.
        if (dashboard.hasExpanded && !_tileExists(dashboard.expandedId))
            closeExpanded()
        return true
    }

    // True if a tile with this instance id still exists on some page.
    function _tileExists(id) {
        if (!id) return false
        var pages = store.pages()
        for (var p = 0; p < pages.length; p++) {
            var tiles = pages[p].tiles || []
            for (var t = 0; t < tiles.length; t++)
                if (tiles[t].id === id) return true
        }
        return false
    }

    // Apply persisted appearance to the shared theme (main.qml root).
    function applyAppearance() {
        _applyingAppearance = true
        var a = store.appearance()
        if (a.themeMode) root.themeMode = a.themeMode
        theme.applyTheme(a.themeMode ? a.themeMode : root.themeMode)
        if (a.accent) theme.applyAccent(a.accent)
        if (a.glass !== undefined) root.glassOpacity = a.glass
        if (a.glow !== undefined) root.showWidgetGlow = a.glow
        if (a.reduceMotion !== undefined) root.reduceMotion = a.reduceMotion
        theme.textScale = a.textScale !== undefined ? a.textScale : 1.15
        theme.fontChoice = a.fontChoice || "hyperlegible"
        if (a.animatedBg !== undefined) root.animatedBackground = a.animatedBg
        if (a.orientation) root.orientationMode = a.orientation
        _applyingAppearance = false
    }

    // Persist appearance changes made through the SettingsPanel.
    Connections {
        target: root
        enabled: store.loaded && !dashboard._applyingAppearance
        // Reduced harness roots do not necessarily expose every ApplicationWindow
        // appearance alias. Production root does. Missing optional signals must
        // not turn an otherwise valid user-widget test into warning noise.
        ignoreUnknownSignals: true
        function onAccentNameChanged() { store.setAppearance("accent", root.accentName) }
        function onGlassOpacityChanged() { store.setAppearance("glass", root.glassOpacity) }
        function onShowWidgetGlowChanged() { store.setAppearance("glow", root.showWidgetGlow) }
        function onReduceMotionChanged() { store.setAppearance("reduceMotion", root.reduceMotion) }
        function onTextScaleChanged() { store.setAppearance("textScale", root.textScale) }
        function onFontChoiceChanged() { store.setAppearance("fontChoice", root.fontChoice) }
        function onThemeModeChanged() { store.setAppearance("themeMode", root.themeMode) }
        function onAnimatedBackgroundChanged() { store.setAppearance("animatedBg", root.animatedBackground) }
        function onOrientationModeChanged() { store.setAppearance("orientation", root.orientationMode) }
    }

    // ── Fallback tile (error boundary for unknown / unavailable widgets) ─────
    Component {
        id: fallbackTile
        WidgetChrome {
            property var metrics: ({})
            property bool expanded: false
            property bool active: true
            property var store: null
            property string instanceId: ""
            title: "Unavailable"; iconName: "ui-warning"; accentColor: theme.textTertiary
            Text {
                anchors.centerIn: parent; width: parent.width * 0.85
                horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                text: "This widget isn't available."
                color: theme.textSecondary; font.pixelSize: theme.fontMinimum
            }
        }
    }

    // How much ROOM a named size gives, in the vocabulary widgets already speak
    // (WidgetChrome: compact/wide/tall/large/full). Named rather than numeric so a
    // widget asks "have I got room?" instead of re-deriving it from geometry it
    // shouldn't know about.
    //
    // The derivation itself lives in WidgetSizes.classFor - it is shared with the
    // Manager's preview, which MUST answer identically or the preview lies. This
    // stays as a named seam because the dashboard is where the rest of the file
    // (and its tests) ask the question.
    function sizeClassFor(size, landscape) { return sizes.classFor(size, landscape) }

    // The next size in this type's own legal list, wrapping around - the edit-mode
    // resize button. The old fixed 1x1→2x1→1x2→2x2 cycle has NO equivalent: those
    // spans are not sizes, and every widget type now declares which sizes it can
    // honestly render, so the cycle has to be the type's own list or it would offer
    // shapes the widget was never built for. A type with one size stays put. (The
    // picker sheet that shows the whole list at once is a later phase; this keeps
    // the button honest in the meantime.)
    function nextSize(type, current) {
        var legal = catalog.sizesFor(type)
        if (!legal.length) return ""
        var i = legal.indexOf(current)
        return legal[(i + 1) % legal.length]          // indexOf -1 → wraps to legal[0]
    }

    // ── Pages ────────────────────────────────────────────────────────────────
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: theme.spacingMd
        spacing: theme.spacingSm

        SwipeView {
            id: swipeView
            objectName: "pageSwipe"
            Layout.fillWidth: true; Layout.fillHeight: true
            clip: true
            interactive: !dashboard.editMode

            // Landing on a just-added page fights the SwipeView's internal ListView:
            // the int-model Repeater grows `count` a frame later, and - crucially - the
            // ListView re-derives currentIndex from `contentX` on a DEFERRED relayout
            // (the new page's build, and in landscape the larger swapped contentRoot
            // geometry, settle late), snapping the view back toward page 0 AFTER a
            // one-shot set. So we (1) COMMIT the position with positionViewAtIndex so
            // there is no stale contentX to snap back to, and (2) re-assert on a timer
            // that keeps going until the index has held for a LONG window (~700ms,
            // spanning the deferred relayout) - not the earlier ~120ms that a late
            // reset simply outlived.
            property int _wantIndex: -1
            function _applyWant() {
                var w = swipeView._wantIndex
                if (w < 0 || w >= swipeView.count) return
                if (swipeView.currentIndex !== w) swipeView.currentIndex = w
                // Commit the ListView's scroll position to the real index (guarded:
                // SwipeView's contentItem is a ListView, but stay defensive).
                var ci = swipeView.contentItem
                if (ci && typeof ci.positionViewAtIndex === "function")
                    ci.positionViewAtIndex(w, ListView.SnapPosition)
                else if (ci && typeof ci.forceLayout === "function")
                    ci.forceLayout()
            }
            function goToPage(idx) {
                swipeView._wantIndex = idx
                goHoldTimer.held = 0; goHoldTimer.ticks = 0
                swipeView._applyWant()
                goHoldTimer.restart()
            }
            onCountChanged: if (_wantIndex >= 0) _applyWant()
            Timer {
                id: goHoldTimer
                interval: 50; repeat: true
                property int held: 0
                property int ticks: 0
                onTriggered: {
                    var w = swipeView._wantIndex
                    if (w < 0) { stop(); return }
                    if (w < swipeView.count) {
                        if (swipeView.currentIndex !== w) { swipeView._applyWant(); held = 0 }
                        else held++
                    }
                    ticks++
                    // Require a LONG sustained hold (~700ms) so a LATE deferred relayout
                    // can't win after we stop; give up after ~2.5s.
                    if (held >= 14 || ticks >= 50) { swipeView._wantIndex = -1; stop() }
                }
            }

            Repeater {
                // A COUNT, not the pages array. `store.pages()` returns a fresh array
                // of freshly-cloned page objects on every structure edit (see
                // DashboardStore._commitStructure: `data = _clone(data)`), and a
                // Repeater handed a new JS array resets its whole delegate model -
                // every page delegate, and with it every tile delegate and every live
                // widget instance, was destroyed and rebuilt for a single tile move.
                // That is why a reorder TELEPORTED: there was no delegate left to
                // animate, only a new one already sitting at the destination.
                //
                // An int model keys delegates by INDEX, so a structure edit adds or
                // removes only at the end and pages 0..n-1 survive it. Each page then
                // re-reads its own slice below (still keyed on structureRevision, so a
                // per-widget settings keystroke still doesn't reach here).
                model: { store.structureRevision; return store.pageCount() }
                delegate: Item {
                    id: pageItem
                    required property int index
                    readonly property var page: {
                        store.structureRevision
                        var ps = store.pages()
                        return (pageItem.index >= 0 && pageItem.index < ps.length)
                               ? ps[pageItem.index] : ({ name: "", tiles: [] })
                    }
                    property var tiles: {
                        store.structureRevision
                        return (pageItem.page && pageItem.page.tiles) ? pageItem.page.tiles : []
                    }

                    // Which physical axis the long axis lands on. This is the ONLY
                    // place orientation enters a page's layout: the packing below is
                    // orientation-free, so a rotation re-projects it rather than
                    // re-packing - the dashboard turns WITH the panel instead of
                    // reshuffling under the user. (See WidgetPacker.)
                    property bool landscape: width > height

                    // The page's ONE packing, in semantic (short, long) space. Keyed on
                    // structureRevision like the old tile Repeater: only add/remove/
                    // move/resize re-packs, not a settings keystroke.
                    property var placements: {
                        store.structureRevision
                        return packer.pack(pageItem.tiles)
                    }

                    // ── The tile Repeater's model ────────────────────────────
                    // `placements` is a fresh JS array every time it re-packs, so
                    // feeding it to the Repeater directly reset the delegate model on
                    // every structure edit - same teleport as the page Repeater above,
                    // one level down. This ListModel is SYNCED to `placements` by id
                    // instead: a tile that still exists keeps its row, so it keeps its
                    // delegate, so it keeps its loaded widget instance - and its new
                    // slot arrives as a property change the delegate can EASE to
                    // (see animS/animL on the cell).
                    //
                    // Row order carries no meaning here: a cell is positioned
                    // absolutely from its own (s, l), and the packer never overlaps
                    // two tiles, so there is nothing for row order to decide. Rows are
                    // therefore patched in place rather than moved - the minimum
                    // churn that still expresses the edit.
                    //
                    // The model is also where a tile's LIFETIME lives, which is what
                    // lets a removed tile fade instead of blinking out: `dying` keeps
                    // the row - and therefore the delegate - alive past the packing that
                    // dropped it, and `entering` marks a row the page grew after it was
                    // born. Both are properties of the ROW (a removed tile is exactly
                    // "a row that is no longer in the packing"), so neither is a mode
                    // flag that can drift out of sync with what is on screen.
                    ListModel { id: placementModel }

                    // True once this page delegate has finished being built. It is the
                    // whole difference between the model being SEEDED and the page
                    // GROWING a tile: the rows appended during creation are the page's
                    // starting state and must not animate in (or every tile would fade
                    // in on every app start, and on every rotation that recreated a
                    // page), while a row appended after it is an add. Monotonic, set
                    // exactly once at the end of creation - it cannot come to mean
                    // anything else later.
                    property bool _live: false

                    // One packer placement → one model row. The string roles are
                    // coerced because a ListModel FIXES each role's type on the first
                    // append: the store's load/applyExternal boundary guarantees a tile
                    // has an id and a legal size, but nothing validates `type`, and a
                    // hand-written document with a typeless tile would otherwise seed
                    // the role with `undefined`. "" is the value the tile loaders below
                    // already treat as "no usable type" (→ the Unavailable card).
                    //
                    // `dying`/`entering` are declared here for the same reason: the
                    // first append fixes the ROLE SET too, so a role that only ever
                    // appeared later would not exist at all.
                    function _row(p) {
                        return ({ tileId: p.id || "", tileType: p.type || "",
                                  tileSize: p.size || "", tileIdx: p.idx,
                                  ps: p.s, pl: p.l, pes: p.es, pel: p.el,
                                  dying: false, entering: false })
                    }
                    // Drop a faded-out row. Called by the cell when its exit fade ends -
                    // by id, because rows shift as others are reaped.
                    //
                    // Only a DYING row may be reaped: this is a fade closing the row it
                    // opened, not a general-purpose delete. A row resurrected mid-fade
                    // (see _syncPlacements) is live again and must survive the animation
                    // that was removing it. That is belt-and-braces with the cell's
                    // `exitFade.stop()` - measured: either one alone is enough today, so
                    // this recheck is not load-bearing for the resurrection path. It is
                    // kept because it is what makes the RULE true of the function itself
                    // rather than of its one caller, and a lifetime rule should not have
                    // a hole waiting for a second caller. Pinned directly, so it cannot
                    // rot into a line that only looks like it does something.
                    function _reapRow(id) {
                        for (var r = 0; r < placementModel.count; r++)
                            if (placementModel.get(r).tileId === id && placementModel.get(r).dying) {
                                placementModel.remove(r)
                                delete pageItem._dyingSince[id]
                                return true
                            }
                        return false
                    }

                    // When each tileId started fading out. Not a model role: the sweep
                    // below is bookkeeping about rows, not state a delegate binds to.
                    property var _dyingSince: ({})

                    // Reap rows whose exit fade can never finish.
                    //
                    // A `dying` row is normally removed by _reapRow from the cell's
                    // exitFade.onFinished. If the delegate is destroyed before that
                    // callback runs - page teardown, a model reset, a sync racing the
                    // fade - the row is STRANDED: it matches no placement, so the
                    // removal loop skips it (already dying) and the survivor loop
                    // `continue`s past it. Nothing else can reach it, so it stays in
                    // placementModel for the process lifetime and the model grows
                    // without bound on repeated add/remove. (manager/qml/EdgeClone.qml
                    // avoids this by clearing the model on a page switch; the hub's
                    // per-page models never get that reseed, so they need this instead.)
                    //
                    // The margin is deliberately wide - 4x the fade, floor 2s - so this
                    // can never race a fade that is merely slow. It is a backstop for
                    // fades that are GONE, not a second reaper.
                    function _sweepStaleDying() {
                        var now = Date.now()
                        var grace = Math.max((theme.motionRemove || 0) * 4, 2000)
                        for (var r = placementModel.count - 1; r >= 0; r--) {
                            var row = placementModel.get(r)
                            if (!row.dying) continue
                            var since = pageItem._dyingSince[row.tileId]
                            if (since === undefined) { pageItem._dyingSince[row.tileId] = now; continue }
                            if (now - since > grace) {
                                placementModel.remove(r)
                                delete pageItem._dyingSince[row.tileId]
                            }
                        }
                    }
                    // Returns how many rows the model ended up with - one per placed
                    // tile, plus any still fading out. (Same shape as _loadUserWidgets
                    // above: a count the caller and the tests can check the sync
                    // against.)
                    function _syncPlacements() {
                        var ps = pageItem.placements || []
                        var byId = Object.create(null)
                        for (var i = 0; i < ps.length; i++) byId[ps[i].id] = ps[i]

                        // Gone → the tile was removed. Its delegate has to OUTLIVE the
                        // packing that dropped it or there is nothing left to fade, so
                        // the row is marked `dying` and the cell reaps it when its fade
                        // ends (see the exit fade below).
                        //
                        // REDUCE MOTION: the duration token does the real work - at
                        // motionRemove 0 the exit fade finishes SYNCHRONOUSLY when it is
                        // started, so the row is reaped in this same event even by the
                        // `dying` path (measured: dropping this branch does NOT make the
                        // removal observably late). The branch is kept as the explicit
                        // statement of intent, and to skip marking, animating and reaping
                        // a row for a fade that cannot be seen - not as the mechanism.
                        // Smooth is not more motion.
                        // Stranded rows from fades that never completed. Runs first so a
                        // swept row cannot be counted as a survivor below.
                        pageItem._sweepStaleDying()

                        for (var r = placementModel.count - 1; r >= 0; r--) {
                            var goneId = placementModel.get(r).tileId
                            if (byId[goneId] !== undefined) continue
                            if (theme.motionRemove > 0) {
                                if (!placementModel.get(r).dying) {
                                    placementModel.setProperty(r, "dying", true)
                                    pageItem._dyingSince[goneId] = Date.now()
                                }
                            } else {
                                placementModel.remove(r)   // backwards: remove() shifts the tail
                                delete pageItem._dyingSince[goneId]
                            }
                        }

                        // Survivors → patch in place. THIS is the move: same row, same
                        // delegate object, new slot. set() only touches the roles that
                        // actually differ, so an unmoved tile is not even notified.
                        var seen = Object.create(null)
                        for (var r2 = 0; r2 < placementModel.count; r2++) {
                            var row = placementModel.get(r2)
                            var p = byId[row.tileId]
                            // A row with no placement is one of the dying rows above,
                            // held open only for its fade. It is not in the packing, so
                            // there is nothing to reconcile it against - and reading
                            // `p.s` off it would throw.
                            if (p === undefined) continue
                            seen[row.tileId] = true
                            // Resurrection: this id was fading out and is back (an undo,
                            // or a live push that re-adds it). Cancel the exit - the tile
                            // exists, so it must not vanish when a fade nobody is watching
                            // any more happens to finish.
                            if (row.dying) {
                                placementModel.setProperty(r2, "dying", false)
                                delete pageItem._dyingSince[row.tileId]
                            }
                            if (row.ps !== p.s || row.pl !== p.l || row.pes !== p.es
                                || row.pel !== p.el || row.tileIdx !== p.idx
                                || row.tileSize !== p.size || row.tileType !== p.type)
                                placementModel.set(r2, pageItem._row(p))
                        }

                        // Genuinely new tiles → append. A new delegate is born at its
                        // final slot (a Behavior does not fire on initial binding), so
                        // an add slides its NEIGHBOURS and never itself - the tile's own
                        // arrival is the `entering` fade instead. Only once the page is
                        // `_live`, and only while the token allows it: the rows that seed
                        // a page are not an add, and reduce-motion means there is no
                        // entrance at all.
                        for (var k = 0; k < ps.length; k++) {
                            if (seen[ps[k].id] !== undefined) continue
                            var fresh = pageItem._row(ps[k])
                            fresh.entering = pageItem._live && theme.motionAdd > 0
                            placementModel.append(fresh)
                        }

                        return placementModel.count
                    }
                    // onPlacementsChanged alone is not enough: a property change signal
                    // is not guaranteed for the binding's FIRST evaluation. Both paths
                    // are idempotent, so the overlap costs nothing.
                    onPlacementsChanged: pageItem._syncPlacements()
                    Component.onCompleted: {
                        pageItem._syncPlacements()
                        // AFTER the seed: every row that exists at birth is part of the
                        // page's starting state, not an entrance.
                        pageItem._live = true
                    }
                    // How far the page reaches along the long axis, in half-cells.
                    // 6 (WidgetSizes.longHalves) is exactly one screen. The store keeps
                    // this <= 6 (a page never scrolls); it stays measured so tests and
                    // future capacity checks can read the real extent.
                    property int longExtent: packer.longExtent(pageItem.placements)

                    // Where the next widget would land: the same packing with one more
                    // tile (at the size the store would actually give it) on the end.
                    // Drives the edit-mode "Add widget" slot. `nextAddSize` is "" when
                    // the page is full, in which case the slot is hidden entirely.
                    property string addSize: {
                        store.structureRevision
                        return store.nextAddSize(pageItem.index)
                    }
                    property bool hasAddRoom: pageItem.addSize !== ""
                    property var addPlacement: {
                        store.structureRevision
                        var virt = (pageItem.tiles || []).slice()
                        virt.push({ id: "", type: "", size: pageItem.hasAddRoom ? pageItem.addSize : sizes.baseline })
                        var ps = packer.pack(virt)
                        return ps[ps.length - 1]
                    }

                    // Page body. CAPACITY POLICY: one page = one screen, and a screen
                    // the user can build NEVER scrolls. The store enforces this at the
                    // source - addTile and setTileSize REFUSE any change that would push
                    // a page past the 2x6 half-cell budget (DashboardStore.pageHasRoomFor)
                    // - so every page created through the Hub or Manager packs to
                    // longExtent <= longHalves and the content exactly fills the screen,
                    // leaving `interactive` false. When a page is full the add affordance
                    // is HIDDEN rather than parked off-screen where it could not be
                    // reached, so there is never anything to scroll to.
                    //
                    // `interactive` is gated on the REAL extent (not hard-false) purely
                    // as a data-safety fallback: a LEGACY config saved before this policy
                    // could still carry an overlong page, and letting it scroll keeps
                    // every tile reachable - strictly better than clipping tiles out of
                    // sight. Such a page shrinks back under budget the moment it is edited.
                    //
                    // The fixed 2x6 grid sizes the CELL, not the page: `1x1` is always a
                    // third of the DISPLAY no matter what else is on the page (the whole
                    // size model, and what GridLayout could not do), so the cell is
                    // screen/(2x6). The scroll axis follows the LONG axis (vertical in
                    // portrait, horizontal on the landscape strip).
                    Flickable {
                        id: pageFlick
                        anchors.fill: parent
                        clip: true
                        // The cell, derived from the SCREEN and nothing else.
                        readonly property real cellShort: (pageItem.landscape ? height : width) / sizes.shortHalves
                        readonly property real cellLong: (pageItem.landscape ? width : height) / sizes.longHalves
                        readonly property real contentLong:
                            Math.max(pageItem.landscape ? width : height, pageItem.longExtent * cellLong)
                        contentWidth: pageItem.landscape ? contentLong : width
                        contentHeight: pageItem.landscape ? height : contentLong
                        flickableDirection: pageItem.landscape ? Flickable.HorizontalFlick
                                                               : Flickable.VerticalFlick
                        boundsBehavior: Flickable.StopAtBounds
                        // False for every page a user can create (store-enforced <= one
                        // screen); true only for a legacy overlong page, so no tile hides.
                        interactive: pageItem.longExtent > sizes.longHalves

                    Item {
                        id: pageGrid
                        width: pageFlick.contentWidth
                        height: pageFlick.contentHeight

                        Repeater {
                            model: placementModel
                            delegate: Item {
                                id: cell
                                // The placement's roles. NOT the Repeater's `index`:
                                // that counts rows, and every store call here addresses
                                // the TILE array - `tileIdx` is that index.
                                required property string tileId
                                required property string tileType
                                required property string tileSize
                                required property int tileIdx
                                required property int ps
                                required property int pl
                                required property int pes
                                required property int pel
                                // Lifetime, not layout: `dying` is set on a row the
                                // packing has dropped and kept until this cell has faded
                                // out; `entering` is fixed at append time and says this
                                // cell was grown by the page, not born with it.
                                required property bool dying
                                required property bool entering

                                // ── The exit ──────────────────────────────────
                                // A removed tile used to blink out of existence while
                                // its neighbours glided into the space it left - the one
                                // motion on screen belonged to everything EXCEPT the
                                // thing the user actually acted on.
                                //
                                // The delegate has to outlive its removal from the
                                // packing for there to be anything to fade, so the row
                                // is the thing that is held open (`dying`, set by
                                // _syncPlacements) and this cell is what closes it: when
                                // the fade ends, it reaps its own row. That keeps the
                                // lifetime in ONE place - no delegate can be orphaned by
                                // a fade that never ran, because the only thing that
                                // starts a fade is the role that also holds the row open.
                                //
                                // motionRemove (150ms) is shorter than the 250ms move,
                                // so the ghost is gone before its neighbours arrive over
                                // it. Under reduce-motion that token is 0, and THAT is
                                // what makes a removal instant rather than merely quick:
                                // a 0ms fade lands and reaps in the same event it starts.
                                opacity: cell.entering ? 0 : 1
                                // A ghost is not a tile: it must not answer a tap, or
                                // offer edit chrome for a tile the store no longer has.
                                enabled: !cell.dying
                                onDyingChanged: {
                                    // Only ever one animation owns `opacity`. A tile can
                                    // be removed inside its own entrance (add a widget,
                                    // think better of it, hit remove - 200ms is easy to
                                    // beat), and two animations writing the same property
                                    // every tick fight rather than blend.
                                    if (cell.dying) { enterFade.stop(); exitFade.start() }
                                    else { exitFade.stop(); cell.opacity = 1 }   // resurrected
                                }
                                NumberAnimation {
                                    id: exitFade
                                    target: cell; property: "opacity"; to: 0
                                    duration: theme.motionRemove; easing.type: Easing.OutCubic
                                    onFinished: pageItem._reapRow(cell.tileId)
                                }

                                // ── The entrance ──────────────────────────────
                                // An added tile is the one thing on screen the user just
                                // asked for, so it arrives in its own right instead of
                                // simply already being there. It fades in AT its slot: it
                                // does not fly in, because the packer put it where it
                                // belongs and there is no truthful "from" to fly from.
                                //
                                // `entering` is decided once, when the row is appended
                                // (see _syncPlacements), so a rotation - which never
                                // appends - cannot trigger it, and reduce-motion means it
                                // is never set and `opacity` stays bound at 1.
                                Component.onCompleted: if (cell.entering) enterFade.start()
                                NumberAnimation {
                                    id: enterFade
                                    target: cell; property: "opacity"; from: 0; to: 1
                                    duration: theme.motionAdd; easing.type: Easing.OutCubic
                                }

                                // ── The move ──────────────────────────────────
                                // The eased mirror of the semantic slot. Animating HERE
                                // rather than on x/y/width/height is what keeps the two
                                // things that move a tile apart:
                                //
                                //   • a structure edit changes the SLOT (ps/pl/pes/pel)
                                //     → these ease → the pixels follow → the tile
                                //     glides to its new home and the eye keeps it;
                                //   • a rotation or resize changes only `landscape` and
                                //     the cell size → the slot is unchanged → `_r`
                                //     recomputes straight through and the tile is
                                //     re-projected INSTANTLY, which is the whole point
                                //     of packing semantically (see WidgetPacker: the
                                //     dashboard turns WITH the panel; it must not
                                //     appear to reflow).
                                //
                                // No flag, no settling timer - the distinction is
                                // structural, so it cannot drift out of sync.
                                //
                                // REDUCE MOTION: the duration token does the real work -
                                // motionPage is 0, and a 0ms Behavior animation already
                                // lands its end value synchronously on write (measured:
                                // dropping this `enabled` gate does NOT make the move
                                // observably late). The gate is kept as the explicit
                                // statement of intent, and to skip starting an animation
                                // object per tile per edit for a value that cannot move -
                                // not as the mechanism. Smooth is not more motion.
                                property real animS:  cell.ps
                                property real animL:  cell.pl
                                property real animEs: cell.pes
                                property real animEl: cell.pel
                                Behavior on animS  { enabled: theme.motionPage > 0
                                    NumberAnimation { duration: theme.motionPage; easing.type: Easing.OutCubic } }
                                Behavior on animL  { enabled: theme.motionPage > 0
                                    NumberAnimation { duration: theme.motionPage; easing.type: Easing.OutCubic } }
                                Behavior on animEs { enabled: theme.motionPage > 0
                                    NumberAnimation { duration: theme.motionPage; easing.type: Easing.OutCubic } }
                                Behavior on animEl { enabled: theme.motionPage > 0
                                    NumberAnimation { duration: theme.motionPage; easing.type: Easing.OutCubic } }

                                // Absolute placement: the (eased) semantic slot projected
                                // onto physical axes at the screen-derived cell size.
                                readonly property var _r: packer.rect({ s: cell.animS, l: cell.animL,
                                                                        es: cell.animEs, el: cell.animEl },
                                                                      pageItem.landscape,
                                                                      pageFlick.cellShort, pageFlick.cellLong,
                                                                      theme.spacingMd)
                                x: _r.x; y: _r.y
                                width: _r.width; height: _r.height

                                scale: tapMA.pressed && !dashboard.editMode ? 0.98 : 1.0
                                Behavior on scale { NumberAnimation { duration: theme.motionFast; easing.type: Easing.OutCubic } }

                                // Body taps NO LONGER open config - only the top-right
                                // corner button does (see below). This frees the whole
                                // widget body for the widget's own in-place controls
                                // (start a timer, log a glass, toggle a task…) so basic
                                // usability lives on the tile and only "advanced" settings
                                // require opening the config view. Kept as a disabled
                                // sibling only so `scale: tapMA.pressed` stays valid.
                                MouseArea {
                                    id: tapMA
                                    anchors.fill: parent
                                    enabled: false
                                }

                                WidgetHost {
                                    id: tileLd
                                    anchors.fill: parent
                                    property string wId: cell.tileId
                                    property string wType: cell.tileType
                                    widgetId: wId
                                    widgetType: wType
                                    widgetSource: catalog.source(wType)
                                    loadEnabled: wId !== "" && wType !== "" && widgetSource !== ""
                                                 && dashboard.policyAllowsWidget(wType)
                                    store: dashboard.widgetStore
                                    catalog: dashboard.widgetCatalog
                                    metrics: dashboard.metrics
                                    netHub: dashboard.netGate
                                    timeZones: dashboard.availableTimeZones
                                    priorityAlerts: dashboard
                                    tick: dashboard._tick
                                    expanded: false
                                    sizeClass: dashboard.sizeClassFor(cell.tileSize, pageItem.landscape)
                                    driverActive: !dashboard.hasExpanded && !dashboard.editMode
                                    foreground: pageItem.index === swipeView.currentIndex
                                                && !dashboard.hasExpanded && !dashboard.editMode
                                    acceptsInput: true
                                }

                                // Error boundary: a tile whose type is unknown/removed -
                                // or disabled by org policy (E9) - renders the fallback
                                // card instead of a blank, confusing tile.
                                //
                                // Deliberately NOT gated on `wType !== ""`: a real tile
                                // (it has an id) whose type is missing entirely is the
                                // most Unavailable a tile can be, and it must not fall
                                // through to a silent blank card. Previously `type` was
                                // read straight off the placement object, so a typeless
                                // tile arrived here as `undefined` - which passed a
                                // `!== ""` test by accident and showed the card. Now the
                                // role is coerced to "" (see _row), so the condition has
                                // to say what it always meant.
                                Loader {
                                    anchors.fill: parent
                                    active: tileLd.wId !== ""
                                            && dashboard.sessionWidgetsEnabled
                                            && (catalog.source(tileLd.wType) === ""
                                                || !dashboard.policyAllowsWidget(tileLd.wType))
                                    // `fallbackTile` is an id in the Dashboard's
                                    // lexical scope, not a QObject property on
                                    // `dashboard`. Qualifying it produced an
                                    // undefined Component: the Loader was active
                                    // but stayed Null, leaving unknown widgets as
                                    // a silent blank tile.
                                    sourceComponent: fallbackTile
                                }

                                // Expand affordance + explicit hit-target. Full-bleed
                                // interactive widgets (Media transport, Tasks, Notes…)
                                // cover the underlying tapMA with their own MouseAreas,
                                // so tapping their body can't reach the expand handler.
                                // This touch-sized corner target sits ON TOP (z:20) and
                                // always opens the expanded view. The small low-opacity
                                // icon is a glanceable hint kept from fighting a widget's
                                // own top-right status. Hidden in edit mode.
                                Item {
                                    objectName: "widgetConfigButton-" + cell.tileId
                                    anchors.right: parent.right; anchors.top: parent.top
                                    width: theme.touchSecondary; height: theme.touchSecondary
                                    z: 20
                                    // Fade with the edit-mode change instead of blinking
                                    // out on the same frame the edit scrim appears.
                                    opacity: dashboard.editMode ? 0.0 : 1.0
                                    visible: opacity > 0.01
                                    Behavior on opacity { NumberAnimation { duration: theme.motionEdit } }
                                    Rectangle {
                                        anchors.fill: parent; anchors.margins: theme.spacingXs
                                        radius: theme.radiusSm
                                        // `pressed`, not just hover: this is a touchscreen -
                                        // a finger on the target must light it up.
                                        color: cfgMA.pressed ? Qt.rgba(1, 1, 1, 0.16)
                                             : cfgMA.containsMouse ? Qt.rgba(1, 1, 1, 0.10) : "transparent"
                                        Behavior on color { ColorAnimation { duration: theme.motionFast } }
                                    }
                                    AppIcon {
                                        anchors.right: parent.right; anchors.top: parent.top
                                        anchors.margins: theme.spacingSm
                                        name: "ui-expand"; size: theme.iconSm
                                        color: theme.textTertiary
                                        opacity: (cfgMA.pressed || cfgMA.containsMouse) ? 0.95 : 0.55
                                    }
                                    MouseArea {
                                        id: cfgMA
                                        anchors.fill: parent
                                        enabled: !dashboard.editMode
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            dashboard.cfgStatus = ""
                                            dashboard.expandedId = cell.tileId
                                            dashboard.expandedType = cell.tileType
                                        }
                                    }
                                }

                                // ── Edit-mode overlay: reorder + remove ──
                                Rectangle {
                                    anchors.fill: parent
                                    // Fade in/out with the mode switch - the scrim +
                                    // controls used to appear on a hard cut, which is
                                    // exactly the "abrupt property jump" class of clunk.
                                    // motionEdit is already 0 under reduce-motion.
                                    opacity: dashboard.editMode ? 1.0 : 0.0
                                    visible: opacity > 0.01
                                    Behavior on opacity { NumberAnimation { duration: theme.motionEdit } }
                                    radius: theme.radiusLg
                                    color: Qt.rgba(0, 0, 0, 0.35)
                                    border.width: 2; border.color: theme.accent
                                    z: 30

                                    // wobble to signal editability (effectiveReduceMotion:
                                    // the OS signal / explicit preference must stop it too)
                                    RotationAnimation on rotation {
                                        running: dashboard.editMode && !theme.effectiveReduceMotion
                                        loops: Animation.Infinite
                                        from: -0.4; to: 0.4; duration: 320
                                        easing.type: Easing.InOutSine
                                    }

                                    RowLayout {
                                        anchors.centerIn: parent
                                        spacing: theme.spacingMd
                                        // move left
                                        Rectangle {
                                            Layout.preferredWidth: theme.touchSecondary; Layout.preferredHeight: theme.touchSecondary
                                            radius: width / 2; color: theme.cardBackgroundAlt; border.width: 1; border.color: theme.cardBorder
                                            // `idx` is the tile's index in the store's tile
                                            // ARRAY, which is what moveTile addresses -
                                            // the delegate's own index counts placements,
                                            // and the two only coincide by luck.
                                            visible: cell.tileIdx > 0
                                            AppIcon { anchors.centerIn: parent; name: "ui-caret-left"; size: theme.iconMd; color: theme.textPrimary }
                                            MouseArea { anchors.fill: parent
                                                onClicked: store.moveTile(pageItem.index, cell.tileIdx, cell.tileIdx - 1) }
                                        }
                                        // remove
                                        Rectangle {
                                            Layout.preferredWidth: theme.touchPrimary; Layout.preferredHeight: theme.touchPrimary
                                            radius: width / 2; color: Qt.rgba(theme.error.r, theme.error.g, theme.error.b, 0.2)
                                            border.width: 2; border.color: theme.error
                                            AppIcon { anchors.centerIn: parent; name: "ui-trash"; size: 26; color: theme.error }
                                            MouseArea {
                                                anchors.fill: parent
                                                onClicked: dashboard.requestWidgetRemoval(
                                                    pageItem.index,
                                                    cell.tileId,
                                                    cell.tileType)
                                            }
                                        }
                                        // move right
                                        Rectangle {
                                            Layout.preferredWidth: theme.touchSecondary; Layout.preferredHeight: theme.touchSecondary
                                            radius: width / 2; color: theme.cardBackgroundAlt; border.width: 1; border.color: theme.cardBorder
                                            visible: cell.tileIdx < pageItem.tiles.length - 1
                                            AppIcon { anchors.centerIn: parent; name: "ui-caret-right"; size: theme.iconMd; color: theme.textPrimary }
                                            MouseArea { anchors.fill: parent
                                                onClicked: store.moveTile(pageItem.index, cell.tileIdx, cell.tileIdx + 1) }
                                        }
                                        // Resize: step through THIS widget type's own legal
                                        // sizes. Hidden for a type with only one - a button
                                        // that provably cannot do anything should not be
                                        // offered.
                                        Rectangle {
                                            Layout.preferredWidth: theme.touchSecondary; Layout.preferredHeight: theme.touchSecondary
                                            radius: width / 2; color: theme.cardBackgroundAlt; border.width: 1; border.color: theme.cardBorder
                                            visible: catalog.sizesFor(cell.tileType).length > 1
                                            AppIcon { anchors.centerIn: parent; name: "ui-resize"; size: theme.iconMd; color: theme.textPrimary }
                                            MouseArea {
                                                anchors.fill: parent
                                                onClicked: store.setTileSize(pageItem.index, cell.tileId,
                                                                             dashboard.nextSize(cell.tileType,
                                                                                                cell.tileSize))
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // "Add widget" placeholder tile (edit mode only). It sits in the
                        // slot the next widget would ACTUALLY land in - it is packed by
                        // the same packer, as a real baseline tile - so the affordance
                        // shows where the thing it adds will go rather than guessing.
                        Loader {
                            id: addTile
                            // Hidden when the page is full: the affordance only appears
                            // where a widget can actually land (no off-screen ghost).
                            // Also gated to the CURRENT page: a just-added page's delegate
                            // can transiently sit at x=0 over page 0 during a SwipeView
                            // model change, and an unguarded ghost bled onto the first
                            // screen. Only the visible page shows its add slot.
                            readonly property bool _showHere: dashboard.editMode && pageItem.hasAddRoom
                                                              && pageItem.index === swipeView.currentIndex
                            active: _showHere
                            visible: _showHere

                            // ── The add slot MOVES too ────────────────────────
                            // It is a real packed placement, so an edit re-packs it just
                            // like a tile: remove a widget and the slot where the next
                            // one lands closes up behind it. It used to JUMP there while
                            // every tile around it glided - the one box on an edit-mode
                            // page that teleported.
                            //
                            // Same shape as a tile's (animS/animL on the cell above) and
                            // for the same reason: the ease is on the SEMANTIC slot, so
                            // a rotation still re-projects it instantly.
                            //
                            // This needs no flag and no ordering against
                            // _syncPlacements. The add slot is a function of the page's
                            // TILES, not of the tile model - the two bindings read the
                            // same `tiles` and never each other - so whichever runs
                            // first, this one still eases from wherever it was to
                            // wherever the packer now puts it. Only the EXTENT is read
                            // straight through: the add slot is always one baseline
                            // tile, so there is nothing there to ease.
                            property real animS: pageItem.addPlacement.s
                            property real animL: pageItem.addPlacement.l
                            Behavior on animS { enabled: theme.motionPage > 0
                                NumberAnimation { duration: theme.motionPage; easing.type: Easing.OutCubic } }
                            Behavior on animL { enabled: theme.motionPage > 0
                                NumberAnimation { duration: theme.motionPage; easing.type: Easing.OutCubic } }

                            readonly property var _r: packer.rect({ s: addTile.animS, l: addTile.animL,
                                                                    es: pageItem.addPlacement.es,
                                                                    el: pageItem.addPlacement.el },
                                                                  pageItem.landscape,
                                                                  pageFlick.cellShort, pageFlick.cellLong,
                                                                  theme.spacingMd)
                            x: _r.x; y: _r.y
                            width: _r.width; height: _r.height
                            sourceComponent: Rectangle {
                                radius: theme.radiusLg
                                color: "transparent"
                                border.width: 2; border.color: theme.cardBorder
                                // Enter softly when edit mode opens (0ms under
                                // reduce-motion via the token).
                                NumberAnimation on opacity {
                                    from: 0; to: 1
                                    duration: theme.motionAdd; easing.type: Easing.OutCubic
                                }
                                Column {
                                    anchors.centerIn: parent; spacing: 6
                                    AppIcon { anchors.horizontalCenter: parent.horizontalCenter; name: "ui-plus"; size: 40; color: theme.accent }
                                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Add widget"; font.pixelSize: theme.fontMinimum; color: theme.textSecondary }
                                }
                                MouseArea { anchors.fill: parent; onClicked: { picker.pageIndex = pageItem.index; picker.shown = true } }
                            }
                        }
                    }
                    }

                    // Empty-page hint. Gated on this being the CURRENT page: after a
                    // live state-swap (Manager push → applyExternal rebuilds the page
                    // Repeater) an off-screen empty page's delegate can momentarily
                    // sit at x=0 and overlap the current page; only the current page
                    // should ever show its hint anyway.
                    Text {
                        anchors.centerIn: parent
                        visible: pageItem.tiles.length === 0 && !dashboard.editMode
                                 && pageItem.index === swipeView.currentIndex
                        text: dashboard.showHubBar
                              ? "This page is empty.\nTap Edit to add widgets."
                              : "This screen is empty.\nAdd widgets from EdgeHub Manager."
                        horizontalAlignment: Text.AlignHCenter
                        color: theme.textTertiary; font.pixelSize: 16
                    }
                }
            }
        }

        // ── Bottom bar ───────────────────────────────────────────────────────
        RowLayout {
            objectName: "hubBottomBar"
            // If Manager hides the bar while an on-device edit is already in
            // progress, keep it until the user taps Done. Immersive mode then
            // takes effect without trapping the Hub in edit mode.
            visible: dashboard.showHubBar || dashboard.editMode
            Layout.fillWidth: true
            Layout.preferredHeight: theme.touchPrimary
            spacing: theme.spacingSm

            Text {
                Layout.preferredWidth: theme.touchSecondary * 1.8
                // structureRevision dep so a page rename refreshes the label.
                // Guard the index against a mid-rebuild transient (currentIndex can
                // momentarily be -1 or point past a shrunken pages() array) so we
                // never dereference an undefined page.
                text: {
                    store.structureRevision
                    var i = swipeView.currentIndex
                    var ps = store.pages()
                    return (i >= 0 && i < ps.length && ps[i]) ? (ps[i].name || "") : ""
                }
                font.pixelSize: theme.fontLabel; font.weight: Font.DemiBold
                font.family: theme.fontDisplay; color: theme.textSecondary
                elide: Text.ElideRight; verticalAlignment: Text.AlignVCenter
            }

            // E9: ONE always-visible line saying the hub is under org
            // management - in the bottom bar, not buried in a submenu.
            Text {
                visible: dashboard.managed
                text: "Managed by your organization"
                color: theme.textTertiary; font.pixelSize: theme.fontLabel
                font.family: theme.fontDisplay
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
                Layout.maximumWidth: theme.touchSecondary * 4
            }

            PageIndicator {
                Layout.alignment: Qt.AlignCenter; Layout.fillWidth: true
                count: swipeView.count; currentIndex: swipeView.currentIndex
                interactive: true
                onCurrentIndexChanged: if (currentIndex !== swipeView.currentIndex) swipeView.currentIndex = currentIndex
                // A tall, transparent hit area (>=44px) carrying a small visual pill,
                // so the dots are actually tappable on a touchscreen.
                delegate: Item {
                    required property int index
                    objectName: "pageIndicatorDelegate-" + index
                    implicitWidth: (index === swipeView.currentIndex ? 36 : 16) + 10
                    implicitHeight: theme.touchTertiary
                    Rectangle {
                        objectName: "pageIndicatorChip-" + index
                        anchors.centerIn: parent
                        width: index === swipeView.currentIndex ? 36 : 14
                        height: 14; radius: 7; color: theme.accent
                        opacity: index === swipeView.currentIndex ? 0.95 : 0.3
                        Behavior on width { NumberAnimation { duration: theme.motionFast } }
                        Behavior on opacity { NumberAnimation { duration: theme.motionFast } }
                    }
                }
            }

            // Add widget (edit mode) - always reachable, even on a full screen where
            // the in-page "＋" ghost is hidden; the store puts it here or on a new
            // screen as it fits. Targets the page currently in view.
            BarButton { iconName: "ui-plus"; visible: dashboard.editMode
                        onClicked: { picker.pageIndex = swipeView.currentIndex; picker.shown = true } }
            // Add page (edit mode) - land ON the new page (matches the Manager).
            // goToPage applies the index once the int-model SwipeView grows to fit;
            // setting it synchronously raced the model growth (snapped back to page 0
            // and bled the new page's overlay onto the first screen).
            BarButton { iconName: "ui-add-page"; visible: dashboard.editMode
                        onClicked: { store.addPage(""); swipeView.goToPage(store.pageCount() - 1) } }
            // Remove current page (edit mode, keep ≥1) - re-clamp the index so the
            // view never points past the new end after deleting the last page.
            BarButton { iconName: "ui-del-page"; visible: dashboard.editMode && store.pageCount() > 1
                        onClicked: dashboard.requestPageRemoval(swipeView.currentIndex) }
            // Edit toggle
            BarButton {
                iconName: dashboard.editMode ? "ui-check" : "ui-edit"
                highlighted: dashboard.editMode
                onClicked: { dashboard.editMode = !dashboard.editMode; if (!dashboard.editMode) store.flushNow() }
            }
            // Appearance
            BarButton { iconName: "ui-palette"; onClicked: settings.shown = true }
            // Diagnostics
            BarButton {
                iconName: "ui-settings"
                // Guard against stacking multiple Diagnostics pages on repeat taps.
                onClicked: if (dashboard.host && dashboard.host.depth <= 1) dashboard.host.push(Qt.resolvedUrl("Diagnostics.qml").toString(), {
                    "metricsJson": Qt.binding(function () { return metricsJson }),
                    "screensData": screensData,
                    // The egress gate for the Network tab (W5 finding 6).
                    "netHub": netHub,
                    "configJson": (typeof configBridge !== "undefined" && configBridge) ? configBridge.configJson() : "",
                    // User-widget loader report: enabled state + loaded entries
                    // + every skipped directory with its reason.
                    "userWidgetsJson": userCatalog.reportJson(dashboard._userWidgetsFlag(),
                        (typeof configBridge !== "undefined" && configBridge && configBridge.userWidgetsDir)
                            ? configBridge.userWidgetsDir() : "")
                })
            }
        }
    }

    // Small reusable bottom-bar button.
    component BarButton: Rectangle {
        id: barBtn
        property string iconName: ""
        property bool highlighted: false
        signal clicked()
        Layout.preferredWidth: theme.touchPrimary
        Layout.preferredHeight: theme.touchPrimary
        radius: theme.radiusLg
        color: highlighted ? Qt.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 0.22)
                           : (bMA.pressed ? theme.cardBackgroundAlt : (bMA.containsMouse ? theme.cardBackground : "transparent"))
        border.width: highlighted ? 2 : 1; border.color: highlighted ? theme.accent : theme.cardBorder
        scale: bMA.pressed ? 0.93 : 1.0
        Behavior on scale { NumberAnimation { duration: theme.motionFast } }
        AppIcon { anchors.centerIn: parent; name: barBtn.iconName; size: theme.iconLg
            color: barBtn.highlighted ? theme.accent : theme.textPrimary }
        MouseArea { id: bMA; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: barBtn.clicked() }
    }

    component ConfirmButton: Button {
        id: confirmButtonRoot
        property bool danger: false
        implicitHeight: theme.touchSecondary
        implicitWidth: 150
        hoverEnabled: true
        contentItem: Text {
            text: confirmButtonRoot.text
            color: theme.textPrimary
            font.pixelSize: theme.fontLabel
            font.bold: confirmButtonRoot.danger
            font.family: theme.fontDisplay
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
        background: Rectangle {
            radius: theme.radiusMd
            color: confirmButtonRoot.danger
                ? (confirmButtonRoot.down ? Qt.darker(theme.error, 1.18) : theme.error)
                : (confirmButtonRoot.down ? theme.cardBackgroundAlt : theme.cardBackground)
            border.width: 1
            border.color: confirmButtonRoot.danger ? theme.error : theme.cardBorder
        }
    }

    Dialog {
        id: pageDeleteConfirm
        objectName: "pageDeleteConfirm"
        anchors.centerIn: parent
        modal: true
        closePolicy: Popup.CloseOnEscape
        width: Math.min(parent ? parent.width - theme.spacingXl * 2 : 520, 520)
        title: "Remove screen?"
        background: Rectangle {
            color: theme.cardBackground
            radius: theme.radiusLg
            border.width: 1
            border.color: theme.cardBorder
        }
        header: Rectangle {
            color: "transparent"
            implicitHeight: theme.touchSecondary
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: theme.spacingLg
                anchors.rightMargin: theme.spacingLg
                spacing: theme.spacingSm
                AppIcon {
                    name: "ui-warning"
                    size: theme.iconMd
                    color: theme.error
                    Layout.alignment: Qt.AlignVCenter
                }
                Text {
                    text: pageDeleteConfirm.title
                    color: theme.textPrimary
                    font.pixelSize: theme.fontTitle
                    font.bold: true
                    font.family: theme.fontDisplay
                    Layout.fillWidth: true
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }
        contentItem: ColumnLayout {
            spacing: theme.spacingMd
            Text {
                id: pageDeleteSummaryText
                objectName: "pageDeleteSummary"
                Layout.fillWidth: true
                text: {
                    var n = dashboard.pendingPageRemovalWidgetCount
                    return "Remove screen \"" + dashboard.pendingPageRemovalName + "\""
                        + (n > 0 ? " and its " + n + " widget" + (n === 1 ? "" : "s") : "")
                        + "? The screen, its widgets, and their saved data will be removed."
                }
                color: theme.textPrimary
                font.pixelSize: theme.fontLabel
                font.family: theme.fontDisplay
                wrapMode: Text.WordWrap
            }
            Text {
                Layout.fillWidth: true
                text: "This cannot be undone."
                color: theme.textSecondary
                font.pixelSize: theme.fontCaption
                font.family: theme.fontDisplay
            }
            Text {
                objectName: "pageDeleteError"
                Layout.fillWidth: true
                visible: dashboard.pageRemovalError.length > 0
                text: dashboard.pageRemovalError
                color: theme.error
                font.pixelSize: theme.fontCaption
                font.family: theme.fontDisplay
                wrapMode: Text.WordWrap
            }
        }
        footer: RowLayout {
            spacing: theme.spacingSm
            Item { Layout.fillWidth: true }
            ConfirmButton {
                id: cancelPageDelete
                objectName: "cancelPageDelete"
                text: "Cancel"
                implicitWidth: 128
                implicitHeight: theme.touchSecondary
                onClicked: pageDeleteConfirm.close()
            }
            ConfirmButton {
                id: confirmPageDelete
                objectName: "confirmPageDelete"
                text: "Remove screen"
                danger: true
                implicitWidth: 172
                implicitHeight: theme.touchSecondary
                onClicked: if (dashboard.confirmPageRemoval()) pageDeleteConfirm.close()
            }
        }
    }

    Dialog {
        id: widgetRemoveConfirm
        objectName: "widgetRemoveConfirm"
        anchors.centerIn: parent
        modal: true
        closePolicy: Popup.CloseOnEscape
        width: Math.min(parent ? parent.width - theme.spacingXl * 2 : 560, 560)
        title: "Remove widget?"
        background: Rectangle {
            color: theme.cardBackground
            radius: theme.radiusLg
            border.width: 1
            border.color: theme.cardBorder
        }
        header: Rectangle {
            color: "transparent"
            implicitHeight: theme.touchSecondary
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: theme.spacingLg
                anchors.rightMargin: theme.spacingLg
                spacing: theme.spacingSm
                AppIcon {
                    name: "ui-warning"
                    size: theme.iconMd
                    color: theme.error
                    Layout.alignment: Qt.AlignVCenter
                }
                Text {
                    text: widgetRemoveConfirm.title
                    color: theme.textPrimary
                    font.pixelSize: theme.fontTitle
                    font.bold: true
                    font.family: theme.fontDisplay
                    Layout.fillWidth: true
                }
            }
        }
        contentItem: ColumnLayout {
            spacing: theme.spacingMd
            Text {
                id: widgetRemoveSummaryText
                objectName: "widgetRemoveSummary"
                Layout.fillWidth: true
                text: {
                    var title = catalog.title(
                        dashboard.pendingWidgetRemovalType)
                    var label = dashboard.pendingWidgetRemovalLabel
                    return "Remove " + title + " from this screen?"
                        + (label.length > 0
                           ? " Its " + label + " will also be removed." : "")
                        + " Any unsaved text in the widget will be removed too."
                }
                color: theme.textPrimary
                font.pixelSize: theme.fontLabel
                font.family: theme.fontDisplay
                wrapMode: Text.WordWrap
            }
            Text {
                Layout.fillWidth: true
                text: "This cannot be undone."
                color: theme.textSecondary
                font.pixelSize: theme.fontCaption
                font.family: theme.fontDisplay
            }
            Text {
                objectName: "widgetRemoveError"
                Layout.fillWidth: true
                visible: dashboard.widgetRemovalError.length > 0
                text: dashboard.widgetRemovalError
                color: theme.error
                font.pixelSize: theme.fontCaption
                font.family: theme.fontDisplay
                wrapMode: Text.WordWrap
            }
        }
        footer: RowLayout {
            spacing: theme.spacingSm
            Item { Layout.fillWidth: true }
            ConfirmButton {
                id: cancelWidgetRemove
                objectName: "cancelWidgetRemove"
                text: "Cancel"
                implicitWidth: 128
                implicitHeight: theme.touchSecondary
                onClicked: widgetRemoveConfirm.close()
            }
            ConfirmButton {
                id: confirmWidgetRemove
                objectName: "confirmWidgetRemove"
                text: "Remove widget"
                danger: true
                implicitWidth: 172
                implicitHeight: theme.touchSecondary
                onClicked: {
                    if (dashboard.confirmWidgetRemoval())
                        widgetRemoveConfirm.close()
                }
            }
        }
    }

    Dialog {
        id: widgetDataConfirm
        objectName: "widgetDataConfirm"
        anchors.centerIn: parent
        modal: true
        closePolicy: Popup.CloseOnEscape
        width: Math.min(parent ? parent.width - theme.spacingXl * 2 : 560, 560)
        title: dashboard.pendingWidgetDataAction === "erase"
            ? "Erase personal data?" : "Reset configuration?"
        background: Rectangle {
            color: theme.cardBackground
            radius: theme.radiusLg
            border.width: 1
            border.color: theme.cardBorder
        }
        header: Rectangle {
            color: "transparent"
            implicitHeight: theme.touchSecondary
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: theme.spacingLg
                anchors.rightMargin: theme.spacingLg
                spacing: theme.spacingSm
                AppIcon {
                    name: dashboard.pendingWidgetDataAction === "erase" ? "ui-warning" : "ui-settings"
                    size: theme.iconMd
                    color: dashboard.pendingWidgetDataAction === "erase" ? theme.error : theme.accent
                    Layout.alignment: Qt.AlignVCenter
                }
                Text {
                    text: widgetDataConfirm.title
                    color: theme.textPrimary
                    font.pixelSize: theme.fontTitle
                    font.bold: true
                    font.family: theme.fontDisplay
                    Layout.fillWidth: true
                }
            }
        }
        contentItem: Text {
            id: widgetDataSummaryText
            objectName: "widgetDataSummary"
            text: {
                var title = catalog.title(dashboard.pendingWidgetDataType)
                var label = dashboard.pendingWidgetDataLabel
                if (dashboard.pendingWidgetDataAction === "erase")
                    return "Erase " + label + " from " + title
                        + "? Widget configuration and appearance will be kept. This cannot be undone."
                return "Reset " + title + " configuration to its defaults?"
                    + (label.length > 0 ? " Your " + label + " will be kept." : "")
            }
            color: theme.textPrimary
            font.pixelSize: theme.fontLabel
            font.family: theme.fontDisplay
            wrapMode: Text.WordWrap
        }
        footer: RowLayout {
            spacing: theme.spacingSm
            Item { Layout.fillWidth: true }
            ConfirmButton {
                id: cancelWidgetDataAction
                objectName: "cancelWidgetDataAction"
                text: "Cancel"
                implicitWidth: 128
                onClicked: widgetDataConfirm.close()
            }
            ConfirmButton {
                id: confirmWidgetDataActionButton
                objectName: "confirmWidgetDataAction"
                text: dashboard.pendingWidgetDataAction === "erase" ? "Erase data" : "Reset configuration"
                danger: dashboard.pendingWidgetDataAction === "erase"
                implicitWidth: dashboard.pendingWidgetDataAction === "erase" ? 150 : 210
                onClicked: if (dashboard.confirmWidgetDataAction()) widgetDataConfirm.close()
            }
        }
    }

    // ── Expanded overlay (shares the tile's persisted settings) ──────────────
    Rectangle {
        id: overlay
        anchors.fill: parent
        z: 100
        visible: dashboard.hasExpanded || opacity > 0.01
        opacity: dashboard.hasExpanded ? 1.0 : 0.0
        scale: dashboard.hasExpanded ? 1.0 : 0.97
        Behavior on opacity { NumberAnimation { duration: theme.motionFast; easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: theme.motionPage; easing.type: Easing.OutCubic } }
        // The fade is over → NOW drop the retained content (see shownType above).
        onVisibleChanged: if (!visible) {
            // Clear the owner id first. WidgetHost reacts to each property
            // independently; clearing the type while the removed tile's id was
            // still live briefly asked it to seed defaults for an empty type,
            // resurrecting the retired id as an orphan `{}` settings bucket.
            dashboard.shownId = ""
            dashboard.shownType = ""
        }

        // Backdrop
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                orientation: Gradient.Vertical
                GradientStop { position: 0.0; color: theme.backgroundColor }
                GradientStop { position: 1.0; color: theme.backgroundColor2 }
            }
        }
        Rectangle {
            anchors.fill: parent; opacity: 0.09
            gradient: Gradient {
                orientation: Gradient.Vertical
                GradientStop { position: 0.0; color: dashboard.expandedColor }
                GradientStop { position: 0.45; color: "transparent" }
            }
        }

        // Modal input barrier - absorbs every tap so nothing reaches the
        // dashboard behind. Declared before the header/content, which stay on top.
        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.AllButtons
            onClicked: {}
            onPressed: {}
        }

        // Header: back button + title + description
        Item {
            id: ovlHeader
            anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
            anchors.margins: theme.spacingLg
            height: Math.max(theme.touchSecondary, titleCol.implicitHeight)

            Rectangle {
                id: backBtn
                anchors.left: parent.left; anchors.top: parent.top
                width: theme.touchSecondary; height: theme.touchSecondary; radius: theme.radiusMd
                color: backMA.pressed ? theme.cardBackgroundAlt : theme.cardBackground
                border.width: 1; border.color: theme.cardBorder
                AppIcon { anchors.centerIn: parent; name: "ui-caret-left"; size: theme.iconMd; color: theme.textPrimary }
                MouseArea { id: backMA; anchors.fill: parent; onClicked: dashboard.closeExpanded() }
            }
            Column {
                id: titleCol
                anchors.left: backBtn.right; anchors.leftMargin: theme.spacingLg
                anchors.right: parent.right; anchors.top: parent.top
                spacing: 3
                Row {
                    spacing: theme.spacingSm
                    // shownType (not expandedType): the header must hold its
                    // icon/title/description through the close fade.
                    AppIcon { anchors.verticalCenter: parent.verticalCenter
                        readonly property var ic: catalog.iconFor(dashboard.shownType)
                        name: ic.name; iconSource: ic.source
                        size: theme.fontTitle + 10; color: dashboard.expandedColor }
                    Text { text: catalog.title(dashboard.shownType); font.pixelSize: theme.fontTitle + 8
                        font.bold: true; font.family: theme.fontDisplay; color: theme.textPrimary }
                }
                Text {
                    width: parent.width
                    text: catalog.desc(dashboard.shownType)
                    font.pixelSize: theme.fontLabel; color: theme.textSecondary
                    wrapMode: Text.WordWrap; visible: text.length > 0
                }
            }
        }

        // Content - FILLS the whole area below the header: a live preview of the
        // widget plus a full, scrollable configuration panel (descriptions +
        // every option). Portrait stacks them; landscape places them side by side.
        property bool ovlWide: overlay.width > overlay.height

        GridLayout {
            id: ovlBody
            anchors.top: ovlHeader.bottom; anchors.topMargin: theme.spacingMd
            anchors.left: parent.left; anchors.right: parent.right
            anchors.bottom: ovlDoneBar.top; anchors.bottomMargin: theme.spacingMd
            anchors.leftMargin: theme.spacingLg; anchors.rightMargin: theme.spacingLg
            columns: overlay.ovlWide ? 2 : 1
            rowSpacing: theme.spacingMd; columnSpacing: theme.spacingMd

            // ── Live, interactive widget ──
            // W5 BLOCKER (finding 2): in landscape both columns declared
            // fillWidth, and a GridLayout hands the stretch out in proportion
            // to preferred widths - the preview's 0.46×width against the
            // config panel's implicit ~0 - so the FORM collapsed to a ~10px
            // sliver and on-device configuration ("connect CI to a URL",
            // per-widget backdrop…) was impossible on a landscape mount.
            // The landscape split is now explicit: the preview takes a FIXED
            // 38% (fillWidth off, width capped) and the form fills every
            // remaining pixel, with a hard minimum of half the overlay so no
            // future sibling can starve it again. Portrait is unchanged:
            // preview stacked on top (≤46% height), form full-width below.
            ColumnLayout {
                Layout.fillWidth: !overlay.ovlWide
                Layout.fillHeight: overlay.ovlWide
                Layout.preferredWidth: overlay.ovlWide ? Math.round(overlay.width * 0.38) : -1
                Layout.maximumWidth: overlay.ovlWide ? Math.round(overlay.width * 0.38)
                                                     : Number.POSITIVE_INFINITY
                Layout.preferredHeight: overlay.ovlWide ? -1 : Math.min(overlay.height * 0.46, 1080)
                spacing: theme.spacingSm

                Rectangle {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    radius: theme.radiusLg
                    color: theme.cardFill()
                    border.width: 1; border.color: theme.cardBorder
                    clip: true
                    WidgetHost {
                        id: ovlLoader
                        anchors.fill: parent
                        anchors.margins: theme.spacingLg
                        // Keyed off the RETAINED type: the widget stays rendered
                        // (frozen, inactive) through the close fade instead of
                        // popping to an empty card on frame 1, and unloads only
                        // once the overlay is fully hidden.
                        widgetId: dashboard.shownId
                        widgetType: dashboard.shownType
                        widgetSource: catalog.source(dashboard.shownType)
                        loadEnabled: dashboard.shownType !== "" && widgetSource !== ""
                                     && dashboard.policyAllowsWidget(dashboard.shownType)
                        store: dashboard.widgetStore
                        catalog: dashboard.widgetCatalog
                        metrics: dashboard.metrics
                        netHub: dashboard.netGate
                        timeZones: dashboard.availableTimeZones
                        priorityAlerts: dashboard
                        tick: dashboard._tick
                        expanded: true
                        sizeClass: "full"
                        driverActive: dashboard.hasExpanded
                        foreground: dashboard.hasExpanded
                        acceptsInput: true
                        chromeless: true
                        suppressHeader: true
                        onWidgetLoaded: function(item) {
                            dashboard.overlayLoaderItem = item
                        }
                    }
                }
                // Reset configuration without deleting classified personal data.
                Rectangle {
                    Layout.fillWidth: true; Layout.preferredHeight: theme.touchSecondary
                    radius: theme.radiusMd; color: resetMA.pressed ? theme.cardBackgroundAlt : theme.cardBackground
                    border.width: 1; border.color: theme.cardBorder
                    Text {
                        anchors.centerIn: parent; text: "Reset configuration"
                        color: theme.textSecondary; font.pixelSize: theme.fontLabel
                    }
                    MouseArea {
                        id: resetMA; anchors.fill: parent
                        onClicked: dashboard.requestWidgetDataAction("reset")
                    }
                }
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: theme.touchSecondary
                    visible: catalog.hasPersonalData(dashboard.shownType)
                    radius: theme.radiusMd
                    color: eraseDataMA.pressed ? Qt.rgba(theme.error.r, theme.error.g, theme.error.b, 0.2) : "transparent"
                    border.width: 1
                    border.color: theme.error
                    Text {
                        anchors.centerIn: parent
                        text: "Erase personal data"
                        color: theme.error
                        font.pixelSize: theme.fontLabel
                    }
                    MouseArea {
                        id: eraseDataMA
                        anchors.fill: parent
                        onClicked: dashboard.requestWidgetDataAction("erase")
                    }
                }
            }

            // ── Configuration panel ──
            WidgetConfigPanel {
                Layout.fillWidth: true; Layout.fillHeight: true
                // The form may never be starved below half the overlay in
                // landscape - this panel is the only way to configure a
                // widget on-device (W5 blocker 2).
                Layout.minimumWidth: overlay.ovlWide ? Math.round(overlay.width * 0.5) : 0
                // User widgets carry their form in the manifest; shipped ones
                // in WidgetConfigSchema. Both compose the same General/About/
                // Appearance sections.
                schema: {
                    var _ = store.revision
                    if (userCatalog.isUser(dashboard.shownType))
                        return userCatalog.schemaFor(dashboard.shownType, cfgSchema)
                    var settings = dashboard.shownId
                                   ? store.settingsFor(dashboard.shownId) : ({})
                    var selected = dashboard.shownType === "gpu" ? settings.gpuDevice
                                 : dashboard.shownType === "sensors" ? settings.gpuDevice
                                 : dashboard.shownType === "net" ? settings.interfaceName
                                 : dashboard.shownType === "disk" ? settings.mountPath : ""
                    return cfgSchema.schemaFor(dashboard.shownType, dashboard.metrics, selected)
                }
                st: store
                instanceId: dashboard.shownId
                col: dashboard.cfgCol
                statusText: {
                    var item = dashboard.overlayLoaderItem
                    if (item && item.hasOwnProperty("connectionStatus")
                            && item.connectionStatus.length)
                        return item.connectionStatus
                    if (item && item.hasOwnProperty("geocodeStatus")
                            && item.geocodeStatus.length)
                        return item.geocodeStatus
                    return dashboard.cfgStatus
                }
                onActionRequested: (a) => dashboard.cfgAction(a)
            }
        }

        // Reachable close: a full-width "Done" bar pinned to the BOTTOM of the
        // overlay. On a 2560px-tall portrait panel the top-left back button is out
        // of one-handed reach, so this is the primary way out of the expanded view.
        Rectangle {
            id: ovlDoneBar
            anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
            anchors.margins: theme.spacingLg
            height: theme.touchPrimary
            radius: theme.radiusMd
            color: doneMA.pressed ? Qt.darker(theme.accent, 1.2) : theme.accent
            RowLayout {
                anchors.centerIn: parent; spacing: theme.spacingSm
                AppIcon { name: "ui-check"; size: theme.iconMd; color: theme.backgroundColor }
                Text { text: "Done"; color: theme.backgroundColor; font.pixelSize: theme.fontTitle
                    font.bold: true; font.family: theme.fontDisplay }
            }
            MouseArea { id: doneMA; anchors.fill: parent; onClicked: dashboard.closeExpanded() }
        }
    }

    // ── Add-widget picker (edit mode) ────────────────────────────────────────
    Rectangle {
        id: picker
        anchors.fill: parent; z: 200
        property bool shown: false
        property int pageIndex: 0
        visible: shown || opacity > 0.01
        opacity: shown ? 1.0 : 0.0
        Behavior on opacity { NumberAnimation { duration: theme.motionFast } }
        color: Qt.rgba(0, 0, 0, 0.6)
        MouseArea { anchors.fill: parent; onClicked: picker.shown = false }

        Rectangle {
            anchors.centerIn: parent
            width: Math.min(parent.width * 0.9, 1100); height: Math.min(parent.height * 0.85, 620)
            radius: theme.radiusXl; color: theme.cardBackground; border.width: 1; border.color: theme.cardBorder
            // Same entrance as the SettingsPanel sheet, so every modal in the hub
            // arrives the same way (scale-up + fade, instant under reduce-motion).
            scale: picker.shown ? 1.0 : 0.96
            Behavior on scale { NumberAnimation { duration: theme.motionPage; easing.type: Easing.OutCubic } }
            MouseArea { anchors.fill: parent } // swallow clicks

            ColumnLayout {
                anchors.fill: parent; anchors.margins: theme.spacingLg; spacing: theme.spacingMd
                RowLayout {
                    Layout.fillWidth: true
                    Text { text: "Add a widget"; font.pixelSize: 22; font.bold: true; color: theme.textPrimary; Layout.fillWidth: true }
                    Rectangle {
                        width: theme.touchSecondary; height: theme.touchSecondary; radius: width / 2; color: theme.cardBackgroundAlt
                        AppIcon { anchors.centerIn: parent; name: "ui-close"; size: theme.iconSm; color: theme.textPrimary }
                        MouseArea { anchors.fill: parent; onClicked: picker.shown = false }
                    }
                }
                // A screen never scrolls, so when it is full the next widget simply
                // starts a new screen. Say so up front - it is helpful, not a blocker.
                Rectangle {
                    Layout.fillWidth: true
                    visible: (store.structureRevision, store.pageIsFull(picker.pageIndex))
                    implicitHeight: fullRow.implicitHeight + theme.spacingMd
                    radius: theme.radiusMd
                    color: Qt.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 0.12)
                    border.width: 1; border.color: Qt.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 0.45)
                    RowLayout {
                        id: fullRow
                        anchors.fill: parent; anchors.margins: theme.spacingSm; spacing: theme.spacingSm
                        AppIcon { name: "ui-add-page"; size: 20; color: theme.accent }
                        Text {
                            Layout.fillWidth: true; wrapMode: Text.WordWrap
                            text: "This screen is full - your next widget will start a new screen."
                            font.pixelSize: theme.fontMinimum; color: theme.textPrimary
                        }
                    }
                }
                Flickable {
                    Layout.fillWidth: true; Layout.fillHeight: true; clip: true
                    contentHeight: pickerCol.implicitHeight
                    ColumnLayout {
                        id: pickerCol; width: parent.width; spacing: theme.spacingMd
                        Repeater {
                            model: catalog.categories()
                            delegate: ColumnLayout {
                                required property var modelData
                                // E9: policy-disabled types are absent, not greyed out; a
                                // category the policy empties disappears with them.
                                property var allowedItems: dashboard.policyFilteredWidgets(modelData)
                                visible: allowedItems.length > 0
                                Layout.fillWidth: true; spacing: theme.spacingSm
                                Text { text: modelData; font.pixelSize: theme.fontMinimum; font.bold: true; color: theme.textSecondary }
                                Flow {
                                    Layout.fillWidth: true; spacing: theme.spacingSm
                                    Repeater {
                                        model: allowedItems
                                        delegate: Rectangle {
                                            required property var modelData
                                            width: 200; height: theme.touchPrimary; radius: theme.radiusMd
                                            // Touchscreens have no hover - react to `pressed` so a tap
                                            // gives real feedback (containsMouse alone did nothing).
                                            color: pickMA.pressed ? Qt.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 0.22)
                                                   : (pickMA.containsMouse ? theme.cardBackgroundAlt : theme.backgroundColor)
                                            border.width: 1
                                            border.color: pickMA.pressed ? theme.accent : theme.cardBorder
                                            scale: pickMA.pressed ? 0.97 : 1.0
                                            Behavior on scale { NumberAnimation { duration: theme.motionFast } }
                                            RowLayout {
                                                anchors.fill: parent; anchors.margins: theme.spacingSm; spacing: theme.spacingSm
                                                // iconFor: shipped types resolve by type; user types
                                                // carry their own file or the bundled fallback glyph.
                                                AppIcon {
                                                    readonly property var ic: catalog.iconFor(modelData.type)
                                                    name: ic.name; iconSource: ic.source
                                                    size: 24; color: theme.textSecondary
                                                }
                                                Text { text: modelData.title; font.pixelSize: 15; color: theme.textPrimary; Layout.fillWidth: true; elide: Text.ElideRight }
                                                AppIcon { name: "ui-plus"; size: 20; color: theme.accent }
                                            }
                                            MouseArea {
                                                id: pickMA; anchors.fill: parent; hoverEnabled: true
                                                // Adding never fails: the tile fits this screen, or the
                                                // store starts a new one. Follow it to wherever it landed.
                                                onClicked: {
                                                    var newId = store.addTile(picker.pageIndex, modelData.type)
                                                    picker.shown = false
                                                    if (newId) {
                                                        var tp = store.pageIndexForTile(newId)
                                                        // If the tile started a NEW screen, land on it once the
                                                        // SwipeView grows to fit; if it fit the current screen,
                                                        // goToPage sets it immediately (no count change).
                                                        if (tp >= 0) swipeView.goToPage(tp)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Persistent priority reminder. It deliberately has no auto-close timer and
    // tapping the scrim does nothing: a break, completed focus phase, or due
    // schedule must remain perceptible until the user makes an explicit choice.
    FocusScope {
        id: priorityAlertLayer
        objectName: "priorityAlertSurface"
        anchors.fill: parent
        z: 1000
        readonly property bool shown: dashboard.currentPriorityAlert !== null
        property var shownAlert: ({})
        visible: shown || opacity > 0.01
        enabled: shown
        opacity: shown ? 1.0 : 0.0
        focus: shown
        Accessible.role: Accessible.StaticText
        Accessible.name: "Important reminder. "
                         + String(shownAlert.title || "") + ". "
                         + String(shownAlert.body || "")
        Behavior on opacity {
            NumberAnimation {
                duration: theme.motionPage
                easing.type: Easing.OutCubic
            }
        }
        onShownChanged: {
            if (shown)
                shownAlert = dashboard.currentPriorityAlert
        }
        onOpacityChanged: {
            if (!shown && opacity <= 0.01)
                shownAlert = ({})
        }
        Keys.onEscapePressed: function(event) {
            dashboard.dismissPriorityAlert()
            event.accepted = true
        }

        Rectangle {
            anchors.fill: parent
            color: Qt.rgba(theme.backgroundColor.r, theme.backgroundColor.g,
                           theme.backgroundColor.b, 0.90)
            MouseArea {
                anchors.fill: parent
                // Swallow the press without dismissing the reminder.
                onClicked: priorityAlertLayer.forceActiveFocus()
            }
        }

        Rectangle {
            id: priorityAlertCard
            objectName: "priorityAlertCard"
            anchors.centerIn: parent
            width: Math.min(parent.width - 2 * theme.spacingXl,
                            parent.width > parent.height ? 1120 : 680)
            height: Math.min(parent.height - 2 * theme.spacingXl,
                             priorityAlertContent.implicitHeight
                             + 2 * theme.spacingXl)
            radius: theme.radiusXl
            color: theme.cardBackground
            border.width: 3
            border.color: priorityAlertLayer.shownAlert.accent || theme.warning
            scale: priorityAlertLayer.shown ? 1.0 : 0.95
            Behavior on scale {
                NumberAnimation {
                    duration: theme.motionPage
                    easing.type: Easing.OutBack
                    easing.overshoot: 1.05
                }
            }

            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                height: theme.spacingSm
                radius: parent.radius
                color: priorityAlertLayer.shownAlert.accent || theme.warning
            }

            ColumnLayout {
                id: priorityAlertContent
                anchors.centerIn: parent
                width: parent.width - 2 * theme.spacingXl
                spacing: theme.spacingMd

                Item {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.preferredWidth: 124
                    Layout.preferredHeight: 124

                    Rectangle {
                        id: priorityPulse
                        anchors.centerIn: parent
                        width: 118
                        height: 118
                        radius: width / 2
                        color: "transparent"
                        border.width: 4
                        border.color: priorityAlertLayer.shownAlert.accent
                                      || theme.warning
                        opacity: theme.effectiveReduceMotion ? 0.52 : 0.30
                        scale: 1.0
                        SequentialAnimation on opacity {
                            running: priorityAlertLayer.shown
                                     && !theme.effectiveReduceMotion
                            loops: Animation.Infinite
                            NumberAnimation {
                                from: 0.28
                                to: 0.78
                                duration: 1200
                                easing.type: Easing.InOutSine
                            }
                            NumberAnimation {
                                from: 0.78
                                to: 0.28
                                duration: 1200
                                easing.type: Easing.InOutSine
                            }
                        }
                        SequentialAnimation on scale {
                            running: priorityAlertLayer.shown
                                     && !theme.effectiveReduceMotion
                            loops: Animation.Infinite
                            NumberAnimation {
                                from: 0.96
                                to: 1.10
                                duration: 1200
                                easing.type: Easing.InOutSine
                            }
                            NumberAnimation {
                                from: 1.10
                                to: 0.96
                                duration: 1200
                                easing.type: Easing.InOutSine
                            }
                        }
                    }
                    Rectangle {
                        anchors.centerIn: parent
                        width: 92
                        height: 92
                        radius: width / 2
                        color: Qt.rgba(priorityAlertLayer.shownAlert.accent
                                       ? priorityAlertLayer.shownAlert.accent.r : theme.warning.r,
                                       priorityAlertLayer.shownAlert.accent
                                       ? priorityAlertLayer.shownAlert.accent.g : theme.warning.g,
                                       priorityAlertLayer.shownAlert.accent
                                       ? priorityAlertLayer.shownAlert.accent.b : theme.warning.b,
                                       0.18)
                        border.width: 2
                        border.color: priorityAlertLayer.shownAlert.accent
                                      || theme.warning
                        AppIcon {
                            anchors.centerIn: parent
                            name: priorityAlertLayer.shownAlert.iconName || "ui-warning"
                            size: 46
                            color: priorityAlertLayer.shownAlert.accent
                                   || theme.warning
                        }
                    }
                }

                Text {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: priorityAlertLayer.shownAlert.eyebrow
                          || "IMPORTANT REMINDER"
                    color: priorityAlertLayer.shownAlert.accent || theme.warning
                    font.pixelSize: Math.max(theme.fontLabel, 18)
                    font.bold: true
                    font.letterSpacing: 1.6
                }
                Text {
                    objectName: "priorityAlertTitle"
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: priorityAlertLayer.shownAlert.title || ""
                    color: theme.textPrimary
                    font.family: theme.fontDisplay
                    font.pixelSize: Math.max(30, theme.fontData)
                    font.bold: true
                    wrapMode: Text.WordWrap
                    maximumLineCount: 3
                    elide: Text.ElideRight
                }
                Text {
                    objectName: "priorityAlertBody"
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: priorityAlertLayer.shownAlert.body || ""
                    color: theme.textPrimary
                    font.pixelSize: Math.max(20, theme.fontTitle)
                    wrapMode: Text.WordWrap
                    maximumLineCount: 4
                    elide: Text.ElideRight
                }
                Text {
                    Layout.fillWidth: true
                    visible: text.length > 0
                    horizontalAlignment: Text.AlignHCenter
                    text: priorityAlertLayer.shownAlert.detail || ""
                    color: theme.textSecondary
                    font.pixelSize: Math.max(18, theme.fontLabel)
                    wrapMode: Text.WordWrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                }
                Text {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: dashboard.priorityAlertQueue.length > 1
                          ? dashboard.priorityAlertQueue.length
                            + " reminders waiting"
                          : "Stays visible until you choose"
                    color: theme.textTertiary
                    font.pixelSize: Math.max(16, theme.fontCaption)
                }

                RowLayout {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.fillWidth: true
                    spacing: theme.spacingMd

                    PillButton {
                        id: priorityDismissButton
                        objectName: "priorityAlertDismiss"
                        label: "Dismiss"
                        minWidth: 150
                        onClicked: dashboard.dismissPriorityAlert()
                    }
                    PillButton {
                        id: prioritySecondaryButton
                        objectName: "priorityAlertSecondary"
                        visible: label.length > 0
                        label: priorityAlertLayer.shownAlert.secondaryLabel || ""
                        minWidth: 190
                        onClicked: dashboard.triggerPriorityAlertAction("secondary")
                    }
                    PillButton {
                        id: priorityPrimaryButton
                        objectName: "priorityAlertPrimary"
                        label: priorityAlertLayer.shownAlert.primaryLabel || "Got it"
                        primary: true
                        tint: priorityAlertLayer.shownAlert.accent || theme.warning
                        minWidth: 210
                        onClicked: dashboard.triggerPriorityAlertAction("primary")
                    }
                }
            }
        }
    }

    // Appearance / settings overlay
    SettingsPanel {
        id: settings
        updateChecker: updateChecker
        // Under an org-forced preset the Screens entry is absent (E9).
        presetsLocked: store.policyLockedPreset !== ""
        onCloseRequested: shown = false
        onPresetsRequested: { settings.shown = false; presetPicker.shown = true }
    }

    // Post-setup preset library ("Screens", W5 finding 3) - opened from the
    // settings sheet. A screen is ADDED as a new page (additive), never replacing
    // the user's layout - that's the wizard's/reset's job (applyPreset).
    PresetPicker {
        id: presetPicker
        catalog: presetLib
        widgetCatalog: catalog
        locked: store.policyLockedPreset !== ""
        onApplyRequested: (pid) => { if (dashboard.appendPreset(pid)) presetPicker.shown = false }
        onCloseRequested: shown = false
    }
}
