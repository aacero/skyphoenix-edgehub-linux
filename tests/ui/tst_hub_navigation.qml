import QtQuick
import QtTest
import "../../ui/qml" as App

// Hub page-navigation suite, hosted in the REAL shell (main.qml → contentRoot →
// StackView → Dashboard → SwipeView). tst_dashboard loads Dashboard alone in a
// plain Item and CANNOT see the deferred-relayout snap-back that the rotating
// contentRoot host produces; this suite pushes the real Dashboard into the real
// StackView and asserts the current page is REACHED AND SUSTAINED (a transient
// tryVerify passes even if the view snaps back a moment later).
//
// COVERS: fn:Dashboard.appendPreset, fn:Dashboard.goToPageExternal
// COVERS: fn:Dashboard.goToPage, fn:Dashboard._applyWant
// COVERS: fn:main.requestHubPage, fn:main.hubCurrentPage
// COVERS: fn:main.applyExternalUiState, fn:main.preflightExternalUiState
// COVERS: fn:Dashboard.preflightExternalState, fn:DashboardStore.canApplyExternal
//
// Honest caveat: qmltestrunner runs offscreen with no Wayland compositor, so its
// relayout timing differs from the device - this may not force the exact snap, but
// it exercises the real stack, uses the fixed geometry-committing goToPage, and
// (with the sustained checks) locks the navigation contract against regressions.
Item {
    id: root
    width: 2560; height: 720                 // device panel dimensions (landscape)

    // Shell context props main.qml reads as `property x: _x` (mirror tst_main.qml).
    property bool _isFirstRun: false
    property string _screens: "[]"
    property string _metricsJson: "{}"
    property string _themeMode: "midnight"
    property string _targetEdidHash: ""
    property string _targetConnector: ""
    property string _targetModel: ""
    property string _configDir: "/tmp"
    property bool _safeMode: false
    property bool _startInDiagnostics: false
    property bool _windowedMode: true
    property int _targetScreenX: 0
    property int _targetScreenY: 0
    property int _targetScreenWidth: 2560
    property int _targetScreenHeight: 720
    property string savedUiState: ""
    property int saveCalls: 0
    property alias configBridge: fakeConfigBridge
    QtObject {
        id: fakeConfigBridge
        function uiState() { return "" }
        function saveUiState(json) {
            root.savedUiState = json
            root.saveCalls++
            return true
        }
        function starterLayout() { return "blank" }
        function policy() { return ({ active: false }) }
        function configJson() { return "" }
        function appVersion() { return "test" }
    }

    property var win: null

    function eachItem(node, fn) {
        if (!node) return
        fn(node)
        var kids = node.children
        if (kids) for (var i = 0; i < kids.length; i++) eachItem(kids[i], fn)
    }
    function findPred(node, pred) {
        var f = null
        eachItem(node, function (n) { if (!f && pred(n)) f = n })
        return f
    }
    function swipe() { return findPred(win.contentItem, function (x) { return x && x.objectName === "pageSwipe" }) }
    function dash()  { return findPred(win.contentItem, function (x) { return x && x.appendPreset !== undefined && x.netGate !== undefined }) }
    function store() { return findPred(win.contentItem, function (x) { return x && x.applyExternal !== undefined && x.structureRevision !== undefined }) }

    TestCase {
        name: "HubNavigation"
        when: windowShown

        function initTestCase() {
            var c = Qt.createComponent("../../ui/qml/main.qml")
            tryVerify(function () { return c.status !== Component.Loading }, 5000)
            compare(c.status, Component.Ready, "main.qml compiles: " + c.errorString())
            win = c.createObject(root)
            verify(win !== null, "main.qml instantiated")
            // Force LANDSCAPE - drives contentRotation=90 and the contentRoot
            // width/height swap (the failing host on device).
            win.orientationMode = "landscape"
            compare(win.contentRotation, 90, "shell is in the landscape (swapped) orientation")
            // main.qml resolves its initial page relative to itself, so the REAL
            // Dashboard now loads under qmltestrunner too. Do not push a second one:
            // StackView.find() would correctly find the older page while this test
            // manipulated the newer page, making the Manager round-trip assertion
            // measure two different dashboards.
            var sv = findPred(win.contentItem, function (n) {
                return n && typeof n.push === "function" && n.currentItem !== undefined })
            verify(sv, "found the StackView")
            tryVerify(function () { return dash() !== null && swipe() !== null }, 6000,
                      "the real Dashboard + SwipeView loaded in the shell")
        }
        function cleanupTestCase() { if (win) win.destroy() }

        // The Manager-facing shell API and Dashboard's landing helpers are one
        // routing chain: C++ calls main.requestHubPage(), main finds the Dashboard,
        // Dashboard forwards to the SwipeView, and getUiState reads the same index
        // back through main.hubCurrentPage(). Pin every seam directly so a rename or
        // a route that only works from the on-panel buttons cannot pass unnoticed.
        function test_manager_page_api_routes_and_reports_the_same_page() {
            var s = store(), sw = swipe(), d = dash()
            verify(s && sw && d, "store, SwipeView, and Dashboard present")
            s.load("blank")
            s.addPage(""); s.addPage("")
            tryVerify(function () { return sw.count === 3 }, 3000, "three pages instantiated")

            // _applyWant is the low-level geometry commit used after deferred
            // SwipeView relayouts. Drive it independently of the hold timer.
            sw._wantIndex = 1
            sw.currentIndex = 0
            compare(sw._applyWant(), undefined, "_applyWant commits the remembered target")
            tryCompare(sw, "currentIndex", 1, 3000)
            sw._wantIndex = -1

            compare(sw.goToPage(2), undefined, "goToPage starts a robust landing")
            tryCompare(sw, "currentIndex", 2, 3000)

            compare(d.goToPageExternal(1), undefined,
                    "goToPageExternal forwards a Manager request to the SwipeView")
            tryCompare(sw, "currentIndex", 1, 3000)
            compare(win.hubCurrentPage(), 1,
                    "hubCurrentPage reports the Dashboard page shown on the panel")

            compare(win.requestHubPage(2), undefined,
                    "requestHubPage routes through the real stack to the Dashboard")
            tryCompare(sw, "currentIndex", 2, 3000)
            compare(win.hubCurrentPage(), 2,
                    "hubCurrentPage reports the page reached through the shell API")
        }

        function test_external_ui_state_property_reloads_the_live_dashboard() {
            var s = store(), sw = swipe()
            s.load("blank")
            var propertyPush = JSON.stringify({
                version: 1,
                appearance: { mode: "light", themeMode: "light" },
                settings: {},
                pages: [
                    { name: "Pushed one", tiles: [
                        { id: "pushed-clock", type: "clock", size: "1x1" }
                    ] },
                    { name: "Pushed two", tiles: [
                        { id: "pushed-moon", type: "moon", size: "1x1" }
                    ] }
                ]
            })
            win.externalUiState = propertyPush
            tryVerify(function () {
                return s.pageCount() === 2
                    && s.pages()[0].name === "Pushed one"
                    && s.pages()[1].name === "Pushed two"
                    && sw.count === 2
            }, 3000, "the C++-facing shell property reached Dashboard.applyExternalState")

            var methodPush = JSON.stringify({
                version: 1,
                appearance: { mode: "dark", themeMode: "midnight" },
                settings: {},
                pages: [
                    { name: "Direct push", tiles: [
                        { id: "direct-quote", type: "quote", size: "1x1" }
                    ] }
                ]
            })
            verify(win.applyExternalUiState(methodPush),
                   "the direct C++ bridge method found the live Dashboard")
            tryVerify(function () {
                return s.pageCount() === 1
                    && s.pages()[0].name === "Direct push"
                    && s.pages()[0].tiles[0].id === "direct-quote"
                    && sw.count === 1
            }, 3000, "the direct C++ bridge method repainted the running dashboard")
        }

        function test_unflushed_note_conflicts_before_manager_push_is_persisted() {
            var s = store(), d = dash()
            var localDoc = JSON.stringify({
                version: 1,
                appearance: { themeMode: "midnight", hubControlsMode: "standard" },
                settings: {
                    "hub-note": { text: "saved before typing", history: [] }
                },
                pages: [
                    { name: "Hub work", tiles: [
                        { id: "hub-note", type: "notes", size: "1x1" }
                    ] }
                ]
            })
            verify(s.applyExternal(localDoc), "loaded the Hub document")
            d.expandedId = "hub-note"
            d.expandedType = "notes"
            tryVerify(function () {
                return d.overlayLoaderItem !== null
                       && d.overlayLoaderItem.instanceId === "hub-note"
            }, 5000, "opened the real Quick Note editor")

            var editor = findPred(d.overlayLoaderItem, function (x) {
                return x && x.objectName === "notesEditor"
            })
            verify(editor !== null, "found the real NotesWidget TextEdit")
            editor.text = "unfinished local Hub edit"
            compare(d.overlayLoaderItem.hasPendingChanges(), true,
                    "the note is still inside its 400 ms local buffer")
            compare(s.settingsFor("hub-note").text, "saved before typing",
                    "the shared document does not contain the buffered text yet")

            var managerDoc = JSON.stringify({
                version: 1,
                appearance: { themeMode: "light", hubControlsMode: "standard" },
                settings: { "manager-clock": {} },
                pages: [
                    { name: "Manager replacement", tiles: [
                        { id: "manager-clock", type: "clock", size: "1x1" }
                    ] }
                ]
            })
            compare(d.preflightExternalState("not json"), "rejected",
                    "Dashboard preflight rejects an invalid document without flushing")
            compare(d.overlayLoaderItem.hasPendingChanges(), true,
                    "invalid input cannot consume or overwrite the local buffer")
            compare(s.canApplyExternal(managerDoc), true,
                    "the valid Manager replacement passes non-mutating validation")
            root.savedUiState = ""
            var savesBefore = root.saveCalls
            compare(win.preflightExternalUiState(managerDoc), "conflict",
                    "the first Manager push is rejected as an explicit conflict")
            compare(root.saveCalls, savesBefore + 1,
                    "preflight persisted the unfinished Hub edit exactly once")
            compare(s.settingsFor("hub-note").text, "unfinished local Hub edit",
                    "the live Hub document retained the local edit")
            compare(JSON.parse(root.savedUiState).settings["hub-note"].text,
                    "unfinished local Hub edit",
                    "the disk-facing bridge received the same local edit")
            compare(s.pages()[0].tiles[0].id, "hub-note",
                    "the rejected Manager document did not rebuild the panel")
            verify(win.persistenceWarningText.indexOf("unfinished edit") >= 0,
                    "the Hub makes the conflict visible")

            compare(win.preflightExternalUiState(managerDoc), "ready",
                    "retry is allowed only after the local buffer is saved")
            verify(root.configBridge.saveUiState(managerDoc),
                    "simulate ConfigBridge persisting the accepted retry")
            var savesAfterManagerPersist = root.saveCalls
            verify(win.applyExternalUiState(managerDoc),
                    "the accepted retry applies to the live Dashboard")
            tryVerify(function () {
                return s.pages()[0].name === "Manager replacement"
                       && s.pages()[0].tiles[0].id === "manager-clock"
                       && s.pageIndexForTile("hub-note") === -1
            }, 3000, "the Hub now renders the Manager document")
            wait(900)
            compare(root.saveCalls, savesAfterManagerPersist,
                    "destroying the old note cannot echo stale text after the push")
            verify(s.document.settings["hub-note"] === undefined,
                   "the removed note has no settings key at all, not an orphan {} bucket")
            // The Hub NORMALISES what it applies, filling in its own appearance
            // defaults, so byte-comparing against the raw Manager payload only
            // ever passed because normalisation happened to be a no-op for the
            // keys this document uses. It broke the moment a new defaulted key
            // landed (`pageCycleSec`), and would break again for the next one.
            //
            // The invariant that actually matters is that the Hub changed
            // nothing the Manager SAID: same pages, same settings, same version,
            // and every key the Manager sent still carrying the Manager's value.
            // Extra keys are allowed ONLY inside appearance, and only as
            // defaults - pages and settings are still compared whole, so an
            // invented tile or a dropped settings bucket still fails.
            var live = s._persistableData()
            var sent = JSON.parse(managerDoc)
            compare(JSON.stringify(live.pages), JSON.stringify(sent.pages),
                    "the live Hub pages are exactly the Manager retry's pages")
            compare(JSON.stringify(live.settings), JSON.stringify(sent.settings),
                    "and so are its settings buckets")
            compare(live.version, sent.version, "and the schema version")
            for (var sentKey in sent.appearance)
                compare(live.appearance[sentKey], sent.appearance[sentKey],
                        "appearance." + sentKey + " still holds what the Manager sent")
            var topKeys = Object.keys(live).sort()
            compare(JSON.stringify(topKeys),
                    JSON.stringify(["appearance", "pages", "settings", "version"]),
                    "the Hub invented no new top-level section")
            compare(root.savedUiState, managerDoc,
                    "disk holds the Manager retry verbatim - the Hub's own defaults "
                    + "reach it on the next save, not by rewriting the push")
            compare(win.persistenceWarningText, "",
                    "a successful explicit retry clears the resolved conflict")
        }

        // The bug: after adding pages the view must LAND on the new page and STAY -
        // not snap back to page 0 a moment later.
        function test_add_page_lands_and_stays_landscape() {
            var s = store(), sw = swipe()
            verify(s && sw, "store + SwipeView present")
            s.load("blank")
            tryVerify(function () { return sw.count === s.pageCount() }, 3000, "SwipeView synced to blank")
            for (var n = 0; n < 3; n++) {
                var target = s.pageCount()               // the new page's index
                s.addPage("")
                sw.goToPage(target)
                tryVerify(function () { return sw.currentIndex === target }, 4000,
                          "reached new page " + target)
                wait(900)                                 // outlast a deferred relayout
                compare(sw.currentIndex, target,
                        "STAYED on new page " + target + " (did not snap back)")
            }
        }

        // Applying a preset is additive and must land+stay on the appended screen.
        function test_additive_preset_lands_and_stays() {
            var s = store(), sw = swipe(), d = dash()
            s.load("blank")
            tryVerify(function () { return sw.count === s.pageCount() }, 3000)
            var target = s.pageCount()
            verify(d.appendPreset("system-monitor"), "appended a preset screen")
            tryVerify(function () { return sw.currentIndex === target }, 4000, "reached appended screen")
            wait(900)
            compare(sw.currentIndex, target, "STAYED on the appended screen")
        }

        // A widget that overflows a full screen starts a new screen and the view
        // follows to it (and stays).
        function test_widget_overflow_navigates_and_stays() {
            var s = store(), sw = swipe()
            s.load("blank")
            s.addTile(0, "cpu"); s.addTile(0, "gpu"); s.addTile(0, "ram")   // page 0 now full
            var overflowId = s.addTile(0, "clock")                          // → new screen
            verify(overflowId, "overflow tile added")
            var target = s.pageIndexForTile(overflowId)
            compare(target, 1, "overflow created a second screen")
            sw.goToPage(target)
            tryVerify(function () { return sw.currentIndex === target }, 4000, "reached overflow screen")
            wait(900)
            compare(sw.currentIndex, target, "STAYED on the overflow screen")
        }

        // Removing the current page re-clamps to a valid, in-range index.
        function test_remove_page_reclamps() {
            var s = store(), sw = swipe()
            s.load("blank")
            s.addPage(""); s.addPage("")                 // 3 pages: 0,1,2
            sw.goToPage(2)
            tryVerify(function () { return sw.currentIndex === 2 }, 3000)
            var i = sw.currentIndex
            s.removePage(i)
            sw.goToPage(Math.max(0, Math.min(i, s.pageCount() - 1)))
            tryVerify(function () { return sw.currentIndex === s.pageCount() - 1 }, 3000,
                      "clamped onto a valid page after removing the last")
            verify(sw.currentIndex >= 0 && sw.currentIndex < sw.count, "index in range")
        }

        // A rotation must PRESERVE the current page (the reflow re-projects, it does
        // not reset navigation) - the rotation analogue of the add-page bug.
        function test_nav_survives_a_rotation() {
            var s = store(), sw = swipe()
            s.load("blank")
            s.addPage(""); s.addPage("")
            sw.goToPage(2)
            tryVerify(function () { return sw.currentIndex === 2 }, 3000)
            win.orientationMode = "portrait"             // rotate
            wait(700)
            compare(sw.currentIndex, 2, "current page survived the rotation to portrait")
            win.orientationMode = "landscape"            // rotate back
            wait(700)
            compare(sw.currentIndex, 2, "current page survived the rotation back to landscape")
        }
    }
}
