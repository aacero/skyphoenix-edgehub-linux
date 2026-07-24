import QtQuick

// ─────────────────────────────────────────────────────────────────────────
// UserWidgetCatalog - the Tier-0 user-widget loader (E3).
//
// Validates the raw scan entries handed over by ConfigBridge.listUserWidgets()
// (one JSON string per subdirectory of $XDG_DATA_HOME/xeneon-edge-hub/widgets)
// against docs/widgets/manifest-spec.md, and turns the valid ones into entries
// in the exact shape WidgetCatalog.items uses - so the rest of the hub (the
// picker, tile loaders, size validation, the expanded overlay) treats them
// like any shipped widget via WidgetCatalog.userItems.
//
// Everything invalid SKIPS that one directory with a recorded reason (surfaced
// in Diagnostics and as structured informational output) - a broken manifest must
// never take the dashboard down. Collisions are refused here AND in
// WidgetCatalog.def(), which consults shipped items first: shipped wins twice.
//
// SECURITY: this file gates nothing. A user widget is arbitrary QML running
// unsandboxed in the hub process (see the spec's security section). The
// validation here buys honest failure modes - visible skip reasons, no crash,
// no shipped-type shadowing - not containment.
// ─────────────────────────────────────────────────────────────────────────
QtObject {
    id: uc

    // Injected by the host (Dashboard): the size vocabulary, the shipped type
    // names (for collision rejection), and an optional path→URL resolver
    // (configBridge.imageUrl percent-encodes spaces/'#'; the concatenation
    // fallback serves hosts without the bridge, i.e. the offscreen tests).
    property var sizesModel: null
    property var shippedTypes: []
    property var urlResolver: null

    // Validated catalog entries (WidgetCatalog.items shape, plus iconName /
    // iconSource / description / fields / dir / user), and the skipped
    // directories with their reasons.
    property var items: []
    property var rejects: []

    // Picker glyph for a widget with no usable icon. The shipped-icon lint
    // (check_widget_icons.sh) cannot see user directories, so a missing SVG
    // must degrade to a bundled glyph rather than a blank picker tile.
    readonly property string fallbackIcon: "ui-layout"

    // The config-field subset manifests may declare. Deliberately excludes
    // `action` (host callbacks), `tasks` (a widget-specific editor) and
    // `accent` (the universal appearance section already provides it).
    readonly property var fieldTypes: ["text", "textarea", "number", "slider",
                                       "toggle", "segmented", "date", "hour", "info"]
    // Settings keys owned by the universal per-widget machinery.
    readonly property var reservedFieldKeys: ["title", "accent", "cardBackdrop"]

    function clear() { uc.items = []; uc.rejects = [] }

    // rawEntries: array of JSON strings from ConfigBridge.listUserWidgets().
    // Replaces items/rejects wholesale (a reload, not an append).
    function load(rawEntries) {
        var good = [], bad = [], seen = ({})
        var list = rawEntries || []
        for (var i = 0; i < list.length; i++) {
            var scan = null
            try { scan = JSON.parse(list[i]) } catch (e) { scan = null }
            var r = uc.validate(scan)
            // First manifest (scan order = directory name order) keeps a type.
            if (r.ok && seen.hasOwnProperty(r.item.type))
                r = { ok: false, reason: "duplicate user widget type '" + r.item.type + "' (an earlier directory already provides it)" }
            if (r.ok) { seen[r.item.type] = true; good.push(r.item) }
            else bad.push({ dir: (scan && typeof scan.dir === "string") ? scan.dir : "<unreadable scan entry>",
                            reason: r.reason })
        }
        uc.items = good
        uc.rejects = bad
        for (var j = 0; j < bad.length; j++)
            console.info("[user-widgets] skipped", bad[j].dir, "-", bad[j].reason)
    }

    function _isObj(v) { return v !== null && typeof v === "object" && !Array.isArray(v) }

    // A plain file name inside the widget directory: no path separators, no
    // parent traversal - a manifest may only reference its own directory.
    function _plainFileName(p) {
        return typeof p === "string" && p.length > 0
            && p.indexOf("/") < 0 && p.indexOf("\\") < 0 && p.indexOf("..") < 0
    }

    function _url(path) { return uc.urlResolver ? uc.urlResolver(path) : "file://" + path }

    // Validate ONE scan entry → { ok: true, item } | { ok: false, reason }.
    // Pure (no state changes), so the spec's rules are testable in isolation.
    function validate(scan) {
        function no(reason) { return { ok: false, reason: reason } }
        if (!_isObj(scan) || typeof scan.dir !== "string" || !scan.dir.length)
            return no("unreadable scan entry")
        if (scan.error) return no(String(scan.error))
        if (typeof scan.manifest !== "string") return no("missing manifest.json")

        var m
        try { m = JSON.parse(scan.manifest) }
        catch (e) { return no("manifest.json is not valid JSON (" + e.message + ")") }
        if (!_isObj(m)) return no("manifest.json must be a JSON object")
        if (m.manifestVersion !== 1)
            return no("unsupported manifestVersion " + JSON.stringify(m.manifestVersion) + " (this hub speaks version 1)")

        if (typeof m.type !== "string" || !/^user\.[a-z0-9][a-z0-9_-]*$/.test(m.type))
            return no("type must be namespaced 'user.<name>' (lowercase letters, digits, '-', '_')")
        if (uc.shippedTypes.indexOf(m.type) >= 0)
            return no("type '" + m.type + "' collides with a shipped widget type (shipped wins)")

        if (typeof m.title !== "string" || !m.title.trim().length)
            return no("title must be a non-empty string")

        var files = Array.isArray(scan.files) ? scan.files : []
        if (!_plainFileName(m.entry) || !/\.qml$/.test(m.entry))
            return no("entry must be a plain .qml file name inside the widget directory")
        if (files.indexOf(m.entry) < 0)
            return no("entry QML file '" + m.entry + "' not found in the widget directory")

        if (!Array.isArray(m.sizes) || !m.sizes.length)
            return no("sizes must be a non-empty array of size names")
        var declared = []
        for (var i = 0; i < m.sizes.length; i++) {
            var s = m.sizes[i]
            if (!uc.sizesModel || !uc.sizesModel.isLegal(s))
                return no("illegal size " + JSON.stringify(s) + " (legal: "
                          + (uc.sizesModel ? uc.sizesModel.all().join(", ") : "unavailable") + ")")
            if (declared.indexOf(s) < 0) declared.push(s)
        }
        // Same smallest → largest presentation order as the shipped catalog.
        declared.sort(function (a, b) {
            var d = uc.sizesModel.area(a) - uc.sizesModel.area(b)
            return d !== 0 ? d : (a < b ? -1 : 1)
        })
        var dflt = m.dflt
        if (dflt !== undefined) {
            if (typeof dflt !== "string" || declared.indexOf(dflt) < 0)
                return no("dflt must be one of the declared sizes")
        } else {
            dflt = declared.indexOf("1x1") >= 0 ? "1x1" : declared[0]
        }

        var seeds = m.defaults === undefined ? ({}) : m.defaults
        if (!_isObj(seeds)) return no("defaults must be a JSON object")

        var category = m.category === undefined ? "User" : m.category
        if (typeof category !== "string" || !category.trim().length)
            return no("category must be a non-empty string")
        var description = m.description === undefined ? "" : m.description
        if (typeof description !== "string") return no("description must be a string")

        // Icon: optional, and never fatal past shape checks - a declared-but-
        // absent file degrades to the fallback glyph; the widget still loads.
        var iconName = uc.fallbackIcon, iconSource = ""
        if (m.icon !== undefined) {
            if (!_plainFileName(m.icon) || !/\.(svg|png)$/.test(m.icon))
                return no("icon must be a plain .svg or .png file name inside the widget directory")
            if (files.indexOf(m.icon) >= 0) { iconSource = _url(scan.dir + "/" + m.icon); iconName = "" }
            else console.info("[user-widgets]", scan.dir,
                              "- declared icon '" + m.icon + "' not found; using the fallback glyph")
        }

        // Config fields: strict - a manifest that lies about its form is
        // skipped whole, not half-loaded. Only known-safe properties carry
        // through to the form renderer.
        var fields = []
        if (m.config !== undefined) {
            if (!Array.isArray(m.config)) return no("config must be an array of field objects")
            for (var f = 0; f < m.config.length; f++) {
                var fd = m.config[f]
                if (!_isObj(fd)) return no("config[" + f + "] must be an object")
                if (fd.type === "info") {
                    if (typeof fd.text !== "string" || !fd.text.length)
                        return no("config[" + f + "]: info fields need a non-empty text string")
                    fields.push({ type: "info", text: fd.text })
                    continue
                }
                if (uc.fieldTypes.indexOf(fd.type) < 0)
                    return no("config[" + f + "]: unsupported field type " + JSON.stringify(fd.type))
                if (typeof fd.key !== "string" || !/^[A-Za-z][A-Za-z0-9_]*$/.test(fd.key))
                    return no("config[" + f + "]: key must be a plain identifier")
                if (uc.reservedFieldKeys.indexOf(fd.key) >= 0)
                    return no("config[" + f + "]: key '" + fd.key + "' is reserved")
                if (typeof fd.label !== "string" || !fd.label.trim().length)
                    return no("config[" + f + "]: label must be a non-empty string")
                var g = { key: fd.key, label: fd.label, type: fd.type }
                var carry = ["dflt", "help", "placeholder", "min", "max", "step", "options"]
                for (var c = 0; c < carry.length; c++)
                    if (fd[carry[c]] !== undefined) g[carry[c]] = fd[carry[c]]
                fields.push(g)
            }
        }

        return { ok: true, item: {
            type: m.type, title: m.title, category: category,
            source: _url(scan.dir + "/" + m.entry),
            defaults: seeds, sizes: declared, dflt: dflt,
            description: description, iconName: iconName, iconSource: iconSource,
            fields: fields, dir: scan.dir, user: true } }
    }

    function isUser(type) {
        for (var i = 0; i < uc.items.length; i++)
            if (uc.items[i].type === type) return true
        return false
    }

    // Config-panel schema for a loaded user type, composed with the shared
    // schema helpers so user widgets get the same General + About + Widget
    // appearance sections as shipped ones. Falls through to the shared schema
    // for a type this catalog does not hold.
    function schemaFor(type, sharedSchema) {
        var d = null
        for (var i = 0; i < uc.items.length; i++)
            if (uc.items[i].type === type) { d = uc.items[i]; break }
        if (!d) return sharedSchema ? sharedSchema.schemaFor(type) : null
        var sections = []
        if (d.fields && d.fields.length)
            sections.push({ title: "Settings", cols: 1, fields: d.fields })
        if (sharedSchema) {
            sections.push(sharedSchema.titleSection(d.title))
            if (d.description) sections.push(sharedSchema.about(d.description))
            sections.push(sharedSchema.appearanceSection())
        }
        return { sections: sections }
    }

    // Diagnostics report (JSON): whether the loader is enabled, the scan dir,
    // what loaded, and every skipped directory with its reason.
    function reportJson(enabled, dirPath) {
        var loaded = []
        for (var i = 0; i < uc.items.length; i++)
            loaded.push({ type: uc.items[i].type, title: uc.items[i].title, dir: uc.items[i].dir })
        return JSON.stringify({ enabled: enabled === true, dir: dirPath || "",
                                loaded: loaded, skipped: uc.rejects })
    }
}
