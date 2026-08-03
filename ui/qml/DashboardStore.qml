import QtQuick

// ─────────────────────────────────────────────────────────────────────────
// DashboardStore - the single source of truth for the dashboard.
//
// Owns the persisted UI-state document (layout + per-widget settings +
// appearance) and mediates all reads/writes. Persistence goes through the C++
// `configBridge` (→ Rust config, atomic XDG write). Reactivity is provided by
// `revision`: every mutation bumps it, so widgets that bind through it re-read
// automatically - this is what lets a tile and its expanded overlay (two
// separate instances) share the same live state.
//
// Document schema (JSON):
//   {
//     "version": 1,
//     "appearance": { themeMode, accent, glass, glow, reduceMotion },
//     "pages": [ { "name": "System", "tiles": [ { "id": "...", "type": "cpu",
//                                                 "size": "1x1" } ] } ],
//     "settings": { "<tileId>": { ...arbitrary per-widget state... } }
//   }
//
// `size` is a NAMED size from WidgetSizes (see that file for what a name means).
// It replaced the old `w`/`h` span pair, and it is a NEW KEY rather than a
// reinterpretation of the old ones for one decisive reason: a new key makes an
// old document STRUCTURALLY DETECTABLE. `size === undefined` ⇒ pre-migration,
// full stop. Reusing `w`/`h` would have silently reinterpreted them - old `h:2`
// meant "twice as tall as my siblings", new means "two thirds of the screen" -
// and there would have been no way to tell a migrated tile from a stale one.
// `version` protects the whole document from an older build. Rust enforces the
// same boundary before loading or saving config, while this QML check protects
// direct test bridges and keeps an incompatible Manager push from mutating the
// live model.
// ─────────────────────────────────────────────────────────────────────────
Item {
    id: store
    visible: false

    // The full document. Structural changes reassign this (clone) to fire
    // bindings; per-widget settings changes mutate in place + bump `revision`.
    property var document: ({ "version": 1, "appearance": {}, "pages": [], "settings": {} })
    readonly property int schemaVersion: 1
    property int revision: 0
    // Bumps ONLY on structural changes (pages/tiles added/removed/moved/resized,
    // page rename/bg/cols, load, or an applyExternal whose pages differ). The
    // dashboard's page+tile Repeater binds to THIS, not `revision`, so settings
    // and appearance pushes no longer tear down and rebuild every tile Loader.
    property int structureRevision: 0
    property bool loaded: false
    // Safe mode is a process-local recovery session. It may normalise or edit
    // the in-memory document for display, but must never publish those bytes.
    property bool persistenceEnabled: true

    signal changed()

    Timer {
        id: saveTimer
        interval: 400; repeat: false
        onTriggered: store._flush()
    }
    // True while a debounced disk save is pending (introspection for tests).
    readonly property alias _savePending: saveTimer.running
    // Persistence is an explicit state machine. A failed write leaves the live
    // document dirty and recoverable instead of looking saved until restart.
    property bool dirty: false
    property bool saveFailed: false
    property string saveFailureMessage: ""
    property string recoveryPath: ""
    property string _lastFailedPayload: ""
    // True only while an authoritative document is replacing the live model.
    // Widgets use this narrow guard to avoid turning reactive change handlers
    // into new local writes after the Manager document was already persisted.
    property bool externalApplyInProgress: false

    function _hasBridge() {
        return (typeof configBridge !== "undefined") && configBridge
    }

    // Setting keys that hold volatile, per-session runtime state (metric sparkline
    // history + session peaks). They are shared in memory so the compact tile and
    // its expanded overlay draw the same sparkline, but they must NEVER be persisted
    // or schedule a disk write - otherwise the metric widgets rewrite config.toml on
    // every sample (~2s), which is constant flash wear on the device and races the
    // Manager's own save (transient ENOENT). They're also stripped from the on-disk
    // document, so a genuine save never carries stale history across restarts (S4).
    // Volatile per-session keys that must NEVER reach config.toml. `hist`/`peakRx`/
    // `peakTx` back the metric sparklines; `http*` back the HTTP/JSON + KPI polling
    // primitives (value/text/error/list) - a poll every N seconds must not rewrite
    // the config (flash wear + a save race with the Manager).
    readonly property var _ephemeralKeys: ({ "hist": true, "histRaw": true, "histDevice": true,
        "peakRx": true, "peakTx": true,
        "httpVal": true, "httpText": true, "httpErr": true, "httpList": true, "httpAt": true,
        "quoteManualIdx": true, "quotePinnedText": true, "quoteManualDay": true })
    function _isEphemeralKey(k) { return store._ephemeralKeys[k] === true }

    // Deep copy of the document with all ephemeral runtime keys removed - the exact
    // bytes written to disk.
    function _persistableData() {
        var d = _clone(store.document)
        if (d.settings) {
            for (var id in d.settings) {
                var b = d.settings[id]
                if (!store._isPlainObject(b)) {
                    d.settings[id] = {}
                    continue
                }
                for (var k in store._ephemeralKeys)
                    if (b[k] !== undefined) delete b[k]
            }
        }
        return d
    }

    function _flush() {
        // Every call is an immediate commit boundary, including preset seeding
        // and shutdown. Retire any older debounce first so it cannot issue a
        // duplicate write after this newer document has already been saved.
        saveTimer.stop()
        if (!persistenceEnabled) {
            dirty = false
            saveFailed = false
            saveFailureMessage = ""
            recoveryPath = ""
            _lastFailedPayload = ""
            return true
        }
        // E9 forced-preset lock: never write. The in-memory document is the
        // org's preset; persisting it would overwrite the user's OWN saved
        // layout (which must come back intact if the policy is ever removed),
        // and "user edits to layout don't persist" is the policy's contract.
        if (policyLockedPreset !== "") return true
        if (!_hasBridge()) {
            dirty = false
            saveFailed = false
            saveFailureMessage = ""
            recoveryPath = ""
            _lastFailedPayload = ""
            return true
        }
        var payload = JSON.stringify(store._persistableData())
        var ok = configBridge.saveUiState(payload) !== false
        if (ok) {
            dirty = false
            saveFailed = false
            saveFailureMessage = ""
            recoveryPath = ""
            _lastFailedPayload = ""
            return true
        }

        dirty = true
        saveFailed = true
        saveFailureMessage = payload.length > 1024 * 1024
            ? "This layout is too large to save. Remove or shorten stored text, then retry."
            : "The latest changes could not be saved. They remain open in this session."
        if (_lastFailedPayload !== payload) {
            _lastFailedPayload = payload
            recoveryPath = ""
            if (typeof configBridge.exportUiStateRecovery === "function")
                recoveryPath = configBridge.exportUiStateRecovery(payload) || ""
        }
        return false
    }

    // Force an immediate (non-debounced) save when a real mutation is pending.
    // A clean shutdown or offline file-watch preflight must not rewrite the
    // current generation merely because it asked whether anything was dirty.
    function flushNow() {
        saveTimer.stop()
        return dirty ? _flush() : true
    }
    function retrySave() { return flushNow() }
    function markSaveFailed(message) {
        // A conflict/rejection is a decision point, not another debounce cycle.
        // Stop any armed write so only the user's explicit Retry can overwrite
        // the competing document.
        saveTimer.stop()
        var payload = JSON.stringify(store._persistableData())
        dirty = true
        saveFailed = true
        saveFailureMessage = message && message.length
            ? message : "The latest changes could not be saved."
        if (_lastFailedPayload !== payload) {
            _lastFailedPayload = payload
            recoveryPath = ""
            if (_hasBridge()
                    && typeof configBridge.exportUiStateRecovery === "function")
                recoveryPath = configBridge.exportUiStateRecovery(payload) || ""
        }
    }
    function discardUnsaved(seedLayout) {
        saveTimer.stop()
        saveFailed = false
        saveFailureMessage = ""
        recoveryPath = ""
        _lastFailedPayload = ""
        dirty = false
        return load(seedLayout || "")
    }

    function _clone(o) { return JSON.parse(JSON.stringify(o)) }

    // ── Tile sizes ───────────────────────────────────────────────────────────
    // The size vocabulary itself lives in WidgetSizes; which sizes a given widget
    // TYPE may legally take lives in WidgetCatalog. The store owns neither - it
    // only enforces them on the way in.
    property QtObject _sizes: WidgetSizes {}
    property QtObject _catalog: WidgetCatalog {}
    // Safe mode deliberately skips user-widget discovery. Preserve any legal
    // size belonging to a then-unknown type so an intentional recovery edit
    // cannot accidentally serialize that tile back at the baseline size.
    property bool preserveUnknownTileSizes: false
    // The same packer the Dashboard/EdgeClone render with, so capacity is measured
    // by real placement (half-width tiles pair across the short axis), never by a
    // naive area sum. Used to enforce "one page = one screen, never scrolls".
    property QtObject _packer: WidgetPacker {}

    // The catalog's per-type size API is consulted defensively: the store is
    // instantiated standalone in tests (and the catalog gained these functions
    // separately), so an absent/older catalog must degrade to "legality alone"
    // rather than throw and take the whole dashboard down.
    function _catalogFn(name) {
        var c = store._catalog
        return (c && typeof c[name] === "function") ? c[name] : null
    }
    function _defaultSizeFor(type) {
        var fn = store._catalogFn("defaultSize")
        var d = fn ? fn(type) : null
        return store._sizes.isLegal(d) ? d : store._sizes.baseline
    }
    function _sizeSupported(type, size) {
        if (!store._sizes.isLegal(size)) return false
        if (store.preserveUnknownTileSizes) {
            var sizesFn = store._catalogFn("sizesFor")
            if (sizesFn && sizesFn(type).length === 0)
                return true
        }
        var fn = store._catalogFn("supports")
        return fn ? (fn(type, size) === true) : true
    }

    // The largest size `type` DECLARES that is no bigger than `size`, or "" if it
    // declares nothing smaller.
    //
    // This is what an unsupported size coerces to, and the distinction from the
    // type's default is the whole point: a stored size the type cannot render still
    // carries one recoverable fact - that the tile was THIS BIG - and the default
    // throws it away. Migration maps a preset's old `h:2` to `1x2`, which `focus`,
    // `media` and `clock` do not declare (they top out at `1x1.5`); defaulting sent
    // them to `1x1` and calm-focus silently lost its hero timer. Coercing DOWN keeps
    // the emphasis at the largest shape the widget can actually render.
    //
    // Ranked by AREA - share of the screen, the same measure `_nearestSize` preserves
    // - never by declaration order, which is a convention the catalog is free to
    // break. Ties (0.5x1 and 1x0.5 are both 1/6) keep the WIDER short axis, matching
    // the shortFrac bias in `_migratedSize`: a coercion may shrink a tile only
    // because the widget cannot render the shape, never by preference.
    function _largestSupportedAtMost(type, size) {
        var fn = store._catalogFn("sizesFor")
        var legal = fn ? fn(type) : []
        var want = store._sizes.area(size)
        var best = "", bestArea = -1, bestShort = -1
        for (var i = 0; i < legal.length; i++) {
            var name = legal[i]
            if (!store._sizes.isLegal(name)) continue
            var area = store._sizes.area(name)
            if (area > want + 1e-9) continue
            // NOT `var short`: `short` is an ECMAScript future-reserved word, and
            // Qt 6.7's V4 parser (what CI runs) rejects it as an identifier -
            // "Expected token `identifier'" - while 6.11 (the dev box) accepts it.
            // The .short PROPERTY read below is fine; only the declaration breaks.
            var shortAxis = store._sizes.table[name].short
            if (area > bestArea + 1e-9 ||
                (Math.abs(area - bestArea) < 1e-9 && shortAxis > bestShort)) {
                best = name; bestArea = area; bestShort = shortAxis
            }
        }
        return best
    }

    // Geometry → the closest legal size name.
    //   shortFrac  - fraction of the short screen axis (the axis has exactly two
    //                stops: 0.5 and 1)
    //   longThirds - count of thirds along the long axis
    // An exact match wins. Otherwise the tile's SHARE OF THE SCREEN (area) is
    // preserved, because that is the closest honest proxy for the emphasis the
    // old sibling-ratio encoded: e.g. a half-wide two-thirds-tall tile (0.5x2 -
    // not a legal size, the short axis has no 2-thirds partner) and `1x1` both
    // occupy exactly a third of the screen, so the tile keeps its weight even
    // though it changes shape.
    function _nearestSize(shortFrac, longThirds) {
        var names = store._sizes.all()   // smallest → largest
        var i, s
        for (i = 0; i < names.length; i++) {
            s = store._sizes.table[names[i]]
            if (s.short === shortFrac && s.long === longThirds) return names[i]
        }
        var want = shortFrac * longThirds / 3
        var best = store._sizes.baseline, bestD = Infinity
        for (i = 0; i < names.length; i++) {
            var d = Math.abs(store._sizes.area(names[i]) - want)
            if (d < bestD - 1e-9) { bestD = d; best = names[i] }   // ties keep the smaller
        }
        return best
    }

    // Best-effort {w,h} → size for ONE tile. THIS IS LOSSY AND CANNOT BE OTHERWISE.
    //
    // Old `w` was a column span against the page's declared column count, so it
    // IS recoverable as a fraction: w/cols. Old `h` was a row span against
    // siblings - its on-screen height depended on how many rows the page happened
    // to pack, which nothing on disk records - whereas the new long axis is a
    // fixed count of thirds of the screen. So `h` is mapped 1:1 onto thirds
    // (h:1 → a third, h:2 → two thirds), which is exactly right only for a page
    // whose rows already totalled three, and merely proportional otherwise.
    function _migratedSize(tile, declaredCols) {
        var cols = Math.max(1, Math.min(6, Math.round(Number(declaredCols)) || 1))
        var span = Math.max(1, Math.min(Math.round(Number(tile.w)) || 1, cols))
        var frac = span / cols
        // Snap to the short axis' two stops, biasing to the WIDER one on a tie so
        // migration never shrinks a tile it simply cannot represent.
        var shortFrac = (Math.abs(frac - 0.5) < Math.abs(frac - 1)) ? 0.5 : 1
        // Mirror the old [1,2] span clamp: no pre-migration document could mean
        // more than 2 rows, so a crafted h:9999 must not become a full screen.
        var longThirds = Math.max(1, Math.min(2, Math.round(Number(tile.h)) || 1))
        return store._nearestSize(shortFrac, longThirds)
    }

    // Give one tile a legal, type-supported `size`, migrating it if needed.
    // Returns a human-readable note when the tile's stored intent changed meaning
    // (for the migration log), else "".
    function _coerceTileSize(tile, declaredCols) {
        var note = ""
        if (tile.size === undefined) {
            // No `size` key ⇒ pre-migration. The vast majority of stored tiles are
            // a bare {id,type} - `addTile` never wrote w/h - and carry no sizing
            // intent at all, so they land on whatever the page's column count
            // implies (with the default 1-column grid: the `1x1` baseline).
            var carriedIntent = (tile.w !== undefined || tile.h !== undefined)
            var before = "w:" + (tile.w !== undefined ? tile.w : "1(default)") +
                         " h:" + (tile.h !== undefined ? tile.h : "1(default)") +
                         " on a " + declaredCols + "-col page"
            tile.size = store._migratedSize(tile, declaredCols)
            // Only tiles that carried a REAL intent are worth reporting; logging
            // every bare {id,type} would bury the signal in the common case.
            if (carriedIntent) note = before + " → " + tile.size
        }
        if (!store._sizeSupported(tile.type, tile.size)) {
            var bad = tile.size
            // Coerce DOWN, not to the default: keep "this tile was big" at the
            // largest shape the widget declares. Only a type that declares nothing
            // this small (or an unknown type, which declares nothing at all) falls
            // back to the default - and a legal-but-unsupported size is still
            // REPORTED either way, because the tile did change shape.
            var down = store._sizes.isLegal(bad)
                     ? store._largestSupportedAtMost(tile.type, bad) : ""
            tile.size = down !== "" ? down : store._defaultSizeFor(tile.type)
            note = "unsupported size " + JSON.stringify(bad) + " → " + tile.size
        }
        // w/h are dead vocabulary. Leaving them would let a stale reader apply the
        // old ratio on top of the new size, and would defeat the `size === undefined`
        // detection above on the next load.
        delete tile.w
        delete tile.h
        return note
    }

    // Validate + normalise a loaded/pushed document in place. `load`/applyExternal
    // only gate on truthiness, so a corrupt or hostile doc (`"pages":5`,
    // `"pages":{}`, string/number tiles, id-less tiles, a non-object `settings`)
    // would otherwise reach the page/tile Repeater and `addTile` → TypeError →
    // blank dashboard. This coerces every structural field into the exact shape the
    // rest of the store and the QML assume, dropping anything that can't be healed.
    function _isPlainObject(v) {
        return v !== null && typeof v === "object" && !Array.isArray(v)
    }
    function _schemaSupported(doc) {
        if (!_isPlainObject(doc)) return false
        if (doc.version === undefined) return true
        return typeof doc.version === "number"
                && isFinite(doc.version)
                && Math.floor(doc.version) === doc.version
                && doc.version >= 0
                && doc.version <= schemaVersion
    }
    function _normaliseDoc(doc) {
        doc.version = schemaVersion
        if (!_isPlainObject(doc.appearance)) doc.appearance = {}
        if (doc.appearance.hubControlsMode !== "immersive"
                && doc.appearance.hubControlsMode !== "standard")
            doc.appearance.hubControlsMode = "standard"
        // A hand-edited or older document can carry anything here; an
        // unrecognised dwell means off, never "some number of seconds".
        if (!isPageCycleChoice(doc.appearance.pageCycleSec))
            doc.appearance.pageCycleSec = 0
        else
            doc.appearance.pageCycleSec = Number(doc.appearance.pageCycleSec)
        if (!_isPlainObject(doc.settings)) doc.settings = {}
        for (var settingId in doc.settings)
            if (!_isPlainObject(doc.settings[settingId]))
                doc.settings[settingId] = {}
        // Pages MUST be an array; anything else (number/object/string/null) is junk.
        if (!Array.isArray(doc.pages)) doc.pages = []

        // Coerce each page into a well-formed { name:String, tiles:[objects with a
        // non-empty string id] }. Non-object pages are dropped entirely; a page's
        // tiles array is reset to [] when it isn't an array; each tile survives only
        // if it is a plain object carrying a non-empty string id (a bare string,
        // number, or id-less object is dropped rather than crashing addTile/binds).
        // A missing or non-string type is retained as "". The tile still owns a
        // stable position and settings bucket, and Dashboard renders its explicit
        // Unavailable card. Silently dropping it would make a damaged or newer
        // configuration look like the user had deleted a widget.
        var cleanPages = []
        var migrationLog = []
        var seenTileIds = Object.create(null)
        for (var i = 0; i < doc.pages.length; i++) {
            var p = doc.pages[i]
            if (!_isPlainObject(p)) continue
            if (typeof p.name !== "string" || p.name === "")
                p.name = "Page " + (cleanPages.length + 1)
            // The column count the old `w` span was measured against: the page
            // override, else the global grid setting, else 1 (Dashboard's own
            // resolution order). Dashboard additionally clamped this by the runtime
            // WIDTH - information that does not exist on disk and is unknowable
            // here, so the declared count is the best available truth.
            var declaredCols = Number(p.cols) || Number(doc.appearance.gridCols) || 1
            var srcTiles = Array.isArray(p.tiles) ? p.tiles : []
            if (!_isPlainObject(p.bg))
                delete p.bg
            var cleanTiles = []
            for (var j = 0; j < srcTiles.length; j++) {
                var t = srcTiles[j]
                if (_isPlainObject(t)
                        && typeof t.id === "string" && t.id !== "") {
                    if (typeof t.type !== "string") t.type = ""
                    if (seenTileIds[t.id] === true) {
                        var previousId = t.id
                        t.id = _newId(t.type || "widget", doc)
                        if (_isPlainObject(doc.settings[previousId])
                                && doc.settings[t.id] === undefined)
                            doc.settings[t.id] = _clone(doc.settings[previousId])
                    }
                    seenTileIds[t.id] = true
                    // Every tile entering `document` leaves here with a legal, supported
                    // `size` - migrated from w/h, or coerced if the document handed
                    // us junk. This runs on load AND applyExternal (another process
                    // pushes that one), so it is the hostile-input boundary too.
                    var note = _coerceTileSize(t, declaredCols)
                    if (note !== "") migrationLog.push(p.name + "/" + t.type + " " + note)
                    cleanTiles.push(t)
                }
            }
            p.tiles = cleanTiles
            // `cols` chose how many columns the page laid its tiles out in. The grid
            // is now FIXED at WidgetSizes.shortHalves (2 half-cells) across the short
            // axis, because a size is a fraction of the SCREEN - a user-chosen column
            // count would make `1x1` mean something different per page, which is the
            // exact property the size model exists to remove. So the key is dead, and
            // it is dropped HERE rather than left to rot: it is read one last time
            // just above (it is the only record of what the old `w` span was measured
            // against) and must not survive to be read again by a later pass.
            delete p.cols
            cleanPages.push(p)
        }
        doc.pages = cleanPages
        // The global default behind the per-page `cols`, dead for the same reason.
        delete doc.appearance.gridCols
        // Best-effort migration is REPORTED, never silent: the user's layout is
        // preserved as closely as the two vocabularies allow (a tile is never
        // dropped, and nothing is re-seeded from a preset), but a tile whose old
        // height was a sibling-ratio may well have changed its share of the screen,
        // and that is not something to hide.
        //
        // A migrated page may exceed the screen's 6 long half-cells - six bare
        // {id,type} tiles become 6 × `1x1` = 12, two screens' worth. That is fine
        // and deliberate: the store does not do capacity. Forcing tiles to fit here
        // would silently destroy the layout this function exists to preserve, so a
        // long page is placed in full by WidgetPacker and SCROLLS (Dashboard.qml).
        if (migrationLog.length)
            console.log("DashboardStore: migrated " + migrationLog.length +
                        " tile(s) from the w/h span vocabulary to named sizes " +
                        "(best-effort: old h was a ratio against sibling tiles, a " +
                        "size is a fraction of the screen):\n  " + migrationLog.join("\n  "))

        // De-duplicate page names on load. renamePage/addPage reject NEW collisions,
        // but a config that already carries two identical page names (the real "two
        // Page 5 tabs" bug) was never reconciled. Walk in order, keep the first
        // occurrence, and disambiguate later duplicates deterministically by
        // appending " 2", " 3", … - tiles/order/all other fields are untouched.
        var seenNames = Object.create(null)
        for (var n = 0; n < doc.pages.length; n++) {
            var pg = doc.pages[n]
            var nm = String(pg.name)
            if (seenNames[nm]) {
                var suffix = 2
                while (seenNames[nm + " " + suffix]) suffix++
                nm = nm + " " + suffix
                pg.name = nm
            }
            seenNames[nm] = true
        }
        // Prune settings whose id is no longer owned by any surviving tile (plus the
        // stray empty-id entry).
        var live = Object.create(null)
        for (var k = 0; k < doc.pages.length; k++) {
            var tiles = doc.pages[k].tiles
            for (var j2 = 0; j2 < tiles.length; j2++) live[tiles[j2].id] = true
        }
        for (var key in doc.settings)
            if (live[key] !== true) delete doc.settings[key]
        return doc
    }

    // Bump reactivity for in-place settings mutations. `persist` (default true)
    // controls whether a disk save is scheduled: volatile metric writes bump
    // revision so the live sparkline updates, but do not touch disk.
    function _touchSettings(persist) {
        revision++
        changed()
        if (persist === undefined || persist) {
            dirty = true
            saveTimer.restart()
        }
    }

    // Reassign `document` (clone) for structural mutations so Repeaters refresh.
    // Structural edits are force-flushed (not debounced) so a page/tile added
    // outside edit mode survives an abrupt power-off.
    function _commitStructure() {
        document = _clone(document)
        revision++
        structureRevision++
        changed()
        dirty = true
        flushNow()
    }

    // ── Managed / org policy (E9): forced-preset lock ───────────────────
    // When non-empty, the layout was seeded from this preset by org policy:
    //   • NOTHING is persisted while the lock holds (see _flush) - session
    //     edits to the forced layout evaporate on restart, and the user's own
    //     saved layout in config.toml survives untouched underneath;
    //   • a Manager push is refused (see applyExternal).
    // Dashboard engages this INSTEAD of load() when configBridge.policy()
    // carries a forcePreset.
    property string policyLockedPreset: ""

    function lockToPreset(presetId) {
        // An unknown preset id falls through seed()'s own "productivity"
        // fallback, but the lock still engages: a typo'd policy must degrade
        // to a locked default layout, never to an unlocked one. An EMPTY id is
        // refused without touching an already-engaged lock.
        var id = String(presetId || "")
        if (id === "") return false
        policyLockedPreset = id
        document = _normaliseDoc(seed(policyLockedPreset))
        loaded = true
        revision++
        structureRevision++
        changed()
        return true
    }

    // ── Load / seed ──────────────────────────────────────────────────────
    function load(seedLayout) {
        var raw = _hasBridge() ? configBridge.uiState() : ""
        var parsed = null
        if (raw && raw.length) {
            try { parsed = JSON.parse(raw) } catch (e) { parsed = null }
        }
        // Honour any valid saved layout - including an intentionally-blank
        // pages:[] - consistently with applyExternal(); only re-seed when there
        // is no usable document at all.
        if (parsed && parsed.pages && _schemaSupported(parsed)) {
            // This is an explicit authoritative reload from the persistence
            // bridge, including the Discard path after a conflict. Retire all
            // stale local-save and recovery state before exposing the document.
            saveTimer.stop()
            dirty = false
            saveFailed = false
            saveFailureMessage = ""
            recoveryPath = ""
            _lastFailedPayload = ""
            document = _normaliseDoc(parsed)
        } else if (parsed && !_schemaSupported(parsed)) {
            // Never turn a future document into this build's defaults. Production
            // rejects it in Rust before QML starts; this branch protects direct
            // bridges and tests without mutating or persisting anything.
            return false
        } else {
            // Seeded docs are normalised too: the curated presets still declare the
            // old w/h vocabulary, so this is what gives a fresh install's tiles a
            // `size` - the invariant "every tile in `document` has one" must hold on
            // EVERY path into `document`, not just the load-from-disk one.
            document = _normaliseDoc(seed(seedLayout && seedLayout.length ? seedLayout : "starter"))
            dirty = true
            _flush()
        }
        loaded = true
        revision++
        structureRevision++
        changed()
        return true
    }

    // Non-mutating validation used by the Hub preflight before it flushes any
    // unfinished local editor state.
    function canApplyExternal(json) {
        // E9: a Manager push must not override an org-forced preset any more
        // than a local edit may - IPC is just another editing surface.
        if (policyLockedPreset !== "") return false
        var parsed = null
        try { parsed = JSON.parse(json) } catch (e) { parsed = null }
        return !!parsed && !!parsed.pages && _schemaSupported(parsed)
    }

    // Apply a UI-state document pushed from the companion Manager app (over the
    // hub's control socket). Reassigns `document` and bumps reactivity so the live
    // dashboard rebuilds without persisting again because the Hub already saved it.
    function applyExternal(json) {
        if (!canApplyExternal(json)) return false
        var parsed = null
        try { parsed = JSON.parse(json) } catch (e) { parsed = null }
        // Cancel any pending debounced save so the externally-applied doc is
        // never echoed back to the hub 400ms later.
        saveTimer.stop()
        var nextDocument = _normaliseDoc(parsed)
        var pagesChanged =
            JSON.stringify(document.pages || [])
            !== JSON.stringify(nextDocument.pages || [])
        externalApplyInProgress = true
        try {
            document = nextDocument
            loaded = true
            dirty = false
            saveFailed = false
            saveFailureMessage = ""
            recoveryPath = ""
            _lastFailedPayload = ""
            revision++
            if (pagesChanged) structureRevision++
            changed()
        } finally {
            externalApplyInProgress = false
        }
        return true
    }

    // ── Appearance ─────────────────────────────────────────────────────────
    function appearance() { return document.appearance || {} }

    // Dwell times the auto-cycle offers, in seconds. 0 is "off" and is the
    // default: a panel that starts moving by itself after an update is a
    // surprise, and this ships B2B. Anything not on this ladder is coerced to
    // off rather than honoured - an arbitrary persisted number (7, 0.5,
    // 86400) would otherwise become a dwell nobody can reproduce from the UI.
    readonly property var pageCycleChoices: [0, 15, 30, 60, 90, 120, 300]
    function isPageCycleChoice(v) {
        var n = Number(v)
        return isFinite(n) && pageCycleChoices.indexOf(n) >= 0
    }

    function setAppearance(key, val) {
        if (!document.appearance) document.appearance = {}
        if (key === "hubControlsMode" && val !== "standard" && val !== "immersive")
            val = "standard"
        if (key === "pageCycleSec")
            val = isPageCycleChoice(val) ? Number(val) : 0
        document.appearance[key] = val
        _touchSettings()
    }

    // ── Per-widget settings ─────────────────────────────────────────────────
    // NON-mutating read: returns the live settings object when it exists, else a
    // throwaway empty default. Must NOT create a persisted entry - it is called
    // inside widget bindings (with a possibly-empty instanceId), and materialising
    // ghost `{}`/`settings['']` entries would grow and poison the document.
    function settingsFor(id) {
        if (!id || !document.settings || !document.settings[id]) return ({})
        return document.settings[id]
    }
    // Get-or-create the persisted bucket for a MUTATION. Empty ids are rejected.
    function _bucket(id) {
        if (!id) return null
        if (!document.settings) document.settings = {}
        if (!document.settings[id]) document.settings[id] = {}
        return document.settings[id]
    }
    // Seed defaults for an instance without clobbering existing values. Bumps
    // revision (so a second instance - the expanded overlay - re-reads the seeded
    // values) and schedules a save (so defaults survive an immediate close).
    function ensureSettings(id, defaults) {
        var s = _bucket(id)
        if (!s) return ({})
        // Only bump revision + schedule a save when a default was ACTUALLY seeded.
        // Otherwise every tile Loader rebuild (e.g. after applyExternal bumps
        // structureRevision) re-ran ensureSettings → unconditional _touchSettings →
        // a redundant ~400ms flash write echoing back the doc the hub just pushed.
        var added = false
        for (var k in defaults)
            if (s[k] === undefined) { s[k] = defaults[k]; added = true }
        if (added) _touchSettings()
        return s
    }
    function setSetting(id, key, val) {
        var s = _bucket(id)
        if (!s) return
        s[key] = val
        // A write to a volatile metric key bumps reactivity but is never persisted.
        _touchSettings(!_isEphemeralKey(key))
    }
    function patchSettings(id, obj) {
        var s = _bucket(id)
        if (!s) return
        var persist = false
        for (var k in obj) { s[k] = obj[k]; if (!_isEphemeralKey(k)) persist = true }
        // Persist only when the patch carries at least one real (non-volatile) key.
        _touchSettings(persist)
    }
    // Replace an instance's settings with a DEEP COPY of `defaults` (drops any
    // stale keys). The clone is essential: assigning array/object defaults by
    // reference would share one instance across every reset (e.g. every widget's
    // tasks:[] becoming the same list). Used by "Reset to defaults".
    function resetSettings(id, defaults) {
        if (!id) return
        if (!document.settings) document.settings = {}
        // Replace the bucket atomically. Repeatedly deleting and re-inserting
        // differently shaped widget settings can crash Qt 6.11 inside
        // QV4::Object::insertMember after enough resets.
        document.settings[id] = _clone(defaults || {})
        _touchSettings()
    }

    // Reset presentation and configuration without deleting classified personal
    // content or progress. The caller gets the classification from WidgetCatalog.
    // Both defaults and retained values are cloned so no instance can acquire a
    // shared nested array/object through the reset path.
    function resetConfiguration(id, defaults, personalKeys) {
        var s = _bucket(id)
        if (!s) return false
        var keep = ({})
        var keys = personalKeys || []
        for (var i = 0; i < keys.length; i++) {
            var key = keys[i]
            if (s[key] !== undefined) keep[key] = _clone(s[key])
        }
        var d = _clone(defaults || {})
        for (var kk in keep) d[kk] = keep[kk]
        document.settings[id] = d
        _touchSettings()
        return true
    }

    // Erase only the explicitly classified personal keys. Configuration,
    // appearance, endpoints and other unrelated values remain untouched.
    function erasePersonalData(id, personalKeys) {
        if (!id || !document.settings || !document.settings[id]) return 0
        var s = document.settings[id]
        var keys = personalKeys || []
        var removed = 0
        for (var i = 0; i < keys.length; i++) {
            if (s[keys[i]] !== undefined) {
                delete s[keys[i]]
                removed++
            }
        }
        if (removed > 0) _touchSettings()
        return removed
    }

    // ── Pages / tiles ────────────────────────────────────────────────────────
    function pages() { return document.pages || [] }
    function pageCount() { return pages().length }

    function _newId(type, sourceDocument) {
        // Counters restart with every process, so a counter alone can reproduce
        // an existing persisted id after restart. Probe both live tiles and
        // settings buckets until the candidate is globally unused.
        var candidate = ""
        do {
            _idSeq++
            candidate = type + "-" + _idSeq + "-" + revision
        } while (_idInUse(candidate, sourceDocument))
        return candidate
    }
    property int _idSeq: 0
    function _idInUse(candidate, sourceDocument) {
        if (!candidate) return true
        var source = sourceDocument || document
        var ps = source && Array.isArray(source.pages)
                 ? source.pages : []
        for (var p = 0; p < ps.length; p++) {
            var ts = Array.isArray(ps[p].tiles) ? ps[p].tiles : []
            for (var t = 0; t < ts.length; t++)
                if (ts[t].id === candidate) return true
        }
        return _isPlainObject(source && source.settings)
                && source.settings[candidate] !== undefined
    }

    // ── One page = one screen (never scrolls) ────────────────────────────────
    // Pack the page's tiles PLUS a probe of `size`; there is room iff the packing
    // still fits within the screen's long axis (longHalves). Half-width tiles pair
    // across the short axis, so this is measured by real placement, not an area sum.
    function pageHasRoomFor(pageIdx, size) {
        if (pageIdx < 0 || pageIdx >= document.pages.length) return false
        if (!store._sizes.isLegal(size)) return false
        var tiles = (document.pages[pageIdx].tiles || []).slice()
        tiles.push({ "id": "__probe__", "type": "__probe__", "size": size })
        return store._packer.longExtent(store._packer.pack(tiles)) <= store._sizes.longHalves
    }
    // Per-page column mode: 1 (full-width tiles) or 2 (half-width, two across).
    // Default 1. Stored as the page `columns` key (survives _normaliseDoc).
    function pageColumns(pageIdx) {
        var ps = pages()
        var p = (pageIdx >= 0 && pageIdx < ps.length) ? ps[pageIdx] : ({})
        return (p.columns === 2) ? 2 : 1
    }
    // A supported size for `type` whose SHORT axis is `targetShort` (1 or 0.5), with
    // the long axis closest to `currentSize`'s. "" if the type declares none that
    // wide (e.g. focus has no 0.5-wide size) - the caller then keeps the old size.
    function _sizeAtShort(type, currentSize, targetShort) {
        var fn = store._catalogFn("sizesFor")
        var legal = fn ? fn(type) : []
        var curLong = (store._sizes.isLegal(currentSize) && store._sizes.table[currentSize])
                      ? store._sizes.table[currentSize].long : 1
        var best = "", bestDL = Infinity
        for (var i = 0; i < legal.length; i++) {
            var nm = legal[i]
            if (!store._sizes.isLegal(nm)) continue
            if (Math.abs(store._sizes.table[nm].short - targetShort) > 1e-9) continue
            var dl = Math.abs(store._sizes.table[nm].long - curLong)
            if (dl < bestDL) { bestDL = dl; best = nm }
        }
        return best
    }
    // The size a NEW tile of `type` takes on this page: honours the page's column
    // mode (2 → a half-width size if the type has one) else the type's default.
    function _addSizeFor(pageIdx, type) {
        var base = _defaultSizeFor(type)
        if (pageColumns(pageIdx) >= 2) {
            var half = _sizeAtShort(type, base, 0.5)
            if (half) return half
        }
        return base
    }
    // Set a page's column mode and REFLOW its tiles to that width - but only if the
    // reflow still fits one screen (it must never create overflow). Narrowing to 2
    // columns always fits; widening to 1 column is applied only when it does.
    function setPageColumns(pageIdx, n) {
        if (pageIdx < 0 || pageIdx >= document.pages.length) return false
        var cols = (n >= 2) ? 2 : 1
        if (pageColumns(pageIdx) === cols) return true
        var targetShort = (cols === 2) ? 0.5 : 1
        var page = document.pages[pageIdx]
        var tiles = page.tiles || []
        var reflowed = tiles.map(function (t) {
            var ns = store._sizeAtShort(t.type, t.size, targetShort)
            return { "id": t.id, "type": t.type, "size": (ns && ns.length ? ns : t.size) }
        })
        if (store._packer.longExtent(store._packer.pack(reflowed))
                > store._sizes.longHalves)
            return false
        for (var i = 0; i < tiles.length; i++) tiles[i].size = reflowed[i].size
        page.columns = cols
        _commitStructure()
        return true
    }

    // ── UI helpers for the add-widget affordances ────────────────────────────
    // A page is full when not even the smallest widget (0.5x0.5) fits - the next
    // widget added here will start a NEW screen (see addTile). Drives the Hub's
    // edit-mode add slot and the picker's "will start a new screen" hint.
    function pageIsFull(pageIdx) { return !pageHasRoomFor(pageIdx, "0.5x0.5") }
    // The size the edit-mode "add" ghost previews: the column-aware baseline if it
    // fits, else the largest smaller size that still fits, else "" (page full → the
    // next widget lands on a new screen, so there is no slot to preview here).
    function nextAddSize(pageIdx) {
        var pref = (pageColumns(pageIdx) >= 2) ? "0.5x1" : store._sizes.baseline
        var order = [pref, "0.5x1", "0.5x0.5"]
        for (var i = 0; i < order.length; i++)
            if (pageHasRoomFor(pageIdx, order[i])) return order[i]
        return ""
    }
    // The size a NEW `type` should take on `pageIdx`: its preferred (column-aware)
    // size if that fits, else the LARGEST supported size smaller than it that fits,
    // else "" - the page is too full for even the smallest, so the caller starts a
    // new screen. This is what lets "add" degrade gracefully into the space left
    // (a widget that would be 1x1 slots into a leftover 0.5x1 gap) instead of
    // refusing, while never overflowing the one-screen budget.
    function _fitSizeFor(pageIdx, type) {
        var pref = _addSizeFor(pageIdx, type)
        if (pageHasRoomFor(pageIdx, pref)) return pref
        var fn = store._catalogFn("sizesFor")
        var legal = fn ? fn(type) : []
        var prefArea = store._sizes.area(pref)
        var cands = []
        for (var i = 0; i < legal.length; i++) {
            var nm = legal[i]
            if (!store._sizes.isLegal(nm)) continue
            if (store._sizes.area(nm) >= prefArea) continue   // only sizes smaller than preferred
            cands.push(nm)
        }
        cands.sort(function (a, b) { return store._sizes.area(b) - store._sizes.area(a) })  // largest first
        for (var j = 0; j < cands.length; j++)
            if (pageHasRoomFor(pageIdx, cands[j])) return cands[j]
        return ""
    }
    // Append a fresh, blank single-column screen and return its index. No commit -
    // the caller (addTile) commits once after placing the tile.
    function _appendBlankPage() {
        document.pages.push({ "name": _uniquePageName(), "tiles": [], "columns": 1 })
        return document.pages.length - 1
    }
    // Which page holds `tileId`, or -1. Lets a caller follow a freshly-added tile to
    // whatever screen it landed on (its own page, or a new one addTile created).
    function pageIndexForTile(tileId) {
        for (var p = 0; p < document.pages.length; p++) {
            var tiles = document.pages[p].tiles || []
            for (var t = 0; t < tiles.length; t++)
                if (tiles[t].id === tileId) return p
        }
        return -1
    }

    // Add a tile. It lands on `pageIdx` if it fits there - at its preferred size, or
    // the largest smaller size that fits the space left. If NOTHING fits, a NEW
    // screen is appended and the tile lands there at its default size. A page never
    // scrolls, and adding never fails for lack of room (only a bad index returns
    // null). Use pageIndexForTile(id) to follow the tile to its screen.
    function addTile(pageIdx, type) {
        if (pageIdx < 0 || pageIdx >= document.pages.length) return null
        var size = _fitSizeFor(pageIdx, type)
        var target = pageIdx
        if (size === "") {                    // this screen is full → start a new one
            target = _appendBlankPage()
            size = _defaultSizeFor(type)      // a fresh screen fits the default size
        }
        var id = _newId(type)
        document.pages[target].tiles.push({ "id": id, "type": type, "size": size })
        _commitStructure()
        return id
    }
    function removeTile(pageIdx, tileId) {
        if (pageIdx < 0 || pageIdx >= document.pages.length) return false
        var tiles = document.pages[pageIdx].tiles || []
        for (var i = 0; i < tiles.length; i++) {
            if (tiles[i].id === tileId) {
                tiles.splice(i, 1)
                if (document.settings) delete document.settings[tileId]
                _commitStructure()
                return true
            }
        }
        return false
    }
    // Set a tile's NAMED size (a WidgetSizes name - not a w/h span). Rejects a
    // size the widget type does not support, so the picker/drag UI cannot put a
    // tile into a shape its widget was never built to render. Returns whether the
    // size was applied.
    // The subset of a tile's DECLARED sizes that would actually FIT the page
    // (i.e. that setTileSize would accept). The resize drag preview uses this so
    // it can only ever offer a size that fits - you can never drag a widget
    // bigger than the space left, which is exactly what makes "a screen always
    // stays one screen" true DURING the drag, not just on release. Always
    // includes the tile's current size so the preview never snaps to nothing.
    function fittingSizesFor(pageIdx, tileId) {
        if (pageIdx < 0 || pageIdx >= document.pages.length) return []
        var tiles = document.pages[pageIdx].tiles
        var target = null
        for (var i = 0; i < tiles.length; i++)
            if (tiles[i].id === tileId) { target = tiles[i]; break }
        if (!target) return []
        var fn = store._catalogFn("sizesFor")
        var all = fn ? (fn(target.type) || []) : []
        var out = []
        for (var s = 0; s < all.length; s++) {
            var probe = tiles.map(function (t) {
                return { "id": t.id, "type": t.type,
                         "size": (t.id === tileId ? all[s] : t.size) }
            })
            if (all[s] === target.size
                    || store._packer.longExtent(store._packer.pack(probe)) <= store._sizes.longHalves)
                out.push(all[s])
        }
        return out
    }

    function setTileSize(pageIdx, tileId, size) {
        if (pageIdx < 0 || pageIdx >= document.pages.length) return false
        var tiles = document.pages[pageIdx].tiles
        for (var i = 0; i < tiles.length; i++) {
            if (tiles[i].id === tileId) {
                if (!_sizeSupported(tiles[i].type, size)) return false
                // A resize must not push the page past one screen (never scrolls).
                var probe = tiles.map(function (t) {
                    return { "id": t.id, "type": t.type, "size": (t.id === tileId ? size : t.size) }
                })
                if (store._packer.longExtent(store._packer.pack(probe)) > store._sizes.longHalves)
                    return false
                tiles[i].size = size
                _commitStructure()
                return true
            }
        }
        return false
    }
    function moveTile(pageIdx, fromIdx, toIdx) {
        if (pageIdx < 0 || pageIdx >= document.pages.length) return
        var tiles = document.pages[pageIdx].tiles || []
        if (fromIdx < 0 || fromIdx >= tiles.length) return
        toIdx = Math.max(0, Math.min(tiles.length - 1, toIdx))
        if (fromIdx === toIdx) return
        var t = tiles.splice(fromIdx, 1)[0]
        tiles.splice(toIdx, 0, t)
        _commitStructure()
    }
    function addPage(name) {
        document.pages.push({ "name": name || _uniquePageName(), "tiles": [] })
        _commitStructure()
    }
    // Generate a "Page N" name that doesn't collide with existing page names.
    function _uniquePageName() {
        var existing = Object.create(null)
        for (var i = 0; i < document.pages.length; i++) existing[document.pages[i].name] = true
        var n = document.pages.length + 1
        while (existing["Page " + n]) n++
        return "Page " + n
    }
    function removePage(pageIdx) {
        if (pageIdx < 0 || pageIdx >= document.pages.length) return   // ignore out-of-range
        if (document.pages.length <= 1) return   // keep at least one page
        var removed = document.pages.splice(pageIdx, 1)[0]
        if (removed && document.settings)
            for (var i = 0; i < removed.tiles.length; i++)
                delete document.settings[removed.tiles[i].id]
        _commitStructure()
    }
    // Validated: trims, keeps the old name if blank, and de-duplicates against the
    // other pages (so the tab bar never gets an empty or ambiguous label).
    function renamePage(pageIdx, name) {
        if (pageIdx < 0 || pageIdx >= document.pages.length) return
        var trimmed = String(name || "").trim()
        if (trimmed === "") trimmed = document.pages[pageIdx].name
        var others = Object.create(null)
        for (var i = 0; i < document.pages.length; i++)
            if (i !== pageIdx) others[document.pages[i].name] = true
        if (others[trimmed]) {
            var base = trimmed, n = 2
            while (others[base + " " + n]) n++
            trimmed = base + " " + n
        }
        document.pages[pageIdx].name = trimmed
        _commitStructure()
    }

    // Per-page background override: key ∈ {"style","wallpaper"}. Empty value
    // clears the override so the page falls back to the global appearance.
    function setPageBackground(pageIdx, key, val) {
        if (pageIdx < 0 || pageIdx >= document.pages.length) return
        if (!document.pages[pageIdx].bg) document.pages[pageIdx].bg = {}
        if (val === "" || val === null || val === undefined)
            delete document.pages[pageIdx].bg[key]
        else
            document.pages[pageIdx].bg[key] = val
        _commitStructure()
    }
    function pageBackground(pageIdx) {
        var ps = pages()
        var p = (pageIdx >= 0 && pageIdx < ps.length) ? ps[pageIdx] : {}
        return p.bg || {}
    }

    // setPageColumns/pageColumns stood here, with the `cols` page key behind them.
    // The column count is gone from the model, not merely unread: `_normaliseDoc`
    // strips `cols`/`gridCols` off every document it loads (reading `cols` one last
    // time to migrate the old `w` span it was measured against), and the pickers
    // that wrote them are gone from both the hub's SettingsPanel and the Manager.

    // Reset the whole dashboard to a named starter layout (default: the recommended
    // few-screen starter bundle).
    function resetTo(seedLayout) {
        document = _normaliseDoc(seed(seedLayout || "starter"))
        loaded = true
        _commitStructure()   // force-flushes; no extra save needed
    }

    // Append a single-page preset ("screen") as a NEW page. Additive - unlike
    // resetTo, it never replaces the user's other pages and NEVER writes
    // document.appearance (the global theme/accent/offline/reduceMotion stay put). It
    // re-keys tile ids against the live document (so they can't collide with an
    // existing tile/settings bucket), merges the screen's per-tile settings, and
    // carries the screen's character as a per-page BACKGROUND so a calm screen
    // doesn't restyle the whole Edge. Returns the new page index, or -1 if refused
    // (managed lock) or the id is unknown. Guarded like every mutation by the E9
    // forced-preset lock.
    function appendPreset(presetId) {
        if (policyLockedPreset !== "") return -1
        if (!document || !document.pages) return -1
        var doc = _presetCatalog.buildDoc(presetId)
        if (!doc || !doc.pages || !doc.pages.length) return -1
        var src = doc.pages[0]                       // screens are single-page
        if (!document.settings) document.settings = {}
        var tiles = []
        for (var i = 0; i < src.tiles.length; i++) {
            var st = src.tiles[i]
            var nid = _newId(st.type)                // re-key: no collision with live tiles
            var tile = { "id": nid, "type": st.type }
            if (st.size) tile.size = st.size
            tiles.push(tile)
            if (doc.settings && doc.settings[st.id] !== undefined)
                document.settings[nid] = JSON.parse(JSON.stringify(doc.settings[st.id]))
        }
        var page = { "name": _dedupPageName(src.name), "tiles": tiles }
        if (doc.appearance && doc.appearance.bgStyle)
            page.bg = { "style": doc.appearance.bgStyle }
        document.pages.push(page)
        _commitStructure()
        return document.pages.length - 1
    }
    // Dedup a proposed page name against existing pages (mirrors renamePage's rule).
    function _dedupPageName(proposed) {
        var want = String(proposed || "").trim()
        if (want === "") return _uniquePageName()
        var existing = Object.create(null)
        for (var i = 0; i < document.pages.length; i++) existing[document.pages[i].name] = true
        if (!existing[want]) return want
        var base = want, n = 2
        while (existing[base + " " + n]) n++
        return base + " " + n
    }

    // ── Starter layouts (seed the grid from the wizard's / preset choice) ─────
    // The curated preset library is the source of truth for starter layouts; the
    // legacy _mk/_page helpers are kept for any code-built layouts.
    property QtObject _presetCatalog: PresetCatalog {}
    function _mk(type) {
        return { "id": _newId(type), "type": type }
    }
    function _page(name, types) {
        var tiles = []
        for (var i = 0; i < types.length; i++) tiles.push(_mk(types[i]))
        return { "name": name, "tiles": tiles }
    }
    function _blankDoc() {
        return { "version": 1, "appearance": {}, "settings": {}, "pages": [ { "name": "Home", "tiles": [] } ] }
    }
    // The recommended few-screen starter a fresh install / wizard begins with -
    // work, system, and home (each a single-page screen), composed by buildBundle.
    readonly property var _starterBundle: ["productivity", "system-monitor", "home-ambient"]
    function seed(which) {
        if (which === "blank") return _blankDoc()
        if (which === "starter") {
            var b = _presetCatalog.buildBundle(_starterBundle)
            return b ? b : _blankDoc()
        }
        // A KNOWN preset id seeds that one screen (legacy ids "productivity",
        // "gaming", "minimal" still resolve, so old configs keep working); anything
        // else - empty or unknown, i.e. the default - starts from the starter bundle.
        if (which && _presetCatalog.has(which)) {
            var doc = _presetCatalog.buildDoc(which)
            return doc ? doc : _blankDoc()
        }
        var bd = _presetCatalog.buildBundle(_starterBundle)
        return bd ? bd : _blankDoc()
    }
}
