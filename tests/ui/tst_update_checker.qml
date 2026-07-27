import QtQuick
import QtQuick.Controls
import QtTest
import "../../ui/qml" as App
import "../../ui/qml/widgets" as W

// UpdateChecker (ui/qml/widgets/UpdateChecker.qml) - the opt-in E10 update
// check - plus its SettingsPanel opt-in surface. Driven entirely offline via
// the xhrFactory seam through NetHub (no real sockets). Pins the privacy
// contract and the version-ordering rules:
//   • OFF by default: with defaults, NO request is ever constructed.
//   • Opting in fires EXACTLY ONE gated request (GET, releases API, no auth).
//   • The NetHub kill switch blocks the check before an XHR exists.
//   • SemVer ordering: v1.0.0-alpha.2 < v1.0.0 (the naive string compare says
//     the opposite), alpha.2 < alpha.10 < beta.1 < rc.1 < release.
//   • Install-type honesty: $APPIMAGE (via the audited ${env:} resolver) →
//     zsync wording; anything else → "update via your package manager".
//
// (UpdateChecker is intentionally NOT in qml_coverage.py's FUNCTION_SOURCES,
// so no COVERS header - the behavior matrix enumerates the gate itself, and
// the gate-side behaviors are claimed by tst_nethub.qml.)
Item {
    id: root
    width: 720; height: 1000

    // A fake XHR that records what the gate did to it and resolves on demand.
    function makeFake() {
        return {
            method: "", url: "", sent: false, aborted: false,
            readyState: 0, status: 0, responseText: "", headers: ({}),
            timeout: 0, ontimeout: null, onreadystatechange: null,
            open: function (m, u) { this.method = m; this.url = u; this.readyState = 1 },
            setRequestHeader: function (k, v) { this.headers[k] = v },
            send: function (b) { this.sent = true; this.body = b },
            abort: function () { this.aborted = true },
            resolveWith: function (st, body) {
                this.status = st; this.responseText = body; this.readyState = 4
                if (this.onreadystatechange) this.onreadystatechange()
            }
        }
    }

    // ── Service under test (manual control) ─────────────────────────────────
    W.NetHub { id: gate }
    W.UpdateChecker { id: checker; netHub: gate }

    // Never touched by any test: proves the shipped default is off.
    W.UpdateChecker { id: pristine }

    // Mirrors a persisted opt-in at Hub startup. `enabled` is already true
    // during construction, which must still create exactly one request.
    // This pins the application lifecycle separately from Qt 6.11's delayed
    // HTTP/2 cleanup warning, which occurs after a successful request.
    property int startupFactoryCount: 0
    property var startupFirstFake: null
    property var startupLastFake: null
    W.NetHub { id: startupGate }
    W.UpdateChecker {
        id: startupEnabled
        netHub: startupGate
        enabled: true
        xhrFactory: function () {
            root.startupFactoryCount++
            var fake = root.makeFake()
            if (!root.startupFirstFake) root.startupFirstFake = fake
            root.startupLastFake = fake
            return fake
        }
    }

    // No gate injected: must fail closed, not build its own XHR.
    W.UpdateChecker { id: gateless }

    // ── SettingsPanel integration (the real opt-in path) ────────────────────
    // Mirrors Dashboard's wiring: the checker's `enabled` is BOUND to the
    // persisted appearance flag the panel's switch writes.
    property alias theme: _theme
    App.Theme { id: _theme }
    App.DashboardStore { id: store }
    property string themeMode: "dark"
    property string orientationMode: "auto"
    property real glassOpacity: 0.6
    property bool showWidgetGlow: true
    property bool animatedBackground: true
    property bool reduceMotion: false
    property string accentName: _theme.accentName
    Component.onCompleted: store.load("blank")

    W.NetHub { id: gate2 }
    W.UpdateChecker {
        id: wired
        netHub: gate2
        currentVersion: "1.0.0-alpha.2"
        enabled: { var _ = store.revision; return store.appearance().updateCheck === true }
    }
    W.SettingsPanel { id: panel; updateChecker: wired }

    // tree helpers (as in tst_settings_panel)
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
    function findText(node, str) {
        return findPred(node, function (n) {
            return n.text !== undefined && typeof n.text === "string" && n.text === str
        })
    }
    function findFlick() {
        return findPred(panel, function (n) {
            return n.contentHeight !== undefined && n.contentY !== undefined && n.boundsBehavior !== undefined
        })
    }

    TestCase {
        name: "UpdateChecker"
        when: windowShown

        property var lastFake: null
        property int factoryCount: 0

        function init() {
            gate.offline = false
            gate.allowHosts = []
            gate.requests = 0
            gate.blocked = 0
            gate.byHost = ({})
            checker.enabled = false          // resets status/latestTag/errorText
            checker.currentVersion = ""
            checker.envResolver = null
            lastFake = null
            factoryCount = 0
            var tc = this
            checker.xhrFactory = function () {
                tc.factoryCount++
                tc.lastFake = root.makeFake()
                return tc.lastFake
            }
        }

        // ── THE default: off, and off means SILENT ──────────────────────────
        function test_default_is_off_and_fires_nothing() {
            compare(pristine.enabled, false, "a factory-fresh checker is opted OUT")
            compare(pristine.status, "idle", "…and has done nothing")
            verify(pristine.message.indexOf("Off") === 0, "the surface says so honestly")

            // Even a direct check() while disabled must not construct a request:
            // the opt-in gates the CODE PATH, not just the trigger.
            checker.check()
            compare(factoryCount, 0, "no XHR constructed while opted out")
            compare(gate.requests, 0, "the egress gate counted nothing")
            compare(gate.blocked, 0, "…and refused nothing (nothing was attempted)")
            compare(checker.status, "idle")
        }

        function test_persisted_optin_at_startup_fires_one_request_without_abort() {
            compare(startupEnabled.enabled, true)
            compare(startupFactoryCount, 1,
                    "construction and Component.onCompleted must not duplicate the startup check")
            compare(startupGate.requests, 1, "the gate sees one startup request")
            verify(startupFirstFake === startupLastFake, "only one XHR object was created")
            verify(!startupFirstFake.aborted,
                   "startup must not abort a just-opened TLS request with a duplicate check")
        }

        // ── opt-in: exactly one gated request, nothing identifying ──────────
        function test_optin_fires_exactly_one_gated_request() {
            checker.currentVersion = "v1.0.0"
            checker.enabled = true
            compare(factoryCount, 1, "opting in fires exactly one request")
            compare(gate.requests, 1, "…and it went through the NetHub gate")
            compare(lastFake.method, "GET")
            compare(lastFake.url, checker.releasesUrl)
            compare(lastFake.url, "https://api.github.com/repos/skyphoenix-it/skyphoenix-edgehub-linux/releases?per_page=20")
            verify(lastFake.headers["Authorization"] === undefined, "no credential rides along")
            verify(lastFake.body === undefined, "a GET with no body - nothing identifying sent")
            compare(checker.status, "checking")
            lastFake.resolveWith(200, '{"tag_name":"v1.0.0"}')
            compare(checker.status, "uptodate")
            compare(checker.updateAvailable, false)
            compare(factoryCount, 1, "no follow-up request appears on its own")
        }

        // ── newer / same / older ─────────────────────────────────────────────
        function test_newer_version_is_detected() {
            checker.currentVersion = "1.0.0-alpha.2"
            checker.enabled = true
            lastFake.resolveWith(200, '{"tag_name":"v1.0.0"}')
            compare(checker.updateAvailable, true, "alpha.2 → 1.0.0 is an update")
            compare(checker.status, "update")
            compare(checker.latestTag, "v1.0.0")
            verify(checker.message.indexOf("v1.0.0") >= 0, "the surface names the version")
            verify(checker.message.indexOf("package manager") >= 0,
                   "a non-AppImage install is sent to its package manager")
        }

        function test_same_and_older_versions_stay_silent() {
            checker.currentVersion = "v1.0.0"
            checker.enabled = true
            lastFake.resolveWith(200, '{"tag_name":"v1.0.0"}')
            compare(checker.updateAvailable, false, "same version → silent")
            compare(checker.status, "uptodate")

            checker.check()   // remote somehow older (rollback / dev build ahead)
            lastFake.resolveWith(200, '{"tag_name":"v0.9.0"}')
            compare(checker.updateAvailable, false, "older remote → silent, never a downgrade nag")
            compare(checker.status, "uptodate")
        }

        function test_build_ahead_of_its_own_tag_is_not_nagged() {
            // git describe on a commit past the tag: still counts as up to date.
            checker.currentVersion = "v1.0.0-alpha.2-5-gabc1234"
            checker.enabled = true
            lastFake.resolveWith(200, '{"tag_name":"v1.0.0-alpha.2"}')
            compare(checker.updateAvailable, false)
            compare(checker.status, "uptodate")
        }

        // ── The list endpoint + release channel (the alpha/beta bug) ────────
        // GitHub's /releases/latest EXCLUDES pre-releases and 404s when every
        // release is one. With alpha.1/alpha.2 both flagged prerelease, a real
        // "Check for updates" returned HTTP 404 -> "no tag_name" -> an ERROR
        // instead of a version, for the entire alpha/beta period. These pin the
        // list-endpoint behaviour that fixes it.
        readonly property string realWorldReleases:
            '[{"tag_name":"v1.0.0-alpha.2","prerelease":true,"draft":false},' +
            ' {"tag_name":"v1.0.0-alpha.1","prerelease":true,"draft":false}]'

        function test_all_prereleases_still_report_a_version_not_an_error() {
            // The exact production situation that used to 404.
            checker.currentVersion = "v1.0.0-alpha.2-220-gabc1234"
            checker.enabled = true
            lastFake.resolveWith(200, realWorldReleases)
            compare(checker.latestTag, "v1.0.0-alpha.2", "the newest pre-release is reported")
            verify(checker.status !== "error", "an all-prerelease repo must not error")
            compare(checker.updateAvailable, false, "this build is ahead of alpha.2")
        }

        function test_prerelease_user_is_offered_a_newer_prerelease() {
            checker.currentVersion = "v1.0.0-alpha.1"
            checker.enabled = true
            lastFake.resolveWith(200, realWorldReleases)
            compare(checker.latestTag, "v1.0.0-alpha.2")
            compare(checker.updateAvailable, true, "alpha user gets the newer alpha")
            compare(checker.status, "update")
        }

        function test_stable_user_is_NOT_pushed_onto_a_prerelease() {
            // Channel rule: a stable build must never be offered an alpha.
            checker.currentVersion = "v1.0.0"
            checker.enabled = true
            lastFake.resolveWith(200,
                '[{"tag_name":"v1.1.0-beta.1","prerelease":true,"draft":false},' +
                ' {"tag_name":"v1.0.0","prerelease":false,"draft":false}]')
            compare(checker.latestTag, "v1.0.0", "the beta is skipped for a stable build")
            compare(checker.updateAvailable, false)
        }

        function test_stable_user_still_gets_a_newer_stable() {
            checker.currentVersion = "v1.0.0"
            checker.enabled = true
            lastFake.resolveWith(200,
                '[{"tag_name":"v1.2.0","prerelease":false,"draft":false},' +
                ' {"tag_name":"v1.1.0-beta.1","prerelease":true,"draft":false}]')
            compare(checker.latestTag, "v1.2.0")
            compare(checker.updateAvailable, true)
        }

        function test_staged_stable_tag_is_never_offered_before_promotion() {
            var staged =
                '[{"tag_name":"v1.0.0","prerelease":true,"draft":false},' +
                ' {"tag_name":"v1.0.0-rc.1","prerelease":true,"draft":false}]'

            checker.currentVersion = "v1.0.0-beta.1"
            checker.enabled = true
            lastFake.resolveWith(200, staged)
            compare(checker.latestTag, "v1.0.0-rc.1",
                    "beta users must not see the staged stable candidate")

            checker.check()
            checker.currentVersion = "v1.0.0-rc.1"
            lastFake.resolveWith(200, staged)
            compare(checker.latestTag, "v1.0.0-rc.1",
                    "RC users must not see the staged stable candidate")

            checker.check()
            checker.currentVersion = "v0.9.0"
            lastFake.resolveWith(200,
                '[{"tag_name":"v1.0.0","prerelease":true,"draft":false},' +
                ' {"tag_name":"v0.9.0","prerelease":false,"draft":false}]')
            compare(checker.latestTag, "v0.9.0",
                    "stable users must not see the staged stable candidate")
        }

        function test_drafts_are_never_offered() {
            checker.currentVersion = "v1.0.0-alpha.1"
            checker.enabled = true
            lastFake.resolveWith(200,
                '[{"tag_name":"v9.9.9","prerelease":false,"draft":true},' +
                ' {"tag_name":"v1.0.0-alpha.2","prerelease":true,"draft":false}]')
            compare(checker.latestTag, "v1.0.0-alpha.2", "the draft is ignored")
        }

        function test_dev_build_reports_unknown_never_update() {
            checker.currentVersion = "dev"
            checker.enabled = true
            lastFake.resolveWith(200, '{"tag_name":"v1.0.0"}')
            compare(checker.updateAvailable, false, "an unorderable version never claims an update")
            compare(checker.status, "unknown")
            compare(checker.latestTag, "v1.0.0", "…but the latest tag is still reported")
        }

        // ── malformed / hostile responses ────────────────────────────────────
        function test_malformed_json_is_an_error_not_an_update() {
            checker.currentVersion = "v1.0.0"
            checker.enabled = true
            lastFake.resolveWith(200, "not json {{{")
            compare(checker.status, "error")
            compare(checker.updateAvailable, false)
            verify(checker.errorText.indexOf("malformed") >= 0)
        }

        function test_missing_tag_name_is_an_error() {
            checker.currentVersion = "v1.0.0"
            checker.enabled = true
            lastFake.resolveWith(200, '{"name":"a release with no tag_name"}')
            compare(checker.status, "error")
            compare(checker.updateAvailable, false)
            verify(checker.errorText.indexOf("tag_name") >= 0)
        }

        function test_http_error_is_reported() {
            checker.currentVersion = "v1.0.0"
            checker.enabled = true
            lastFake.resolveWith(500, "")
            compare(checker.status, "error")
            compare(checker.updateAvailable, false)
            verify(checker.errorText.indexOf("http 500") >= 0)
        }

        // ── the kill switch ──────────────────────────────────────────────────
        function test_nethub_offline_blocks_the_check() {
            gate.offline = true
            checker.currentVersion = "v1.0.0"
            checker.enabled = true
            compare(factoryCount, 0, "the gate refused BEFORE any XHR existed")
            compare(gate.blocked, 1, "…and counted the refusal")
            compare(gate.requests, 0)
            compare(checker.status, "offline")
            compare(checker.updateAvailable, false)
            verify(checker.message.indexOf("offline switch") >= 0)
        }

        function test_host_allowlist_blocks_the_check() {
            gate.allowHosts = ["intranet.example.com"]
            checker.currentVersion = "v1.0.0"
            checker.enabled = true
            compare(factoryCount, 0)
            compare(gate.blocked, 1)
            compare(checker.status, "offline")
            verify(checker.message.indexOf("allowlist") >= 0)
        }

        // ── opting out aborts + clears ───────────────────────────────────────
        function test_disable_aborts_inflight_and_clears_result() {
            checker.currentVersion = "v1.0.0"
            checker.enabled = true
            var pending = lastFake
            verify(pending.sent, "a request is in flight")
            checker.enabled = false
            verify(pending.aborted, "opting out aborts the in-flight request")
            compare(checker.status, "idle")
            compare(checker.latestTag, "", "no stale result outlives consent")
            compare(checker.updateAvailable, false)
        }

        function test_no_gate_fails_closed() {
            gateless.enabled = true
            compare(gateless.status, "error", "no NetHub → no request, an honest error")
            gateless.enabled = false
        }

        // ── version ordering (the edge cases that have bitten) ──────────────
        function test_compare_versions_prerelease_ordering() {
            compare(checker.compareVersions("v1.0.0-alpha.2", "v1.0.0"), -1,
                    "pre-release < its release (naive string compare says the OPPOSITE)")
            compare(checker.compareVersions("v1.0.0", "v1.0.0-alpha.2"), 1)
            compare(checker.compareVersions("v1.0.0-alpha.2", "v1.0.0-alpha.10"), -1,
                    "numeric identifiers compare numerically, not lexically")
            compare(checker.compareVersions("v1.0.0-alpha.2", "v1.0.0-beta.1"), -1, "alpha < beta")
            compare(checker.compareVersions("v1.0.0-beta.1", "v1.0.0-rc.1"), -1, "beta < rc")
            compare(checker.compareVersions("v1.0.0-rc.1", "v1.0.0"), -1, "rc < release")
            compare(checker.compareVersions("1.0.0-alpha", "1.0.0-alpha.1"), -1,
                    "a prefix pre-release sorts lower")
            compare(checker.compareVersions("1.0.0-alpha.2", "1.0.0-alpha.2"), 0)
        }

        function test_compare_versions_numeric_components() {
            compare(checker.compareVersions("1.9.0", "1.10.0"), -1,
                    "minor 9 < 10 - component-wise, not string-wise")
            compare(checker.compareVersions("1.0.0", "1.0.1"), -1)
            compare(checker.compareVersions("2.0.0", "1.9.9"), 1)
            compare(checker.compareVersions("v1.0.0", "1.0.0"), 0, "leading v is cosmetic")
            compare(checker.compareVersions("1.0", "1.0.0"), 0, "missing patch reads as 0")
            compare(checker.compareVersions("1.0.0+build.5", "1.0.0"), 0, "build metadata is ignored")
        }

        function test_compare_versions_unparsable_is_null() {
            compare(checker.compareVersions("dev", "1.0.0"), null)
            compare(checker.compareVersions("1.0.0", ""), null)
            compare(checker.compareVersions("nightly", "banana"), null)
            compare(checker.compareVersions("1.0.0-alpha.2-5-gabc1234", "1.0.0-alpha.2"), 1,
                    "a git-describe suffix parses and sorts AFTER its tag")
        }

        // ── install-type detection ($APPIMAGE via the ${env:} resolver) ─────
        function test_install_kind_detection() {
            compare(checker.installKind, "package", "no resolver → assume package manager")

            checker.envResolver = ({ resolveSecret: function (raw) {
                return raw === "${env:APPIMAGE}"
                       ? { ok: true, value: "/home/u/Apps/EdgeHub.AppImage" }
                       : { ok: false, value: "", error: "unexpected ref: " + raw }
            } })
            compare(checker.installKind, "appimage", "$APPIMAGE set → AppImage install")

            checker.envResolver = ({ resolveSecret: function (raw) {
                return { ok: false, value: "", error: "environment variable APPIMAGE not set" }
            } })
            compare(checker.installKind, "package", "$APPIMAGE unset resolves as error → package")
        }

        function test_appimage_install_gets_zsync_wording() {
            checker.envResolver = ({ resolveSecret: function (raw) {
                return { ok: true, value: "/x/EdgeHub.AppImage" }
            } })
            checker.currentVersion = "1.0.0-alpha.2"
            checker.enabled = true
            lastFake.resolveWith(200, '{"tag_name":"v1.0.0"}')
            compare(checker.updateAvailable, true)
            verify(checker.message.indexOf("zsync") >= 0,
                   "an AppImage install is pointed at the zsync path")
            verify(checker.message.indexOf("package manager") < 0)
        }
    }

    // The real opt-in path: the SettingsPanel switch writes the persisted
    // appearance flag, the bound checker reacts, and exactly one gated request
    // fires. Runs against the same wiring shape Dashboard uses.
    TestCase {
        name: "UpdateOptInUI"
        when: windowShown

        property var lastFake: null
        property int factoryCount: 0

        function init() {
            tryVerify(function () { return store.loaded === true }, 3000)
            store.setAppearance("updateCheck", false)
            gate2.offline = false
            gate2.requests = 0
            gate2.blocked = 0
            gate2.byHost = ({})
            lastFake = null
            factoryCount = 0
            var tc = this
            wired.xhrFactory = function () {
                tc.factoryCount++
                tc.lastFake = root.makeFake()
                return tc.lastFake
            }
            panel.shown = true
            tryVerify(function () { return panel.opacity > 0.99 }, 2000)
        }

        function cleanup() { panel.shown = false }

        function bringIntoView(target) {
            var scroll = root.findFlick()
            verify(scroll !== null, "found the settings Flickable")
            var p = target.mapToItem(scroll.contentItem, 0, 0)
            var maxY = Math.max(0, scroll.contentHeight - scroll.height)
            scroll.contentY = Math.max(0, Math.min(maxY, p.y - 40))
            wait(60)
        }
        function clickTarget(target) { bringIntoView(target); mouseClick(target) }

        function updateSwitch() {
            var t = root.findText(panel, "Check for updates")
            verify(t !== null, "the opt-in row exists")
            var rowKids = t.parent.children
            for (var i = 0; i < rowKids.length; i++)
                if (rowKids[i].checked !== undefined && rowKids[i].checkable !== undefined)
                    return rowKids[i]
            return null
        }

        function test_switch_defaults_off_then_optin_fires_one_request() {
            var sw = updateSwitch()
            verify(sw !== null, "found the update-check switch")
            compare(sw.checked, false, "the switch is OFF by default")
            compare(wired.enabled, false, "…so the bound checker is disabled")
            compare(gate2.requests, 0, "…and nothing has ever left the gate")
            compare(factoryCount, 0)

            clickTarget(sw)
            compare(store.appearance().updateCheck, true, "the tap persists the appearance flag")
            compare(wired.enabled, true, "the bound checker follows the flag")
            compare(factoryCount, 1, "opting in via the UI fires exactly one gated request")
            compare(gate2.requests, 1)

            lastFake.resolveWith(200, '{"tag_name":"v1.0.0"}')
            compare(wired.updateAvailable, true, "alpha.2 sees 1.0.0 as an update")
            var line = root.findPred(panel, function (n) {
                return n.text !== undefined && typeof n.text === "string"
                       && n.text.indexOf("v1.0.0 is available") >= 0
            })
            verify(line !== null, "the result line surfaces the new version in the panel")
        }

        function test_optout_clears_and_goes_silent_again() {
            var sw = updateSwitch()
            clickTarget(sw)                       // on
            compare(wired.enabled, true)
            compare(factoryCount, 1)
            clickTarget(sw)                       // off again
            compare(store.appearance().updateCheck, false, "the flag persists off")
            compare(wired.enabled, false)
            compare(wired.status, "idle", "the stale result is cleared")
            compare(factoryCount, 1, "opting out fires nothing further")
        }
    }
}
