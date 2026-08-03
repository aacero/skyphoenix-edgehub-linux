import QtQuick

// ─────────────────────────────────────────────────────────────────────────
// NetHub - the single egress gate. EVERY outbound request from a widget goes
// through NetHub.request(); it is the ONLY place in the QML tree that may
// construct an XMLHttpRequest. This makes "no telemetry / local-only" provable
// by construction: there is exactly one choke point to audit, gate, and count.
//
// In production Dashboard.qml creates ONE NetHub and injects it into every net
// widget (so `offline`, the host allowlist and the attestation counters are
// app-global). A widget instantiated standalone (tests) falls back to its own
// NetHub, so the same code path is exercised offline through the xhrFactory seam.
//
// The gate enforces, in order:
//   1. global offline  - a hard kill switch (blocks all remote egress)
//   2. host allowlist   - when non-empty, only these hosts may be reached
//   3. local files pass - file:/relative URLs are not egress, so they are only
//                         subject to nothing (a local KPI file works offline)
// then counts the request (for the attestation surface) and performs it.
// ─────────────────────────────────────────────────────────────────────────
QtObject {
    id: hub

    // Global kill switch. When true, NO remote request is made (local file:
    // reads still work - they are not egress).
    property bool offline: false

    // Host allowlist. Empty = allow any host. Non-empty = only these hosts.
    // (Populated by managed/enterprise config in a later epic; empty by default.)
    property var allowHosts: []

    // Test seam: when set, called instead of `new XMLHttpRequest()`. A caller
    // may also pass a per-request `xhrFactory` in opts (used by widgets that
    // already own the seam, e.g. Weather), which takes precedence.
    property var xhrFactory: null
    // The native QNetworkAccessManager consumes this private request header,
    // removes it before egress, and aborts the transport by byte count. The QML
    // responseText check remains a second parser-boundary guard and a test seam.
    readonly property int maximumTransportResponseBytes: 2097152
    // Qt's QML XMLHttpRequest accepts a `timeout` property but does not emit
    // `ontimeout` reliably on every supported runtime. Every request therefore
    // gets its own QML Timer watchdog. A shared Timer would let one widget
    // cancel or extend another widget's deadline. Overridable so a test can
    // drive the deadline deterministically instead of by wall clock.
    property Component _timeoutTimerFactory: Component {
        Timer { repeat: false }
    }

    // Resolves credential references (E7). Anything with a
    // resolveSecret(raw) -> { ok, value, error, plaintext } method; in the hub
    // that is ConfigBridge (Dashboard injects it). Null in tests/standalone,
    // where _resolveToken falls back - see there for why a ref then FAILS rather
    // than being sent verbatim.
    property var secretResolver: null

    // ── Attestation counters (read-only surface for Diagnostics / enterprise) ──
    property int requests: 0     // requests actually sent
    property int blocked: 0      // requests refused by the gate
    property var byHost: ({})    // { host: count } of sent requests

    // Volatile provider cache and request lease. This is intentionally owned by
    // the app-global gate: Calendar and Now/Next can render the same subscription
    // without each opening a socket. Keys and payloads live in memory only.
    property int sharedRevision: 0
    property var _sharedProviders: ({})

    function _sharedId(kind, key) { return (kind || "") + "\n" + (key || "") }
    function sharedProvider(kind, key) {
        return hub._sharedProviders[hub._sharedId(kind, key)] || null
    }
    function claimSharedProvider(kind, key, owner, reuseMs) {
        var id = hub._sharedId(kind, key)
        var entry = hub._sharedProviders[id]
        var now = Date.now()
        if (entry && entry.loading && entry.owner !== owner) return false
        if (entry && !entry.loading && entry.lastSuccessAt > 0
                && now - entry.lastSuccessAt < Math.max(0, reuseMs || 0))
            return false
        var next = entry || ({})
        next.loading = true
        next.owner = owner
        hub._sharedProviders[id] = next
        hub.sharedRevision++
        return true
    }
    function publishSharedProvider(kind, key, owner, values) {
        var id = hub._sharedId(kind, key)
        var entry = hub._sharedProviders[id] || ({})
        if (entry.loading && entry.owner !== owner) return false
        for (var k in values) entry[k] = values[k]
        entry.loading = false
        entry.owner = null
        hub._sharedProviders[id] = entry
        hub.sharedRevision++
        return true
    }
    function releaseSharedProvider(kind, key, owner, errorText) {
        var id = hub._sharedId(kind, key)
        var entry = hub._sharedProviders[id]
        if (!entry || entry.owner !== owner) return false
        entry.loading = false
        entry.owner = null
        entry.errorText = errorText || ""
        hub._sharedProviders[id] = entry
        hub.sharedRevision++
        return true
    }

    // Is this a LOCAL read (not egress)? This must be an allowlist of local forms,
    // never "anything that isn't http(s)": the old shape treated EVERY unknown
    // scheme as local, so `webcal://…` - a real Apple/iCloud calendar URL - skipped
    // both the offline kill switch and the host allowlist and went straight out.
    // Any scheme we do not positively recognise is therefore NOT local; it is
    // refused by request() rather than waved through as a file read.
    function _isLocal(url) {
        var u = ("" + (url || "")).trim()
        if (!u.length) return false
        if (/^file:/i.test(u)) return true          // explicit local file
        if (/^qrc:/i.test(u)) return true           // bundled resource
        return !_hasScheme(u)                       // a bare/relative path
    }
    // "scheme:" per RFC 3986, plus protocol-relative "//host" (which inherits
    // http(s) and is therefore egress, not a path).
    function _hasScheme(url) {
        return /^[a-z][a-z0-9+.-]*:/i.test(url) || url.indexOf("//") === 0
    }
    // Egress we recognise and are willing to send.
    function _isRemote(url) {
        return /^https?:\/\//i.test(("" + (url || "")).trim())
    }
    function hostOf(url) {
        var m = /^https?:\/\/([^\/?#]+)/i.exec(url || "")
        return m ? m[1].toLowerCase() : ""
    }
    // Whether a URL would be permitted right now (does not send). Useful for UI.
    function isAllowed(url) {
        if (_isLocal(url)) return true
        if (offline) return false
        if (allowHosts && allowHosts.length && allowHosts.indexOf(hostOf(url)) < 0) return false
        return true
    }

    // Returns the host's new tally (so callers/tests can assert the count without
    // reaching into byHost).
    function _bump(host) {
        var m = hub.byHost
        m[host] = (m[host] || 0) + 1
        hub.byHost = m   // reassign so bindings on byHost update
        return m[host]
    }

    // ── Secrets (E7 Phase A) ────────────────────────────────────────────────
    // A stored token is a REFERENCE, not a value. Widgets hand the raw stored
    // string to request({authToken}) and NEVER resolve it themselves: the
    // resolved secret then exists only inside one request() call, so it cannot
    // reach a widget property, the store, or config.toml.
    function _looksLikeRef(s) {
        var t = (s || "").trim()
        return t.indexOf("${env:") === 0 || t.indexOf("file:") === 0 || t.indexOf("secret://") === 0
    }

    // Hosts already warned about a plaintext credential - the warning is about a
    // stored value, not an event, so it must not repeat on every poll.
    property var _plaintextWarned: ({})

    // → { ok, value, error }
    function _resolveToken(raw) {
        if (!raw || !("" + raw).length) return { ok: true, value: "" }
        var r = hub.secretResolver
        if (r && r.resolveSecret) {
            var res = r.resolveSecret("" + raw)
            // Keep working, but say so once: E1 shipped this field, so a user may
            // already have a real token sitting in config.toml.
            if (res.plaintext === true && !hub._plaintextWarned[raw]) {
                hub._plaintextWarned[raw] = true
                console.warn("NetHub: this widget's Bearer token is stored in plain text in " +
                             "config.toml. Use ${env:VAR} or file:/path instead - it is then read " +
                             "only when the request is made and never written to disk.")
            }
            return { ok: !!res.ok, value: res.value || "", error: res.error || "" }
        }
        // No resolver (standalone widget / test harness). A plaintext literal is
        // still usable, but a REF must NOT be sent verbatim: shipping
        // "${env:CI_TOKEN}" to a remote host as a Bearer token both fails
        // confusingly AND discloses the reference. Fail closed instead.
        if (_looksLikeRef(raw))
            return { ok: false, value: "", error: "no secret resolver available to read " + ("" + raw).trim() }
        return { ok: true, value: "" + raw }
    }

    // Resolve a stored capability URL without ever assigning the plaintext URL
    // to a widget property. Legacy literal URLs remain supported for upgrades.
    function _resolveUrl(raw) {
        if (!raw || !("" + raw).length) return { ok: true, value: "" }
        if (!_looksLikeRef(raw)) return { ok: true, value: "" + raw }
        var r = hub.secretResolver
        if (!r || !r.resolveSecret)
            return { ok: false, value: "", error: "no secret resolver is available" }
        var res = r.resolveSecret("" + raw)
        return { ok: !!res.ok, value: res.value || "", error: res.error || "" }
    }

    // request(opts): the single egress entry point.
    //   opts.url        (required) http(s):// for remote, anything else = local file
    //   opts.urlIsSecretRef resolve ${env:}, file:, or secret:// URL references
    //                       inside this call. The resolved URL never reaches the
    //                       widget store or a widget property.
    //   opts.normalizeWebcal map a resolved webcal:// subscription to HTTPS.
    //   opts.method     default "GET"
    //   opts.headers    { name: value } (applied when the XHR supports it)
    //   opts.authToken  the STORED credential (a "${env:}"/"file:" ref or a legacy
    //                   literal) - resolved here and sent as "Authorization:
    //                   Bearer <value>". Pass the stored string, never a resolved
    //                   secret: that is what keeps it out of ui_state.
    //   opts.body       request body (string)
    //   opts.timeout    ms, default 8000
    //   opts.maxResponseBytes native transport and responseText limit, default
    //                         1 MiB and hard-clamped to 2 MiB
    //   opts.allow      per-request host allowlist (augments the global one)
    //   opts.xhrFactory per-request XHR factory (test seam; wins over hub.xhrFactory)
    //   opts.onDone(status, responseText)
    //   opts.onError(reason)  reason ∈ offline | blocked | timeout | "http <n>" |
    //                         open-failed | "secret: <why>"
    // Returns the XHR object (so the caller can track / abort it), or null if
    // the gate refused the request before any socket was opened.
    function request(opts) {
        opts = opts || {}
        var url = opts.url || ""
        if (opts.urlIsSecretRef) {
            var urlSecret = _resolveUrl(url)
            if (!urlSecret.ok) {
                hub.blocked++
                if (opts.onError) opts.onError("url-secret: " + urlSecret.error)
                return null
            }
            url = urlSecret.value
        }
        if (opts.normalizeWebcal && /^webcal:/i.test(url))
            url = url.replace(/^webcal:/i, "https:")
        var local = _isLocal(url)

        // Neither a local read nor http(s): a scheme the gate cannot reason about
        // (webcal:, ftp:, //host, …). Refuse it. Treating it as "local" would skip
        // the kill switch and the allowlist, and guessing it is remote would mean
        // enforcing an allowlist against a host we did not parse. A caller that
        // wants webcal: must map it to https: itself (CalendarWidget does).
        if (!local && !_isRemote(url)) {
            hub.blocked++
            if (opts.onError) opts.onError("unsupported-scheme")
            return null
        }

        if (!local && hub.offline) {
            hub.blocked++
            if (opts.onError) opts.onError("offline")
            return null
        }
        var effAllow = (opts.allow && opts.allow.length) ? opts.allow : hub.allowHosts
        if (!local && effAllow && effAllow.length && effAllow.indexOf(hostOf(url)) < 0) {
            hub.blocked++
            if (opts.onError) opts.onError("blocked")
            return null
        }

        // A bearer token on plain HTTP is exposed to the network. Legacy widgets
        // may still use HTTP without authentication, but adding a credential
        // makes HTTPS mandatory.
        if (!local && /^http:\/\//i.test(url)
                && opts.authToken !== undefined && opts.authToken !== null
                && ("" + opts.authToken).length > 0) {
            hub.blocked++
            if (opts.onError) opts.onError("insecure-auth")
            return null
        }

        // Resolve the credential BEFORE any socket is opened: an unresolvable
        // secret must never become a request (a missing env var would otherwise
        // send an unauthenticated call, which reads as an auth failure from the
        // far end and hides the real cause).
        var headers = opts.headers
        if (opts.authToken !== undefined && opts.authToken !== null) {
            var sec = _resolveToken(opts.authToken)
            if (!sec.ok) {
                hub.blocked++
                if (opts.onError) opts.onError("secret: " + sec.error)
                return null
            }
            if (sec.value.length) {
                // Copy: never mutate the caller's object - headers may be a
                // widget property, which would park the secret in the QML tree.
                headers = {}
                for (var hk in opts.headers) headers[hk] = opts.headers[hk]
                headers["Authorization"] = "Bearer " + sec.value
            }
        }

        hub.requests++
        _bump(local ? "(local)" : hostOf(url))

        var mk = opts.xhrFactory ? opts.xhrFactory : (hub.xhrFactory ? hub.xhrFactory : null)
        var xhr = mk ? mk() : new XMLHttpRequest()
        var requestTimeout = opts.timeout || 8000
        var maxResponseBytes = opts.maxResponseBytes !== undefined
            ? Math.max(1024, Math.min(hub.maximumTransportResponseBytes,
                                     Number(opts.maxResponseBytes)))
            : 1048576
        var settled = false
        var watchdog = null
        function clearWatchdog() {
            if (!watchdog) return
            watchdog.stop()
            watchdog.destroy()
            watchdog = null
        }
        function fail(reason, abortRequest) {
            if (settled) return
            settled = true
            clearWatchdog()
            if (abortRequest && xhr.abort) {
                try { xhr.abort() } catch (e) {}
            }
            if (opts.onError) opts.onError(reason)
        }
        function succeed(status, body) {
            if (settled) return
            settled = true
            clearWatchdog()
            if (opts.onDone) opts.onDone(status, body)
        }
        xhr.timeout = requestTimeout
        xhr.ontimeout = function () { fail("timeout", false) }
        // A caller abort is intentional supersession or teardown, not an HTTP
        // failure. It still must cancel the watchdog and suppress late events.
        xhr.onabort = function () {
            if (settled) return
            settled = true
            clearWatchdog()
        }
        xhr.onreadystatechange = function () {
            if (settled) return
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            var st = xhr.status
            if (xhr.responseText && xhr.responseText.length > maxResponseBytes) {
                fail("response-too-large", false)
                return
            }
            // A local file read succeeds with status 0 (no HTTP layer). A remote
            // request succeeds on ANY 2xx, not just 200: a transforming proxy
            // legitimately answers 203, and CalendarWidget accepted 203/206 before
            // it moved onto the gate - narrowing that here would have silently
            // broken an ICS feed behind a corporate proxy. A 2xx with an empty body
            // (204) still fails the caller's own parse, which is the right layer
            // for that.
            var ok = (st >= 200 && st < 300) || (local && (st === 0 || st === 200) && !!xhr.responseText)
            if (ok) succeed(st, xhr.responseText)
            else fail("http " + st, false)
        }
        try {
            xhr.open(opts.method || "GET", url)
            // Not gated on `mk`: this header is how a widget's own (tighter)
            // cap reaches XeneonNetworkAccessManager::responseByteLimit(), and
            // an absent header silently widens the cap back to the 2 MiB
            // maximum. Skipping it under an injected factory made the only
            // line that carries the cap unreachable by every QML test, so a
            // regression that dropped it would have been invisible on both
            // sides of the seam - the C++ suite asserts the limit GIVEN the
            // header, never that anything sends one.
            if (!local && xhr.setRequestHeader)
                xhr.setRequestHeader("X-Xeneon-Max-Response-Bytes",
                                     String(maxResponseBytes))
            if (headers && xhr.setRequestHeader)
                for (var k in headers) xhr.setRequestHeader(k, headers[k])
            xhr.send(opts.body !== undefined ? opts.body : undefined)
        } catch (e) {
            fail("open-failed", false)
            return xhr
        }
        // Not gated on `mk` either. The watchdog is the ONLY defence against a
        // connection that hangs without the transport ever firing ontimeout,
        // and the only caller that passes abortRequest=true - so gating it on
        // "no injected factory" made the whole mechanism (creation, firing,
        // abort, and clearWatchdog's teardown) unreachable by construction in
        // the test suite. Measured: deleting the entire block left all 213
        // tests across the six NetHub-backed suites green. Tests inject
        // _timeoutTimerFactory or pass a short opts.timeout to drive it.
        if (!settled) {
            watchdog = hub._timeoutTimerFactory.createObject(hub, {
                interval: Math.max(1, Number(requestTimeout))
            })
            watchdog.triggered.connect(function () { fail("timeout", true) })
            watchdog.start()
        }
        return xhr
    }
}
