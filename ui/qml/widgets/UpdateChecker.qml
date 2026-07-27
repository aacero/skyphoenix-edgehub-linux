import QtQuick

// ─────────────────────────────────────────────────────────────────────────
// UpdateChecker - the opt-in "is a newer EdgeHub available?" service (E10).
//
// A QtObject service, not a widget: it has no visual surface of its own.
// Dashboard creates ONE instance and SettingsPanel renders its result line.
// It deliberately contains no Timer - a QtObject child would lean on the
// QtObject default `data` property, and the periodic re-check lives in
// Dashboard's wiring instead, where an Item can host a Timer on every Qt 6.
//
// THE PRIVACY CONTRACT (load-bearing, CI-enforced):
//   • `enabled` defaults to FALSE and nothing here flips it. With a default
//     config the checker never constructs a request - packaging/ci/no-egress.sh
//     launches the hub with defaults and fails the build on a single connect().
//   • When the user opts in, the ONE request goes through NetHub.request()
//     like every other widget (scripts/check_no_raw_xhr.sh forbids a raw
//     XMLHttpRequest anywhere else), so the global kill switch, the host
//     allowlist and the attestation counters all govern it.
//   • The request is a bare GET of the public GitHub releases API. No token,
//     no serial, no config, no telemetry - nothing beyond what a GET carries.
//
// SELF-UPDATE IS OUT OF SCOPE: this only *reports*. Native packages update
// through the distro's package manager; only an AppImage install is pointed
// at the .zsync/download path (see docs/DISTRIBUTION.md "Updates").
// ─────────────────────────────────────────────────────────────────────────
QtObject {
    id: checker

    // The egress gate (Dashboard's app-global NetHub). Without one, check()
    // fails closed - this service never builds its own XMLHttpRequest.
    property var netHub: null

    // THE OPT-IN. Default OFF, and it must stay OFF: defaulting this to true
    // fails the no-egress attestation by design. Dashboard binds it to the
    // persisted appearance flag (`updateCheck`), written by SettingsPanel.
    property bool enabled: false

    // The version currently running - ConfigBridge.appVersion(): a git
    // describe (e.g. "1.0.0-alpha.2-5-gabc1234") or the pkgver for packaged
    // builds; "dev" for syntax-only builds (which compares as unknown).
    property string currentVersion: ""

    // The one URL the check ever touches.
    // The LIST endpoint, not /releases/latest. GitHub's "latest" EXCLUDES
    // pre-releases and 404s when every release is one - exactly the alpha/beta
    // situation, where the check then reported an error instead of a version.
    // Listing lets us pick the newest release on the user's own channel.
    readonly property string releasesUrl:
        "https://api.github.com/repos/skyphoenix-it/skyphoenix-edgehub-linux/releases?per_page=20"

    // Test seam, passed through the gate exactly like the net widgets do.
    property var xhrFactory: null

    // ── Install-type detection ──────────────────────────────────────────────
    // An AppImage sets $APPIMAGE in the process environment; QML cannot read
    // the environment itself, so we reuse the audited ${env:} resolver that
    // ConfigBridge already exposes for credential refs (Dashboard injects it;
    // null in tests/standalone). An unset variable resolves as an error, so
    // absence honestly reads as "package" - never a guess at "appimage".
    property var envResolver: null
    readonly property string installKind: {
        var r = checker.envResolver
        if (r && r.resolveSecret) {
            var res = r.resolveSecret("${env:APPIMAGE}")
            if (res && res.ok === true && ("" + (res.value || "")).length > 0)
                return "appimage"
        }
        return "package"
    }

    // ── Result surface (rendered by SettingsPanel) ──────────────────────────
    // status ∈ idle | checking | uptodate | update | offline | error | unknown
    property string status: "idle"
    property bool updateAvailable: false
    property string latestTag: ""
    property string errorText: ""

    // One human line summarising the state, install-type aware: a package
    // install is told to use its package manager; only an AppImage is pointed
    // at the zsync/download path.
    readonly property string message: {
        if (checker.status === "checking") return "Checking…"
        if (checker.status === "update")
            return "EdgeHub " + checker.latestTag + " is available - " +
                   (checker.installKind === "appimage"
                        ? "update the AppImage via its .zsync (or download it from GitHub Releases)."
                        : "update via your package manager.")
        if (checker.status === "uptodate")
            return "Up to date (" + (checker.currentVersion.length ? checker.currentVersion : "unknown version") + ")."
        if (checker.status === "offline") return checker.errorText
        if (checker.status === "error") return checker.errorText
        if (checker.status === "unknown")
            return "Latest release is " + checker.latestTag + " - this build (" +
                   (checker.currentVersion.length ? checker.currentVersion : "dev") +
                   ") has no comparable version."
        return checker.enabled ? "Not checked yet." : "Off - EdgeHub never checks on its own."
    }

    property var _xhr: null

    // Opting in checks once immediately; opting out aborts anything in flight
    // and clears the result, so a stale "update available" line cannot outlive
    // the user's consent.
    onEnabledChanged: {
        if (checker.enabled) {
            checker.check()
        } else {
            if (checker._xhr) { checker._xhr.abort(); checker._xhr = null }
            checker.status = "idle"
            checker.updateAvailable = false
            checker.latestTag = ""
            checker.errorText = ""
        }
    }
    Component.onCompleted: if (checker.enabled) checker.check()

    // ── The check ───────────────────────────────────────────────────────────
    function check() {
        if (!checker.enabled) return   // opt-in is load-bearing: never fire when off
        if (!checker.netHub) {
            checker.status = "error"
            checker.errorText = "No egress gate available - check skipped."
            return
        }
        if (checker._xhr) { checker._xhr.abort(); checker._xhr = null }
        checker.status = "checking"
        checker.errorText = ""
        checker._xhr = checker.netHub.request({
            url: checker.releasesUrl,
            timeout: 10000,
            xhrFactory: checker.xhrFactory,
            onDone: function (st, body) {
                checker._xhr = null
                checker._applyResponse(body)
            },
            onError: function (reason) {
                checker._xhr = null
                checker.updateAvailable = false
                if (reason === "offline") {
                    checker.status = "offline"
                    checker.errorText = "Blocked: the global offline switch is on."
                } else if (reason === "blocked") {
                    checker.status = "offline"
                    checker.errorText = "Blocked by the host allowlist."
                } else {
                    checker.status = "error"
                    checker.errorText = "Check failed (" + reason + ")."
                }
            }
        })
    }

    function _applyResponse(body) {
        var doc
        try { doc = JSON.parse(body) } catch (e) {
            checker.updateAvailable = false
            checker.status = "error"
            checker.errorText = "Check failed (malformed response)."
            return
        }
        var tag = Array.isArray(doc)
                  ? checker._pickRelease(doc)
                  : ((doc && typeof doc.tag_name === "string") ? doc.tag_name.trim() : "")
        if (!tag.length) {
            checker.updateAvailable = false
            checker.status = "error"
            checker.errorText = "Check failed (no tag_name in response)."
            return
        }
        checker.latestTag = tag
        var cmp = compareVersions(checker.currentVersion, tag)
        if (cmp === null) {
            // "dev" or an unparsable tag: report, never nag. Claiming an update
            // against a version we cannot order would be a lie half the time.
            checker.updateAvailable = false
            checker.status = "unknown"
        } else if (cmp < 0) {
            checker.updateAvailable = true
            checker.status = "update"
        } else {
            checker.updateAvailable = false
            checker.status = "uptodate"
        }
    }

    // ── Version ordering (SemVer §11) ───────────────────────────────────────
    // A naive string compare says "v1.0.0-alpha.2" > "v1.0.0" - exactly wrong.
    // Rules pinned by tests/ui/tst_update_checker.qml:
    //   • a pre-release sorts BEFORE its release (1.0.0-rc.1 < 1.0.0)
    //   • pre-release identifiers compare dot-by-dot; numeric ones numerically
    //     (alpha.2 < alpha.10), numeric < alphanumeric, else lexically
    //     (alpha < beta < rc)
    //   • a prefix pre-release sorts lower (alpha < alpha.1)
    //   • build metadata (+…) is ignored; a git-describe suffix
    //     ("-5-gabc1234") rides along as extra identifiers, so a build AHEAD
    //     of its tag is not told to "update" to that same tag.
    // Returns -1 / 0 / 1, or null when either side has no parsable version
    // (e.g. "dev") - null means "cannot honestly order these".
    // Newest release the user should be OFFERED, from the list endpoint.
    // Channel rule: a pre-release is only offered when the RUNNING build is
    // itself a pre-release - a stable user is never pushed onto an alpha, and an
    // alpha user still gets alpha updates (without this, every check during the
    // whole alpha/beta period fails). Drafts are never offered.
    function _pickRelease(list) {
        var onPre = checker._isPrerelease(checker.currentVersion)
        var best = ""
        for (var i = 0; i < list.length; i++) {
            var r = list[i]
            if (!r || r.draft === true) continue
            var t = (typeof r.tag_name === "string") ? r.tag_name.trim() : ""
            if (!t.length) continue
            // A stable tag may temporarily be public with GitHub's prerelease
            // flag while its versioned AppImage update is certified. It is not
            // an offerable release until promotion clears that flag. This also
            // protects alpha, beta, and RC users, for whom the generic channel
            // rule below would otherwise expose the staged stable candidate.
            if (r.prerelease === true && !checker._isPrerelease(t)) continue
            if (r.prerelease === true && !onPre) continue
            if (best === "" || compareVersions(best, t) === -1) best = t
        }
        return best
    }

    // Is this version string a pre-release (has SemVer pre-release identifiers)?
    // A git-describe build like v1.0.0-alpha.2-220-gabc rides its identifiers, so
    // a dev build off an alpha tag correctly counts as pre-release.
    function _isPrerelease(v) {
        var p = parseVersion(v)
        return !!(p && p.pre && p.pre.length)
    }

    function parseVersion(s) {
        var t = ("" + (s || "")).trim().replace(/^v/i, "")
        var m = /^(\d+)\.(\d+)(?:\.(\d+))?(?:-([0-9A-Za-z.\-]+))?(?:\+[0-9A-Za-z.\-]+)?$/.exec(t)
        if (!m) return null
        return {
            nums: [parseInt(m[1], 10), parseInt(m[2], 10),
                   m[3] !== undefined ? parseInt(m[3], 10) : 0],
            pre: m[4] !== undefined ? m[4].split(".") : null
        }
    }

    function compareVersions(a, b) {
        var va = parseVersion(a)
        var vb = parseVersion(b)
        if (!va || !vb) return null
        for (var i = 0; i < 3; i++)
            if (va.nums[i] !== vb.nums[i]) return va.nums[i] < vb.nums[i] ? -1 : 1
        return _comparePre(va.pre, vb.pre)
    }

    function _comparePre(pa, pb) {
        if (!pa && !pb) return 0
        if (!pa) return 1    // release > any of its pre-releases
        if (!pb) return -1
        var n = Math.max(pa.length, pb.length)
        for (var i = 0; i < n; i++) {
            if (i >= pa.length) return -1   // shorter prefix sorts lower
            if (i >= pb.length) return 1
            var x = pa[i], y = pb[i]
            var xNum = /^\d+$/.test(x)
            var yNum = /^\d+$/.test(y)
            if (xNum && yNum) {
                var xi = parseInt(x, 10), yi = parseInt(y, 10)
                if (xi !== yi) return xi < yi ? -1 : 1
            } else if (xNum !== yNum) {
                return xNum ? -1 : 1        // numeric identifiers sort lower
            } else if (x !== y) {
                return x < y ? -1 : 1       // alpha < beta < rc, lexically
            }
        }
        return 0
    }
}
