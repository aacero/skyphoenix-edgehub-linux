import QtQuick
import QtTest

// COVERS: fn:main.bindStackItem, fn:main.flushPendingUiState, fn:main.onContentRotationChanged,
//         fn:main.onDisplayDisconnectedChanged,
//         fn:main.onDisplaySelectionRequestedChanged
//
// ui/qml/main.qml - bindStackItem (binds/rebinds cleanly, skips null +
// items without the shell properties) and the readonly `contentRotation`
// mapping for every orientation mode (portrait 0 / landscape 90 /
// inverted-portrait 180 / inverted-landscape 270 / auto-follows-sensor), plus
// the contentRoot width/height swap for the 90°/270° landscape aspect.
//
// main.qml is an ApplicationWindow that reads a set of `_`-prefixed context
// properties injected by the C++ shell. We declare them on this wrapper so the
// window resolves them through the context scope (exactly as the widget harness
// feeds `theme`/`store` to widgets), then instantiate the REAL main.qml. Its
// initialItem is a qrc: URL that isn't registered under qmltestrunner, so the
// StackView starts empty - irrelevant here: we drive bindStackItem with our own
// stub item and assert the rotation binding directly (props, never pixels).
Item {
    id: root
    width: 200; height: 200

    // Shell-provided context properties (mirror main.qml's `property x: _x`).
    property bool _isFirstRun: false
    property string _screens: "[]"
    property string _metricsJson: "{}"
    property string _themeMode: "dark"
    property string _targetEdidHash: ""
    property string _targetConnector: ""
    property string _targetModel: ""
    property string _configDir: "/tmp"
    property bool _safeMode: false
    property bool _startInDiagnostics: false
    property bool _windowedMode: true
    property int _targetScreenX: 0
    property int _targetScreenY: 0
    property int _targetScreenWidth: 1920
    property int _targetScreenHeight: 1080

    // A stand-in for a StackView page that declares the shell-bound properties.
    Component {
        id: pageStub
        QtObject {
            property string metricsJson: ""
            property string screensData: ""
            property string configJson: ""
        }
    }
    // A page that declares NONE of them (bindStackItem must leave it untouched).
    Component {
        id: barePage
        QtObject { property int marker: 7 }
    }

    property var win: null

    // ── tree helpers ─────────────────────────────────────────────────────────
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

    TestCase {
        name: "Main"
        when: windowShown

        function initTestCase() {
            var c = Qt.createComponent("../../ui/qml/main.qml")
            tryVerify(function () { return c.status !== Component.Loading }, 5000)
            compare(c.status, Component.Ready, "main.qml compiles: " + c.errorString())
            win = c.createObject(root)
            verify(win !== null, "main.qml instantiated")
        }
        function cleanupTestCase() { if (win) win.destroy() }

        // ── bindStackItem ─────────────────────────────────────────────────────
        function test_bindStackItem_binds_live_shell() {
            root._metricsJson = "{\"cpu\":1}"
            root._screens = "[{\"n\":1}]"
            var pg = pageStub.createObject(root)
            win.bindStackItem(pg)
            compare(pg.metricsJson, win.metricsJson, "bindStackItem bound the page's metricsJson to the window")
            compare(pg.metricsJson, "{\"cpu\":1}", "reflects current shell value")
            compare(pg.screensData, win.screensData, "screensData bound to the window")
            // configJson: no configBridge in the test → the binding yields "".
            compare(pg.configJson, "", "configJson binding falls back to empty")

            // A LIVE shell update must flow through the binding (not a one-shot copy).
            root._metricsJson = "{\"cpu\":99}"
            compare(win.metricsJson, "{\"cpu\":99}", "window property tracks the shell")
            compare(pg.metricsJson, "{\"cpu\":99}", "bound page updates live")
            pg.destroy()
        }

        function test_bindStackItem_rebinds_cleanly() {
            var pg = pageStub.createObject(root)
            win.bindStackItem(pg)
            win.bindStackItem(pg)                    // second bind must not throw
            root._metricsJson = "{\"v\":2}"
            compare(pg.metricsJson, "{\"v\":2}", "still tracks after a rebind")
            pg.destroy()
        }

        // W5 finding 6: bindStackItem resolves the Dashboard's egress gate for
        // a Diagnostics page. With no dashboard on the stack (--diagnostics
        // start; here the StackView is empty) the page's netHub must STAY null
        // - the Network tab then shows its honest "not available" state.
        function test_bindStackItem_leaves_netHub_null_without_a_dashboard() {
            // The stack must ACTUALLY be empty for this to mean anything. It used
            // to be empty by accident - main.qml's initialItem was a qrc: URL that
            // could not resolve under qmltestrunner, so no Dashboard ever loaded
            // and this assertion passed without exercising the branch. Now that
            // the Dashboard does load, empty the stack deliberately.
            // Single axis (`children` only) - no visited set needed, and
            // scripts/check_tree_walks.py only flags multi-axis descents.
            function findStack(n) {
                if (!n) return null
                if (n.objectName === "mainStack") return n
                var kids = n.children || []
                for (var i = 0; i < kids.length; i++) {
                    var hit = findStack(kids[i])
                    if (hit) return hit
                }
                return null
            }
            var stack = findStack(win.contentItem)
            verify(stack !== null, "found the StackView")
            stack.clear()
            wait(50)
            compare(stack.depth, 0, "precondition: the stack really is empty")
            var pg = Qt.createQmlObject(
                'import QtQuick; QtObject { property var netHub: null; property string metricsJson: "" }',
                root, "netpg")
            win.bindStackItem(pg)
            compare(pg.netHub, null, "no dashboard on the stack → netHub stays null (never a fake gate)")
            compare(pg.metricsJson, win.metricsJson, "the other bindings still landed")
            pg.destroy()
        }

        function test_bindStackItem_ignores_null_and_bare_items() {
            win.bindStackItem(null)                  // no throw
            var bare = barePage.createObject(root)
            win.bindStackItem(bare)                  // item lacks the props → untouched
            compare(bare.marker, 7, "an item without shell props is left alone")
            verify(!bare.hasOwnProperty("metricsJson"), "no property was injected")
            bare.destroy()
            verify(true, "null + bare items handled without error")
        }

        function test_flushPendingUiState_routes_to_the_dashboard() {
            var dashboard = findPred(win.contentItem, function (n) {
                return n && typeof n.flushPendingUiState === "function" && n !== win
            })
            verify(dashboard !== null, "the real Dashboard exposes the shutdown flush surface")
            verify(win.flushPendingUiState(), "main.qml routes the clean-shutdown flush successfully")
        }

        function test_display_disconnect_events_are_declared_and_observable() {
            compare(win.displayDisconnected, "")
            compare(win.displaySelectionRequested, "")
            win.displayDisconnected = "DP-3"
            compare(win.lastDisplayEventText,
                    "Dashboard display DP-3 disconnected. Waiting for reconnection.")
            win.displaySelectionRequested = "DP-3"
            compare(win.lastDisplayEventText,
                    "Dashboard display DP-3 is unavailable. Open Xeneon Edge Manager to select a display.")
            // C++ clears both markers when the configured target reconnects.
            win.displaySelectionRequested = ""
            win.displayDisconnected = ""
            compare(win.lastDisplayEventText, "")
        }

        // ── contentRotation (fixed modes) ─────────────────────────────────────
        function test_content_rotation_fixed_modes_data() {
            return [
                { tag: "portrait",           mode: "portrait",           rot: 0 },
                { tag: "landscape",          mode: "landscape",          rot: 90 },
                { tag: "inverted-portrait",  mode: "inverted-portrait",  rot: 180 },
                { tag: "inverted-landscape", mode: "inverted-landscape", rot: 270 },
            ]
        }
        function test_content_rotation_fixed_modes(d) {
            win.orientationMode = d.mode
            compare(win.contentRotation, d.rot, d.mode + " → " + d.rot + "°")
        }

        // Auto mode ignores manual rotation and follows the (debounced) sensor.
        // The FIRST reading is applied promptly (no wall-clock wait needed).
        function test_content_rotation_auto_follows_sensor() {
            win.orientationMode = "auto"
            win.sensorRotation = -1
            win._stableSensorRotation = -1
            // No reading yet → default to LANDSCAPE (the Edge's primary orientation),
            // derived from the window aspect so it's right on either OS display config.
            win.width = 300; win.height = 500     // portrait window → rotate 90° to landscape
            compare(win.contentRotation, 90, "auto, no reading, portrait window → landscape (90°)")
            win.width = 500; win.height = 300     // landscape window → already landscape
            compare(win.contentRotation, 0, "auto, no reading, landscape window → landscape (0°)")
            win.sensorRotation = 90               // first reading applies immediately
            compare(win._stableSensorRotation, 90, "first sensor reading applied promptly")
            compare(win.contentRotation, 90, "auto follows the sensor to 90°")
        }

        // The rotating container (main.qml contentRoot) swaps width/height
        // (portrait↔landscape aspect) only for the 90°/270° quarter turns. We
        // tree-walk the window for the REAL contentRoot (the object exposing
        // `swapped`) and read its actual `swapped`/`width`/`height` - so a broken
        // `swapped:` predicate OR a broken width/height swap fails here.
        function test_content_root_swaps_aspect_at_quarter_turns() {
            var cr = findPred(win.contentItem, function (n) {
                return n && typeof n.swapped === "boolean" })
            verify(cr !== null, "found contentRoot (the rotating aspect container)")
            // Distinct window dimensions so an actual width/height swap is observable.
            win.width = 300; win.height = 500

            // 0° portrait - upright, keeps the window aspect (not swapped).
            win.orientationMode = "portrait"
            compare(win.contentRotation, 0)
            compare(cr.swapped, false, "0° is not swapped")
            compare(cr.width, win.width, "0°: contentRoot width tracks the window width")
            compare(cr.height, win.height, "0°: contentRoot height tracks the window height")

            // 90° landscape - swapped: width takes the window HEIGHT and vice-versa.
            win.orientationMode = "landscape"
            compare(win.contentRotation, 90)
            compare(cr.swapped, true, "90° is a swapped (landscape) orientation")
            compare(cr.width, win.height, "90°: contentRoot width takes the window HEIGHT (aspect swapped)")
            compare(cr.height, win.width, "90°: contentRoot height takes the window WIDTH")

            // 180° inverted-portrait - back to the portrait aspect (not swapped).
            win.orientationMode = "inverted-portrait"
            compare(win.contentRotation, 180)
            compare(cr.swapped, false, "180° keeps the portrait aspect (not swapped)")
            compare(cr.width, win.width, "180°: contentRoot width back to the window width")
            compare(cr.height, win.height, "180°: contentRoot height back to the window height")

            // 270° inverted-landscape - swapped again.
            win.orientationMode = "inverted-landscape"
            compare(win.contentRotation, 270)
            compare(cr.swapped, true, "270° is a swapped (landscape) orientation")
            compare(cr.width, win.height, "270°: contentRoot width takes the window HEIGHT")
            compare(cr.height, win.width, "270°: contentRoot height takes the window WIDTH")
        }

        // (Full-shell add-page navigation is covered in tst_hub_navigation.qml, which
        // pushes the real Dashboard into this shell by relative URL - main.qml's qrc:
        // initialItem can't resolve under qmltestrunner.)

        // ── onContentRotationChanged (reorient fx) ────────────────────────────
        // A contentRotation change fires main.qml's Connections handler
        // `onContentRotationChanged`, which - when motion is allowed - restarts the
        // reorient fx that briefly dips contentRoot's scale/opacity before easing it
        // back to full. We drive a real rotation change on the REAL contentRoot and
        // observe that dip-then-settle, proving the handler ran (not just the binding).
        function test_content_rotation_change_runs_reorient_fx() {
            var cr = findPred(win.contentItem, function (n) {
                return n && typeof n.swapped === "boolean" })
            verify(cr !== null, "found contentRoot (the reorient-fx target)")
            win.reduceMotion = false
            win.orientationMode = "portrait"          // settle at a known upright state
            tryVerify(function () { return cr.scale === 1 && cr.opacity === 1 }, 3000,
                      "contentRoot rests at full scale/opacity between turns")
            win.orientationMode = "landscape"         // rotation change → handler fires
            tryVerify(function () { return cr.scale < 1 || cr.opacity < 1 }, 2000, "onContentRotationChanged restarted the reorient fx (scale/opacity dip)")
            tryVerify(function () { return cr.scale === 1 && cr.opacity === 1 }, 3000,
                      "reorient fx eases contentRoot back to full scale/opacity")
        }

        function test_rotation_is_temporally_smooth_when_motion_is_enabled() {
            var cr = findPred(win.contentItem, function (n) {
                return n && typeof n.swapped === "boolean" })
            verify(cr !== null, "found contentRoot")
            win.reduceMotion = false
            win.orientationMode = "portrait"
            tryCompare(cr, "rotation", 0, 2000)

            win.orientationMode = "landscape"
            wait(90)
            verify(cr.rotation > 0 && cr.rotation < 90,
                   "a physical quarter-turn is between endpoints while easing")
            tryCompare(cr, "rotation", 90, 2000)
        }
    }
}
