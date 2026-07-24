import QtQuick
import QtTest
import "../../ui/qml" as App

// COVERS: fn:Dashboard.policyAllowsWidget, fn:Dashboard.policyFilteredWidgets, fn:DashboardStore.lockToPreset
//
// E9 managed/org policy - what the Dashboard ENFORCES, driven through a fake
// configBridge whose policy() answer we control per test:
//   • no policy       → behaviour is byte-for-byte the unmanaged default
//                       (user's own netOffline flag still governs the hub)
//   • net_offline     → NetHub's kill switch is PINNED on; the user's
//                       appearance flag cannot lift it; requests are refused
//   • allowed_hosts   → NetHub.allowHosts is pinned to the org list; a
//                       non-listed host is blocked, a listed one goes through
//   • disable_widget_types → hidden from the picker model AND the tile loader
//                       never instantiates the widget
//   • force_preset    → the store is locked to the preset: nothing persists
//                       (saveUiState never fires), a Manager push is refused,
//                       and an unknown preset id still engages the lock
//   • the "Managed by your organization" line is visible exactly when managed
//
// The real Dashboard.qml is loaded via a Loader exactly as tst_dashboard.qml
// does; the store and tile hosts are duck-typed out of the object graph, and
// the app-global NetHub is exposed by Dashboard's host contract.
Item {
    id: root
    width: 900; height: 600

    // Shell (main.qml root) surface Dashboard binds to.
    property alias theme: _theme
    App.Theme { id: _theme }
    App.WidgetCatalog { id: _catalog }
    property string accentName: "blue"
    property real glassOpacity: 0.5
    property bool showWidgetGlow: true
    property bool reduceMotion: false
    property string themeMode: "dark"
    property bool animatedBackground: true
    property string orientationMode: "auto"
    property string metricsJson: "{}"
    property string screensData: "[]"

    // ── Fake configBridge (the policy seam + a saveUiState recorder) ─────────
    property var fakePolicy: ({ "active": false })
    property int saveCalls: 0
    property string lastSaved: ""
    property string storedUiState: ""

    property var configBridge: ({
        policy: function () { return root.fakePolicy },
        uiState: function () { return root.storedUiState },
        saveUiState: function (json) { root.saveCalls++; root.lastSaved = json; return true },
        starterLayout: function () { return "" },
        imageUrl: function (p) { return p },
        configJson: function () { return "{}" },
        resolveSecret: function (raw) { return { ok: true, value: "" + raw, error: "", plaintext: false } }
    })

    Loader { id: ld; anchors.fill: parent }

    // A fake XHR so the allowlist tests never open a socket (see tst_nethub).
    function makeFake() {
        return {
            method: "", url: "", sent: false,
            readyState: 0, status: 0, responseText: "",
            timeout: 0, ontimeout: null, onreadystatechange: null,
            headers: ({}),
            open: function (m, u) { this.method = m; this.url = u; this.readyState = 1 },
            setRequestHeader: function (k, v) { this.headers[k] = v },
            send: function (b) { this.sent = true }
        }
    }

    // ── tree helpers (as tst_dashboard.qml) ──────────────────────────────────
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
    function netHub() {
        return ld.item ? ld.item.netGate : null
    }
    function tileLoaderFor(type) {
        return findPred(ld.item, function (x) {
            return x && x.wType !== undefined && x.wType === type && x.wId !== undefined
        })
    }
    function managedLine() {
        return findPred(ld.item, function (x) {
            return x && x.text !== undefined && x.text === "Managed by your organization"
        })
    }
    function makeDoc(tileList) {
        return JSON.stringify({ version: 1, appearance: {}, settings: {},
            pages: [ { name: "P1", tiles: tileList } ] })
    }

    TestCase {
        name: "PolicyQml"
        when: windowShown

        // Tear down + relaunch the REAL Dashboard under a given policy - the
        // policy is read once at creation, exactly as in the app.
        function reload(policy) {
            ld.source = ""
            root._store = null
            root.fakePolicy = policy
            root.saveCalls = 0
            root.lastSaved = ""
            root.storedUiState = ""
            ld.source = "../../ui/qml/Dashboard.qml"
            tryVerify(function () { return ld.status === Loader.Ready && ld.item !== null }, 5000)
            verify(root.store() !== null, "found Dashboard's private DashboardStore")
        }

        // ── No policy: the unmanaged default, byte-for-byte ─────────────────
        function test_absent_policy_is_todays_behaviour() {
            reload({ "active": false, "source": "absent", "forcePreset": "",
                     "netOffline": false, "allowedHosts": [],
                     "disableUserWidgets": false, "disabledWidgetTypes": [] })
            var d = ld.item
            var hub = root.netHub()
            verify(hub !== null, "the app-global NetHub was injected")
            compare(hub.offline, false, "no policy: hub starts online")
            compare(hub.allowHosts.length, 0, "no policy: no allowlist pin")

            // The USER's own kill switch still works - policy absent must not
            // change the pre-E9 contract in either direction.
            root.store().setAppearance("netOffline", true)
            tryCompare(hub, "offline", true)
            root.store().setAppearance("netOffline", false)
            tryCompare(hub, "offline", false)

            compare(d.policyAllowsWidget("httpjson"), true, "no policy: every type allowed")
            compare(d.policyFilteredWidgets("Data").length, _catalog.inCategory("Data").length,
                    "no policy: the picker model is the full catalog category")
            compare(root.store().policyLockedPreset, "", "no policy: layout not locked")
            var line = root.managedLine()
            verify(!line || !line.visible, "no policy: no managed-by line")
        }

        // ── net_offline pin ──────────────────────────────────────────────────
        function test_net_offline_is_pinned_over_user_config() {
            reload({ "active": true, "source": "policy", "forcePreset": "",
                     "netOffline": true, "allowedHosts": [],
                     "disableUserWidgets": false, "disabledWidgetTypes": [] })
            var hub = root.netHub()
            compare(hub.offline, true, "policy pins the kill switch on")

            // The user flag CANNOT lift the pin - that is what "enforceable"
            // means, and what the attestation now rests on.
            root.store().setAppearance("netOffline", false)
            compare(hub.offline, true, "user config cannot lift a policy pin")

            var reason = ""
            var xhr = hub.request({ url: "https://api.example.com/x",
                                    onError: function (r) { reason = r } })
            compare(xhr, null, "no socket is even constructed")
            compare(reason, "offline", "the gate refused with the offline reason")
            compare(hub.blocked, 1, "the refusal is counted (attestation surface)")
        }

        // ── allowed_hosts pin ────────────────────────────────────────────────
        function test_allowed_hosts_is_pinned() {
            reload({ "active": true, "source": "policy", "forcePreset": "",
                     "netOffline": false, "allowedHosts": ["api.internal.example"],
                     "disableUserWidgets": false, "disabledWidgetTypes": [] })
            var hub = root.netHub()
            compare(hub.allowHosts.length, 1, "the org list is pinned onto the hub")
            compare(hub.allowHosts[0], "api.internal.example")

            var reason = ""
            hub.request({ url: "https://evil.example/x",
                          onError: function (r) { reason = r } })
            compare(reason, "blocked", "a host outside the org list is refused")

            var fake = null
            var sentXhr = hub.request({ url: "https://api.internal.example/x",
                                        xhrFactory: function () { fake = root.makeFake(); return fake } })
            verify(sentXhr !== null, "a listed host goes through the gate")
            compare(fake.sent, true, "…and is actually sent")
            compare(hub.requests, 1)
            compare(hub.blocked, 1)
        }

        // ── disable_widget_types: hidden from picker, never rendered ────────
        // The E9<->E3 integration point, wired at merge time: the policy's
        // disableUserWidgets bit vetoes the user-widget loader even when the
        // user's own enable flag says yes. The veto lives inside
        // _userWidgetsFlag so every load path inherits it; that is also what
        // makes it directly testable rather than inferred from an empty
        // catalog (which "no widgets installed" would fake).
        function test_policy_vetoes_user_widget_loader() {
            reload({ "active": true, "source": "policy", "forcePreset": "",
                     "netOffline": false, "allowedHosts": [],
                     "disableUserWidgets": true, "disabledWidgetTypes": [] })
            var d = ld.item
            // The user says YES on the LIVE store - the strongest form of the
            // preference - and the org still wins.
            root.store().setAppearance("enableUserWidgets", true)
            verify(d.managed, "the session reads as managed")
            compare(d._userWidgetsFlag(), false,
                    "org veto beats the user's enabled flag")
        }

        // ...and without the veto the same user flag reads true - proving the
        // case above fails for the RIGHT reason, not because the flag never
        // reads true in this harness.
        function test_user_widget_flag_honoured_when_policy_allows() {
            reload({ "active": true, "source": "policy", "forcePreset": "",
                     "netOffline": false, "allowedHosts": [],
                     "disableUserWidgets": false, "disabledWidgetTypes": [] })
            var d = ld.item
            root.store().setAppearance("enableUserWidgets", true)
            compare(d._userWidgetsFlag(), true,
                    "no veto: the user's own flag decides")
        }

        function test_disabled_types_hidden_and_not_rendered() {
            reload({ "active": true, "source": "policy", "forcePreset": "",
                     "netOffline": false, "allowedHosts": [],
                     "disableUserWidgets": false, "disabledWidgetTypes": ["httpjson"] })
            var d = ld.item
            compare(d.policyAllowsWidget("httpjson"), false, "the disabled type is disallowed")
            compare(d.policyAllowsWidget("clock"), true, "other types are untouched")

            var dataAll = _catalog.inCategory("Data")
            var dataFiltered = d.policyFilteredWidgets("Data")
            compare(dataFiltered.length, dataAll.length - 1,
                    "policyFilteredWidgets removed exactly the disabled type")
            for (var i = 0; i < dataFiltered.length; i++)
                verify(dataFiltered[i].type !== "httpjson", "httpjson is hidden from the picker model")

            // A stored tile of the disabled type must not instantiate the widget.
            verify(root.store().applyExternal(root.makeDoc([
                { id: "h1", type: "httpjson", size: "1x1" },
                { id: "c1", type: "clock", size: "1x1" } ])),
                "an unlocked store accepts the pushed doc")
            tryVerify(function () { return root.tileLoaderFor("clock") !== null }, 5000)
            var blockedLd = root.tileLoaderFor("httpjson")
            verify(blockedLd !== null, "the disabled tile's loader exists")
            compare(blockedLd.loadEnabled, false, "…but never loads the widget")
            compare(root.tileLoaderFor("clock").loadEnabled, true, "allowed neighbour renders")
        }

        // ── force_preset: locked layout, nothing persists ────────────────────
        function test_force_preset_locks_layout_and_persistence() {
            root.storedUiState = ""   // pretend the user had no doc; irrelevant under lock
            reload({ "active": true, "source": "policy", "forcePreset": "minimal",
                     "netOffline": false, "allowedHosts": [],
                     "disableUserWidgets": false, "disabledWidgetTypes": [] })
            var s = root.store()
            compare(s.policyLockedPreset, "minimal", "lockToPreset engaged the forced preset")
            var pages = s.pages()
            compare(pages.length, 1, "the minimal preset's single page is live")
            compare(pages[0].tiles[0].type, "clock", "…with the preset's own tiles")

            // Nothing persists: not the seed, not a structural edit, not an
            // explicit flush. The user's own layout stays untouched underneath.
            s.addTile(0, "clock")     // structural edit → would normally force-flush
            s.flushNow()
            compare(root.saveCalls, 0, "lockToPreset means saveUiState NEVER fires")
            compare(root.storedUiState, "", "the user's stored layout is untouched")

            // IPC is just another editing surface: a Manager push is refused.
            compare(s.applyExternal(root.makeDoc([{ id: "x", type: "cpu", size: "1x1" }])),
                    false, "a Manager push cannot override the org preset")

            var line = root.managedLine()
            verify(line !== null, "the managed-by line exists")
            compare(line.visible, true, "\"Managed by your organization\" is visible")
        }

        // ── force_preset with a bad id: locked FALLBACK, never unlocked ─────
        function test_unknown_forced_preset_stays_locked() {
            reload({ "active": true, "source": "policy", "forcePreset": "no-such-preset",
                     "netOffline": false, "allowedHosts": [],
                     "disableUserWidgets": false, "disabledWidgetTypes": [] })
            var s = root.store()
            verify(s.policyLockedPreset !== "", "lockToPreset stays engaged for an unknown preset id")
            verify(s.pages().length > 0, "…and a usable fallback layout is live")
            s.flushNow()
            compare(root.saveCalls, 0, "the fallback lock still suppresses persistence")
            // The guard branch: an empty id refuses to engage at all.
            compare(s.lockToPreset(""), false, "lockToPreset(\"\") is refused")
        }
    }
}
