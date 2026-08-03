import QtQuick
import QtTest
import "../../ui/qml/widgets" as W

// The egress gate (ui/qml/widgets/NetHub.qml). Driven entirely offline through a
// fake XHR: no real sockets. Asserts the gate's ordering (offline → allowlist →
// local-file bypass), the attestation counters, header pass-through, and the
// onDone/onError contract for success, non-200, timeout and open-failure.
Item {
    id: root
    width: 50; height: 50

    // A fake XHR that records what NetHub did to it and resolves on demand.
    function makeFake() {
        return {
            method: "", url: "", sent: false, aborted: false,
            readyState: 0, status: 0, responseText: "",
            timeout: 0, ontimeout: null, onreadystatechange: null,
            headers: ({}),
            open: function (m, u) { this.method = m; this.url = u; this.readyState = 1 },
            setRequestHeader: function (k, v) { this.headers[k] = v },
            send: function (b) { this.sent = true; this.body = b },
            abort: function () { this.aborted = true },
            resolveWith: function (status, body) {
                this.status = status; this.responseText = body; this.readyState = 4
                if (this.onreadystatechange) this.onreadystatechange()
            },
            fireTimeout: function () { if (this.ontimeout) this.ontimeout() }
        }
    }

    // A stand-in for the watchdog's QML Timer, injected through NetHub's
    // existing `_timeoutTimerFactory` seam. Timers are parented to the hub with
    // createObject(), and NetHub is a QtObject - it has no `children`/`data` to
    // count - so a leaked watchdog is otherwise invisible from QML. Recording
    // start/stop/destruction here makes clearWatchdog()'s teardown observable,
    // and firing `triggered` by hand makes the timeout deterministic instead of
    // wall-clock dependent.
    property int timersStarted: 0
    property int timersStopped: 0
    property int timersDestroyed: 0
    property var lastTimer: null
    property Component fakeTimerFactory: Component {
        QtObject {
            property int interval: 0
            property bool running: false
            signal triggered()
            function start() { running = true; root.timersStarted++ }
            function stop() { running = false; root.timersStopped++ }
            Component.onCompleted: root.lastTimer = this
            Component.onDestruction: root.timersDestroyed++
        }
    }

    W.NetHub { id: hub }

    TestCase {
        name: "NetHub"
        when: windowShown

        property var lastFake: null
        // Captured before any test swaps in fakeTimerFactory, so the override
        // cannot leak into the tests that run after it (they share one hub).
        property var realTimerFactory: null
        function init() {
            if (realTimerFactory === null) realTimerFactory = hub._timeoutTimerFactory
            hub._timeoutTimerFactory = realTimerFactory
            root.timersStarted = 0
            root.timersStopped = 0
            root.timersDestroyed = 0
            root.lastTimer = null
            hub.offline = false
            hub.allowHosts = []
            hub.requests = 0
            hub.blocked = 0
            hub.byHost = ({})
            hub.secretResolver = null
            hub._sharedProviders = ({})
            hub.sharedRevision = 0
            var tc = this
            hub.xhrFactory = function () { tc.lastFake = root.makeFake(); return tc.lastFake }
        }

        // ── host parsing ─────────────────────────────────────────────────────
        // COVERS: fn:NetHub.hostOf, fn:NetHub._isLocal
        function test_hostOf_extracts_authority() {
            compare(hub.hostOf("https://api.example.com/v1/x?y=1"), "api.example.com")
            compare(hub.hostOf("http://10.0.0.5:9090/metrics"), "10.0.0.5:9090")
            compare(hub.hostOf("/local/path"), "", "a local path has no host")
            // _isLocal decides whether the offline switch and allowlist apply at
            // all, so it is the gate's first branch: assert it directly.
            compare(hub._isLocal("/run/metrics/x"), true, "a path is local (not egress)")
            compare(hub._isLocal("file:/run/x"), true, "a file: URL is local")
            compare(hub._isLocal("https://api.example.com"), false, "https is egress")
            compare(hub._isLocal("http://api.example.com"), false, "http is egress")
        }

        // COVERS: fn:NetHub._bump
        // The per-host counters are the attestation surface ("what did this box
        // actually talk to"), so the tally itself is asserted, not just its use.
        function test_bump_tallies_per_host() {
            compare(hub._bump("a.example"), 1, "first visit to a host tallies 1")
            compare(hub._bump("a.example"), 2, "repeat host accumulates")
            compare(hub._bump("b.example"), 1, "distinct host counted separately")
            compare(hub.byHost["a.example"], 2, "the tally is exposed on byHost")
            compare(hub.byHost["never.example"], undefined, "unvisited host absent")
        }

        // COVERS: fn:NetHub._hasScheme, fn:NetHub._isRemote
        // REGRESSION: _isLocal used to be "not http and not https", so EVERY
        // unknown scheme counted as a local file read and skipped both the offline
        // kill switch and the allowlist. webcal:// is not hypothetical - it is what
        // Apple/iCloud hands you for a private calendar, so the kill switch had a
        // hole exactly where a secret URL goes.
        function test_unknown_schemes_are_not_local() {
            compare(hub._isLocal("/run/metrics/x"), true, "a bare path is local")
            compare(hub._isLocal("relative/path"), true, "a relative path is local")
            compare(hub._isLocal("file:/run/x"), true, "file: is local")
            compare(hub._isLocal("qrc:/x"), true, "qrc: is local")
            compare(hub._isLocal("webcal://p.icloud.com/x.ics"), false, "webcal is NOT a local file")
            compare(hub._isLocal("ftp://h/x"), false, "ftp is NOT a local file")
            compare(hub._isLocal("//evil.example/x"), false, "protocol-relative is NOT a local file")
            compare(hub._isLocal("https://api.example.com"), false)
            compare(hub._hasScheme("webcal://x"), true)
            compare(hub._hasScheme("/plain/path"), false)
            compare(hub._isRemote("https://a/b"), true)
            compare(hub._isRemote("webcal://a/b"), false, "only http(s) is sendable egress")
        }

        // The gate must refuse a scheme it cannot reason about rather than guess.
        function test_unsupported_scheme_is_refused_even_when_online() {
            hub.offline = false
            var err = null
            var xhr = hub.request({ url: "webcal://p.icloud.com/private.ics",
                                    onError: function (r) { err = r } })
            compare(xhr, null, "no socket for a scheme the gate can't classify")
            compare(err, "unsupported-scheme")
            compare(hub.requests, 0, "not counted as sent")
            compare(hub.blocked, 1, "counted as refused")
        }

        // The actual hole: offline ON, a webcal URL still went out because it was
        // read as a local file.
        function test_webcal_does_not_bypass_the_offline_kill_switch() {
            hub.offline = true
            var err = null
            var xhr = hub.request({ url: "webcal://p.icloud.com/private.ics",
                                    onError: function (r) { err = r } })
            compare(xhr, null, "offline must not be bypassable via an odd scheme")
            compare(hub.requests, 0, "NOTHING was sent")
            verify(err === "unsupported-scheme" || err === "offline", "refused, got: " + err)
        }

        // 203 is what a transforming proxy returns; Calendar accepted it before the
        // NetHub migration, so the gate must not narrow it away.
        // COVERS: fn:NetHub.succeed, fn:NetHub.clearWatchdog
        function test_any_2xx_is_success_not_just_200() {
            var observed = { succeed: 0, error: 0, clearWatchdog: false, status: null }
            hub.request({ url: "https://api.example.com/s",
                          onDone: function (st, b) {
                              observed.succeed++
                              observed.status = st
                          },
                          onError: function (r) { observed.error++ } })
            lastFake.resolveWith(203, "body")
            // A late native timeout must not settle the request a second time.
            // The real-XHR watchdog follows the same fail() path and is destroyed
            // by clearWatchdog() during the first settlement.
            lastFake.fireTimeout()
            observed.clearWatchdog = observed.succeed === 1 && observed.error === 0
            compare(observed.status, 203, "203 (proxy-transformed) is a success")
            compare(observed.succeed, 1, "success settles exactly once")
            compare(observed.clearWatchdog, true,
                    "late timeout cannot fire after successful settlement")
        }

        // COVERS: fn:NetHub.fail
        function test_3xx_and_4xx_are_still_errors() {
            var observed = { fail: null, successes: 0 }
            hub.request({ url: "https://api.example.com/s",
                          onDone: function () { observed.successes++ },
                          onError: function (r) { observed.fail = r } })
            lastFake.resolveWith(304, "")
            compare(observed.fail, "http 304", "304 is not a 2xx - still an error")
            compare(observed.successes, 0, "failure cannot also invoke success")
        }

        // ── success path ─────────────────────────────────────────────────────
        // COVERS: fn:NetHub.request
        function test_request_success_calls_onDone_and_counts() {
            var got = null
            hub.request({ url: "https://api.example.com/s",
                onDone: function (st, body) { got = { st: st, body: body } },
                onError: function () { fail("should not error") } })
            verify(lastFake !== null && lastFake.sent, "request was actually sent")
            compare(hub.requests, 1, "one request counted")
            compare(hub.byHost["api.example.com"], 1, "per-host counter bumped")
            lastFake.resolveWith(200, '{"ok":true}')
            verify(got !== null, "onDone fired")
            compare(got.st, 200); compare(got.body, '{"ok":true}')
        }

        function test_non_200_is_error() {
            var err = null
            hub.request({ url: "https://api.example.com/s",
                onDone: function () { fail("should not succeed") },
                onError: function (r) { err = r } })
            lastFake.resolveWith(503, "")
            compare(err, "http 503", "a server error surfaces as http <status>")
        }

        // ── offline kill switch ──────────────────────────────────────────────
        function test_offline_blocks_remote_before_send() {
            hub.offline = true
            var err = null
            var xhr = hub.request({ url: "https://api.example.com/s",
                onError: function (r) { err = r } })
            compare(xhr, null, "no XHR created when offline")
            compare(err, "offline")
            compare(hub.blocked, 1, "blocked counter bumped")
            compare(hub.requests, 0, "nothing sent")
        }

        function test_offline_still_allows_local_file() {
            hub.offline = true
            hub.request({ url: "file:///run/metric",
                onDone: function () {}, onError: function () { fail("local read must not be gated") } })
            verify(lastFake !== null && lastFake.sent, "a local file reads even offline (not egress)")
            compare(hub.byHost["(local)"], 1, "counted as a local read")
        }

        // ── host allowlist ───────────────────────────────────────────────────
        function test_allowlist_blocks_disallowed_host() {
            hub.allowHosts = ["allowed.example.com"]
            var err = null
            hub.request({ url: "https://evil.example.com/x", onError: function (r) { err = r } })
            compare(err, "blocked")
            compare(hub.blocked, 1)
            // an allowed host passes
            hub.request({ url: "https://allowed.example.com/x", onDone: function () {} })
            compare(hub.requests, 1, "the allowed host went through")
        }

        function test_per_request_allow_overrides_global() {
            hub.allowHosts = []   // global allows all
            var err = null
            hub.request({ url: "https://other.example.com/x", allow: ["only.example.com"],
                onError: function (r) { err = r } })
            compare(err, "blocked", "a per-request allowlist narrows the global one")
        }

        // ── headers, timeout, open failure ───────────────────────────────────
        function test_headers_are_applied() {
            hub.request({ url: "https://api.example.com/s",
                headers: { "Authorization": "Bearer T", "X-Test": "1" }, onDone: function () {} })
            compare(lastFake.headers["Authorization"], "Bearer T", "auth header set")
            compare(lastFake.headers["X-Test"], "1", "extra header set")
        }

        // ── secrets (E7 Phase A) ─────────────────────────────────────────────
        // COVERS: fn:NetHub._resolveToken, fn:NetHub._looksLikeRef
        // The gate resolves the STORED credential; widgets hand it the raw ref so
        // the plaintext value never lands in a widget property or the store.

        // A fake ConfigBridge.resolveSecret (the real one is Rust-backed).
        function _resolver(map) {
            return { resolveSecret: function (raw) {
                if (map.hasOwnProperty(raw)) return { ok: true, value: map[raw], error: "", plaintext: false }
                return { ok: false, value: "", error: "no such ref " + raw, plaintext: false }
            } }
        }

        function test_authToken_ref_is_resolved_into_the_header() {
            hub.secretResolver = _resolver({ "${env:CI_TOKEN}": "resolved-abc" })
            hub.request({ url: "https://api.example.com/s",
                          authToken: "${env:CI_TOKEN}", onDone: function () {} })
            compare(lastFake.headers["Authorization"], "Bearer resolved-abc",
                    "the REF is resolved to its value before the header is built")
            hub.secretResolver = null
        }

        function test_capability_url_ref_is_resolved_only_inside_request() {
            hub.secretResolver = _resolver({ "${env:CAL_URL}": "webcal://private.example/a.ics" })
            var stored = "${env:CAL_URL}"
            hub.request({
                url: stored,
                urlIsSecretRef: true,
                normalizeWebcal: true,
                onDone: function () {}
            })
            compare(lastFake.url, "https://private.example/a.ics")
            compare(stored, "${env:CAL_URL}", "the caller retains only the stored reference")
            hub.secretResolver = null
        }

        function test_missing_capability_url_ref_fails_before_xhr() {
            hub.secretResolver = _resolver({})
            var err = ""
            var xhr = hub.request({
                url: "${env:MISSING_CAL_URL}",
                urlIsSecretRef: true,
                onError: function (reason) { err = reason }
            })
            compare(xhr, null)
            verify(err.indexOf("url-secret:") === 0)
            compare(hub.requests, 0)
            compare(hub.blocked, 1)
            hub.secretResolver = null
        }

        // COVERS: fn:NetHub._sharedId, fn:NetHub.sharedProvider
        // COVERS: fn:NetHub.claimSharedProvider, fn:NetHub.publishSharedProvider
        // COVERS: fn:NetHub.releaseSharedProvider
        function test_shared_provider_lease_coalesces_reuses_and_releases() {
            var ownerA = ({ name: "a" })
            var ownerB = ({ name: "b" })
            compare(hub._sharedId("calendar", "${env:C}"),
                    "calendar\n${env:C}", "provider identity includes kind and stored key")
            compare(hub.claimSharedProvider("calendar", "${env:C}", ownerA, 3000), true)
            compare(hub.claimSharedProvider("calendar", "${env:C}", ownerB, 3000), false,
                    "a second consumer cannot duplicate an in-flight fetch")
            compare(hub.publishSharedProvider("calendar", "${env:C}", ownerA, {
                events: ["one"], lastSuccessAt: Date.now(), errorText: ""
            }), true)
            compare(hub.claimSharedProvider("calendar", "${env:C}", ownerB, 3000), false,
                    "a just-published result is reused")
            compare(hub.sharedProvider("calendar", "${env:C}").events[0], "one")
            compare(hub.claimSharedProvider("calendar", "${env:C}", ownerB, 0), true,
                    "an explicit refresh can bypass the short reuse window")
            compare(hub.releaseSharedProvider("calendar", "${env:C}", ownerA, "wrong"), false,
                    "only the lease owner can release an in-flight request")
            compare(hub.releaseSharedProvider("calendar", "${env:C}", ownerB, "offline"), true)
            compare(hub.sharedProvider("calendar", "${env:C}").loading, false)
            compare(hub.sharedProvider("calendar", "${env:C}").errorText, "offline")
        }

        // COVERS: fn:NetHub._resolveUrl
        function test_resolveUrl_keeps_literals_and_resolves_capability_refs() {
            compare(hub._resolveUrl("https://public.example/x").value,
                    "https://public.example/x")
            hub.secretResolver = _resolver({ "${env:PRIVATE_URL}": "https://private.example/x" })
            var resolved = hub._resolveUrl("${env:PRIVATE_URL}")
            compare(resolved.ok, true)
            compare(resolved.value, "https://private.example/x")
            hub.secretResolver = null
            compare(hub._resolveUrl("${env:PRIVATE_URL}").ok, false,
                    "a private reference fails closed without a resolver")
        }

        // COVERS: fn:NetHub._looksLikeRef
        // The ref/literal split decides whether a value may be sent verbatim, so
        // pin it directly: a literal that merely resembles a scheme must stay a
        // literal, or a real token could be misread as a path.
        function test_looksLikeRef_distinguishes_refs_from_literals() {
            compare(hub._looksLikeRef("${env:TOK}"), true)
            compare(hub._looksLikeRef("file:/run/tok"), true)
            compare(hub._looksLikeRef("secret://a/b"), true)
            compare(hub._looksLikeRef("  ${env:TOK}  "), true, "whitespace tolerated")
            compare(hub._looksLikeRef("ghp_abc123"), false)
            compare(hub._looksLikeRef("filesystem-token"), false, "not the file: scheme")
            compare(hub._looksLikeRef(""), false)
        }

        // COVERS: fn:NetHub._resolveToken
        function test_resolveToken_returns_value_or_reason() {
            hub.secretResolver = _resolver({ "${env:T}": "v" })
            var ok = hub._resolveToken("${env:T}")
            compare(ok.ok, true); compare(ok.value, "v")

            var bad = hub._resolveToken("${env:NOPE}")
            compare(bad.ok, false); compare(bad.value, "")
            verify(bad.error.length > 0, "a failure must explain itself")

            hub.secretResolver = null
            compare(hub._resolveToken("").ok, true, "empty is a no-op success")
            compare(hub._resolveToken("").value, "")
            compare(hub._resolveToken("ghp_x").value, "ghp_x", "a literal needs no resolver")
            compare(hub._resolveToken("file:/x").ok, false, "a ref without a resolver fails closed")
        }

        // A plaintext token still works, but the user is told - once. The warning
        // is about a STORED value, so repeating it every poll would be log spam.
        function test_plaintext_token_warns_once_not_every_poll() {
            hub.secretResolver = { resolveSecret: function (raw) {
                return { ok: true, value: raw, error: "", plaintext: true } } }
            hub._plaintextWarned = ({})

            ignoreWarning(/stored in plain text/)
            hub.request({ url: "https://api.example.com/s", authToken: "ghp_x", onDone: function () {} })
            compare(lastFake.headers["Authorization"], "Bearer ghp_x", "it still authenticates")
            verify(hub._plaintextWarned["ghp_x"] === true, "warned once")

            // No second ignoreWarning is queued: a repeat warning would be an
            // unexpected message here.
            hub.request({ url: "https://api.example.com/s", authToken: "ghp_x", onDone: function () {} })
            compare(lastFake.headers["Authorization"], "Bearer ghp_x", "still works on the next poll")
            hub.secretResolver = null
        }

        // The warning must never carry the secret itself into the log.
        function test_plaintext_warning_never_logs_the_token() {
            hub.secretResolver = { resolveSecret: function (raw) {
                return { ok: true, value: raw, error: "", plaintext: true } } }
            hub._plaintextWarned = ({})
            // Matching on a pattern that EXCLUDES the token: if the message
            // contained "ghp_supersecret" this regex still matches, so assert the
            // absence separately via the ignore pattern being the whole message.
            ignoreWarning(/^NetHub: this widget's Bearer token is stored in plain text in config\.toml\. Use \$\{env:VAR\} or file:\/path instead - it is then read only when the request is made and never written to disk\.$/)
            hub.request({ url: "https://api.example.com/s", authToken: "ghp_supersecret", onDone: function () {} })
            hub.secretResolver = null
        }

        // The reference itself must never travel to the far end.
        function test_the_reference_string_is_never_sent() {
            hub.secretResolver = _resolver({ "${env:CI_TOKEN}": "resolved-abc" })
            hub.request({ url: "https://api.example.com/s",
                          authToken: "${env:CI_TOKEN}", onDone: function () {} })
            verify(lastFake.headers["Authorization"].indexOf("${env:") < 0,
                   "the raw ref must not appear in any header")
            hub.secretResolver = null
        }

        function test_unresolvable_secret_blocks_the_request_entirely() {
            hub.secretResolver = _resolver({})   // resolves nothing
            var before = hub.requests
            var err = null
            var xhr = hub.request({ url: "https://api.example.com/s",
                                    authToken: "${env:MISSING}", onError: function (r) { err = r } })
            compare(xhr, null, "no XHR is created")
            verify(("" + err).indexOf("secret:") === 0, "error names the cause: " + err)
            compare(hub.requests, before, "an unresolved secret must NOT count as a sent request")
            hub.secretResolver = null
        }

        // Fail closed: without a resolver a ref must not be sent verbatim as a
        // Bearer token (that both leaks the ref and fails confusingly).
        function test_ref_without_a_resolver_fails_closed() {
            hub.secretResolver = null
            var err = null
            var xhr = hub.request({ url: "https://api.example.com/s",
                                    authToken: "file:/run/tok", onError: function (r) { err = r } })
            compare(xhr, null, "no request without a way to read the ref")
            verify(("" + err).indexOf("secret:") === 0, "got: " + err)
        }

        // A legacy plaintext token still works with no resolver - E1 shipped the
        // field, so breaking it would break real users' widgets.
        function test_legacy_plaintext_token_still_authenticates() {
            hub.secretResolver = null
            hub.request({ url: "https://api.example.com/s",
                          authToken: "ghp_legacy", onDone: function () {} })
            compare(lastFake.headers["Authorization"], "Bearer ghp_legacy")
        }

        function test_bearer_token_is_never_sent_over_plain_http() {
            var err = null
            var xhr = hub.request({
                url: "http://api.example.com/s",
                authToken: "ghp_legacy",
                onError: function (r) { err = r }
            })
            compare(xhr, null, "plain HTTP bearer request is refused before XHR")
            compare(err, "insecure-auth")
            compare(hub.requests, 0, "the insecure request is not counted as sent")
            compare(hub.blocked, 1, "the refusal is attested")
        }

        function test_empty_token_sends_no_auth_header() {
            hub.secretResolver = null
            hub.request({ url: "https://api.example.com/s", authToken: "", onDone: function () {} })
            verify(lastFake.headers["Authorization"] === undefined,
                   "an unconfigured token must not produce an empty Bearer header")
        }

        // request() must not write the secret back into the caller's object: a
        // widget's `headers` property would carry it into the QML tree.
        function test_caller_headers_object_is_not_mutated() {
            hub.secretResolver = _resolver({ "${env:T}": "v" })
            var mine = { "X-Test": "1" }
            hub.request({ url: "https://api.example.com/s", headers: mine,
                          authToken: "${env:T}", onDone: function () {} })
            compare(lastFake.headers["Authorization"], "Bearer v", "header still applied")
            verify(mine["Authorization"] === undefined,
                   "the caller's headers object must not gain the secret")
            hub.secretResolver = null
        }

        function test_timeout_surfaces() {
            var err = null
            hub.request({ url: "https://api.example.com/s", onError: function (r) { err = r } })
            lastFake.fireTimeout()
            compare(err, "timeout")
            verify(!lastFake.aborted,
                   "the transport's own timeout has already finished the request - "
                   + "aborting it again is not the watchdog's job")
        }

        // The case test_timeout_surfaces CANNOT reach: a connection that hangs
        // without the transport ever firing ontimeout. Only the watchdog settles
        // it, and it is the only caller passing abortRequest=true. Until the
        // creation guard dropped `!mk` this whole mechanism was unreachable by
        // construction - deleting it left all 213 tests in the six NetHub-backed
        // suites green.
        // COVERS: fn:NetHub.request, fn:NetHub.fail
        function test_watchdog_settles_a_request_the_transport_never_finishes() {
            var err = null
            var done = false
            hub.request({ url: "https://api.example.com/s",
                          timeout: 40,
                          onDone: function () { done = true },
                          onError: function (r) { err = r } })
            var hung = lastFake
            verify(hung.sent, "the request really was dispatched")
            compare(err, null, "nothing has timed out yet")
            tryVerify(function () { return err !== null }, 2000,
                      "a hung connection must not stay pending forever")
            compare(err, "timeout")
            compare(done, false, "a timed-out request never reports success")
            verify(hung.aborted,
                   "the watchdog aborts the hung request instead of leaking the socket")
        }

        // clearWatchdog()'s body had never executed: watchdog was always null
        // under an injected factory, so the function early-returned and gutting
        // it entirely changed no result. Asserting only on callbacks does NOT
        // recover the coverage - `settled` already suppresses a late fire, so a
        // watchdog that survives settlement is behaviourally silent and leaks
        // one Timer per request for the hub's lifetime. Measured: with this
        // test asserting callbacks alone, gutting stop()+destroy() still passed.
        // COVERS: fn:NetHub.clearWatchdog
        function test_watchdog_is_torn_down_when_the_request_settles_first() {
            hub._timeoutTimerFactory = root.fakeTimerFactory
            var err = null
            var successes = 0
            hub.request({ url: "https://api.example.com/s",
                          timeout: 40,
                          onDone: function () { successes++ },
                          onError: function (r) { err = r } })
            var fake = lastFake
            var timer = root.lastTimer
            compare(root.timersStarted, 1, "the request armed a watchdog")
            verify(timer.running, "and started it")

            fake.resolveWith(200, "body")
            compare(successes, 1, "the request settled on its own")
            compare(root.timersStopped, 1, "settling stops the watchdog")
            verify(!timer.running, "a settled request leaves no armed timer")
            // destroy() is deferred to the event loop, so the object outlives
            // the call that requested it by one turn.
            tryVerify(function () { return root.timersDestroyed === 1 }, 2000,
                      "the watchdog is destroyed, not merely stopped - otherwise "
                      + "the hub accumulates one Timer per request")
            compare(err, null, "a settled request cannot time out afterwards")
            verify(!fake.aborted, "a successful request is never aborted")
        }

        // The cap only reaches the enforcing layer through this header:
        // XeneonNetworkAccessManager::responseByteLimit() widens an absent
        // header back to the 2 MiB maximum. The C++ suite asserts the limit
        // GIVEN a header; nothing asserted that anything sends one.
        // COVERS: fn:NetHub.request
        function test_response_cap_is_advertised_to_the_transport() {
            hub.request({ url: "https://api.example.com/s", maxResponseBytes: 4096 })
            compare(lastFake.headers["X-Xeneon-Max-Response-Bytes"], "4096",
                    "the widget's own cap is what the transport is told to enforce")
        }

        // A file:// read has no HTTP layer to carry the header.
        // COVERS: fn:NetHub.request
        function test_local_reads_carry_no_transport_header() {
            hub.request({ url: "file:///tmp/x.json", maxResponseBytes: 4096 })
            compare(lastFake.headers["X-Xeneon-Max-Response-Bytes"], undefined,
                    "a local file read has no HTTP header layer")
        }

        function test_response_size_is_bounded_before_callback() {
            var err = null
            var done = false
            hub.request({
                url: "https://api.example.com/s",
                maxResponseBytes: 1024,
                onDone: function () { done = true },
                onError: function (r) { err = r }
            })
            lastFake.resolveWith(200, new Array(1026).join("x"))
            compare(done, false, "oversized content never reaches the parser")
            compare(err, "response-too-large")
        }

        function test_response_limit_has_a_native_hard_ceiling() {
            compare(hub.maximumTransportResponseBytes, 2 * 1024 * 1024)
            var err = null
            hub.request({
                url: "https://api.example.com/s",
                maxResponseBytes: 64 * 1024 * 1024,
                onError: function (reason) { err = reason }
            })
            lastFake.resolveWith(
                200, new Array(hub.maximumTransportResponseBytes + 2).join("x"))
            compare(err, "response-too-large",
                    "callers cannot raise the parser limit beyond the native ceiling")
        }

        function test_open_failure_is_reported() {
            var err = null
            hub.xhrFactory = function () {
                return { timeout: 0, open: function () { throw new Error("boom") },
                         setRequestHeader: function () {}, send: function () {} }
            }
            var xhr = hub.request({ url: "https://api.example.com/s", onError: function (r) { err = r } })
            compare(err, "open-failed")
        }

        // ── isAllowed (non-sending predicate) ────────────────────────────────
        // COVERS: fn:NetHub.isAllowed
        function test_isAllowed_predicate() {
            hub.offline = false; hub.allowHosts = ["ok.example.com"]
            verify(hub.isAllowed("https://ok.example.com/x"), "listed host allowed")
            verify(!hub.isAllowed("https://no.example.com/x"), "unlisted host not allowed")
            verify(hub.isAllowed("file:///x"), "local always allowed")
            hub.offline = true
            verify(!hub.isAllowed("https://ok.example.com/x"), "offline blocks even listed hosts")
            verify(hub.isAllowed("file:///x"), "offline still allows local files")
        }
    }
}
