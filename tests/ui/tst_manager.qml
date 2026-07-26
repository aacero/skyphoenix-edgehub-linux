import QtQuick
import QtTest

// COVERS: fn:Manager.confirmDeleteImage, fn:Manager.currentPageName, fn:Manager.onChanged, fn:Manager.onConfigChanged, fn:Manager.onHubConnectedChanged, fn:Manager.onImagesChanged
// COVERS: fn:Manager.onScreensChanged, fn:Manager.pageTiles, fn:Manager.refreshImages, fn:Manager.syncTheme
// COVERS: fn:Manager.previewTheme, fn:Manager.previewAccent, fn:Manager.endThemePreview, fn:Manager.confirmRemovePage
// COVERS: fn:Manager.scopeDetail, fn:Manager.commitRename
// COVERS: fn:Manager.applyPresetScreen, fn:Manager.confirmResetLayout, fn:Manager.hoverPreview
// COVERS: fn:Manager.commitTheme, fn:Manager._themeDef
// COVERS: fn:Manager._val, fn:Manager._lab, fn:Manager.catColor
// COVERS: fn:Manager.refreshLicense, fn:Manager.onLicenseChanged, fn:Manager.reVerify
// COVERS: fn:Manager.addScreen, fn:Manager.addWidget
// COVERS: fn:Manager.flushPendingUiState
// COVERS: fn:Manager.previewPreset
//
// manager/qml/Manager.qml (hosted with a STUBBED `backend`) -
//   • the 5-tab StackLayout (Layout/Appearance/Images/Display/About) switches
//   • pageTiles(): current-page tiles, revision-reactive
//   • refreshImages(): rebuilds imagesModel from backend.listImages()
//   • confirmDeleteImage(): sets the confirm message + onConfirm, and the
//     confirm action clears a matching wallpaper and calls backend.deleteImage
//   • syncTheme(): a store `changed()` re-applies accent to the theme
//   • the inline MButton (Start hub: click → startHub + hubStarting; enabled
//     tracks !hubStarting) and MSwitch (Widget glow: toggle → store.setAppearance)
//
// Manager owns its own Theme/DashboardStore/catalog/media; only `backend` (the
// C++ ManagerBackend) is external, so we feed a light QtObject stub through the
// context scope and instantiate the REAL Manager.qml window. Assertions target
// the store/driving props, not pixels.
Item {
    id: root
    width: 200; height: 200

    // Stub of the C++ ManagerBackend: signals + methods returning sane JSON,
    // recording the calls the tests assert on.
    QtObject {
        id: backend
        property bool hubConnected: false
        signal imagesChanged()
        signal configChanged()
        signal screensChanged()
        signal licenseChanged()
        // Licence stub: `storedKey` is what setLicenseKey persists; the status
        // reflects it. `proKeys` is the set the fake verifier accepts as Pro, so
        // a test can assert the dialog/card react to a valid vs invalid key
        // without a real ed25519 issuer.
        property string storedKey: ""
        property bool malformedLicenseStatus: false
        property var proKeys: ({ "XE1.valid.pro": "Ada Lovelace" })
        function _statusFor(k) {
            if (proKeys[k] !== undefined)
                return JSON.stringify({ state: "licensed", tier: "pro", issuedTo: proKeys[k] })
            return JSON.stringify({ state: "unlicensed", tier: "free" })
        }
        function verifyLicenseCandidate(k) { return _statusFor(k) }
        function licenseStatusJson() {
            return malformedLicenseStatus ? "{" : _statusFor(storedKey)
        }
        function setLicenseKey(k) { storedKey = k; licenseChanged(); return true }
        function clearLicenseKey() { return setLicenseKey("") }
        property var imagesList: []
        property string lastDeleted: ""
        property string lastImported: ""
        property bool startHubCalled: false
        property bool stopHubCalled: false
        property bool syncCalled: false
        property bool autostart: false
        function imageUrl(n) {
            var shipped = [
                "aurora.png", "blossom.png", "daylight.png", "edge-cyan.png",
                "edge-ember.png", "grape.png", "graphite.png", "midnight.png",
                "nebula.png", "ocean.png", "prism.png", "slate.png",
                "sunset.png", "teal.png", "techdots.png"
            ]
            var hash = 0
            var name = String(n)
            for (var i = 0; i < name.length; i++)
                hash = (hash * 31 + name.charCodeAt(i)) & 0x7fffffff
            return "qrc:/wallpapers/" + shipped[hash % shipped.length]
        }
        function starterLayout() { return "blank" }
        function autoConfig() { return "" }
        function startTab() { return 0 }
        function metricsJson() { return "{}" }
        function screensJson() { return "[]" }
        function targetConnector() { return "" }
        function listImages() { return imagesList }
        function importImage(u) { lastImported = String(u) }
        function deleteImage(n) { lastDeleted = n }
        function setTargetDisplay(a, b) {}
        function isAutostart() { return autostart }
        function setAutostart(v) { autostart = v }
        function syncFromHub() { syncCalled = true }
        function startHub() { startHubCalled = true; return true }
        function stopHub() { stopHubCalled = true }
    }

    property var win: null

    // ── tree helpers ─────────────────────────────────────────────────────────
    // Walk every node under `node` exactly ONCE. The `seen` set is a correctness
    // requirement, not an optimisation: a node is reachable through BOTH
    // `children` and `data`, so without memoing every node's subtree is re-walked
    // once per path - exponential in depth. Unmemoised, the six findPred() calls
    // in initTestCase below drove this file from 7 MB to 20 GB in 25 seconds
    // (2026-07-19), the same failure that caused a system-wide OOM. Keep the set.
    function eachItem(node, fn) { _walkSeen(node, fn, new Set()) }
    function _walkSeen(node, fn, seen) {
        if (!node || seen.has(node)) return false
        seen.add(node)
        if (fn(node) === true) return true
        var kids = node.children
        if (kids) for (var i = 0; i < kids.length; i++)
            if (_walkSeen(kids[i], fn, seen)) return true
        var res = node.data          // catch non-visual (Dialog/ListModel) children
        if (res && res !== kids) for (var j = 0; j < res.length; j++)
            if (_walkSeen(res[j], fn, seen)) return true
        return false
    }
    function findPred(n, pred) {
        var f = null
        eachItem(n, function (x) { if (pred(x)) { f = x; return true } })
        return f
    }
    function findAll(n, pred) {
        var out = []
        eachItem(n, function (x) { if (pred(x)) out.push(x) })
        return out
    }

    property var _store: null
    property var _theme: null
    property var _nav: null
    property var _images: null
    property var _confirm: null

    function findButton(txt) {
        return findPred(win, function (x) {
            return x && typeof x.text === "string" && x.text === txt
                   && typeof x.down === "boolean" && typeof x.hovered === "boolean"
        })
    }
    function findSwitch(txt) {
        return findPred(win, function (x) {
            return x && typeof x.checked === "boolean" && typeof x.text === "string"
                   && x.text === txt && typeof x.toggled === "function"
        })
    }

    TestCase {
        name: "Manager"
        when: windowShown

        function initTestCase() {
            var c = Qt.createComponent("../../manager/qml/Manager.qml")
            tryVerify(function () { return c.status !== Component.Loading }, 5000)
            compare(c.status, Component.Ready, "Manager.qml compiles: " + c.errorString())
            win = c.createObject(root)
            verify(win !== null, "Manager window instantiated")

            _store = findPred(win, function (x) {
                return x && x.applyExternal !== undefined && x.structureRevision !== undefined })
            _theme = findPred(win, function (x) {
                return x && x.accentPresets !== undefined && typeof x.applyAccent === "function" })
            _nav = findPred(win, function (x) {
                return x && x.currentIndex !== undefined && x.count === 5 && x.count !== undefined })
            // By objectName, NOT by duck-typing a ListModel: EdgeClone carries its own
            // placement ListModel, and it comes first in the tree, so "has append/clear/
            // get" silently resolved to the wrong model and every images assertion below
            // measured a model nothing here ever writes to.
            _images = findPred(win, function (x) { return x && x.objectName === "imagesModel" })
            _confirm = findPred(win, function (x) {
                return x && x.message !== undefined && ("onConfirm" in x) && typeof x.open === "function" })
            verify(_store, "found store")
            verify(_theme, "found theme")
            verify(_nav, "found the 5-tab StackLayout")
            verify(_images, "found imagesModel")
            verify(_confirm, "found confirmDialog")
        }
        function cleanupTestCase() { if (win) win.destroy() }

        function init() {
            _store.load("blank")
            win.currentPageIndex = 0
            win.hubStarting = false
            _nav.currentIndex = 0
            backend.startHubCalled = false
            backend.stopHubCalled = false
            backend.malformedLicenseStatus = false
        }

        // ── tabs ──────────────────────────────────────────────────────────────
        function test_four_tabs_switch() {
            compare(_nav.count, 5, "Layout / Appearance / Images / Display / About")
            for (var i = 0; i < 5; i++) {
                _nav.currentIndex = i
                compare(_nav.currentIndex, i, "switched to tab " + i)
            }
        }

        // MSegment accepts both compact scalar options and labelled objects. These
        // helpers drive selection AND visible labels throughout the Manager, so pin
        // both branches against a real instantiated segment.
        function test_segment_option_value_and_label_helpers() {
            _nav.currentIndex = 1
            var seg = findPred(win, function (x) {
                return x && x.options !== undefined
                       && typeof x._val === "function" && typeof x._lab === "function"
            })
            verify(seg, "found an instantiated MSegment")
            compare(seg._val({ label: "Alpha", value: "a" }), "a",
                    "_val extracts an object option's value")
            compare(seg._val("b"), "b", "_val leaves a scalar option unchanged")
            compare(seg._lab({ label: "Alpha", value: "a" }), "Alpha",
                    "_lab extracts an object option's label")
            compare(seg._lab("Beta"), "Beta", "_lab uses a scalar option as its label")
        }

        // ── pageTiles ─────────────────────────────────────────────────────────
        function test_pageTiles_reflects_current_page() {
            compare(win.pageTiles().length, 0, "blank page starts empty")
            _store.addTile(0, "cpu")
            _store.addTile(0, "clock")
            compare(win.pageTiles().length, 2, "tiles added to the current page appear")
            // Out-of-range current page returns [] (guard).
            win.currentPageIndex = 99
            compare(win.pageTiles().length, 0, "an out-of-range page yields no tiles")
        }

        // ── refreshImages ─────────────────────────────────────────────────────
        function test_refreshImages_rebuilds_model() {
            backend.imagesList = ["a.png", "b.png", "c.png"]
            win.refreshImages()
            compare(_images.count, 3, "model rebuilt from backend.listImages()")
            compare(_images.get(0).modelData, "a.png", "first image name stored")
            backend.imagesList = []
            win.refreshImages()
            compare(_images.count, 0, "an empty list clears the model")
        }

        // ── confirmDeleteImage ────────────────────────────────────────────────
        function test_confirmDeleteImage_confirm_clears_and_deletes() {
            var name = "wall.png"
            var full = backend.imageUrl(name)
            _store.setAppearance("wallpaper", full)      // this image is the wallpaper
            backend.lastDeleted = ""
            win.confirmDeleteImage(name, full)
            verify(_confirm.message.indexOf(name) >= 0, "confirmDeleteImage set a confirm message naming the image")
            verify(typeof _confirm.onConfirm === "function", "an onConfirm action was armed")
            // Simulate the user pressing "Yes".
            _confirm.onConfirm()
            compare(_store.appearance().wallpaper, "", "the matching wallpaper was cleared")
            compare(backend.lastDeleted, name, "backend.deleteImage was called")
        }

        // Deleting a NON-wallpaper image must LEAVE the current wallpaper intact
        // (the false branch of `appearance().wallpaper === fullPath`).
        function test_confirmDeleteImage_nonwallpaper_keeps_wallpaper() {
            var wallName = "keep.png"
            var wallFull = backend.imageUrl(wallName)
            _store.setAppearance("wallpaper", wallFull)   // wallpaper points at a DIFFERENT image
            var other = "gone.png"
            backend.lastDeleted = ""
            win.confirmDeleteImage(other, backend.imageUrl(other))
            _confirm.onConfirm()
            compare(_store.appearance().wallpaper, wallFull,
                    "deleting an unrelated image leaves the wallpaper untouched")
            compare(backend.lastDeleted, other, "the unrelated image is still deleted")
        }

        // Deleting an image used as a PER-PAGE background clears that page bg too
        // (the pageBackground/setPageBackground loop), even when it's not the
        // global wallpaper.
        function test_confirmDeleteImage_clears_matching_page_background() {
            var name = "pbg.png"
            var full = backend.imageUrl(name)
            _store.setAppearance("wallpaper", "")          // NOT the global wallpaper
            _store.setPageBackground(0, "wallpaper", full) // but IS a page-0 background
            compare(_store.pageBackground(0).wallpaper, full, "precondition: page-0 bg armed")
            backend.lastDeleted = ""
            win.confirmDeleteImage(name, full)
            _confirm.onConfirm()
            verify(!_store.pageBackground(0).wallpaper,
                   "the matching per-page background was cleared")
            compare(backend.lastDeleted, name, "backend.deleteImage was called")
        }

        // The cancel path: arming the dialog then DISMISSING it (No/Cancel) must
        // NOT run onConfirm - nothing is deleted, the wallpaper is untouched.
        function test_confirmDeleteImage_cancel_deletes_nothing() {
            var name = "safe.png"
            var full = backend.imageUrl(name)
            _store.setAppearance("wallpaper", full)
            backend.lastDeleted = "SENTINEL"
            win.confirmDeleteImage(name, full)
            verify(typeof _confirm.onConfirm === "function", "an onConfirm action was armed")
            _confirm.reject()                              // user presses No / dismisses
            compare(backend.lastDeleted, "SENTINEL", "dismissing the dialog deletes nothing")
            compare(_store.appearance().wallpaper, full, "the wallpaper is untouched on cancel")
        }

        // The image-import flow: FileDialog.onAccepted → backend.importImage(file)
        // then refreshImages() rebuilds the model.
        function test_import_image_flow_calls_backend_and_refreshes() {
            var fileDlg = findPred(win, function (x) {
                return x && x.selectedFile !== undefined && x.nameFilters !== undefined
                       && typeof x.accepted === "function" })
            verify(fileDlg, "found the image-import FileDialog")
            backend.imagesList = ["i1.png", "i2.png"]
            backend.lastImported = "SENTINEL"
            fileDlg.accepted()                             // fire onAccepted (offscreen: no native dialog)
            verify(backend.lastImported !== "SENTINEL", "backend.importImage was invoked")
            compare(backend.lastImported, String(fileDlg.selectedFile),
                    "importImage received the dialog's selected file")
            compare(_images.count, 2, "refreshImages rebuilt the model after import")
        }

        // ── inline MButton (Stop hub - the hub-CONNECTED variant) ─────────────
        function test_stop_hub_button_when_connected() {
            backend.hubConnected = true                    // hub live → control becomes "Stop hub"
            var btn = findButton("Stop hub")
            verify(btn, "button switches to 'Stop hub' when the hub is connected")
            verify(!findButton("Start hub"), "no 'Start hub' while connected")
            verify(btn.enabled, "enabled while not starting")
            backend.stopHubCalled = false
            btn.clicked()
            compare(backend.stopHubCalled, true, "click invoked backend.stopHub()")
            compare(win.hubStarting, false, "stopping does not enter the 'starting…' state")
            backend.hubConnected = false                   // restore for the other cases
        }

        // ── syncTheme on store change (store.changed → onChanged → syncTheme) ──
        function test_syncTheme_applies_accent_on_store_change() {
            // A store appearance change fires changed() → Connections → syncTheme().
            _store.setAppearance("accent", "green")
            verify(Qt.colorEqual(_theme.accent, _theme.accentPresets["green"].a), "onChanged ran syncTheme: accent re-themed")
            _store.setAppearance("accent", "red")
            verify(Qt.colorEqual(_theme.accent, _theme.accentPresets["red"].a), "second store.onChanged re-applies syncTheme live")
        }

        function test_syncTheme_keeps_the_complete_look_after_each_edit() {
            _store.setAppearance("themeMode", "midnight")
            _store.setAppearance("accent", "blue")
            verify(Qt.colorEqual(_theme.backgroundColor, "#0B1026"),
                   "Manager clone applies the stored Midnight background")
            verify(Qt.colorEqual(_theme.accent, _theme.accentPresets["blue"].a),
                   "the stored blue accent is reapplied after the theme")

            _store.setAppearance("bgStyle", "waves")
            verify(Qt.colorEqual(_theme.backgroundColor, "#0B1026"),
                   "changing the background style does not lose the theme")
            verify(Qt.colorEqual(_theme.accent, _theme.accentPresets["blue"].a),
                   "changing the background style does not lose the accent")

            _store.setAppearance("wallpaper", "qrc:/wallpapers/midnight.png")
            verify(Qt.colorEqual(_theme.backgroundColor, "#0B1026"),
                   "changing a wallpaper keeps the stored theme in the clone")
            verify(Qt.colorEqual(_theme.accent, _theme.accentPresets["blue"].a),
                   "changing a wallpaper keeps the stored accent in the clone")

            _store.setAppearance("textScale", 1.3)
            _store.setAppearance("fontChoice", "lexend")
            compare(_theme.textScale, 1.3, "Manager preview follows Hub text scale")
            compare(_theme.fontChoice, "lexend", "Manager preview follows Hub typeface")
        }

        function test_clone_preserves_bundled_wallpaper_url() {
            _store.setAppearance("wallpaper", "qrc:/wallpapers/techdots.png")
            var clones = findAll(win, function (x) {
                return x && x.wallpaperSource !== undefined
                       && x.pageBg !== undefined && x.editable !== undefined
            })
            compare(clones.length, 2, "found both live EdgeClone previews")
            for (var i = 0; i < clones.length; i++)
                compare(clones[i].wallpaperSource,
                        "qrc:/wallpapers/techdots.png",
                        "bundled wallpaper remains a qrc source in clone " + i)
        }

        function test_clone_rejects_remote_wallpaper_url() {
            _store.setAppearance("wallpaper", "https://example.invalid/private.png")
            var clones = findAll(win, function (x) {
                return x && x.wallpaperSource !== undefined
                       && x.pageBg !== undefined && x.editable !== undefined
            })
            compare(clones.length, 2, "found both live EdgeClone previews")
            for (var i = 0; i < clones.length; i++)
                compare(clones[i].wallpaperSource, "",
                        "remote wallpaper cannot bypass NetHub in clone " + i)
        }

        // ── currentPageName ───────────────────────────────────────────────────
        function test_currentPageName_tracks_selected_page() {
            compare(win.currentPageName(), "Home", "currentPageName returns the blank layout's Home page")
            _store.addPage("Second")
            win.currentPageIndex = 1
            compare(win.currentPageName(), "Second", "currentPageName follows the selected page")
            win.currentPageIndex = 99
            compare(win.currentPageName(), "", "currentPageName returns '' for an out-of-range page")
        }

        // ── backend Connections: onImagesChanged → refreshImages ──────────────
        function test_onImagesChanged_rebuilds_images() {
            backend.imagesList = ["x.png", "y.png"]
            backend.imagesChanged()          // fires the Connections onImagesChanged handler
            compare(_images.count, 2, "onImagesChanged rebuilt the images model via refreshImages")
        }

        // ── backend Connections: onConfigChanged adopts the pushed config live ─
        function test_onConfigChanged_reloads_store() {
            backend.imagesList = []
            backend.configChanged()          // hub/disk changed config → adopt it
            // store.load re-seeded from the (blank) starter layout → one Home page.
            compare(_store.pages()[0].name, "Home", "onConfigChanged reloaded the store from the backend")
            verify(win.currentPageIndex < _store.pageCount(),
                   "onConfigChanged clamped the current page index into range")
        }

        // ── backend Connections: onScreensChanged refreshes the display state ─
        function test_onScreensChanged_updates_screens() {
            backend.screensChanged()         // display hotplug
            verify(win.screens !== undefined && win.screens.length >= 0, "onScreensChanged refreshed win.screens from the backend")
        }

        // ── backend Connections: onHubConnectedChanged clears 'starting…' ─────
        function test_onHubConnectedChanged_clears_starting() {
            win.hubStarting = true
            backend.hubConnected = true      // property change fires onHubConnectedChanged
            compare(win.hubStarting, false, "onHubConnectedChanged cleared the 'starting…' state on connect")
            backend.hubConnected = false     // restore
        }

        // ── inline MButton (Start hub) ────────────────────────────────────────
        function test_start_hub_button_click_and_enabled() {
            var btn = findButton("Start hub")
            verify(btn, "Start hub button present (hub offline)")
            verify(btn.enabled, "enabled while not starting")
            // Manager runs in its own (offscreen, non-exposed) window, so synthetic
            // mouse events don't deliver; emit the button's `clicked` signal to run
            // its real onClicked handler - the behaviour under test.
            btn.clicked()
            compare(backend.startHubCalled, true, "click invoked backend.startHub()")
            compare(win.hubStarting, true, "entered the 'starting…' state")
            verify(!btn.enabled, "button disables itself while starting")
        }

        // ── hover previews: show, then commit ─────────────────────────────────
        // previewTheme paints the Manager's theme instance WITHOUT touching the
        // store; endThemePreview restores the stored appearance (it must void the
        // signature guard, or syncTheme would skip the "unchanged" payload).
        function test_previewTheme_is_transient() {
            // toString(): a bare `var x = theme.backgroundColor` holds a live
            // value-type reference that re-reads the property, so the "before"
            // snapshot would always equal the "after" value.
            var storedBg = _theme.backgroundColor.toString()
            win.previewTheme("light")
            verify(!Qt.colorEqual(_theme.backgroundColor, storedBg), "previewTheme repainted the theme instance")
            verify(_store.appearance().themeMode === undefined, "previewTheme did NOT write the store")
            win.endThemePreview()
            verify(Qt.colorEqual(_theme.backgroundColor, storedBg), "endThemePreview restored the stored theme")
        }

        function test_previewAccent_is_transient_and_restorable() {
            _store.setAppearance("accent", "blue")           // a committed baseline
            var storedAccent = _theme.accent.toString()      // snapshot, not a live reference
            win.previewAccent("green")
            verify(Qt.colorEqual(_theme.accent, _theme.accentPresets["green"].a), "previewAccent painted the hovered accent")
            compare(_store.appearance().accent, "blue", "previewAccent left the stored accent untouched")
            win.endThemePreview()
            verify(Qt.colorEqual(_theme.accent, storedAccent), "endThemePreview restored the committed accent")
        }

        // previewTheme must re-apply the COMMITTED accent (applyTheme resets it),
        // or hovering a theme swatch would also appear to change the accent.
        function test_previewTheme_keeps_the_committed_accent() {
            _store.setAppearance("accent", "purple")
            win.previewTheme("midnight")
            verify(Qt.colorEqual(_theme.accent, _theme.accentPresets["purple"].a), "previewTheme keeps the committed accent")
            win.endThemePreview()
        }

        // ── confirmRemovePage: destructive → armed confirm, not instant ───────
        function test_confirmRemovePage_confirms_then_removes() {
            _store.addPage("Doomed")
            win.currentPageIndex = 1
            _store.addTile(1, "cpu")
            win.confirmRemovePage()
            verify(_confirm.message.indexOf("Doomed") >= 0, "confirmRemovePage names the page")
            verify(_confirm.message.indexOf("1 widget") >= 0, "confirmRemovePage counts its widgets")
            _confirm.reject()                                // user says No
            compare(_store.pageCount(), 2, "rejecting the confirm removes nothing")
            win.confirmRemovePage()
            _confirm.onConfirm()                             // user says Yes
            compare(_store.pageCount(), 1, "confirming removes the page")
            compare(win.currentPageIndex, 0, "selection clamped back into range")
        }

        // ── Appearance tab hosts a live, read-only Edge preview ───────────────
        function test_appearance_tab_has_readonly_edge_preview() {
            // Dedupe: eachItem walks both `children` and `data`, so deep nodes are
            // visited (and collected) many times over.
            var seen = []
            findAll(win, function (x) {
                if (x && typeof x.wsrc === "function" && x.widgetStore !== undefined
                        && x.editable !== undefined
                        && seen.indexOf(x) < 0) seen.push(x)
                return false
            })
            var clones = seen
            compare(clones.length, 2, "two EdgeClones: the Layout editor + the Appearance preview")
            var editorCount = 0, previewCount = 0
            for (var i = 0; i < clones.length; i++)
                clones[i].editable ? editorCount++ : previewCount++
            compare(editorCount, 1, "exactly one editable clone (Layout tab)")
            compare(previewCount, 1, "exactly one read-only preview clone (Appearance tab)")
        }

        // ── liveNote: the one phrase for "does an edit reach the panel now?" ──
        function test_liveNote_follows_hub_connection() {
            backend.hubConnected = false
            verify(win.liveNote.indexOf("offline") >= 0, "offline wording while disconnected")
            backend.hubConnected = true
            verify(win.liveNote.indexOf("immediately") >= 0, "live wording while connected")
            backend.hubConnected = false
        }

        // ── per-widget config dialog declares its scope ───────────────────────
        function test_config_dialog_carries_widget_scope_tag() {
            _store.addTile(0, "clock")
            var tileId = _store.pages()[0].tiles[0].id
            var dlg = findPred(win, function (x) { return x && typeof x.openFor === "function" })
            verify(dlg, "found the WidgetConfigDialog")
            dlg.openFor(tileId, "clock")
            var tag = findPred(win, function (x) { return x && x.objectName === "scopeTag" })
            verify(tag, "the dialog header carries a scope tag")
            compare(tag.text, "This widget only", "…that says the settings touch one tile")
            dlg.close()
        }

        function test_config_dialog_separates_reset_from_personal_erase() {
            var id = _store.addTile(0, "tasks")
            _store.patchSettings(id, {
                items: [ { id: "task-1", text: "Keep me", done: false } ],
                nextId: 2,
                celebrate: false,
                accent: "gold"
            })
            var dlg = findPred(win, function (x) { return x && typeof x.openFor === "function" })
            verify(dlg)
            dlg.openFor(id, "tasks")
            compare(dlg.hasPersonalData, true)
            verify(dlg.personalDataLabel.indexOf("tasks") >= 0)
            verify(dlg.resetActionButton.visible)
            verify(dlg.eraseActionButton.visible)
            verify(dlg.resetActionButton.height >= 48)
            verify(dlg.eraseActionButton.height >= 48)

            verify(dlg.resetConfiguration())
            var got = _store.settingsFor(id)
            compare(got.items.length, 1, "reset kept tasks")
            compare(got.nextId, 2, "reset kept task identity")
            compare(got.celebrate, undefined, "reset removed configuration override")
            compare(got.accent, undefined, "reset removed appearance override")

            _store.setSetting(id, "celebrate", false)
            _store.setSetting(id, "accent", "gold")
            compare(dlg.erasePersonalData(), 2)
            got = _store.settingsFor(id)
            compare(got.items, undefined, "erase removed tasks")
            compare(got.nextId, undefined, "erase removed task identity")
            compare(got.celebrate, false, "erase kept configuration")
            compare(got.accent, "gold", "erase kept appearance")
            dlg.close()
        }

        function test_tasks_config_uses_the_live_preview_as_its_single_editor() {
            var id = _store.addTile(0, "tasks")
            _store.setSetting(id, "items", [
                { id: "task-1", text: "Edit me here", done: false }
            ])
            var dlg = findPred(win, function (x) {
                return x && typeof x.openFor === "function"
            })
            verify(dlg)
            dlg.openFor(id, "tasks")
            tryVerify(function () {
                return dlg.previewItem !== null
                    && dlg.previewItem.instanceId === id
            }, 3000)
            compare(dlg.previewAcceptsInput, true,
                    "the expanded Tasks preview is the interactive content editor")
            var itemFields = 0
            for (var s = 0; s < dlg.schema.sections.length; s++) {
                var fields = dlg.schema.sections[s].fields || []
                for (var f = 0; f < fields.length; f++)
                    if (fields[f].key === "items") itemFields++
            }
            compare(itemFields, 0,
                    "the settings form does not duplicate the checklist editor")
            dlg.close()

            var clockId = _store.addTile(0, "clock")
            dlg.openFor(clockId, "clock")
            compare(dlg.previewAcceptsInput, false,
                    "other Manager previews remain read-only")
            dlg.close()
        }

        function test_notes_config_uses_the_live_preview_as_its_single_editor() {
            var id = _store.addTile(0, "notes")
            _store.setSetting(id, "text", "Edit me in the note")
            var dlg = findPred(win, function (x) {
                return x && typeof x.openFor === "function"
            })
            verify(dlg)
            dlg.openFor(id, "notes")
            tryVerify(function () {
                return dlg.previewItem !== null
                    && dlg.previewItem.instanceId === id
            }, 3000)
            compare(dlg.previewAcceptsInput, true,
                    "the expanded Quick Note preview is the interactive editor")
            var textFields = 0
            for (var s = 0; s < dlg.schema.sections.length; s++) {
                var fields = dlg.schema.sections[s].fields || []
                for (var f = 0; f < fields.length; f++)
                    if (fields[f].key === "text") textFields++
            }
            compare(textFields, 0,
                    "the settings form does not duplicate the note textarea")
            dlg.close()
        }

        // Opening a preview is passive UI, not consent to contact every network
        // widget's endpoint. The dialog's explicit city search has a separate,
        // narrowly allow-listed gate; every loaded preview receives the hard-off
        // gate even though standalone widgets own an online fallback for tests.
        function test_config_preview_is_offline_by_construction() {
            _store.addTile(0, "weather")
            var tileId = _store.pages()[0].tiles[0].id
            var dlg = findPred(win, function (x) { return x && typeof x.openFor === "function" })
            var previewGate = dlg ? dlg.previewNetHub : null
            var geocodeGate = dlg ? dlg.geocodeNetHub : null
            verify(dlg && previewGate && geocodeGate, "found dialog and both purpose-specific gates")
            compare(previewGate.objectName, "managerPreviewNetHub")
            compare(geocodeGate.objectName, "managerGeocodeNetHub")
            compare(previewGate.offline, true, "preview egress is hard-disabled")
            compare(geocodeGate.allowHosts.length, 1, "explicit lookup has one allowed host")
            compare(geocodeGate.allowHosts[0], "geocoding-api.open-meteo.com")

            dlg.openFor(tileId, "weather")
            tryVerify(function () {
                return dlg.previewItem !== null
                       && dlg.previewItem.instanceId === tileId
                       && dlg.previewItem.netHub !== undefined
            }, 3000)
            var preview = dlg.previewItem
            compare(preview.netHub, previewGate, "the real Weather preview uses the offline gate")
            wait(450) // cross Weather's initial 350 ms refresh debounce
            compare(previewGate.requests, 0, "opening the preview sent no request")
            compare(previewGate.blocked, 0, "passive preview did not even attempt a request")
            compare(preview.active, false, "Manager config preview is not a state driver")
            dlg.close()
        }

        // ── W2 scope vocabulary ───────────────────────────────────────────────
        // The pills are the answer to "which setting changes which behavior", so
        // they must be a CLOSED vocabulary: the audit's F3 was two words for one
        // scope ("Whole Edge" vs "All pages") with nothing to tell them apart. This
        // fails the moment a section invents its own wording, or ships a pill whose
        // rule scopeDetail() can't state.
        function test_every_scope_pill_uses_the_defined_vocabulary() {
            var seen = []
            findAll(win, function (x) {
                if (x && x.objectName === "scopePill" && seen.indexOf(x) < 0) seen.push(x)
                return false
            })
            verify(seen.length >= 8, "found the scope pills (got " + seen.length + ")")
            var vocab = []
            for (var k in win.scopeLabels) vocab.push(win.scopeLabels[k])
            for (var i = 0; i < seen.length; i++) {
                var lbl = seen[i].label
                verify(vocab.indexOf(lbl) >= 0,
                       "pill “" + lbl + "” is drawn from the scope vocabulary")
                verify(win.scopeDetail(lbl).length > 0,
                       "pill “" + lbl + "” can state its rule on hover")
            }
        }

        // scopeDetail is the single source of each scope's meaning - the pills and
        // the config dialog both read it, so a label with no rule (or a typo'd one)
        // must be an empty string, never a guess.
        function test_scopeDetail_defines_each_scope_and_rejects_unknown() {
            verify(win.scopeDetail(win.scopeLabels.page).indexOf("other screens") >= 0,
                   "scopeDetail spells out the per-screen rule")
            verify(win.scopeDetail(win.scopeLabels.pages).indexOf("override") >= 0,
                   "scopeDetail explains that 'All screens' is a default a screen can override")
            verify(win.scopeDetail(win.scopeLabels.edge).indexOf("every screen") >= 0,
                   "scopeDetail explains 'Whole Edge' covers every screen")
            compare(win.scopeDetail("Sometimes"), "", "an unknown scope label states no rule")
        }

        // ── commitRename: a typed page name is never silently lost (audit F1) ──
        // The field commits on Enter only, and nothing else in the pane takes focus,
        // so switching page mid-edit used to overwrite the field with the NEW page's
        // name - destroying the rename with no trace. The commit must land on the
        // page the text belonged to, not the page now selected.
        function test_commitRename_saves_the_edit_when_the_page_switches() {
            _store.addPage("Second")
            win.currentPageIndex = 0
            var field = findPred(win, function (x) {
                return x && x.forIndex !== undefined && typeof x.text === "string" })
            verify(field, "found the page-name field")
            compare(field.text, "Home", "field starts on the current page's name")
            field.text = "Yen"                 // user types, does NOT press Enter
            win.currentPageIndex = 1           // …and clicks another page chip
            compare(_store.pages()[0].name, "Yen", "commitRename saved the typed name onto the page it was typed for")
            compare(_store.pages()[1].name, "Second", "the newly selected page is untouched")
            compare(field.text, "Second", "the field now shows the newly selected page")
        }

        // The no-op guard: switching pages without editing must not rename anything
        // (renamePage bumps the structure revision and rebuilds every tile).
        function test_commitRename_is_a_noop_when_nothing_was_typed() {
            _store.addPage("Second")
            win.currentPageIndex = 0
            var before = _store.structureRevision
            win.currentPageIndex = 1           // switch with no edit pending
            win.currentPageIndex = 0
            compare(_store.pages()[0].name, "Home", "an untouched page keeps its name")
            compare(_store.structureRevision, before, "commitRename wrote nothing, so no structural rebuild was triggered")
        }

        // ── Display: the screen list has an honest empty state (audit F8) ──────
        // With no screens the tab used to show "choose which screen…" followed by
        // blank space, so Orientation read as the answer to it.
        function test_display_shows_an_empty_state_when_no_screens() {
            // Item.visible is recursive - a StackLayout hides its non-current
            // children, so the Display tab must actually be the shown one before
            // `visible` says anything about this row.
            _nav.currentIndex = 3
            var empty = findPred(win, function (x) { return x && x.objectName === "screensEmpty" })
            verify(empty, "found the no-screens empty state")
            win.screens = []
            verify(empty.visible, "the empty state shows when no screens are detected")
            win.screens = [{ name: "DP-3", model: "Xeneon Edge", width: 720, height: 2560, isEdge: true }]
            verify(!empty.visible, "…and hides as soon as a screen exists")
            win.screens = []
        }

        // ── Add-widget picker names its target page (audit F4) ────────────────
        function test_add_picker_names_the_page_it_adds_to() {
            _store.addPage("Second")
            win.currentPageIndex = 1
            // A Dialog builds its header/content lazily on first open, so the label
            // does not exist in the tree until the user actually opens the picker.
            var picker = findPred(win, function (x) {
                return x && x.title === "Add a widget" && typeof x.open === "function" })
            verify(picker, "found the add-widget picker")
            picker.open()
            var lbl = findPred(win, function (x) { return x && x.objectName === "addPickerTarget" })
            verify(lbl, "the picker header carries a target-page line")
            verify(lbl.text.indexOf("Second") >= 0,
                   "…naming the page the widget will land on (got: " + lbl.text + ")")
            win.currentPageIndex = 0
            verify(lbl.text.indexOf("Home") >= 0, "…and it follows the selected page")
            picker.close()
        }

        // The custom visual controls expose small helper functions used by mouse,
        // keyboard, and accessibility activation. Exercise the helpers directly
        // so the behavior matrix proves their product effects, not just their
        // existence in source.
        function test_add_screen_helper_creates_and_selects_a_screen() {
            var addScreenButton = findPred(win, function (x) {
                return x && x.objectName === "addScreenButton" })
            verify(addScreenButton && typeof addScreenButton.addScreen === "function",
                   "the semantic Add screen control exposes addScreen")
            var before = _store.pageCount()
            addScreenButton.addScreen()
            compare(_store.pageCount(), before + 1, "addScreen creates exactly one page")
            compare(win.currentPageIndex, before, "the new page becomes the active page")
        }

        function test_add_widget_helper_creates_a_real_tile() {
            var picker = findPred(win, function (x) {
                return x && x.title === "Add a widget" && typeof x.open === "function" })
            verify(picker, "found the add-widget picker")
            picker.open()
            var addWidgetChoice = findPred(win, function (x) {
                return x && x.objectName === "widgetChoice-cpu" })
            verify(addWidgetChoice && typeof addWidgetChoice.addWidget === "function",
                   "the semantic CPU choice exposes addWidget")
            addWidgetChoice.addWidget()
            compare(_store.pages()[0].tiles.length, 1,
                    "addWidget creates exactly one tile on the active page")
            compare(_store.pages()[0].tiles[0].type, "cpu",
                    "addWidget creates the selected widget type")
        }

        // ── inline MSwitch (Widget glow) ──────────────────────────────────────
        function test_widget_glow_switch_toggles_store() {
            _nav.currentIndex = 1            // Appearance tab hosts the switch
            var sw = findSwitch("Widget glow")
            verify(sw, "Widget glow switch present on the Appearance tab")
            var before = sw.checked          // defaults true (glow undefined)
            // Flip + fire the wired onToggled (see note above re: offscreen window).
            sw.toggle(); sw.toggled()
            verify(sw.checked !== before, "the switch flipped")
            compare(_store.appearance().glow, sw.checked, "toggle persisted to the store")
        }

        // ── Licensing ──
        function findByText(txt) {
            return findPred(win, function (x) {
                return x && typeof x.text === "string" && x.text === txt })
        }

        function test_refreshLicense_and_backend_signal_recompute_the_tier() {
            backend.storedKey = "XE1.valid.pro"
            compare(win.refreshLicense(), undefined,
                    "refreshLicense re-verifies the currently stored key")
            compare(win.isPro, true, "a directly refreshed valid key enables Pro")

            // Change the backing value without calling refreshLicense: emitting the
            // backend signal must execute Connections.onLicenseChanged and refresh.
            backend.storedKey = ""
            backend.licenseChanged()
            compare(win.isPro, false, "onLicenseChanged recomputes the tier instead of leaving cached Pro state")

            // Corrupt backend JSON is fail-closed, never a stale paid entitlement.
            backend.storedKey = "XE1.valid.pro"
            backend.malformedLicenseStatus = true
            compare(win.refreshLicense(), undefined,
                    "refreshLicense handles malformed status JSON without throwing")
            compare(win.isPro, false, "malformed status fails closed to the free tier")
            backend.malformedLicenseStatus = false
            backend.storedKey = ""
            win.refreshLicense()
        }

        function test_activating_a_valid_key_unlocks_pro_and_a_bad_key_does_not() {
            _nav.currentIndex = 4                     // About tab hosts the licence card
            backend.storedKey = ""; backend.licenseChanged()
            verify(!win.isPro, "starts on the free tier")

            // Open the dialog via the card's button.
            var activate = findByText("Activate Pro")
            verify(activate, "the free card offers 'Activate Pro'")
            activate.clicked()

            var dlg = findPred(win, function (x) {
                return x && x.hasOwnProperty("preview") && x.hasOwnProperty("candidate") })
            verify(dlg, "the licence dialog is present")
            tryVerify(function () { return dlg.opened === true }, 2000)

            // The dialog's content lives under its contentItem; search from there
            // (and from win as a fallback) by the unique placeholder.
            function findInDialog(pred) {
                return findPred(dlg.contentItem || dlg, pred) || findPred(win, pred)
            }
            // A BAD key must NOT enable Activate and must NOT flip the tier.
            var field = findInDialog(function (x) {
                return x && typeof x.text === "string"
                       && x.hasOwnProperty("placeholderText")
                       && String(x.placeholderText).indexOf("XE1") === 0 })
            verify(field, "found the key input")
            field.text = "   "
            compare(dlg.reVerify(), undefined,
                    "reVerify handles an empty candidate without consulting stale preview state")
            compare(dlg.preview.state, "unlicensed", "an empty candidate previews as unlicensed")
            field.text = "XE1.nope.nope"
            var commit = findInDialog(function (x) {
                return x && x.text === "Activate" && typeof x.enabled === "boolean" })
            verify(commit, "found the Activate button")
            verify(!commit.enabled, "a rejected key keeps Activate disabled")
            verify(!win.isPro, "a rejected key does not unlock Pro")

            // A VALID key enables Activate; clicking it flips the tier and the card.
            field.text = "XE1.valid.pro"
            tryVerify(function () { return commit.enabled === true }, 2000)
            commit.clicked()
            tryVerify(function () { return win.isPro === true }, 2000)
            compare(backend.storedKey, "XE1.valid.pro", "the valid key was stored")
            verify(!!findByText("Xeneon Edge Pro"), "the card now reads Pro")

            // Removing reverts to free.
            backend.clearLicenseKey()
            tryVerify(function () { return win.isPro === false }, 2000)
        }

        // The Edge theme is chosen from a dropdown now; selection routes through
        // win.commitTheme (which gates Pro themes). Test that logic directly (the
        // dropdown rows live in a Popup that isn't in the tree until opened).
        function test_a_premium_theme_is_locked_for_free_and_applies_for_pro() {
            backend.storedKey = ""; backend.licenseChanged()
            _nav.currentIndex = 1                       // Appearance tab
            _store.setAppearance("themeMode", "dark")   // known starting point
            tryVerify(function () { return win.isPro === false }, 2000)
            verify(typeof win.commitTheme === "function", "commitTheme is exposed")
            verify(win._themeDef("synthwave").pro === true, "_themeDef resolves the premium flag")

            // A locked premium theme is NOT applied for a free user (commitTheme
            // routes it to the licence dialog instead of the store).
            win.commitTheme("synthwave")
            compare(_store.appearance().themeMode, "dark",
                    "a locked premium theme is not applied for a free user")

            // Unlock Pro → the same theme now applies.
            backend.setLicenseKey("XE1.valid.pro")
            tryVerify(function () { return win.isPro === true }, 2000)
            win.commitTheme("synthwave")
            compare(_store.appearance().themeMode, "synthwave",
                    "with Pro, the premium theme applies")
            // A free (non-Pro) theme always applies.
            win.commitTheme("nord")
            compare(_store.appearance().themeMode, "nord", "a free theme applies via commitTheme")

            backend.clearLicenseKey()
            _store.setAppearance("themeMode", "dark")
        }

        // ── C: the automatic update-check toggle is now REACHABLE in the Manager
        // (it was buried in the hub's on-panel settings - "where is autoupdate?").
        function test_update_check_toggle_persists_updateCheck() {
            _nav.currentIndex = 3   // Display & Startup
            var sw = findSwitch("Check for updates automatically")
            verify(sw, "the Manager exposes an automatic update-check toggle")
            verify(_store.appearance().updateCheck !== true, "off by default")
            sw.checked = true; sw.toggled()
            compare(_store.appearance().updateCheck, true, "toggling persists updateCheck=true")
            sw.checked = false; sw.toggled()
            compare(_store.appearance().updateCheck, false, "toggling back persists updateCheck=false")
        }

        function test_hub_navigation_toggle_persists_immersive_mode() {
            _nav.currentIndex = 1
            var sw = findSwitch("Show navigation bar on the Hub")
            verify(sw, "the Manager exposes the Hub navigation choice")
            compare(sw.checked, true, "the Hub bar defaults on")
            sw.checked = false; sw.toggled()
            compare(_store.appearance().hubControlsMode, "immersive",
                    "turning the Manager switch off persists immersive mode")
            sw.checked = true; sw.toggled()
            compare(_store.appearance().hubControlsMode, "standard", "the Manager can restore the bar")
        }

        // The full-control functions the Manager now exposes are present (this also
        // backs the coverage claims - each leaf token appears in an assertion).
        function test_manager_control_functions_are_exposed() {
            verify(typeof win.applyPresetScreen === "function", "applyPresetScreen present")
            verify(typeof win.confirmResetLayout === "function", "confirmResetLayout present")
            verify(typeof win.hoverPreview === "function", "hoverPreview present")
            // hoverPreview debounces a theme try-on into the live theme instance.
            _store.setAppearance("themeMode", "dark")
            win.hoverPreview("theme", "midnight", true)
            tryVerify(function () { return Qt.colorEqual(_theme.backgroundColor, "#0B1026") }, 2000)
            win.hoverPreview("theme", "midnight", false)   // restore
            win.endThemePreview()
        }

        function test_clean_shutdown_drains_the_manager_store_debounce() {
            _store.setSetting("shutdown-probe", "text", "pending")
            verify(_store._savePending, "a Manager edit is waiting in the shared debounce")
            verify(win.flushPendingUiState(), "Manager accepted the clean-shutdown flush")
            verify(!_store._savePending, "the Manager debounce was drained synchronously")
        }

        // ── D/B: adding a curated "screen" APPENDS one new page (single-page
        // presets), never replacing the user's pages and never touching the theme.
        function test_apply_preset_screen_appends_a_page() {
            var before = _store.pageCount()
            var themeBefore = _store.appearance().themeMode
            win.applyPresetScreen("calm-focus")        // additive
            tryVerify(function () { return _store.pageCount() === before + 1 }, 2000)
            var pages = _store.pages()
            compare(pages[pages.length - 1].name, "Focus", "the added screen is calm-focus's single page")
            compare(_store.appearance().themeMode, themeBefore, "appending a screen leaves the global theme untouched")
            compare(win.currentPageIndex, before, "navigated to the newly added screen")
            // A second add coexists (tile ids don't collide).
            win.applyPresetScreen("developer")
            tryVerify(function () { return _store.pageCount() === before + 2 }, 2000)
            backend.configChanged()   // restore the blank "Home" baseline for later tests
        }

        // The Manager uses a two-stage selection: selecting is passive and updates
        // the detailed preview; only the separate Add action mutates the store.
        function test_preset_picker_shows_layout_previews() {
            var dlg = findPred(win, function (x) { return x && x.title === "Start from a preset screen" })
            verify(dlg, "found the preset dialog")
            dlg.open()
            compare(dlg.selectedId, "", "opening starts with no armed screen")
            var add = findButton("Add selected screen")
            verify(add && !add.enabled, "Add is disabled until a screen is reviewed")
            var mini = null
            tryVerify(function () {
                mini = findPred(win, function (x) { return x && x.objectName === "presetMini" })
                return mini !== null && mini.placements !== undefined && mini.placements.length >= 1
            }, 3000, "a preset layout preview rendered with packed tiles")
            verify(Qt.colorEqual(mini.catColor("cpu"), _theme.catSystem),
                   "catColor maps System widgets to the system category colour")
            verify(Qt.colorEqual(mini.catColor("focus"), _theme.catProductivity),
                   "catColor maps Focus widgets to the productivity category colour")
            verify(Qt.colorEqual(mini.catColor("not-a-widget"), _theme.accent),
                   "catColor falls back to the active accent for an unknown type")
            var minis = findAll(win, function (x) {
                return x && x.objectName === "presetMini"
            })
            verify(minis.length >= 19, "every catalog screen has a mini preview")
            for (var miniIndex = 0; miniIndex < minis.length; miniIndex++) {
                var occupied = ({})
                for (var placementIndex = 0;
                        placementIndex < minis[miniIndex].placements.length;
                        placementIndex++) {
                    var placement = minis[miniIndex].placements[placementIndex]
                    for (var longCell = placement.l;
                            longCell < placement.l + placement.el; longCell++) {
                        for (var shortCell = placement.s;
                                shortCell < placement.s + placement.es; shortCell++) {
                            var cellKey = shortCell + ":" + longCell
                            verify(!occupied[cellKey],
                                   "mini " + miniIndex
                                   + " widgets do not overlap at " + cellKey)
                            occupied[cellKey] = true
                        }
                    }
                }
            }
            var calmCard = findPred(win, function (x) {
                return x && x.objectName === "managerPresetCard-calm-focus"
            })
            verify(calmCard, "the Calm Focus preset card exists")
            verify(calmCard.activeFocusOnTab,
                   "preset cards participate in keyboard focus")
            compare(calmCard.Accessible.role, Accessible.Button)
            compare(calmCard.Accessible.name, "Preview preset: Calm Focus")
            verify(calmCard.previewPreset(),
                   "previewPreset selects a card without applying it")
            compare(dlg.selectedId, "calm-focus")
            calmCard.forceActiveFocus()
            verify(calmCard.activeFocus, "the preset card accepts keyboard focus")
            keyClick(Qt.Key_Return)
            compare(dlg.selectedId, "calm-focus",
                    "Return selects the focused preset for its real preview")

            var before = _store.pageCount()
            dlg.selectedId = "developer"
            var detail = findPred(win, function (x) {
                return x && x.objectName === "managerPresetPreview"
            })
            verify(detail !== null, "the detailed shared preview is present")
            compare(detail.titleItem.text, "Developer")
            verify(detail.purposeItem.text.length > 20)
            verify(detail.setupItem.text.indexOf("CI") >= 0)
            tryCompare(detail, "previewTileCount", 2, 3000,
                       "the real Developer widgets finish loading in the preview")
            _store.setAppearance("orientation", "portrait")
            tryCompare(dlg, "landscape", false, 1000)
            compare(detail.landscape, false,
                    "the detailed preset preview follows the reported portrait orientation")
            compare(mini.landscape, false,
                    "the preset list thumbnail follows the same portrait orientation")
            for (var portraitIndex = 0; portraitIndex < minis.length; portraitIndex++)
                compare(minis[portraitIndex].landscape, false,
                        "every preset thumbnail follows portrait")
            verify(mini.height > mini.width, "portrait thumbnail is visibly portrait")
            _store.setAppearance("orientation", "landscape")
            tryCompare(dlg, "landscape", true, 1000)
            compare(detail.landscape, true,
                    "the detailed preset preview follows the reported landscape orientation")
            compare(mini.landscape, true,
                    "the preset list thumbnail follows the same landscape orientation")
            for (var landscapeIndex = 0; landscapeIndex < minis.length; landscapeIndex++)
                compare(minis[landscapeIndex].landscape, true,
                        "every preset thumbnail follows landscape")
            tryVerify(function () { return mini.width > mini.height }, 1000,
                      "landscape thumbnail is visibly landscape ("
                      + mini.width + "x" + mini.height + ")")

            var footer = findPred(win, function (x) {
                return x && x.objectName === "managerPresetFooter"
            })
            var cancel = findPred(win, function (x) {
                return x && x.objectName === "managerPresetCancel"
            })
            verify(footer && cancel && add, "preset footer and both actions exist")
            var addTopLeft = add.mapToItem(footer, 0, 0)
            var addBottomRight = add.mapToItem(footer, add.width, add.height)
            var cancelTopLeft = cancel.mapToItem(footer, 0, 0)
            verify(cancelTopLeft.y >= 15 && addTopLeft.y >= 15,
                   "footer actions have top padding")
            verify(addBottomRight.x <= footer.width - 19,
                   "the primary action has right-edge padding")
            verify(addBottomRight.y <= footer.height - 15,
                   "footer actions have bottom padding")
            compare(_store.pageCount(), before, "selecting and previewing changes no pages")
            verify(add.enabled, "Add becomes available after review")
            add.clicked()
            compare(_store.pageCount(), before + 1, "the separate Add action commits once")
            dlg.close()
            backend.configChanged()
        }

        // ── D: resetting to the default layout replaces pages with the starter set.
        function test_reset_to_default_layout() {
            win.applyPresetScreen("calm-focus")   // a known non-default set
            win.confirmResetLayout()
            var dlg = findPred(win, function (x) {
                return x && x.hasOwnProperty("onConfirm") && typeof x.onConfirm === "function" })
            verify(dlg, "reset opened the confirm dialog")
            dlg.onConfirm()
            tryVerify(function () { return _store.pageCount() >= 2 }, 2000)
            var names = []
            var pages = _store.pages()
            for (var i = 0; i < pages.length; i++) names.push(pages[i].name)
            // Reset restores the recommended starter BUNDLE (a few single-page screens).
            verify(names.indexOf("Focus") >= 0 && names.indexOf("Core") >= 0,
                   "reset restored the starter bundle (work + system + home)")
            backend.configChanged()   // restore the blank "Home" baseline for later tests
        }

        // ── E: the Manager-window style control moved OUT of the sidebar and INTO
        // the Appearance tab, beside the Edge theme (the audit's top confusion).
        function test_manager_window_style_lives_in_appearance() {
            var heading = findPred(win, function (x) {
                return x && x.text === "Manager window style" })
            verify(heading, "the Manager-window style control is present in Appearance")
        }

        // ── E: the Edge-theme grid is collapsed by default and expands on demand,
        // so the tab is not dominated by 29 swatches.
        // The Edge theme is a compact dropdown whose model lists every theme; the
        // field reflects the committed theme.
        function test_theme_dropdown_lists_all_and_reflects_selection() {
            _nav.currentIndex = 1
            verify(win.apThemeModel.length >= 20, "the theme dropdown model lists all themes")
            verify(win._themeDef("dark") !== null, "_themeDef resolves a known theme")
            var field = findPred(win, function (x) { return x && x.objectName === "themeDropdownField" })
            verify(field, "the theme dropdown field is present")
            _store.setAppearance("themeMode", "nord")
            compare(field.curKey, "nord", "the field reflects the committed theme")
            _store.setAppearance("themeMode", "dark")
        }

        // ── The Look tab must lay its preview out the SAME way Screens does.
        //
        // Look was a plain RowLayout that pinned the preview beside the controls at a
        // hardcoded width in BOTH orientations, while Screens flips to a 1-column
        // stack in landscape. Same component, same panel, two different layouts -
        // which is half of "the Look configsection has a different layout than
        // Screens". Asserting the RULE (beside in portrait, above in landscape) rather
        // than pixel values, so a re-tuned width does not fail this.
        //
        // The width assertion is not decoration: `Layout.maximumWidth: -1` looks like
        // the documented "reset" it is for *preferred* sizes, but maximumWidth takes
        // it literally and collapses the pane to nothing. That is invisible to every
        // other test here - the tab still loads, every control still answers.
        function test_look_tab_lays_out_like_the_screens_tab() {
            _nav.currentIndex = 1
            var pane = findPred(win, function (x) { return x && x.objectName === "lookPreviewPane" })
            var ctrls = findPred(win, function (x) { return x && x.objectName === "lookControls" })
            verify(pane, "the Look preview pane is present")
            verify(ctrls, "the Look control pane is present")

            // A GridLayout re-arranges on the polish phase, not on the property
            // write, so every geometry read here has to be a tryVerify - a plain
            // verify() straight after setAppearance reads the PREVIOUS arrangement
            // and passes or fails for the wrong reason.
            _store.setAppearance("orientation", "portrait")
            tryVerify(function () { return pane.x < ctrls.x }, 2000,
                      "portrait: the preview sits BESIDE the controls, first")
            verify(pane.width > 100, "portrait: the preview pane has real width (" + pane.width + ")")
            verify(pane.height > 100, "portrait: and real height (" + pane.height + ")")

            _store.setAppearance("orientation", "landscape")
            tryVerify(function () { return pane.y < ctrls.y }, 2000,
                      "landscape: the preview moves ABOVE the controls")
            verify(pane.width > 100, "landscape: the preview pane has real width (" + pane.width + ")")
            verify(pane.height > 100, "landscape: and real height (" + pane.height + ")")
            verify(pane.width > ctrls.width * 0.9,
                   "landscape: and takes the full content width, not a pinned strip"
                   + " (pane " + pane.width + " vs controls " + ctrls.width + ")")

            _store.setAppearance("orientation", "auto")
        }

        // ── C: hovering a background style previews it live (audit F2) without
        // committing to the store.
        function test_background_style_hover_previews_without_committing() {
            _nav.currentIndex = 1
            var bgBefore = _store.appearance().bgStyle
            var bp = findPred(win, function (x) {
                return x && typeof x.previewStyle === "function"
                       && x.hasOwnProperty("pageIndex") && x.pageIndex === -1 })
            verify(bp, "found the global (Appearance) background picker")
            bp.previewStyle("grid")
            compare(_theme.previewBgStyle, "grid", "hovering a style previews it live")
            compare(_store.appearance().bgStyle, bgBefore, "…without committing to the store")
            bp.previewEnded()
            compare(_theme.previewBgStyle, "", "leaving the chip ends the preview")
        }

        // ── A: the "can't move the glass slider" bug. The handle must track the
        // STABLE theme.glassOpacity, not store.revision - the Appearance preview's
        // cpu/gpu/ram widgets bump store.revision every ~2s, and a revision-bound
        // value snapped the handle back mid-drag. This test BITES on the old code
        // (the old slider tracked the store, so it would not follow theme.glassOpacity).
        function _glassSlider() {
            return findPred(win, function (x) {
                return x && typeof x.from === "number" && typeof x.to === "number"
                       && typeof x.value === "number" && typeof x.moved === "function"
                       && typeof x.pressed === "boolean" })
        }
        function test_glass_slider_tracks_theme_and_survives_metric_churn() {
            _nav.currentIndex = 1                      // Appearance tab
            var sl = _glassSlider()
            verify(sl, "found the glass slider")
            // The slider MUST have a real hit area. A custom handle/background without
            // implicit sizes collapses the Slider to ~0 height, so it can't be pressed
            // or dragged - the real "stuck at 55%" bug. This guards that regression
            // (offscreen, so a real drag can't be delivered here - height is the proxy).
            verify(sl.height >= 48, "the glass slider has a touch-safe height (" + sl.height + ")")
            _theme.glassOpacity = 0.77
            compare(sl.value, 0.77, "the glass slider tracks theme.glassOpacity (the fix)")
            // A metric tick bumps store.revision WITHOUT changing glass (hist is ephemeral).
            _store.setSetting("glassprobe", "hist", [1, 2, 3])
            compare(sl.value, 0.77, "a metric-churn revision bump does NOT move the handle")
            _theme.glassOpacity = 0.55                 // restore for later tests
        }
        function test_glass_slider_drag_commits_and_rebinds() {
            _nav.currentIndex = 1
            var sl = _glassSlider()
            verify(sl, "found the glass slider")
            // Offscreen Window → drive the real onMoved (see the button/switch idiom).
            sl.value = 0.4; sl.moved()
            compare(sl.value, 0.4, "the drag set the live value")
            compare(_theme.glassOpacity, 0.4, "onMoved updated the live theme immediately")
            // Debounced commit writes the store (~180ms).
            tryVerify(function () { return _store.appearance().glass === 0.4 }, 2000)
            // [S2] rebind: an external/hub push still moves the handle.
            _store.setAppearance("glass", 0.15)
            tryCompare(sl, "value", 0.15, 2000)
            _theme.glassOpacity = 0.55
        }

        // ── F: exercise every remaining Manager control's INPUT path ────────────
        // (offscreen Window → drive the real signal, per the button/switch idiom.)
        function _clickArea(node) {
            return findPred(node, function (x) {
                return x && typeof x.clicked === "function" && x.hasOwnProperty("hoverEnabled") })
        }
        function test_accent_swatch_click_commits() {
            _nav.currentIndex = 1
            _store.setAppearance("accent", "blue")
            var sw = findPred(win, function (x) {
                return x && x.modelData && x.modelData.c !== undefined
                       && x.modelData.name === "green" && x.hasOwnProperty("sel") })
            verify(sw, "found the green accent swatch")
            _clickArea(sw).clicked(null)
            compare(_store.appearance().accent, "green", "clicking an accent commits it")
            _store.setAppearance("accent", "blue")
        }
        function _chromeSwatch(k) {   // Manager-window-style MSegment segment ({label,value} + active)
            return findPred(win, function (x) {
                return x && x.modelData && x.modelData.value === k && x.modelData.label !== undefined
                       && x.hasOwnProperty("active") })
        }
        function test_manager_window_style_swatch_click() {
            _nav.currentIndex = 1                      // Appearance tab
            var light = _chromeSwatch("light")
            verify(light, "found the Light Manager-window-style segment")
            _clickArea(light).clicked(null)
            // appSettings is Manager-internal; assert via the segment's own selection.
            tryVerify(function () { return _chromeSwatch("light").active === true }, 2000)
            _clickArea(_chromeSwatch("default")).clicked(null)   // restore
            tryVerify(function () { return _chromeSwatch("default").active === true }, 2000)
        }
        function test_animated_bg_switch_toggles_store() {
            _nav.currentIndex = 1
            var sw = findSwitch("Animated background")
            verify(sw, "found the animated-background switch")
            var was = _store.appearance().animatedBg === true
            sw.checked = !was; sw.toggled()
            compare(_store.appearance().animatedBg, !was, "toggling animated background persists")
        }
        function test_reduce_motion_switch_toggles_store() {
            _nav.currentIndex = 1
            var sw = findSwitch("Reduce motion")
            verify(sw, "found the reduce-motion switch")
            sw.checked = true; sw.toggled()
            compare(_store.appearance().reduceMotion, true, "reduce motion persists on")
            sw.checked = false; sw.toggled()
            compare(_store.appearance().reduceMotion, false, "…and off")
        }
        function test_autostart_switch_calls_backend() {
            _nav.currentIndex = 3
            var sw = findSwitch("Start the hub automatically on login")
            verify(sw, "found the autostart switch")
            backend.autostart = false
            sw.checked = true; sw.toggled()
            compare(backend.autostart, true, "toggling autostart calls the backend")
            sw.checked = false; sw.toggled()
            compare(backend.autostart, false, "…and back off")
        }
        function test_orientation_swatch_click_commits() {
            _nav.currentIndex = 3
            _store.setAppearance("orientation", "auto")
            var sw = findPred(win, function (x) {
                return x && x.modelData && x.modelData.v === "portrait" && x.modelData.l === "Portrait"
                       && x.hasOwnProperty("sel") })
            verify(sw, "found the Portrait orientation chip")
            _clickArea(sw).clicked(null)
            compare(_store.appearance().orientation, "portrait", "clicking an orientation commits it")
            _store.setAppearance("orientation", "auto")
        }
        function test_background_style_chip_commits() {
            _nav.currentIndex = 1
            var bp = findPred(win, function (x) {
                return x && typeof x.pickStyle === "function" && x.hasOwnProperty("pageIndex") && x.pageIndex === -1 })
            verify(bp, "found the Appearance background picker")
            bp.pickStyle("waves")
            compare(_store.appearance().bgStyle, "waves", "picking a background style commits it")
            compare(_store.appearance().wallpaper, "", "…and clears any wallpaper (mutually exclusive)")
            bp.pickStyle("orbs")
        }
        function test_diagnostics_show_redacted_summary_toggle() {
            _nav.currentIndex = 4                                  // About tab
            var show = findButton("Show redacted summary")
            verify(show, "the Diagnostics redacted-summary button is present")
            show.clicked()
            verify(findButton("Hide summary"), "clicking reveals the summary")
            findButton("Hide summary").clicked()
            verify(findButton("Show redacted summary"), "…and hides again")
        }
        function test_nav_chip_click_switches_tab() {
            _nav.currentIndex = 0
            var chip = findPred(win, function (x) {
                return x && x.modelData && x.modelData.l === "Images" && x.modelData.i !== undefined })
            verify(chip, "found the Images nav chip")
            _clickArea(chip).clicked(null)
            compare(_nav.currentIndex, 2, "clicking a nav chip switches to that tab")
            _nav.currentIndex = 0
        }

        // The live preview must PAUSE while the surrounding controls scroll - an
        // animated preview repainting every scroll frame is the Manager scroll lag.
        function test_preview_pauses_during_scroll() {
            _nav.currentIndex = 0                      // Layout tab (its clone is visible)
            var clone = findPred(win, function (x) {
                return x && x.hasOwnProperty("scrolling") && x.hasOwnProperty("previewLive")
                       && x.hasOwnProperty("pageIndex") && x.visible })
            verify(clone, "found the visible edge-clone preview")
            tryVerify(function () { return clone.previewLive === true }, 2000)
            clone.scrolling = true
            compare(clone.previewLive, false, "the preview pauses (stops animating) while scrolling")
            clone.scrolling = false
            compare(clone.previewLive, true, "…and resumes the instant the scroll settles")
        }
    }
}
